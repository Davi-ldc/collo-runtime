//! The lookups and ready-queue helpers the fetch body files share, on the
//! worker's VM thread; `root.zig` states the invariants they keep.

const std = @import("std");
const bindings = @import("collo_bindings");
const request_context = @import("collo_worker_request").context;
const Runtime = @import("../../runtime/root.zig").Runtime;
const body_mod = @import("body.zig");

pub const Body = body_mod.Body;

/// The request whose JavaScript may start a read, pull or clone of the view
/// `identity` names: active under the view's generation and accepting work
/// (`RequestContext.acceptsWork`). Fails with
/// `error.FetchBodyOutsideActiveRequest` otherwise.
pub fn acceptingRequest(runtime: *Runtime, identity: bindings.FetchBodyIdentity) !*request_context.RequestContext {
    const request = runtime.requests.active.get(identity.request_id) orelse return error.FetchBodyOutsideActiveRequest;
    if (request.request_generation != identity.request_generation)
        return error.FetchBodyOutsideActiveRequest;
    if (!request.acceptsWork())
        return error.FetchBodyOutsideActiveRequest;
    return request;
}

/// The body `identity` names, or null when no body has its id or the stored
/// identity differs in any field, as for a handle from an earlier request
/// generation. The table keeps its reference, so the pointer is valid until
/// the body leaves the table.
pub fn ptr(runtime: *Runtime, identity: bindings.FetchBodyIdentity) ?*Body {
    const body = runtime.egress.state.bodies.get(identity.body_id) orelse return null;
    if (body.identity.request_id != identity.request_id or
        body.identity.request_generation != identity.request_generation or
        body.identity.fetch_id != identity.fetch_id or
        body.identity.body_id != identity.body_id)
    {
        return null;
    }
    return body;
}

/// Queues every view of `body`, a body in the table, whose reader is ready
/// and that has no item queued: the body itself and, for a root, each
/// branch, since one packet that feeds a root can ready all of them. A
/// root's branches are in the table, since a body leaves it with its links
/// (`cleanup.zig:removeFromTable`).
pub fn queueReadyViews(runtime: *Runtime, body: *Body) void {
    queueIfReady(runtime, body);
    for (body.tee_branches.items) |branch|
        queueIfReady(runtime, branch);
}

/// Queues `body`, a body in the table, when its reader is ready and it has
/// no item queued.
pub fn queueIfReady(runtime: *Runtime, body: *Body) void {
    if (body.claimReadyForQueue())
        queueClaimed(runtime, body);
}

/// Queues the item of a body in the table whose place in the ready queue the
/// caller claimed (`Body.claimReadyForQueue`). Only bodies in the table queue
/// items, one at a time each, so the queue's room for them is the table's
/// slots (`register.zig`), and the push never fails.
pub fn queueClaimed(runtime: *Runtime, body: *Body) void {
    std.debug.assert(body.ready_queued);
    const listed = runtime.egress.state.bodies.get(body.identity.body_id);
    std.debug.assert(listed != null);
    std.debug.assert(listed.? == body);
    runtime.queueReadyWork(.{ .fetch_body_ready = body.identity.body_id }, body.ready_at_mono_ns);
}
