//! The body of a fetch response: the decoded byte queue a `Response` reads,
//! with its terminal state, its tee links and its meters. This file owns the
//! fields and their invariants; the methods live in `body_append.zig`,
//! `body_settlement.zig`, `body_state.zig` and `body_tee.zig`.
//!
//! The type serves both processes. In the gateway, the transport engine's
//! owner thread appends chunks and folds meters while the gateway loop pulls
//! and releases them. In the worker, the event loop thread both feeds every
//! body from gateway packets and reads it. Fields change under `mutex` unless
//! their own comment says otherwise. When several bodies are locked together,
//! a tee root is locked before any of its branches.
//!
//! A body is reference counted. Before the last release, the caller must
//! release every queued chunk and detach every tee link; freeing asserts both.

const std = @import("std");
const bindings = @import("collo_bindings");
const body_append = @import("body_append.zig");
const body_chunks = @import("body_chunks.zig");
const body_credits = @import("body_credits.zig");
const body_settlement = @import("body_settlement.zig");
const body_state = @import("body_state.zig");
const body_tee_mod = @import("body_tee.zig");
const common_io = @import("collo_common_io");

pub const ReadKind = body_settlement.ReadKind;
pub const Credit = body_credits.Credit;
pub const BorrowedChunkRelease = body_chunks.BorrowedChunkRelease;
pub const BorrowedChunk = body_chunks.BorrowedChunk;
pub const ByteLease = body_chunks.ByteLease;
pub const Chunk = body_chunks.Chunk;
pub const Waiter = body_settlement.Waiter;
pub const PullWaiter = body_settlement.PullWaiter;
pub const Drain = body_settlement.Drain;
pub const PullDrain = body_settlement.PullDrain;
pub const PullCredits = body_settlement.PullCredits;

pub const State = enum {
    open,
    complete,
    failed,
};

/// The three meters a fetch body carries. Each is an absolute running total
/// set by maximum, so a repeated or stale fold changes nothing.
/// - `billed_sent` and `billed_received` count HTTP payload per direction,
///   never TLS. HTTP/2 counts header blocks and DATA payload, without
///   framing, padding or interim 1xx blocks. HTTP/1 counts the serialized
///   head and body as they cross the connection, chunked framing included,
///   minus interim 1xx heads. A redirect chain sums its hops; a retried
///   attempt's bytes are dropped here and its ciphertext stays in `cost`.
/// - `cost` counts transport ciphertext observed at the memory-BIO boundary.
///   Plain HTTP and `.fd_tls` HTTP/1 connections have no such boundary, so
///   cost stays 0 there; the conservation alarm only evaluates where
///   cost > 0.
pub const EgressMeters = struct {
    billed_sent: u64 = 0,
    billed_received: u64 = 0,
    cost: u64 = 0,

};

pub const Body = struct {
    pub const Waiter = body_settlement.Waiter;
    pub const PullWaiter = body_settlement.PullWaiter;
    pub const Drain = body_settlement.Drain;
    pub const PullDrain = body_settlement.PullDrain;

    /// Reference count, changed atomically without the mutex; see
    /// `releaseAfterQueuedResourcesReleased`.
    refs: std.atomic.Value(u32) = .init(1),
    mutex: std.Thread.Mutex = .{},
    queue_condition: std.Thread.Condition = .{},
    identity: bindings.FetchBodyIdentity,
    state: State,
    /// The materialized body. Only the consumer thread writes it, and a
    /// waiter drain does so without the mutex (see `drainReadyForWaiter`).
    bytes: common_io.buffer.StreamBuffer,
    chunks: std.ArrayListUnmanaged(Chunk) = .empty,
    /// Index of the first live entry of `chunks`; entries below it were
    /// already popped and freed. A front pop advances it instead of shifting
    /// the list. Either `chunks_head < chunks.items.len` or both are zero,
    /// because the pop path resets the cursor when the queue empties, so
    /// `chunks.items.len != 0` stays a correct emptiness check. Code that
    /// iterates or clears the queue must use `chunks.items[chunks_head..]` and
    /// reset the cursor. The pop helpers in `body_settlement.zig` keep it.
    chunks_head: usize = 0,
    max_buf: common_io.buffer.MaxBuf,
    queued_chunk_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    consumed: bool = false,
    streaming: bool = false,
    waiter: ?body_settlement.Waiter = null,
    pull_waiter: ?body_settlement.PullWaiter = null,
    error_message: ?[]u8 = null,
    abort_reason: ?bindings.Value = null,
    ready_queued: bool = false,
    view_released: bool = false,
    /// CLOCK_MONOTONIC time at which the gateway published the packet (chunk
    /// batch, body end or fetch error) that first made this body readable
    /// since the worker last ran its ready task for it; 0 when no gateway
    /// packet made it readable, as in teardown, cancel or cleanup. Worker
    /// only, read and written on its event loop without the mutex. The
    /// `fetch_body_ready` enqueue carries it, so the request's io interval
    /// closes when the data became ready, not when it was drained.
    ready_at_mono_ns: u64 = 0,
    /// Meter totals, atomic so the engine owner thread can fold them once per
    /// DATA frame without contending with the consumer for `mutex`. Every fold
    /// carries an absolute total and each field only grows through
    /// `fetchMax`, so `.monotonic` ordering suffices for each field; a
    /// snapshot of all three goes through `egress_meters_version`.
    /// `egress_meters_accounted` stays under `mutex`, so concurrent
    /// `takeUnaccountedEgressMeters` calls never count one delta twice.
    egress_meters_billed_sent: std.atomic.Value(u64) = .init(0),
    egress_meters_billed_received: std.atomic.Value(u64) = .init(0),
    egress_meters_cost: std.atomic.Value(u64) = .init(0),
    /// Sequence counter over the three meters, odd while a fold is writing.
    /// The packets that end a fetch, the gateway's body end and error, carry
    /// a snapshot taken through it; a fold racing an unguarded snapshot could
    /// ship a torn trio, such as a new `billed_sent` beside an old
    /// `billed_received`, that no later packet corrects. The check needs one
    /// thread to fold a body's meters: the engine owner thread in the
    /// gateway, the event loop in the worker. It also needs a release fence
    /// after the fold's first increment and an acquire fence before the
    /// snapshot's second version load. Neither is there: the field stores are
    /// not ordered after the first `.release` increment, and the field loads
    /// are not ordered before the second `.acquire` load, so a torn snapshot
    /// can still pass with an even, unchanged version on a weakly ordered
    /// target such as ARM64.
    egress_meters_version: std.atomic.Value(u64) = .init(0),
    egress_meters_accounted: EgressMeters = .{},
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tee_root: ?*Body = null,
    tee_branches: std.ArrayListUnmanaged(*Body) = .empty,

    /// An open, empty body holding one reference. `max_bytes` caps the bytes
    /// it accepts; null means no cap.
    pub fn initOpen(
        allocator: std.mem.Allocator,
        identity: bindings.FetchBodyIdentity,
        max_bytes: ?u64,
    ) Body {
        return .{
            .identity = identity,
            .state = .open,
            .bytes = common_io.buffer.StreamBuffer.initDefault(allocator),
            .max_buf = common_io.buffer.MaxBuf.init(max_bytes),
        };
    }

    /// A complete body holding a copy of `bytes`. Fails with
    /// `error.MaxBufferExceeded` when `bytes` exceed `max_bytes`, or
    /// `error.OutOfMemory`.
    pub fn initComplete(
        allocator: std.mem.Allocator,
        identity: bindings.FetchBodyIdentity,
        bytes: []const u8,
        max_bytes: ?u64,
    ) !Body {
        var body = initOpen(allocator, identity, max_bytes);
        errdefer body.deinitAfterQueuedResourcesReleased(allocator);
        try body.append(bytes);
        _ = body.complete();
        return body;
    }

    /// Frees the body's own storage. Every queued chunk must already be
    /// released and every tee link detached; both are asserted.
    pub fn deinitAfterQueuedResourcesReleased(
        self: *Body,
        allocator: std.mem.Allocator,
    ) void {
        std.debug.assert(self.tee_root == null);
        std.debug.assert(self.tee_branches.items.len == 0);
        std.debug.assert(self.chunks.items.len == 0);
        std.debug.assert(self.chunks_head == 0);
        std.debug.assert(self.queued_chunk_bytes.load(.monotonic) == 0);
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

    pub fn isTeeBranch(self: *Body) bool {
        return body_tee_mod.Methods(Body).isBranch(self);
    }

    pub fn detachTeeLinks(self: *Body, allocator: std.mem.Allocator) void {
        body_tee_mod.Methods(Body).detachLinks(self, allocator);
    }

    pub fn hasTeeBranches(self: *Body) bool {
        return body_tee_mod.Methods(Body).hasBranches(self);
    }

    pub fn shouldKeepReleasedSource(self: *Body) bool {
        return body_tee_mod.Methods(Body).shouldKeepReleasedSource(self);
    }

    pub fn canRemoveReleasedSource(self: *Body) bool {
        return body_tee_mod.Methods(Body).canRemoveReleasedSource(self);
    }

    pub fn isRootView(self: *Body) bool {
        return body_tee_mod.Methods(Body).isRootView(self);
    }

    /// Marks this view released: no reader can start, and any registered
    /// reader is dropped.
    pub fn markViewReleased(self: *Body, allocator: std.mem.Allocator) void {
        self.markViewReleasedWithOptions(allocator, true);
    }

    /// As `markViewReleased`, but a registered reader stays and is still
    /// answered when the body settles.
    pub fn markViewReleasedPreservingWaiters(self: *Body, allocator: std.mem.Allocator) void {
        self.markViewReleasedWithOptions(allocator, false);
    }

    fn markViewReleasedWithOptions(self: *Body, allocator: std.mem.Allocator, comptime drop_waiters: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.view_released = true;
        self.consumed = true;
        self.streaming = false;
        self.ready_queued = false;
        self.queue_condition.broadcast();
        if (drop_waiters) {
            if (self.waiter) |*stored| {
                stored.deinit(allocator);
                self.waiter = null;
            }
            if (self.pull_waiter) |*stored| {
                stored.deinit();
                self.pull_waiter = null;
            }
        }
    }

    pub fn hasPendingWaiter(self: *Body) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waiter != null or self.pull_waiter != null;
    }

    pub fn viewReleased(self: *Body) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.view_released;
    }

    pub fn sourceCancelIdentityAfterViewRelease(self: *Body) ?bindings.FetchBodyIdentity {
        return body_tee_mod.Methods(Body).sourceCancelIdentityAfterViewRelease(self);
    }

    pub fn sourceIdentity(self: *Body) bindings.FetchBodyIdentity {
        return body_tee_mod.Methods(Body).sourceIdentity(self);
    }

    pub fn retain(self: *Body) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Drops one reference and frees a heap-allocated body at the last one,
    /// under the conditions of `deinitAfterQueuedResourcesReleased`.
    pub fn releaseAfterQueuedResourcesReleased(self: *Body, allocator: std.mem.Allocator) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1)
            return;
        self.deinitAfterQueuedResourcesReleased(allocator);
        allocator.destroy(self);
    }

    pub fn append(self: *Body, bytes: []const u8) !void {
        return body_append.Methods(Body).append(self, bytes);
    }

    pub fn appendOwnedChunk(
        self: *Body,
        allocator: std.mem.Allocator,
        bytes: []u8,
        credit: Credit,
    ) !bool {
        return body_append.Methods(Body).appendOwnedChunk(self, allocator, bytes, credit);
    }

    pub fn appendBorrowedChunk(
        self: *Body,
        allocator: std.mem.Allocator,
        borrowed: BorrowedChunk,
        credit: Credit,
    ) !bool {
        return body_append.Methods(Body).appendBorrowedChunk(self, allocator, borrowed, credit);
    }

    pub fn complete(self: *Body) bool {
        return body_state.Methods(Body).complete(self);
    }

    pub fn fail(self: *Body, allocator: std.mem.Allocator, message: []const u8) !bool {
        return body_state.Methods(Body).fail(self, allocator, message);
    }

    pub fn failNoAlloc(self: *Body) bool {
        return body_state.Methods(Body).failNoAlloc(self);
    }

    pub fn cancel(self: *Body, allocator: std.mem.Allocator, message: []const u8, reason: ?bindings.Value) !bool {
        return body_state.Methods(Body).cancel(self, allocator, message, reason);
    }

    pub fn cancelNoAlloc(self: *Body) bool {
        return body_state.Methods(Body).cancelNoAlloc(self);
    }

    pub fn cancelViewOnly(self: *Body, allocator: std.mem.Allocator, message: []const u8, reason: ?bindings.Value) !bool {
        return body_state.Methods(Body).cancelViewOnly(self, allocator, message, reason);
    }

    pub fn cancelViewOnlyNoAlloc(self: *Body) bool {
        return body_state.Methods(Body).cancelViewOnlyNoAlloc(self);
    }

    /// Folds absolute totals into the meters, keeping the maximum of each
    /// field, so a repeated or stale fold (a redirect re-publish, a deferred
    /// `.end` after the last chunk) changes nothing and never counts twice.
    /// Takes no lock; only one thread may fold a body's meters (see
    /// `egress_meters_version`).
    pub fn setEgressMeters(self: *Body, meters: EgressMeters) void {
        // An odd version brackets the fold so an overlapping snapshot can
        // detect it and retry. No fence orders the field stores after the
        // first increment, so detection can miss an overlap; see
        // `egress_meters_version`.
        _ = self.egress_meters_version.fetchAdd(1, .release);
        _ = self.egress_meters_billed_sent.fetchMax(meters.billed_sent, .monotonic);
        _ = self.egress_meters_billed_received.fetchMax(meters.billed_received, .monotonic);
        _ = self.egress_meters_cost.fetchMax(meters.cost, .monotonic);
        _ = self.egress_meters_version.fetchAdd(1, .release);
    }

    /// A snapshot of the three meters, read again while the version shows a
    /// fold overlapping it. After a bounded number of attempts it returns the
    /// last read. The version check misses some overlaps (see
    /// `egress_meters_version`), so any result may be torn, but none
    /// overstates: each field is a real total from some instant, so a torn
    /// snapshot can only undercount.
    pub fn egressMetersTotal(self: *Body) EgressMeters {
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            const before = self.egress_meters_version.load(.acquire);
            const snapshot = EgressMeters{
                .billed_sent = self.egress_meters_billed_sent.load(.monotonic),
                .billed_received = self.egress_meters_billed_received.load(.monotonic),
                .cost = self.egress_meters_cost.load(.monotonic),
            };
            const after = self.egress_meters_version.load(.acquire);
            if (before == after and before % 2 == 0)
                return snapshot;
            if (attempts >= 16)
                return snapshot;
        }
    }

    /// Returns the growth of the meters since the previous call, so a caller
    /// that sums the deltas counts each byte once. A tee branch answers
    /// through its root, which owns the meters.
    pub fn takeUnaccountedEgressMeters(self: *Body) EgressMeters {
        self.mutex.lock();
        if (self.tee_root) |root| {
            self.mutex.unlock();
            return root.takeUnaccountedEgressMeters();
        }
        defer self.mutex.unlock();
        const total = self.egressMetersTotal();
        const delta = EgressMeters{
            .billed_sent = total.billed_sent -| self.egress_meters_accounted.billed_sent,
            .billed_received = total.billed_received -| self.egress_meters_accounted.billed_received,
            .cost = total.cost -| self.egress_meters_accounted.cost,
        };
        self.egress_meters_accounted = total;
        return delta;
    }

    pub fn releaseQueuedChunksCallback(
        self: *Body,
        allocator: std.mem.Allocator,
        context: anytype,
        comptime callback: fn (@TypeOf(context), Credit) void,
    ) void {
        body_settlement.Methods(Body).releaseQueuedChunksCallback(self, allocator, context, callback);
    }

    pub fn releaseQueuedChunksPreservingWaitersCallback(
        self: *Body,
        allocator: std.mem.Allocator,
        context: anytype,
        comptime callback: fn (@TypeOf(context), Credit) void,
    ) void {
        body_settlement.Methods(Body).releaseQueuedChunksPreservingWaitersCallback(
            self,
            allocator,
            context,
            callback,
        );
    }

    pub fn beginConsume(self: *Body, waiter: body_settlement.Waiter) !bool {
        return body_settlement.Methods(Body).beginConsume(self, waiter);
    }

    pub fn beginPull(self: *Body, waiter: body_settlement.PullWaiter) !bool {
        return body_settlement.Methods(Body).beginPull(self, waiter);
    }

    pub fn drainReadyForPull(self: *Body, allocator: std.mem.Allocator) !body_settlement.PullDrain {
        return body_settlement.Methods(Body).drainReadyForPull(self, allocator);
    }

    pub fn drainReadyForWaiter(self: *Body, allocator: std.mem.Allocator) !body_settlement.Drain {
        return body_settlement.Methods(Body).drainReadyForWaiter(self, allocator);
    }

    pub fn rollbackPendingConsume(self: *Body, allocator: std.mem.Allocator) void {
        body_settlement.Methods(Body).rollbackPendingConsume(self, allocator);
    }

    pub fn rollbackPendingPull(self: *Body) void {
        body_settlement.Methods(Body).rollbackPendingPull(self);
    }

    pub fn clearReadyQueued(self: *Body) void {
        body_settlement.Methods(Body).clearReadyQueued(self);
    }

    /// Bytes queued in chunks, read without the mutex on the engine owner
    /// thread: the HTTP/1 pump sizes each append from it
    /// (`availableDecodedCapacityFor` in `stream_pump.zig`), and the engine
    /// reads it whenever it rebuilds the watch list or a consumer releases
    /// credit, to decide whether consumer backpressure suspends an HTTP/2
    /// stream's stall clock (`Pending.pausedByBodyBackpressure` in
    /// `egress/client/engine/h2_types.zig`). Writers change it under the
    /// mutex. A stale read is at most one wake behind, which the credit
    /// protocol and the driver's watchdog tick bound.
    pub fn queuedDecodedBytes(self: *Body) usize {
        return self.queued_chunk_bytes.load(.monotonic);
    }

    /// The byte limit this body was created with, or null for none. The
    /// gateway resolves it per fetch from the request's ask and its own limit
    /// (`resolveMaxResponseBodyBytes` in `egress/gateway/policy.zig`)
    /// and copies it into the fetch head, so the worker's decoder enforces
    /// the same decoded limit the gateway would.
    pub fn maxDecodedBytes(self: *const Body) ?u64 {
        return self.max_buf.budget.limit;
    }

    /// Blocks until `bytes`, capped at `max_pending_decoded_bytes`, fit under
    /// the pending watermark, checking `cancel_probe.isCanceled()` between
    /// timed waits. Fails with `error.FetchAborted` on cancel and
    /// `error.FetchBodyNotWritable` once the body leaves `open`.
    pub fn waitForDecodedCapacity(
        self: *Body,
        bytes: usize,
        max_pending_decoded_bytes: usize,
        cancel_probe: anytype,
    ) !void {
        if (bytes == 0)
            return;
        while (true) {
            if (cancel_probe.isCanceled())
                return error.FetchAborted;
            self.mutex.lock();
            if (self.state != .open) {
                self.mutex.unlock();
                return error.FetchBodyNotWritable;
            }
            const needed_capacity = @min(bytes, max_pending_decoded_bytes);
            if (needed_capacity <= max_pending_decoded_bytes -| self.queued_chunk_bytes.load(.monotonic)) {
                self.mutex.unlock();
                return;
            }
            self.queue_condition.timedWait(&self.mutex, 10 * std.time.ns_per_ms) catch |err| switch (err) {
                error.Timeout => {},
            };
            self.mutex.unlock();
        }
    }

    pub fn isReadyForWaiter(self: *Body) bool {
        return body_settlement.Methods(Body).isReadyForWaiter(self);
    }

    pub fn takeReadyWaiter(self: *Body) ?body_settlement.Waiter {
        return body_settlement.Methods(Body).takeReadyWaiter(self);
    }

    pub fn isFailed(self: *Body) bool {
        return body_state.Methods(Body).isFailed(self);
    }

    pub fn isCanceled(self: *Body) bool {
        return body_state.Methods(Body).isCanceled(self);
    }

    pub fn failureMessage(self: *Body) ?[]const u8 {
        return body_state.Methods(Body).failureMessage(self);
    }

    pub fn failureReasonRetained(self: *Body) ?bindings.Value {
        return body_state.Methods(Body).failureReasonRetained(self);
    }

    fn isReadyForWaiterLocked(self: *const Body) bool {
        return self.isReadyForConsumeLocked() or self.isReadyForPullLocked();
    }

    fn isReadyForConsumeLocked(self: *const Body) bool {
        if (self.waiter == null)
            return false;
        return switch (self.state) {
            .open => self.chunks.items.len != 0,
            .complete, .failed => true,
        };
    }

    fn isReadyForPullLocked(self: *const Body) bool {
        if (self.pull_waiter == null)
            return false;
        return switch (self.state) {
            .open => self.chunks.items.len != 0,
            .complete, .failed => true,
        };
    }

    pub fn claimReadyForQueue(self: *Body) bool {
        return body_settlement.Methods(Body).claimReadyForQueue(self);
    }

    /// The materialized bytes of a complete body, without consuming it, or
    /// null before completion. Chunks still queued are not in the slice until
    /// a waiter drain copies them in.
    pub fn borrowCompleteBytes(self: *Body) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .complete)
            return null;
        return self.bytes.slice();
    }

    pub fn cloneBranch(
        self: *Body,
        allocator: std.mem.Allocator,
        identity: bindings.FetchBodyIdentity,
    ) !*Body {
        return body_append.Methods(Body).cloneBranch(self, allocator, identity);
    }
};
