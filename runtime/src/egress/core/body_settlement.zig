//! The reader side of a fetch body, as methods `fetch_body.Body` delegates
//! to. A body has one reader at a time: a waiter that materializes the whole
//! body for `text()`, `json()` and the like, which only the worker uses, or a
//! pull waiter that takes one chunk per read, which the gateway and the
//! worker both use. A drain moves chunks out of the queue and returns their
//! credits for the caller to release. It does every allocation before it
//! changes the queue, so an allocation failure leaves every chunk queued.

const std = @import("std");
const bindings = @import("collo_bindings");
const body_chunks = @import("body_chunks.zig");
const body_credits = @import("body_credits.zig");

pub const Credit = body_credits.Credit;
pub const BorrowedChunkRelease = body_chunks.BorrowedChunkRelease;
pub const Chunk = body_chunks.Chunk;

/// A pending whole-body read: its kind, the response's content type and the
/// promise to settle, if any. `deinit` frees the content type and releases
/// the promise unless `takeDeferredRaw` took it.
pub const Waiter = struct {
    kind: ReadKind,
    content_type: []u8,
    deferred: ?*bindings.RawPromiseDeferred,

    pub fn deinit(self: *Waiter, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        if (self.deferred) |raw| {
            bindings.releasePromiseDeferred(raw);
        }
        self.* = undefined;
    }

    pub fn takeDeferredRaw(self: *Waiter) !*bindings.RawPromiseDeferred {
        const raw = self.deferred orelse return error.InvalidPromiseDeferred;
        self.deferred = null;
        return raw;
    }
};

/// A pending pull read and the promise to settle, if any; the gateway pulls
/// with no promise.
pub const PullWaiter = struct {
    deferred: ?*bindings.RawPromiseDeferred,

    pub fn deinit(self: *PullWaiter) void {
        if (self.deferred) |raw| {
            bindings.releasePromiseDeferred(raw);
        }
        self.* = undefined;
    }

    pub fn takeDeferredRaw(self: *PullWaiter) !*bindings.RawPromiseDeferred {
        const raw = self.deferred orelse return error.InvalidPromiseDeferred;
        self.deferred = null;
        return raw;
    }
};

/// What a waiter drain moved out: one credit slot per drained chunk, `.none`
/// where nothing is released, and the waiter once the body is complete or
/// failed. The caller releases the credits; `deinit` frees the slots and the
/// waiter but releases no credit.
pub const Drain = struct {
    credits: []Credit = &.{},
    waiter: ?Waiter = null,
    terminal: bool = false,
    failed: bool = false,

    pub fn deinit(self: *Drain, allocator: std.mem.Allocator) void {
        allocator.free(self.credits);
        if (self.waiter) |*waiter| {
            waiter.deinit(allocator);
        }
        self.* = .{};
    }
};

/// The credits one pull drain returns, inline up to `inline_slots` so the
/// usual pull allocates nothing; the gateway pulls once per chunk. A pull
/// returns at most one data chunk, so it usually carries zero or one credit,
/// or two behind a credit-only chunk. A latch holder that is not the last
/// fills its slot with `.none`. Read through `slice()`, because the inline
/// buffer moves with every copy of the drain and a stored slice would
/// dangle. `deinit` frees only heap storage.
pub const PullCredits = struct {
    pub const inline_slots = 2;

    storage: Storage = .{ .inline_buf = .{} },

    const Storage = union(enum) {
        inline_buf: struct {
            len: usize = 0,
            buf: [inline_slots]Credit = undefined,
        },
        heap: []Credit,
    };

    fn initCapacity(allocator: std.mem.Allocator, count: usize) !PullCredits {
        if (count <= inline_slots)
            return .{ .storage = .{ .inline_buf = .{ .len = count } } };
        return .{ .storage = .{ .heap = try allocator.alloc(Credit, count) } };
    }

    fn mutSlice(self: *PullCredits) []Credit {
        return switch (self.storage) {
            .inline_buf => |*inline_buf| inline_buf.buf[0..inline_buf.len],
            .heap => |heap| heap,
        };
    }

    pub fn slice(self: *const PullCredits) []const Credit {
        return switch (self.storage) {
            .inline_buf => |*inline_buf| inline_buf.buf[0..inline_buf.len],
            .heap => |heap| heap,
        };
    }

    pub fn take(self: *PullCredits) PullCredits {
        const taken = self.*;
        self.* = .{};
        return taken;
    }

    pub fn deinit(self: *PullCredits, allocator: std.mem.Allocator) void {
        switch (self.storage) {
            .inline_buf => {},
            .heap => |heap| allocator.free(heap),
        }
        self.* = .{};
    }
};

/// What a pull drain moved out: the credits to release, at most one chunk's
/// bytes as a lease, the waiter once its read has an answer, and whether the
/// body ended (`done`) or failed. `deinit` drops the lease and the credit
/// storage but releases no credit; take the credits first.
pub const PullDrain = struct {
    credits: PullCredits = .{},
    waiter: ?PullWaiter = null,
    bytes: body_chunks.ByteLease = .empty,
    done: bool = false,
    failed: bool = false,

    pub fn deinit(self: *PullDrain, allocator: std.mem.Allocator) void {
        self.credits.deinit(allocator);
        self.bytes.deinit(allocator);
        if (self.waiter) |*waiter| {
            waiter.deinit();
        }
        self.* = .{};
    }

    pub fn takeBytes(self: *PullDrain) body_chunks.ByteLease {
        return self.bytes.take();
    }

    pub fn takeCredits(self: *PullDrain) PullCredits {
        return self.credits.take();
    }
};

pub const ReadKind = enum {
    text,
    json,
    array_buffer,
    bytes,
    blob,
    form_data,
};

pub fn Methods(comptime Body: type) type {
    return struct {
        /// Drops every queued chunk, passing each credit it releases to
        /// `callback`, and drops any registered reader. Never allocates.
        pub fn releaseQueuedChunksCallback(
            self: *Body,
            allocator: std.mem.Allocator,
            context: anytype,
            comptime callback: fn (@TypeOf(context), Credit) void,
        ) void {
            releaseQueuedChunksWithOptions(
                self,
                allocator,
                .{ .drop_waiters = true },
                context,
                callback,
            );
        }

        /// As `releaseQueuedChunksCallback`, but a registered reader stays and
        /// is still answered when the body settles.
        pub fn releaseQueuedChunksPreservingWaitersCallback(
            self: *Body,
            allocator: std.mem.Allocator,
            context: anytype,
            comptime callback: fn (@TypeOf(context), Credit) void,
        ) void {
            releaseQueuedChunksWithOptions(
                self,
                allocator,
                .{ .drop_waiters = false },
                context,
                callback,
            );
        }

        /// Registers the whole-body reader, which the body then owns. Fails
        /// with `error.FetchBodyAlreadyUsed` once the body was read, released
        /// or has a reader. Returns true when the body is already ready and
        /// this call claimed its place in the ready queue; the caller must
        /// then queue it, or call `clearReadyQueued` if it cannot.
        pub fn beginConsume(self: *Body, waiter: Waiter) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.view_released or self.consumed or self.waiter != null or self.pull_waiter != null) {
                return error.FetchBodyAlreadyUsed;
            }
            self.consumed = true;
            self.waiter = waiter;
            return claimReadyForQueueLocked(self);
        }

        /// Registers a pull reader, which the body then owns. Fails with
        /// `error.FetchBodyAlreadyUsed` after a whole-body read or a release,
        /// or `error.FetchBodyReadInProgress` while another pull waits.
        /// Returns as `beginConsume` does.
        pub fn beginPull(self: *Body, waiter: PullWaiter) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.view_released or (self.consumed and !self.streaming) or self.waiter != null) {
                return error.FetchBodyAlreadyUsed;
            }
            if (self.pull_waiter != null) {
                return error.FetchBodyReadInProgress;
            }
            self.consumed = true;
            self.streaming = true;
            self.pull_waiter = waiter;
            return claimReadyForQueueLocked(self);
        }

        /// Moves out at most one data chunk, with the credits of the
        /// credit-only chunks ahead of it, and returns an empty drain while
        /// the pull is not ready. A failed body drops every queued chunk and
        /// returns all their credits; a complete body returns `done` once the
        /// queue is empty. Fails only with `error.OutOfMemory`, before any
        /// chunk moves.
        pub fn drainReadyForPull(self: *Body, allocator: std.mem.Allocator) !PullDrain {
            self.mutex.lock();
            var failed_borrowed_releases: []BorrowedChunkRelease = &.{};
            var failed_borrowed_release_count: usize = 0;
            defer {
                self.mutex.unlock();
                for (failed_borrowed_releases[0..failed_borrowed_release_count]) |borrowed_release| {
                    borrowed_release.release();
                }
                allocator.free(failed_borrowed_releases);
            }

            if (!isReadyForPullLocked(self)) {
                return .{};
            }

            if (self.state == .failed) {
                const live = liveChunksLocked(self);
                var credits = try PullCredits.initCapacity(allocator, live.len);
                errdefer credits.deinit(allocator);
                var borrowed_count: usize = 0;
                for (live) |chunk| {
                    if (chunk.hasBorrowedRelease()) {
                        borrowed_count += 1;
                    }
                }
                if (borrowed_count != 0) {
                    failed_borrowed_releases = try allocator.alloc(BorrowedChunkRelease, borrowed_count);
                }
                const slots = credits.mutSlice();
                for (live, 0..) |*chunk, index| {
                    slots[index] = chunk.takeCredit(allocator) orelse .none;
                    if (chunk.takeBorrowedRelease(allocator)) |borrowed_release| {
                        failed_borrowed_releases[failed_borrowed_release_count] = borrowed_release;
                        failed_borrowed_release_count += 1;
                        chunk.bytes = &.{};
                    }
                    chunk.deinit(allocator);
                }
                self.chunks.clearRetainingCapacity();
                self.chunks_head = 0;
                self.queued_chunk_bytes.store(0, .monotonic);
                // Wakes a producer parked in `waitForDecodedCapacity`, which
                // would otherwise see the empty queue only when its timed wait
                // expires.
                self.queue_condition.broadcast();
                const waiter = self.pull_waiter.?;
                self.pull_waiter = null;
                self.ready_queued = false;
                return .{
                    .credits = credits,
                    .waiter = waiter,
                    .failed = true,
                };
            }

            if (self.chunks.items.len == 0) {
                const waiter = self.pull_waiter.?;
                self.pull_waiter = null;
                self.ready_queued = false;
                return .{
                    .waiter = waiter,
                    .done = true,
                };
            }

            // Slots are counted with `hasCreditSource`, which reads only this
            // body's chunks under its mutex. Counting the takes that will
            // yield a credit would read a shared latch's count, which another
            // view, draining or cloning under its own mutex, can change before
            // the `takeCredit` below; a wrong count means an out-of-bounds
            // write or uninitialized slots in release builds. A latch take that
            // yields nothing fills its slot with `.none`, which every consumer
            // skips, as in the waiter drain.
            var slot_count: usize = 0;
            for (liveChunksLocked(self)) |*chunk| {
                if (chunk.hasCreditSource())
                    slot_count += 1;
                if (chunk.bytes.len != 0)
                    break;
            }

            var credits = try PullCredits.initCapacity(allocator, slot_count);
            errdefer credits.deinit(allocator);
            const slots = credits.mutSlice();

            var credit_index: usize = 0;
            while (self.chunks.items.len != 0 and self.chunks.items[self.chunks_head].bytes.len == 0) {
                var credit_only = popFrontChunkLocked(self);
                if (credit_only.hasCreditSource()) {
                    slots[credit_index] = credit_only.takeCredit(allocator) orelse .none;
                    credit_index += 1;
                }
                credit_only.deinit(allocator);
            }

            if (self.chunks.items.len == 0) {
                self.ready_queued = false;
                std.debug.assert(credit_index == slot_count);
                if (self.state == .open) {
                    return .{ .credits = credits };
                }
                const waiter = self.pull_waiter.?;
                self.pull_waiter = null;
                return .{
                    .credits = credits,
                    .waiter = waiter,
                    .done = true,
                };
            }

            var chunk = popFrontChunkLocked(self);
            releaseQueuedChunkBytesLocked(self, chunk.bytes.len);
            if (chunk.hasCreditSource()) {
                slots[credit_index] = chunk.takeCredit(allocator) orelse .none;
                credit_index += 1;
            }
            std.debug.assert(credit_index == slot_count);
            // The lease keeps the owned allocation or the borrowed extent alive
            // until the consumer, or the response outbox it hands the bytes
            // to, drops it.
            const bytes = chunk.takeByteLease();
            chunk.deinit(allocator);

            const waiter = self.pull_waiter.?;
            self.pull_waiter = null;
            self.ready_queued = false;
            return .{
                .credits = credits,
                .waiter = waiter,
                .bytes = bytes,
            };
        }

        /// Copies every queued chunk into the body's materialized buffer and
        /// returns their credits, with the waiter once the body is complete;
        /// a failed body drops its chunks instead and returns the waiter.
        /// Fails with `error.OutOfMemory`, or `error.Overflow` if the queued
        /// sizes overflow `usize`, before any chunk moves.
        ///
        /// The body mutex is not held across the sizing and the copy, so
        /// producers appending chunks or folding meters do not wait on it.
        /// That is safe because of four invariants:
        /// - One consumer. Waiter drains run only on the thread that owns the
        ///   body's reader: `beginConsume` admits one waiter and the worker
        ///   settles ready bodies on one thread, while the gateway only pulls.
        ///   Only that thread writes `self.bytes`, since raw `append` serves
        ///   bodies the worker builds on the same thread, so growing and
        ///   writing it without the mutex cannot race. Producers touch only
        ///   the chunk queue and the atomic meters.
        /// - Sizing. Allocations happen with the lock dropped and the sizes
        ///   are checked again under it; chunks appended in between grow the
        ///   counts and the loop sizes again. The loop ends because producers
        ///   pause at the pending watermark, which bounds the queued bytes.
        /// - Allocation order. Every fallible step precedes the first change
        ///   to the queue, so an allocation failure leaves every chunk queued.
        /// - Appends during the copy. Once sized, the queue is taken under the
        ///   lock. Chunks appended while the taken batch is copied land in the
        ///   emptied queue, and a later ready cycle drains them after the
        ///   batch, which reaches `self.bytes` before this call returns.
        ///   Whether the drain is terminal is decided when the queue is taken:
        ///   producers cannot append after `.complete`, and a failure or
        ///   cancel during the copy looks to the caller as if it came right
        ///   after the drain.
        pub fn drainReadyForWaiter(self: *Body, allocator: std.mem.Allocator) !Drain {
            var credits: []Credit = &.{};
            var credits_owned = false;
            errdefer if (credits_owned) allocator.free(credits);
            var borrowed_releases: []BorrowedChunkRelease = &.{};
            var borrowed_owned = false;
            errdefer if (borrowed_owned) allocator.free(borrowed_releases);
            // Scratch for the chunk structs during the unlocked copy. This
            // drain only clears the body's `chunks` list, never replaces it,
            // so the allocator that grows the list stays the one that frees
            // it; only these drain-local arrays come from the drain's
            // allocator.
            var chunk_scratch: []Chunk = &.{};
            var chunk_scratch_owned = false;
            errdefer if (chunk_scratch_owned) allocator.free(chunk_scratch);
            var ensured_total: usize = 0;

            self.mutex.lock();
            var locked = true;
            defer if (locked) self.mutex.unlock();

            // Size the credits, borrowed releases, scratch and `self.bytes`
            // capacity, dropping the lock around every allocation, until the
            // sizes hold under the lock.
            while (true) {
                if (!isReadyForConsumeLocked(self)) {
                    self.ready_queued = false;
                    self.mutex.unlock();
                    locked = false;
                    if (credits_owned) allocator.free(credits);
                    if (borrowed_owned) allocator.free(borrowed_releases);
                    if (chunk_scratch_owned) allocator.free(chunk_scratch);
                    return .{};
                }
                const live = liveChunksLocked(self);
                var borrowed_count: usize = 0;
                var total_bytes: usize = 0;
                for (live) |chunk| {
                    if (chunk.hasBorrowedRelease()) {
                        borrowed_count += 1;
                    }
                    total_bytes = try std.math.add(usize, total_bytes, chunk.bytes.len);
                }
                if ((credits_owned and credits.len == live.len) and
                    (chunk_scratch_owned and chunk_scratch.len == live.len) and
                    borrowed_releases.len == borrowed_count and
                    total_bytes <= ensured_total)
                    break;

                const want_chunks = live.len;
                const want_borrowed = borrowed_count;
                const want_total = total_bytes;
                self.mutex.unlock();
                locked = false;

                if (!credits_owned) {
                    credits = try allocator.alloc(Credit, want_chunks);
                    credits_owned = true;
                } else if (credits.len != want_chunks) {
                    credits = try allocator.realloc(credits, want_chunks);
                }
                if (!chunk_scratch_owned) {
                    chunk_scratch = try allocator.alloc(Chunk, want_chunks);
                    chunk_scratch_owned = true;
                } else if (chunk_scratch.len != want_chunks) {
                    chunk_scratch = try allocator.realloc(chunk_scratch, want_chunks);
                }
                if (borrowed_releases.len != want_borrowed) {
                    if (!borrowed_owned) {
                        borrowed_releases = try allocator.alloc(BorrowedChunkRelease, want_borrowed);
                        borrowed_owned = true;
                    } else {
                        borrowed_releases = try allocator.realloc(borrowed_releases, want_borrowed);
                    }
                }
                if (want_total > ensured_total) {
                    // Safe without the lock: only the consumer thread writes
                    // `self.bytes` (see the function comment).
                    try self.bytes.ensureUnusedCapacity(want_total);
                    ensured_total = want_total;
                }

                self.mutex.lock();
                locked = true;
            }

            // Locked from here with every size checked, so nothing below can
            // fail. `borrowed_releases.len` is only an upper bound: a
            // tee-latched borrow's take yields null for every holder but the
            // last, so only the filled prefix is released.
            if (self.state == .failed) {
                const live = liveChunksLocked(self);
                var borrowed_release_count: usize = 0;
                for (live, 0..) |*chunk, index| {
                    credits[index] = chunk.takeCredit(allocator) orelse .none;
                    if (chunk.takeBorrowedRelease(allocator)) |borrowed_release| {
                        borrowed_releases[borrowed_release_count] = borrowed_release;
                        borrowed_release_count += 1;
                        chunk.bytes = &.{};
                    }
                    chunk.deinit(allocator);
                }
                std.debug.assert(borrowed_release_count <= borrowed_releases.len);
                self.chunks.clearRetainingCapacity();
                self.chunks_head = 0;
                self.queued_chunk_bytes.store(0, .monotonic);
                // Wakes capacity waiters now, as the pull drain does, rather
                // than when their timed wait expires.
                self.queue_condition.broadcast();
                const waiter = self.waiter.?;
                self.waiter = null;
                self.ready_queued = false;
                self.mutex.unlock();
                locked = false;
                for (borrowed_releases[0..borrowed_release_count]) |borrowed_release| {
                    borrowed_release.release();
                }
                if (borrowed_owned) allocator.free(borrowed_releases);
                if (chunk_scratch_owned) allocator.free(chunk_scratch);
                credits_owned = false;
                return .{
                    .credits = credits,
                    .waiter = waiter,
                    .terminal = true,
                    .failed = true,
                };
            }

            // Take the chunk structs, whose payloads move by reference, and
            // publish the settlement state under the lock; the payloads are
            // copied into `self.bytes` after unlocking.
            {
                const live = liveChunksLocked(self);
                std.debug.assert(live.len == chunk_scratch.len);
                @memcpy(chunk_scratch, live);
            }
            self.chunks.clearRetainingCapacity();
            self.chunks_head = 0;
            self.queued_chunk_bytes.store(0, .monotonic);
            // Wakes capacity waiters, as the paths above do.
            self.queue_condition.broadcast();
            const terminal = self.state == .complete;
            const waiter = if (terminal) blk: {
                const stored = self.waiter.?;
                self.waiter = null;
                break :blk stored;
            } else null;
            self.ready_queued = false;
            self.mutex.unlock();
            locked = false;

            var borrowed_release_count: usize = 0;
            for (chunk_scratch, 0..) |*chunk, index| {
                credits[index] = chunk.takeCredit(allocator) orelse .none;
                self.bytes.writeAssumeCapacity(chunk.bytes);
                if (chunk.takeBorrowedRelease(allocator)) |borrowed_release| {
                    borrowed_releases[borrowed_release_count] = borrowed_release;
                    borrowed_release_count += 1;
                    chunk.bytes = &.{};
                }
                chunk.deinit(allocator);
            }
            // An upper bound, as in the failed-body branch above.
            std.debug.assert(borrowed_release_count <= borrowed_releases.len);
            allocator.free(chunk_scratch);
            chunk_scratch_owned = false;
            for (borrowed_releases[0..borrowed_release_count]) |borrowed_release| {
                borrowed_release.release();
            }
            if (borrowed_owned) allocator.free(borrowed_releases);
            borrowed_owned = false;
            credits_owned = false;

            return .{
                .credits = credits,
                .waiter = waiter,
                .terminal = terminal,
                .failed = false,
            };
        }

        /// Drops the registered whole-body reader and makes the body readable
        /// again.
        pub fn rollbackPendingConsume(self: *Body, allocator: std.mem.Allocator) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.waiter) |*stored| {
                stored.deinit(allocator);
                self.waiter = null;
            }
            self.consumed = false;
            self.ready_queued = false;
        }

        /// Drops the registered pull reader; a body that was only being
        /// pulled becomes readable again.
        pub fn rollbackPendingPull(self: *Body) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.pull_waiter) |*stored| {
                stored.deinit();
                self.pull_waiter = null;
            }
            if (self.streaming and self.waiter == null) {
                self.consumed = false;
            }
            self.streaming = false;
            self.ready_queued = false;
        }

        pub fn clearReadyQueued(self: *Body) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.ready_queued = false;
        }

        pub fn isReadyForWaiter(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return isReadyForWaiterLocked(self);
        }

        pub fn takeReadyWaiter(self: *Body) ?Waiter {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!isReadyForConsumeLocked(self)) {
                return null;
            }
            const waiter = self.waiter.?;
            self.waiter = null;
            self.ready_queued = false;
            return waiter;
        }

        pub fn claimReadyForQueue(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return claimReadyForQueueLocked(self);
        }

        const ReleaseQueuedChunksOptions = struct {
            drop_waiters: bool,
        };

        /// The release path of JS destructors and request cleanup, so it must
        /// not allocate or return an error. Chunks are moved out under the
        /// lock, and their credits and borrowed buffers are released after
        /// unlocking, so the callbacks may re-enter body cleanup.
        fn releaseQueuedChunksWithOptions(
            self: *Body,
            allocator: std.mem.Allocator,
            options: ReleaseQueuedChunksOptions,
            context: anytype,
            comptime callback: fn (@TypeOf(context), Credit) void,
        ) void {
            var chunks: std.ArrayListUnmanaged(Chunk) = .empty;
            var chunks_head: usize = 0;
            var waiter: ?Waiter = null;
            var pull_waiter: ?PullWaiter = null;

            self.mutex.lock();
            chunks = self.chunks;
            chunks_head = self.chunks_head;
            self.chunks = .empty;
            self.chunks_head = 0;
            self.queued_chunk_bytes.store(0, .monotonic);
            self.ready_queued = false;
            if (options.drop_waiters) {
                waiter = self.waiter;
                self.waiter = null;
                pull_waiter = self.pull_waiter;
                self.pull_waiter = null;
            }
            self.queue_condition.broadcast();
            self.mutex.unlock();

            // Entries below the taken head cursor were already popped and
            // freed by a pull drain.
            for (chunks.items[chunks_head..]) |*chunk| {
                if (chunk.takeCredit(allocator)) |credit| {
                    callback(context, credit);
                }
                chunk.deinit(allocator);
            }
            chunks.deinit(allocator);

            if (waiter) |*stored| {
                stored.deinit(allocator);
            }
            if (pull_waiter) |*stored| {
                stored.deinit();
            }
        }

        // A front pop advances `Body.chunks_head` instead of shifting the
        // list, so it costs O(1). The dead prefix is reclaimed at once when
        // the queue empties, and by compaction when dead entries outnumber
        // live ones, which keeps pops amortized O(1).

        fn liveChunksLocked(self: *Body) []Chunk {
            return self.chunks.items[self.chunks_head..];
        }

        /// Minimum dead prefix before a mid-queue compaction is worth it.
        const chunk_compact_min: usize = 8;

        fn popFrontChunkLocked(self: *Body) Chunk {
            std.debug.assert(self.chunks_head < self.chunks.items.len);
            const chunk = self.chunks.items[self.chunks_head];
            self.chunks_head += 1;
            const len = self.chunks.items.len;
            if (self.chunks_head == len) {
                // Empty: reset so `items.len != 0` stays a correct emptiness
                // check (see `Body.chunks_head`).
                self.chunks.clearRetainingCapacity();
                self.chunks_head = 0;
            } else if (self.chunks_head >= chunk_compact_min and
                self.chunks_head > len - self.chunks_head)
            {
                // More dead entries than live ones: compacting moves fewer
                // entries than the pops that made the dead prefix, so pops
                // stay amortized O(1), and it bounds the dead entries a
                // long-lived queue can hold.
                const live = len - self.chunks_head;
                std.mem.copyForwards(
                    Chunk,
                    self.chunks.items[0..live],
                    self.chunks.items[self.chunks_head..],
                );
                self.chunks.shrinkRetainingCapacity(live);
                self.chunks_head = 0;
            }
            return chunk;
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

        fn claimReadyForQueueLocked(self: *Body) bool {
            if (!isReadyForWaiterLocked(self) or self.ready_queued) {
                return false;
            }
            self.ready_queued = true;
            return true;
        }

        fn releaseQueuedChunkBytesLocked(self: *Body, amount: usize) void {
            if (amount == 0) {
                return;
            }
            const queued = self.queued_chunk_bytes.load(.monotonic);
            std.debug.assert(amount <= queued);
            self.queued_chunk_bytes.store(queued - amount, .monotonic);
            self.queue_condition.broadcast();
        }
    };
}
