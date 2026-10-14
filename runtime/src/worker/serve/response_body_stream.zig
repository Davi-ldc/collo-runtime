//! Streams a response whose body is a ReadableStream the handler's Response
//! carried, which the bridge locked at extraction (`ResponseBodyStream` in
//! `bindings/root.zig`). The head goes out first; then the stream is read one
//! chunk at a time, and each chunk goes out through the same writer as a
//! fetch body's (`response_payload_writer.zig`) before the next read starts.
//! A chunk must be an ArrayBuffer or an ArrayBufferView, as the Fetch
//! Standard requires; anything else, a string included, errors the stream
//! with a TypeError. The request finishes when the stream closes and its end
//! is sent; a stream that errors resets the client's stream instead of
//! ending it. Runs on the worker's VM thread.
//!
//! Every step that can run the tenant's JavaScript runs inside the request's
//! owner window (`runtime/owner.zig`), so the request's deadline and CPU
//! budget bound the whole stream and its record counts every window: a read
//! starts in a turn of the request, from `start` inside the window of the
//! work item that wrote the response or from the request's
//! `response_advance` item; the read's reaction runs under the request that
//! registered it; and the cancel runs inside the window that `release`
//! opens. A chunk that waits for credit or room stays rooted in
//! `request/response_stream.zig:BodyStream`, and each try borrows its bytes
//! again, since a call into the VM may move or detach them.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const exception_log = @import("collo_worker_js").exception_log;
const turn = @import("collo_worker_js").turn;
const request_context = @import("collo_worker_request").context;
const response_model = @import("collo_worker_request").response_model;
const response_stream = @import("collo_worker_request").response_stream;
const payload_writer = @import("response_payload_writer.zig");
const response_flow = @import("response.zig");
const runtime_owner = @import("../runtime/owner.zig");
const state = @import("../runtime/root.zig");

/// Sends the head of `response`, whose body is a body stream it takes, and
/// starts the first read, or parks the head when the control socket has no
/// room, in which case the advance that sends it asks for the first read.
/// Finishes nothing: the stream's end or failure does. The caller is inside
/// the request's owner window, and on failure the stream already belongs to
/// the request, whose finish releases it.
pub fn start(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *response_model.Response,
) !void {
    var stream = response.body.takeBodyStream() orelse return error.InvalidResponseBody;
    if (request_ctx.response_stream != .none) {
        stream.deinit();
        return error.ResponseBodyStreamAlreadyPending;
    }
    request_ctx.response_stream = .{ .body_stream = .{ .stream = stream } };

    switch (try payload_writer.writeStreamHead(runtime, request_ctx, response)) {
        .sent => {},
        .blocked => {
            var head = try payload_writer.pendingHead(runtime, response, false);
            errdefer head.deinit(runtime.core.allocator);
            try request_ctx.response_outbox.park(.{ .stream_head = head });
            return;
        },
        // A streamed response's head never ends its stream.
        .last => unreachable,
    }
    try startRead(runtime, request_ctx);
}

/// Takes `result`, the outcome `collo_runtime_response_body_stream_settled`
/// reported for request `request_id`, on every path. A result for a request
/// that is gone, finishing, or not waiting for a read is dropped: the bridge
/// reports a read once, so such a result outlived the read it answers.
/// Otherwise it waits on the request for the request's `response_advance`
/// item, which this queues; the call itself comes from a microtask drain,
/// where nothing may be sent or finished.
pub fn noteSettled(runtime: *state.Runtime, request_id: u64, result: response_stream.Result) void {
    var owned = result;
    const request_ctx = readingRequest(runtime, request_id) orelse {
        owned.deinit();
        return;
    };
    const body_stream = bodyStreamOf(request_ctx).?;
    body_stream.reading = false;
    switch (owned) {
        .none, .chunk => {},
        .done, .failed => body_stream.open = false,
    }
    body_stream.result = owned;
    // A full ready queue leaves the stamped advance for the ingress rescan.
    _ = response_stream.queueAdvance(runtime, request_ctx);
}

/// The body stream's part of the request's `response_advance` item, run in
/// the request's owner window once its outbox is empty: sends the chunk a
/// read returned and starts the next read once all of it went out, sends the
/// end of a stream that closed, or resets the client's stream for one that
/// errored.
pub fn execute(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    const body_stream = bodyStreamOf(request_ctx) orelse return;
    switch (body_stream.result) {
        .none => {
            if (body_stream.read_next and !body_stream.reading)
                try startRead(runtime, request_ctx);
        },
        .chunk => try writeChunk(runtime, request_ctx),
        .done => try endStream(runtime, request_ctx),
        .failed => |*reason| try failStream(runtime, request_ctx, if (reason.*) |*value| value else null),
    }
}

/// Takes the body stream off `request_ctx` and releases it; does nothing for
/// another source. A stream that has not reported its end is cancelled
/// first with `cancel`, when there is one (`cancelFor`), in a turn of the
/// request inside its owner window, which this opens when the caller runs
/// outside it. A failed cancel is logged: the stream is released either way.
pub fn release(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    cancel: ?bindings.ResponseBodyStreamCancel,
) void {
    var body_stream = switch (request_ctx.response_stream) {
        .body_stream => |held| held,
        .none, .fetch => return,
    };
    // Off the context before the cancel's drain, so the done result that
    // drain reports for a read in flight finds no stream to park on.
    request_ctx.response_stream = .none;
    defer body_stream.deinit();
    if (!body_stream.open)
        return;
    const reason = cancel orelse return;
    cancelInWindow(runtime, request_ctx, body_stream.stream, reason);
}

/// Releases `stream`, the body stream of a response that never started,
/// such as one that failed its checks after extraction: it is cancelled
/// with `response_failed` as `release` cancels, then destroyed.
pub fn discard(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    stream: *bindings.ResponseBodyStream,
) void {
    defer stream.deinit();
    cancelInWindow(runtime, request_ctx, stream.*, .response_failed);
}

/// Cancels `stream` with `reason` in a turn of the request, inside its owner
/// window, which this opens when the caller runs outside it. A failed cancel
/// is logged; the caller releases the stream either way.
fn cancelInWindow(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    stream: bindings.ResponseBodyStream,
    reason: bindings.ResponseBodyStreamCancel,
) void {
    const request_id = request_ctx.exec.request_id;
    const previous_owner_id = runtime_owner.enter(runtime, request_id, .{});
    defer runtime_owner.leave(runtime, previous_owner_id);
    turn.cancelResponseBodyStream(runtime.core.vm, &request_ctx.exec, stream, reason) catch |err|
        std.log.warn("response body stream cancel failed request_id={d}: {s}", .{ request_id, @errorName(err) });
}

/// The cancel a request that ends with `done_status` gives a body stream that
/// is still open. A cancel runs the tenant's cancel algorithm, so there is
/// none when the request has no budget left for it (its deadline or CPU) or
/// when the VM can no longer run its JavaScript: the stream is then released
/// as it is.
pub fn cancelFor(done_status: ipc.RequestDoneStatus) ?bindings.ResponseBodyStreamCancel {
    return switch (done_status) {
        .client_closed => .client_reset,
        .ok, .bad_request, .js_exception, .internal_error => .response_failed,
        .deadline_timeout, .cpu_exceeded, .worker_crash, .worker_retiring, .worker_stopped => null,
    };
}

/// Starts the next read in a turn of the request; the caller is inside the
/// request's owner window. Its result reaches `noteSettled`, during this
/// turn's drain when the stream had a chunk queued.
fn startRead(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !void {
    const body_stream = bodyStreamOf(request_ctx) orelse return;
    std.debug.assert(!body_stream.reading);
    std.debug.assert(body_stream.result == .none);
    if (request_ctx.response_credit.available() == 0) {
        body_stream.read_next = true;
        request_ctx.response_advance.wait = .credit;
        return;
    }
    body_stream.read_next = false;
    body_stream.reading = true;
    turn.readResponseBodyStream(runtime.core.vm, &request_ctx.exec, body_stream.stream) catch |err| {
        // The read never started, or its turn failed after it did; either
        // way no result is coming.
        if (bodyStreamOf(request_ctx)) |current|
            current.reading = false;
        return err;
    };
}

/// Sends the chunk in `BodyStream.result` from its offset, borrowing its
/// bytes for this try alone, and asks for the next read once all of it went
/// out. A chunk that does not all go out keeps its offset for the next try.
fn writeChunk(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !void {
    const body_stream = bodyStreamOf(request_ctx) orelse return;
    const bytes = switch (try body_stream.stream.chunk(&body_stream.result.chunk)) {
        .success => |lent| lent,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            try rejectChunk(runtime, request_ctx, &owned);
            return;
        },
    };
    if (body_stream.chunk_len) |expected| {
        if (bytes.len != expected or body_stream.offset > bytes.len)
            return error.InvalidResponseBodyChunk;
    } else {
        body_stream.chunk_len = bytes.len;
    }
    switch (try payload_writer.writeStreamBytes(runtime, request_ctx, bytes, &body_stream.offset, false, .hold)) {
        .sent => {},
        .credit_empty, .ring_full, .socket_full => return,
        // A chunk the stream's end follows never ends the response.
        .last => unreachable,
    }
    body_stream.result.deinit();
    body_stream.offset = 0;
    body_stream.chunk_len = null;
    body_stream.read_next = true;
    if (request_ctx.response_credit.available() == 0) {
        request_ctx.response_advance.wait = .credit;
    } else {
        _ = response_stream.queueAdvance(runtime, request_ctx);
    }
}

/// A chunk that is not bytes, a string included, or whose buffer was
/// detached, ends the response: the TypeError goes to the tenant's log, the
/// stream is cancelled with it, and the client's stream is reset.
fn rejectChunk(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    exception: *const bindings.Value,
) !void {
    exception_log.logException(runtime.core.vm, request_ctx.exec.request_id, exception, "response body stream chunk");
    release(runtime, request_ctx, .invalid_chunk);
    try response_flow.failResponse(runtime, request_ctx, .js_exception, request_ctx.response_http_status);
}

/// The stream closed: the request finishes with the response's statuses,
/// and its end goes out as the request's last packet, now or from a later
/// advance.
fn endStream(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !void {
    try response_flow.finishResponseStream(runtime, request_ctx, .stream_end);
}

/// The stream errored after the head went out. Its reason goes to the
/// tenant's log, and the client's stream is reset rather than ended, so the
/// client cannot take a truncated body for a whole one.
fn failStream(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    reason: ?*const bindings.Value,
) !void {
    const request_id = request_ctx.exec.request_id;
    if (reason) |value| {
        exception_log.logException(runtime.core.vm, request_id, value, "response body stream");
    } else {
        std.log.warn("response body stream failed without a reason request_id={d}", .{request_id});
    }
    try response_flow.failResponse(runtime, request_ctx, .js_exception, request_ctx.response_http_status);
}

/// The request `request_id` names while it waits for a read of its body
/// stream: active, not finishing, a read in flight and no result parked.
fn readingRequest(runtime: *state.Runtime, request_id: u64) ?*request_context.RequestContext {
    if (request_id == 0 or request_context.isReservedId(request_id))
        return null;
    const request_ctx = runtime.requests.active.get(request_id) orelse return null;
    if (request_ctx.finish_started)
        return null;
    const body_stream = bodyStreamOf(request_ctx) orelse return null;
    if (!body_stream.reading)
        return null;
    if (body_stream.result != .none)
        return null;
    return request_ctx;
}

fn bodyStreamOf(request_ctx: *request_context.RequestContext) ?*response_stream.BodyStream {
    return switch (request_ctx.response_stream) {
        .body_stream => |*body_stream| body_stream,
        .none, .fetch => null,
    };
}
