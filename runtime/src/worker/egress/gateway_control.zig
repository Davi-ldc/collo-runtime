//! The worker's writes to the egress gateway: commands into the shared command
//! ring, returned body-pool extents into the pool's release queue, and the
//! eventfd wakes that announce both. Runs on the worker's event loop thread.
//! Decoding gateway completions and deciding fetch and body lifecycles belong
//! to `gateway_runtime.zig` and `body/`.
//!
//! A failed command write detaches the worker from its gateway
//! (`gateway_runtime.disconnect`), which fails every active fetch; only
//! `tryQueuePacketReserved` hands a full ring back to its caller instead. A
//! detached worker has no session to tell anything, so a cancel or a release
//! it sends is dropped. A failed release means the pool's shared state is
//! corrupt, since its release queue has a slot for every block
//! (`body_pool_release_queue_capacity`), and the gateway writes that state
//! too, so the session goes as on any other fault of it. The release runs
//! inside a body's own release path or a detach's drain, where a detach
//! would free what its caller still uses, so it only marks the session
//! (`State.body_pool_release_failed`) and the event loop detaches the worker
//! between handlers.

const std = @import("std");
const ipc = @import("collo_ipc");
const egress_core = @import("collo_egress_core");
const egress_context = @import("context.zig");

/// Points the body-pool and credit release callbacks in `State` at `context`.
/// A borrowed chunk calls the pool callback when its last reader lets go, and
/// released chunks pass their credits to the credit callback.
pub fn bindBodyPoolRelease(
    runtime: *egress_context.Context,
    context: ?*anyopaque,
    body_pool_release_fn: *const fn (?*anyopaque, u64, usize) void,
    body_credit_release_fn: *const fn (?*anyopaque, egress_core.body_credit.Handle) void,
) void {
    runtime.egress_state.body_pool_release_context.bind(context, body_pool_release_fn);
    runtime.egress_state.body_credit_release_context.bind(context, body_credit_release_fn);
}

pub fn queuePacket(runtime: *egress_context.Context, bytes: []const u8) !void {
    return queuePacketReserved(runtime, bytes, 0);
}

/// Writes a command the gateway must not miss. A detached worker drops it,
/// since its session and everything the command names are gone; a failed
/// write has already detached the worker, so it is only logged.
pub fn queueCriticalPacket(runtime: *egress_context.Context, bytes: []const u8) void {
    if (runtime.egress_state.shared == null)
        return;
    queuePacket(runtime, bytes) catch |err| {
        std.log.warn(
            "critical egress gateway control packet failed; detached from the gateway: {s}",
            .{@errorName(err)},
        );
    };
}

/// Writes a command while leaving `reserved_free_bytes` of the ring free, and
/// wakes the gateway when it might otherwise miss the command. Every write
/// failure disconnects the gateway; a full ring returns
/// `error.EgressGatewayWorkerBackpressure`. Without an endpoint it fails with
/// `error.PeerClosed`.
pub fn queuePacketReserved(
    runtime: *egress_context.Context,
    bytes: []const u8,
    reserved_free_bytes: usize,
) !void {
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return error.PeerClosed;
    const result = endpoint.command.writePacketReserved(bytes, reserved_free_bytes) catch |err| switch (err) {
        error.EgressSharedRingFull => {
            runtime.disconnectEgressGateway();
            return error.EgressGatewayWorkerBackpressure;
        },
        else => {
            runtime.disconnectEgressGateway();
            return err;
        },
    };
    ipc.egress_shared.notifyAfterPacketWrite(endpoint.command_eventfd, result);
}

/// As `queuePacketReserved`, except that a full ring returns
/// `error.EgressSharedRingFull` without disconnecting, so the upload path can
/// park the task and retry on a later pump pass.
pub fn tryQueuePacketReserved(
    runtime: *egress_context.Context,
    bytes: []const u8,
    reserved_free_bytes: usize,
) !void {
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return error.PeerClosed;
    const result = endpoint.command.writePacketReserved(bytes, reserved_free_bytes) catch |err| switch (err) {
        error.EgressSharedRingFull => return error.EgressSharedRingFull,
        else => {
            runtime.disconnectEgressGateway();
            return err;
        },
    };
    ipc.egress_shared.notifyAfterPacketWrite(endpoint.command_eventfd, result);
}

/// Sends `EgressCancel` for `fetch_id`, with `reason` cut to fit the packet
/// buffer; a detached worker drops it, as `queueCriticalPacket` does.
pub fn sendCancel(runtime: *egress_context.Context, fetch_id: u64, reason: []const u8) void {
    if (runtime.egress_state.shared == null)
        return;
    const max_reason_len = if (runtime.dispatch_recv_scratch.len > @sizeOf(ipc.EgressCancel))
        runtime.dispatch_recv_scratch.len - @sizeOf(ipc.EgressCancel)
    else
        0;
    const reason_bytes = reason[0..@min(reason.len, max_reason_len, std.math.maxInt(u32))];
    const message = ipc.EgressCancel.init(fetch_id, @intCast(reason_bytes.len));
    var cursor: usize = 0;
    cursor += ipc.packet.writeStruct(runtime.dispatch_recv_scratch[cursor..], &message);
    cursor += ipc.packet.writeSlice(runtime.dispatch_recv_scratch[cursor..], reason_bytes);
    queueCriticalPacket(runtime, runtime.dispatch_recv_scratch[0..cursor]);
}

/// Sends `EgressReleaseBody` for the body `identity` names; any value with
/// `fetch_id` and `body_id` fields serves.
pub fn sendRelease(runtime: *egress_context.Context, identity: anytype) void {
    const message = ipc.EgressReleaseBody.init(identity.fetch_id, identity.body_id);
    queueCriticalPacket(runtime, std.mem.asBytes(&message));
}

pub fn releaseBodyCredit(runtime: *egress_context.Context, credit: egress_core.body_credit.Handle) void {
    _ = runtime;
    // The worker acknowledges body flow control only by returning pool
    // extents, so every chunk it queues carries credit `.none`; a real credit
    // here means some path broke that rule.
    switch (credit) {
        .none => {},
        else => std.log.warn("unexpected fetch body credit in gateway worker runtime: {s}", .{@tagName(credit)}),
    }
}

/// Queues the extent `handle`, `len` back to the gateway and records that the
/// next flush owes a wake. Without an endpoint it does nothing, and a failed
/// release marks the session for the event loop to detach
/// (`State.body_pool_release_failed`).
pub fn noteBodyPoolChunkReleased(runtime: *egress_context.Context, handle: u64, len: usize) void {
    if (len == 0)
        return;
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return;
    endpoint.body_pool.releaseChunk(handle, len) catch |err| {
        std.log.warn("failed to release gateway body pool chunk handle={d} len={d}: {s}", .{
            handle,
            len,
            @errorName(err),
        });
        runtime.egress_state.body_pool_release_failed = true;
        return;
    };
    // Every release-queue write comes through here, from the borrowed-chunk
    // release callback and from the orphan-chunk path in `gateway_runtime`,
    // so this flag lets one eventfd write per flush cover them all.
    runtime.egress_state.releases_need_notify = true;
}

/// Wakes the gateway through the command eventfd when releases were queued
/// since the last flush. A release returns pool space and, for HTTP/2,
/// refills the gateway's window toward the origin, so a missed wake stalls the
/// origin's flow control. Callers flush once per packet batch, ready item or
/// cleanup pass.
pub fn flushBodyPoolReleases(runtime: *egress_context.Context) void {
    if (!runtime.egress_state.releases_need_notify)
        return;
    runtime.egress_state.releases_need_notify = false;
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return;
    ipc.egress_shared.notify(endpoint.command_eventfd);
}
