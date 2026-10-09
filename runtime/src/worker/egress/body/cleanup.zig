//! Cancellation and release of fetch body views, and the sweeps that remove a
//! finished request's bodies or every body at shutdown. Runs on the worker's
//! event loop thread.
//!
//! The gateway sends chunks for the source body, the one a fetch registered,
//! while JS may hold tee branches cloned from it. Releasing a view therefore
//! stops the fetch only once no view can still read it, and `release` keeps a
//! released source in the table while it is open and feeds branches.

const std = @import("std");
const bindings = @import("collo_bindings");
const egress_context = @import("../context.zig");
const egress_state = @import("../state.zig");
const gateway_control = @import("../gateway_control.zig");
const common = @import("common.zig");

/// Cancels the view `identity` names, as JS does when it cancels the body's
/// stream: drops the view's queued chunks and reader, fails it as aborted, and
/// stops the source fetch once no other view can read it. A stale identity
/// does nothing.
pub fn cancel(runtime: *egress_context.Context, identity: bindings.FetchBodyIdentity) void {
    const body = common.ptr(runtime, identity) orelse return;
    defer gateway_control.flushBodyPoolReleases(runtime);
    body.releaseQueuedChunksCallback(
        runtime.allocator,
        &runtime.egress_state.body_credit_release_context,
        egress_state.BodyCreditReleaseContext.release,
    );
    body.markViewReleased(runtime.allocator);
    const cancel_identity = body.sourceCancelIdentityAfterViewRelease();
    if (cancel_identity) |source_identity|
        cancelSource(runtime, source_identity);
    const ready = body.cancelViewOnly(runtime.allocator, "fetch aborted", null) catch body.cancelViewOnlyNoAlloc();
    if (ready and body.claimReadyForQueue()) {
        if (!runtime.tryQueueReady(.{ .fetch_body_ready = body.identity.body_id })) {
            body.clearReadyQueued();
        }
    }
    runtime.wake();
}

/// Stops the source fetch `identity` names at the gateway: drops its decoder,
/// then sends `EgressCancel` and `EgressReleaseBody`.
pub fn cancelSource(runtime: *egress_context.Context, identity: bindings.FetchBodyIdentity) void {
    // Decoders are keyed by the source body id. Stopping the source ends its
    // chunks, so its decoder goes here and returns its pending encoded
    // extents to the pool while the endpoint is still mapped.
    _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, identity.body_id);
    gateway_control.sendCancel(runtime, identity.fetch_id, "fetch body canceled");
    gateway_control.sendRelease(runtime, identity);
}

/// Cancels every body of `fetch_id`, stopping each source once, and fails each
/// view with `reason` when one is given. Takes ownership of `reason`. Running
/// out of memory while deduplicating sources disconnects the gateway, which
/// fails every body instead.
pub fn cancelForFetch(runtime: *egress_context.Context, fetch_id: u64, reason: ?bindings.Value) void {
    var owned_reason = reason;
    defer if (owned_reason) |*value|
        value.deinit();

    var canceled_any = false;
    defer gateway_control.flushBodyPoolReleases(runtime);
    var canceled_sources = std.AutoHashMapUnmanaged(u64, void){};
    defer canceled_sources.deinit(runtime.allocator);
    var iterator = runtime.egress_state.bodies.iterator();
    while (iterator.next()) |entry| {
        const body = entry.value_ptr.*;
        if (body.identity.fetch_id != fetch_id)
            continue;

        canceled_any = true;
        const source_identity = body.sourceIdentity();
        const source_entry = canceled_sources.getOrPut(runtime.allocator, source_identity.body_id) catch |err| {
            std.log.warn("failed to dedupe fetch body cancel source body_id={d}: {s}", .{ source_identity.body_id, @errorName(err) });
            runtime.disconnectEgressGateway();
            return;
        };
        if (!source_entry.found_existing)
            cancelSource(runtime, source_identity);
        body.releaseQueuedChunksCallback(
            runtime.allocator,
            &runtime.egress_state.body_credit_release_context,
            egress_state.BodyCreditReleaseContext.release,
        );

        const cancel_reason = if (owned_reason) |value| value.retain() catch null else null;
        const ready = body.cancel(runtime.allocator, "fetch aborted", cancel_reason) catch body.cancelNoAlloc();
        if (ready and body.claimReadyForQueue()) {
            if (!runtime.tryQueueReady(.{ .fetch_body_ready = body.identity.body_id })) {
                body.clearReadyQueued();
            }
        }
    }

    if (canceled_any)
        runtime.wake();
}

/// Handles an error from the `fetch_body_ready` item of `body_id`
/// (`Runtime.executeFetchBodyReady`, which runs `ready.executeReady` or the
/// response stream's drain): logs it, accounts the body's meters and cancels
/// the body. A body already gone is only logged.
pub fn handleReadyFailure(runtime: *egress_context.Context, body_id: u64, err: anyerror) void {
    const body = runtime.egress_state.bodies.get(body_id) orelse {
        std.log.warn("fetch body completion failed after body removal body_id={d}: {s}", .{ body_id, @errorName(err) });
        return;
    };
    const identity = body.identity;
    common.accountEgress(runtime, body);
    std.log.warn("fetch body completion failed body_id={d}: {s}", .{ body_id, @errorName(err) });
    cancel(runtime, identity);
    common.accountEgress(runtime, body);
}

/// Releases the JS view `identity` names, as when its `Response` is freed;
/// returns false when no body matches. A view with a pending reader stays
/// until that reader settles, and a released source that still feeds open
/// branches stays until they are done.
pub fn release(runtime: *egress_context.Context, identity: bindings.FetchBodyIdentity) bool {
    return releaseInternal(runtime, identity, true);
}

/// As `release`, but with `preserve_open_source` false the body leaves the
/// table whatever its readers or branches, as request cleanup and shutdown
/// need. Returns false when no body matches.
pub fn releaseInternal(
    runtime: *egress_context.Context,
    identity: bindings.FetchBodyIdentity,
    preserve_open_source: bool,
) bool {
    const body = common.ptr(runtime, identity) orelse
        return false;
    defer gateway_control.flushBodyPoolReleases(runtime);
    common.accountEgress(runtime, body);
    const preserve_waiter = preserve_open_source and body.hasPendingWaiter();
    const source_identity = body.sourceIdentity();
    if (!preserve_waiter) {
        body.releaseQueuedChunksCallback(
            runtime.allocator,
            &runtime.egress_state.body_credit_release_context,
            egress_state.BodyCreditReleaseContext.release,
        );
        body.markViewReleased(runtime.allocator);
    } else {
        body.markViewReleasedPreservingWaiters(runtime.allocator);
    }
    const cancel_identity = body.sourceCancelIdentityAfterViewRelease();
    if (cancel_identity) |cancel_source_identity| {
        cancelSource(runtime, cancel_source_identity);
    }
    if (preserve_waiter)
        return true;
    if (preserve_open_source and body.shouldKeepReleasedSource()) {
        return true;
    }
    body.detachTeeLinks(runtime.allocator);
    // No assert may guard this lookup: under ReleaseFast it would become
    // `unreachable`, the optimizer would drop the `return false`, and a miss
    // would release an undefined `removed.value`.
    const removed = runtime.egress_state.bodies.fetchRemove(identity.body_id) orelse return false;
    // A decoder never outlives its body: it goes in the same step, returning
    // its pending pool extents.
    _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, identity.body_id);
    removed.value.releaseAfterQueuedResourcesReleased(runtime.allocator);
    if (source_identity.body_id != identity.body_id) {
        removeReleasedSourceIfIdle(runtime, source_identity);
    }
    return true;
}

/// Removes a released source once its last branch and reader are gone.
fn removeReleasedSourceIfIdle(
    runtime: *egress_context.Context,
    identity: bindings.FetchBodyIdentity,
) void {
    const body = common.ptr(runtime, identity) orelse return;
    if (!body.canRemoveReleasedSource()) {
        return;
    }
    common.accountEgress(runtime, body);
    body.releaseQueuedChunksCallback(
        runtime.allocator,
        &runtime.egress_state.body_credit_release_context,
        egress_state.BodyCreditReleaseContext.release,
    );
    body.detachTeeLinks(runtime.allocator);
    // As in `releaseInternal`, no assert may guard this lookup.
    const removed = runtime.egress_state.bodies.fetchRemove(identity.body_id) orelse return;
    _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, identity.body_id);
    removed.value.releaseAfterQueuedResourcesReleased(runtime.allocator);
}

/// Removes every body, for runtime teardown.
pub fn releaseAllForShutdown(runtime: *egress_context.Context) void {
    while (true) {
        var identity: ?bindings.FetchBodyIdentity = null;
        var iterator = runtime.egress_state.bodies.iterator();
        while (iterator.next()) |entry| {
            identity = entry.value_ptr.*.identity;
            break;
        }
        const current = identity orelse return;
        const removed = releaseInternal(runtime, current, false);
        std.debug.assert(removed);
    }
}

/// Removes every body of `request_id`, accounting each one's meters first. A
/// body can outlive its fetch promise, as an unread streaming response does,
/// and ends here when its request finishes.
pub fn cleanupForRequest(runtime: *egress_context.Context, request_id: u64) void {
    while (true) {
        var remove_identity: ?bindings.FetchBodyIdentity = null;
        var iterator = runtime.egress_state.bodies.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.identity.request_id == request_id) {
                remove_identity = entry.value_ptr.*.identity;
                break;
            }
        }
        const identity = remove_identity orelse return;
        if (runtime.egress_state.bodies.get(identity.body_id)) |body|
            common.accountEgress(runtime, body);
        const removed = releaseInternal(runtime, identity, false);
        std.debug.assert(removed);
    }
}
