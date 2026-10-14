//! JavaScript readers of fetch body views: whole-body reads such as `text()`
//! and `json()`, stream pulls, the response stream that forwards a fetch body
//! as the request's own response, and clones. Runs on the worker's VM thread.
//! A read registered here is answered later, from the ready queue, by
//! `ready.zig`, or by `serve/response.zig` for the response stream.

const bindings = @import("collo_bindings");
const promise_deferred = @import("collo_worker_js").deferred;
const Runtime = @import("../../runtime/root.zig").Runtime;
const gateway_control = @import("../gateway_control.zig");
const body_mod = @import("body.zig");
const common = @import("common.zig");
const register = @import("register.zig");

pub const ResponseStreamDrain = body_mod.PullDrain;

/// Registers a whole-body read of `kind` on the view `identity` names and
/// returns its body id. Takes ownership of `deferred` on every path. On
/// success the body owns the promise until `ready.executeReady` settles it;
/// the stored reader takes no reference, since the table's covers it until
/// the settlement takes its own (`ready.zig`). Fails with
/// `error.FetchBodyOutsideActiveRequest` when the request is gone, its
/// generation moved on or its finish started (`common.acceptingRequest`),
/// `error.FetchBodyNotFound`, `error.InvalidPromiseDeferred` for an empty
/// `deferred`, `error.FetchBodyAlreadyUsed` when the view was read or
/// released, or `error.OutOfMemory`.
pub fn scheduleConsume(
    runtime: *Runtime,
    identity: bindings.FetchBodyIdentity,
    kind: body_mod.ReadKind,
    content_type: []const u8,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    var owned_deferred = deferred;
    errdefer owned_deferred.deinit();
    _ = try common.acceptingRequest(runtime, identity);
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;

    const owned_content_type = try runtime.core.allocator.dupe(u8, content_type);
    var waiter = body_mod.Waiter{
        .kind = kind,
        .content_type = owned_content_type,
        .deferred = owned_deferred.take() catch |err| {
            runtime.core.allocator.free(owned_content_type);
            return err;
        },
    };
    const should_queue = body.beginConsume(waiter) catch |err| {
        waiter.deinit(runtime.core.allocator);
        return err;
    };
    if (should_queue)
        common.queueClaimed(runtime, body);
    return identity.body_id;
}

/// Registers a JavaScript stream pull on the view `identity` names and
/// returns its body id, with the ownership `scheduleConsume` describes.
/// Fails as `scheduleConsume` does, or with `error.FetchBodyReadInProgress`
/// while another pull waits.
pub fn schedulePull(
    runtime: *Runtime,
    identity: bindings.FetchBodyIdentity,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    var owned_deferred = deferred;
    errdefer owned_deferred.deinit();
    _ = try common.acceptingRequest(runtime, identity);
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;

    var waiter = body_mod.PullWaiter{ .deferred = try owned_deferred.take() };
    const should_queue = body.beginPull(waiter) catch |err| {
        waiter.deinit();
        return err;
    };
    if (should_queue)
        common.queueClaimed(runtime, body);
    return identity.body_id;
}

/// Registers a pull without a promise for the response stream that forwards
/// this body as the request's response, taking no extra reference. It is the
/// worker's own pull of a response already decided, so it needs no
/// `acceptsWork`, only the request under the body's generation. When the
/// body turns ready, `serve/response.zig` takes the chunk through
/// `drainResponseStreamReady`. Fails as `schedulePull` does.
pub fn beginResponseStreamPull(runtime: *Runtime, identity: bindings.FetchBodyIdentity) !void {
    const request = runtime.requests.active.get(identity.request_id) orelse return error.FetchBodyOutsideActiveRequest;
    if (request.request_generation != identity.request_generation)
        return error.FetchBodyOutsideActiveRequest;
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    if (try body.beginPull(.{ .deferred = null }))
        common.queueClaimed(runtime, body);
}

/// Moves out the next ready chunk of a response-stream body. The caller owns
/// the drain; its `deinit` returns the chunk's borrowed extent, after which
/// the caller flushes the pool releases again. Fails with
/// `error.FetchBodyNotFound`.
pub fn drainResponseStreamReady(runtime: *Runtime, identity: bindings.FetchBodyIdentity) !ResponseStreamDrain {
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    // Covers the extents a failed body's drain returns before this function
    // returns.
    defer gateway_control.flushBodyPoolReleases(runtime);
    return body.drainReadyForPull(runtime.core.allocator);
}

/// The materialized bytes of a complete body, without consuming it, or null
/// before completion or for a stale identity. Chunks still queued are not in
/// the slice until a waiter drain copies them in. The slice is valid until
/// the next waiter drain or until the body is freed.
pub fn borrow(runtime: *Runtime, identity: bindings.FetchBodyIdentity) ?[]const u8 {
    const body = common.ptr(runtime, identity) orelse return null;
    return body.borrowCompleteBytes();
}

/// Tees the view `identity` names into a new view of the same fetch, which
/// the table holds, and returns the new identity. Fails with
/// `error.FetchBodyOutsideActiveRequest`, `error.FetchBodyNotFound`,
/// `error.FetchBodyLimitExceeded` when the table is full,
/// `error.FetchBodyAlreadyUsed` once the view was read or released,
/// `error.FetchBodyNotReadable` for a view failed without a message, or
/// `error.OutOfMemory`.
pub fn clone(runtime: *Runtime, identity: bindings.FetchBodyIdentity) !bindings.FetchBodyIdentity {
    const request = try common.acceptingRequest(runtime, identity);
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    try register.reserveSlot(runtime);
    const state = &runtime.egress.state;
    const cloned_identity = state.nextBodyIdentity(request, identity.fetch_id);
    const branch = try body.cloneBranch(runtime.core.allocator, cloned_identity);
    state.bodies.putAssumeCapacityNoClobber(cloned_identity.body_id, branch);
    return cloned_identity;
}
