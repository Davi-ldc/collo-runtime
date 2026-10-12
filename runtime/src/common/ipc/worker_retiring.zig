//! The `worker_retiring` packet: a worker asks the server to retire it, at
//! most once and only after WorkerReady, on its control socket. The body is
//! `messages.WorkerRetiring` alone and carries no descriptor. The worker keeps
//! answering every request that reaches it after the notice; the server,
//! which alone knows whether a request is still on its way, decides when the
//! worker goes. The codec holds no state, so any thread may call it.

const std = @import("std");
const messages = @import("messages.zig");
const packet = @import("packet.zig");

/// Sends the notice for `reason` on the worker's control socket `fd`. On a
/// nonblocking `fd` the call never waits and fails with `error.WouldBlock`
/// when the socket is full, so the caller sends it again once the socket
/// drains; any other failure is the socket's error.
pub fn send(fd: std.posix.fd_t, reason: messages.WorkerRetiringReason) !void {
    const message = messages.WorkerRetiring.init(reason);
    try packet.sendExact(fd, std.mem.asBytes(&message));
}

/// The reason a received `worker_retiring` packet names. A packet with any
/// descriptor, or a body other than exactly `messages.WorkerRetiring`, fails
/// with `error.InvalidPacket`, another kind with `error.InvalidMessageKind`,
/// and a reason `WorkerRetiringReason` does not name with
/// `error.InvalidWorkerRetiringReason`. The packet stays the caller's, and its
/// `deinit` closes whatever it carried.
pub fn decode(received: *const packet.ReceivedPacket) !messages.WorkerRetiringReason {
    if (received.fd_count != 0)
        return error.InvalidPacket;
    if (received.bytes.len != @sizeOf(messages.WorkerRetiring))
        return error.InvalidPacket;
    const message = packet.readStruct(messages.WorkerRetiring, received.bytes);
    if (try messages.decodeMessageKind(message.kind) != .worker_retiring)
        return error.InvalidMessageKind;
    return messages.decodeWorkerRetiringReason(message.reason);
}
