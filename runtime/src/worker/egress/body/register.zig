//! Creation of fetch response bodies, on the worker's VM thread. A new body
//! enters `State.bodies`, which holds its first reference.
//!
//! A body has at most one `fetch_body_ready` item in the ready queue
//! (`Body.ready_queued`), and the item of a body that left the table still
//! holds its place until it pops (`State.body_ready_orphans`). A new body
//! takes a slot only while the bodies in the table and those items together
//! stay below `fetch_bodies_per_worker_max`, so the queue never holds more
//! than that many body items, the bound the worker's ready queue is sized
//! for (`common/limits/worker.zig:egress_ready_items_max`).

const bindings = @import("collo_bindings");
const limits = @import("collo_limits");
const request_context = @import("collo_worker_request").context;
const Runtime = @import("../../runtime/root.zig").Runtime;
const common = @import("common.zig");

const Body = common.Body;

/// Registers an open, empty body of `fetch_id` under `request` and returns
/// its identity. Fails with `error.FetchBodyLimitExceeded` when no slot is
/// free (`reserveSlot`), or `error.OutOfMemory`; nothing stays registered on
/// failure.
pub fn registerOpen(
    runtime: *Runtime,
    request: *const request_context.RequestContext,
    fetch_id: u64,
) !bindings.FetchBodyIdentity {
    const state = &runtime.egress.state;
    try reserveSlot(runtime);
    const identity = state.nextBodyIdentity(request, fetch_id);
    const body = try runtime.core.allocator.create(Body);
    body.* = Body.initOpen(runtime.core.allocator, identity);
    state.bodies.putAssumeCapacityNoClobber(identity.body_id, body);
    return identity;
}

/// Makes room for one more body in the table, within the slots the file
/// header counts. Fails with `error.FetchBodyLimitExceeded` or
/// `error.OutOfMemory`.
pub fn reserveSlot(runtime: *Runtime) !void {
    const state = &runtime.egress.state;
    const slots_used = state.bodies.count() + state.body_ready_orphans;
    if (slots_used >= limits.worker.fetch_bodies_per_worker_max)
        return error.FetchBodyLimitExceeded;
    try state.bodies.ensureUnusedCapacity(runtime.core.allocator, 1);
}
