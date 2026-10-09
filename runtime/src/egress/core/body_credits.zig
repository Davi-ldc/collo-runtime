//! Shares one chunk's flow-control credit among the tee views that queue the
//! same chunk. The credit is released exactly once, by the view that drops
//! the chunk last, so the engine never reopens a window for bytes a view
//! still holds. The count is atomic because each view's chunk sits under its
//! own body's mutex, never a shared one.

const std = @import("std");
const body_credit = @import("body_credit.zig");

pub const Credit = body_credit.Handle;

/// A credit held by `remaining` views. The `releaseBranch` that drops the
/// count to zero receives the credit and frees the latch.
pub const Latch = struct {
    remaining: std.atomic.Value(usize),
    credit: Credit,

    pub fn init(remaining: usize, credit: Credit) Latch {
        std.debug.assert(remaining > 0);
        return .{
            .remaining = std.atomic.Value(usize).init(remaining),
            .credit = credit,
        };
    }

    /// Adds one holder. The caller must itself be a holder, since a latch at
    /// zero is already freed. Fails with `error.Overflow` when the count
    /// would wrap.
    pub fn addBranch(self: *Latch) !void {
        var current = self.remaining.load(.acquire);
        while (true) {
            std.debug.assert(current != 0);
            const next = try std.math.add(usize, current, 1);
            const result = self.remaining.cmpxchgWeak(
                current,
                next,
                .acq_rel,
                .acquire,
            );
            if (result == null)
                return;
            current = result.?;
        }
    }

    /// Drops one holder. The last holder gets the credit, after the latch is
    /// destroyed with `allocator`, which must be the one that created it;
    /// every earlier holder gets null.
    pub fn releaseBranch(self: *Latch, allocator: std.mem.Allocator) ?Credit {
        const previous = self.remaining.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1)
            return null;
        const credit = self.credit;
        allocator.destroy(self);
        return credit;
    }
};

/// Shares `chunk`'s credit with one more view and returns the latch that
/// view's copy of the chunk must hold, or null when the chunk carries no
/// credit. A direct credit moves into a new latch counting two holders.
/// Fails with `error.OutOfMemory` or `error.Overflow`, leaving the chunk as
/// it was.
pub fn shareChunkCredit(allocator: std.mem.Allocator, chunk: anytype) !?*Latch {
    if (chunk.latch) |latch| {
        try latch.addBranch();
        return latch;
    }
    return switch (chunk.credit) {
        .none => null,
        else => blk: {
            const latch = try allocator.create(Latch);
            latch.* = Latch.init(2, chunk.credit);
            chunk.credit = .none;
            chunk.latch = latch;
            break :blk latch;
        },
    };
}
