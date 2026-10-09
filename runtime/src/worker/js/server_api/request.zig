//! Builds the `Request` object a handler receives from a dispatched request
//! whose head passed `request/head.zig`. The engine bridge copies every
//! string, so the object outlives the dispatch it was built from. It runs on
//! the worker's VM thread.
//!
//! `request.url` is `https://` followed by the dispatch's authority, the
//! path and the query (`collo_request_new` in
//! `bindings/host_functions/server/fetch/request.cpp`): the server speaks
//! TLS only, and the host normalizes the authority before dispatch.

const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const request_head = @import("collo_worker_request").head;
const request_context = @import("collo_worker_request").context;
const state = @import("../../runtime/root.zig");

/// Creates the handler's `Request` for `request`. A head with more headers
/// or route captures than the dispatch format allows fails with
/// `error.InvalidDispatchRequestHead`, and an exception while the object is
/// built is released and returned as `error.JsException`.
pub fn makeRequestObject(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    parsed: *const request_head.ParsedHead,
) !bindings.Value {
    var header_storage: [ipc.max_request_header_count]bindings.NameValuePair = undefined;
    if (parsed.headers.len > header_storage.len)
        return error.InvalidDispatchRequestHead;
    const headers = header_storage[0..parsed.headers.len];
    for (parsed.headers, 0..) |header, index| {
        headers[index] = .{
            .name = borrowedString(header.name),
            .value = borrowedString(header.value),
        };
    }

    var param_storage: [ipc.max_route_capture_count]bindings.NameValuePair = undefined;
    if (request.dispatch_work.route_captures.len > param_storage.len)
        return error.InvalidDispatchRequestHead;
    const params = param_storage[0..request.dispatch_work.route_captures.len];
    for (request.dispatch_work.route_captures, 0..) |capture, index| {
        params[index] = .{
            .name = borrowedString(capture.name),
            .value = borrowedString(capture.value),
        };
    }

    const init = bindings.RequestInit{
        .method = borrowedString(request.dispatch_work.method),
        .path = borrowedString(request.dispatch_work.path),
        .raw_query = borrowedString(request.dispatch_work.raw_query),
        .authority = borrowedString(request.dispatch_work.authority),
        .headers = if (headers.len == 0) null else headers.ptr,
        .headers_len = headers.len,
        .params = if (params.len == 0) null else params.ptr,
        .params_len = params.len,
        .identity = .{
            .request_id = request.exec.request_id,
            .request_generation = request.request_generation,
        },
    };

    return switch (try runtime.core.vm.requestValue(&init)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.JsException;
        },
    };
}

fn borrowedString(value: []const u8) bindings.RawString {
    return .{
        .ptr = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}
