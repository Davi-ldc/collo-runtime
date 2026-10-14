//! Starts a fetch for JavaScript: checks it, counts it, registers its
//! response body and task, and sends its start to the gateway. Runs on the
//! worker's VM thread. The gateway is the egress security boundary; the
//! checks here only reject early what it would refuse anyway, so that honest
//! code fails with a precise TypeError before anything leaves. A scheduled
//! task holds one reference on its response body, and `State.bodies` holds
//! another until the view is released.
//!
//! A fetch leaves only from a worker whose definition grants some route
//! network access, only while it is attached and only for a request that
//! carries an egress token (`refusal`). No more fetches start under one token
//! than `fetches_per_request_max`: a request counts its own, and the
//! evaluations count theirs together, since each presents a copy of the one
//! boot token. No more than `fetches_per_worker_max` are counted at once
//! (`State.fetches`), on the lifetime the gateway counts them, so an honest
//! worker never meets the gateway's caps; and no more than that many tasks
//! wait for their completion to run, counting the completions still queued
//! for tasks already gone, which bounds the worker's ready queue
//! (`common/limits/worker.zig:egress_ready_items_max`). A request dispatched
//! before its worker was attached to a new gateway still carries the old
//! gateway's token, and its fetches fail there as forged.
//!
//! A worker without a grant refuses every fetch as the network setting's
//! denial, the text the gateway would send (`collo_network.writeDenial`),
//! and writes it to the tenant's log as the gateway's denials are
//! (`completion_runtime.deliver`). Each such denial counts against the
//! token's fetches as one the gateway makes does, which bounds the lines one
//! request writes.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const network = @import("collo_network");
const request_context = @import("collo_worker_request").context;
const promise_deferred = @import("collo_worker_js").deferred;
const Runtime = @import("../runtime/root.zig").Runtime;
const task_mod = @import("task.zig");
const task_runtime = @import("task_runtime.zig");
const fetch_body_runtime = @import("body/root.zig");
const upload_runtime = @import("upload_runtime.zig");

const FetchTask = task_mod.Task;

/// Why a fetch of a live request cannot leave the worker.
pub const Refusal = enum {
    /// The worker's definition grants no route network access, so it holds
    /// no session and never will (`State.grant`).
    no_network_grant,
    /// The worker holds no gateway session: it booted without one, or its
    /// gateway closed and the server has not attached it to a new one.
    detached,
    /// The request's `DispatchWork` carries `egress_token.none`: the server
    /// minted no token for it, because the worker had no live session when
    /// the request was dispatched.
    no_egress_token,

    pub const Error = error{ FetchNotGranted, FetchEgressDetached, FetchWithoutEgressToken };

    /// The longest message `message` writes.
    pub const message_bytes_max: usize = network.grant.denial_bytes_max;

    /// The TypeError message a refused fetch of `url` rejects with, written
    /// into `buffer` or static. A worker without a grant answers with the
    /// network setting's denial for the URL's origin, or with the reason
    /// alone for a URL that has no http or https origin, as the gateway
    /// does; a gateway that is gone or a missing token is no denial and
    /// says so.
    pub fn message(self: Refusal, url: []const u8, buffer: *[message_bytes_max]u8) []const u8 {
        switch (self) {
            .no_network_grant => {},
            .detached => return "fetch failed: no egress gateway",
            .no_egress_token => return "fetch failed: the request has no egress token",
        }
        const origin = urlOrigin(url) orelse return network.Denial.no_grant.describe();
        var writer: std.Io.Writer = .fixed(buffer);
        // `message_bytes_max` is the longest text `writeDenial` writes.
        network.writeDenial(&writer, origin, .no_grant) catch unreachable;
        return writer.buffered();
    }

    /// The error `schedule` returns for the refusal.
    pub fn asError(self: Refusal) Error {
        return switch (self) {
            .no_network_grant => error.FetchNotGranted,
            .detached => error.FetchEgressDetached,
            .no_egress_token => error.FetchWithoutEgressToken,
        };
    }
};

/// Whether a fetch of `request_id` would be refused before it leaves.
/// Returns null for a request that is not live or accepts no work, which
/// `schedule` refuses on its own, and in a worker without a grant for a
/// request whose token's fetches its denials spent, which `schedule` refuses
/// as a fetch past that limit.
pub fn refusal(runtime: *Runtime, request_id: u64) ?Refusal {
    const request = runtime.requests.active.get(request_id) orelse return null;
    if (!request.acceptsWork())
        return null;
    if (runtime.egress.state.grant() == .none) {
        if (tokenFetchesStarted(runtime, request_id, request).* >= limits.worker.fetches_per_request_max)
            return null;
        return .no_network_grant;
    }
    if (runtime.egress.state.shared == null)
        return .detached;
    if (ipc.egress_token.isNone(&request.dispatch_work.egress_token))
        return .no_egress_token;
    return null;
}

/// Refuses a fetch of `url` that `refusal` refused for the live request
/// `request_id` and returns the TypeError message, written into `buffer` or
/// static. A denial for want of a grant also counts against the token's
/// fetches and goes to the tenant's log as a warning; the other refusals
/// change nothing.
pub fn refuse(
    runtime: *Runtime,
    request_id: u64,
    refused: Refusal,
    url: []const u8,
    buffer: *[Refusal.message_bytes_max]u8,
) []const u8 {
    const text = refused.message(url, buffer);
    switch (refused) {
        .no_network_grant => {
            if (runtime.requests.active.get(request_id)) |request|
                tokenFetchesStarted(runtime, request_id, request).* += 1;
            runtime.logNetworkDenial(request_id, text);
        },
        .detached, .no_egress_token => {},
    }
    return text;
}

/// The origin a denial names for `url`, as the gateway forms it: its scheme,
/// its host as the URL spells it, an IPv6 address in brackets, and its
/// effective port. Null for a URL without an http or https origin.
fn urlOrigin(url: []const u8) ?network.Origin {
    const uri = std.Uri.parse(url) catch return null;
    const scheme: network.Scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        .https
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
        .http
    else
        return null;
    const host = uri.host orelse return null;
    return .{
        .scheme = scheme,
        .host = switch (host) {
            .raw, .percent_encoded => |text| text,
        },
        .port = uri.port orelse scheme.defaultPort(),
    };
}

/// Schedules a fetch for the live request `request_id` and returns its fetch
/// id. Takes ownership of `deferred` on every path; on success the task owns
/// it and `completion_runtime.execute` settles it. Fails with
/// `error.FetchOutsideActiveRequest` for an owner that is not active or
/// accepts no work (`RequestContext.acceptsWork`), with the error of its
/// `refusal`, `error.FetchWorkerLimitExceeded` at `fetches_per_worker_max`
/// counted fetches or tasks, `error.FetchRequestLimitExceeded` once the token's
/// fetches reached `fetches_per_request_max`,
/// `error.FetchBodyLimitExceeded` when the body table is full, a URL error,
/// a bound error of `ipc.egress.checkFetchStart`, or an error sending the
/// start. A full command ring, upload pool or upload reservation only parks
/// the task.
pub fn schedule(
    runtime: *Runtime,
    request_id: u64,
    request: FetchTask.Request,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    var owned_deferred = deferred;
    errdefer owned_deferred.deinit();
    const state = &runtime.egress.state;
    const allocator = runtime.core.allocator;

    if (request_id == 0)
        return error.FetchOutsideActiveRequest;
    const owner = runtime.requests.active.get(request_id) orelse return error.FetchOutsideActiveRequest;
    // Refused before anything leaves the worker: a start sent for a request
    // whose finish started would reach the gateway after its response was
    // decided.
    if (!owner.acceptsWork())
        return error.FetchOutsideActiveRequest;
    if (refusal(runtime, request_id)) |refused|
        return refused.asError();
    if (state.fetches.count() >= limits.worker.fetches_per_worker_max)
        return error.FetchWorkerLimitExceeded;
    // Each task queues one completion, and a completion whose task went
    // before it popped still holds its place in the ready queue, so this
    // bounds the completion items there (`State.completion_ready_orphans`).
    if (state.tasks.count() + state.completion_ready_orphans >= limits.worker.fetches_per_worker_max)
        return error.FetchWorkerLimitExceeded;
    // A finished fetch gives the token nothing back, so the limit counts
    // every fetch started under the token.
    const token_fetches_started = tokenFetchesStarted(runtime, request_id, owner);
    if (token_fetches_started.* >= limits.worker.fetches_per_request_max)
        return error.FetchRequestLimitExceeded;
    try validateUrlForGateway(request.url);
    try ipc.egress.checkFetchStart(.{
        .method_len = request.method.len,
        .url_len = request.url.len,
        .header_count = request.headers.len,
        .header_bytes = try headerBytes(request.headers),
        .body_len = request.body.len,
    });
    try state.fetches.ensureUnusedCapacity(allocator, 1);
    try state.tasks.ensureUnusedCapacity(allocator, 1);

    const fetch_id = state.next_fetch_id;
    state.next_fetch_id += 1;
    const response_body_identity = try fetch_body_runtime.registerOpen(runtime, owner, fetch_id);
    errdefer _ = fetch_body_runtime.release(runtime, response_body_identity);
    const response_body = fetch_body_runtime.ptr(runtime, response_body_identity).?;

    const task = try allocator.create(FetchTask);
    errdefer allocator.destroy(task);
    const task_deferred = owned_deferred;
    owned_deferred = .{};
    task.* = try FetchTask.init(
        allocator,
        fetch_id,
        request_id,
        request,
        response_body_identity,
        response_body,
        task_deferred,
    );
    response_body.retain();
    state.tasks.putAssumeCapacityNoClobber(fetch_id, task);
    state.beginFetch(fetch_id, owner);
    // Counted before the start can leave, so a start that the gateway took
    // before a later step failed is counted too.
    token_fetches_started.* += 1;

    // A full command ring or upload pool parks the task for the completion
    // pump to resume, so only a hard failure unwinds here.
    upload_runtime.ensureTaskUploadProgress(runtime, task) catch |err| {
        // Out of the table first, so stopping a start that never left ends
        // the fetch without publishing to this task.
        _ = state.tasks.remove(fetch_id);
        task_runtime.stopFetch(runtime, fetch_id);
        task.deinit(allocator);
        return err;
    };
    return fetch_id;
}

/// The count of fetches started under the token that `request`, live under
/// `request_id`, presents: its own for a request, and for an evaluation the
/// one count every evaluation shares, since they all present a copy of the
/// boot token.
fn tokenFetchesStarted(
    runtime: *Runtime,
    request_id: u64,
    request: *request_context.RequestContext,
) *u64 {
    if (request_context.isEvaluationId(request_id))
        return &runtime.evaluations.boot_fetches_started;
    return &request.egress_fetches_started;
}

/// Rejects early a URL the gateway would refuse: anything but `http:` or
/// `https:` followed by `//` and a non-empty rest. The gateway remains the
/// egress security boundary and checks the token, policy, redirects, DNS
/// results, ports and private or reserved address ranges itself.
fn validateUrlForGateway(url: []const u8) !void {
    const scheme_end = std.mem.indexOfScalar(u8, url, ':') orelse return error.InvalidFetchUrl;
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

/// The name and value bytes of `headers`. Fails with
/// `error.EgressGatewayRequestHeaderLimitExceeded` when they overflow.
fn headerBytes(headers: []const bindings.NameValuePair) !usize {
    var total: usize = 0;
    for (headers) |header| {
        total = std.math.add(usize, total, header.name.len) catch
            return error.EgressGatewayRequestHeaderLimitExceeded;
        total = std.math.add(usize, total, header.value.len) catch
            return error.EgressGatewayRequestHeaderLimitExceeded;
    }
    return total;
}
