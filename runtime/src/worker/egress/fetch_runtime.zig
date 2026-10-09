//! Starts a fetch for JS: checks it, registers its response body and task, and
//! sends its start to the gateway. Runs on the worker's event loop thread. The
//! gateway is the egress security boundary; the checks here only reject early
//! what it would refuse anyway. A scheduled task holds one reference on its
//! response body, and `State.bodies` holds another until the view is released.
//!
//! A fetch leaves only from an attached worker and only for a request that
//! carries an egress token (`refusal`), and a request starts no more fetches
//! than `RuntimeLimits.max_fetches_per_request`, which the token's budget
//! covers. The gateway counts a start it cannot verify, or one past the
//! budget, as an invalid command against the worker's session, so an honest
//! worker sends neither, with one exception the gateway's window absorbs: a
//! request dispatched before its worker was attached to a new gateway still
//! carries the old gateway's token, and its fetches fail there as forged, at
//! most `max_fetches_per_request` of them per request.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const egress_context = @import("context.zig");
const promise_deferred = @import("collo_worker_js").deferred;
const task_mod = @import("task.zig");
const fetch_body_runtime = @import("body/root.zig");
const gateway_control = @import("gateway_control.zig");
const upload_runtime = @import("upload_runtime.zig");

const FetchTask = task_mod.Task;

/// Why a fetch of a live request cannot leave the worker.
pub const Refusal = enum {
    /// The worker holds no gateway session: it booted without one, or its
    /// gateway closed and the server has not attached it to a new one.
    detached,
    /// The request's `DispatchWork` carries `egress_token.none`: the server
    /// minted no token for it, because the worker had no live session when
    /// the request was dispatched, or because the boot had no egress grant.
    no_egress_token,

    pub const Error = error{ FetchEgressDetached, FetchWithoutEgressToken };

    /// The TypeError message a refused fetch rejects with.
    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .detached => "fetch failed: no egress gateway",
            .no_egress_token => "fetch failed: the request has no egress token",
        };
    }

    /// The error `schedule` returns for the refusal.
    pub fn asError(self: Refusal) Error {
        return switch (self) {
            .detached => error.FetchEgressDetached,
            .no_egress_token => error.FetchWithoutEgressToken,
        };
    }
};

/// Whether a fetch of `request_id` would be refused before it leaves. Returns
/// null for a request that is not live, which `schedule` refuses on its own.
pub fn refusal(runtime: *egress_context.Context, request_id: u64) ?Refusal {
    const request = runtime.requests.get(request_id) orelse return null;
    if (runtime.egress_state.shared == null)
        return .detached;
    if (ipc.egress_token.isNone(&request.dispatch_work.egress_token))
        return .no_egress_token;
    return null;
}

/// Schedules a fetch for the live request `request_id` and returns its fetch
/// id. Takes ownership of `deferred` on every path; on success the task owns
/// it and `completion_runtime.execute` settles it. Fails with
/// `error.FetchOutsideActiveRequest`, with the error of its `refusal`
/// (`error.FetchEgressDetached`, `error.FetchWithoutEgressToken`),
/// `error.FetchWorkerLimitExceeded` at
/// `RuntimeLimits.max_fetches_per_worker` fetches in flight,
/// `error.FetchRequestLimitExceeded` once the request has started
/// `RuntimeLimits.max_fetches_per_request`, a URL or size error from the
/// start checks, or an error sending the start. Command-ring and upload-pool
/// backpressure only park the task.
pub fn schedule(
    runtime: *egress_context.Context,
    request_id: u64,
    url: []const u8,
    method: []const u8,
    body: []const u8,
    headers: []const bindings.NameValuePair,
    flags: u32,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    var owned_deferred = deferred;
    errdefer owned_deferred.deinit();

    if (request_id == 0)
        return error.FetchOutsideActiveRequest;
    const request = runtime.requests.get(request_id) orelse return error.FetchOutsideActiveRequest;
    if (refusal(runtime, request_id)) |refused|
        return refused.asError();
    if (runtime.egress_state.tasks.count() >= runtime.limits.max_fetches_per_worker)
        return error.FetchWorkerLimitExceeded;
    // A finished fetch gives the token's budget nothing back, so the limit
    // counts every fetch the request started.
    if (request.egress_fetches_started >= runtime.limits.max_fetches_per_request)
        return error.FetchRequestLimitExceeded;
    try validateUrlForGateway(url);
    try validateStartShape(method, url, body, headers);

    const fetch_id = runtime.egress_state.next_fetch_id;
    runtime.egress_state.next_fetch_id += 1;

    const response_body_identity = try fetch_body_runtime.registerOpen(runtime, request, fetch_id, null);
    var response_body_registered = true;
    errdefer {
        if (response_body_registered)
            _ = fetch_body_runtime.release(runtime, response_body_identity);
    }
    const response_body = fetch_body_runtime.ptr(runtime, response_body_identity) orelse return error.FetchBodyNotFound;

    const task = try runtime.allocator.create(FetchTask);
    var task_initialized = false;
    var task_owned_by_scope = true;
    errdefer {
        if (task_owned_by_scope) {
            if (task_initialized)
                task.deinit(runtime.allocator);
            runtime.allocator.destroy(task);
        }
    }
    const task_deferred = owned_deferred;
    owned_deferred = .{};
    task.* = try FetchTask.init(
        runtime.allocator,
        fetch_id,
        request_id,
        url,
        method,
        body,
        headers,
        flags,
        response_body_identity,
        response_body,
        task_deferred,
    );
    response_body.retain();
    task_initialized = true;

    runtime.egress_state.tasks.putNoClobber(runtime.allocator, fetch_id, task) catch |err| {
        task.deinit(runtime.allocator);
        runtime.allocator.destroy(task);
        task_owned_by_scope = false;
        return err;
    };
    task_owned_by_scope = false;

    // Counted before the start can leave, so a start that the gateway took
    // before a later step failed is counted too.
    request.egress_fetches_started += 1;
    // A full command ring or upload pool parks the task for the completion
    // pump to resume, so only a hard failure unwinds here. When the start
    // already reached the gateway, it is told to drop the fetch before the
    // task is destroyed.
    upload_runtime.ensureTaskUploadProgress(runtime, task) catch |err| {
        if (task.start_sent)
            gateway_control.sendCancel(runtime, fetch_id, "fetch schedule failed");
        _ = runtime.egress_state.tasks.remove(fetch_id);
        task.deinit(runtime.allocator);
        runtime.allocator.destroy(task);
        return err;
    };
    response_body_registered = false;
    return fetch_id;
}

/// Rejects early a URL the gateway would refuse: anything but `http:` or
/// `https:` followed by `//` and a non-empty rest. The gateway remains the
/// egress security boundary and checks the token, policy, redirects, DNS
/// results, ports and private or reserved address ranges itself.
fn validateUrlForGateway(url: []const u8) !void {
    const scheme_end = std.mem.indexOfScalar(
        u8,
        url,
        ':',
    ) orelse return error.InvalidFetchUrl;
    if (scheme_end == 0) return error.InvalidFetchUrl;
    if (url.len < scheme_end + 3) return error.InvalidFetchUrl;
    if (url[scheme_end + 1] != '/') return error.InvalidFetchUrl;
    if (url[scheme_end + 2] != '/') return error.InvalidFetchUrl;
    if (url.len == scheme_end + 3)
        return error.InvalidFetchUrl;
    const scheme = url[0..scheme_end];
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https"))
        return;
    return error.UnsupportedFetchProtocol;
}

/// Checks the start against the gateway's packet limits (`ipc.fetch_limits`)
/// before the fetch id, response body and task are created.
fn validateStartShape(
    method: []const u8,
    url: []const u8,
    body: []const u8,
    headers: []const bindings.NameValuePair,
) !void {
    if (method.len > ipc.fetch_limits.request_method_bytes_max)
        return error.EgressGatewayRequestMethodLimitExceeded;
    if (url.len > ipc.fetch_limits.request_url_bytes_max)
        return error.EgressGatewayRequestUrlLimitExceeded;
    if (body.len > ipc.fetch_limits.request_body_pooled_bytes_max)
        return error.EgressGatewayRequestBodyLimitExceeded;
    if (headers.len > ipc.max_request_header_count)
        return error.TooManyFetchHeaders;

    var header_bytes: usize = 0;
    for (headers) |header| {
        header_bytes = std.math.add(usize, header_bytes, header.name.len) catch
            return error.EgressGatewayRequestHeaderLimitExceeded;
        header_bytes = std.math.add(usize, header_bytes, header.value.len) catch
            return error.EgressGatewayRequestHeaderLimitExceeded;
        if (header_bytes > ipc.fetch_limits.request_headers_bytes_max)
            return error.EgressGatewayRequestHeaderLimitExceeded;
    }
}
