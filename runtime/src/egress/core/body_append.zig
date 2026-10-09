//! The producer side of a fetch body, as methods `fetch_body.Body` delegates
//! to: appending bytes or chunks, fanning a root's chunks out to its open tee
//! branches, and cloning a branch. Only a root accepts chunks; a branch gets
//! them through its root. Every append checks the byte limit (`max_buf`) of
//! each view it feeds and reserves all capacity before it queues anything, so
//! a failed append leaves every view unchanged. A chunk queued in several
//! views shares its credit and its borrowed release through latches, so each
//! is released once, by the last view.

const std = @import("std");
const bindings = @import("collo_bindings");
const body_chunks = @import("body_chunks.zig");
const body_credits = @import("body_credits.zig");

pub const BorrowedChunk = body_chunks.BorrowedChunk;
pub const Credit = body_credits.Credit;

pub fn Methods(comptime Body: type) type {
    return struct {
        /// Copies `bytes` into the materialized buffer of a body the consumer
        /// builds itself, such as `Body.initComplete`. Call it only on the
        /// consumer's thread: `drainReadyForWaiter` writes the same buffer
        /// without the mutex. Fails with `error.FetchBodyNotWritable` unless
        /// the body is open, `error.MaxBufferExceeded` past the byte limit, or
        /// `error.OutOfMemory`.
        pub fn append(self: *Body, bytes: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (bytes.len == 0) {
                return;
            }
            if (self.state != .open) {
                return error.FetchBodyNotWritable;
            }
            try self.max_buf.checkBytes(bytes.len);
            try self.bytes.ensureUnusedCapacity(bytes.len);
            try self.max_buf.onBytes(bytes.len);
            self.bytes.writeAssumeCapacity(bytes);
        }

        /// Queues `bytes`, allocated with `allocator`, with `credit`; an empty
        /// slice queues a credit-only chunk. Ownership differs by outcome: on
        /// success the body owns `bytes`, queued or already freed, and the
        /// caller must not touch them; on error the caller still owns `bytes`
        /// and `credit` and must free the bytes itself. Fails with
        /// `error.FetchBodyNotWritable` when the body is not open or is a tee
        /// branch, `error.MaxBufferExceeded` past a view's byte limit,
        /// `error.FetchBodyNoActiveViews` when every view was released and no
        /// reader waits, or `error.OutOfMemory`. Returns whether a view now
        /// has a ready reader.
        pub fn appendOwnedChunk(
            self: *Body,
            allocator: std.mem.Allocator,
            bytes: []u8,
            credit: Credit,
        ) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .open) {
                return error.FetchBodyNotWritable;
            }
            if (self.tee_root != null) {
                return error.FetchBodyNotWritable;
            }

            const open_branches = countOpenBranchesLocked(self);
            if (open_branches != 0 or self.view_released) {
                return try appendOwnedChunkTeeLocked(self, allocator, bytes, credit, open_branches);
            }

            if (bytes.len == 0) {
                try self.chunks.append(allocator, .{ .bytes = bytes, .credit = credit });
                return isReadyForWaiterLocked(self);
            }
            try self.max_buf.checkBytes(bytes.len);
            try self.chunks.append(allocator, .{ .bytes = bytes, .credit = credit });
            try self.max_buf.onBytes(bytes.len);
            addQueuedChunkBytesLocked(self, bytes.len);
            return isReadyForWaiterLocked(self);
        }

        /// Queues borrowed bytes with `credit`. On success the body owns
        /// `borrowed` and fires its release once the last view drops the
        /// bytes, or right away when no view keeps them; on error the caller
        /// still owns the release and must fire it. Errors and the result are
        /// those of `appendOwnedChunk`.
        pub fn appendBorrowedChunk(
            self: *Body,
            allocator: std.mem.Allocator,
            borrowed: BorrowedChunk,
            credit: Credit,
        ) !bool {
            self.mutex.lock();
            var borrowed_to_release: ?body_chunks.BorrowedChunkRelease = null;
            defer {
                self.mutex.unlock();
                if (borrowed_to_release) |release| {
                    release.release();
                }
            }
            if (self.state != .open) {
                return error.FetchBodyNotWritable;
            }
            if (self.tee_root != null) {
                return error.FetchBodyNotWritable;
            }
            const open_branches = countOpenBranchesLocked(self);
            if (open_branches != 0 or self.view_released) {
                return try appendBorrowedChunkTeeLocked(
                    self,
                    allocator,
                    borrowed,
                    credit,
                    open_branches,
                    &borrowed_to_release,
                );
            }

            try self.max_buf.checkBytes(borrowed.bytes.len);
            try self.chunks.append(allocator, .{
                .bytes = borrowed.bytes,
                .credit = credit,
                .borrowed_release = borrowed.release,
            });
            try self.max_buf.onBytes(borrowed.bytes.len);
            addQueuedChunkBytesLocked(self, borrowed.bytes.len);
            return isReadyForWaiterLocked(self);
        }

        /// Creates a branch, named by `identity`, that starts with this view's
        /// bytes, queued chunks and state, and receives every later chunk of
        /// the root while the root stays open. A root that is no longer open
        /// yields an unlinked copy. The caller owns the branch's first
        /// reference and must detach a linked branch with `detachTeeLinks`
        /// before releasing it. Fails with `error.FetchBodyAlreadyUsed` once
        /// this view was read or released, `error.FetchBodyNotReadable` for a
        /// failed body without a message, or `error.OutOfMemory`; the source
        /// then stays drainable with every credit and borrow intact.
        pub fn cloneBranch(
            self: *Body,
            allocator: std.mem.Allocator,
            identity: bindings.FetchBodyIdentity,
        ) !*Body {
            const root = self.tee_root orelse self;
            root.mutex.lock();
            defer root.mutex.unlock();
            if (self != root) {
                self.mutex.lock();
            }
            defer if (self != root) {
                self.mutex.unlock();
            };

            if (self.view_released or self.consumed or self.waiter != null or self.pull_waiter != null) {
                return error.FetchBodyAlreadyUsed;
            }
            if (self.state == .failed and self.error_message == null) {
                return error.FetchBodyNotReadable;
            }

            const branch = try allocator.create(Body);
            var branch_initialized = false;
            errdefer {
                if (branch_initialized) {
                    branch.deinitAfterQueuedResourcesReleased(allocator);
                }
                allocator.destroy(branch);
            }
            branch.* = Body.initOpen(allocator, identity, self.max_buf.budget.limit);
            branch_initialized = true;

            try branch.bytes.write(self.bytes.slice());
            if (self.bytes.slice().len != 0) {
                try branch.max_buf.onBytes(self.bytes.slice().len);
            }

            // Entries below `chunks_head` were already popped and freed; only
            // the live suffix is copied.
            const source_chunks = self.chunks.items[self.chunks_head..];
            try branch.chunks.ensureTotalCapacity(allocator, source_chunks.len);
            var initialized_chunks: usize = 0;
            errdefer {
                for (branch.chunks.items[0..initialized_chunks]) |*chunk| {
                    _ = chunk.takeCredit(allocator);
                    chunk.deinit(allocator);
                }
                branch.chunks.clearRetainingCapacity();
                branch.queued_chunk_bytes.store(0, .monotonic);
            }
            for (source_chunks) |*source_chunk| {
                var copied: []u8 = &.{};
                var copied_needs_free = false;
                errdefer if (copied_needs_free) {
                    allocator.free(copied);
                };
                var borrowed_latch: ?*body_chunks.BorrowedChunkReleaseLatch = null;
                var borrowed_latch_added = false;
                errdefer if (borrowed_latch_added) {
                    if (borrowed_latch.?.releaseBranch(allocator)) |release| {
                        release.release();
                    }
                };
                if (source_chunk.hasBorrowedRelease()) {
                    borrowed_latch = try body_chunks.shareChunkBorrowedRelease(allocator, source_chunk);
                    borrowed_latch_added = true;
                } else {
                    copied = try allocator.dupe(u8, source_chunk.bytes);
                    copied_needs_free = true;
                }
                const latch = try body_credits.shareChunkCredit(allocator, source_chunk);
                const branch_bytes = if (borrowed_latch != null) source_chunk.bytes else copied;
                branch.chunks.appendAssumeCapacity(.{
                    .bytes = branch_bytes,
                    .credit = .none,
                    .latch = latch,
                    .borrowed_latch = borrowed_latch,
                });
                initialized_chunks += 1;
                borrowed_latch_added = false;
                copied_needs_free = false;
                if (branch_bytes.len != 0) {
                    try branch.max_buf.onBytes(branch_bytes.len);
                    addQueuedChunkBytesLocked(branch, branch_bytes.len);
                }
            }

            if (self.error_message) |message| {
                branch.error_message = try allocator.dupe(u8, message);
            }
            if (self.abort_reason) |reason| {
                branch.abort_reason = try reason.retain();
            }
            branch.state = self.state;
            branch.canceled.store(self.canceled.load(.monotonic), .monotonic);

            if (root.state == .open) {
                try root.tee_branches.append(allocator, branch);
                branch.tee_root = root;
                // The branch keeps the root alive, and the root keeps the
                // branch alive, until `detachTeeLinks` severs the link.
                root.retain();
                branch.retain();
            }

            branch_initialized = false;
            return branch;
        }

        fn appendOwnedChunkTeeLocked(
            self: *Body,
            allocator: std.mem.Allocator,
            bytes: []u8,
            credit: Credit,
            open_branches: usize,
        ) !bool {
            const include_root = !self.view_released or self.waiter != null or self.pull_waiter != null;
            if (!include_root and open_branches == 0) {
                return error.FetchBodyNoActiveViews;
            }

            var branch_targets: std.ArrayListUnmanaged(*Body) = .empty;
            defer branch_targets.deinit(allocator);
            var branch_bytes: std.ArrayListUnmanaged([]u8) = .empty;
            defer branch_bytes.deinit(allocator);
            errdefer {
                for (branch_bytes.items) |owned| {
                    allocator.free(owned);
                }
            }

            try self.chunks.ensureUnusedCapacity(allocator, 1);
            if (bytes.len != 0) {
                try self.max_buf.checkBytes(bytes.len);
                for (self.tee_branches.items) |branch| {
                    const branch_open = blk: {
                        branch.mutex.lock();
                        defer branch.mutex.unlock();
                        const open = branch.state == .open and !branch.view_released;
                        if (open) {
                            try branch.max_buf.checkBytes(bytes.len);
                            try branch.chunks.ensureUnusedCapacity(allocator, 1);
                        }
                        break :blk open;
                    };
                    if (!branch_open) {
                        continue;
                    }
                    try branch_targets.append(allocator, branch);
                    const owned = try allocator.dupe(u8, bytes);
                    var owned_moved = false;
                    errdefer if (!owned_moved) allocator.free(owned);
                    try branch_bytes.append(allocator, owned);
                    owned_moved = true;
                }
            } else {
                for (self.tee_branches.items) |branch| {
                    const branch_open = blk: {
                        branch.mutex.lock();
                        defer branch.mutex.unlock();
                        const open = branch.state == .open and !branch.view_released;
                        if (open) {
                            try branch.chunks.ensureUnusedCapacity(allocator, 1);
                        }
                        break :blk open;
                    };
                    if (!branch_open) {
                        continue;
                    }
                    try branch_targets.append(allocator, branch);
                    try branch_bytes.append(allocator, &.{});
                }
            }

            const branch_count = branch_bytes.items.len;
            const latch_count = branch_count + @as(usize, if (include_root) 1 else 0);
            if (latch_count == 0) {
                return error.FetchBodyNoActiveViews;
            }
            const latch = switch (credit) {
                .none => null,
                else => blk: {
                    const created = try allocator.create(body_credits.Latch);
                    created.* = body_credits.Latch.init(latch_count, credit);
                    break :blk created;
                },
            };

            if (include_root) {
                self.chunks.appendAssumeCapacity(.{
                    .bytes = bytes,
                    .credit = if (latch == null) credit else .none,
                    .latch = latch,
                });
                if (bytes.len != 0) {
                    self.max_buf.onBytesAssumeChecked(bytes.len);
                    addQueuedChunkBytesLocked(self, bytes.len);
                }
            } else if (bytes.len != 0) {
                allocator.free(bytes);
            }

            var any_ready = include_root and isReadyForWaiterLocked(self);
            for (branch_targets.items, branch_bytes.items, 0..) |branch, owned, index| {
                branch.mutex.lock();
                if (branch.state != .open or branch.view_released) {
                    branch.mutex.unlock();
                    allocator.free(owned);
                    branch_bytes.items[index] = &.{};
                    if (latch) |shared| {
                        if (shared.releaseBranch(allocator)) |released_credit| {
                            self.chunks.appendAssumeCapacity(.{
                                .bytes = &.{},
                                .credit = released_credit,
                            });
                        }
                    }
                    continue;
                }
                branch_bytes.items[index] = &.{};
                branch.chunks.appendAssumeCapacity(.{
                    .bytes = owned,
                    .credit = .none,
                    .latch = latch,
                });
                if (owned.len != 0) {
                    branch.max_buf.onBytesAssumeChecked(owned.len);
                    addQueuedChunkBytesLocked(branch, owned.len);
                }
                any_ready = any_ready or isReadyForWaiterLocked(branch);
                branch.mutex.unlock();
            }

            return any_ready;
        }

        fn appendBorrowedChunkTeeLocked(
            self: *Body,
            allocator: std.mem.Allocator,
            borrowed: BorrowedChunk,
            credit: Credit,
            open_branches: usize,
            borrowed_to_release: *?body_chunks.BorrowedChunkRelease,
        ) !bool {
            const include_root = !self.view_released or self.waiter != null or self.pull_waiter != null;
            if (!include_root and open_branches == 0) {
                return error.FetchBodyNoActiveViews;
            }

            var branch_targets: std.ArrayListUnmanaged(*Body) = .empty;
            defer branch_targets.deinit(allocator);

            try self.chunks.ensureUnusedCapacity(allocator, 1);
            try self.max_buf.checkBytes(borrowed.bytes.len);
            for (self.tee_branches.items) |branch| {
                const branch_open = blk: {
                    branch.mutex.lock();
                    defer branch.mutex.unlock();
                    const open = branch.state == .open and !branch.view_released;
                    if (open) {
                        try branch.max_buf.checkBytes(borrowed.bytes.len);
                        try branch.chunks.ensureUnusedCapacity(allocator, 1);
                    }
                    break :blk open;
                };
                if (!branch_open) {
                    continue;
                }
                try branch_targets.append(allocator, branch);
            }

            const branch_count = branch_targets.items.len;
            const latch_count = branch_count + @as(usize, if (include_root) 1 else 0);
            if (latch_count == 0) {
                return error.FetchBodyNoActiveViews;
            }
            const credit_latch = switch (credit) {
                .none => null,
                else => blk: {
                    const created = try allocator.create(body_credits.Latch);
                    errdefer allocator.destroy(created);
                    created.* = body_credits.Latch.init(latch_count, credit);
                    break :blk created;
                },
            };
            var credit_latch_owned = true;
            errdefer if (credit_latch_owned) {
                if (credit_latch) |latch| {
                    allocator.destroy(latch);
                }
            };

            const borrowed_latch = if (latch_count == 1) null else blk: {
                const created = try allocator.create(body_chunks.BorrowedChunkReleaseLatch);
                errdefer allocator.destroy(created);
                created.* = body_chunks.BorrowedChunkReleaseLatch.init(latch_count, borrowed.release);
                break :blk created;
            };
            var borrowed_latch_owned = true;
            errdefer if (borrowed_latch_owned) {
                if (borrowed_latch) |latch| {
                    allocator.destroy(latch);
                }
            };

            credit_latch_owned = false;
            borrowed_latch_owned = false;

            if (include_root) {
                self.chunks.appendAssumeCapacity(.{
                    .bytes = borrowed.bytes,
                    .credit = if (credit_latch == null) credit else .none,
                    .latch = credit_latch,
                    .borrowed_release = if (borrowed_latch == null) borrowed.release else null,
                    .borrowed_latch = borrowed_latch,
                });
                if (borrowed.bytes.len != 0) {
                    self.max_buf.onBytesAssumeChecked(borrowed.bytes.len);
                    addQueuedChunkBytesLocked(self, borrowed.bytes.len);
                }
            }

            var any_ready = include_root and isReadyForWaiterLocked(self);
            for (branch_targets.items) |branch| {
                branch.mutex.lock();
                if (branch.state != .open or branch.view_released) {
                    branch.mutex.unlock();
                    if (credit_latch) |shared| {
                        if (shared.releaseBranch(allocator)) |released_credit| {
                            self.chunks.appendAssumeCapacity(.{
                                .bytes = &.{},
                                .credit = released_credit,
                            });
                        }
                    }
                    if (borrowed_latch) |shared| {
                        if (shared.releaseBranch(allocator)) |release| {
                            borrowed_to_release.* = release;
                        }
                    } else if (!include_root) {
                        borrowed_to_release.* = borrowed.release;
                    }
                    continue;
                }
                branch.chunks.appendAssumeCapacity(.{
                    .bytes = borrowed.bytes,
                    .credit = .none,
                    .latch = credit_latch,
                    .borrowed_latch = borrowed_latch,
                    .borrowed_release = if (!include_root and borrowed_latch == null)
                        borrowed.release
                    else
                        null,
                });
                if (borrowed.bytes.len != 0) {
                    branch.max_buf.onBytesAssumeChecked(borrowed.bytes.len);
                    addQueuedChunkBytesLocked(branch, borrowed.bytes.len);
                }
                any_ready = any_ready or isReadyForWaiterLocked(branch);
                branch.mutex.unlock();
            }

            return any_ready;
        }

        fn countOpenBranchesLocked(self: *Body) usize {
            var count: usize = 0;
            for (self.tee_branches.items) |branch| {
                branch.mutex.lock();
                if (branch.state == .open and !branch.view_released) {
                    count += 1;
                }
                branch.mutex.unlock();
            }
            return count;
        }

        fn addQueuedChunkBytesLocked(self: *Body, amount: usize) void {
            if (amount == 0) {
                return;
            }
            const queued = self.queued_chunk_bytes.load(.monotonic);
            std.debug.assert(amount <= std.math.maxInt(usize) - queued);
            self.queued_chunk_bytes.store(queued + amount, .monotonic);
        }

        fn isReadyForWaiterLocked(self: *const Body) bool {
            return isReadyForConsumeLocked(self) or isReadyForPullLocked(self);
        }

        fn isReadyForConsumeLocked(self: *const Body) bool {
            if (self.waiter == null) {
                return false;
            }
            return switch (self.state) {
                .open => self.chunks.items.len != 0,
                .complete, .failed => true,
            };
        }

        fn isReadyForPullLocked(self: *const Body) bool {
            if (self.pull_waiter == null) {
                return false;
            }
            return switch (self.state) {
                .open => self.chunks.items.len != 0,
                .complete, .failed => true,
            };
        }
    };
}
