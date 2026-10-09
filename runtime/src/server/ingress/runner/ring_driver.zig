//! The event loop of an ingress lane thread in the server: the lane's one
//! io_uring, the dispatch of each completion to its handler, the handlers of
//! a worker registration's polls, the writability poll of a worker's control
//! socket, the wake bits other threads raise, the shutdown drain, the renewal
//! and the sends of the lane's egress lease, and the per-lane tables and
//! buffers the loop serves.
//!
//! Invariants:
//! - The loop runs a handler per completion, per queued connection and per
//!   deferred worker fault, and each one returns `LaneFault!void`
//!   (`fault.loop_handlers`, checked in `root.zig`): a failure a client or a
//!   worker causes is settled inside the handler as a connection or worker
//!   outcome (`fault.zig`), so an error that leaves `run` is the lane's own.
//! - A handler runs to its end before the next one starts, and none runs
//!   another, except the deadline backstop, which first takes the worker's
//!   output or the lane's commands so that a completion that came in time
//!   wins over the fault (`deadline_driver.zig`).
//! - A completion of a worker registration's poll reaches its handler only
//!   while the registration still holds the worker it was armed for (its
//!   generation) and, for a poll only a reader arms, while the lane still
//!   reads that worker; any other completion is counted as stale.
//! - A pass makes one `io_uring_enter` at most: handlers only prepare
//!   submissions, and the pass ends by handing them to the kernel without
//!   waiting when it found work, or with the wait when it found none
//!   (`event_sources.LaneRing`). Only a pass that fills the submission queue
//!   enters early.
//! - A pass first renews the lane's egress lease when the manager's current
//!   gateway is not the one the lease holds (`renewEgressLease`), and last
//!   sends the `request_ended` entries its finishes noted (`runQueuedWork`).
//!   It waits for a completion only after both, and the wait ends the pass,
//!   so no handler mints a token under a lease older than the lane's last
//!   wait and no entry sits in the batch while the lane sleeps.
//! - Shutdown refuses new work first (accepts in `accept_flow.zig`, new
//!   streams in `admission.zig`), then serves until no request of the lane is
//!   live and the lane reads no worker, because a reader that left would
//!   strand the output of another lane's request on a worker it read. It
//!   ends only with its command queue empty, closing the lane to posts in
//!   the same step, since a `dispatch_ready` queued and never run would hold
//!   a worker slot for good.
//! - Only the lane thread touches what `initRuntime` allocates and the
//!   egress lease. Teardown gives back what commands still queued hold,
//!   finishes every request, closes every connection, gives its reader roles
//!   back, sends the `request_ended` entries its finishes noted and closes
//!   the lease's descriptor, and checks that every table is empty again,
//!   asserting it after a clean stop; only then does it free the tables.

const std = @import("std");
const linux = std.os.linux;

const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const uring_tags = @import("collo_io_uring_tags");
const accept = @import("../accept.zig");
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const http2_writing = @import("../http2/writing.zig");
const http2_lane = @import("../http2/lane_resources.zig");
const lane_mod = @import("../lane.zig");
const accept_flow = @import("accept_flow.zig");
const command_flow = @import("command_flow.zig");
const connection_flow = @import("connection_flow.zig");
const connection_slot = @import("connection_slot.zig");
const deadline_driver = @import("deadline_driver.zig");
const dispatch = @import("dispatch.zig");
const event_sources = @import("event_sources.zig");
const fs_fault_control = @import("fs_fault_control.zig");
const request_finish = @import("request_finish.zig");
const request_slot = @import("request_slot.zig");
const work_queues = @import("work_queues.zig");
const worker_completions = @import("worker_completions.zig");
const worker_control = @import("worker_control.zig");
const worker_fault = @import("worker_fault.zig");
const worker_registration = @import("worker_registration.zig");
const runner = @import("root.zig");

const LaneFault = fault.LaneFault;
const LaneRing = event_sources.LaneRing;

/// Completions one drain takes from the ring.
const cqe_batch_max: usize = 64;
/// Ring calls in a row that may fail transiently (`fault.ringErrorIsTransient`)
/// before the lane reports the last failure. A failed wait is retried after
/// the loop reaps what the ring holds, which is what clears a completion
/// queue overflow, so only a ring that keeps failing that long is broken.
const ring_transient_failures_max: u32 = 64;
/// How long the shutdown drain waits before it looks again at the tenures it
/// still holds over workers busy with other lanes' requests. Those lanes give
/// their slots back to the pool without telling the reader, so nothing else
/// wakes the drain when the worker goes idle.
const shutdown_tenure_check_ns: u64 = std.time.ns_per_ms;

comptime {
    // An accept completion is told apart from every other one by its top
    // byte (`dispatchCqe`).
    for (std.enums.values(event_sources.EventKind)) |kind|
        std.debug.assert(@intFromEnum(kind) != uring_tags.server_ingress_high_byte);
}

/// Consecutive transient failures of the lane's ring calls. A completion
/// reaped resets the count.
const RingRetries = struct {
    failures: u32 = 0,

    fn note(self: *RingRetries, err: fault.RingError) LaneFault!void {
        if (!fault.ringErrorIsTransient(err))
            return err;
        self.failures += 1;
        if (self.failures >= ring_transient_failures_max)
            return err;
    }
};

pub fn Methods(comptime Self: type) type {
    return struct {
        const Accept = accept_flow.Methods(Self);
        const Command = command_flow.Methods(Self);
        const Connection = connection_flow.Methods(Self);
        const Deadlines = deadline_driver.Methods(Self);
        const Dispatch = dispatch.Methods(Self);
        const FsFaultControl = fs_fault_control.Methods(Self);
        const Queues = work_queues.Methods(Self);
        const RequestFinish = request_finish.Methods(Self);
        const WorkerCompletions = worker_completions.Methods(Self);
        const WorkerControl = worker_control.Methods(Self);
        const WorkerFault = worker_fault.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        pub fn run(self: *Self) LaneFault!void {
            try initLane(self);
            defer deinitLane(self);

            try initRuntime(self);
            defer deinitRuntime(self);

            var ring = try LaneRing.init();
            defer ring.deinit();
            self.runtime_ring = &ring;
            defer self.runtime_ring = null;

            try armCommandPoll(self, &ring);
            try armTimerPoll(self, &ring);
            try Accept.ensureAcceptArmed(self, &ring);
            var terminal_state: event_sources.LaneRuntimeState = .exited;
            defer self.lane_state.store(@intFromEnum(terminal_state), .release);
            errdefer terminal_state = .failed;
            self.lane_state.store(@intFromEnum(event_sources.LaneRuntimeState.active), .release);
            var retries: RingRetries = .{};
            while (!self.service.shouldStop())
                try runPass(self, &ring, &retries);
            try self.handleStop();
        }

        /// Loop handler, run once the service is stopping: queues GOAWAY with
        /// no new streams on every HTTP/2 connection, serves until no request
        /// of the lane is live, it reads no worker and its command queue is
        /// empty, closes the lane to posts, then closes each connection still
        /// open.
        pub fn handleStop(self: *Self) LaneFault!void {
            const ring = self.runtime_ring orelse return error.IngressRingUnavailable;
            for (self.connections.touched(), 0..) |*runtime, index| {
                if (!runtime.isLive() or runtime.state != .http2_connection)
                    continue;
                // A connection that cannot take the frame still drains its
                // streams; the frame only spares a well-behaved client the
                // 503 a new stream gets now. The turn flushes it.
                try http2_writing.queueGoawayNoNewStreams(Self, self, runtime);
                Queues.enqueueConnection(self, @intCast(index));
            }
            var retries: RingRetries = .{};
            while (true) {
                try releaseIdleTenures(self);
                if (self.request_count == 0 and !readsAnyWorker(self)) {
                    if (closeIfQueueEmpty(self))
                        break;
                    // A slot handed to a request that ended meanwhile is in
                    // the queue, and only running its `dispatch_ready` gives
                    // it back; a grant it carries can make the lane a reader
                    // again, which the next round sees.
                    try self.handleCommands();
                    _ = try runQueuedWork(self);
                    continue;
                }
                if (self.request_count == 0) {
                    const now = self.monotonicNowNs();
                    try deadline_driver.armTimerNoLaterThan(Self, self, now, now +| shutdown_tenure_check_ns);
                }
                try runPass(self, ring, &retries);
            }
            for (self.connections.touched()) |*runtime| {
                if (runtime.isLive())
                    try Connection.tearDownConnection(self, runtime);
            }
            // The closes above are prepared on the ring; they reach the
            // kernel before the ring goes.
            try ring.submit();
        }

        /// Loop handler: drives the connection in `slot`, whose read poll
        /// fired or which another handler queued for a turn.
        pub fn handleConnectionReadable(self: *Self, slot: u32) LaneFault!void {
            return driveSlot(self, slot);
        }

        /// Loop handler: drives the connection in `slot` after its write
        /// poll fired. A drive flushes the queued writes before it reads.
        pub fn handleConnectionWritable(self: *Self, slot: u32) LaneFault!void {
            return driveSlot(self, slot);
        }

        /// Loop handler: the reader drains the worker's control socket and
        /// re-arms its polls, or runs the death path on a fault.
        pub fn handleWorkerControlReadable(self: *Self, registration_index: u32) LaneFault!void {
            switch (try WorkerControl.drainWorkerControl(self, registration_index, .yield_to_backlog)) {
                .ok, .would_block => try WorkerRegistration.armWorkerPolls(self, registration_index),
                .fault => |reason| try WorkerFault.faultWorker(self, registration_index, reason),
            }
        }

        /// Loop handler: the worker's control socket has room for the bytes
        /// this lane parked on it (`armWorkerControlWritable`).
        pub fn handleWorkerControlWritable(self: *Self, registration_index: u32) LaneFault!void {
            try Dispatch.flushBlockedSends(self, registration_index);
        }

        /// Loop handler: the reader answers the worker's fault requests and
        /// re-arms its polls, or runs the death path on a fault.
        pub fn handleWorkerFsFault(self: *Self, registration_index: u32) LaneFault!void {
            switch (try FsFaultControl.drainWorkerFsFault(self, registration_index)) {
                .ok, .would_block => try WorkerRegistration.armWorkerPolls(self, registration_index),
                .fault => |reason| try WorkerFault.faultWorker(self, registration_index, reason),
            }
        }

        /// Loop handler: the pidfd of a worker this lane reads reported its
        /// exit.
        pub fn handleWorkerPidfd(self: *Self, registration_index: u32) LaneFault!void {
            try WorkerFault.faultWorker(self, registration_index, .exited);
        }

        /// Arms a one-shot writability poll on the worker's control socket
        /// for a send of this lane that would block; its completion runs
        /// `handleWorkerControlWritable`. A poll already in flight serves.
        pub fn armWorkerControlWritable(self: *Self, registration_index: u32) LaneFault!void {
            const registration = try registrationAt(self, registration_index);
            if (registration.control_writable_poll_registered)
                return;
            const ring = self.runtime_ring orelse return error.IngressRingUnavailable;
            try ring.queuePoll(
                registration.control_fd,
                event_sources.pollMask(event_sources.write_events),
                .{ .kind = .worker_control_writable, .index = registration_index, .generation = registration.generation },
            );
            registration.control_writable_poll_registered = true;
        }

        /// Takes every wake bit raised since the last call and runs the
        /// retry each one asks for: the request bodies of this lane parked
        /// on a full payload ring, and the workers this lane reads whose
        /// forwarding window reopened.
        pub fn takeWakeBits(self: *Self) LaneFault!void {
            const bits = self.wake_bits.swap(0, .seq_cst);
            if (bits & runner.wake.payload_credit != 0) {
                self.lane.counters.h2_request_body_credit_wakes += 1;
                try Dispatch.retryRingBlockedSends(self);
            }
            if (bits & runner.wake.window_reopened != 0)
                try WorkerCompletions.resumeWindowBlockedReaders(self);
        }

        pub fn initRuntime(self: *Self) LaneFault!void {
            const capacities = self.table_capacities;
            self.connections = try connection_slot.ConnectionSlab.init(capacities.connections);
            errdefer self.connections.deinit();
            self.ready_connections = .{};
            self.connection_deadlines = try connection_slot.DeadlineHeap.initCapacity(
                self.service.allocator,
                {},
                capacities.connections,
            );
            errdefer {
                Deadlines.connectionDeadlines(self).deinit();
                self.connection_deadlines = null;
            }
            self.requests = try request_slot.RequestSlab.init(capacities.requests);
            errdefer self.requests.deinit();
            self.request_count = 0;
            self.registrations = try completions.RegistrationSlab.init(runner.max_completion_registrations);
            errdefer self.registrations.deinit();
            self.deferred_deaths = .{};
            self.h2_lane = try http2_lane.LaneResources.init(capacities.streams);
            errdefer self.h2_lane.deinit();

            self.ipc_send_scratch = try self.service.allocator.alloc(u8, ipc.max_message_bytes);
            errdefer {
                self.service.allocator.free(self.ipc_send_scratch);
                self.ipc_send_scratch = &.{};
            }
            self.ipc_recv_scratch = try self.service.allocator.alloc(u8, ipc.max_message_bytes);
            errdefer {
                self.service.allocator.free(self.ipc_recv_scratch);
                self.ipc_recv_scratch = &.{};
            }

            self.runtime_events = try event_sources.EventSet.init();
        }

        pub fn initLane(self: *Self) LaneFault!void {
            if (self.lane_initialized)
                return;
            self.lane = try lane_mod.IngressLane.init(
                self.service.allocator,
                .{
                    .lane_id = self.listener_index,
                    .max_requests = self.table_capacities.requests,
                    .command_obligation_reserve = lane_mod.obligationReserve(
                        self.service.routes.definitionCount(),
                    ),
                },
                self.monotonicNowNs(),
            );
            // `lane_initialized` flips under both locks, `runtime_mutex` first:
            // command producers read it under `runtime_mutex` (`post` in
            // `root.zig`) and counter snapshots under `counters_mutex`
            // (`countersSnapshot` in `root.zig`).
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            self.counters_mutex.lock();
            defer self.counters_mutex.unlock();
            self.lane_initialized = true;
        }

        pub fn deinitLane(self: *Self) void {
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            self.counters_mutex.lock();
            defer self.counters_mutex.unlock();
            if (!self.lane_initialized)
                return;
            self.retained_counters.add(self.lane.countersSnapshot());
            self.lane_initialized = false;
            self.lane.deinit();
        }

        /// Runs after the ring is gone and the lane stopped taking posts.
        /// After a clean `handleStop` no request is live, no connection open,
        /// no worker read and no command queued. After a lane fault it gives
        /// back what the commands still queued hold, ends each request still
        /// live as `.shutdown`, closes each connection, and tells the other
        /// lanes and the pool what each registration still owes them
        /// (`worker_registration.endRegistrationAtTeardown`); the server is
        /// stopping then.
        pub fn deinitRuntime(self: *Self) void {
            // `run` stores `.exited` only when `handleStop` returned, and a
            // lane fault stores `.failed` before this runs.
            const stopped_clean = self.state() == .exited;
            var teardown_failed = false;
            Command.returnQueuedHandoffs(self) catch |err| {
                teardown_failed = true;
                noteTeardownFailure(self, "give back a queued handoff", err);
            };
            for (self.requests.touched(), 0..) |*active, index| {
                if (!active.isLive())
                    continue;
                RequestFinish.finishRequest(self, @intCast(index), .shutdown) catch |err| {
                    teardown_failed = true;
                    noteTeardownFailure(self, "finish a request", err);
                };
            }
            for (self.connections.touched()) |*runtime| {
                if (!runtime.isLive())
                    continue;
                Connection.tearDownConnection(self, runtime) catch |err| {
                    teardown_failed = true;
                    noteTeardownFailure(self, "close a connection", err);
                };
            }
            for (self.registrations.touched(), 0..) |*registration, index| {
                if (!registration.inUse())
                    continue;
                WorkerRegistration.endRegistrationAtTeardown(self, @intCast(index)) catch |err| {
                    teardown_failed = true;
                    noteTeardownFailure(self, "end a worker registration", err);
                };
            }
            // The finishes above noted their `request_ended` entries on the
            // lease, which sends them before it closes its descriptor. Its
            // counts move into the retained counters in the same critical
            // section that resets it, so a snapshot counts them once.
            self.egress_lease.flush();
            {
                self.counters_mutex.lock();
                defer self.counters_mutex.unlock();
                self.retained_counters.egress_ended_batches_dropped_full += self.egress_lease.ended_batches_dropped_full;
                self.retained_counters.egress_ended_batches_dropped_closed += self.egress_lease.ended_batches_dropped_closed;
                self.egress_lease.deinit();
                self.egress_lease = .{};
            }
            // Every request is finished and every connection closed, so each
            // table must be empty here. The runner's count and the slabs'
            // own are kept by different code on different paths, so their
            // agreement is a real cross-check. Nothing else would notice an
            // entry that never comes back: it passes through no allocator and
            // stays invisible to a leak checker until its slab runs out and
            // new work is refused. A teardown that failed, or one after a
            // lane fault, broke the state these counts describe, so it
            // reports a disagreement instead of asserting.
            if (stopped_clean and !teardown_failed) {
                std.debug.assert(self.request_count == 0);
                std.debug.assert(self.requests.live_count == 0);
                std.debug.assert(self.connections.live_count == 0);
                std.debug.assert(self.h2_lane.streams.live_count == 0);
                std.debug.assert(self.h2_lane.header_blocks.used == 0);
                std.debug.assert(self.lane.deadline_wheel.liveEntries() == 0);
            } else if (!livenessCountsClear(self)) {
                std.log.err(
                    "ingress lane {d} tore down with state still held: requests={d} request_entries={d} connections={d} streams={d}",
                    .{
                        self.listener_index,
                        self.request_count,
                        self.requests.live_count,
                        self.connections.live_count,
                        self.h2_lane.streams.live_count,
                    },
                );
            }
            if (self.connection_deadlines) |*heap| {
                heap.deinit();
                self.connection_deadlines = null;
            }
            self.runtime_events.deinit();
            if (self.ipc_send_scratch.len != 0) {
                self.service.allocator.free(self.ipc_send_scratch);
                self.ipc_send_scratch = &.{};
            }
            if (self.ipc_recv_scratch.len != 0) {
                self.service.allocator.free(self.ipc_recv_scratch);
                self.ipc_recv_scratch = &.{};
            }
            self.h2_lane.deinit();
            self.registrations.deinit();
            self.requests.deinit();
            self.connections.deinit();
            self.ready_connections = .{};
            self.deferred_deaths = .{};
            self.lane.accept_registration = .{};
        }

        /// A failure met while tearing the lane down: the server stops, and
        /// the teardown goes on with the rest.
        fn noteTeardownFailure(self: *Self, comptime what: []const u8, err: LaneFault) void {
            self.service.requestStopSignal();
            std.log.err("ingress lane {d} failed to " ++ what ++ " at teardown: {s}", .{ self.listener_index, @errorName(err) });
        }

        /// Whether no request, connection, stream or wheel entry of the lane
        /// is still held.
        fn livenessCountsClear(self: *Self) bool {
            if (self.request_count != 0) return false;
            if (self.requests.live_count != 0) return false;
            if (self.connections.live_count != 0) return false;
            if (self.h2_lane.streams.live_count != 0) return false;
            return self.lane.deadline_wheel.liveEntries() == 0;
        }

        fn armCommandPoll(self: *Self, ring: *LaneRing) LaneFault!void {
            try ring.queuePoll(
                self.lane.command_queue.commandEventFd(),
                event_sources.pollMask(event_sources.read_events),
                .{ .kind = .command },
            );
        }

        fn armTimerPoll(self: *Self, ring: *LaneRing) LaneFault!void {
            try ring.queuePoll(
                self.runtime_events.timer_fd,
                event_sources.pollMask(event_sources.read_events),
                .{ .kind = .deadline_timer },
            );
        }

        /// One turn of the loop: renews the egress lease when the gateway
        /// changed, prepares the accept's re-arm when it is due, runs the
        /// completions the ring holds and the rest of the pass
        /// (`runQueuedWork`), and ends in its one `io_uring_enter`: a submit
        /// of what the pass prepared when it found work, so the next pass
        /// starts at once, or the submit and the wait when it found none. The
        /// completions the wait brings run in the next pass, after its
        /// renewal.
        fn runPass(self: *Self, ring: *LaneRing, retries: *RingRetries) LaneFault!void {
            self.lane.counters.loop_passes += 1;
            renewEgressLease(self);
            if (!self.service.shouldStop()) {
                _ = self.lane.accept_registration.finishBackoff(self.monotonicNowNs());
                if (self.lane.accept_registration.state == .inactive)
                    try Accept.ensureAcceptArmed(self, ring);
            }
            var did_work = try drainRingCqes(self, ring, retries);
            did_work = (try runQueuedWork(self)) or did_work;
            defer self.lane.counters.ring_enters = ring.enters;
            if (did_work)
                return ring.submit();
            ring.submitAndWait() catch |err| try retries.note(err);
        }

        /// Gives the lane's egress lease the current gateway's key and a
        /// descriptor of its control socket, or empties it while no gateway
        /// is current (`Manager.renewLease` in `server/gateway/manager.zig`),
        /// when the manager's current gateway is not the one the lease holds.
        /// Comparing the generations is one atomic load, so every pass makes
        /// it, and only a gateway change takes the manager's mutex.
        pub fn renewEgressLease(self: *Self) void {
            const gateways = self.service.egress_gateways;
            if (gateways.currentGeneration() != self.egress_lease.generation)
                gateways.renewLease(&self.egress_lease);
        }

        /// The rest of a pass after the completions it ran: the connections
        /// handlers queued for a turn, then the worker faults they deferred,
        /// then one `request_ended` packet with the entries the pass's
        /// finishes noted on the egress lease (`Lease.flush`), which never
        /// waits. Returns whether the connections or the faults found work.
        pub fn runQueuedWork(self: *Self) LaneFault!bool {
            const drove = try driveQueuedConnections(self);
            const faulted = try WorkerFault.processDeferredWorkerFaults(self);
            self.egress_lease.flush();
            return drove or faulted;
        }

        /// Takes the completions the ring holds without waiting and runs
        /// each one's handler. Returns whether it took any. A transient
        /// failure gives up this turn and is counted (`RingRetries`).
        fn drainRingCqes(self: *Self, ring: *LaneRing, retries: *RingRetries) LaneFault!bool {
            var cqes: [cqe_batch_max]linux.io_uring_cqe = undefined;
            const ready = ring.copyCompletions(&cqes) catch |err| {
                try retries.note(err);
                return false;
            };
            if (ready == 0)
                return false;
            retries.failures = 0;
            for (cqes[0..ready]) |cqe|
                try dispatchCqe(self, ring, cqe);
            return true;
        }

        /// Runs the handler a completion names, after the poll bookkeeping:
        /// a one-shot poll that completed is no longer in flight. A completion
        /// for a connection or a registration that has moved on, or one of a
        /// poll the lane cancelled, is counted as stale. Every user_data was
        /// packed by the lane, so one that decodes to nothing is a lane fault.
        fn dispatchCqe(self: *Self, ring: *LaneRing, cqe: linux.io_uring_cqe) LaneFault!void {
            if (accept.unpackAcceptUserData(cqe.user_data)) |_| {
                return self.handleAcceptCqe(cqe);
            } else |err| switch (err) {
                error.InvalidUserDataTag => {},
                error.InvalidLaneId => return error.InvalidLaneId,
            }
            const data = try event_sources.unpackEventData(cqe.user_data);
            switch (data.kind) {
                .command => {
                    try self.handleCommands();
                    try armCommandPoll(self, ring);
                },
                .deadline_timer => {
                    try self.handleDeadlineTimer();
                    try armTimerPoll(self, ring);
                },
                .connection_poll_cancel => self.lane.counters.connection_poll_cancel_cqes += 1,
                .connection_close => self.lane.counters.connection_close_cqes += 1,
                .worker_poll_cancel => self.lane.counters.worker_poll_cancel_cqes += 1,
                .connection_read, .connection_write => {
                    const runtime = self.connections.get(data.index) orelse {
                        self.lane.counters.stale_connection_cqe += 1;
                        return;
                    };
                    if (connection_slot.connectionGenerationTag(runtime.key) != data.generation) {
                        self.lane.counters.stale_connection_cqe += 1;
                        return;
                    }
                    switch (data.kind) {
                        .connection_write => {
                            runtime.registered_wait_events &= ~event_sources.write_interest;
                            try self.handleConnectionWritable(data.index);
                        },
                        .connection_read => {
                            runtime.registered_wait_events &= ~event_sources.read_interest;
                            try self.handleConnectionReadable(data.index);
                        },
                        else => unreachable,
                    }
                },
                .worker_completion => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerCompletions(data.index),
                .worker_control => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerControlReadable(data.index),
                .worker_control_writable => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerControlWritable(data.index),
                .worker_fs_fault => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerFsFault(data.index),
                .worker_pidfd => if (workerPollReady(self, data, cqe.res))
                    try self.handleWorkerPidfd(data.index),
            }
        }

        /// Takes the completion of a worker registration's poll: clears its
        /// in-flight flag and returns whether it reports readiness for the
        /// handler. A completion for a registration that moved on, or of a
        /// poll a cancel removed (ECANCELED), is counted as stale.
        fn workerPollReady(self: *Self, data: event_sources.EventData, result: i32) bool {
            const registration = registrationForCqe(self, data) orelse {
                self.lane.counters.stale_worker_poll_cqes += 1;
                return false;
            };
            const in_flight = pollInFlight(registration, data.kind) orelse {
                self.lane.counters.stale_worker_poll_cqes += 1;
                return false;
            };
            in_flight.* = false;
            if (result == -@as(i32, @intFromEnum(linux.E.CANCELED))) {
                self.lane.counters.stale_worker_poll_cqes += 1;
                return false;
            }
            return true;
        }

        /// The registration a worker poll's completion names, or null when
        /// the place was freed or holds a later worker since the poll was
        /// armed, or when the poll is one only a reader arms and the lane no
        /// longer reads the worker.
        fn registrationForCqe(self: *Self, data: event_sources.EventData) ?*completions.Registration {
            const registration = self.registrations.get(data.index) orelse return null;
            if (registration.generation != data.generation)
                return null;
            switch (data.kind) {
                .worker_completion, .worker_control, .worker_fs_fault, .worker_pidfd => {
                    if (!registration.reading())
                        return null;
                },
                else => {},
            }
            return registration;
        }

        /// Drives the connections handlers queued for a turn, each once per
        /// pass at most as many times as the lane has connection slots, so a
        /// connection that queues itself again cannot hold the loop.
        fn driveQueuedConnections(self: *Self) LaneFault!bool {
            var did_work = false;
            var budget = self.connections.high_water;
            while (budget != 0) : (budget -= 1) {
                const slot = Queues.popConnection(self) orelse break;
                did_work = true;
                try self.handleConnectionReadable(slot);
            }
            return did_work;
        }

        /// Drives the connection in `slot` (`connection_flow.driveConnection`),
        /// counting a slot that holds no connection as stale.
        fn driveSlot(self: *Self, slot: u32) LaneFault!void {
            if (self.connections.get(slot) == null) {
                self.lane.counters.stale_connection_cqe += 1;
                return;
            }
            _ = try Connection.driveConnection(self, slot);
        }

        /// The registration at `registration_index`, which must hold a
        /// worker: a handler reaches one only through a completion or a call
        /// that checked it, so anything else is the lane's own mistake.
        fn registrationAt(self: *Self, registration_index: u32) LaneFault!*completions.Registration {
            return self.registrations.get(registration_index) orelse error.InvalidCompletionRegistration;
        }

        /// Gives up every tenure over a worker on which the lane has no
        /// request, as the shutdown drain needs. A tenure over a worker other
        /// lanes still use stays (`Pool.transferReader` answers `.kept`).
        fn releaseIdleTenures(self: *Self) LaneFault!void {
            for (self.registrations.touched(), 0..) |*registration, index| {
                if (!registration.inUse() or !registration.reading())
                    continue;
                if (registration.inflight_request_len != 0)
                    continue;
                _ = try Command.giveUpTenure(self, @intCast(index));
            }
        }

        /// Closes the lane to commands when its queue is empty, and says
        /// whether it did. The check and the close run under `runtime_mutex`,
        /// which every post holds from its check of the lane's state through
        /// its push (`post` in `root.zig`), so a post lands before the close
        /// and is seen here, or after it and is refused to its sender, which
        /// keeps what it carried (`lane_commands.zig`).
        fn closeIfQueueEmpty(self: *Self) bool {
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            if (self.lane.command_queue.pending() != 0)
                return false;
            self.lane_state.store(@intFromEnum(event_sources.LaneRuntimeState.closed), .release);
            return true;
        }

        fn readsAnyWorker(self: *Self) bool {
            for (self.registrations.touched()) |*registration| {
                if (registration.inUse() and registration.reading())
                    return true;
            }
            return false;
        }
    };
}

/// The in-flight flag of a registration's poll of `kind`; null for a kind
/// no registration polls.
fn pollInFlight(registration: *completions.Registration, kind: event_sources.EventKind) ?*bool {
    return switch (kind) {
        .worker_completion => &registration.poll_registered,
        .worker_control => &registration.control_poll_registered,
        .worker_control_writable => &registration.control_writable_poll_registered,
        .worker_fs_fault => &registration.fs_fault_poll_registered,
        .worker_pidfd => &registration.pidfd_poll_registered,
        .command,
        .deadline_timer,
        .connection_read,
        .connection_write,
        .connection_poll_cancel,
        .connection_close,
        .worker_poll_cancel,
        => null,
    };
}
