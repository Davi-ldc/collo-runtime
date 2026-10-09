//! The `egress_attach` packet: after the gateway a live worker was attached to is replaced, the
//! launcher hands the worker the worker half of its new egress session on the worker's control
//! socket. The body is `messages.EgressAttach` and the descriptors are the session's
//! `egress_shared.shared_fd_count`, in `egress_shared.RawFds.asArray` order, the order WorkerInit
//! carries them in, so the worker maps them with the checks it runs at boot
//! (`egress_shared.mapEndpointTakeForWorker`). The codec holds no state, so any thread may call it.

const std = @import("std");
const messages = @import("messages.zig");
const packet = @import("packet.zig");
const egress_shared = @import("egress_shared.zig");

/// Sends the worker half `fds` on the worker's control socket `fd`. The worker gets its own
/// copies, so the caller keeps and closes `fds`. On a nonblocking `fd` the call never waits and
/// fails with `error.WouldBlock` when the worker's socket is full. An incomplete half fails with
/// `error.InvalidEgressSharedEndpoint`, and any other failure is the socket's error.
pub fn send(fd: std.posix.fd_t, fds: egress_shared.RawFds) !void {
    if (!fds.isValid())
        return error.InvalidEgressSharedEndpoint;
    const message = messages.EgressAttach.init();
    const raw = fds.asArray();
    try packet.sendWithFds(fd, std.mem.asBytes(&message), &raw);
}

/// Takes the worker half out of a received `egress_attach` packet. A body other than exactly
/// `messages.EgressAttach` fails with `error.InvalidPacket`, another kind with
/// `error.InvalidMessageKind`, and any descriptor count other than `shared_fd_count` with
/// `error.InvalidPacket`; on every failure the descriptors stay in `received`, whose `deinit`
/// closes them. On success the caller owns the returned descriptors.
pub fn decode(received: *packet.ReceivedPacket) !egress_shared.RawFds {
    if (received.bytes.len != @sizeOf(messages.EgressAttach))
        return error.InvalidPacket;
    const message = packet.readStruct(messages.EgressAttach, received.bytes);
    if (try messages.decodeMessageKind(message.kind) != .egress_attach)
        return error.InvalidMessageKind;
    if (received.fd_count != egress_shared.shared_fd_count)
        return error.InvalidPacket;
    var taken: [egress_shared.shared_fd_count]std.posix.fd_t = undefined;
    for (&taken, 0..) |*slot, index| {
        var owned = received.takeFd(index);
        slot.* = owned.release();
    }
    return .{
        .command_control_fd = taken[0],
        .command_producer_fd = taken[1],
        .command_consumer_fd = taken[2],
        .command_data_fd = taken[3],
        .completion_control_fd = taken[4],
        .completion_producer_fd = taken[5],
        .completion_consumer_fd = taken[6],
        .completion_data_fd = taken[7],
        .body_pool_control_fd = taken[8],
        .body_pool_producer_fd = taken[9],
        .body_pool_consumer_fd = taken[10],
        .body_pool_data_fd = taken[11],
        .upload_pool_control_fd = taken[12],
        .upload_pool_producer_fd = taken[13],
        .upload_pool_consumer_fd = taken[14],
        .upload_pool_data_fd = taken[15],
        .command_eventfd = taken[16],
        .completion_eventfd = taken[17],
        .liveness_fd = taken[18],
        .peer_liveness_fd = taken[19],
    };
}

comptime {
    // `decode` names every slot of `RawFds.asArray` by index.
    std.debug.assert(egress_shared.shared_fd_count == 20);
    std.debug.assert(egress_shared.shared_fd_count <= messages.max_fds_per_message);
}
