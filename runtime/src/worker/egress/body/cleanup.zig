//! Cancellation and release of fetch body views, and the sweeps that remove a
//! finished request's bodies or every body at shutdown. Runs on the worker's
//! VM thread.
//!
//! The gateway sends chunks for the source body, the one a fetch registered,
//! while JavaScript may hold tee branches cloned from it. Releasing a view
//! therefore stops the fetch only once no view can still read it, and
//! `release` keeps a released source in the table while it is open and feeds
//! branches.
//!
//! A body that leaves the table, or a cancelled view left with no reader and
//! no decoder, may still have a `fetch_body_ready` item queued that will
//! answer no reader; its request takes that ready count back at once
//! (`Runtime.withdrawReadyWork`), so the time until the item pops is not
//! counted as waiting, and the item pops in no window. The item of a body
//! that left the table still holds its place in the queue until it pops, so
//! the body's slot stays charged meanwhile (`State.body_ready_orphans`).
//!
//! A released or cancelled source that keeps its decoder, because clones
//! still read, loses its queued chunks, which frees the decoder's room, so
//! the decoder resumes here (`ready.resumeBodyDecoder`).

const std = @import("std");
const bindings = @import("collo_bindings");
const Runtime = @import("../../runtime/root.zig").Runtime;
const gateway_control = @import("../gateway_control.zig");
const task_runtime = @import("../task_runtime.zig");
const common = @import("common.zig");
const ready = @import("ready.zig");

const Body = common.Body;

/// Cancels the view `identity` names, as JavaScript does when it cancels the
/// body's stream: drops the view's queued chunks and reader, and stops the
/// source fetch once no other view can read it. The body's state stays: a
/// released view takes no more chunks, and a source keeps feeding the clones
/// that still read. A stale identity does nothing.
pub fn cancel(runtime: *Runtime, identity: bindings.FetchBodyIdentity) void {
    const body = common.ptr(runtime, identity) orelse return;
    defer gateway_control.flushBodyPoolReleases(runtime);
    body.releaseQueuedChunks(runtime.core.allocator);
    body.markViewReleased(runtime.core.allocator);
    if (body.sourceCancelIdentityAfterViewRelease()) |source_identity|
        stopSource(runtime, source_identity);
    if (body.decoder != null) {
        // A source that still feeds clones keeps its decoder, whose room the
        // dropped chunks freed.
        ready.resumeBodyDecoderOrFail(runtime, body);
    } else {
        // The view lost its reader and has no decoder to resume, so an item
        // queued for it before the cancel answers nobody; it only drops the
        // view, which needs no window of the request.
        runtime.withdrawReadyWork(.{ .fetch_body_ready = body.identity.body_id });
    }
    runtime.wake();
}

/// Stops the source fetch `identity` names: drops its decoder, which returns
/// its pending encoded extents while the endpoint is still mapped, and stops
/// the fetch at the gateway (`task_runtime.stopFetch`).
fn stopSource(runtime: *Runtime, identity: bindings.FetchBodyIdentity) void {
    if (common.ptr(runtime, identity)) |source|
        source.dropDecoder(runtime.core.allocator);
    task_runtime.stopFetch(runtime, identity.fetch_id);
}

/// Cancels every body of `fetch_id` with `reason`, of which it takes
/// ownership, each view getting a reference of its own, and stops the fetch
/// once. A canceled view stays readable: a read already waiting is answered
/// from the ready queue with the reason, and so is the next one.
pub fn cancelForFetch(runtime: *Runtime, fetch_id: u64, reason: ?bindings.Value) void {
    var owned_reason = reason;
    defer if (owned_reason) |*value| value.deinit();
    defer gateway_control.flushBodyPoolReleases(runtime);

    var canceled_any = false;
    var iterator = runtime.egress.state.bodies.valueIterator();
    while (iterator.next()) |entry| {
        const body = entry.*;
        if (body.identity.fetch_id != fetch_id)
            continue;
        canceled_any = true;
        body.dropDecoder(runtime.core.allocator);
        // The waiting reader stays, so the failure below readies it.
        body.releaseQueuedChunksPreservingWaiters(runtime.core.allocator);
        const view_reason: ?bindings.Value = if (owned_reason) |value| value.retain() catch |err| blk: {
            // The view then rejects with the message alone.
            std.log.warn("fetch abort reason retain failed: {s}", .{@errorName(err)});
            break :blk null;
        } else null;
        body.cancel(runtime.core.allocator, task_runtime.aborted_message, view_reason);
        common.queueIfReady(runtime, body);
    }
    if (canceled_any) {
        task_runtime.stopFetch(runtime, fetch_id);
        runtime.wake();
    }
}

/// Handles an error from the `fetch_body_ready` item of `body_id`
/// (`Runtime.executeFetchBodyReady`, which runs `ready.executeReady` or the
/// response stream's drain): logs it and cancels the body. A body already
/// gone is only logged.
pub fn handleReadyFailure(runtime: *Runtime, body_id: u64, err: anyerror) void {
    std.log.warn("fetch body completion failed body_id={d}: {s}", .{ body_id, @errorName(err) });
    const body = runtime.egress.state.bodies.get(body_id) orelse return;
    cancel(runtime, body.identity);
}

/// Releases the view `identity` names, as when its `Response` is freed;
/// returns false when no body matches. A view with a pending reader stays
/// until that reader settles, and a released source that still feeds open
/// branches stays until they are done.
pub fn release(runtime: *Runtime, identity: bindings.FetchBodyIdentity) bool {
    return releaseInternal(runtime, identity, true);
}

/// As `release`, but with `preserve_open_source` false the body leaves the
/// table whatever its readers or branches, as request cleanup and shutdown
/// need. Returns false when no body matches.
pub fn releaseInternal(
    runtime: *Runtime,
    identity: bindings.FetchBodyIdentity,
    preserve_open_source: bool,
) bool {
    const body = common.ptr(runtime, identity) orelse return false;
    defer gateway_control.flushBodyPoolReleases(runtime);
    const allocator = runtime.core.allocator;
    const preserve_waiter = preserve_open_source and body.hasPendingWaiter();
    const source_identity = body.sourceIdentity();
    if (preserve_waiter) {
        body.markViewReleasedPreservingWaiters();
    } else {
        body.releaseQueuedChunks(allocator);
        body.markViewReleased(allocator);
    }
    if (body.sourceCancelIdentityAfterViewRelease()) |cancel_identity|
        stopSource(runtime, cancel_identity);
    if (preserve_waiter)
        return true;
    if (preserve_open_source and body.shouldKeepReleasedSource()) {
        // The released source keeps feeding its clones, and its decoder the
        // room its dropped chunks held.
        ready.resumeBodyDecoderOrFail(runtime, body);
        return true;
    }
    removeFromTable(runtime, body);
    if (source_identity.body_id != identity.body_id)
        removeReleasedSourceIfIdle(runtime, source_identity);
    return true;
}

/// Takes `body` out of the table with its decoder, its chunks and its tee
/// links, and drops the table's reference. An item still queued for it finds
/// no body and runs nothing, so its count goes back now, and its place in
/// the queue stays charged to the table until it pops.
fn removeFromTable(runtime: *Runtime, body: *Body) void {
    const allocator = runtime.core.allocator;
    const state = &runtime.egress.state;
    const body_id = body.identity.body_id;
    // No assert may guard this removal: under ReleaseFast it would become
    // `unreachable`, and a miss would release the body twice.
    if (!state.bodies.remove(body_id))
        return;
    if (body.ready_queued)
        state.body_ready_orphans += 1;
    body.dropDecoder(allocator);
    body.releaseQueuedChunks(allocator);
    body.detachTeeLinks(allocator);
    body.release(allocator);
    runtime.withdrawReadyWork(.{ .fetch_body_ready = body_id });
}

/// Removes a released source once its last branch and reader are gone.
fn removeReleasedSourceIfIdle(runtime: *Runtime, identity: bindings.FetchBodyIdentity) void {
    const body = common.ptr(runtime, identity) orelse return;
    if (!body.canRemoveReleasedSource())
        return;
    removeFromTable(runtime, body);
}

/// Removes every body, for runtime teardown.
pub fn releaseAllForShutdown(runtime: *Runtime) void {
    while (true) {
        var bodies = runtime.egress.state.bodies.valueIterator();
        const body = (bodies.next() orelse return).*;
        const removed = releaseInternal(runtime, body.identity, false);
        std.debug.assert(removed);
    }
}

/// Removes every body of `request_id`. A body can outlive its fetch promise,
/// as an unread streaming response does, and ends here when its request
/// finishes.
pub fn cleanupForRequest(runtime: *Runtime, request_id: u64) void {
    while (true) {
        var found: ?bindings.FetchBodyIdentity = null;
        var bodies = runtime.egress.state.bodies.valueIterator();
        while (bodies.next()) |body| {
            if (body.*.identity.request_id == request_id) {
                found = body.*.identity;
                break;
            }
        }
        const identity = found orelse return;
        const removed = releaseInternal(runtime, identity, false);
        std.debug.assert(removed);
    }
}
