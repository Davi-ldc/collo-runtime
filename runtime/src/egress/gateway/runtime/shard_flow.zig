//! What the gateway does with its shards, as a comptime mixin over the gateway run on its loop
//! thread: publishing what shard engines produce into worker endpoints, collecting a shard's
//! ready fetches and supervising a shard that failed.
//!
//! A shard failure that is not one fetch's own, such as a hung-up wake eventfd or an error that
//! escapes collection, restarts that shard in place. Its fetches end with an error, except those
//! whose replay the worker cannot observe, which are resubmitted on the restarted engine under
//! the pool key and the network policy entry their routes recorded at admission. The gateway
//! process ends only when the shard's teardown or restart fails, or when the shard exceeds the
//! restart budget in `supervisor_limits.shard_restart`.

const std = @import("std");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const active_fetch = @import("../active_fetch.zig");
const engine_mod = @import("../engine.zig");
const publisher = @import("../publisher.zig");
const readiness_mod = @import("../readiness.zig");
const router_mod = @import("../router.zig");
const sessions = @import("../sessions.zig");
const supervisor_limits = @import("../supervisor_limits.zig");

pub const ReadinessInterests = struct {
    shards: []const readiness_mod.ShardFd,
    workers: []const readiness_mod.WorkerFd,
};

pub fn Methods(comptime Gateway: type) type {
    return struct {
        /// Writes `bytes` onto the worker's completion ring. A worker that is gone fails with
        /// `error.PeerClosed`; a full or broken ring marks the worker for drop and fails with
        /// `error.EgressGatewayWorkerBackpressure`.
        pub fn queuePacket(self: *Gateway, worker_session_id: u64, bytes: []const u8) !void {
            const worker = self.findWorkerBySession(worker_session_id) orelse return error.PeerClosed;
            const result = publisher.queuePacket(worker, bytes) catch |err| switch (err) {
                error.EgressSharedRingFull => {
                    self.markWorkerForDrop(worker_session_id);
                    return error.EgressGatewayWorkerBackpressure;
                },
                else => {
                    self.markWorkerForDrop(worker_session_id);
                    std.log.warn("egress gateway dropping worker_session_id={d} after corrupt completion ring: {s}", .{ worker_session_id, @errorName(err) });
                    return error.EgressGatewayWorkerBackpressure;
                },
            };
            self.noteCompletionWrite(worker, result);
        }

        /// Publishes a body batch of `fetch_id`, records each extent it wrote in the worker's
        /// slot ledger, and returns how many it wrote. A worker that is gone fails with
        /// `error.PeerClosed`. Otherwise every failure returns
        /// `error.EgressGatewayWorkerBackpressure`: a full pool or ring fails only the fetch, and
        /// any other publication error also marks the worker for drop.
        pub fn publishBodyChunkBatch(
            self: *Gateway,
            worker_session_id: u64,
            fetch_id: u64,
            body_id: u64,
            chunks: []const engine_mod.BodyChunkPayload,
            scratch: []u8,
        ) !usize {
            const worker = self.findWorkerBySession(worker_session_id) orelse return error.PeerClosed;
            var extents: [ipc.egress_shared.body_pool_slot_count]publisher.PublishedExtent = undefined;
            const result = publisher.publishBodyChunkBatch(
                worker,
                fetch_id,
                body_id,
                chunks,
                scratch,
                &extents,
            ) catch |err| switch (err) {
                error.EgressSharedRingFull => {
                    // A full pool or ring means a slow worker, not a protocol
                    // failure. The drain preflight reserves the worst-case blocks
                    // and descriptors of the whole batch before it drains, and
                    // every completion-ring producer runs on this thread, so only
                    // a bookkeeping bug reaches this branch. If one does, the
                    // fetch fails, since its drained bytes are gone, and the
                    // worker stays.
                    std.log.warn("egress gateway body pool full for worker_session_id={d}; failing fetch_id={d}", .{ worker_session_id, fetch_id });
                    return error.EgressGatewayWorkerBackpressure;
                },
                else => {
                    self.markWorkerForDrop(worker_session_id);
                    std.log.warn("egress gateway dropping worker_session_id={d} after failed body publication: {s}", .{ worker_session_id, @errorName(err) });
                    return error.EgressGatewayWorkerBackpressure;
                },
            };
            for (extents[0..result.extents]) |extent|
                worker.recordSlotCredit(extent.handle, extent.len, fetch_id, body_id, extent.credit);
            self.noteCompletionWrite(worker, result.write);
            return result.extents;
        }

        /// Writes the worker's completion eventfd when the ring write asked for it: at once
        /// outside a shard-ready pass, and at the end of a pass otherwise, since a pass publishes
        /// many packets but owes each worker one wake. `collectShardReady` flushes in a defer, so
        /// a pass that fails still delivers its wakes.
        pub fn noteCompletionWrite(
            self: *Gateway,
            worker: *sessions.Worker,
            result: ipc.egress_shared.PacketWriteResult,
        ) void {
            if (!result.eventfd_notify_required)
                return;
            if (self.coalesce_completion_notifies) {
                worker.completion_notify_pending = true;
                return;
            }
            ipc.egress_shared.notify(worker.endpoint.completion_eventfd);
        }

        pub fn flushCompletionNotifies(self: *Gateway) void {
            var index: usize = 0;
            while (index < self.workers.len()) : (index += 1) {
                const worker = self.workers.byIndex(index) orelse continue;
                if (!worker.completion_notify_pending)
                    continue;
                worker.completion_notify_pending = false;
                ipc.egress_shared.notify(worker.endpoint.completion_eventfd);
            }
        }

        pub fn refreshReadinessInterests(self: *Gateway) !ReadinessInterests {
            return .{
                .shards = try self.shards.refreshInterests(self.allocator),
                .workers = try self.workers.refreshInterests(self.allocator),
            };
        }

        pub fn collectShardReady(self: *Gateway, shard_index: usize) !void {
            self.completed_fetches.clearRetainingCapacity();
            self.coalesce_completion_notifies = true;
            defer {
                self.coalesce_completion_notifies = false;
                self.flushCompletionNotifies();
            }
            // Completed fetches lose their routes even when collection fails
            // partway. A completed fetch has already left the shard's active
            // table, so the supervisor's partition never sees it; skipping
            // this on the error path would leave its route and active-fetch
            // counts behind for good whenever one fetch completes and a later
            // one in the same pass trips a shard fault.
            defer {
                for (self.completed_fetches.items) |fetch| {
                    self.removeRoute(.{
                        .worker_session_id = fetch.worker_session_id,
                        .fetch_id = fetch.fetch_id,
                        .body_id = fetch.body_id,
                    });
                }
                self.completed_fetches.clearRetainingCapacity();
            }
            try self.shards.collectReadyCompleted(shard_index, self.allocator, &self.completed_fetches);
        }

        /// Contains a shard-scoped failure to its shard: a hung-up wake eventfd, or an error
        /// from `collectShardReady` that the engine did not demote to one fetch's failure. It
        /// quarantines the shard, stops its engine, partitions its fetches into replay-safe ones
        /// and ones it ends with an error, removes the routes of the latter, restarts the engine
        /// on the threads and rings it booted with (`Shard.restart`, the only restart the
        /// gateway's seccomp filter allows), resubmits the replay-safe fetches and lifts the
        /// quarantine. An error it returns ends the gateway process: either the shard exceeded
        /// its restart budget, returned as `cause`, or the teardown or restart failed.
        pub fn superviseShardFailure(self: *Gateway, shard_index: usize, cause: anyerror) anyerror!void {
            const shard = self.shards.get(shard_index);
            // The restart budget comes first: a shard that keeps failing is not
            // recovering, and each restart already cost it its fetches. The
            // trip logs at warn, not err: the propagated cause ends the process
            // and is reported there, and this line only adds the budget and
            // the trip count.
            if (!shard.restart_backstop.admitRestartAt(os_process.monotonicNowNsOrZero())) {
                std.log.warn(
                    "egress gateway shard {d} restart backstop tripped ({d} restarts/{d}s, trips={d}): {s}",
                    .{
                        shard_index,
                        supervisor_limits.shard_restart.max_restarts_in_window,
                        supervisor_limits.shard_restart.window_ns / std.time.ns_per_s,
                        shard.restart_backstop.trips,
                        @errorName(cause),
                    },
                );
                return cause;
            }
            std.log.warn("egress gateway restarting shard {d}: {s}", .{ shard_index, @errorName(cause) });

            // While the shard is quarantined, admission refuses fetches that
            // hash to it. The restart runs synchronously on this loop, so no
            // command can observe the flag; it keeps the rule in place should
            // teardown ever run asynchronously. A failed restart leaves it
            // set, since the process is ending.
            shard.quarantined = true;

            // Stop before partitioning: the partition reads task state the
            // engine threads mutate until stop has parked them.
            shard.engine.stop();

            var replay: std.array_list.Aligned(engine_mod.ReplayFetch, null) = .empty;
            defer {
                // A successful restart pops every item, so only a failure
                // leaves retained tasks here. The process is ending then, but
                // releasing them keeps its teardown free of leaks.
                for (replay.items) |item|
                    item.task.release();
                replay.deinit(self.allocator);
            }
            var retired: std.array_list.Aligned(active_fetch.WorkerScopedFetch, null) = .empty;
            defer retired.deinit(self.allocator);
            try shard.engine.partitionActivesForTeardown(self.allocator, &replay, &retired, cause);

            // Demoted and finished fetches lose their routes now: their late
            // extent releases take the release path's missing-route branch,
            // and their admission counts drop as on any retirement.
            // Replay-safe fetches keep their routes, since they come back with
            // the same identity on the same shard.
            for (retired.items) |scoped| {
                self.removeRoute(.{
                    .worker_session_id = scoped.worker_session_id,
                    .fetch_id = scoped.fetch_id,
                    .body_id = scoped.body_id,
                });
            }

            const retired_count = retired.items.len;
            const replay_count = replay.items.len;
            try shard.restart();

            // Resubmit the replay-safe fetches right away, with the same
            // identity, the original deadline and the dead attempt's cost
            // carried over. A resubmission that fails ends only its fetch, as
            // a demotion would.
            while (replay.pop()) |item| {
                defer item.task.release();
                self.redispatchReplayFetch(shard_index, item);
            }

            shard.quarantined = false;
            std.log.warn(
                "egress gateway shard {d} restarted (restarts={d} retired={d} redispatched={d})",
                .{ shard_index, shard.restarts, retired_count, replay_count },
            );
        }

        /// Resubmits one replay-safe fetch on its restarted shard, under the pool key and the
        /// network policy entry its route recorded at admission. A failure ends the fetch as a
        /// demotion would: the worker gets an error packet whose billed totals are zero, since it
        /// received nothing, and whose `cost_total` carries the dead attempt's cost, and the route
        /// is removed.
        pub fn redispatchReplayFetch(
            self: *Gateway,
            shard_index: usize,
            item: engine_mod.ReplayFetch,
        ) void {
            const key = router_mod.RouteKey{
                .worker_session_id = item.worker_session_id,
                .fetch_id = item.fetch_id,
                .body_id = item.body_id,
            };
            const route = self.router.routeForKey(key) orelse {
                // Admission recorded a route for every active fetch, and only
                // removing its worker takes the route away early, which leaves
                // nobody to tell.
                return;
            };
            std.debug.assert(route.record.shard_index == shard_index);
            // Admission records a route only for a policy id the table holds, and the table
            // never changes, so the lookup finds the entry the fetch ran under. A miss still
            // fails only this fetch.
            const resubmitted = if (self.hello.policies.lookup(route.record.policy_id)) |entry|
                self.shards.get(shard_index).engine.resubmitReplayFetch(item, .{
                    .security_cell_id = route.record.security_cell_id,
                    .policy_id = self.hello.isolation_ids[route.record.policy_id],
                }, entry.*)
            else
                error.EgressPolicyUnknown;
            resubmitted catch |err| {
                std.log.warn(
                    "egress gateway redispatch failed session={d} fetch_id={d}: {s}",
                    .{ item.worker_session_id, item.fetch_id, @errorName(err) },
                );
                if (ipc.encodeEgressFetchErrorInto(self.scratch, .{
                    .fetch_id = item.fetch_id,
                    .body_id = item.body_id,
                    .message = "egress internal error",
                    .billed_sent_total = 0,
                    .billed_received_total = 0,
                    .cost_total = item.dead_attempt_cost,
                    .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
                })) |bytes| {
                    self.queuePacket(item.worker_session_id, bytes) catch |send_err|
                        std.log.warn("failed to queue egress redispatch error fetch_id={d}: {s}", .{ item.fetch_id, @errorName(send_err) });
                } else |encode_err| {
                    std.log.warn("failed to encode egress redispatch error fetch_id={d}: {s}", .{ item.fetch_id, @errorName(encode_err) });
                }
                self.removeRoute(key);
            };
        }
    };
}
