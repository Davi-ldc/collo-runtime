//! The `worker_retiring` packet (`common/ipc/worker_retiring.zig`): its
//! message kind, size and reasons, the notice crossing a control socketpair
//! with each reason, the send that fails at once on a full nonblocking
//! socket, and the decode that refuses another length, another kind, a
//! descriptor or an unnamed reason while the packet keeps what it carried for
//! its `deinit` to close. The worker that sends the notice and the server
//! that retires it are covered by the worker and server-ingress lanes.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

const worker_retiring = ipc.worker_retiring;

/// Packets a test writes at most while filling a socket; the kernel refuses
/// far fewer.
const filler_packets_max: usize = 1 << 16;

test "worker_retiring is message kind 27, its body the kind and a reason, and the reasons are 1 to 3" {
    try std.testing.expectEqual(@as(u32, 27), @intFromEnum(ipc.MessageKind.worker_retiring));
    try std.testing.expectEqual(ipc.MessageKind.worker_retiring, try ipc.decodeMessageKind(27));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ipc.WorkerRetiring));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(ipc.WorkerRetiringReason.routes_failed));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(ipc.WorkerRetiringReason.vm_terminated));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(ipc.WorkerRetiringReason.egress_detached));
    const message = ipc.WorkerRetiring.init(.vm_terminated);
    try std.testing.expectEqual(@as(u32, 27), message.kind);
    try std.testing.expectEqual(@as(u32, 2), message.reason);
    try std.testing.expectEqual(ipc.WorkerRetiringReason.egress_detached, try ipc.decodeWorkerRetiringReason(3));
    try std.testing.expectError(error.InvalidWorkerRetiringReason, ipc.decodeWorkerRetiringReason(0));
    try std.testing.expectError(error.InvalidWorkerRetiringReason, ipc.decodeWorkerRetiringReason(4));
}

test "a worker_retiring notice crosses the control socket with its reason" {
    const pair = try controlPair();
    defer closePair(pair);

    for (std.enums.values(ipc.WorkerRetiringReason)) |reason| {
        try worker_retiring.send(pair[0], reason);
        var scratch: [64]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch);
        defer packet.deinit();
        try std.testing.expectEqual(@as(usize, @sizeOf(ipc.WorkerRetiring)), packet.bytes.len);
        try std.testing.expectEqual(reason, try worker_retiring.decode(&packet));
    }
}

test "send on a full nonblocking socket fails with WouldBlock at once" {
    const pair = try controlPair();
    defer closePair(pair);

    // The server reads nothing, so the worker's socket fills.
    const filler: [8]u8 = @splat(0);
    const filled = for (0..filler_packets_max) |_| {
        ipc.packet.sendExact(pair[0], &filler) catch |err| switch (err) {
            error.WouldBlock => break true,
            else => return err,
        };
    } else false;
    try std.testing.expect(filled);
    try std.testing.expectError(error.WouldBlock, worker_retiring.send(pair[0], .routes_failed));
}

test "decode refuses another length, another kind, a descriptor and an unnamed reason, and the packet keeps the descriptors" {
    const pair = try controlPair();
    defer closePair(pair);
    const carried = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(carried);
    const carried_fds = [_]std.posix.fd_t{carried};

    const notice = ipc.WorkerRetiring.init(.routes_failed);
    const notice_bytes = std.mem.asBytes(&notice);
    var longer: [@sizeOf(ipc.WorkerRetiring) + 1]u8 = @splat(0);
    @memcpy(longer[0..@sizeOf(ipc.WorkerRetiring)], notice_bytes);
    var other_kind = notice;
    other_kind.kind = @intFromEnum(ipc.MessageKind.egress_attach);
    var unknown_kind = notice;
    unknown_kind.kind = 999;
    var unnamed_reason = notice;
    unnamed_reason.reason = 4;
    var zero_reason = notice;
    zero_reason.reason = 0;

    const Case = struct {
        bytes: []const u8,
        fd_count: usize,
        expected: anyerror,
    };
    const cases = [_]Case{
        .{ .bytes = notice_bytes[0..4], .fd_count = 0, .expected = error.InvalidPacket },
        .{ .bytes = &longer, .fd_count = 0, .expected = error.InvalidPacket },
        .{ .bytes = notice_bytes, .fd_count = 1, .expected = error.InvalidPacket },
        .{ .bytes = std.mem.asBytes(&other_kind), .fd_count = 0, .expected = error.InvalidMessageKind },
        .{ .bytes = std.mem.asBytes(&unknown_kind), .fd_count = 0, .expected = error.InvalidMessageKind },
        .{ .bytes = std.mem.asBytes(&unnamed_reason), .fd_count = 0, .expected = error.InvalidWorkerRetiringReason },
        .{ .bytes = std.mem.asBytes(&zero_reason), .fd_count = 0, .expected = error.InvalidWorkerRetiringReason },
    };
    for (cases) |case| {
        const open_before = try openFdCount();
        try ipc.packet.sendWithFds(pair[0], case.bytes, carried_fds[0..case.fd_count]);
        var scratch: [64]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch);
        try std.testing.expectError(case.expected, worker_retiring.decode(&packet));
        try std.testing.expectEqual(case.fd_count, packet.fd_count);
        for (packet.fds[0..packet.fd_count]) |owned|
            try std.testing.expect(owned.isValid());
        packet.deinit();
        try std.testing.expectEqual(open_before, try openFdCount());
    }
}

/// A nonblocking pair, so a packet that should not exist fails the receive
/// instead of hanging it.
fn controlPair() ![2]std.posix.fd_t {
    const flags = std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
    return fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | flags);
}

fn closePair(pair: [2]std.posix.fd_t) void {
    std.posix.close(pair[0]);
    std.posix.close(pair[1]);
}

/// Open descriptors of this process, counted from `/proc/self/fd` without
/// the directory's own.
fn openFdCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const fd = std.fmt.parseInt(std.posix.fd_t, entry.name, 10) catch continue;
        if (fd == dir.fd)
            continue;
        count += 1;
    }
    return count;
}
