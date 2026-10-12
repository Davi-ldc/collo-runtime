//! Streams a response whose body is a ReadableStream the handler's Response
//! carried, which the bridge locked at extraction (`ResponseBodyStream` in
//! `bindings/root.zig`). The head goes out first; then the stream is read one
//! chunk at a time, and each chunk goes out through the same writer, payload
//! ring and outbox as a fetch body's (`response_payload_writer.zig`,
//! `response.zig`) before the next read starts. The request finishes when the
//! stream closes and its end is sent; a stream that errors resets the
//! client's stream instead of ending it. Runs on the worker's VM thread.
//!
//! Every step that can run the tenant's JavaScript runs inside the request's
//! owner window (`runtime/owner.zig`), so the request's deadline and CPU
//! budget bound the whole stream and its record counts every window: a read
//! starts in a turn of the request, from `start` inside the window of the
//! work item that wrote the response or from the request's own
//! `response_body_stream` work item; the read's reaction runs under the
//! request that registered it; and the cancel runs inside the window that
//! `release` opens. The loop's flush, which runs outside every window, never
//! reads: once it sent a parked step it queues the work item instead
//! (`readNextAfterFlush`).

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
/// room, in which case the flush asks for the first read once it sent it.
/// Finishes nothing: the stream's end or failure does. The caller is inside
/// the request's owner window, and on failure the stream already belongs to
/// the request, whose finish releases it.
pub fn start(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    response: *response_model.Response,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !void {
    var stream = response.body.takeBodyStream() orelse return error.InvalidResponseBody;
    if (request_ctx.response_stream != .none) {
        stream.deinit();
        return error.ResponseBodyStreamAlreadyPending;
    }
    request_ctx.response_stream = .{ .body_stream = .{ .stream = stream } };
    request_ctx.response_done_status = done_status;
    request_ctx.response_http_status = http_status;

    switch (try payload_writer.writeStreamHead(runtime, request_ctx, response)) {
        .sent => {},
        .blocked => {
            var head = try payload_writer.pendingHead(runtime, response, false);
            errdefer head.deinit(runtime.core.allocator);
            try request_ctx.response_outbox.park(.{ .stream_head = head });
            return;
        },
    }
    try startRead(runtime, request_ctx);
}

/// Takes `result`, the outcome `collo_runtime_response_body_stream_settled`
/// reported for request `request_id`, on every path. A result for a request
/// that is gone, finishing, or not waiting for a read is dropped: the bridge
/// reports a read once, so such a result outlived the read it answers.
/// Otherwise it waits on the request for the request's work item, which this
/// queues; the call itself comes from a microtask drain, where nothing may be
/// sent or finished.
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
    // A full ready queue leaves the item to the ingress rescan, which finds
    // this result through `response_stream.wantsAdvance`.
    _ = response_stream.queueAdvance(runtime, request_id, &request_ctx.response_stream);
}

/// The `response_body_stream` work item of request `request_id`, run in the
/// request's owner window: sends the chunk a read returned and starts the
/// next read once all of it went out, sends the end of a stream that closed,
/// or resets the client's stream for one that errored. A step parked in the
/// outbox goes first; the flush queues this item again once it is sent.
pub fn execute(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    const body_stream = bodyStreamOf(request_ctx) orelse return;
    body_stream.advance_queued = false;
    if (request_ctx.finish_started)
        return;
    if (!request_ctx.response_outbox.isEmpty())
        return;

    var result = body_stream.result.take();
    defer result.deinit();
    switch (result) {
        .none => {
            if (body_stream.read_next and !body_stream.reading)
                try startRead(runtime, request_ctx);
        },
        .chunk => |*chunk| try writeChunk(runtime, request_ctx, chunk),
        .done => try endStream(runtime, request_ctx),
        .failed => |*reason| try failStream(runtime, request_ctx, if (reason.*) |*value| value else null),
    }
}

/// Asks the request's work item for the next read, for the flush, which
/// just sent the step the response had parked and runs outside every owner
/// window, so it cannot read itself. Does nothing for another source.
pub fn readNextAfterFlush(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) void {
    const body_stream = bodyStreamOf(request_ctx) orelse return;
    body_stream.read_next = true;
    _ = response_stream.queueAdvance(runtime, request_ctx.exec.request_id, &request_ctx.response_stream);
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

/// Sends the bytes of `chunk`, a read's value, and reads on once they all
/// went out. The bytes are borrowed from the tenant's buffer, which stays in
/// place while no script runs, so they are written at once, and only a rest
/// that finds no room is copied into the outbox.
fn writeChunk(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    chunk_value: *const bindings.Value,
) !void {
    const body_stream = bodyStreamOf(request_ctx) orelse return;
    var chunk = switch (try body_stream.stream.chunk(chunk_value)) {
        .success => |lent| lent,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            try rejectChunk(runtime, request_ctx, &owned);
            return;
        },
    };
    defer chunk.deinit();

    const bytes = chunk.slice();
    var sent_len: usize = 0;
    switch (try payload_writer.writeStreamBytes(runtime, request_ctx, bytes, &sent_len, false)) {
        .sent => try startRead(runtime, request_ctx),
        .ring_full, .socket_full => {
            const rest = try runtime.core.allocator.dupe(u8, bytes[sent_len..]);
            errdefer runtime.core.allocator.free(rest);
            try request_ctx.response_outbox.park(.{ .stream_chunk = .{
                .bytes = .{ .owned = rest },
                .done = false,
            } });
        },
    }
}

/// A chunk that is not bytes, or whose buffer was detached, ends the
/// response: the TypeError goes to the tenant's log, the stream is cancelled
/// with it, and the client's stream is reset.
fn rejectChunk(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    exception: *const bindings.Value,
) !void {
    exception_log.logException(runtime.core.vm, request_ctx.exec.request_id, exception, "response body stream chunk");
    release(runtime, request_ctx, .invalid_chunk);
    try response_flow.failResponse(runtime, request_ctx, .js_exception, request_ctx.response_http_status);
}

/// The stream closed: its end goes out, now or from the flush, and then the
/// request finishes with the response's statuses.
fn endStream(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !void {
    switch (try payload_writer.writeStreamEnd(runtime, request_ctx)) {
        .sent => try response_flow.finishResponseStream(runtime, request_ctx),
        .blocked => try request_ctx.response_outbox.park(.stream_end),
    }
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
