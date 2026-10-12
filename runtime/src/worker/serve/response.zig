//! Writes a request's response to the host and finishes the request. A
//! buffered body goes through `response_writer.zig`. A streamed body pulls
//! from its source (`request/response_stream.zig`): a fetch body chunk by
//! chunk here, a ReadableStream the handler's Response carried through
//! `response_body_stream.zig`. Either way the head goes out first, each
//! chunk is written when the payload ring has room, and the request
//! finishes when the source ends, or resets the client's stream when it
//! fails. A pull that cannot start, as when the handler aborted the fetch,
//! fails only that response. A step that finds no room in the ring or the
//! control socket waits in the request's outbox until
//! `flushPendingIngressResponses` sends it, and the request sends nothing
//! else meanwhile. A path that answers the request anew or ends its response
//! early drops what the outbox holds and releases the source first, so no
//! second head follows a parked one. It runs on the worker's VM thread.

const std = @import("std");
const h2 = @import("collo_http").http2;
const ipc = @import("collo_ipc");
const request_context = @import("collo_worker_request").context;
const ingress_response_payload_writer = @import("response_payload_writer.zig");
const ingress_response_writer = @import("response_writer.zig");
const response_body_stream = @import("response_body_stream.zig");
const response_outbox = @import("collo_worker_request").ingress.response_outbox;
const response_finish = @import("response_finish.zig");
const response_model = @import("collo_worker_request").response_model;
const state = @import("../runtime/root.zig");
const tracing = @import("trace.zig");

pub const Header = response_model.Header;
pub const Response = response_model.Response;
pub const finishRequest = response_finish.finishRequest;
pub const releasePendingIngressResponse = response_finish.releasePendingIngressResponse;

const PendingFlushResult = enum {
    /// The step still waits for room in the payload ring.
    blocked,
    /// The step found the control socket full and stays parked; no other
    /// request's step would find room either.
    socket_full,
    progressed,
    /// The request finished, which invalidates the pass's iterator. A
    /// stream whose next pull could not start answers it too, since failing
    /// the response may finish the request.
    finished,
};

/// Writes `response` and finishes the request with `done_status` and
/// `http_status`, now or, when part of it waits in the outbox, once the
/// flush sends it; a streamed body finishes the request when its source
/// ends. A streamed body is taken out of `response`. The caller is inside
/// the request's owner window, since a ReadableStream body's first read runs
/// the tenant's JavaScript.
pub fn writeAndFinishResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *Response,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !void {
    switch (response.body) {
        .fetch_stream => {
            try writeFetchStreamResponse(runtime, request_ctx, response, done_status, http_status);
            return;
        },
        .body_stream => {
            try response_body_stream.start(runtime, request_ctx, response, done_status, http_status);
            return;
        },
        .empty, .bytes, .owned, .abi => {},
    }

    if (request_ctx.response_stream != .none)
        return error.ResponseBodyStreamAlreadyPending;
    try ingress_response_writer.writeAndFinish(
        runtime,
        request_ctx,
        response,
        done_status,
        http_status,
        response_finish.finishRequest,
    );
}

/// Answers `status` with `message` as a plain-text body.
pub fn writeSimpleError(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    status: u16,
    message: []const u8,
    done_status: ipc.RequestDoneStatus,
) !void {
    // The server adds no content-type to a worker's head, so a body without
    // one here would reach the client without one.
    var response = Response{
        .status = status,
        .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        .body = .{ .bytes = message },
    };
    try writeAndFinishResponse(runtime, request_ctx, &response, done_status, status);
}

/// Answers `status` with `message` as `writeSimpleError` does, in place of a
/// response whose head has not gone out. What is left of that response is
/// dropped first (`abandonResponse`), a head parked in the outbox with it,
/// so the head of this answer is the only one the client gets.
pub fn replaceUnsentResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    status: u16,
    message: []const u8,
    done_status: ipc.RequestDoneStatus,
) !void {
    std.debug.assert(!request_ctx.response_committed);
    abandonResponse(runtime, request_ctx, done_status);
    try writeSimpleError(runtime, request_ctx, status, message, done_status);
}

/// Ends the response of `request_ctx`, which cannot go on, and finishes the
/// request with `done_status` and `http_status`. What is left of the
/// response is dropped first (`abandonResponse`). A head that went out means
/// the client already has part of the response, so its stream is reset
/// instead of ending cleanly. A reset that finds the control socket full
/// waits in the outbox, and the flush sends it and finishes the request.
pub fn failResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !void {
    const request_id = request_ctx.exec.request_id;
    abandonResponse(runtime, request_ctx, done_status);
    // The flush finishes the request of a parked reset with these statuses.
    request_ctx.response_done_status = done_status;
    request_ctx.response_http_status = http_status;
    if (request_ctx.response_committed) {
        // Every dispatched request has a nonzero stream
        // (`validateStreamBeginDescriptor`); a context without one has no
        // stream to reset.
        if (request_ctx.ingress_channel_id != 0) {
            const reset_code = @intFromEnum(h2.ErrorCode.internal_error);
            if (ingress_response_payload_writer.writeStreamReset(runtime, request_ctx, reset_code)) |sent| {
                switch (sent) {
                    .sent => {},
                    .blocked => {
                        try request_ctx.response_outbox.park(.{ .stream_reset = reset_code });
                        return;
                    },
                }
            } else |err| {
                // Without the reset the server keeps this request's committed
                // completion waiting for a stream end that never comes.
                // Stopping the worker turns that into death synthesis: the
                // server drains the control socket and finalizes the slot
                // with the real status.
                std.log.warn("failed to reset committed failed response request_id={d}; stopping worker: {s}", .{ request_id, @errorName(err) });
                runtime.traceRuntimeEvent("worker.runtime.stop=reset_send_failed,{d}", .{request_id});
                runtime.core.running = false;
            }
        }
    }
    tracing.mark(runtime, request_ctx, "response_write_done_ns");
    _ = try response_finish.finishRequest(runtime, request_ctx, done_status, http_status);
}

/// Drops what is left of the response of `request_ctx`, which ends with
/// `done_status`: its streamed source and the steps its outbox holds. A
/// fetch body goes back to the runtime, and a pull still in flight then
/// finds no request streaming it (`executeFetchBodyStreamReady`); a body
/// stream still open is cancelled when `done_status` allows it
/// (`response_body_stream.cancelFor`).
fn abandonResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    done_status: ipc.RequestDoneStatus,
) void {
    switch (request_ctx.response_stream) {
        .none => {},
        .fetch => |fetch| {
            request_ctx.response_stream = .none;
            _ = runtime.releaseFetchBody(fetch.identity);
        },
        .body_stream => response_body_stream.release(runtime, request_ctx, response_body_stream.cancelFor(done_status)),
    }
    response_finish.releasePendingIngressResponse(runtime, request_ctx);
}

/// Sends what every request's outbox holds while the control socket and the
/// payload ring have room, and finishes each request whose outbox empties.
/// The loop calls it when the socket turns writable or the ring gets room
/// (`scheduler/loop.zig`). A step that finds the socket full stays parked
/// and ends the call; one that finds the ring full stays parked and the pass
/// goes on. A request that finishes restarts the pass, because its removal
/// invalidates the iterator. Runs outside every owner window, so it never
/// reads a body stream: it asks the stream's work item for the next read.
pub fn flushPendingIngressResponses(runtime: *state.Runtime) !void {
    runtime.requests.control_send_blocked = false;
    while (true) {
        var restart_after_removal = false;
        var made_progress = false;
        var iterator = runtime.requests.active.iterator();
        while (iterator.next()) |entry| {
            const request_ctx = entry.value_ptr.*;
            if (request_ctx.response_outbox.isEmpty())
                continue;
            switch (try flushPendingIngressResponse(runtime, request_ctx)) {
                .blocked => {},
                .socket_full => return,
                .progressed => made_progress = true,
                .finished => {
                    made_progress = true;
                    restart_after_removal = true;
                    break;
                },
            }
        }
        if (restart_after_removal)
            continue;
        if (!made_progress)
            break;
    }
}

/// Sends the step the outbox of `request_ctx` holds. The step stays parked
/// until it is sent whole, so a send that finds no room leaves the outbox
/// as it was, apart from the progress a body or a chunk made.
fn flushPendingIngressResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !PendingFlushResult {
    switch (request_ctx.response_outbox.pending) {
        .none => return .blocked,
        .buffered_body => |*buffered| return try flushBufferedResponse(runtime, request_ctx, buffered),
        .stream_head => |*head| return try flushStreamHead(runtime, request_ctx, head),
        .stream_chunk => |*chunk| return try flushStreamChunk(runtime, request_ctx, chunk),
        .stream_end => return try flushStreamEnd(runtime, request_ctx),
        .stream_reset => |reset_code| return try flushStreamReset(runtime, request_ctx, reset_code),
    }
}

fn flushBufferedResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    buffered: *response_outbox.BufferedBody,
) !PendingFlushResult {
    const head_before = buffered.head != null;
    const offset_before = buffered.offset;
    switch (try ingress_response_payload_writer.flushBufferedBody(runtime, request_ctx, buffered)) {
        .sent => {},
        .ring_full => {
            const head_now = buffered.head != null;
            const moved = head_now != head_before or buffered.offset != offset_before;
            return if (moved) .progressed else .blocked;
        },
        .socket_full => return .socket_full,
    }

    const flushed = request_ctx.response_outbox.take().buffered_body;
    std.debug.assert(flushed.head == null);
    runtime.core.allocator.free(flushed.body);
    tracing.mark(runtime, request_ctx, "response_write_done_ns");
    _ = try response_finish.finishRequest(
        runtime,
        request_ctx,
        flushed.done_status,
        flushed.http_status,
    );
    return .finished;
}

fn flushStreamHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    head: *const response_outbox.PendingHead,
) !PendingFlushResult {
    switch (try ingress_response_payload_writer.sendPendingHead(runtime, request_ctx, head)) {
        .sent => {},
        .blocked => return .socket_full,
    }
    var sent_head = request_ctx.response_outbox.take().stream_head;
    sent_head.deinit(runtime.core.allocator);
    if (!pullNextChunkOrFail(runtime, request_ctx))
        return .finished;
    return .progressed;
}

/// Sends a parked chunk of a streamed body from the offset it reached. The
/// chunk keeps its place until all of it went out; then its credits go back
/// to the gateway, a chunk that ended the body finishes the request, and any
/// other asks its source for the next one.
fn flushStreamChunk(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    chunk: *response_outbox.StreamChunk,
) !PendingFlushResult {
    const offset_before = chunk.offset;
    switch (try ingress_response_payload_writer.writeStreamBytes(
        runtime,
        request_ctx,
        chunk.bytes.bytes(),
        &chunk.offset,
        chunk.done,
    )) {
        .sent => {},
        .ring_full => return if (chunk.offset != offset_before) .progressed else .blocked,
        .socket_full => return .socket_full,
    }

    var sent_chunk = request_ctx.response_outbox.take().stream_chunk;
    const chunk_done = sent_chunk.done;
    runtime.releaseFetchBodyResponseStreamCredits(sent_chunk.credits.slice());
    sent_chunk.deinit(runtime.core.allocator);
    runtime.flushFetchBodyPoolReleases();
    if (chunk_done) {
        try finishResponseStream(runtime, request_ctx);
        return .finished;
    }

    if (!pullNextChunkOrFail(runtime, request_ctx))
        return .finished;
    return .progressed;
}

fn flushStreamEnd(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !PendingFlushResult {
    switch (try ingress_response_payload_writer.writeStreamEnd(runtime, request_ctx)) {
        .sent => {},
        .blocked => return .socket_full,
    }
    _ = request_ctx.response_outbox.take();
    try finishResponseStream(runtime, request_ctx);
    return .finished;
}

fn flushStreamReset(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    reset_code: u32,
) !PendingFlushResult {
    switch (try ingress_response_payload_writer.writeStreamReset(runtime, request_ctx, reset_code)) {
        .sent => {},
        .blocked => return .socket_full,
    }
    _ = request_ctx.response_outbox.take();
    tracing.mark(runtime, request_ctx, "response_write_done_ns");
    _ = try response_finish.finishRequest(
        runtime,
        request_ctx,
        request_ctx.response_done_status,
        request_ctx.response_http_status,
    );
    return .finished;
}

fn writeFetchStreamResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *Response,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !void {
    const stream_identity = response.body.takeFetchStream() orelse return error.InvalidResponseBody;
    if (request_ctx.response_stream != .none) {
        response.body = .{ .fetch_stream = stream_identity };
        return error.ResponseBodyStreamAlreadyPending;
    }

    var stream_moved = false;
    errdefer if (!stream_moved) {
        request_ctx.response_stream = .none;
        response.body = .{ .fetch_stream = stream_identity };
    };

    request_ctx.response_stream = .{ .fetch = .{ .identity = stream_identity } };
    request_ctx.response_done_status = done_status;
    request_ctx.response_http_status = http_status;
    switch (try ingress_response_payload_writer.writeStreamHead(runtime, request_ctx, response)) {
        .sent => {},
        .blocked => {
            // The first pull starts once the flush sends the head.
            var head = try ingress_response_payload_writer.pendingHead(runtime, response, false);
            errdefer head.deinit(runtime.core.allocator);
            try request_ctx.response_outbox.park(.{ .stream_head = head });
            stream_moved = true;
            return;
        },
    }
    stream_moved = true;
    _ = pullNextChunkOrFail(runtime, request_ctx);
}

/// Moves the next ready bytes of the fetch body `body_id` into the response
/// it streams. Returns false when no request streams that body, so the
/// caller settles it as an ordinary fetch body instead.
pub fn executeFetchBodyStreamReady(runtime: *state.Runtime, body_id: u64) !bool {
    const request_ctx = responseStreamRequestForBodyId(runtime, body_id) orelse return false;
    const fetch = &request_ctx.response_stream.fetch;
    if (!fetch.pull_pending)
        return true;

    const identity = fetch.identity;
    fetch.pull_pending = false;

    // Defers run last-in first-out: the drain's deinit below releases
    // borrowed pool extents after the drain's own flush ran, so the gateway
    // notification is flushed again after it.
    defer runtime.flushFetchBodyPoolReleases();
    var drain = try runtime.drainFetchBodyResponseStreamReady(identity);
    defer drain.deinit(runtime.core.allocator);
    var credits_released = false;
    defer if (!credits_released) {
        runtime.releaseFetchBodyResponseStreamCredits(drain.credits.slice());
    };

    if (drain.waiter == null) {
        credits_released = true;
        runtime.releaseFetchBodyResponseStreamCredits(drain.credits.slice());
        fetch.pull_pending = true;
        return true;
    }

    if (drain.failed) {
        try failResponse(runtime, request_ctx, .internal_error, request_ctx.response_http_status);
        credits_released = true;
        runtime.releaseFetchBodyResponseStreamCredits(drain.credits.slice());
        return true;
    }

    const drain_bytes = drain.bytes.bytes();
    if (drain_bytes.len != 0) {
        var sent_len: usize = 0;
        switch (try ingress_response_payload_writer.writeStreamBytes(runtime, request_ctx, drain_bytes, &sent_len, drain.done)) {
            .sent => {
                credits_released = true;
                runtime.releaseFetchBodyResponseStreamCredits(drain.credits.slice());
                if (drain.done) {
                    try finishResponseStream(runtime, request_ctx);
                } else {
                    _ = pullNextChunkOrFail(runtime, request_ctx);
                }
                return true;
            },
            .ring_full, .socket_full => {},
        }
        // The ring or the control socket has no room, so the chunk waits in
        // the outbox with its credits until the flush sends the rest.
        var chunk = response_outbox.StreamChunk{
            .bytes = drain.takeBytes(),
            .offset = sent_len,
            .credits = drain.takeCredits(),
            .done = drain.done,
        };
        errdefer chunk.deinit(runtime.core.allocator);
        try request_ctx.response_outbox.park(.{ .stream_chunk = chunk });
        credits_released = true;
        return true;
    }

    if (drain.done) {
        const end_sent = try ingress_response_payload_writer.writeStreamEnd(runtime, request_ctx);
        credits_released = true;
        runtime.releaseFetchBodyResponseStreamCredits(drain.credits.slice());
        switch (end_sent) {
            .sent => try finishResponseStream(runtime, request_ctx),
            // The flush sends the end and then finishes the stream.
            .blocked => try request_ctx.response_outbox.park(.stream_end),
        }
        return true;
    }

    credits_released = true;
    runtime.releaseFetchBodyResponseStreamCredits(drain.credits.slice());
    _ = pullNextChunkOrFail(runtime, request_ctx);
    return true;
}

fn responseStreamRequestForBodyId(
    runtime: *state.Runtime,
    body_id: u64,
) ?*request_context.RequestContext {
    const body = runtime.egress.state.bodies.get(body_id) orelse return null;
    const request_ctx = runtime.requests.active.get(body.identity.request_id) orelse return null;
    const stream_identity = switch (request_ctx.response_stream) {
        .fetch => |fetch| fetch.identity,
        .none, .body_stream => return null,
    };
    if (stream_identity.request_id != body.identity.request_id)
        return null;
    if (stream_identity.request_generation != body.identity.request_generation)
        return null;
    if (stream_identity.fetch_id != body.identity.fetch_id)
        return null;
    if (stream_identity.body_id != body.identity.body_id)
        return null;
    return request_ctx;
}

/// Asks the source the response of `request_ctx` streams for its next
/// chunk: a fetch body's pull starts here, and a body stream's read waits
/// for the request's work item (`response_body_stream.readNextAfterFlush`),
/// since this runs from the flush too. A fetch body that can no longer be
/// pulled, such as one whose fetch the handler aborted, ends only this
/// response (`failResponse`), and the call returns false.
fn pullNextChunkOrFail(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) bool {
    switch (request_ctx.response_stream) {
        .none => return true,
        .body_stream => {
            response_body_stream.readNextAfterFlush(runtime, request_ctx);
            return true;
        },
        .fetch => {},
    }
    scheduleNextFetchPull(runtime, request_ctx) catch |err| {
        const request_id = request_ctx.exec.request_id;
        std.log.warn("failed to pull streamed response body request_id={d}: {s}", .{
            request_id,
            @errorName(err),
        });
        failResponse(runtime, request_ctx, .internal_error, request_ctx.response_http_status) catch |fail_err| {
            std.log.warn("failed to reset failed streamed response request_id={d}: {s}", .{
                request_id,
                @errorName(fail_err),
            });
        };
        return false;
    };
    return true;
}

fn scheduleNextFetchPull(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !void {
    const fetch = switch (request_ctx.response_stream) {
        .fetch => |*fetch| fetch,
        .none, .body_stream => return error.FetchBodyNotFound,
    };
    if (fetch.pull_pending)
        return error.FetchBodyReadInProgress;
    fetch.pull_pending = true;
    errdefer fetch.pull_pending = false;
    try runtime.beginFetchBodyResponseStreamPull(fetch.identity);
}

/// Finishes the request of a streamed response whose end went out, with the
/// statuses the response was written with, after releasing its source: a
/// fetch body back to the runtime, a body stream, which has closed, without
/// a cancel.
pub fn finishResponseStream(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !void {
    switch (request_ctx.response_stream) {
        .none => return error.ResponseStreamNotFound,
        .fetch => |fetch| {
            request_ctx.response_stream = .none;
            _ = runtime.releaseFetchBody(fetch.identity);
        },
        .body_stream => response_body_stream.release(runtime, request_ctx, null),
    }
    tracing.mark(runtime, request_ctx, "response_write_done_ns");
    _ = try response_finish.finishRequest(
        runtime,
        request_ctx,
        request_ctx.response_done_status,
        request_ctx.response_http_status,
    );
}
