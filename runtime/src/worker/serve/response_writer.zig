//! Writes a buffered or segmented response to the host over the ingress
//! channel and finishes the request. A small body rides one inline batch
//! with its head; a larger one goes as chunks, inline or through the shared
//! payload ring. The packet that ends the response goes out from the
//! request's finish, with the request's `request_done`
//! (`response_finish.zig:LastStep.response`). When the request has no
//! credit, or the control socket or the ring has no room, the rest of the
//! response waits in the request's outbox, with its head when the head has
//! not gone out, and the request's advance sends it and finishes the request
//! (`response.zig`). It runs on the worker's VM thread.

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

/// Writes `response`, whose body is not a stream, up to the packet that ends
/// it, and finishes the request with the statuses in its context, which
/// sends that packet. When part of the response waits in the outbox, the
/// advance that sends it finishes the request instead. The request's
/// response has not committed: this is its first write, or an answer in
/// place of one whose head never went out
/// (`response.zig:replaceUnsentResponse`).
pub fn writeAndFinish(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *response_model.Response,
) !void {
    // Every chunk goes out with or after the head, so a response that has
    // not committed has spent no credit, and its first chunk always fits.
    std.debug.assert(!request_ctx.response_committed);
    std.debug.assert(request_ctx.response_credit.spent == 0);

    var head_sent = false;
    var body_offset: usize = 0;
    switch (try writeRest(runtime, request_ctx, response, &head_sent, &body_offset, .hold)) {
        .last => {},
        .credit_empty, .ring_full, .socket_full => {
            try parkRest(runtime, request_ctx, response, head_sent, body_offset);
            return;
        },
        // A held write stops before the packet that ends the response, which
        // every buffered response has.
        .sent => unreachable,
    }
    _ = try response_finish.finishRequest(
        runtime,
        request_ctx,
        request_ctx.response_done_status,
        request_ctx.response_http_status,
        .{ .response = .{ .response = response, .head_sent = head_sent, .body_offset = body_offset } },
    );
}

/// Sends the rest of `response` from `body_offset.*`, its head first unless
/// `head_sent.*`, and updates both as packets go out. The packet that ends
/// the response is held or carries the request's `request_done` (`ending`).
pub fn writeRest(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    head_sent: *bool,
    body_offset: *usize,
    ending: response_payload_writer.Ending,
) !response_payload_writer.BodyProgress {
    const response_body_len = response.body.len();
    const response_body = response.body.contiguous();
    const contiguous = response_body.len == response_body_len;
    if (!head_sent.*) {
        switch (try writeHead(runtime, request_ctx, response, if (contiguous) response_body else null, ending)) {
            .sent => |offset| {
                head_sent.* = true;
                body_offset.* = offset;
            },
            .blocked => return .socket_full,
            .last => return .last,
        }
        // A head sent with the whole body, or over an empty one, was the
        // response's last packet.
        if (body_offset.* == response_body_len)
            return .sent;
    }
    if (contiguous)
        return response_payload_writer.writeBody(runtime, request_ctx, response_body, body_offset, ending);
    return response_payload_writer.writeSegmentedBody(
        runtime,
        request_ctx,
        response.body.segments(),
        response_body_len,
        body_offset,
        ending,
    );
}

/// Moves what is left of `response`, its head unless `head_sent` and its
/// body from `body_offset`, into the request's outbox, where the advance
/// that sends it finds it.
pub fn parkRest(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *response_model.Response,
    head_sent: bool,
    body_offset: usize,
) !void {
    const head = if (head_sent) null else try response_payload_writer.pendingHead(runtime, response, response.body.len() == 0);
    var owned_head = head;
    errdefer if (owned_head) |*pending| pending.deinit(runtime.core.allocator);
    try parkBody(runtime, request_ctx, response, owned_head, body_offset);
    owned_head = null;
}

const HeadSent = union(enum) {
    /// The head went out, with the body up to this offset.
    sent: usize,
    blocked,
    last,
};

/// Sends the head of `response`, with the first bytes of `contiguous_body`
/// when they fit one batch, and returns the body offset after them. A
/// segmented body, passed as null, goes after a head of its own.
fn writeHead(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    contiguous_body: ?[]const u8,
    ending: response_payload_writer.Ending,
) !HeadSent {
    if (contiguous_body) |body| {
        switch (try writeSmallInlineBatch(runtime, request_ctx, response, body, ending)) {
            .unbatched => {},
            .sent => |body_offset| return .{ .sent = body_offset },
            .blocked => return .blocked,
            .last => return .last,
        }
        switch (try response_payload_writer.trySendInitialRingBatch(runtime, request_ctx, response, body, ending)) {
            .unbatched => {},
            .sent => |body_offset| return .{ .sent = body_offset },
            .blocked => return .blocked,
            .last => return .last,
        }
    }
    return switch (try response_payload_writer.sendHeadOnly(runtime, request_ctx, response, response.body.len() == 0, ending)) {
        .sent => .{ .sent = 0 },
        .blocked => .blocked,
        .last => .last,
    };
}

/// Sends the head and a body of at most `shared_payload_threshold` bytes
/// inline in one batch, which commits the response, spends one credit and
/// ends the response, so it carries the request's `request_done`; an empty
/// body is never batched.
fn writeSmallInlineBatch(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *const response_model.Response,
    response_body: []const u8,
    ending: response_payload_writer.Ending,
) !response_payload_writer.HeadBatch {
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
        true,
        &small_batch_entries,
    ) orelse return .unbatched;
    std.debug.assert(response_body.len != 0);
    const carry = switch (ending) {
        .hold => return .last,
        .carry => |carry| carry,
    };
    if (!try response_payload_writer.sendCarriedBatch(runtime, request_ctx, entries, carry, response_body.len))
        return .blocked;
    request_ctx.response_credit.spend(1);
    request_ctx.client_served_bytes += response_body.len;
    request_ctx.markResponseCommitted();
    return .{ .sent = response_body.len };
}

/// Moves the body out of `response` into the request's outbox with
/// `body_offset` bytes already sent, behind `head` when the head has not
/// gone out. The outbox owns `head` once this returns; on failure the caller
/// still does.
fn parkBody(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *response_model.Response,
    head: ?response_outbox.PendingHead,
    body_offset: usize,
) !void {
    const response_body_len = response.body.len();
    std.debug.assert(body_offset <= response_body_len);
    var body = try response.body.takeRetained(runtime.core.allocator);
    errdefer body.deinitOwned(runtime.core.allocator);
    if (body.len() != response_body_len)
        return error.InvalidResponseBody;

    try request_ctx.response_outbox.park(.{ .buffered_body = .{
        .head = head,
        .body = body,
        .offset = body_offset,
    } });
}
