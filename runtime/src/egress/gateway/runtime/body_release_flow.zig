//! The one place the gateway drains a worker's body-pool releases, as a comptime mixin over the
//! gateway run on its loop thread. For each extent the worker returned, it consumes the slot
//! ledger entry, hands the extent's flow-control credit back to the engine that owns the fetch,
//! counts the extent off the fetch, and removes the fetch's route once the engine no longer holds
//! the body. Then it wakes the worker's shards, so a fetch paused for pool space resumes.
//!
//! No other code may advance the release cursor: a release drained anywhere else would free its
//! pool space and lose its credit, and the stream waiting for that credit would stall. A release
//! the slot ledger cannot match drops the worker's session.

const std = @import("std");
const ipc = @import("collo_ipc");

const egress = @import("collo_egress_client");
const router_mod = @import("../router.zig");
const sessions = @import("../sessions.zig");

const body_credit = egress.body_credit;

pub fn Methods(comptime Gateway: type) type {
    return struct {
        /// Drains every extent `worker` has released. A drain that fails marks the worker for
        /// drop. When the drain freed anything, the worker's shards are woken, and when the pool
        /// is then at most a quarter full, the freed blocks' pages go back to the kernel.
        pub fn drainWorkerPoolReleases(self: *Gateway, worker: *sessions.Worker) void {
            var observer = ReleaseObserver(Gateway){ .gateway = self, .worker = worker };
            const freed = worker.endpoint.body_pool.drainReleasedChunksObserved(
                &observer,
                ReleaseObserver(Gateway).observe,
            ) catch |err| {
                observer.flushPendingCreditAck();
                std.log.warn("egress gateway body pool release drain failed session={d}: {s}", .{ worker.session_id, @errorName(err) });
                self.markWorkerForDrop(worker.session_id);
                return;
            };
            observer.flushPendingCreditAck();
            if (freed == 0)
                return;
            self.wakeShardsForWorkerPressureChange(worker.session_id);
            // Pages go back to the kernel only at low water: punching holes under
            // steady load would fault the same pages in again on their next use.
            // The observer collected the freed ranges, and `usage` is read after
            // the drain.
            const usage = worker.endpoint.body_pool.usage() catch return;
            if (usage.used * 4 <= usage.capacity) {
                for (observer.punch_ranges[0..observer.punch_count]) |range| {
                    worker.endpoint.body_pool.punchFreeRange(range.block_index, range.block_count) catch |err| {
                        std.log.debug("egress gateway pool punch failed session={d}: {s}", .{ worker.session_id, @errorName(err) });
                        break;
                    };
                }
            }
        }
    };
}

const PunchRange = struct { block_index: usize, block_count: usize };

/// One credit acknowledgement on its way to an engine, possibly merged from several extents.
/// Public only so tests can pin `tryMerge`, whose rule must stay the one
/// `active_fetch.CreditBatch.add` applies.
pub const PendingCreditAck = struct {
    shard_index: usize,
    fetch_id: u64,
    credit: body_credit.Handle,

    /// Folds `credit` into this acknowledgement when both go to the same shard and the same
    /// stream or source, and returns whether it did.
    pub fn tryMerge(self: *PendingCreditAck, shard_index: usize, credit: body_credit.Handle) bool {
        if (self.shard_index != shard_index)
            return false;
        switch (self.credit) {
            .h2_data => |*mine| switch (credit) {
                .h2_data => |other| {
                    // The update_stream_window flags must match as well, for the
                    // reason `active_fetch.CreditBatch.add` gives.
                    if (mine.source_id != other.source_id or
                        mine.stream_id != other.stream_id or
                        mine.update_stream_window != other.update_stream_window)
                        return false;
                    mine.encoded_bytes +|= other.encoded_bytes;
                    return true;
                },
                else => return false,
            },
            .h1_resume => |mine| switch (credit) {
                // Same source: one resume covers the whole run.
                .h1_resume => |other| return mine.source_id == other.source_id,
                else => return false,
            },
            .none => return false,
        }
    }
};

fn ReleaseObserver(comptime Gateway: type) type {
    return struct {
        gateway: *Gateway,
        worker: *sessions.Worker,
        punch_ranges: [ipc.egress_shared.body_pool_slot_count]PunchRange = undefined,
        punch_count: usize = 0,
        /// The acknowledgement being built from a run of extents. A worker that consumed a
        /// streamed body returns its extents in order, so consecutive extents usually share
        /// shard and stream, and merging them costs one engine message, and one wake of the
        /// engine's owner thread, per run instead of per extent. Only the acknowledgement is
        /// merged: `observe` still counts, retires and unroutes per extent. Sending the
        /// acknowledgement after that bookkeeping is safe because the engine ignores one for a
        /// stream that has finished or been reset, and the merged bytes are the sum of credits
        /// each recorded against the stream once.
        pending_ack: ?PendingCreditAck = null,

        fn stageCreditAck(self: *@This(), shard_index: usize, fetch_id: u64, credit: body_credit.Handle) void {
            if (credit.isNone())
                return;
            if (self.pending_ack) |*pending| {
                if (pending.tryMerge(shard_index, credit))
                    return;
                self.flushPendingCreditAck();
            }
            self.pending_ack = .{
                .shard_index = shard_index,
                .fetch_id = fetch_id,
                .credit = credit,
            };
        }

        fn flushPendingCreditAck(self: *@This()) void {
            const pending = self.pending_ack orelse return;
            self.pending_ack = null;
            const shard = self.gateway.shards.get(pending.shard_index);
            shard.engine.releaseExtentCreditOnly(pending.fetch_id, pending.credit);
        }

        fn observe(self: *@This(), extent: ipc.egress_shared.BodyPoolView.ReleasedExtent) void {
            self.punch_ranges[self.punch_count] = .{
                .block_index = @intCast(extent.block_index),
                .block_count = @intCast(extent.block_count),
            };
            self.punch_count += 1;
            const entry = switch (self.worker.takeSlotCredit(extent)) {
                .ok => |slot| slot,
                .empty => {
                    std.log.err("egress gateway slot release without ledger entry session={d} handle={d}", .{
                        self.worker.session_id,
                        extent.handle,
                    });
                    self.gateway.markWorkerForDrop(self.worker.session_id);
                    return;
                },
                .mismatch => {
                    std.log.err("egress gateway slot ledger mismatch session={d} handle={d}", .{
                        self.worker.session_id,
                        extent.handle,
                    });
                    self.gateway.markWorkerForDrop(self.worker.session_id);
                    return;
                },
            };
            if (entry.credit.isNone() and entry.fetch_id == 0)
                return;
            const key = router_mod.RouteKey{
                .worker_session_id = self.worker.session_id,
                .fetch_id = entry.fetch_id,
                .body_id = entry.body_id,
            };
            const route = self.gateway.router.routeForKey(key) orelse {
                // The fetch already failed or was canceled and its route is
                // gone. Canceling its stream restored the flow windows, so the
                // credit has nothing left to refill.
                return;
            };
            const shard = self.gateway.shards.get(route.record.shard_index);
            self.stageCreditAck(route.record.shard_index, entry.fetch_id, entry.credit);
            shard.engine.noteExtentReleasedAndMaybeRetire(
                self.worker.session_id,
                entry.fetch_id,
                entry.body_id,
            );
            if (!shard.engine.hasActiveBody(self.worker.session_id, entry.fetch_id, entry.body_id))
                self.gateway.removeRoute(key);
        }
    };
}
