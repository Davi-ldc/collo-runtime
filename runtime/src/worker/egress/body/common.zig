//! The lookups and ready-queue helpers the fetch body files share, on the
//! worker's event loop thread; `root.zig` states the invariants they keep.

const bindings = @import("collo_bindings");
const egress_core = @import("collo_egress_core");
const request_context = @import("collo_worker_request").context;
const egress_context = @import("../context.zig");

pub const FetchBody = egress_core.fetch_body.Body;
pub const FetchBodyReadKind = egress_core.fetch_body.ReadKind;
pub const FetchBodyWaiter = egress_core.fetch_body.Waiter;
pub const FetchBodyPullWaiter = egress_core.fetch_body.PullWaiter;
pub const ResponseStreamDrain = FetchBody.PullDrain;

/// The identity of a new body of `fetch_id`, under `request`'s id and
/// generation.
pub fn nextIdentity(
    runtime: *egress_context.Context,
    request: *const request_context.RequestContext,
    fetch_id: u64,
) bindings.FetchBodyIdentity {
    return runtime.egress_state.nextBodyIdentity(request, fetch_id);
}

/// The body `identity` names, or null when no body has its id or the stored
/// identity differs in any field, as for a handle from an earlier request
/// generation. The table keeps its reference, so the pointer is valid until
/// the body leaves the table.
pub fn ptr(runtime: *egress_context.Context, identity: bindings.FetchBodyIdentity) ?*FetchBody {
    const body_ptr = runtime.egress_state.bodies.getPtr(identity.body_id) orelse return null;
    const body = body_ptr.*;
    if (body.identity.request_id != identity.request_id or
        body.identity.request_generation != identity.request_generation or
        body.identity.fetch_id != identity.fetch_id or
        body.identity.body_id != identity.body_id)
    {
        return null;
    }
    return body;
}

/// Adds the growth of the body's meters since the last call to its request's
/// fetch byte totals. The growth is taken even when the request is gone or its
/// generation moved on, so those bytes are dropped rather than charged to
/// another request.
pub fn accountEgress(runtime: *egress_context.Context, body: *FetchBody) void {
    const meters = body.takeUnaccountedEgressMeters();
    if (meters.billed_sent == 0 and meters.billed_received == 0 and meters.cost == 0)
        return;
    if (runtime.requests.get(body.identity.request_id)) |request| {
        if (request.request_generation == body.identity.request_generation) {
            request.fetch_billed_sent_bytes += meters.billed_sent;
            request.fetch_billed_received_bytes += meters.billed_received;
            request.fetch_cost_bytes += meters.cost;
        }
    }
}

/// Queues the body for settlement when it is ready and not already queued.
pub fn queueReady(runtime: *egress_context.Context, body: *FetchBody) !void {
    if (!body.claimReadyForQueue())
        return;
    try pushClaimedReady(runtime, body);
}

/// Queues a body whose ready slot the caller claimed. When the ready queue and
/// its backlog are both full, the claim is dropped and the body rescan flag is
/// set, so `ready.collectReady` queues the body later.
pub fn pushClaimedReady(runtime: *egress_context.Context, body: *FetchBody) !void {
    if (runtime.tryQueueReadyReadySince(
        .{ .fetch_body_ready = body.identity.body_id },
        body.ready_at_mono_ns,
    ))
        return;
    body.clearReadyQueued();
}
