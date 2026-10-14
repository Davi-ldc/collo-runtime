//! The gateway's queue of one fetch's response body chunks, from the
//! transport engine to the gateway loop, which publishes them into the
//! worker's body pool. The engine's owner thread appends chunks and ends the
//! queue; the loop thread arms, pulls, cancels and drops the queue. They meet
//! under `mutex`, except the queued byte count, which the engine reads
//! without it, and the reference count. A worker never sees this type: its
//! fetch body lives in `worker/egress/body/`.
//!
//! Every chunk owns its bytes, allocated with the allocator its producer
//! passes, and carries the flow-control credit it returns to the engine once
//! the loop took it (`body_credit.zig`). A credit-only chunk has no bytes;
//! the engine queues one where a zero-byte DATA frame must still reach the
//! loop, since its credit is what surfaces the stream's end. Each pull moves
//! at most one chunk, so each credit leaves exactly once, either with a pull
//! or through `releaseQueued`.
//!
//! The loop arms the queue when it waits for more (`armPull`). While armed,
//! every producer event that leaves something to pull answers true, and the
//! engine then wakes the loop; a pull that hands out bytes or the end consumes
//! the arm. A pull of an unarmed queue moves nothing, so the loop decides when
//! it takes chunks, and the engine's wakes stay one per arm at most.
//!
//! Only the engine moves `state` off `open`, with `complete` or `fail`, and it
//! does so exactly when it lets go of the fetch whose head it published; no
//! engine thread appends after that. The loop reads the end as the engine's
//! settlement of the fetch (`producerEnded`), which tells it when a fetch it
//! stopped no longer holds anything in the engine. The loop's own `cancel`
//! therefore leaves `state` alone: it refuses the engine's later appends and
//! arms the queue, so the engine's end, which then answers true, wakes the
//! loop whenever it comes.
//!
//! A queue is reference counted: the engine's task holds one reference and
//! the loop's record of the fetch another. Before the last release, the loop
//! returns every queued chunk's credit through `releaseQueued`; freeing
//! asserts an empty queue.

const std = @import("std");
const common_io = @import("collo_common_io");
const body_credit = @import("body_credit.zig");

pub const Credit = body_credit.Handle;

/// Names one fetch body to the gateway's engine, which matches a cancel to
/// the stream that feeds it by all four fields. The layout is that of
/// `ColloFetchBodyIdentity` in `abi.h`, the worker's name for the same body.
pub const FetchBodyIdentity = extern struct {
    request_id: u64,
    request_generation: u64,
    fetch_id: u64,
    body_id: u64,
};

pub const State = enum {
    open,
    complete,
    failed,
};

/// What one `pull` moved out of the queue. The caller owns `bytes`, which it
/// frees with the allocator the producer appended them with, the one it
/// passes to `pull`, and returns `credit` to the engine.
pub const Pull = struct {
    /// The chunk's bytes, never empty; null when the pull moved no bytes.
    bytes: ?[]u8 = null,
    /// The credit of the chunk this pull moved; `.none` when it moved no
    /// chunk or the chunk carried none.
    credit: Credit = .none,
    /// The queue completed and nothing follows.
    done: bool = false,
    /// The queue failed and nothing follows; `failureMessage` says why.
    failed: bool = false,
    /// This pull consumed the arm; the loop arms again before it waits.
    disarmed: bool = false,

    /// Whether the pull moved nothing and the queue has nothing to pull now.
    pub fn isEmpty(self: Pull) bool {
        return self.bytes == null and self.credit.isNone() and !self.done and !self.failed;
    }
};

const Chunk = struct {
    bytes: []u8,
    credit: Credit,
};

pub const ResponseQueue = struct {
    /// Changed atomically without the mutex; see `release`.
    refs: std.atomic.Value(u32) = .init(1),
    mutex: std.Thread.Mutex = .{},
    identity: FetchBodyIdentity,
    /// The producer's end of the queue; only `complete` and `fail` move it.
    state: State = .open,
    /// Set by the loop's `cancel`: the queue refuses appends whatever `state`
    /// says, and a pull hands out what a failed queue does.
    canceled: bool = false,
    /// Queued chunks from `chunks_head` on; entries below it were pulled. A
    /// pull that empties the queue resets both, so `chunks.items.len != 0`
    /// means the queue holds a chunk.
    chunks: std.ArrayListUnmanaged(Chunk) = .empty,
    chunks_head: usize = 0,
    /// The byte limit the queue was created with and the bytes appended so
    /// far.
    max_buf: common_io.buffer.MaxBuf,
    /// Bytes in queued chunks. Written under the mutex, read without it by
    /// the engine (`queuedBytes`).
    queued_bytes: std.atomic.Value(usize) = .init(0),
    pull_armed: bool = false,
    error_message: ?[]u8 = null,

    /// An open, empty queue holding one reference. `max_bytes` caps the bytes
    /// it accepts; null means no cap.
    pub fn init(identity: FetchBodyIdentity, max_bytes: ?u64) ResponseQueue {
        return .{
            .identity = identity,
            .max_buf = common_io.buffer.MaxBuf.init(max_bytes),
        };
    }

    /// Frees the queue's own storage; every queued chunk must already be
    /// gone (`releaseQueued`), which is asserted.
    pub fn deinit(self: *ResponseQueue, allocator: std.mem.Allocator) void {
        std.debug.assert(self.chunks.items.len == 0);
        std.debug.assert(self.chunks_head == 0);
        std.debug.assert(self.queued_bytes.load(.monotonic) == 0);
        self.chunks.deinit(allocator);
        if (self.error_message) |message|
            allocator.free(message);
        self.* = undefined;
    }

    pub fn retain(self: *ResponseQueue) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Drops one reference and frees a heap-allocated queue at the last one,
    /// under the condition of `deinit`.
    pub fn release(self: *ResponseQueue, allocator: std.mem.Allocator) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1)
            return;
        self.deinit(allocator);
        allocator.destroy(self);
    }

    /// Queues `bytes`, allocated with `allocator`, with `credit`; empty bytes
    /// with a credit queue a credit-only chunk, and empty bytes without one
    /// queue nothing. On success the queue owns `bytes`; on error the caller
    /// still owns `bytes` and `credit`. Returns whether the loop must be woken
    /// (the queue is armed). Fails with `error.FetchBodyNotWritable` once the
    /// queue left `open` or the loop canceled it, `error.MaxBufferExceeded`
    /// past its byte limit, or `error.OutOfMemory`.
    pub fn appendOwnedChunk(
        self: *ResponseQueue,
        allocator: std.mem.Allocator,
        bytes: []u8,
        credit: Credit,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .open or self.canceled)
            return error.FetchBodyNotWritable;
        if (bytes.len == 0 and credit.isNone())
            return false;
        try self.max_buf.checkBytes(bytes.len);
        try self.chunks.append(allocator, .{ .bytes = bytes, .credit = credit });
        self.max_buf.onBytesAssumeChecked(bytes.len);
        self.queued_bytes.store(self.queued_bytes.load(.monotonic) + bytes.len, .monotonic);
        return self.pull_armed;
    }

    /// Ends the queue: what is queued is the whole body, and the engine lets
    /// go of the fetch. A failed queue stays failed. Returns whether the loop
    /// must be woken, which a canceled queue always answers.
    pub fn complete(self: *ResponseQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state == .open)
            self.state = .complete;
        return self.pull_armed;
    }

    /// Fails an open queue with a copy of `message`, as the engine lets go of
    /// the fetch; a complete or failed queue keeps its state, so bytes that
    /// fully arrived stay deliverable and the first failure stays. Without
    /// memory for the copy the queue still fails, with no message. Returns
    /// whether the loop must be woken, which a canceled queue always answers.
    pub fn fail(self: *ResponseQueue, allocator: std.mem.Allocator, message: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .open)
            return false;
        std.debug.assert(self.error_message == null);
        self.error_message = allocator.dupe(u8, message) catch |err| switch (err) {
            // The queue fails all the same; the loop sends a generic text.
            error.OutOfMemory => null,
        };
        self.state = .failed;
        return self.pull_armed;
    }

    /// The loop gives the queue up: the engine's later appends are refused,
    /// which makes it reset the stream that feeds the queue, and the queue is
    /// armed, so the engine's `complete` or `fail` wakes the loop. `state`
    /// stays the producer's. Returns whether the producer had already ended
    /// the queue, decided under the same lock as the arm, so a false answer
    /// guarantees a wake when the engine ends it. The loop also asks the
    /// engine to stop the fetch (`Engine.cancel`) and returns the queued
    /// credits with `releaseQueued`.
    pub fn cancel(self: *ResponseQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.canceled = true;
        self.pull_armed = true;
        return self.state != .open;
    }

    /// Whether the engine ended the queue (`complete` or `fail`), after which
    /// it holds nothing of the fetch that fed it.
    pub fn producerEnded(self: *ResponseQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state != .open;
    }

    /// Bytes in queued chunks, read without the mutex on the engine's owner
    /// thread, which sizes appends and decides whether consumer backpressure
    /// holds a stream from it. A stale read is at most one wake behind.
    pub fn queuedBytes(self: *const ResponseQueue) usize {
        return self.queued_bytes.load(.monotonic);
    }

    /// The byte limit the queue was created with, or null for none. The
    /// gateway resolves it per fetch and copies it into the fetch head, so
    /// the worker's decoder enforces the same decoded limit.
    pub fn maxBytes(self: *const ResponseQueue) ?u64 {
        return self.max_buf.budget.limit;
    }

    /// The message of a failed queue, or null. The slice stays valid until
    /// the queue is freed.
    pub fn failureMessage(self: *ResponseQueue) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .failed)
            return null;
        return self.error_message;
    }

    /// Arms the queue for the loop, which then waits for a wake. Returns true
    /// when something is already there to pull, so the loop pulls at once
    /// instead of waiting.
    pub fn armPull(self: *ResponseQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pull_armed = true;
        return self.hasPullLocked();
    }

    /// Moves out the next chunk of an armed queue, credit-only chunks
    /// included, or reports the end once the queue is empty and complete or
    /// failed. A failed or canceled queue frees the bytes of the chunks still
    /// queued, which the worker never gets, and hands out their credits, one
    /// per pull, skipping chunks that carry none, so each of its pulls
    /// returns a credit or `failed`. An unarmed queue moves nothing. Never
    /// allocates.
    pub fn pull(self: *ResponseQueue, allocator: std.mem.Allocator) Pull {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.pull_armed)
            return .{};
        if (self.state == .failed or self.canceled) {
            while (self.chunks.items.len != 0) {
                const chunk = self.popFrontLocked();
                allocator.free(chunk.bytes);
                if (!chunk.credit.isNone())
                    return .{ .credit = chunk.credit };
            }
            self.pull_armed = false;
            return .{ .failed = true, .disarmed = true };
        }
        if (self.chunks.items.len != 0) {
            const chunk = self.popFrontLocked();
            // A chunk without bytes always carries a credit
            // (`appendOwnedChunk`).
            if (chunk.bytes.len == 0)
                return .{ .credit = chunk.credit };
            self.pull_armed = false;
            return .{ .bytes = chunk.bytes, .credit = chunk.credit, .disarmed = true };
        }
        if (self.state == .open)
            return .{};
        std.debug.assert(self.state == .complete);
        self.pull_armed = false;
        return .{ .done = true, .disarmed = true };
    }

    /// Frees every queued chunk and passes each credit it carried to
    /// `callback`, after the mutex is released, so the callback may re-enter
    /// the engine. Never allocates.
    pub fn releaseQueued(
        self: *ResponseQueue,
        allocator: std.mem.Allocator,
        context: anytype,
        comptime callback: fn (@TypeOf(context), Credit) void,
    ) void {
        self.mutex.lock();
        var chunks = self.chunks;
        const chunks_head = self.chunks_head;
        self.chunks = .empty;
        self.chunks_head = 0;
        self.queued_bytes.store(0, .monotonic);
        self.mutex.unlock();

        for (chunks.items[chunks_head..]) |chunk| {
            allocator.free(chunk.bytes);
            if (!chunk.credit.isNone())
                callback(context, chunk.credit);
        }
        chunks.deinit(allocator);
    }

    fn hasPullLocked(self: *const ResponseQueue) bool {
        return self.chunks.items.len != 0 or self.state != .open or self.canceled;
    }

    /// Minimum pulled prefix before a compaction is worth it.
    const chunk_compact_min: usize = 8;

    /// Pops the front chunk in O(1) amortized: the head moves forward, the
    /// list resets when it empties, and the pulled prefix is compacted once
    /// it outnumbers the live chunks, which bounds the dead entries a
    /// long-lived queue holds.
    fn popFrontLocked(self: *ResponseQueue) Chunk {
        std.debug.assert(self.chunks_head < self.chunks.items.len);
        const chunk = self.chunks.items[self.chunks_head];
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
        const queued = self.queued_bytes.load(.monotonic);
        std.debug.assert(chunk.bytes.len <= queued);
        self.queued_bytes.store(queued - chunk.bytes.len, .monotonic);
        return chunk;
    }
};
