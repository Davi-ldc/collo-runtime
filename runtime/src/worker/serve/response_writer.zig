//! Writes a buffered response to the host over the ingress channel and
//! finishes the request. A small body rides one inline batch with its head;
//! a larger one goes as chunks, inline or through the shared payload ring.
//! When the control socket or the ring has no room, the rest of the response
//! waits in the request's outbox, with its head when the head has not gone
//! out, and the outbox flush sends it and finishes the request
//! (`serve/response.zig`). It runs on the worker's VM thread.

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const request_context = @import("collo_worker_request").context;
const ingress_response = @import("collo_worker_request").http2.response;
const response_model = @import("collo_worker_request").response_model;
const response_outbox = @import("collo_worker_request").ingress.response_outbox;
const response_finish = @import("response_finish.zig");
const response_payload_writer = @import("response_payload_writer.zig");
const state = @import("../runtime/root.zig");
const tracing = @import("trace.zig");

/// Finishes the request with a done status and an HTTP status.
pub const FinishFn = *const fn (
    *state.Runtime,
    *request_context.RequestContext,
    ipc.RequestDoneStatus,
    u16,
) anyerror!response_finish.FinishOutcome;

/// Writes `response`, whose body is not a stream, and calls `finish_request`
/// once every byte is sent. When part of the response waits in the outbox,
/// the outbox flush finishes the request instead.
pub fn writeAndFinish(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *response_model.Response,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
    finish_request: FinishFn,
) !void {
    tracing.mark(runtime, request_ctx, "response_extract_done_ns");

    const response_body_len = response.body.len();
    const response_body = response.body.contiguous();
    const contiguous = response_body.len == response_body_len;
    var body_offset = try writeHead(
        runtime,
        request_ctx,
        response,
        if (contiguous) response_body else null,
    ) orelse {
        var head = try response_payload_writer.pendingHead(runtime, response, response_body_len == 0);
        errdefer head.deinit(runtime.core.allocator);
        try parkBody(runtime, request_ctx, response, head, 0, done_status, http_status);
        return;
    };
    const progress = if (contiguous)
        try response_payload_writer.writeBody(runtime, request_ctx, response_body, &body_offset)
    else
        try response_payload_writer.writeSegmentedBody(
            runtime,
            request_ctx,
            response.body.segments(),
            response_body_len,
            &body_offset,
        );
    switch (progress) {
        .sent => {},
        .ring_full, .socket_full => {
            try parkBody(runtime, request_ctx, response, null, body_offset, done_status, http_status);
            return;
        },
    }

    tracing.mark(runtime, request_ctx, "response_write_done_ns");
    _ = try finish_request(runtime, request_ctx, done_status, http_status);
}

/// Sends the head of `response`, with the first bytes of `contiguous_body`
/// when they fit one batch, and returns the body offset after them. A
/// segmented body, passed as null, goes after a head of its own. Returns
/// null when the control socket was full and nothing went out.
fn writeHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    contiguous_body: ?[]const u8,
) !?usize {
    if (contiguous_body) |body| {
        switch (try writeSmallInlineBatch(runtime, request_ctx, response, body)) {
            .unbatched => {},
            .sent => |body_offset| return body_offset,
            .blocked => return null,
        }
        switch (try response_payload_writer.trySendInitialRingBatch(runtime, request_ctx, response, body)) {
            .unbatched => {},
            .sent => |body_offset| return body_offset,
            .blocked => return null,
        }
    }
    return switch (try response_payload_writer.sendHeadOnly(runtime, request_ctx, response, response.body.len() == 0)) {
        .sent => 0,
        .blocked => null,
    };
}

/// Sends the head and a body of at most `shared_payload_threshold` bytes
/// inline in one batch, which commits the response.
fn writeSmallInlineBatch(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    response_body: []const u8,
) !response_payload_writer.HeadBatch {
    const control_fd = runtime.core.control_fd orelse return error.InvalidArgument;
    const small_body_batch_limit = @min(
        ipc.ingress_channel.shared_payload_threshold,
        limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES,
    );
    var small_batch_entries: [2]ipc.ingress_channel.BatchEntry = undefined;
    const entries = try ingress_response.tryEncodeInlineHeadBodyBatch(
        runtime.core.dispatch_recv_scratch,
        response_payload_writer.h2Identity(request_ctx),
        request_ctx.ingress_channel_id,
        response.status,
        response.headers,
        response_body,
        small_body_batch_limit,
        &small_batch_entries,
    ) orelse return .unbatched;

    switch (try response_payload_writer.sentOrBlocked(runtime, ipc.ingress_channel.sendDescriptorBatchPayloads(
        control_fd,
        entries,
        runtime.core.dispatch_recv_scratch,
    ))) {
        .sent => {},
        .blocked => return .blocked,
    }
    request_ctx.client_served_bytes += response_body.len;
    request_ctx.markResponseCommitted();
    return .{ .sent = response_body.len };
}

/// Moves the body out of `response` into the request's outbox with
/// `body_offset` bytes already sent, behind `head` when the head has not
/// gone out. The outbox owns `head` once this returns; on failure the caller
/// still does. The outbox flush sends the rest and finishes the request with
/// the two statuses.
fn parkBody(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *response_model.Response,
    head: ?response_outbox.PendingHead,
    body_offset: usize,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !void {
    const response_body_len = response.body.len();
    std.debug.assert(body_offset <= response_body_len);
    const body = try response.body.takeOwnedBytes(runtime.core.allocator);
    errdefer runtime.core.allocator.free(body);
    if (body.len != response_body_len)
        return error.InvalidResponseBody;

    try request_ctx.response_outbox.park(.{ .buffered_body = .{
        .head = head,
        .body = body,
        .offset = body_offset,
        .done_status = done_status,
        .http_status = http_status,
    } });
}
