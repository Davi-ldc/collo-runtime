//! The ingress service's (`service.zig`) side of the launcher's and the
//! reaper's `Deps`, and the posts that carry a worker pool's results to the
//! lanes. The service is the one place that reaches every lane, so it posts
//! the commands that pools and other threads address to a lane
//! (`postToLane`, `postHandoff`, `strandWaiters`, `announceWorkerDeath`),
//! raises a lane's wake bits (`raiseLaneWake`), and hands the reaper the
//! retirements a pool call answers (`queueRetirement`); the launcher and the
//! reaper reach the supervisor, the lanes and each other through it.
//!
//! `Methods(Service)` holds all of it, and each part has its thread: the
//! `launch*` callbacks run on the launcher thread and the `reaper*` ones on
//! the reaper thread, which hold none of their own locks across the call.
//! `postToLane` and `raiseLaneWake` run on any thread, `postHandoff` on the
//! launcher thread for a publish, `strandWaiters` on the launcher thread and
//! the metrics thread, `announceWorkerDeath` on the metrics thread
//! (`analytics_drain.zig`) and the launcher thread (an egress retirement),
//! and `queueRetirement` on a lane thread, the launcher thread or the
//! metrics thread.
//!
//! Invariants:
//! - Every post goes through `postToLane`, which no pool mutex may be held
//!   across.
//! - A post a lane refuses is the poster's to act on, as `lane_commands.zig`
//!   says for each command.
//! - Of the callbacks, only the egress attach and the gateway prewarm return
//!   an error, and the launcher decides what each failure costs
//!   (`launcher.zig`). A post or a pool call that fails inside the others,
//!   and a zygote that exited, stop the server (`recordFatalError`).

const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const lifecycle = @import("collo_server_lifecycle");
const server_config = @import("collo_server_config");
const supervision = @import("collo_server_supervisor");
const commands = @import("commands.zig");
const fault = @import("fault.zig");
const lane_commands = @import("lane_commands.zig");

const launcher_mod = supervision.launcher;
const pool = supervision.pool;
const WorkerPool = supervision.WorkerPool;
const WorkerRecord = supervision.worker_table.Record;
const DefinitionIndex = server_config.DefinitionIndex;

/// Waiters one `takeStranded` call hands over; `strandWaiters` calls again
/// until a call returns fewer.
const stranded_batch_max: usize = 32;

pub fn Methods(comptime Self: type) type {
    return struct {
        const PostError = Self.PostError;

        /// Posts `command` to lane `lane_id` from any thread, consuming it on
        /// every path (`LaneWorker.post`). False when the lane's queue is full for
        /// it or the lane is not running; the caller then does what
        /// `lane_commands.zig` says for that command. Takes no pool mutex, and
        /// none may be held across it.
        pub fn postToLane(self: *Self, lane_id: pool.LaneId, command: commands.Command) PostError!bool {
            if (lane_id >= self.lanes.len) {
                var refused = command;
                refused.deinit();
                return error.InvalidLaneId;
            }
            return self.lanes[lane_id].post(command);
        }

        /// Raises the wake bit `bit` (`runner.wake`) on lane `lane_id` from
        /// any thread (`LaneWorker.raiseWake`). A lane that is not running
        /// has nothing to retry and takes no wake.
        pub fn raiseLaneWake(self: *Self, lane_id: pool.LaneId, bit: u32) PostError!void {
            if (lane_id >= self.lanes.len)
                return error.InvalidLaneId;
            try self.lanes[lane_id].raiseWake(bit);
        }

        /// Posts `dispatch_ready` for a slot a pool handed to a waiting request
        /// off any lane (`Pool.publish` on the launcher thread). When the
        /// waiter's lane cannot take the command, the slot goes back to the pool
        /// at once with the grant that lane never saw (`Pool.returnHandoff`).
        /// That may hand the slot to the next waiter, so the loop runs until a
        /// post lands or the pool keeps the slot; every turn takes a waiter out
        /// of the FIFO, which bounds it by `pool_waiters_max`. A waiter whose post
        /// was refused is answered 503 at its own deadline.
        pub fn postHandoff(self: *Self, first: WorkerPool.Handoff) (PostError || error{SlotNotHeld})!void {
            var next: ?WorkerPool.Handoff = first;
            while (next) |handoff| {
                next = null;
                const posted = try self.postToLane(handoff.waiter.lane, .{ .dispatch_ready = .{
                    .request_key = handoff.waiter.request_key,
                    .worker_key = handoff.worker.key(),
                    .worker = handoff.worker,
                    .slot = handoff.slot,
                    .reader = handoff.reader,
                } });
                if (posted)
                    return;
                const worker_pool = self.supervisor.poolFor(handoff.worker.definition_index);
                switch (try worker_pool.returnHandoff(
                    handoff.worker,
                    handoff.slot,
                    handoff.waiter.lane,
                    handoff.reader,
                    process.monotonicNowNsOrZero(),
                )) {
                    .idle => {},
                    .handed_to => |again| next = again,
                    .retire => self.queueRetirement(handoff.worker),
                }
            }
        }

        /// Answers the waiters of `definition`'s pool that nothing can serve,
        /// because no worker is live and no launch is in flight
        /// (`Pool.takeStranded`): each waiter's lane gets `dispatch_failed` and
        /// answers 503. A waiter whose post is refused gets 503 at its own
        /// deadline. The loop ends once the FIFO is empty, at most
        /// `pool_waiters_max` waiters later.
        pub fn strandWaiters(
            self: *Self,
            definition: DefinitionIndex,
            reason: lane_commands.DispatchFailed.Reason,
        ) PostError!void {
            const worker_pool = self.supervisor.poolFor(definition);
            var batch: [stranded_batch_max]pool.Waiter = undefined;
            while (true) {
                const stranded = worker_pool.takeStranded(&batch);
                for (stranded) |waiter| {
                    _ = try self.postToLane(waiter.lane, .{ .dispatch_failed = .{
                        .request_key = waiter.request_key,
                        .reason = reason,
                    } });
                }
                if (stranded.len < batch.len)
                    return;
            }
        }

        /// The death of `worker` seen off the lanes and off the reaper, after
        /// `Pool.markDead` returned `death`: posts `worker_died` with `reason`
        /// to every lane the death names, each of which ends its requests on the
        /// worker and gives its slots and its reader role back, and queues the
        /// retirement at once when no lane holds or reads the worker. A lane
        /// whose queue refuses the notice learns of the death from the worker's
        /// own channels or from its requests' deadlines. As a lane does for a
        /// death it owns, it then asks for a replacement, or answers 503 to the
        /// waiters nothing is left to serve (`growOrStrand` in
        /// `runner/admission.zig`).
        pub fn announceWorkerDeath(
            self: *Self,
            worker: *WorkerRecord,
            worker_key: lifecycle.WorkerKey,
            death: WorkerPool.Death,
            reason: fault.WorkerFaultReason,
        ) void {
            for (death.slice()) |lane_id| {
                _ = self.postToLane(lane_id, .{ .worker_died = .{
                    .worker_key = worker_key,
                    .reason = reason,
                } }) catch |err| self.recordFatalError(err);
            }
            if (death.retire)
                self.queueRetirement(worker);
            const definition = worker.definition_index;
            if (self.supervisor.poolFor(definition).growthWanted(self.supervisor.memoryGate())) {
                self.launcher.submit(definition, .replacement);
            } else {
                self.strandWaiters(definition, .growth_refused) catch |err| self.recordFatalError(err);
            }
        }

        /// Queues the retirement of `worker` to the reaper after a pool call
        /// answered `.retire`: the worker left service through a death, an
        /// idle retirement or an egress retirement, and nothing holds or reads
        /// it. The reaper counts each departure apart.
        pub fn queueRetirement(self: *Self, worker: *WorkerRecord) void {
            const worker_pool = self.supervisor.poolFor(worker.definition_index);
            const departure: pool.Departure = if (worker_pool.inspect(worker)) |view|
                view.departure orelse .died
            else
                .died;
            self.reaper.queueRetirement(worker, switch (departure) {
                .idle => .idle,
                .died => .died,
                .egress => .egress_reattach,
            });
        }

        // The launcher's `Deps`, on the launcher thread.

        /// Claims a launch when the pool wants one under the memory gate
        /// (`Supervisor.claimLaunch`).
        pub fn launchClaim(ctx: *anyopaque, definition: DefinitionIndex) ?pool.LaunchTicket {
            return fromContext(ctx).supervisor.claimLaunch(definition);
        }

        pub fn launchAttachEgress(
            ctx: *anyopaque,
            definition: DefinitionIndex,
            wake_set: *const ipc.egress_shared.WakeSet,
        ) anyerror!?launcher_mod.EgressAttach {
            return supervision.worker_factory.attachLaunchEgress(fromContext(ctx).supervisor, definition, wake_set);
        }

        pub fn launchEgressCurrentGeneration(ctx: *anyopaque) u64 {
            return fromContext(ctx).supervisor.currentEgressGatewayGeneration();
        }

        pub fn launchEgressPrewarm(ctx: *anyopaque) anyerror!void {
            try fromContext(ctx).supervisor.prewarmEgressGateway();
        }

        pub fn launchEgressBootEnded(ctx: *anyopaque, generation: u64, session_id: u64) void {
            fromContext(ctx).supervisor.endEgressGatewayBootToken(generation, session_id);
        }

        pub fn launchNextStaleEgressWorker(ctx: *anyopaque, generation: u64) ?launcher_mod.ReattachTarget {
            return fromContext(ctx).supervisor.nextStaleEgressWorker(generation);
        }

        pub fn launchSetWorkerEgress(
            ctx: *anyopaque,
            target: *const launcher_mod.ReattachTarget,
            generation: u64,
            session_id: u64,
        ) bool {
            return fromContext(ctx).supervisor.setWorkerEgress(target, generation, session_id);
        }

        /// Takes a worker its gateway's loss left without a session out of
        /// service (`Supervisor.retireForEgress`) and announces the death to
        /// the lanes that hold or read it, as a death seen off the lanes is.
        /// Does nothing when the worker left service meanwhile.
        pub fn launchRetireForEgress(ctx: *anyopaque, target: *const launcher_mod.ReattachTarget) void {
            const self = fromContext(ctx);
            const death = self.supervisor.retireForEgress(target) orelse return;
            self.announceWorkerDeath(target.record, target.worker_key, death, .egress_session_failed);
        }

        pub fn launchDropEgressSession(ctx: *anyopaque, generation: u64, session_id: u64) bool {
            return fromContext(ctx).supervisor.dropEgressSession(generation, session_id);
        }

        /// Builds the record of a ready worker in the storage of its ticket's
        /// entry (`worker_registry.buildRecord`), publishes it, and posts each
        /// slot the publish handed to a waiting request. Only this thread ends a
        /// launch, and it ends each once, so a publish the pool refuses is the
        /// server's own fault.
        pub fn launchPublish(
            ctx: *anyopaque,
            definition: DefinitionIndex,
            ticket: pool.LaunchTicket,
            ready: launcher_mod.ReadyWorker,
        ) void {
            const self = fromContext(ctx);
            const supervisor = self.supervisor;
            const record = supervision.worker_registry.buildRecord(supervisor, definition, ticket, ready);
            const worker_pool = supervisor.poolFor(definition);
            const handoffs = worker_pool.publish(ticket, record, process.monotonicNowNsOrZero()) catch |err| {
                self.recordFatalError(err);
                return;
            };
            for (handoffs.slice()) |handoff|
                self.postHandoff(handoff) catch |err| self.recordFatalError(err);
            // A worker that serves no waiter has no reader, and the reaper
            // watches the pidfds of reader-less workers only from its next scan,
            // so it is told now rather than at its next pass.
            const view = worker_pool.inspect(record) orelse return;
            if (view.reader == null)
                self.reaper.wakeForPidfdScan();
        }

        /// Ends a launch that produced no worker: gives the ticket back
        /// (`worker_factory.endLaunch`), answers the waiters nothing else can
        /// serve, and hands what the child left to the reaper. A failed launch
        /// starts no other by itself; the next request starts one again. A
        /// failure that took the zygote with it stops the server, since nothing
        /// restarts the zygote.
        pub fn launchFailed(
            ctx: *anyopaque,
            definition: DefinitionIndex,
            ticket: pool.LaunchTicket,
            failure: launcher_mod.LaunchFailure,
            leftovers: launcher_mod.Leftovers,
        ) void {
            const self = fromContext(ctx);
            supervision.worker_factory.endLaunch(self.supervisor, definition, ticket);
            self.strandWaiters(definition, .launch_failed) catch |err| self.recordFatalError(err);
            self.reaper.queueLeftovers(leftovers);
            if (failure.endsZygote())
                self.recordFatalError(error.ZygoteDied);
        }

        pub fn launchZygoteExited(ctx: *anyopaque) void {
            fromContext(ctx).recordFatalError(error.ZygoteDied);
        }

        // The reaper's `Deps`, on the reaper thread.

        pub fn reaperPostReleaseWorker(
            ctx: *anyopaque,
            lane_id: pool.LaneId,
            worker_key: lifecycle.WorkerKey,
            epoch: pool.ReaderEpoch,
        ) bool {
            const self = fromContext(ctx);
            return self.postToLane(lane_id, .{ .release_worker = .{
                .worker_key = worker_key,
                .epoch = epoch,
            } }) catch |err| {
                self.recordFatalError(err);
                return false;
            };
        }

        /// The reaper sees a death only through the pidfd of a worker no lane
        /// reads, so the reason is always its exit.
        pub fn reaperPostWorkerDied(ctx: *anyopaque, lane_id: pool.LaneId, worker_key: lifecycle.WorkerKey) bool {
            const self = fromContext(ctx);
            return self.postToLane(lane_id, .{ .worker_died = .{
                .worker_key = worker_key,
                .reason = .exited,
            } }) catch |err| {
                self.recordFatalError(err);
                return false;
            };
        }

        pub fn reaperSubmit(ctx: *anyopaque, definition: DefinitionIndex, reason: launcher_mod.GrowthReason) void {
            fromContext(ctx).launcher.submit(definition, reason);
        }

        pub fn reaperLeftoversReaped(ctx: *anyopaque) void {
            fromContext(ctx).launcher.leftoversReaped();
        }

        fn fromContext(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }
    };
}
