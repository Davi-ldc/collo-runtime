//! The server's side of the gateway control wire (`egress/gateway/control.zig`): the attach
//! acknowledgement's session invariant, which an `ok` acknowledgement meets by carrying a worker
//! session id and a `rejected` one by carrying none, checked by both the sender and the decoder;
//! and the control reader's decoder, which accepts an attach acknowledgement and a session removal
//! report without descriptors and nothing else. The rest of the wire is covered in
//! `egress/tests/gateway/control.zig`. Lane: server-gateway-control.

const std = @import("std");
const os = @import("collo_os");
const ipc = @import("collo_ipc");

const control_client = @import("collo_server_gateway_control_client");
const control = control_client.protocol;

test "attach acknowledgement rejects invalid session invariants" {
    // The sends pass descriptor -1, so only a check that runs before the
    // write can produce the expected error.
    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        control.sendAttachAck(-1, .ok, 1, 0),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        control.sendAttachAck(-1, .rejected, 1, 9),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        decodeAttachAck(.ok, 1, 0),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        decodeAttachAck(.rejected, 1, 9),
    );
}

test "the control reader decodes an attach acknowledgement and a removal report and refuses every other packet" {
    const acknowledged = switch (try receiveAndDecode(&ackBytes(.attach_worker_ack, 5, 9), &.{})) {
        .attach_ack => |ack| ack,
        .session_removed => return error.TestUnexpectedControlPacket,
    };
    try std.testing.expectEqual(
        @as(u32, @intFromEnum(control.AttachAckStatus.ok)),
        acknowledged.status,
    );
    try std.testing.expectEqual(@as(u64, 5), acknowledged.request_id);
    try std.testing.expectEqual(@as(u64, 9), acknowledged.worker_session_id);

    const report_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(report_pair[0]);
    defer std.posix.close(report_pair[1]);
    try control.sendSessionRemoved(report_pair[0], 41);
    var report_scratch: [ack_packet_bytes]u8 = undefined;
    var report = try ipc.recvPacketWithFdsScratch(std.testing.allocator, report_pair[1], &report_scratch);
    defer report.deinit();
    switch (try control.decodeGatewayToServerPacket(&report)) {
        .session_removed => |removed| try std.testing.expectEqual(@as(u64, 41), removed.session_id),
        .attach_ack => return error.TestUnexpectedControlPacket,
    }

    // The same acknowledgement with a descriptor attached: the gateway sends none after its
    // ready report.
    const extra_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(extra_fd);
    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        receiveAndDecode(&ackBytes(.attach_worker_ack, 5, 9), &.{extra_fd}),
    );
    // An acknowledgement's length under another kind, and a second ready report.
    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        receiveAndDecode(&ackBytes(.request_ended, 5, 9), &.{}),
    );
    const ready = control.Header{
        .magic = control.magic,
        .kind = @intFromEnum(control.Kind.gateway_ready),
    };
    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        receiveAndDecode(std.mem.asBytes(&ready), &.{}),
    );
    try std.testing.expectError(error.ShortRead, receiveAndDecode(&[_]u8{ 1, 2, 3 }, &.{}));
}

const ack_packet_bytes: usize = @sizeOf(control.Header) + @sizeOf(control.AttachAck);

fn ackBytes(kind: control.Kind, request_id: u64, worker_session_id: u64) [ack_packet_bytes]u8 {
    const header = control.Header{
        .magic = control.magic,
        .kind = @intFromEnum(kind),
    };
    const body = control.AttachAck{
        .status = @intFromEnum(control.AttachAckStatus.ok),
        .request_id = request_id,
        .worker_session_id = worker_session_id,
    };
    var buffer: [ack_packet_bytes]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(control.Header)], std.mem.asBytes(&header));
    @memcpy(buffer[@sizeOf(control.Header)..], std.mem.asBytes(&body));
    return buffer;
}

/// Sends `bytes` with `fds` over a fresh socket pair and decodes the packet as the control
/// reader does.
fn receiveAndDecode(bytes: []const u8, fds: []const std.posix.fd_t) !control.GatewayToServer {
    const pair = try os.fd.socketPairType(
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
    );
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    try ipc.packet.sendWithFds(pair[0], bytes, fds);
    var scratch: [ack_packet_bytes]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch);
    defer packet.deinit();
    return control.decodeGatewayToServerPacket(&packet);
}

fn decodeAttachAck(
    status: control.AttachAckStatus,
    request_id: u64,
    worker_session_id: u64,
) !control.AttachAck {
    const header = control.Header{
        .magic = control.magic,
        .kind = @intFromEnum(control.Kind.attach_worker_ack),
    };
    const body = control.AttachAck{
        .status = @intFromEnum(status),
        .request_id = request_id,
        .worker_session_id = worker_session_id,
    };
    var buffer: [@sizeOf(control.Header) + @sizeOf(control.AttachAck)]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(control.Header)], std.mem.asBytes(&header));
    @memcpy(buffer[@sizeOf(control.Header)..], std.mem.asBytes(&body));
    return control.decodeAttachAck(&buffer);
}
