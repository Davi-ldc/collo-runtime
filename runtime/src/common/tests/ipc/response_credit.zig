//! Shared response credit arithmetic, wire validation and nonblocking sends.
//! Server ingress tests cover chunk lifetime and credit after socket writes;
//! worker tests cover scheduling when a grant arrives.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd = @import("collo_os").fd;

const message: ipc.ResponseCredit = .{
    .request_lane_id = 2,
    .request_slot = 7,
    .stream_id = 9,
    .request_id = 11,
    .request_generation = 13,
    .grant_chunks_total = 17,
};

fn packetFor(bytes: []u8) ipc.ReceivedPacket {
    return .{
        .allocator = std.testing.allocator,
        .bytes = bytes,
        .owned_buffer = null,
        .fds = @splat(.{}),
        .fd_count = 0,
    };
}

test "response credit bounds unpaid chunks and grants room after retirement" {
    var server: ipc.response_credit.Window = .{};
    var worker: ipc.response_credit.Window = .{};
    const window = ipc.response_credit.window;
    try std.testing.expectEqual(window, worker.available());
    worker.spend(window);
    for (0..window) |_|
        try std.testing.expect(server.trySpend());
    try std.testing.expect(!server.trySpend());
    try std.testing.expectEqual(@as(u64, 0), worker.available());
    const grant = server.retire();
    try std.testing.expect(server.trySpend());
    try std.testing.expect(!server.trySpend());
    try worker.grant(grant);
    try std.testing.expectEqual(@as(u64, 1), worker.available());
    worker.spend(1);
    try worker.grant(grant);
    try worker.grant(grant - 1);
    try std.testing.expectEqual(@as(u64, 0), worker.available());
    try std.testing.expectError(error.InvalidResponseCredit, worker.grant(worker.spent + window + 1));
    try std.testing.expectEqual(@as(u64, 0), worker.available());
    for (0..window) |_|
        _ = server.retire();
    try worker.grant(server.granted);
    try std.testing.expectEqual(window, worker.available());
}

test "response credit decodes its message kind and identity" {
    try std.testing.expectEqual(ipc.MessageKind.response_credit, try ipc.decodeMessageKind(28));
    var wire = message;
    var packet = packetFor(std.mem.asBytes(&wire));
    try std.testing.expectEqualDeep(message, try ipc.response_credit.decode(&packet));
}

test "response credit decode refuses padding, another kind, a grant below the window, descriptors and a wrong length" {
    var wire = message;
    var packet = packetFor(std.mem.asBytes(&wire));
    wire.reserved0 = 1;
    try std.testing.expectError(error.InvalidPacket, ipc.response_credit.decode(&packet));
    wire = message;
    wire.kind = @intFromEnum(ipc.MessageKind.worker_retiring);
    try std.testing.expectError(error.InvalidMessageKind, ipc.response_credit.decode(&packet));
    wire = message;
    wire.grant_chunks_total = 3;
    try std.testing.expectError(error.InvalidPacket, ipc.response_credit.decode(&packet));
    wire.grant_chunks_total = 4;
    _ = try ipc.response_credit.decode(&packet);
    wire.grant_chunks_total = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), (try ipc.response_credit.decode(&packet)).grant_chunks_total);
    packet.fd_count = 1;
    try std.testing.expectError(error.InvalidPacket, ipc.response_credit.decode(&packet));
    packet.fd_count = 0;
    packet.bytes = packet.bytes[0..39];
    try std.testing.expectError(error.InvalidPacket, ipc.response_credit.decode(&packet));
    var oversized: [41]u8 = undefined;
    @memcpy(oversized[0..40], std.mem.asBytes(&wire));
    packet.bytes = &oversized;
    try std.testing.expectError(error.InvalidPacket, ipc.response_credit.decode(&packet));
}

test "response credit never waits on a full blocking socket and publishes once after room returns" {
    const pair = try fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    var count: usize = 0;
    while (count < 4096) : (count += 1) {
        ipc.packet.sendExactNonblocking(pair[0], "x") catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    try std.testing.expect(count != 0);
    try std.testing.expect(count < 4096);
    try std.testing.expectError(error.WouldBlock, ipc.response_credit.send(pair[0], message));
    for (0..count) |_| {
        var filler: [1]u8 = undefined;
        try ipc.packet.recvPacketExact(pair[1], &filler);
        try std.testing.expectEqualStrings("x", &filler);
    }
    try ipc.response_credit.send(pair[0], message);
    var scratch: [40]u8 = undefined;
    var received = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch);
    defer received.deinit();
    try std.testing.expectEqualDeep(message, try ipc.response_credit.decode(&received));
    var polls = [_]std.posix.pollfd{.{ .fd = pair[1], .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&polls, 0));
}
