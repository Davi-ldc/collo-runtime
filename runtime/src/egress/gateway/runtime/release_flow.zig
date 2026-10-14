//! The one place the gateway drains a session's body-pool releases, on its loop thread. For each
//! extent the worker returned, it takes the session's ledger entry and hands the flow-control
//! credit the extent carried back to the engine of the shard that published it, whether or not
//! the fetch has ended since; the engine drops it when the shard restarted after the extent was
//! published (`engine.zig:Engine.releaseCredit`). When the drain freed anything, the session's
//! fetches are pumped again before the next wait, so a body drain that stopped for pool room
//! resumes, and when the pool is then at most a quarter full, the freed blocks' pages go back to
//! the kernel.
//!
//! No other code may advance the release cursor: a release drained anywhere else would free its
//! pool space and lose its credit, and the stream waiting for that credit would stall. A drain
//! that fails, or a release the ledger cannot match, marks the session for drop.

const std = @import("std");
const ipc = @import("collo_ipc");

const credit_batch = @import("../credit_batch.zig");
const sessions_mod = @import("../sessions.zig");
const Gateway = @import("root.zig").Gateway;
const session_flow = @import("session_flow.zig");

const Session = sessions_mod.Session;

/// Drains every extent `session` has released.
pub fn drainReleases(gateway: *Gateway, session: *Session) void {
    var observer = ReleaseObserver{ .gateway = gateway, .session = session };
    const freed = session.endpoint.body_pool.drainReleasedChunksObserved(
        &observer,
        ReleaseObserver.observe,
    ) catch |err| {
        observer.credits.flush(&gateway.shards);
        session_flow.markForDrop(gateway, session, @errorName(err));
        return;
    };
    observer.credits.flush(&gateway.shards);
    if (observer.ledger_missed) {
        session_flow.markForDrop(gateway, session, "body-pool release without a ledger entry");
        return;
    }
    if (freed == 0)
        return;
    session_flow.noteRoomGained(gateway, session);
    // Pages go back to the kernel only at low water: punching holes under steady load would fault
    // the same pages in again on their next use. The observer collected the freed ranges, and
    // `usage` is read after the drain.
    const usage = session.endpoint.body_pool.usage() catch return;
    if (usage.used * 4 <= usage.capacity) {
        for (observer.punch_ranges[0..observer.punch_count]) |range| {
            session.endpoint.body_pool.punchFreeRange(range.block_index, range.block_count) catch |err| {
                std.log.debug("egress gateway pool punch failed session={d}: {s}", .{ session.id, @errorName(err) });
                break;
            };
        }
    }
}

const PunchRange = struct { block_index: usize, block_count: usize };

const ReleaseObserver = struct {
    gateway: *Gateway,
    session: *Session,
    /// A worker that consumed a streamed body returns its extents in order, so consecutive
    /// extents usually share shard and stream, and merging their credits costs one engine message
    /// per run instead of per extent.
    credits: credit_batch.CreditBatch = .{},
    /// One entry per extent the drain freed; the pool's release queue holds at most one per slot.
    punch_ranges: [ipc.egress_shared.body_pool_slot_count]PunchRange = undefined,
    punch_count: usize = 0,
    ledger_missed: bool = false,

    fn observe(self: *ReleaseObserver, extent: ipc.egress_shared.BodyPoolView.ReleasedExtent) void {
        self.punch_ranges[self.punch_count] = .{
            .block_index = extent.block_index,
            .block_count = extent.block_count,
        };
        self.punch_count += 1;
        const entry = self.session.extents.take(self.gateway.allocator, extent) orelse {
            // The worker writes the release queue, so an unmatched release is the worker's doing,
            // which costs its session, and nothing the operator must act on.
            std.log.warn("egress gateway body-pool release without a ledger entry session={d} handle={d}", .{
                self.session.id,
                extent.handle,
            });
            self.ledger_missed = true;
            return;
        };
        self.credits.add(&self.gateway.shards, entry.shard_index, entry.run, entry.credit);
    }
};
