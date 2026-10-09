//! JS readers of fetch body views: whole-body reads such as `text()` and
//! `json()`, stream pulls, the response stream that forwards a fetch body as
//! the request's own response, and clones. Runs on the worker's event loop
//! thread. A read registered here is answered later, from the ready queue, by
//! `ready.zig`, or by `serve/response.zig` for the response stream.

const bindings = @import("collo_bindings");
const promise_deferred = @import("collo_worker_js").deferred;
const egress_context = @import("../context.zig");
const egress_state = @import("../state.zig");
const gateway_control = @import("../gateway_control.zig");
const common = @import("common.zig");

const FetchBodyReadKind = common.FetchBodyReadKind;
const FetchBodyWaiter = common.FetchBodyWaiter;
const FetchBodyPullWaiter = common.FetchBodyPullWaiter;
pub const ResponseStreamDrain = common.ResponseStreamDrain;

/// Registers a whole-body read of `kind` on the view `identity` names and
/// returns its body id. Takes ownership of `deferred` on every path. On
/// success the body owns the promise and holds an extra reference until
/// `ready.executeReady` settles it. Fails with
/// `error.FetchBodyOutsideActiveRequest` when the request is gone or its
/// generation moved on, `error.FetchBodyNotFound`, `error.InvalidPromiseDeferred`
/// for an empty `deferred`, `error.FetchBodyAlreadyUsed` when the view was read
/// or released, or `error.OutOfMemory`.
pub fn scheduleConsume(
    runtime: *egress_context.Context,
    identity: bindings.FetchBodyIdentity,
    kind: FetchBodyReadKind,
    content_type: []const u8,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    var owned_deferred = deferred;
    errdefer owned_deferred.deinit();
    const request = runtime.requests.get(identity.request_id) orelse return error.FetchBodyOutsideActiveRequest;
    if (request.request_generation != identity.request_generation)
        return error.FetchBodyOutsideActiveRequest;
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    body.retain();
    var body_retained = true;
    errdefer if (body_retained)
        body.releaseAfterQueuedResourcesReleased(runtime.allocator);

    const owned_content_type = try runtime.allocator.dupe(u8, content_type);
    var content_type_moved = false;
    errdefer if (!content_type_moved)
        runtime.allocator.free(owned_content_type);
    const raw_deferred = try owned_deferred.take();
    var waiter = FetchBodyWaiter{
        .kind = kind,
        .content_type = owned_content_type,
        .deferred = raw_deferred,
    };
    content_type_moved = true;
    var waiter_stored = false;
    errdefer if (!waiter_stored) {
        waiter.deinit(runtime.allocator);
    };
    const should_queue = try body.beginConsume(waiter);
    waiter_stored = true;
    errdefer body.rollbackPendingConsume(runtime.allocator);

    if (should_queue)
        try common.pushClaimedReady(runtime, body);
    body_retained = false;
    return identity.body_id;
}

/// Registers a JS stream pull on the view `identity` names and returns its
/// body id, with the ownership `scheduleConsume` describes. Fails as
/// `scheduleConsume` does, or with `error.FetchBodyReadInProgress` while
/// another pull waits.
pub fn schedulePull(
    runtime: *egress_context.Context,
    identity: bindings.FetchBodyIdentity,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    var owned_deferred = deferred;
    errdefer owned_deferred.deinit();
    const request = runtime.requests.get(identity.request_id) orelse return error.FetchBodyOutsideActiveRequest;
    if (request.request_generation != identity.request_generation)
        return error.FetchBodyOutsideActiveRequest;
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    body.retain();
    var body_retained = true;
    errdefer if (body_retained)
        body.releaseAfterQueuedResourcesReleased(runtime.allocator);

    const raw_deferred = try owned_deferred.take();
    var waiter = FetchBodyPullWaiter{ .deferred = raw_deferred };
    var waiter_stored = false;
    errdefer if (!waiter_stored) {
        waiter.deinit();
    };
    const should_queue = try body.beginPull(waiter);
    waiter_stored = true;
    errdefer body.rollbackPendingPull();

    if (should_queue)
        try common.pushClaimedReady(runtime, body);
    body_retained = false;
    return identity.body_id;
}

/// Registers a pull without a promise for the response stream that forwards
/// this body as the request's response, taking no extra reference. When the
/// body turns ready, `serve/response.zig` takes the chunk through
/// `drainResponseStreamReady`. Fails as `schedulePull` does.
pub fn beginResponseStreamPull(
    runtime: *egress_context.Context,
    identity: bindings.FetchBodyIdentity,
) !void {
    const request = runtime.requests.get(identity.request_id) orelse return error.FetchBodyOutsideActiveRequest;
    if (request.request_generation != identity.request_generation)
        return error.FetchBodyOutsideActiveRequest;
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;

    const should_queue = try body.beginPull(.{ .deferred = null });
    errdefer body.rollbackPendingPull();

    if (should_queue)
        try common.pushClaimedReady(runtime, body);
}

/// Moves out the next ready chunk of a response-stream body. The caller owns
/// the drain: it releases the drain's credits, and its `deinit` returns the
/// chunk's borrowed extent, after which the caller flushes the pool releases
/// again. Fails with `error.FetchBodyNotFound` or `error.OutOfMemory`.
pub fn drainResponseStreamReady(
    runtime: *egress_context.Context,
    identity: bindings.FetchBodyIdentity,
) !ResponseStreamDrain {
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    common.accountEgress(runtime, body);
    // Covers the extents a failed body's drain returns before this function
    // returns.
    defer gateway_control.flushBodyPoolReleases(runtime);
    return body.drainReadyForPull(runtime.allocator);
}

/// The materialized bytes of a complete body, without consuming it, or null
/// before completion or for a stale identity. Chunks still queued are not in
/// the slice until a waiter drain copies them in. The slice is valid until the
/// next waiter drain or until the body is freed.
pub fn borrow(runtime: *egress_context.Context, identity: bindings.FetchBodyIdentity) ?[]const u8 {
    const body = common.ptr(runtime, identity) orelse return null;
    return body.borrowCompleteBytes();
}

/// Tees the view `identity` names into a new view of the same fetch, which the
/// table holds, and returns the new identity. Fails with
/// `error.FetchBodyOutsideActiveRequest`, `error.FetchBodyNotFound`,
/// `error.FetchBodyAlreadyUsed` once the view was read or released,
/// `error.FetchBodyNotReadable` for a view failed without a message, or
/// `error.OutOfMemory`.
pub fn clone(runtime: *egress_context.Context, identity: bindings.FetchBodyIdentity) !bindings.FetchBodyIdentity {
    const request = runtime.requests.get(identity.request_id) orelse return error.FetchBodyOutsideActiveRequest;
    if (request.request_generation != identity.request_generation)
        return error.FetchBodyOutsideActiveRequest;
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    const cloned_identity = common.nextIdentity(runtime, request, identity.fetch_id);
    const branch = try body.cloneBranch(runtime.allocator, cloned_identity);
    errdefer {
        // The branch shares the source's queued chunks, and its final release
        // asserts an empty queue, so it is drained first. The source stays in
        // the table, so the shared credits and borrowed extents remain held
        // on its side and this drain releases nothing. It still goes through
        // the real release context, so a credit that does surface is
        // returned rather than dropped.
        branch.releaseQueuedChunksCallback(
            runtime.allocator,
            &runtime.egress_state.body_credit_release_context,
            egress_state.BodyCreditReleaseContext.release,
        );
        gateway_control.flushBodyPoolReleases(runtime);
        branch.detachTeeLinks(runtime.allocator);
        branch.releaseAfterQueuedResourcesReleased(runtime.allocator);
    }
    try runtime.egress_state.bodies.putNoClobber(runtime.allocator, cloned_identity.body_id, branch);
    return cloned_identity;
}
