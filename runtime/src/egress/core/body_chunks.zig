//! The chunks a fetch body queues and the leases a drain hands out. A chunk's
//! bytes are owned by the body's allocator or borrowed from memory the body
//! does not own: in the worker, a gateway body-pool extent. A borrowed chunk
//! carries the callback that returns its extent, and that callback must fire
//! exactly once, after the last view has dropped the bytes. When tee views
//! share a borrowed chunk, `BorrowedChunkReleaseLatch` counts them the way
//! `body_credits.Latch` counts a shared credit.

const std = @import("std");
const body_credits = @import("body_credits.zig");

pub const Credit = body_credits.Credit;
pub const CreditLatch = body_credits.Latch;

/// Returns borrowed bytes to their owner; `seq` and `len` name the extent to
/// it. `release` must be called exactly once.
pub const BorrowedChunkRelease = struct {
    context: ?*anyopaque,
    seq: u64,
    len: usize,
    release_fn: *const fn (?*anyopaque, u64, usize) void,

    pub fn release(self: BorrowedChunkRelease) void {
        self.release_fn(self.context, self.seq, self.len);
    }
};

pub const BorrowedChunk = struct {
    bytes: []u8,
    release: BorrowedChunkRelease,
};

/// One borrowed release shared by `remaining` tee views. The
/// `releaseBranch` that drops the count to zero returns the release and
/// frees the latch; `addBranch` fails with `error.Overflow` when the count
/// would wrap.
pub const BorrowedChunkReleaseLatch = struct {
    remaining: std.atomic.Value(usize),
    release: BorrowedChunkRelease,

    pub fn init(remaining: usize, release: BorrowedChunkRelease) BorrowedChunkReleaseLatch {
        std.debug.assert(remaining > 0);
        return .{
            .remaining = std.atomic.Value(usize).init(remaining),
            .release = release,
        };
    }

    pub fn addBranch(self: *BorrowedChunkReleaseLatch) !void {
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

    pub fn releaseBranch(
        self: *BorrowedChunkReleaseLatch,
        allocator: std.mem.Allocator,
    ) ?BorrowedChunkRelease {
        const previous = self.remaining.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1)
            return null;
        const release = self.release;
        allocator.destroy(self);
        return release;
    }
};

/// The bytes a pull drain hands its consumer: owned, or borrowed with a
/// release that fires on `deinit`. Pass `deinit` the allocator the body's
/// chunks and latches came from.
pub const ByteLease = union(enum) {
    empty,
    owned: []u8,
    borrowed: Borrowed,

    pub const Borrowed = struct {
        bytes: []u8,
        release: BorrowedStorage,
    };

    pub const BorrowedStorage = union(enum) {
        direct: BorrowedChunkRelease,
        latched: *BorrowedChunkReleaseLatch,
    };

    pub fn bytes(self: *const ByteLease) []const u8 {
        return switch (self.*) {
            .empty => &.{},
            .owned => |owned| owned,
            .borrowed => |borrowed| borrowed.bytes,
        };
    }

    pub fn len(self: *const ByteLease) usize {
        return self.bytes().len;
    }

    pub fn isEmpty(self: *const ByteLease) bool {
        return switch (self.*) {
            .empty => true,
            .owned => |owned| owned.len == 0,
            .borrowed => |borrowed| borrowed.bytes.len == 0,
        };
    }

    pub fn isPresent(self: *const ByteLease) bool {
        return switch (self.*) {
            .empty => false,
            .owned, .borrowed => true,
        };
    }

    pub fn isBorrowed(self: *const ByteLease) bool {
        return switch (self.*) {
            .borrowed => true,
            .empty, .owned => false,
        };
    }

    pub fn deinit(self: *ByteLease, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty => {},
            .owned => |owned| allocator.free(owned),
            .borrowed => |borrowed| switch (borrowed.release) {
                .direct => |release| release.release(),
                .latched => |latch| {
                    if (latch.releaseBranch(allocator)) |release|
                        release.release();
                },
            },
        }
        self.* = .empty;
    }

    pub fn take(self: *ByteLease) ByteLease {
        const taken = self.*;
        self.* = .empty;
        return taken;
    }
};

/// One queued chunk. Its credit is either direct in `credit` or shared
/// through `latch`, never both; a borrowed chunk holds either
/// `borrowed_release` or `borrowed_latch`, and an owned one neither.
pub const Chunk = struct {
    bytes: []u8,
    credit: Credit,
    latch: ?*CreditLatch = null,
    borrowed_release: ?BorrowedChunkRelease = null,
    borrowed_latch: ?*BorrowedChunkReleaseLatch = null,

    /// Takes the chunk's credit: the direct one, or the shared one when this
    /// chunk is the latch's last holder. Returns null when there is nothing to
    /// release, including for a latch holder that is not the last; that
    /// holder still gives up its count.
    pub fn takeCredit(self: *Chunk, allocator: std.mem.Allocator) ?Credit {
        if (self.latch) |latch| {
            self.latch = null;
            self.credit = .none;
            return latch.releaseBranch(allocator);
        }
        const credit = self.credit;
        self.credit = .none;
        return switch (credit) {
            .none => null,
            else => credit,
        };
    }

    /// Whether `takeCredit` may yield a credit: the chunk holds a latch or a
    /// direct credit. It reads only this chunk's fields, which its body's
    /// mutex guards, and never the shared latch's count, which a tee view
    /// under another mutex can change between a count and the take. A caller
    /// that sizes slots with it fills a latch's slot with `.none` when the
    /// take yields nothing, and every credit consumer skips `.none`.
    pub fn hasCreditSource(self: *const Chunk) bool {
        return self.latch != null or !self.credit.isNone();
    }

    /// Frees owned bytes or fires the borrowed release. The credit must have
    /// been taken first.
    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        std.debug.assert(self.credit.isNone());
        std.debug.assert(self.latch == null);
        if (self.hasBorrowedRelease()) {
            self.releaseBorrowed(allocator);
        } else {
            allocator.free(self.bytes);
        }
        self.* = undefined;
    }

    pub fn hasBorrowedRelease(self: *const Chunk) bool {
        return self.borrowed_release != null or self.borrowed_latch != null;
    }

    /// Takes the borrow marker and clears the bytes. Returns the release to
    /// fire, or null for an owned chunk or while another tee view still holds
    /// the borrow.
    pub fn takeBorrowedRelease(self: *Chunk, allocator: std.mem.Allocator) ?BorrowedChunkRelease {
        // Borrowed bytes belong to shared memory, never to the allocator.
        // They must be dropped together with the borrow marker: a latched take
        // returns null while other tee branches still hold the borrow, and a
        // later deinit would otherwise treat the shared bytes as
        // allocator-owned and free them.
        if (self.borrowed_release) |borrowed_release| {
            self.borrowed_release = null;
            self.bytes = &.{};
            return borrowed_release;
        }
        if (self.borrowed_latch) |borrowed_latch| {
            self.borrowed_latch = null;
            self.bytes = &.{};
            return borrowed_latch.releaseBranch(allocator);
        }
        return null;
    }

    /// Moves the bytes and their ownership into a lease, leaving the chunk
    /// empty so `deinit` frees nothing. The credit is taken separately.
    pub fn takeByteLease(self: *Chunk) ByteLease {
        const bytes = self.bytes;
        self.bytes = &.{};

        if (self.borrowed_release) |release| {
            self.borrowed_release = null;
            return .{ .borrowed = .{
                .bytes = bytes,
                .release = .{ .direct = release },
            } };
        }
        if (self.borrowed_latch) |latch| {
            self.borrowed_latch = null;
            return .{ .borrowed = .{
                .bytes = bytes,
                .release = .{ .latched = latch },
            } };
        }
        return .{ .owned = bytes };
    }

    fn releaseBorrowed(self: *Chunk, allocator: std.mem.Allocator) void {
        if (self.takeBorrowedRelease(allocator)) |borrowed_release|
            borrowed_release.release();
    }
};

/// Shares `chunk`'s borrowed release with one more view and returns the latch
/// that view's copy must hold, or null for an owned chunk. A direct release
/// moves into a new latch counting two holders. Fails with
/// `error.OutOfMemory` or `error.Overflow`, leaving the chunk as it was.
pub fn shareChunkBorrowedRelease(allocator: std.mem.Allocator, chunk: anytype) !?*BorrowedChunkReleaseLatch {
    if (chunk.borrowed_latch) |latch| {
        try latch.addBranch();
        return latch;
    }
    const release = chunk.borrowed_release orelse return null;
    const latch = try allocator.create(BorrowedChunkReleaseLatch);
    latch.* = BorrowedChunkReleaseLatch.init(2, release);
    chunk.borrowed_release = null;
    chunk.borrowed_latch = latch;
    return latch;
}
