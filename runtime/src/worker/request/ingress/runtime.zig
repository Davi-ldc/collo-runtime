//! Turns the host's ingress-channel packets into live requests: a request
//! begin becomes a `RequestContext` and takes a live slot on the shared page,
//! a body chunk feeds that request's body pipe, and a reset cancels it. The
//! scheduler decides when packets are read; this file decides what they
//! mean. It runs on the worker's VM thread.
//!
//! A request's identity is the dispatch's, all of it assigned by the host:
//! the request's live slot is the one at the pool slot it was dispatched on
//! (`DispatchWork.worker_slot`), written with its request id and generation,
//! and every later packet must match the identity of the request it names. A
//! begin never takes the id or the pool slot of a request still in the
//! active map, so each dispatched request there holds a pool slot of its own.

const ipc = @import("collo_ipc");
const request_context = @import("../context.zig");
const h2_ingress = @import("../http2/ingress.zig");
const response_stream = @import("../response_stream.zig");

/// Applies one received packet and takes `received` on every path. A packet
/// for a request that is no longer active is dropped, and one whose identity
/// differs from its request's fails with `error.InvalidH2StreamIdentity`. A
/// response op, or any op the host never sends a worker, fails with
/// `error.InvalidH2WorkerInboundDescriptor`.
pub fn enqueueDescriptor(runtime: anytype, received: ipc.ingress_channel.Received) !void {
    var owned = received;
    defer owned.deinit();

    switch (owned.descriptor.op) {
        @intFromEnum(ipc.ingress_channel.Op.request_begin) => try enqueueRequestBegin(runtime, &owned),
        @intFromEnum(ipc.ingress_channel.Op.request_body_chunk) => try enqueueBodyChunk(runtime, &owned),
        @intFromEnum(ipc.ingress_channel.Op.request_reset) => try enqueueReset(runtime, &owned),
        @intFromEnum(ipc.ingress_channel.Op.response_head),
        @intFromEnum(ipc.ingress_channel.Op.response_chunk),
        @intFromEnum(ipc.ingress_channel.Op.response_end),
        => return error.InvalidH2WorkerInboundDescriptor,
        else => return error.InvalidH2WorkerInboundDescriptor,
    }
}

/// Applies a cumulative body grant to the request it names and queues the
/// request's response advance when the grant ends its wait for credit. A
/// grant for a request no longer active is dropped, and one whose identity
/// differs from its request's fails with `error.InvalidH2StreamIdentity`.
pub fn enqueueResponseCredit(runtime: anytype, credit: ipc.messages.ResponseCredit) !void {
    if (request_context.isReservedId(credit.request_id))
        return;
    const request_ctx = runtime.requests.active.get(credit.request_id) orelse return;
    if (request_ctx.ingress_channel_id != credit.stream_id or
        request_ctx.dispatch_work.request_generation != credit.request_generation or
        request_ctx.dispatch_work.request_lane_id != credit.request_lane_id or
        request_ctx.dispatch_work.request_slot != credit.request_slot)
        return error.InvalidH2StreamIdentity;
    try request_ctx.response_credit.grant(credit.grant_chunks_total);
    if (request_ctx.response_advance.wait == .credit and request_ctx.response_credit.available() != 0) {
        request_ctx.response_advance.wait = .none;
        _ = response_stream.queueAdvance(runtime, request_ctx);
    }
}

fn enqueueRequestBegin(runtime: anytype, received: *ipc.ingress_channel.Received) !void {
    // The decode refuses a `worker_slot` the page has no live slot for
    // (`common/ipc/dispatch.zig:validateWorkerSlot`), and
    // `validateStreamBeginDescriptor` a zero request id, so the live slot
    // write below holds whatever the server sent.
    var dispatch_work = try ipc.ingress_channel.decodeDispatchPayload(runtime.core.allocator, received);
    var dispatch_moved = false;
    defer if (!dispatch_moved)
        dispatch_work.deinit();

    try h2_ingress.validateStreamBeginDescriptor(received.descriptor, &dispatch_work);
    try requireUnheld(runtime, dispatch_work.request_id, dispatch_work.worker_slot);

    const started = runtime.nowMonoNs();
    const request_id = dispatch_work.request_id;
    const worker_slot = dispatch_work.worker_slot;
    // The live slot of the request's pool slot names it from here on, in
    // place of the last request begun there
    // (`common/worker_state/page/live_slots.zig`). A failure below ends the
    // loop, and the slot keeps naming this request, with no CPU, for the
    // server to end it from.
    runtime.observability.metrics_view.beginLiveSlot(worker_slot, request_id, dispatch_work.request_generation);

    const request_ctx = try runtime.core.allocator.create(request_context.RequestContext);
    errdefer runtime.core.allocator.destroy(request_ctx);
    request_ctx.* = request_context.RequestContext.initOwnedDispatch(
        runtime.core.allocator,
        received.descriptor.stream_id,
        dispatch_work,
        started,
    );
    dispatch_moved = true;
    errdefer request_ctx.deinit();
    // The budget is the definition's, the same for every request the worker
    // serves (`runtime/owner.zig`).
    request_ctx.cpu_budget_ns = runtime.owners.request_cpu_budget_ns;
    request_ctx.arrived_retiring = runtime.retirement.reason != null;

    try request_ctx.body.initFromIngressFraming(
        request_ctx.requestAllocator(),
        dispatch_work.body_framing,
        received.descriptor.hasFlag(ipc.ingress_channel.flags.end_stream),
    );

    try runtime.requests.active.putNoClobber(runtime.core.allocator, request_id, request_ctx);
    errdefer _ = runtime.requests.active.fetchRemove(request_id);
    _ = queueDispatch(runtime, request_ctx);
}

/// Refuses a begin that names what an unfinished request still holds: its
/// id, which keys the active map, with `error.RequestIdInUse`, or its pool
/// slot, whose live slot still carries that request's CPU for the server,
/// with `error.WorkerSlotInUse`. A request is unfinished while it is in the
/// active map, from its begin to its finish, which sends its `request_done`
/// and drops it in one step (`serve/response_finish.zig:finishRequest`). The
/// server dispatches on a pool slot only after that `request_done` arrived
/// (`server/ingress/runner/request_slot.zig`) and never reuses a request id,
/// so either refusal is the server's protocol error and ends the loop. The
/// refusal makes the bound local: every dispatched request in the map holds
/// a pool slot of its own, so the map holds at most `LIVE_SLOT_COUNT` of them
/// (`serve/termination.zig`), whatever the server sends.
fn requireUnheld(runtime: anytype, request_id: u64, worker_slot: u8) error{ RequestIdInUse, WorkerSlotInUse }!void {
    if (runtime.requests.active.contains(request_id))
        return error.RequestIdInUse;
    var iterator = runtime.requests.active.iterator();
    while (iterator.next()) |entry| {
        // An evaluation holds no pool slot.
        if (request_context.isReservedId(entry.key_ptr.*))
            continue;
        if (entry.value_ptr.*.dispatch_work.worker_slot == worker_slot)
            return error.WorkerSlotInUse;
    }
}

fn enqueueBodyChunk(runtime: anytype, received: *ipc.ingress_channel.Received) !void {
    const request_ctx = runtime.requests.active.get(received.descriptor.request_id) orelse return;
    try validateH2RequestDescriptor(request_ctx, received.descriptor);
    if (!received.descriptor.hasFlag(ipc.ingress_channel.flags.inline_bytes) and
        received.descriptor.byte_len != 0)
    {
        return error.IngressSharedPayloadUnavailable;
    }
    if (received.descriptor.byte_len != received.payload.len)
        return error.InvalidH2WorkerInboundDescriptor;
    request_ctx.body.appendH2ReadBytes(
        request_ctx.requestAllocator(),
        received.payload,
        received.descriptor.hasFlag(ipc.ingress_channel.flags.end_stream),
    ) catch |err| switch (err) {
        error.RequestTooLarge,
        error.RequestBodyNotInitialized,
        => {
            request_ctx.client_reset = true;
            request_ctx.body.pipe.fail(@errorName(err));
            _ = queueCancel(runtime, request_ctx);
            return;
        },
        else => return err,
    };
    if (received.descriptor.hasFlag(ipc.ingress_channel.flags.end_stream) and
        !request_ctx.body.isComplete())
    {
        request_ctx.client_reset = true;
        request_ctx.body.pipe.fail("request body ended early");
        _ = queueCancel(runtime, request_ctx);
        return;
    }
    if (bodyReadReady(request_ctx))
        _ = queueBodyReady(runtime, request_ctx);
}

fn enqueueReset(runtime: anytype, received: *ipc.ingress_channel.Received) !void {
    const request_ctx = runtime.requests.active.get(received.descriptor.request_id) orelse return;
    try validateH2RequestDescriptor(request_ctx, received.descriptor);
    if (request_ctx.client_reset)
        return;
    request_ctx.client_reset = true;
    request_ctx.body.pipe.fail("http2 stream reset");
    _ = queueCancel(runtime, request_ctx);
}

/// After a full ready queue asked for a rescan, queues what each active
/// request still waits for: the cancel of a reset request, a dispatch that
/// has not started, a body read that can settle, or a stamped response
/// advance of any source. It stops at the first item that
/// still finds no room, which asks for the rescan again.
pub fn collectReadyRequests(runtime: anytype) void {
    if (!runtime.scheduler.ingress_rescan_needed)
        return;
    runtime.scheduler.ingress_rescan_needed = false;

    var iterator = runtime.requests.active.iterator();
    while (iterator.next()) |entry| {
        const request_ctx = entry.value_ptr.*;
        if (request_ctx.finish_started)
            continue;
        if (request_ctx.client_reset) {
            if (!queueCancel(runtime, request_ctx))
                return;
            continue;
        }
        if (!request_ctx.dispatch_started) {
            if (!queueDispatch(runtime, request_ctx))
                return;
        }
        if (bodyReadReady(request_ctx)) {
            if (!queueBodyReady(runtime, request_ctx))
                return;
        }
        if (request_ctx.response_advance.state == .unqueued) {
            if (!response_stream.queueAdvance(runtime, request_ctx))
                return;
        }
    }
}

/// Queues the request's `request_body_ready` work item unless one is
/// already queued. Returns false when the ready queue and its backlog are
/// full; the item then waits for `collectReadyRequests`, keeping the instant
/// it first became ready (`queueStamped`).
pub fn queueBodyReady(runtime: anytype, request_ctx: *request_context.RequestContext) bool {
    if (request_ctx.body_ready_queued)
        return true;
    if (!queueStamped(runtime, request_ctx.exec.request_id, .body_ready, &request_ctx.body_ready_since_ns))
        return false;
    request_ctx.body_ready_queued = true;
    return true;
}

fn queueDispatch(runtime: anytype, request_ctx: *request_context.RequestContext) bool {
    if (request_ctx.dispatch_queued or request_ctx.dispatch_started)
        return true;
    if (!queueStamped(runtime, request_ctx.exec.request_id, .dispatch, &request_ctx.dispatch_ready_since_ns))
        return false;
    request_ctx.dispatch_queued = true;
    return true;
}

fn queueCancel(runtime: anytype, request_ctx: *request_context.RequestContext) bool {
    if (request_ctx.cancel_queued)
        return true;
    if (!queueStamped(runtime, request_ctx.exec.request_id, .cancel, &request_ctx.cancel_ready_since_ns))
        return false;
    request_ctx.cancel_queued = true;
    return true;
}

const ReadyKind = enum { dispatch, body_ready, cancel };

/// Queues the `kind` item of request `request_id` with the instant it first
/// became ready, `ready_since_ns`, which the first attempt stamps and every
/// retry after a full queue keeps, so the wait for queue room counts as the
/// request's waiting, as it does for every source that keeps its own stamp;
/// a queued item clears it.
fn queueStamped(runtime: anytype, request_id: u64, comptime kind: ReadyKind, ready_since_ns: *u64) bool {
    if (ready_since_ns.* == 0)
        ready_since_ns.* = runtime.nowMonoNs();
    const queued = switch (kind) {
        .dispatch => runtime.tryQueueReadyWorkReadySince(.{ .request = request_id }, ready_since_ns.*),
        .body_ready => runtime.tryQueueReadyWorkReadySince(.{ .request_body_ready = request_id }, ready_since_ns.*),
        .cancel => runtime.tryQueueReadyWorkReadySince(.{ .request_cancelled = request_id }, ready_since_ns.*),
    };
    if (!queued)
        return false;
    ready_since_ns.* = 0;
    return true;
}

fn bodyReadReady(request_ctx: *const request_context.RequestContext) bool {
    if (!request_ctx.body.hasWaiter())
        return false;
    if (request_ctx.body.isComplete())
        return true;
    return request_ctx.body.pipe.state == .errored;
}

fn validateH2RequestDescriptor(
    request_ctx: *request_context.RequestContext,
    descriptor: ipc.ingress_channel.Descriptor,
) !void {
    if (request_ctx.ingress_channel_id != descriptor.stream_id)
        return error.InvalidH2StreamIdentity;
    if (request_ctx.dispatch_work.request_generation != descriptor.request_generation or
        request_ctx.dispatch_work.request_lane_id != descriptor.request_lane_id or
        request_ctx.dispatch_work.request_slot != descriptor.request_slot)
    {
        return error.InvalidH2StreamIdentity;
    }
}
