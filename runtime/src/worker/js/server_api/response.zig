//! Turns the Response a handler returned into the worker's response model:
//! extracts it from JavaScript in a turn, checks it against the worker's
//! response bounds and hands it to the serve layer to write. It belongs to
//! the `worker` module and runs on the VM thread.
//!
//! A response that fails extraction or the checks is answered with a 500
//! instead. A streamed fetch body is released through the runtime on every
//! path that does not hand it to the writer.

const std = @import("std");
const bindings = @import("collo_bindings");
const limits = @import("collo_limits");
const request_context = @import("collo_worker_request").context;
const request_response = @import("../../serve/response.zig");
const response_model = @import("collo_worker_request").response_model;
const state = @import("../../runtime/root.zig");
const turn = @import("collo_worker_js").turn;
const ipc = @import("collo_ipc");

/// Writes the response and finishes the request. The last two arguments are
/// the done status and the HTTP status recorded for the request. The writer
/// may take the body out of the response; the caller releases whatever it
/// leaves.
pub const WriteAndFinishFn = *const fn (
    *state.Runtime,
    *request_context.RequestContext,
    *response_model.Response,
    ipc.RequestDoneStatus,
    u16,
) anyerror!void;

/// Writes `value`, the handler's borrowed result, as the answer to `request`
/// through `write_and_finish`. An extraction or validation failure is logged
/// and answered with a 500 instead. Fails only when `write_and_finish` fails.
pub fn writeValueResponse(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    value: *const bindings.Value,
    write_and_finish: WriteAndFinishFn,
) !void {
    runtime.observability.response_extraction_count += 1;
    var extracted = extractNativeResponse(runtime, request, value) catch |err| {
        std.log.warn("response extraction failed request_id={d}: {s}", .{ request.exec.request_id, @errorName(err) });
        try writeInternalErrorResponse(runtime, request, write_and_finish, "invalid response");
        return;
    };
    defer extracted.deinit(runtime);

    var owned_response = extracted.toResponse();
    defer deinitResponseBody(runtime, &owned_response);
    response_model.validate(owned_response) catch |err| {
        std.log.warn("response validation failed request_id={d}: {s}", .{ request.exec.request_id, @errorName(err) });
        try writeInternalErrorResponse(runtime, request, write_and_finish, "invalid response");
        return;
    };

    try write_and_finish(runtime, request, &owned_response, .ok, extracted.status);
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

/// Extracts the Response `value` in a turn, checks it and takes its status,
/// headers and body. A JavaScript exception during extraction is released
/// and returned as `error.JsException`; a failed check returns its error.
fn extractNativeResponse(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    value: *const bindings.Value,
) !ExtractedHandlerResult {
    var host = switch (try turn.extractResponse(runtime.core.vm, &request.exec, value, response_model.extractionLimits())) {
        .success => |response| response,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.JsException;
        },
    };
    defer host.deinit();
    var host_stream_moved = false;
    errdefer {
        if (!host_stream_moved and host.hasFetchBodyStream())
            _ = runtime.releaseFetchBody(host.body.stream_identity);
    }

    try validateHostResponseShape(host, request);

    var extracted = ExtractedHandlerResult{
        .status = host.status,
        .headers = .empty,
        .header_block = host.takeHeaders(),
        .body = if (host.hasFetchBodyStream()) blk: {
            host_stream_moved = true;
            break :blk .{ .fetch_stream = host.body.stream_identity };
        } else .{ .abi = host.takeBody() },
    };
    errdefer extracted.deinit(runtime);

    for (extracted.header_block.headersSlice()) |header| {
        const name = extracted.header_block.nameSlice(header);
        if (shouldDropHostHeader(host, name)) {
            continue;
        }
        const header_value = extracted.header_block.valueSlice(header);
        try response_model.validateHeader(name, header_value);
        try extracted.headers.append(runtime.core.allocator, .{ .name = name, .value = header_value });
    }

    return extracted;
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

/// Answers with status 500 and `body`, recording the request as an internal
/// error.
fn writeInternalErrorResponse(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    write_and_finish: WriteAndFinishFn,
    body: []const u8,
) !void {
    var error_response = response_model.Response{
        .status = 500,
        .body = .{ .bytes = body },
    };
    try write_and_finish(runtime, request, &error_response, .internal_error, 500);
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
