//! The chunks a worker's fetch body queues and the leases its pull drains
//! hand out. A chunk owns bytes from the worker's allocator, a decoded
//! chunk's, or borrows a gateway body-pool extent and carries the release
//! that returns it. That release is the worker's flow-control signal to the
//! gateway, so it fires exactly once, after the last view that holds the
//! extent dropped it. Tee views that queue one extent share its release
//! through a `SharedRelease`, which counts them. Everything here runs on the
//! worker's VM thread.

const std = @import("std");

/// Returns a borrowed extent to the gateway; `handle` and `len` name it.
/// `release` must be called exactly once.
pub const BorrowedRelease = struct {
    context: ?*anyopaque,
    handle: u64,
    len: usize,
    release_fn: *const fn (?*anyopaque, u64, usize) void,

    pub fn release(self: BorrowedRelease) void {
        self.release_fn(self.context, self.handle, self.len);
    }
};

pub const BorrowedChunk = struct {
    bytes: []u8,
    release: BorrowedRelease,
};

/// One borrowed release held by `holders` views. The `drop` that takes the
/// count to zero frees the counter and returns the release to fire.
pub const SharedRelease = struct {
    holders: usize,
    release: BorrowedRelease,

    /// Adds a holder; fails with `error.Overflow` when the count would wrap.
    pub fn add(self: *SharedRelease) !void {
        std.debug.assert(self.holders != 0);
        self.holders = try std.math.add(usize, self.holders, 1);
    }

    pub fn drop(self: *SharedRelease, allocator: std.mem.Allocator) ?BorrowedRelease {
        std.debug.assert(self.holders != 0);
        self.holders -= 1;
        if (self.holders != 0)
            return null;
        const release = self.release;
        allocator.destroy(self);
        return release;
    }
};

/// Where a chunk's bytes come from: the worker's allocator, one extent's
/// release, or a release shared with other views.
pub const Storage = union(enum) {
    owned,
    borrowed: BorrowedRelease,
    shared: *SharedRelease,
};

/// The bytes a pull drain hands its consumer, which owns them until
/// `deinit`: owned bytes are freed, a borrowed extent is released. Pass
/// `deinit` the allocator of the body the bytes came from.
pub const ByteLease = struct {
    bytes: []u8 = &.{},
    storage: Storage = .owned,
    present: bool = false,

    pub const empty: ByteLease = .{};

    pub fn isPresent(self: *const ByteLease) bool {
        return self.present;
    }

    pub fn isBorrowed(self: *const ByteLease) bool {
        return self.storage != .owned;
    }

    pub fn deinit(self: *ByteLease, allocator: std.mem.Allocator) void {
        dropStorage(allocator, self.bytes, self.storage);
        self.* = .empty;
    }

    pub fn take(self: *ByteLease) ByteLease {
        const taken = self.*;
        self.* = .empty;
        return taken;
    }
};

pub const Chunk = struct {
    bytes: []u8,
    storage: Storage = .owned,

    /// Frees owned bytes or drops this view's hold on the extent.
    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        dropStorage(allocator, self.bytes, self.storage);
        self.* = undefined;
    }

    /// Moves the bytes and their ownership into a lease.
    pub fn toLease(self: Chunk) ByteLease {
        return .{ .bytes = self.bytes, .storage = self.storage, .present = true };
    }

    /// A copy of this chunk for one more view: owned bytes are duplicated,
    /// a borrowed extent's release becomes shared, and this chunk then holds
    /// the shared release too. Fails with `error.OutOfMemory` or
    /// `error.Overflow`, leaving this chunk as it was.
    pub fn share(self: *Chunk, allocator: std.mem.Allocator) !Chunk {
        switch (self.storage) {
            .owned => return .{ .bytes = try allocator.dupe(u8, self.bytes) },
            .borrowed => |release| {
                const shared = try allocator.create(SharedRelease);
                shared.* = .{ .holders = 2, .release = release };
                self.storage = .{ .shared = shared };
                return .{ .bytes = self.bytes, .storage = .{ .shared = shared } };
            },
            .shared => |shared| {
                try shared.add();
                return .{ .bytes = self.bytes, .storage = .{ .shared = shared } };
            },
        }
    }
};

fn dropStorage(allocator: std.mem.Allocator, bytes: []u8, storage: Storage) void {
    switch (storage) {
        .owned => allocator.free(bytes),
        .borrowed => |release| release.release(),
        .shared => |shared| if (shared.drop(allocator)) |release| release.release(),
    }
}
