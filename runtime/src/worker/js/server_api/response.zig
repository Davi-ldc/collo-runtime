//! Turns the Response a handler returned into the worker's response model:
//! extracts it from JavaScript in a turn, checks it against the worker's
//! response bounds and hands it to the serve layer to write. It belongs to
//! the `worker` module and runs on the VM thread.
//!
//! An extraction that throws is answered as any exception of the request is
//! (`serve/termination.zig:answerException`). A response that fails the
//! checks is named in the tenant's log and answered with a 500 instead. A
//! streamed fetch body is released through the runtime on every path that
//! does not hand it to the writer, and a ReadableStream body the checks
//! refuse is cancelled (`serve/response_body_stream.zig:discard`).

const std = @import("std");
const bindings = @import("collo_bindings");
const limits = @import("collo_limits");
const exception_log = @import("collo_worker_js").exception_log;
const request_context = @import("collo_worker_request").context;
const request_response = @import("../../serve/response.zig");
const response_body_stream = @import("../../serve/response_body_stream.zig");
const response_model = @import("collo_worker_request").response_model;
const state = @import("../../runtime/root.zig");
const termination = @import("../../serve/termination.zig");
const turn = @import("collo_worker_js").turn;

/// Writes `value`, the handler's borrowed result, as the answer to `request`
/// and finishes the request (`serve/response.zig:writeAndFinishResponse`).
/// An extraction that throws answers as the exception it threw; a response
/// that fails a check writes one line naming the check to the tenant's log
/// and answers 500 instead. Fails only when writing an answer fails.
pub fn writeValueResponse(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    value: *const bindings.Value,
) !void {
    const extraction = extractNativeResponse(runtime, request, value) catch |err| switch (err) {
        // The request's boundary decides what running out of memory means
        // (`handleLocalFailure` in `serve/dispatch.zig`); it is no check
        // the tenant's response failed.
        error.OutOfMemory => return err,
        else => {
            try answerInvalidResponse(runtime, request, err);
            return;
        },
    };
    var extracted = switch (extraction) {
        .extracted => |extracted| extracted,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            try termination.answerException(runtime, request, &owned, "response extraction");
            return;
        },
    };
    defer extracted.deinit(runtime);

    var owned_response = extracted.toResponse();
    defer deinitResponseBody(runtime, &owned_response);
    response_model.validate(owned_response) catch |err| {
        try answerInvalidResponse(runtime, request, err);
        return;
    };

    try request_response.writeAndFinishResponse(runtime, request, &owned_response, .ok, extracted.status);
}

/// What extracting a handler's result gave: the response, or the exception
/// the extraction's JavaScript threw, which the caller owns.
const Extraction = union(enum) {
    extracted: ExtractedHandlerResult,
    exception: bindings.Value,
};

/// Answers a response the worker refused, `err` naming the failed check, as
/// a 500 that records the request as an internal error. The check's name
/// goes to the tenant's log under the request's id, since the tenant's
/// handler returned the response.
fn answerInvalidResponse(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    err: anyerror,
) !void {
    var line_buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "invalid response: {s}", .{@errorName(err)}) catch
        "invalid response";
    exception_log.logMessage(runtime.core.vm, request.exec.request_id, line);
    var error_response = response_model.Response{
        .status = 500,
        .body = .{ .bytes = "invalid response" },
    };
    try request_response.writeAndFinishResponse(runtime, request, &error_response, .internal_error, 500);
}

const ExtractedHandlerResult = struct {
    status: u16,
    /// The kept headers, whose names and values point into `header_block`.
    headers: std.array_list.Aligned(response_model.Header, null),
    header_block: bindings.ExtractedHeaderBlock = .{},
    body: response_model.Body,

    fn deinit(self: *ExtractedHandlerResult, runtime: *state.Runtime) void {
        deinitExtractedBody(runtime, &self.body);
        self.headers.deinit(runtime.core.allocator);
        self.header_block.deinit();
        self.* = undefined;
    }

    /// Moves the body into the returned response, which borrows the headers
    /// and so must not outlive `self`.
    fn toResponse(self: *ExtractedHandlerResult) response_model.Response {
        const body = self.body;
        self.body = .empty;
        return .{
            .status = self.status,
            .headers = self.headers.items,
            .body = body,
        };
    }
};

/// Extracts the Response `value` in a turn, in the realm of the request's
/// route, checks it and takes its status, headers and body. A JavaScript
/// exception during extraction comes back as `.exception`, which the caller
/// owns; a failed check returns its error.
fn extractNativeResponse(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    value: *const bindings.Value,
) !Extraction {
    const realm = runtime.realmOfRoute(request.dispatch_work.route_index);
    var host = switch (try turn.extractResponse(runtime.core.vm, realm, &request.exec, value, response_model.extractionLimits())) {
        .success => |response| response,
        .exception => |exception| return .{ .exception = exception },
    };
    defer host.deinit();
    var host_stream_moved = false;
    errdefer {
        if (!host_stream_moved and host.hasFetchBodyStream())
            _ = runtime.releaseFetchBody(host.body.stream_identity);
    }

    validateHostResponseShape(host, request) catch |err| {
        // A refused body stream is cancelled, so the tenant's source learns
        // that nothing will read it, rather than only destroyed unread.
        if (host.body.takeBodyStream()) |stream| {
            var refused = stream;
            response_body_stream.discard(runtime, request, &refused);
        }
        return err;
    };

    var extracted = ExtractedHandlerResult{
        .status = host.status,
        .headers = .empty,
        .header_block = host.takeHeaders(),
        .body = if (host.hasFetchBodyStream()) blk: {
            host_stream_moved = true;
            break :blk .{ .fetch_stream = host.body.stream_identity };
        } else if (host.body.takeBodyStream()) |stream|
            .{ .body_stream = stream }
        else
            .{ .abi = host.takeBody() },
    };
    errdefer extracted.deinit(runtime);

    // `validateHostResponseShape` checked every header kept here.
    try extracted.headers.ensureTotalCapacityPrecise(runtime.core.allocator, extracted.header_block.headersSlice().len);
    for (extracted.header_block.headersSlice()) |header| {
        const name = extracted.header_block.nameSlice(header);
        if (shouldDropHostHeader(host, name)) {
            continue;
        }
        extracted.headers.appendAssumeCapacity(.{ .name = name, .value = extracted.header_block.valueSlice(header) });
    }

    return .{ .extracted = extracted };
}

/// Checks the extracted response before any of it is kept: the body kind, a
/// materialized body's length against `MATERIALIZED_BODY_BYTES_MAX` and
/// against its segments, a streamed body's owner, and each header the
/// response keeps, with their count and bytes. A streamed body must come from
/// this request, id and generation both, so a handler cannot answer with a
/// fetch body another request opened.
fn validateHostResponseShape(
    host: bindings.ExtractedResponse,
    request: *const request_context.RequestContext,
) !void {
    switch (host.body.kind) {
        bindings.extracted_response_body_empty,
        bindings.extracted_response_body_bytes,
        bindings.extracted_response_body_byte_segments,
        => {
            if (host.body.total_len > limits.http_body.MATERIALIZED_BODY_BYTES_MAX)
                return error.ResponseBodyTooLarge;
            const segments = host.body.segmentsSlice();
            if (host.body.total_len != 0 and segments.len == 0)
                return error.InvalidResponseBody;
            var total_len: usize = 0;
            for (segments) |segment| {
                const bytes = segment.slice();
                total_len = std.math.add(usize, total_len, bytes.len) catch
                    return error.InvalidResponseBody;
            }
            if (total_len != host.body.total_len)
                return error.InvalidResponseBody;
        },
        bindings.extracted_response_body_fetch_stream => {
            const identity = host.body.stream_identity;
            if (identity.request_id != request.exec.request_id)
                return error.FetchBodyOutsideActiveRequest;
            if (identity.request_generation != request.request_generation)
                return error.FetchBodyOutsideActiveRequest;
        },
        // A stream has no length to bound; its chunks pass the payload
        // writer's own bounds as they are sent.
        bindings.extracted_response_body_readable_stream => {},
        else => return error.InvalidResponseBody,
    }

    const headers = host.headers.headersSlice();
    if (headers.len > response_model.max_response_header_count)
        return error.ResponseHeadersTooLarge;

    var kept_headers: usize = 0;
    var header_bytes: usize = 0;
    for (headers) |header| {
        const name = host.headers.nameSlice(header);
        if (shouldDropHostHeader(host, name)) {
            continue;
        }
        const value = host.headers.valueSlice(header);
        try response_model.validateHeader(name, value);
        kept_headers += 1;
        if (kept_headers > response_model.max_response_header_count)
            return error.ResponseHeadersTooLarge;
        header_bytes = std.math.add(usize, header_bytes, name.len) catch return error.ResponseHeadersTooLarge;
        header_bytes = std.math.add(usize, header_bytes, value.len) catch return error.ResponseHeadersTooLarge;
        if (header_bytes > response_model.max_response_header_bytes)
            return error.ResponseHeadersTooLarge;
    }
}

/// A body streamed from a fetch response arrives with that response's
/// headers. Its framing headers are ones `response_model.validateHeader`
/// rejects, although the handler never chose them, and its content-encoding
/// no longer describes the body, whose bytes are decoded before they reach
/// the stream. For such a body those headers are dropped rather than failing
/// the response.
fn shouldDropHostHeader(host: bindings.ExtractedResponse, name: []const u8) bool {
    if (!host.hasFetchBodyStream())
        return false;
    if (std.ascii.eqlIgnoreCase(name, "content-length"))
        return true;
    if (std.ascii.eqlIgnoreCase(name, "connection"))
        return true;
    if (std.ascii.eqlIgnoreCase(name, "transfer-encoding"))
        return true;
    if (std.ascii.eqlIgnoreCase(name, "content-encoding"))
        return true;
    return false;
}

fn deinitResponseBody(runtime: *state.Runtime, response: *response_model.Response) void {
    deinitExtractedBody(runtime, &response.body);
}

/// A streamed fetch body goes back to the runtime, which owns it; any other
/// body is freed.
fn deinitExtractedBody(runtime: *state.Runtime, body: *response_model.Body) void {
    switch (body.*) {
        .fetch_stream => |identity| {
            _ = runtime.releaseFetchBody(identity);
            body.* = .empty;
        },
        else => body.deinitOwned(runtime.core.allocator),
    }
}
