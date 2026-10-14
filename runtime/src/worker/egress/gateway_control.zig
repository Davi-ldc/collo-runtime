//! The worker's writes to the egress gateway: commands into the shared command
//! ring, returned body-pool extents into the pool's release queue, and the
//! eventfd wakes that announce both. Runs on the worker's VM thread.
//! Decoding gateway completions and deciding fetch and body lifecycles belong
//! to `gateway_runtime.zig`, `task_runtime.zig` and `body/`.
//!
//! A failed command write detaches the worker from its gateway
//! (`gateway_runtime.detachForGatewayFault`), which fails every active fetch;
//! only `tryQueuePacketReserved` hands a full ring back to its caller
//! instead. A detached worker has no session to tell anything, so a stop or
//! a release it sends is dropped. A failed release means the pool's shared
//! state is corrupt, since its release queue has a slot for every block
//! (`body_pool_release_queue_capacity`), and the gateway writes that state
//! too, so the session goes as on any other fault of it. The release runs
//! inside a body's own release path or a detach's drain, where a detach
//! would free what its caller still uses, so it only marks the session
//! (`State.body_pool_release_failed`) and the event loop detaches the worker
//! between handlers.

const std = @import("std");
const ipc = @import("collo_ipc");
const Runtime = @import("../runtime/root.zig").Runtime;
const chunk = @import("body/chunk.zig");
const gateway_runtime = @import("gateway_runtime.zig");

/// Writes a command the gateway must not miss. A detached worker drops it,
/// since its session and everything the command names are gone; a failed
/// write has already detached the worker, so it is only logged.
pub fn queueCriticalPacket(runtime: *Runtime, bytes: []const u8) void {
    if (runtime.egress.state.shared == null)
        return;
    queuePacket(runtime, bytes) catch |err| {
        std.log.warn(
            "critical egress gateway control packet failed; detached from the gateway: {s}",
            .{@errorName(err)},
        );
    };
}

/// Writes a command and wakes the gateway when it might otherwise miss it.
/// Every write failure detaches the worker; a full ring returns
/// `error.EgressGatewayWorkerBackpressure`. Without an endpoint it fails
/// with `error.PeerClosed`.
fn queuePacket(runtime: *Runtime, bytes: []const u8) !void {
    const endpoint = if (runtime.egress.state.shared) |*endpoint| endpoint else return error.PeerClosed;
    const result = endpoint.command.writePacketReserved(bytes, 0) catch |err| {
        gateway_runtime.detachForGatewayFault(runtime, "command_write");
        return switch (err) {
            error.EgressSharedRingFull => error.EgressGatewayWorkerBackpressure,
            else => err,
        };
    };
    ipc.egress_shared.notifyAfterPacketWrite(endpoint.command_eventfd, result);
}

/// Writes a command while leaving `reserved_free_bytes` of the ring free, so
/// stops still fit behind it. A full ring returns
/// `error.EgressSharedRingFull` without detaching, so the upload path can
/// park the task and retry on a later pump pass; any other write failure
/// detaches the worker. Without an endpoint it fails with
/// `error.PeerClosed`.
pub fn tryQueuePacketReserved(runtime: *Runtime, bytes: []const u8, reserved_free_bytes: usize) !void {
    const endpoint = if (runtime.egress.state.shared) |*endpoint| endpoint else return error.PeerClosed;
    const result = endpoint.command.writePacketReserved(bytes, reserved_free_bytes) catch |err| switch (err) {
        error.EgressSharedRingFull => return error.EgressSharedRingFull,
        else => {
            gateway_runtime.detachForGatewayFault(runtime, "command_write");
            return err;
        },
    };
    ipc.egress_shared.notifyAfterPacketWrite(endpoint.command_eventfd, result);
}

/// Sends the stop of `fetch_id`; a detached worker drops it, as
/// `queueCriticalPacket` does. Only `task_runtime.stopFetch` calls it, which
/// sends one per fetch and none for a fetch the gateway holds nothing of.
pub fn sendStop(runtime: *Runtime, fetch_id: u64) void {
    const message = ipc.EgressStop.init(fetch_id);
    queueCriticalPacket(runtime, std.mem.asBytes(&message));
}

/// The release that returns the extent `handle`, `len` of the body pool
/// through `runtime` once the last view of it is done.
pub fn bodyPoolRelease(runtime: *Runtime, handle: u64, len: usize) chunk.BorrowedRelease {
    return .{
        .context = runtime,
        .handle = handle,
        .len = len,
        .release_fn = releaseBodyPoolExtent,
    };
}

fn releaseBodyPoolExtent(context: ?*anyopaque, handle: u64, len: usize) void {
    const runtime: *Runtime = @ptrCast(@alignCast(context orelse return));
    noteBodyPoolChunkReleased(runtime, handle, len);
}

/// Queues the extent `handle`, `len` back to the gateway and records that the
/// next flush owes a wake. Without an endpoint it does nothing, and a failed
/// release marks the session for the event loop to detach
/// (`State.body_pool_release_failed`).
pub fn noteBodyPoolChunkReleased(runtime: *Runtime, handle: u64, len: usize) void {
    if (len == 0)
        return;
    const endpoint = if (runtime.egress.state.shared) |*endpoint| endpoint else return;
    endpoint.body_pool.releaseChunk(handle, len) catch |err| {
        std.log.warn("failed to release gateway body pool chunk handle={d} len={d}: {s}", .{
            handle,
            len,
            @errorName(err),
        });
        runtime.egress.state.body_pool_release_failed = true;
        return;
    };
    // Every release-queue write comes through here, so this flag lets one
    // eventfd write per flush cover them all.
    runtime.egress.state.releases_need_notify = true;
}

/// Wakes the gateway through the command eventfd when releases were queued
/// since the last flush. A release returns pool space and, for HTTP/2,
/// refills the gateway's window toward the origin, so a missed wake stalls the
/// origin's flow control. Callers flush once per packet batch, ready item or
/// cleanup pass.
pub fn flushBodyPoolReleases(runtime: *Runtime) void {
    const state = &runtime.egress.state;
    if (!state.releases_need_notify)
        return;
    state.releases_need_notify = false;
    const endpoint = if (state.shared) |*endpoint| endpoint else return;
    ipc.egress_shared.notify(endpoint.command_eventfd);
}
