//! Turns the host's ingress-channel packets into live requests: a request
//! begin becomes a `RequestContext` with a live slot on the shared page, a
//! body chunk feeds that request's body pipe, and a reset cancels it. The
//! scheduler decides when packets are read; this file decides what they
//! mean. It runs on the worker's VM thread.
//!
//! A request's identity is the dispatch's, all of it assigned by the host:
//! the live slot is written from the dispatch's request id, generation, lane
//! slot and worker, and every later packet must match the identity of the
//! request it names.

const std = @import("std");
const ipc = @import("collo_ipc");
const common_worker_metrics_state = @import("collo_worker_state").metrics;
const request_context = @import("../context.zig");
const h2_ingress = @import("../http2/ingress.zig");

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

fn enqueueRequestBegin(runtime: anytype, received: *ipc.ingress_channel.Received) !void {
    var dispatch_work = try ipc.ingress_channel.decodeDispatchPayload(runtime.core.allocator, received);
    var dispatch_moved = false;
    defer if (!dispatch_moved)
        dispatch_work.deinit();

    try h2_ingress.validateStreamBeginDescriptor(received.descriptor, &dispatch_work);

    const started = runtime.nowMonoNs();
    const live_slot_index = try runtime.observability.worker_metrics_state.allocateLiveSlot(.{
        .external_request_id = dispatch_work.request_id,
        .request_lane_id = dispatch_work.request_lane_id,
        .request_slot = dispatch_work.request_slot,
        .request_generation = dispatch_work.request_generation,
        .worker_id = dispatch_work.worker_id,
        .worker_generation = dispatch_work.worker_generation,
        .billing_sequence = dispatch_work.request_id,
    }, started);
    errdefer freeLiveSlotBestEffort(&runtime.observability.worker_metrics_state, live_slot_index);

    const request_id = dispatch_work.request_id;
    const request_ctx = try runtime.core.allocator.create(request_context.RequestContext);
    errdefer runtime.core.allocator.destroy(request_ctx);
    request_ctx.* = request_context.RequestContext.initOwnedDispatch(
        runtime.core.allocator,
        received.descriptor.stream_id,
        dispatch_work,
        live_slot_index,
        started,
    );
    dispatch_moved = true;
    errdefer request_ctx.deinit();

    try request_ctx.body.initFromIngressFraming(
        request_ctx.requestAllocator(),
        dispatch_work.body_framing,
        received.descriptor.hasFlag(ipc.ingress_channel.flags.end_stream),
    );
    if (shouldTraceRequest(runtime)) {
        request_ctx.trace_enabled = true;
        request_ctx.trace.dispatch_enqueued_ns = started;
    }

    try runtime.requests.active.putNoClobber(runtime.core.allocator, request_id, request_ctx);
    errdefer _ = runtime.requests.active.fetchRemove(request_id);
    _ = queueDispatch(runtime, request_ctx);
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
/// has not started, or a body read that can settle. It stops at the first
/// item that still finds no room, which asks for the rescan again.
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
    }
}

/// Queues the request's `request_body_ready` work item unless one is
/// already queued. Returns false when the ready queue and its backlog are
/// full; the item then waits for `collectReadyRequests`.
pub fn queueBodyReady(runtime: anytype, request_ctx: *request_context.RequestContext) bool {
    if (request_ctx.body_ready_queued)
        return true;
    if (!runtime.tryQueueReadyWork(.{ .request_body_ready = request_ctx.exec.request_id }))
        return false;
    request_ctx.body_ready_queued = true;
    return true;
}

fn queueDispatch(runtime: anytype, request_ctx: *request_context.RequestContext) bool {
    if (request_ctx.dispatch_queued or request_ctx.dispatch_started)
        return true;
    if (!runtime.tryQueueReadyWork(.{ .request = request_ctx.exec.request_id }))
        return false;
    request_ctx.dispatch_queued = true;
    return true;
}

fn queueCancel(runtime: anytype, request_ctx: *request_context.RequestContext) bool {
    if (request_ctx.cancel_queued)
        return true;
    if (!runtime.tryQueueReadyWork(.{ .request_cancelled = request_ctx.exec.request_id }))
        return false;
    request_ctx.cancel_queued = true;
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

fn shouldTraceRequest(runtime: anytype) bool {
    if (!runtime.observability.trace_requests)
        return false;
    if (runtime.observability.trace_all_requests)
        return true;
    if (runtime.observability.traced_first_request)
        return false;
    runtime.observability.traced_first_request = true;
    return true;
}

fn freeLiveSlotBestEffort(
    state: *common_worker_metrics_state.WorkState,
    live_slot_index: common_worker_metrics_state.LiveSlotHandle,
) void {
    state.freeLiveSlot(live_slot_index) catch |err|
        std.log.warn("failed to release live slot during request enqueue rollback: {s}", .{@errorName(err)});
}
