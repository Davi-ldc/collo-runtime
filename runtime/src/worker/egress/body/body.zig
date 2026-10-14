//! A fetch response body as the worker's JavaScript reads it: the chunks
//! gateway packets and the decoder queue, the bytes a whole-body read
//! materializes, its terminal state, its reader, its tee links and, on the
//! source body of an encoded fetch, its decoder.
//!
//! Everything here runs on the worker's VM thread, which is also its event
//! loop: packets feed a body, JavaScript reads, clones, cancels and releases
//! it, all between turns. So a body holds no lock and no atomic, and in
//! safety-checked builds its entry points assert they run on the thread that
//! created it.
//!
//! A body has at most one reader: a waiter that materializes the whole body
//! for `text()`, `json()` and the like, or a pull waiter that takes one chunk
//! per read. A reader is answered from the ready queue (`ready.zig`).
//! `ready_queued` says the body's `fetch_body_ready` item is in that queue:
//! the claim that queues the item sets it and only the item's pop clears it
//! (`noteReadyItemPopped`), whatever happens to the reader or the view
//! meanwhile, so the queue never holds two items of one body.
//!
//! A clone is a branch of the source body, its root. Only a root accepts
//! chunks and it feeds a share of every chunk (`Chunk.share`) to each open
//! branch some reader can still read; a branch starts with the clone source's
//! queued chunks. A link holds one reference on each side, and
//! `detachTeeLinks` drops both. A root keeps feeding branches after its own
//! view is released, and the fetch is stopped only once no view can read it
//! (`sourceCancelIdentityAfterViewRelease`).
//!
//! Terminal states: a body leaves `open` for `complete` or `failed`, and only
//! a cancel moves it again, from `complete` to `failed`, because a user abort
//! overrides everything. `fail` applies only to an open body, so bytes that
//! fully arrived stay readable and the first failure stays. A root applies
//! each transition to its branches too. A transition that cannot allocate its
//! message still happens, without one.
//!
//! A body is reference counted. Before the last release, the caller releases
//! every queued chunk, detaches every tee link and drops the decoder; freeing
//! asserts all three.

const std = @import("std");
const bindings = @import("collo_bindings");
const common_io = @import("collo_common_io");
const chunk_mod = @import("chunk.zig");
const decoder_mod = @import("decoder.zig");

pub const Chunk = chunk_mod.Chunk;
pub const ByteLease = chunk_mod.ByteLease;
pub const BorrowedChunk = chunk_mod.BorrowedChunk;
pub const BorrowedRelease = chunk_mod.BorrowedRelease;
pub const Decoder = decoder_mod.Decoder;
pub const Identity = bindings.FetchBodyIdentity;

pub const State = enum {
    open,
    complete,
    failed,
};

/// What a whole-body read builds from the complete bytes.
pub const ReadKind = enum {
    text,
    json,
    array_buffer,
    bytes,
    blob,
    form_data,
};

/// A pending whole-body read: its kind, the response's content type and the
/// promise to settle. `deinit` frees the content type and releases the
/// promise unless `takeDeferredRaw` took it.
pub const Waiter = struct {
    kind: ReadKind,
    content_type: []u8,
    deferred: ?*bindings.RawPromiseDeferred,

    pub fn deinit(self: *Waiter, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        if (self.deferred) |raw|
            bindings.releasePromiseDeferred(raw);
        self.* = undefined;
    }

    pub fn takeDeferredRaw(self: *Waiter) !*bindings.RawPromiseDeferred {
        const raw = self.deferred orelse return error.InvalidPromiseDeferred;
        self.deferred = null;
        return raw;
    }
};

/// A pending pull and the promise to settle; a response stream pulls with no
/// promise (`consume.beginResponseStreamPull`).
pub const PullWaiter = struct {
    deferred: ?*bindings.RawPromiseDeferred,

    pub fn deinit(self: *PullWaiter) void {
        if (self.deferred) |raw|
            bindings.releasePromiseDeferred(raw);
        self.* = undefined;
    }

    pub fn takeDeferredRaw(self: *PullWaiter) !*bindings.RawPromiseDeferred {
        const raw = self.deferred orelse return error.InvalidPromiseDeferred;
        self.deferred = null;
        return raw;
    }
};

/// What a waiter drain did: the waiter once the body is complete or failed,
/// which the caller owns.
pub const Drain = struct {
    waiter: ?Waiter = null,
    terminal: bool = false,

    pub fn deinit(self: *Drain, allocator: std.mem.Allocator) void {
        if (self.waiter) |*waiter|
            waiter.deinit(allocator);
        self.* = .{};
    }
};

/// What a pull drain moved out: at most one chunk's bytes as a lease, the
/// waiter once its read has an answer, and whether the body ended (`done`)
/// or failed. The caller owns all of it until `deinit`.
pub const PullDrain = struct {
    waiter: ?PullWaiter = null,
    bytes: ByteLease = .empty,
    done: bool = false,
    failed: bool = false,

    pub fn deinit(self: *PullDrain, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        if (self.waiter) |*waiter|
            waiter.deinit();
        self.* = .{};
    }

    pub fn takeBytes(self: *PullDrain) ByteLease {
        return self.bytes.take();
    }
};

const ThreadId = if (std.debug.runtime_safety) std.Thread.Id else void;

pub const Body = struct {
    refs: u32 = 1,
    identity: Identity,
    state: State = .open,
    /// The materialized body, which waiter drains fill.
    bytes: common_io.buffer.StreamBuffer,
    /// Queued chunks from `chunks_head` on; entries below it were drained. A
    /// drain that empties the queue resets both, so `chunks.items.len != 0`
    /// means a chunk is queued.
    chunks: std.ArrayListUnmanaged(Chunk) = .empty,
    chunks_head: usize = 0,
    /// Bytes in queued chunks; the decoder pauses at its watermark on it.
    queued_bytes: usize = 0,
    consumed: bool = false,
    streaming: bool = false,
    waiter: ?Waiter = null,
    pull_waiter: ?PullWaiter = null,
    error_message: ?[]u8 = null,
    abort_reason: ?bindings.Value = null,
    /// This body's `fetch_body_ready` item is in the ready queue, from the
    /// claim that queues it (`claimReadyForQueue`) until it pops
    /// (`noteReadyItemPopped`). A body that leaves `State.bodies` while it is
    /// set hands its item to `State.body_ready_orphans`.
    ready_queued: bool = false,
    view_released: bool = false,
    /// CLOCK_MONOTONIC time at which the gateway published the packet that
    /// first made this body readable since its ready item last ran; 0 when no
    /// packet did, as for a cancel or a detach. The `fetch_body_ready`
    /// enqueue carries it, so the request's I/O interval closes when the data
    /// arrived rather than when it was drained.
    ready_at_mono_ns: u64 = 0,
    tee_root: ?*Body = null,
    tee_branches: std.ArrayListUnmanaged(*Body) = .empty,
    /// The decoder of a source body the gateway forwards encoded. It lives
    /// exactly while the body is in `State.bodies` and the gateway may still
    /// send chunks: every path that removes the body, ends the fetch or
    /// detaches the worker drops it (`dropDecoder`), which returns its
    /// pending extents while the pool is still mapped.
    decoder: ?*Decoder = null,
    owner_thread: ThreadId,

    /// An open, empty body holding one reference. A body sets no byte limit
    /// of its own: the gateway caps the bytes it publishes for a fetch, the
    /// decoder of an encoded body caps what it decodes (`decoder.zig`), and
    /// the worker's cgroup bounds what tee branches copy.
    pub fn initOpen(allocator: std.mem.Allocator, identity: Identity) Body {
        return .{
            .identity = identity,
            .bytes = common_io.buffer.StreamBuffer.initDefault(allocator),
            .owner_thread = currentThread(),
        };
    }

    /// Frees the body's own storage, under the conditions the file header
    /// names.
    pub fn deinit(self: *Body, allocator: std.mem.Allocator) void {
        std.debug.assert(self.tee_root == null);
        std.debug.assert(self.tee_branches.items.len == 0);
        std.debug.assert(self.chunks.items.len == 0);
        std.debug.assert(self.chunks_head == 0);
        std.debug.assert(self.queued_bytes == 0);
        std.debug.assert(self.decoder == null);
        if (self.waiter) |*waiter|
            waiter.deinit(allocator);
        if (self.pull_waiter) |*waiter|
            waiter.deinit();
        self.chunks.deinit(allocator);
        self.tee_branches.deinit(allocator);
        if (self.error_message) |message|
            allocator.free(message);
        if (self.abort_reason) |*reason|
            reason.deinit();
        self.bytes.deinit();
        self.* = undefined;
    }

    pub fn retain(self: *Body) void {
        self.assertOwnerThread();
        self.refs += 1;
    }

    /// Drops one reference and frees a heap-allocated body at the last one.
    pub fn release(self: *Body, allocator: std.mem.Allocator) void {
        self.assertOwnerThread();
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs != 0)
            return;
        self.deinit(allocator);
        allocator.destroy(self);
    }

    /// Drops the decoder, which releases its pending extents.
    pub fn dropDecoder(self: *Body, allocator: std.mem.Allocator) void {
        const decoder = self.decoder orelse return;
        self.decoder = null;
        decoder.deinit(allocator);
        allocator.destroy(decoder);
    }

    /// Queues `bytes`, owned with `allocator`, which must not be empty. On
    /// success the body owns them; on error the caller does. Fails as
    /// `appendChunk` does.
    pub fn appendOwnedChunk(self: *Body, allocator: std.mem.Allocator, bytes: []u8) !void {
        return self.appendChunk(allocator, .{ .bytes = bytes });
    }

    /// Queues a borrowed extent, which must not be empty. On success the body
    /// fires its release once the last view dropped the bytes; on error the
    /// caller still owns the release. Fails as `appendChunk` does.
    pub fn appendBorrowedChunk(self: *Body, allocator: std.mem.Allocator, borrowed: BorrowedChunk) !void {
        return self.appendChunk(allocator, .{
            .bytes = borrowed.bytes,
            .storage = .{ .borrowed = borrowed.release },
        });
    }

    /// Queues `incoming` on this root and each of its open branches, every
    /// capacity and copy reserved before anything is queued, so a failure
    /// leaves every view as it was and `incoming` the caller's. The first
    /// view takes `incoming` itself and the others a share. The caller then
    /// queues the views whose reader became ready (`common.queueReadyViews`).
    /// Fails with `error.FetchBodyNotWritable` unless this is an open root,
    /// `error.FetchBodyNoActiveViews` when no view can still read, or
    /// `error.OutOfMemory`.
    fn appendChunk(self: *Body, allocator: std.mem.Allocator, incoming: Chunk) !void {
        self.assertOwnerThread();
        std.debug.assert(incoming.bytes.len != 0);
        if (self.state != .open or self.tee_root != null)
            return error.FetchBodyNotWritable;
        const include_root = self.readsRemain();
        var branch_count: usize = 0;
        for (self.tee_branches.items) |branch| {
            if (!branch.acceptsTeeChunks())
                continue;
            try branch.chunks.ensureUnusedCapacity(allocator, 1);
            branch_count += 1;
        }
        if (include_root)
            try self.chunks.ensureUnusedCapacity(allocator, 1);
        const view_count = branch_count + @intFromBool(include_root);
        if (view_count == 0)
            return error.FetchBodyNoActiveViews;

        // Every share after the first view's is made before anything is
        // queued. A share of owned bytes is a copy; shares of a borrowed
        // extent hold one counted release.
        var first = incoming;
        var shares: std.ArrayListUnmanaged(Chunk) = .empty;
        defer shares.deinit(allocator);
        errdefer {
            for (shares.items) |*share| share.deinit(allocator);
            if (first.storage == .shared) {
                // The shared release came from the caller's release, which
                // stays the caller's on error.
                const shared = first.storage.shared;
                std.debug.assert(shared.holders == 1);
                allocator.destroy(shared);
            }
        }
        try shares.ensureTotalCapacity(allocator, view_count - 1);
        for (1..view_count) |_|
            shares.appendAssumeCapacity(try first.share(allocator));

        var next_share: usize = 0;
        var queued_first = false;
        if (include_root) {
            self.queueAssumeCapacity(first);
            queued_first = true;
        }
        for (self.tee_branches.items) |branch| {
            if (!branch.acceptsTeeChunks())
                continue;
            if (!queued_first) {
                branch.queueAssumeCapacity(first);
                queued_first = true;
            } else {
                branch.queueAssumeCapacity(shares.items[next_share]);
                next_share += 1;
            }
        }
        std.debug.assert(next_share == shares.items.len);
        shares.clearRetainingCapacity();
    }

    /// Creates a branch named `identity` that starts with this view's queued
    /// chunks and state and, while the root stays open, receives every later
    /// chunk of the root. A root that is no longer open yields an unlinked
    /// copy. The caller owns the branch's first reference and must detach a
    /// linked branch before releasing it. Fails with
    /// `error.FetchBodyAlreadyUsed` once this view was read or released,
    /// `error.FetchBodyNotReadable` for a failed body without a message, or
    /// `error.OutOfMemory`, and this view then keeps every chunk.
    pub fn cloneBranch(self: *Body, allocator: std.mem.Allocator, identity: Identity) !*Body {
        self.assertOwnerThread();
        const root = self.tee_root orelse self;
        if (self.view_released or self.consumed or self.waiter != null or self.pull_waiter != null)
            return error.FetchBodyAlreadyUsed;
        if (self.state == .failed and self.error_message == null)
            return error.FetchBodyNotReadable;
        // Only a whole-body read's drain fills the materialized bytes, and a
        // view that took a reader is consumed, so a view that can be cloned
        // holds all its bytes in queued chunks.
        std.debug.assert(self.bytes.slice().len == 0);

        const branch = try allocator.create(Body);
        branch.* = initOpen(allocator, identity);
        errdefer {
            branch.releaseQueuedChunks(allocator);
            branch.deinit(allocator);
            allocator.destroy(branch);
        }

        const source_chunks = self.liveChunks();
        try branch.chunks.ensureTotalCapacity(allocator, source_chunks.len);
        for (source_chunks) |*source_chunk|
            branch.queueAssumeCapacity(try source_chunk.share(allocator));
        if (self.error_message) |message|
            branch.error_message = try allocator.dupe(u8, message);
        if (self.abort_reason) |reason|
            branch.abort_reason = try reason.retain();
        branch.state = self.state;

        if (root.state == .open) {
            try root.tee_branches.append(allocator, branch);
            branch.tee_root = root;
            // The branch keeps the root alive and the root the branch, until
            // `detachTeeLinks` severs the link.
            root.refs += 1;
            branch.refs += 1;
        }
        return branch;
    }

    /// Severs every link of this body, from either side, and drops the
    /// references those links held.
    pub fn detachTeeLinks(self: *Body, allocator: std.mem.Allocator) void {
        self.assertOwnerThread();
        if (self.tee_root) |root| {
            self.tee_root = null;
            for (root.tee_branches.items, 0..) |item, index| {
                if (item == self) {
                    _ = root.tee_branches.orderedRemove(index);
                    self.release(allocator);
                    break;
                }
            }
            root.release(allocator);
            return;
        }
        var branches = self.tee_branches;
        self.tee_branches = .empty;
        defer branches.deinit(allocator);
        for (branches.items) |branch| {
            if (branch.tee_root == self)
                branch.tee_root = null;
            branch.release(allocator);
            self.release(allocator);
        }
    }

    /// Whether this released root must stay because it is open and still
    /// feeds branches.
    pub fn shouldKeepReleasedSource(self: *const Body) bool {
        return self.tee_root == null and self.state == .open and self.tee_branches.items.len != 0;
    }

    /// Whether this root's view is released with no branch and no reader
    /// left, so it can leave the table.
    pub fn canRemoveReleasedSource(self: *const Body) bool {
        return self.tee_root == null and
            self.view_released and
            self.tee_branches.items.len == 0 and
            !self.hasPendingWaiter();
    }

    /// The identity of the source to stop now that this view was released,
    /// or null while this view has a reader, another view can still read,
    /// or the source already settled.
    pub fn sourceCancelIdentityAfterViewRelease(self: *const Body) ?Identity {
        if (self.hasPendingWaiter())
            return null;
        const root = self.tee_root orelse self;
        if (root.state != .open)
            return null;
        if (root != self and root.readsRemain())
            return null;
        for (root.tee_branches.items) |branch| {
            if (branch != self and branch.readsRemain())
                return null;
        }
        return root.identity;
    }

    /// The identity of the fetch's source body: this view's root, or itself.
    pub fn sourceIdentity(self: *const Body) Identity {
        const root = self.tee_root orelse self;
        return root.identity;
    }

    /// Marks this view released: no reader can start, and a registered
    /// reader is dropped.
    pub fn markViewReleased(self: *Body, allocator: std.mem.Allocator) void {
        self.markViewReleasedPreservingWaiters();
        if (self.waiter) |*stored| {
            stored.deinit(allocator);
            self.waiter = null;
        }
        if (self.pull_waiter) |*stored| {
            stored.deinit();
            self.pull_waiter = null;
        }
    }

    /// As `markViewReleased`, but a registered reader stays and is still
    /// answered when the body settles.
    pub fn markViewReleasedPreservingWaiters(self: *Body) void {
        self.view_released = true;
        self.consumed = true;
        self.streaming = false;
    }

    pub fn hasPendingWaiter(self: *const Body) bool {
        return self.waiter != null or self.pull_waiter != null;
    }

    pub fn viewReleased(self: *const Body) bool {
        return self.view_released;
    }

    /// Completes the body, and a root's branches, unless failed. The caller
    /// then queues the views whose reader became ready, as after every
    /// transition below.
    pub fn complete(self: *Body) void {
        self.assertOwnerThread();
        if (self.state != .failed)
            self.state = .complete;
        if (self.tee_root != null)
            return;
        for (self.tee_branches.items) |branch| {
            if (branch.state != .failed)
                branch.state = .complete;
        }
    }

    /// Fails an open body, and each open branch of a root, with a copy of
    /// `message`.
    pub fn fail(self: *Body, allocator: std.mem.Allocator, message: []const u8) void {
        self.assertOwnerThread();
        if (self.state != .open)
            return;
        self.setFailed(allocator, message, null);
        if (self.tee_root != null)
            return;
        for (self.tee_branches.items) |branch| {
            if (branch.state == .open)
                branch.setFailed(allocator, message, null);
        }
    }

    /// Fails the body and a root's branches whatever their state, with a copy
    /// of `message` and the abort reason JavaScript gave, of which this
    /// takes ownership; a branch gets a reference of its own, or none when
    /// the retain fails.
    pub fn cancel(
        self: *Body,
        allocator: std.mem.Allocator,
        message: []const u8,
        reason: ?bindings.Value,
    ) void {
        self.assertOwnerThread();
        if (self.tee_root == null) {
            for (self.tee_branches.items) |branch| {
                const branch_reason: ?bindings.Value = if (reason) |value| value.retain() catch |err| blk: {
                    // The branch then rejects with the message alone.
                    std.log.warn("fetch body abort reason retain failed: {s}", .{@errorName(err)});
                    break :blk null;
                } else null;
                branch.setFailed(allocator, message, branch_reason);
            }
        }
        self.setFailed(allocator, message, reason);
    }

    /// Moves the body to `failed` with a copy of `message`, which replaces
    /// the old one unless the copy fails, and with `reason`, of which it
    /// takes ownership.
    fn setFailed(self: *Body, allocator: std.mem.Allocator, message: []const u8, reason: ?bindings.Value) void {
        const copy: ?[]u8 = allocator.dupe(u8, message) catch |err| switch (err) {
            // The body fails all the same, keeping the message it had.
            error.OutOfMemory => null,
        };
        if (copy) |new_message| {
            if (self.error_message) |old|
                allocator.free(old);
            self.error_message = new_message;
        }
        if (reason) |value| {
            if (self.abort_reason) |*old|
                old.deinit();
            self.abort_reason = value;
        }
        self.state = .failed;
    }

    pub fn isFailed(self: *const Body) bool {
        return self.state == .failed;
    }

    /// The message of a failed body, or null. The slice stays valid until a
    /// later cancel replaces it or the body is freed.
    pub fn failureMessage(self: *const Body) ?[]const u8 {
        if (self.state != .failed)
            return null;
        return self.error_message;
    }

    /// A new reference to a failed body's abort reason, which the caller
    /// releases; null when there is none or the retain fails.
    pub fn failureReasonRetained(self: *const Body) ?bindings.Value {
        if (self.state != .failed)
            return null;
        const reason = self.abort_reason orelse return null;
        return reason.retain() catch null;
    }

    /// The materialized bytes of a complete body, without consuming it, or
    /// null before completion. Queued chunks are not in the slice until a
    /// waiter drain copies them in.
    pub fn borrowCompleteBytes(self: *const Body) ?[]const u8 {
        if (self.state != .complete)
            return null;
        return self.bytes.slice();
    }

    pub fn queuedBytes(self: *const Body) usize {
        return self.queued_bytes;
    }

    /// Registers the whole-body reader, which the body then owns. Fails with
    /// `error.FetchBodyAlreadyUsed` once the body was read, released or has
    /// a reader. Returns true when the body is ready and this call claimed
    /// its place in the ready queue; the caller must then queue it.
    pub fn beginConsume(self: *Body, waiter: Waiter) !bool {
        self.assertOwnerThread();
        if (self.view_released or self.consumed or self.hasPendingWaiter())
            return error.FetchBodyAlreadyUsed;
        self.consumed = true;
        self.waiter = waiter;
        return self.claimReadyForQueue();
    }

    /// Registers a pull reader, which the body then owns. Fails with
    /// `error.FetchBodyAlreadyUsed` after a whole-body read or a release, or
    /// `error.FetchBodyReadInProgress` while another pull waits. Returns as
    /// `beginConsume` does.
    pub fn beginPull(self: *Body, waiter: PullWaiter) !bool {
        self.assertOwnerThread();
        if (self.view_released or (self.consumed and !self.streaming) or self.waiter != null)
            return error.FetchBodyAlreadyUsed;
        if (self.pull_waiter != null)
            return error.FetchBodyReadInProgress;
        self.consumed = true;
        self.streaming = true;
        self.pull_waiter = waiter;
        return self.claimReadyForQueue();
    }

    /// Claims the body's place in the ready queue when its reader is ready
    /// and no item of it is queued; the caller must then queue the item
    /// (`common.queueClaimed`).
    pub fn claimReadyForQueue(self: *Body) bool {
        if (!self.isReady() or self.ready_queued)
            return false;
        self.ready_queued = true;
        return true;
    }

    /// Notes that the body's item left the ready queue, whether or not it
    /// runs, so a later readiness may queue another
    /// (`State.noteReadyItemPopped`).
    pub fn noteReadyItemPopped(self: *Body) void {
        std.debug.assert(self.ready_queued);
        self.ready_queued = false;
    }

    /// Moves out at most one chunk for a ready pull reader and hands back the
    /// reader, and returns an empty drain while the pull is not ready. A
    /// failed body drops every queued chunk; a complete body answers `done`
    /// once the queue is empty.
    pub fn drainReadyForPull(self: *Body, allocator: std.mem.Allocator) PullDrain {
        self.assertOwnerThread();
        if (!self.isReadyForPull())
            return .{};
        if (self.state == .failed) {
            self.dropChunks(allocator);
            return .{ .waiter = self.takePullWaiter(), .failed = true };
        }
        if (self.chunks.items.len == 0)
            return .{ .waiter = self.takePullWaiter(), .done = true };
        const front = self.popFront();
        return .{ .waiter = self.takePullWaiter(), .bytes = front.toLease() };
    }

    /// Copies every queued chunk into the materialized bytes, releasing each
    /// borrowed extent, and hands back the waiter once the body is complete;
    /// a failed body drops its chunks instead and hands back the waiter.
    /// Fails with `error.OutOfMemory`, or `error.Overflow` when the queued
    /// sizes overflow, before any chunk moves.
    pub fn drainReadyForWaiter(self: *Body, allocator: std.mem.Allocator) !Drain {
        self.assertOwnerThread();
        if (!self.isReadyForConsume())
            return .{};
        if (self.state == .failed) {
            self.dropChunks(allocator);
            return .{ .waiter = self.takeWaiter(), .terminal = true };
        }
        var total: usize = 0;
        for (self.liveChunks()) |chunk|
            total = try std.math.add(usize, total, chunk.bytes.len);
        try self.bytes.ensureUnusedCapacity(total);
        var chunks = self.takeChunks();
        defer chunks.deinit(allocator);
        for (chunks.items) |*chunk| {
            self.bytes.writeAssumeCapacity(chunk.bytes);
            chunk.deinit(allocator);
        }
        if (self.state != .complete)
            return .{};
        return .{ .waiter = self.takeWaiter(), .terminal = true };
    }

    /// Drops every queued chunk, releasing each borrowed extent, and any
    /// registered reader. Never allocates.
    pub fn releaseQueuedChunks(self: *Body, allocator: std.mem.Allocator) void {
        self.releaseQueuedChunksPreservingWaiters(allocator);
        if (self.waiter) |*stored| {
            stored.deinit(allocator);
            self.waiter = null;
        }
        if (self.pull_waiter) |*stored| {
            stored.deinit();
            self.pull_waiter = null;
        }
    }

    /// As `releaseQueuedChunks`, but a registered reader stays and is still
    /// answered when the body settles.
    pub fn releaseQueuedChunksPreservingWaiters(self: *Body, allocator: std.mem.Allocator) void {
        self.assertOwnerThread();
        self.dropChunks(allocator);
    }

    /// Whether some reader can still read this view: it is not released, or
    /// a reader waits on it.
    fn readsRemain(self: *const Body) bool {
        return !self.view_released or self.hasPendingWaiter();
    }

    /// Whether this branch takes the root's chunks: it is open and a reader
    /// can still read it, the same test that keeps the root reading and the
    /// fetch running, so a released clone whose read is pending still gets
    /// the rest of the body.
    fn acceptsTeeChunks(self: *const Body) bool {
        return self.state == .open and self.readsRemain();
    }

    fn isReady(self: *const Body) bool {
        return self.isReadyForConsume() or self.isReadyForPull();
    }

    fn isReadyForConsume(self: *const Body) bool {
        return self.waiter != null and self.hasChunkOrEnd();
    }

    fn isReadyForPull(self: *const Body) bool {
        return self.pull_waiter != null and self.hasChunkOrEnd();
    }

    fn hasChunkOrEnd(self: *const Body) bool {
        return switch (self.state) {
            .open => self.chunks.items.len != 0,
            .complete, .failed => true,
        };
    }

    fn takeWaiter(self: *Body) ?Waiter {
        const waiter = self.waiter;
        self.waiter = null;
        return waiter;
    }

    fn takePullWaiter(self: *Body) ?PullWaiter {
        const waiter = self.pull_waiter;
        self.pull_waiter = null;
        return waiter;
    }

    fn liveChunks(self: *Body) []Chunk {
        return self.chunks.items[self.chunks_head..];
    }

    /// Queues `chunk` into capacity the caller reserved.
    fn queueAssumeCapacity(self: *Body, chunk: Chunk) void {
        self.chunks.appendAssumeCapacity(chunk);
        self.queued_bytes += chunk.bytes.len;
    }

    /// Moves the live chunks out and leaves the queue empty.
    fn takeChunks(self: *Body) std.ArrayListUnmanaged(Chunk) {
        var chunks = self.chunks;
        if (self.chunks_head != 0) {
            const live = chunks.items.len - self.chunks_head;
            std.mem.copyForwards(Chunk, chunks.items[0..live], chunks.items[self.chunks_head..]);
            chunks.shrinkRetainingCapacity(live);
        }
        self.chunks = .empty;
        self.chunks_head = 0;
        self.queued_bytes = 0;
        return chunks;
    }

    fn dropChunks(self: *Body, allocator: std.mem.Allocator) void {
        var chunks = self.takeChunks();
        defer chunks.deinit(allocator);
        for (chunks.items) |*chunk|
            chunk.deinit(allocator);
    }

    /// Minimum drained prefix before a compaction is worth it.
    const chunk_compact_min: usize = 8;

    /// Pops the front chunk in O(1) amortized: the head moves forward, the
    /// list resets when it empties, and the drained prefix is compacted once
    /// it outnumbers the live chunks.
    fn popFront(self: *Body) Chunk {
        std.debug.assert(self.chunks_head < self.chunks.items.len);
        const front = self.chunks.items[self.chunks_head];
        self.chunks_head += 1;
        const len = self.chunks.items.len;
        if (self.chunks_head == len) {
            self.chunks.clearRetainingCapacity();
            self.chunks_head = 0;
        } else if (self.chunks_head >= chunk_compact_min and self.chunks_head > len - self.chunks_head) {
            const live = len - self.chunks_head;
            std.mem.copyForwards(Chunk, self.chunks.items[0..live], self.chunks.items[self.chunks_head..]);
            self.chunks.shrinkRetainingCapacity(live);
            self.chunks_head = 0;
        }
        std.debug.assert(front.bytes.len <= self.queued_bytes);
        self.queued_bytes -= front.bytes.len;
        return front;
    }

    fn assertOwnerThread(self: *const Body) void {
        if (std.debug.runtime_safety)
            std.debug.assert(self.owner_thread == currentThread());
    }
};

fn currentThread() ThreadId {
    return if (std.debug.runtime_safety) std.Thread.getCurrentId() else {};
}

comptime {
    // Only the gateway's queue carries flow-control credits and a lock; a
    // worker body holds neither.
    std.debug.assert(!@hasField(Body, "mutex"));
    std.debug.assert(!@hasField(Chunk, "credit"));
}
