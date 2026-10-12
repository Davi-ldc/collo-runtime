//! Writes a request's response to the host and finishes the request. A
//! buffered or segmented body goes through `response_writer.zig`. A streamed
//! body pulls from its source (`request/response_stream.zig`): a fetch body
//! chunk by chunk here, a ReadableStream the handler's Response carried
//! through `response_body_stream.zig`. Either way the head goes out first,
//! the request finishes when the source ends, and a source that fails resets
//! the client's stream. It runs on the worker's VM thread.
//!
//! A step that finds no body credit, or no room in the payload ring or the
//! control socket, waits in the request's outbox, and the request sends
//! nothing else meanwhile (`response_payload_writer.zig` says what a send
//! spends). The event that ends the wait queues the request's one
//! `response_advance` item, which resumes every kind of response in the
//! request's owner window, so the request's deadline and CPU budget apply
//! (`executeAdvance`). A path that answers the request anew or ends its
//! response early drops what the outbox holds and releases the source first,
//! so no second head follows a parked one.

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
const response_stream = @import("collo_worker_request").response_stream;
const state = @import("../runtime/root.zig");
const tracing = @import("trace.zig");

pub const Header = response_model.Header;
pub const Response = response_model.Response;
pub const finishRequest = response_finish.finishRequest;
pub const releasePendingIngressResponse = response_finish.releasePendingIngressResponse;

/// Writes `response` and finishes with its statuses after every byte is sent.
/// A streamed body moves into the request and finishes when its source ends.
/// The caller is inside the request's owner window, since a ReadableStream
/// body's first read runs the tenant's JavaScript.
pub fn writeAndFinishResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *Response,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !void {
    request_ctx.response_done_status = done_status;
    request_ctx.response_http_status = http_status;
    switch (response.body) {
        .fetch_stream => {
            try writeFetchStreamResponse(runtime, request_ctx, response);
            return;
        },
        .body_stream => {
            try response_body_stream.start(runtime, request_ctx, response);
            return;
        },
        .empty, .bytes, .owned, .abi => {},
    }

    if (request_ctx.response_stream != .none)
        return error.ResponseBodyStreamAlreadyPending;
    try ingress_response_writer.writeAndFinish(runtime, request_ctx, response, response_finish.finishRequest);
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
/// waits in the outbox, and the advance that sends it finishes the request.
pub fn failResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !void {
    const request_id = request_ctx.exec.request_id;
    abandonResponse(runtime, request_ctx, done_status);
    // A parked reset finishes the request with these statuses once it is
    // sent (`flushStreamReset`).
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
    // Dropping the source may send a gateway command and detach on failure.
    // Return its retained pool lease before that command can unmap the pool.
    response_finish.releasePendingIngressResponse(runtime, request_ctx);
    switch (request_ctx.response_stream) {
        .none => {},
        .fetch => |fetch| {
            request_ctx.response_stream = .none;
            _ = runtime.releaseFetchBody(fetch.identity);
        },
        .body_stream => response_body_stream.release(runtime, request_ctx, response_body_stream.cancelFor(done_status)),
    }
}

/// Drops every fetch chunk that waits to be sent with bytes borrowed from
/// the gateway's body pool, while the pool is still mapped, for the detach
/// about to unmap it (`egress/gateway_runtime.zig:disconnectWithReason`).
/// Runs no JavaScript, sends nothing and removes no request: each response
/// it touches is marked failed, and its advance resets it. A chunk whose
/// bytes the worker owns survives the detach.
pub fn releaseFetchResponseHoldsBeforeDetach(runtime: *state.Runtime) void {
    var iterator = runtime.requests.active.iterator();
    while (iterator.next()) |entry| {
        const request_ctx = entry.value_ptr.*;
        if (request_ctx.response_stream != .fetch)
            continue;
        const borrowed = switch (request_ctx.response_outbox.pending) {
            .stream_chunk => |chunk| chunk.bytes == .borrowed,
            else => false,
        };
        if (!borrowed)
            continue;
        request_ctx.response_stream.fetch.failed = true;
        response_finish.releasePendingIngressResponse(runtime, request_ctx);
        _ = response_stream.queueAdvance(runtime, request_ctx);
    }
}

/// Queues the advance of every response that waits for `transport`, which
/// the loop found with room. A response waiting for credit stays as it is,
/// since only a grant ends that wait.
pub fn notifyTransport(runtime: *state.Runtime, transport: enum { socket, ring }) void {
    const wait: response_stream.Wait = switch (transport) {
        .socket => .socket,
        .ring => .ring,
    };
    if (transport == .socket)
        runtime.requests.control_send_blocked = false;
    var iterator = runtime.requests.active.iterator();
    while (iterator.next()) |entry| {
        const request_ctx = entry.value_ptr.*;
        if (request_ctx.response_advance.wait != wait)
            continue;
        request_ctx.response_advance.wait = .none;
        _ = response_stream.queueAdvance(runtime, request_ctx);
    }
}

/// The `response_advance` item of request `request_id`, run in its owner
/// window: sends the step its outbox holds, or else asks the source for more
/// (a body stream's next read or result, a fetch body's next pull). A
/// committed response whose fetch body failed is reset instead.
pub fn executeAdvance(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    request_ctx.response_advance.state = .idle;
    request_ctx.response_advance.ready_since_ns = 0;
    if (request_ctx.finish_started or request_ctx.client_reset)
        return;
    if (request_ctx.response_advance.wait != .none)
        return;
    if (request_ctx.response_committed and fetchFailed(runtime, request_ctx)) {
        try failResponse(runtime, request_ctx, .internal_error, request_ctx.response_http_status);
        return;
    }
    if (!request_ctx.response_outbox.isEmpty()) {
        try flushPendingIngressResponse(runtime, request_ctx);
        return;
    }
    switch (request_ctx.response_stream) {
        .none => {},
        .body_stream => try response_body_stream.execute(runtime, request_id),
        .fetch => |*fetch| {
            if (!fetch.pull_pending) {
                scheduleNextFetchPull(runtime, request_ctx) catch |err| {
                    std.log.warn("failed to pull streamed response body request_id={d}: {s}", .{ request_id, @errorName(err) });
                    try failResponse(runtime, request_ctx, .internal_error, request_ctx.response_http_status);
                };
            }
        },
    }
}

/// Sends the parked step, retaining its owner and offset on backpressure.
fn flushPendingIngressResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !void {
    switch (request_ctx.response_outbox.pending) {
        .none => {},
        .buffered_body => |*buffered| try flushBufferedResponse(runtime, request_ctx, buffered),
        .stream_head => |*head| try flushStreamHead(runtime, request_ctx, head),
        .stream_chunk => |*chunk| try flushStreamChunk(runtime, request_ctx, chunk),
        .stream_end => try flushStreamEnd(runtime, request_ctx),
        .stream_reset => |reset_code| try flushStreamReset(runtime, request_ctx, reset_code),
    }
}

fn flushBufferedResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    buffered: *response_outbox.BufferedBody,
) !void {
    switch (try ingress_response_payload_writer.flushBufferedBody(runtime, request_ctx, buffered)) {
        .sent => {},
        .credit_empty, .ring_full, .socket_full => return,
    }

    var flushed = request_ctx.response_outbox.take().buffered_body;
    std.debug.assert(flushed.head == null);
    flushed.body.deinitOwned(runtime.core.allocator);
    tracing.mark(runtime, request_ctx, "response_write_done_ns");
    _ = try response_finish.finishRequest(
        runtime,
        request_ctx,
        request_ctx.response_done_status,
        request_ctx.response_http_status,
    );
}

fn flushStreamHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    head: *const response_outbox.PendingHead,
) !void {
    switch (try ingress_response_payload_writer.sendPendingHead(runtime, request_ctx, head)) {
        .sent => {},
        .blocked => return,
    }
    var sent_head = request_ctx.response_outbox.take().stream_head;
    sent_head.deinit(runtime.core.allocator);
    queueNextChunk(runtime, request_ctx);
}

/// Sends a parked chunk from its offset, then returns its gateway credits.
/// A final chunk finishes the request; another asks its source for more.
fn flushStreamChunk(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    chunk: *response_outbox.StreamChunk,
) !void {
    switch (try ingress_response_payload_writer.writeStreamBytes(
        runtime,
        request_ctx,
        chunk.bytes.bytes(),
        &chunk.offset,
        chunk.done,
    )) {
        .sent => {},
        .credit_empty, .ring_full, .socket_full => return,
    }

    var sent_chunk = request_ctx.response_outbox.take().stream_chunk;
    const chunk_done = sent_chunk.done;
    runtime.releaseFetchBodyResponseStreamCredits(sent_chunk.credits.slice());
    sent_chunk.deinit(runtime.core.allocator);
    runtime.flushFetchBodyPoolReleases();
    if (chunk_done) {
        try finishResponseStream(runtime, request_ctx);
        return;
    }
    queueNextChunk(runtime, request_ctx);
}

fn flushStreamEnd(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !void {
    switch (try ingress_response_payload_writer.writeStreamEnd(runtime, request_ctx)) {
        .sent => {},
        .blocked => return,
    }
    _ = request_ctx.response_outbox.take();
    try finishResponseStream(runtime, request_ctx);
}

fn flushStreamReset(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    reset_code: u32,
) !void {
    switch (try ingress_response_payload_writer.writeStreamReset(runtime, request_ctx, reset_code)) {
        .sent => {},
        .blocked => return,
    }
    _ = request_ctx.response_outbox.take();
    tracing.mark(runtime, request_ctx, "response_write_done_ns");
    _ = try response_finish.finishRequest(
        runtime,
        request_ctx,
        request_ctx.response_done_status,
        request_ctx.response_http_status,
    );
}

fn writeFetchStreamResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *Response,
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
    switch (try ingress_response_payload_writer.writeStreamHead(runtime, request_ctx, response)) {
        .sent => {},
        .blocked => {
            // The first pull starts once the advance sends the head.
            var head = try ingress_response_payload_writer.pendingHead(runtime, response, false);
            errdefer head.deinit(runtime.core.allocator);
            try request_ctx.response_outbox.park(.{ .stream_head = head });
            stream_moved = true;
            return;
        },
    }
    stream_moved = true;
    queueNextChunk(runtime, request_ctx);
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
                    queueNextChunk(runtime, request_ctx);
                }
                return true;
            },
            .credit_empty, .ring_full, .socket_full => {},
        }
        // No credit, or no room in the ring or the control socket, so the
        // chunk waits in the outbox with its credits until an advance sends
        // the rest.
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
            // The advance that sends the end finishes the stream.
            .blocked => try request_ctx.response_outbox.park(.stream_end),
        }
        return true;
    }

    credits_released = true;
    runtime.releaseFetchBodyResponseStreamCredits(drain.credits.slice());
    queueNextChunk(runtime, request_ctx);
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

/// Asks the source of a streamed response for its next chunk, in the
/// response's advance, where a body stream starts its next read and a fetch
/// body its next pull once the request has credit.
fn queueNextChunk(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) void {
    if (request_ctx.response_stream == .none)
        return;
    if (request_ctx.response_stream == .body_stream)
        request_ctx.response_stream.body_stream.read_next = true;
    _ = response_stream.queueAdvance(runtime, request_ctx);
}

/// Whether the fetch body the response streams failed, left the table or
/// lost a chunk to a detach (`Fetch.failed`).
fn fetchFailed(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) bool {
    const fetch = switch (request_ctx.response_stream) {
        .fetch => |fetch| fetch,
        .none, .body_stream => return false,
    };
    if (fetch.failed)
        return true;
    const body = runtime.egress.state.bodies.get(fetch.identity.body_id) orelse return true;
    return body.isFailed();
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
    if (request_ctx.response_credit.available() == 0) {
        request_ctx.response_advance.wait = .credit;
        return;
    }
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
