//! HTTP/2 on the owner thread: a hop opens a stream on a pooled entry of its
//! origin, or waits for its origin's dial, a pool slot or a retry; each
//! entry's events go to its streams; consumer credits reopen flow-control
//! windows; redirects, transparent retries and expiry end or restart streams.
//!
//! A stream runs two clocks. The stall clock (`socket_timeout_ms`) measures
//! only time spent waiting on the origin and restarts on origin progress;
//! the total request deadline (0 when the fetch has none) caps the whole
//! fetch. While the engine waits on its own consumer instead of the origin,
//! the stall clock is suspended and only the total deadline applies. A stream
//! holds its hop, whose task reference keeps the response queue alive after
//! the head's publication, when the gateway may retire the fetch, and a
//! credit source (`credit_sources.zig`) from its start to its end.
//!
//! A stream is retried on a fresh connection, at most `max_stream_retries`
//! times per fetch, only when the server guarantees it never processed it
//! (REFUSED_STREAM, a GOAWAY that excludes it), or when it rode a reused
//! session that proved dead before any response byte and the request is
//! idempotent without a body. Every removal of an entry goes through the
//! data driver (`Pool.removeEntry`).
//!
//! Thread: the engine's owner thread alone.

const std = @import("std");
const core = @import("collo_egress_core");
const http2 = @import("../transport/h2/codec/root.zig");
const pool_mod = @import("../transport/h2/pool.zig");
const transport = @import("../transport/root.zig");
const task_model = @import("../task.zig");
const owner_mod = @import("owner.zig");
const result = @import("result.zig");
const dial = @import("dial.zig");
const credit_sources = @import("credit_sources.zig");

const decompress = core.decompress;
const stream_pump = core.stream_pump;
const Hop = owner_mod.Hop;
const Owner = owner_mod.Owner;
const ResponseQueue = core.ResponseQueue;
const Task = task_model.Task;
const monotonicNowNs = transport.config.monotonicNowNs;

/// Transparent retry budget per fetch, matching Bun's max_h2_retries.
const max_stream_retries: u8 = 5;

pub const Stream = struct {
    hop: Hop,
    handle: pool_mod.StreamHandle,
    /// The stall deadline: `socket_timeout_ms` from the last origin
    /// progress, bounded by the total request deadline. Every response head,
    /// body chunk and unpause restarts it, so only an origin silence of
    /// `socket_timeout_ms` fires FetchReadTimeout.
    /// `effectiveDeadlineMonoNs` suspends it while the consumer is the
    /// bottleneck.
    deadline_mono_ns: u64,
    /// The task's queue, which the hop's task reference keeps alive.
    queue: *ResponseQueue,
    /// Takes the response's DATA payloads still encoded; the worker decodes
    /// them. Configured at response-head time.
    sink: stream_pump.H2EncodedSink = .{},
    /// The id every credit of this stream's chunks names.
    source_id: u64,
    headers_published: bool = false,
    /// Flow-control credit delivered to the consumer and not yet acked back.
    /// While nonzero the response is in the consumer's hands, so the stall
    /// clock stays suspended: the gateway drains the queue long before the
    /// worker releases its pool extents, and a running clock would fail slow
    /// workers with FetchReadTimeout. A credit worth more than this was never
    /// issued for the stream and is dropped.
    unacked_credit: usize = 0,
    /// The origin sent END_STREAM: nothing more will arrive from it, and any
    /// remaining wait is for the consumer's terminal ack, so the stall clock
    /// stops.
    origin_finished: bool = false,

    /// Creates the stream of `hop` on `handle`, with its credit source.
    /// Takes `hop` on success; on error the caller keeps it. Fails with
    /// `error.OutOfMemory` or `error.EgressEngineSourcesExhausted`.
    fn create(owner: *Owner, hop: Hop, handle: pool_mod.StreamHandle, deadline_mono_ns: u64) !*Stream {
        const stream = try owner.allocator.create(Stream);
        errdefer owner.allocator.destroy(stream);
        const source_id = try owner.engine.acquireSource(.{ .h2 = stream }, handle.stream_id);
        stream.* = .{
            .hop = hop,
            .handle = handle,
            .deadline_mono_ns = deadline_mono_ns,
            .queue = hop.task().response_body,
            .source_id = source_id,
        };
        return stream;
    }

    /// Retires the stream's credit source, releases its hop and frees it.
    fn destroy(self: *Stream, owner: *Owner) void {
        owner.engine.retireSource(self.source_id);
        self.hop.deinit();
        owner.allocator.destroy(self);
    }

    /// Retires the stream's credit source, frees it and hands its hop to the
    /// caller.
    fn takeHop(self: *Stream, owner: *Owner) Hop {
        owner.engine.retireSource(self.source_id);
        const hop = self.hop;
        owner.allocator.destroy(self);
        return hop;
    }

    pub fn effectiveDeadlineMonoNs(self: *const Stream) u64 {
        if (self.stallClockSuspended())
            return self.hop.config().requestDeadlineOrUnbounded();
        return self.deadline_mono_ns;
    }

    fn stallClockSuspended(self: *const Stream) bool {
        return self.origin_finished or self.pausedByConsumer();
    }

    fn pausedByConsumer(self: *const Stream) bool {
        if (!self.headers_published)
            return false;
        return self.queue.queuedBytes() != 0 or self.unacked_credit != 0;
    }

    fn expiredErrorAt(self: *const Stream, now_mono_ns: u64) anyerror {
        if (self.hop.config().requestDeadlineExpiredAt(now_mono_ns))
            return error.FetchRequestDeadlineExceeded;
        return error.FetchReadTimeout;
    }

    fn refreshStallDeadline(self: *Stream) void {
        // A failed clock read leaves the current deadline in place rather
        // than failing an in-flight fetch on a stray clock error.
        const now_ns = monotonicNowNs() catch return;
        self.deadline_mono_ns = self.hop.config().stallDeadlineFromNow(now_ns);
    }
};

/// Opens `hop`'s stream on a pooled entry of its origin, or parks the hop on
/// its origin's dial, a pool slot or a retry. Takes `hop`.
pub fn start(owner: *Owner, hop: Hop) void {
    var owned = hop;
    const start_result = owner.pool.startRequest(&owned.plan, owned.task().body, owned.config().*, owner.driver) catch |err| {
        owner.failHop(&owned, err);
        return;
    };
    switch (start_result) {
        .pending => |handle| appendStream(owner, owned, handle),
        .needs_connection => dial.joinShared(owner, owned),
        .failed => |err| switch (err) {
            error.Http2PoolExhausted => queuePoolWaiter(owner, owned),
            else => owner.failHop(&owned, err),
        },
        .entry_failed => |failed| {
            failStreamsForEntry(owner, failed.entry, failed.err);
            owner.pool.removeEntry(failed.entry, owner.driver);
            // The open may have flushed partial frames before failing, so
            // only idempotent bodyless requests replay.
            if (failed.reused and retryEligible(&owned) and isIdempotentReplayable(&owned))
                queueRetry(owner, owned)
            else
                owner.failHop(&owned, failed.err);
        },
    }
}

fn appendStream(owner: *Owner, hop: Hop, handle: pool_mod.StreamHandle) void {
    var owned = hop;
    // Open and refresh share one stall-deadline policy.
    const now_ns = monotonicNowNs() catch |err| {
        cancelStreamBestEffort(owner, handle, "deadline setup");
        removeEntryIfIdle(owner, handle.entry);
        owner.failHop(&owned, err);
        return;
    };
    owner.h2_streams.ensureUnusedCapacity(owner.allocator, 1) catch |err| {
        cancelStreamBestEffort(owner, handle, "stream append");
        removeEntryIfIdle(owner, handle.entry);
        owner.failHop(&owned, err);
        return;
    };
    const stream = Stream.create(owner, owned, handle, owned.config().stallDeadlineFromNow(now_ns)) catch |err| {
        cancelStreamBestEffort(owner, handle, "stream create");
        removeEntryIfIdle(owner, handle.entry);
        owner.failHop(&owned, err);
        return;
    };
    owner.h2_streams.appendAssumeCapacity(stream);
}

/// The entry's watch reported readiness. `stream` names the stream whose
/// deadline the watch carried, or null for an entry without streams.
pub fn entryReady(owner: *Owner, entry: *pool_mod.Entry, stream: ?*Stream, readable: bool, writable: bool) void {
    if (writable and entry.hasOutgoing()) {
        entry.flushOutgoing() catch |err| {
            failStreamsForEntry(owner, entry, err);
            owner.pool.removeEntry(entry, owner.driver);
            return;
        };
    }
    if (!readable)
        return;
    if (stream != null)
        drainEntry(owner, entry)
    else
        handleIdleEntryReadable(owner, entry);
}

/// The entry's watch reported a socket failure.
pub fn entryFailed(owner: *Owner, entry: *pool_mod.Entry, stream: ?*Stream, err: anyerror) void {
    if (isSendHalfCloseError(err)) {
        // The peer closed before reading our trailing writes (final window
        // updates race its FIN or RST). Its responses may already sit in our
        // buffers and can still complete every stream: stop writing, keep
        // reading until EOF, and let truncation fail only what it never
        // sent.
        entry.wire.markSendBroken();
        entry.h2.closeWithoutPeerGoaway();
        if (stream != null)
            drainEntry(owner, entry)
        else
            handleIdleEntryReadable(owner, entry);
        return;
    }
    failStreamsForEntry(owner, entry, err);
    owner.pool.removeEntry(entry, owner.driver);
}

/// The entry's watch deadline passed: the earliest stream's, or an idle
/// entry's lifecycle deadline.
pub fn entryExpired(owner: *Owner, entry: *pool_mod.Entry, stream: ?*Stream) void {
    const now_ns = monotonicNowNs() catch std.math.maxInt(u64);
    const expired = stream orelse {
        _ = removeEntryIfLifecycleExpired(owner, entry, now_ns);
        return;
    };
    const handle = expired.handle;
    const timeout_err = expired.expiredErrorAt(now_ns);
    const index = findStreamIndex(owner, handle.entry, handle.stream_id) orelse return;
    owner.pool.cancelStream(handle) catch |err| {
        settleEndedStream(owner, owner.h2_streams.orderedRemove(index), timeout_err);
        failStreamsForEntry(owner, handle.entry, err);
        owner.pool.removeEntry(handle.entry, owner.driver);
        return;
    };
    settleEndedStream(owner, owner.h2_streams.orderedRemove(index), timeout_err);
    _ = removeEntryIfClosingAndIdle(owner, handle.entry);
}

/// Applies a cancel. Returns false when no stream belongs to `task`.
pub fn cancelTask(owner: *Owner, task: *Task) bool {
    const index = for (owner.h2_streams.items, 0..) |item, index| {
        if (item.hop.task() == task)
            break index;
    } else return false;
    const handle = owner.h2_streams.items[index].handle;
    owner.pool.cancelStream(handle) catch |err| {
        settleCanceledStream(owner, owner.h2_streams.orderedRemove(index));
        failStreamsForEntry(owner, handle.entry, err);
        owner.pool.removeEntry(handle.entry, owner.driver);
        return true;
    };
    settleCanceledStream(owner, owner.h2_streams.orderedRemove(index));
    _ = removeEntryIfClosingAndIdle(owner, handle.entry);
    return true;
}

/// Settles a stream already removed from the list that ended with `err`: a
/// published one fails its queue, an unpublished one fails its task. Frees
/// the stream.
fn settleEndedStream(owner: *Owner, item: *Stream, err: anyerror) void {
    if (item.headers_published) {
        failQueue(owner, item.queue, @errorName(err));
        owner.wake(.{ .task_ready = item.hop.readyToken() });
        item.destroy(owner);
        return;
    }
    var hop = item.takeHop(owner);
    owner.failHop(&hop, err);
}

fn settleCanceledStream(owner: *Owner, item: *Stream) void {
    if (item.headers_published) {
        failQueue(owner, item.queue, @errorName(error.FetchAborted));
        owner.wake(.{ .task_ready = item.hop.readyToken() });
        item.destroy(owner);
        return;
    }
    var hop = item.takeHop(owner);
    owner.cancelHop(&hop);
}

/// One recv can leave events for several streams (or HEADERS, DATA and
/// END_STREAM of one) in the session. Bytes already taken from the socket
/// never produce another readiness, so every event the wire's bytes hold is
/// handled now; the peer cannot extend the loop indefinitely, because
/// handling grants no new flow-control credit.
fn drainEntry(owner: *Owner, entry: *pool_mod.Entry) void {
    while (drainOneEvent(owner, entry) == .more) {}
}

const DrainStep = enum {
    /// Event handled and the entry survived; more events may be queued.
    more,
    /// The events are drained, or the entry was removed.
    stop,
};

fn drainOneEvent(owner: *Owner, entry: *pool_mod.Entry) DrainStep {
    var event = owner.pool.readEntryEvent(entry) catch |err| {
        if (err == error.Http2WouldBlock)
            return .stop;
        failStreamsForEntry(owner, entry, err);
        owner.pool.removeEntry(entry, owner.driver);
        return .stop;
    };
    defer event.deinit();
    switch (event) {
        .head => |*head| return handleHead(owner, entry, head.stream_id, head.status_code, head.headers, head.end_stream),
        .progress => |progress| {
            const index = findStreamIndex(owner, entry, progress.stream_id) orelse
                return failEntryUnknownStream(owner, entry);
            // An interim (1xx) response is origin progress: a 103 Early
            // Hints followed by a slow final head is not origin silence. The
            // total request deadline still bounds an origin stalling behind
            // 1xx spam.
            owner.h2_streams.items[index].refreshStallDeadline();
            return .more;
        },
        .body_chunk => |*chunk| {
            const index = findStreamIndex(owner, entry, chunk.stream_id) orelse
                return failEntryUnknownStream(owner, entry);
            const item = owner.h2_streams.items[index];
            // Origin progress: a long download that keeps progressing is not
            // killed by the idle timeout.
            item.refreshStallDeadline();
            if (!item.headers_published) {
                ackDataBestEffort(owner, entry, chunk.stream_id, chunk.flow_credit, false, "body before headers");
                failStreamsForEntry(owner, entry, error.Http2ProtocolError);
                owner.pool.removeEntry(entry, owner.driver);
                return .stop;
            }
            const owned_chunk = chunk.bytes;
            chunk.bytes = &.{};
            const ready = item.sink.appendH2DataOwned(
                owner.allocator,
                item.queue,
                item.source_id,
                chunk.stream_id,
                owned_chunk,
                chunk.flow_credit,
                chunk.update_stream_window,
            ) catch |err| {
                ackDataBestEffort(owner, entry, chunk.stream_id, chunk.flow_credit, false, "body sink append failure");
                cancelStreamBestEffort(owner, item.handle, "body sink append failure");
                settleEndedStream(owner, owner.h2_streams.orderedRemove(index), err);
                return if (removeEntryIfClosingAndIdle(owner, entry)) .stop else .more;
            };
            item.unacked_credit +|= chunk.flow_credit;
            if (chunk.end_stream)
                item.origin_finished = true;
            if (ready)
                owner.wake(.{ .task_ready = item.hop.readyToken() });
            return .more;
        },
        .end => |end| return if (completeFromEnd(owner, entry, end.stream_id)) .more else .stop,
        .failure => |failure| {
            const index = findStreamIndex(owner, entry, failure.stream_id) orelse
                return failEntryUnknownStream(owner, entry);
            const item = owner.h2_streams.orderedRemove(index);
            if (!item.headers_published and isNotProcessedError(failure.err) and retryEligible(&item.hop)) {
                // The server guarantees the request never ran.
                queueRetry(owner, item.takeHop(owner));
            } else {
                settleEndedStream(owner, item, failure.err);
            }
            return if (removeEntryIfClosingAndIdle(owner, entry)) .stop else .more;
        },
    }
}

fn handleHead(
    owner: *Owner,
    entry: *pool_mod.Entry,
    stream_id: u32,
    status_code: u16,
    headers: []const transport.Header,
    end_stream: bool,
) DrainStep {
    const index = findStreamIndex(owner, entry, stream_id) orelse
        return failEntryUnknownStream(owner, entry);
    const item = owner.h2_streams.items[index];
    // Origin progress: the head arrived, so the stall clock restarts for
    // the body.
    item.refreshStallDeadline();
    if (item.headers_published)
        return .more;
    const task = item.hop.task();
    const maybe_redirect = transport.redirectTarget(
        owner.allocator,
        task.url,
        task.method,
        task.headers,
        status_code,
        headers,
        .{
            .redirect_mode = transport.RedirectMode.fromFlags(task.flags),
            .max_redirects = item.hop.config().max_redirects,
        },
        task.redirect_count,
    ) catch |err| return failStreamAt(owner, entry, index, err, "redirect validation failure");
    if (maybe_redirect) |redirect|
        return followRedirect(owner, entry, index, redirect);

    const encoding = decompress.encodingFromHeaders(headers) catch |err|
        return failStreamAt(owner, entry, index, err, "response encoding failure");
    const limits = item.hop.config().streamPumpLimits().normalized() catch |err|
        return failStreamAt(owner, entry, index, err, "response body limits failure");
    item.sink = .{ .max_encoded_bytes = limits.max_encoded_bytes };

    const result_allocator = task.resultAllocator();
    const owned_url = result_allocator.dupe(u8, task.url) catch |err|
        return failStreamAt(owner, entry, index, err, "response url copy failure");
    const owned_headers = task.copyResponseHeaders(headers) catch |err|
        return failStreamAt(owner, entry, index, err, "response header copy failure");
    item.headers_published = true;
    result.publishResult(task, .{ .success = .{
        .status = status_code,
        .url = owned_url,
        .headers = owned_headers,
        .redirected = task.redirect_count != 0,
        .body_encoding = encoding,
    } }, owner.engine.wake_ctx, owner.engine.wake_fn.?);
    if (end_stream) {
        // A stream that ends at HEADERS never queues DATA credit, so no
        // credit ack will surface its deferred `.end`; ack zero credit now.
        return if (ackZeroCreditAndComplete(owner, entry, stream_id)) .more else .stop;
    }
    return .more;
}

/// Fails the unpublished stream at `index` with `err` after resetting it.
fn failStreamAt(owner: *Owner, entry: *pool_mod.Entry, index: usize, err: anyerror, context: []const u8) DrainStep {
    cancelStreamBestEffort(owner, owner.h2_streams.items[index].handle, context);
    settleEndedStream(owner, owner.h2_streams.orderedRemove(index), err);
    return if (removeEntryIfClosingAndIdle(owner, entry)) .stop else .more;
}

fn failEntryUnknownStream(owner: *Owner, entry: *pool_mod.Entry) DrainStep {
    failStreamsForEntry(owner, entry, error.Http2UnknownStream);
    owner.pool.removeEntry(entry, owner.driver);
    return .stop;
}

/// Ends the stream at `index` and restarts its fetch on the redirect's
/// target as its next hop. Returns `.more` while the entry is still pooled.
fn followRedirect(owner: *Owner, entry: *pool_mod.Entry, index: usize, redirect: transport.RedirectTarget) DrainStep {
    defer freeRedirectTarget(owner.allocator, redirect);
    const handle = owner.h2_streams.items[index].handle;
    owner.pool.cancelStream(handle) catch |err| {
        failStreamsForEntry(owner, entry, err);
        owner.pool.removeEntry(entry, owner.driver);
        return .stop;
    };
    var hop = owner.h2_streams.orderedRemove(index).takeHop(owner);
    hop.task().replaceRequest(redirect.url, redirect.method, redirect.body, redirect.headers) catch |err| {
        owner.failHop(&hop, err);
        return if (removeEntryIfClosingAndIdle(owner, entry)) .stop else .more;
    };
    hop.task().redirect_count += 1;
    owner.routeNextHop(hop);
    // A same-origin redirect routes back through this entry, and a failed
    // open removes it; only touch the entry if it is still pooled.
    for (owner.pool.entries.items) |candidate| {
        if (candidate == entry)
            return if (removeEntryIfClosingAndIdle(owner, entry)) .stop else .more;
    }
    return .stop;
}

fn freeRedirectTarget(allocator: std.mem.Allocator, redirect: transport.RedirectTarget) void {
    allocator.free(redirect.url);
    allocator.free(redirect.method);
    transport.freeHeaders(allocator, redirect.headers);
}

/// Applies the credit `stream`'s consumer released since the owner last
/// took it (`credit_sources.zig`): the summed bytes of its window-reopening
/// credits, then the credit of its last DATA frame. Every appended chunk's
/// credit entered `unacked_credit` once and comes back once, alone or merged
/// with others by the gateway or the source, so a sum above `unacked_credit`
/// was never issued for this stream: it is dropped whole, before the codec
/// sees it, and opens no window. A zero-byte credit (an empty final DATA
/// frame) writes no window update but still runs, since only it surfaces the
/// deferred `.end` of a stream whose credit is fully released.
pub fn applyCredit(owner: *Owner, stream: *Stream, credit: credit_sources.Credit) void {
    const credited_bytes = credit.window_bytes +| credit.final_bytes;
    if (credited_bytes > stream.unacked_credit) {
        warnCreditDropped(stream, credited_bytes);
        return;
    }
    if (credit.window) {
        switch (ackStreamCredit(owner, stream, credit.window_bytes, true)) {
            .applied => {},
            .refused, .ended => return,
        }
    }
    if (credit.final) {
        switch (ackStreamCredit(owner, stream, credit.final_bytes, false)) {
            .applied => {},
            .refused, .ended => return,
        }
    }
    // No terminal event: the consumer released credit. If it caught up, the
    // engine waits on the origin again, so the stall clock restarts from
    // now; a deadline frozen at the last chunk would treat a slow consumer
    // as origin silence.
    if (!stream.stallClockSuspended())
        stream.refreshStallDeadline();
}

const CreditAck = enum {
    /// The connection took the credit, and the stream lives on.
    applied,
    /// The codec found the credit worth more than the stream's pending
    /// credit and changed nothing; the credit is dropped.
    refused,
    /// The stream ended meanwhile: its deferred `.end` surfaced, or its
    /// entry failed.
    ended,
};

/// Acks `bytes` of `stream`'s credit on its connection, and takes them off
/// `unacked_credit` once the connection took them.
fn ackStreamCredit(owner: *Owner, stream: *Stream, bytes: usize, update_stream_window: bool) CreditAck {
    const entry = stream.handle.entry;
    const stream_id = stream.handle.stream_id;
    var maybe_end = owner.pool.ackReceivedData(entry, stream_id, bytes, update_stream_window) catch |err| switch (err) {
        // The engine's count and the codec's agree by construction, so this
        // is a bookkeeping fault of the engine's own; the connection is fine.
        error.Http2AckExceedsPendingCredit => {
            warnCreditDropped(stream, bytes);
            return .refused;
        },
        else => {
            failStreamsForEntry(owner, entry, err);
            owner.pool.removeEntry(entry, owner.driver);
            return .ended;
        },
    };
    stream.unacked_credit -= bytes;
    if (maybe_end) |*end_event| {
        defer end_event.deinit();
        switch (end_event.*) {
            .end => |end| _ = completeFromEnd(owner, entry, end.stream_id),
            else => {
                failStreamsForEntry(owner, entry, error.Http2ProtocolError);
                owner.pool.removeEntry(entry, owner.driver);
                return .ended;
            },
        }
        // The end may be this stream's, or another's whose completion
        // failed the entry; only a stream still listed lives on.
        return if (findStreamIndex(owner, entry, stream_id) != null) .applied else .ended;
    }
    return .applied;
}

fn warnCreditDropped(stream: *const Stream, credited_bytes: usize) void {
    std.log.warn("egress HTTP/2 stream {d} was credited {d} bytes but holds {d}; credit dropped", .{
        stream.handle.stream_id,
        credited_bytes,
        stream.unacked_credit,
    });
}

/// Surfaces the deferred `.end` of a stream that will never get a non-zero
/// credit ack (its response ended at HEADERS). Returns true while the entry
/// is still pooled.
fn ackZeroCreditAndComplete(owner: *Owner, entry: *pool_mod.Entry, stream_id: u32) bool {
    var maybe_end = owner.pool.ackReceivedData(entry, stream_id, 0, false) catch |err| {
        failStreamsForEntry(owner, entry, err);
        owner.pool.removeEntry(entry, owner.driver);
        return false;
    };
    if (maybe_end) |*end_event| {
        defer end_event.deinit();
        switch (end_event.*) {
            .end => |end| return completeFromEnd(owner, entry, end.stream_id),
            else => {
                failStreamsForEntry(owner, entry, error.Http2ProtocolError);
                owner.pool.removeEntry(entry, owner.driver);
                return false;
            },
        }
    }
    return true;
}

/// The stream's response ended. The engine forwards bytes as received,
/// with no decode stage, so the end completes the queue at once. Returns
/// true while the entry is still pooled.
fn completeFromEnd(owner: *Owner, entry: *pool_mod.Entry, stream_id: u32) bool {
    const index = findStreamIndex(owner, entry, stream_id) orelse {
        _ = failEntryUnknownStream(owner, entry);
        return false;
    };
    const item = owner.h2_streams.orderedRemove(index);
    if (!item.headers_published) {
        settleEndedStream(owner, item, error.FetchResultMissing);
        return !removeEntryIfClosingAndIdle(owner, entry);
    }
    if (item.queue.complete())
        owner.wake(.{ .task_ready = item.hop.readyToken() });
    item.destroy(owner);
    return !removeEntryIfClosingAndIdle(owner, entry);
}

fn handleIdleEntryReadable(owner: *Owner, entry: *pool_mod.Entry) void {
    var event = owner.pool.readEntryEvent(entry) catch |err| {
        if (err == error.Http2WouldBlock) {
            _ = removeEntryIfClosingAndIdle(owner, entry);
            return;
        }
        owner.pool.removeEntry(entry, owner.driver);
        return;
    };
    // An event on an entry without streams breaks the protocol.
    event.deinit();
    owner.pool.removeEntry(entry, owner.driver);
}

/// Fails every stream on `entry` with `err`: a published stream fails its
/// queue; an unpublished one retries when `err` allows it, or fails its
/// task. The caller removes the entry.
pub fn failStreamsForEntry(owner: *Owner, entry: *pool_mod.Entry, err: anyerror) void {
    var index: usize = 0;
    while (index < owner.h2_streams.items.len) {
        if (owner.h2_streams.items[index].handle.entry != entry) {
            index += 1;
            continue;
        }
        const item = owner.h2_streams.orderedRemove(index);
        const retryable = isNotProcessedError(err) or
            (item.handle.reused and isStaleReuseError(err) and isIdempotentReplayable(&item.hop));
        if (!item.headers_published and retryable and retryEligible(&item.hop)) {
            queueRetry(owner, item.takeHop(owner));
        } else {
            settleEndedStream(owner, item, err);
        }
    }
}

/// Transport-death errors safe to retry on a fresh connection when the
/// failed request rode a reused session and saw no response bytes (the
/// undici and Bun stale-connection rule). Errors caused by the response
/// itself are excluded, because a retry would fetch it again.
fn isStaleReuseError(err: anyerror) bool {
    return err == error.BrokenPipe or
        err == error.ConnectionResetByPeer or
        err == error.FetchWriteFailed or
        err == error.FetchResponseTruncated;
}

fn isSendHalfCloseError(err: anyerror) bool {
    return err == error.BrokenPipe or
        err == error.ConnectionResetByPeer or
        err == error.FetchWriteFailed;
}

/// The server's explicit guarantee that the request was never processed,
/// which makes a replay safe whatever the method or session reuse.
fn isNotProcessedError(err: anyerror) bool {
    return err == error.Http2StreamRefused or
        err == error.Http2StreamNotProcessed;
}

pub fn retryEligible(hop: *const Hop) bool {
    return hop.h2_retries < max_stream_retries;
}

/// Without the server's not-processed guarantee part of the request may
/// have reached the server, so only idempotent bodyless requests replay,
/// the same rule as HTTP/1's.
fn isIdempotentReplayable(hop: *const Hop) bool {
    return transport.http1.isReplayableBeforeResponse(hop.plan.method, hop.task().body);
}

/// Moves `hop` onto the retry list instead of failing its fetch; the owner
/// restarts it in the same iteration (`drainRetries`).
pub fn queueRetry(owner: *Owner, hop: Hop) void {
    var retried = hop;
    retried.h2_retries += 1;
    owner.retries.append(owner.allocator, retried) catch |err|
        owner.failHop(&retried, err);
}

/// Restarts every queued retry. A restart may queue further retries (an
/// open that fails on the next candidate entry), which this drains too,
/// bounded by each fetch's retry budget.
pub fn drainRetries(owner: *Owner) void {
    while (owner.retries.pop()) |hop| {
        start(owner, hop);
        owner.watch_dirty = true;
    }
}

/// Parks a hop that found every pool slot busy. It waits for a slot instead
/// of failing, bounded by its own deadline, fixed at the first park and kept
/// across re-parks.
fn queuePoolWaiter(owner: *Owner, hop: Hop) void {
    var parked = hop;
    const fresh = transport.config.deadlineAfterMs(parked.config().socket_timeout_ms) catch std.math.maxInt(u64);
    _ = parked.poolParkDeadline(parked.config().capDeadlineMonoNs(fresh));
    owner.pool_waiters.append(owner.allocator, parked) catch
        owner.failHop(&parked, error.Http2PoolExhausted);
}

/// Fails the pool waiters whose deadline passed: with the request-deadline
/// error when the total clock ran out, and `Http2PoolExhausted` when the
/// wait for a slot did.
pub fn expirePoolWaiters(owner: *Owner, now_ns: u64) void {
    var index: usize = 0;
    while (index < owner.pool_waiters.items.len) {
        const waiter = &owner.pool_waiters.items[index];
        const request_expired = waiter.config().requestDeadlineExpiredAt(now_ns);
        if (now_ns < waiter.pool_deadline_mono_ns and !request_expired) {
            index += 1;
            continue;
        }
        var expired = owner.pool_waiters.orderedRemove(index);
        owner.failHop(&expired, if (request_expired) error.FetchRequestDeadlineExceeded else error.Http2PoolExhausted);
    }
}

/// The earliest instant a pool waiter expires, or null without waiters.
pub fn earliestPoolWaiterDeadline(owner: *Owner) ?u64 {
    var earliest: ?u64 = null;
    for (owner.pool_waiters.items) |*waiter| {
        const deadline = @min(waiter.pool_deadline_mono_ns, waiter.config().requestDeadlineOrUnbounded());
        if (earliest == null or deadline < earliest.?)
            earliest = deadline;
    }
    return earliest;
}

/// One restart pass over the pool waiters, run on every iteration that
/// changed what is watched, which covers every event that can free a slot.
/// A waiter that still finds none parks again at the back.
pub fn drainPoolWaiters(owner: *Owner) void {
    var pass = owner.pool_waiters.items.len;
    while (pass != 0 and owner.pool_waiters.items.len != 0) : (pass -= 1)
        start(owner, owner.pool_waiters.orderedRemove(0));
}

/// Takes `wire`, handshaken with h2 for `key`'s origin, into the pool; the
/// dial then opens its waiting hops with `start`, which finds the entry. On
/// error the pool released the wire, and each waiting hop goes to
/// `startAfterPoolFailure`.
pub fn addEntry(owner: *Owner, key: *const transport.request_plan.OriginKey, wire: *transport.Wire, config: transport.Config) !void {
    _ = try owner.pool.addEntry(key, wire, config, owner.driver);
}

/// Settles a hop whose dial's wire found no room in the pool: it waits for
/// a slot when every slot is busy, and fails otherwise. Takes `hop`.
pub fn startAfterPoolFailure(owner: *Owner, hop: Hop, err: anyerror) void {
    var owned = hop;
    if (err == error.Http2PoolExhausted)
        queuePoolWaiter(owner, owned)
    else
        owner.failHop(&owned, err);
}

pub fn evictExpiredEntries(owner: *Owner, now_ns: u64) void {
    var index: usize = 0;
    while (index < owner.pool.entries.items.len) {
        if (removeEntryIfLifecycleExpired(owner, owner.pool.entries.items[index], now_ns))
            continue;
        index += 1;
    }
}

/// One source per entry, carrying the deadline of its earliest stream, or
/// its lifecycle deadline when it has none.
pub fn appendWatches(owner: *Owner) void {
    const first_watch = owner.watches.items.len;
    for (owner.pool.entries.items, 0..) |entry, offset| {
        entry.watch_index = first_watch + offset;
        owner.watches.appendAssumeCapacity(.{ .entry = .{ .entry = entry, .stream = null } });
    }
    // One pass over the streams picks each entry's earliest-deadline stream,
    // evaluating each stream's effective deadline once.
    for (owner.h2_streams.items) |item| {
        const watch = &owner.watches.items[item.handle.entry.watch_index].entry;
        std.debug.assert(watch.entry == item.handle.entry);
        const deadline = item.effectiveDeadlineMonoNs();
        if (watch.stream == null or deadline < watch.deadline_mono_ns) {
            watch.stream = item;
            watch.deadline_mono_ns = deadline;
        }
    }
    for (owner.watches.items[first_watch..]) |*watch| {
        const entry = watch.entry.entry;
        const stream = watch.entry.stream;
        const idle = stream == null and entry.isIdle();
        const deadline = if (stream != null)
            watch.entry.deadline_mono_ns
        else if (idle)
            owner.pool.entryLifecycleDeadlineNs(entry)
        else
            std.math.maxInt(u64);
        owner.watch_sources.appendAssumeCapacity(.{
            .context = @ptrCast(watch),
            .io = .{ .wire = entry.wire },
            .deadline_mono_ns = deadline,
            .want_read = (stream != null or idle or entry.wantsOutgoingRead()) and !entry.remote_eof,
            .want_write = entry.wantsOutgoingWrite(),
        });
    }
}

/// Settles every stream with `err` and removes every entry that carried
/// one.
pub fn settleAll(owner: *Owner, err: anyerror) void {
    while (owner.h2_streams.items.len != 0) {
        const entry = owner.h2_streams.items[0].handle.entry;
        // Nothing replays at the end of a run.
        var index: usize = 0;
        while (index < owner.h2_streams.items.len) {
            if (owner.h2_streams.items[index].handle.entry != entry) {
                index += 1;
                continue;
            }
            settleEndedStream(owner, owner.h2_streams.orderedRemove(index), err);
        }
        owner.pool.removeEntry(entry, owner.driver);
    }
}

fn findStreamIndex(owner: *Owner, entry: *pool_mod.Entry, stream_id: u32) ?usize {
    for (owner.h2_streams.items, 0..) |item, index| {
        if (item.handle.entry == entry and item.handle.stream_id == stream_id)
            return index;
    }
    return null;
}

fn removeEntryIfIdle(owner: *Owner, entry: *pool_mod.Entry) void {
    if (!entry.isIdle())
        return;
    owner.pool.removeEntry(entry, owner.driver);
}

fn removeEntryIfClosingAndIdle(owner: *Owner, entry: *pool_mod.Entry) bool {
    if (!entry.h2.closing or entry.h2.hasActiveStreams() or entry.hasOutgoing())
        return false;
    owner.pool.removeEntry(entry, owner.driver);
    return true;
}

fn removeEntryIfLifecycleExpired(owner: *Owner, entry: *pool_mod.Entry, now_ns: u64) bool {
    if (!entry.isIdle())
        return false;
    if (!entry.h2.closing and owner.pool.entryLifecycleDeadlineNs(entry) > now_ns)
        return false;
    owner.pool.removeEntry(entry, owner.driver);
    return true;
}

fn cancelStreamBestEffort(owner: *Owner, handle: pool_mod.StreamHandle, context: []const u8) void {
    owner.pool.cancelStream(handle) catch |err|
        std.log.debug("HTTP/2 egress stream cancel failed in {s}: {s}", .{ context, @errorName(err) });
}

fn ackDataBestEffort(
    owner: *Owner,
    entry: *pool_mod.Entry,
    stream_id: u32,
    encoded_bytes: usize,
    update_stream_window: bool,
    context: []const u8,
) void {
    var maybe_event = owner.pool.ackReceivedData(entry, stream_id, encoded_bytes, update_stream_window) catch |err| {
        std.log.debug("HTTP/2 egress flow-credit ack failed in {s}: {s}", .{ context, @errorName(err) });
        return;
    };
    if (maybe_event) |*event|
        event.deinit();
}

/// Fails a response queue on a path that already ends its fetch. A queue
/// that already ended keeps its state.
pub fn failQueue(owner: *Owner, queue: *ResponseQueue, message: []const u8) void {
    _ = queue.fail(owner.allocator, message);
}
