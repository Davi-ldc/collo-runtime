//! The `egress_attach` packet (`common/ipc/egress_attach.zig`): its message
//! kind and size, the worker half's descriptors crossing a socketpair in
//! `RawFds.asArray` order and mapping as the half WorkerInit carries does, the
//! send that refuses an incomplete half or fails at once on a full socket,
//! and the decode that refuses another body, another kind or another
//! descriptor count while the packet keeps the descriptors for its `deinit` to
//! close. The launcher's reattach that sends the packet is covered by
//! `server/tests/supervisor/launcher.zig`, a worker that takes it by
//! `worker/tests/runtime/fetch.zig`, and a forked worker that takes it after
//! its gateway restarts by the zygote integration lane and local-e2e.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

const egress_attach = ipc.egress_attach;
const egress_shared = ipc.egress_shared;
const RawFds = egress_shared.RawFds;

/// The descriptors one packet carries: the whole worker half, every field of
/// `RawFds`.
const attach_fd_count: usize = egress_shared.shared_fd_count;
/// Packets a test writes at most while filling a socket; the kernel refuses
/// far fewer.
const filler_packets_max: usize = 1 << 16;

test "egress_attach is message kind 26 and its body is the kind alone" {
    try std.testing.expectEqual(@as(u32, 26), @intFromEnum(ipc.MessageKind.egress_attach));
    try std.testing.expectEqual(ipc.MessageKind.egress_attach, try ipc.decodeMessageKind(26));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ipc.EgressAttach));
    try std.testing.expectEqual(@as(u32, 26), ipc.EgressAttach.init().kind);
}

test "an egress_attach packet moves the worker half's descriptors in RawFds order" {
    var session = try createSession();
    defer session.deinit();
    const pair = try controlPair();
    defer closePair(pair);

    const sent = session.rawForWorker();
    try egress_attach.send(pair[0], sent);
    var scratch: [64]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch);
    defer packet.deinit();
    try std.testing.expectEqual(attach_fd_count, packet.fd_count);
    var received = try egress_attach.decode(&packet);
    defer received.close();
    try std.testing.expect(received.isValid());

    // Each received descriptor is a new one for the file sent in its slot,
    // and the sender's descriptor stays open.
    for (sent.asArray(), received.asArray()) |sent_fd, received_fd| {
        try std.testing.expect(sent_fd != received_fd);
        try expectSameFile(sent_fd, received_fd);
    }
    try expectSameEventfds(sent, received);

    var endpoint = try egress_shared.mapEndpointTakeForWorker(&received);
    defer endpoint.deinit();
    try endpoint.validateConsistentSession();
    try std.testing.expect(!received.isValid());
}

test "send refuses a half with any descriptor missing and sends nothing" {
    var session = try createSession();
    defer session.deinit();
    const pair = try controlPair();
    defer closePair(pair);

    const complete = session.rawForWorker();
    inline for (std.meta.fields(RawFds)) |field| {
        var half = complete;
        @field(half, field.name) = -1;
        try std.testing.expectError(
            error.InvalidEgressSharedEndpoint,
            egress_attach.send(pair[0], half),
        );
    }
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(
        error.WouldBlock,
        ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch),
    );
}

test "send on a full nonblocking socket fails with WouldBlock at once and leaves the half with the caller" {
    var session = try createSession();
    defer session.deinit();
    const pair = try controlPair();
    defer closePair(pair);

    // The worker reads nothing, so its socket fills.
    const filler: [8]u8 = @splat(0);
    const filled = for (0..filler_packets_max) |_| {
        ipc.packet.sendExact(pair[0], &filler) catch |err| switch (err) {
            error.WouldBlock => break true,
            else => return err,
        };
    } else false;
    try std.testing.expect(filled);

    const half = session.rawForWorker();
    const open_before = try openFdCount();
    try std.testing.expectError(error.WouldBlock, egress_attach.send(pair[0], half));
    try std.testing.expectEqual(open_before, try openFdCount());
    try std.testing.expect(half.isValid());
}

test "decode refuses another body, kind or descriptor count and the packet keeps the descriptors" {
    const pair = try controlPair();
    defer closePair(pair);
    const carried = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(carried);
    const carried_fds: [attach_fd_count + 1]std.posix.fd_t = @splat(carried);

    const attach = ipc.EgressAttach.init();
    const attach_bytes = std.mem.asBytes(&attach);
    var longer: [@sizeOf(ipc.EgressAttach) + 1]u8 = @splat(0);
    @memcpy(longer[0..@sizeOf(ipc.EgressAttach)], attach_bytes);
    const ready = ipc.WorkerReady.init();
    const unknown_kind: u32 = 999;

    const Case = struct {
        bytes: []const u8,
        fd_count: usize,
        expected: anyerror,
    };
    const ready_bytes = std.mem.asBytes(&ready);
    const unknown_bytes = std.mem.asBytes(&unknown_kind);
    const full = attach_fd_count;
    const cases = [_]Case{
        .{ .bytes = attach_bytes[0..2], .fd_count = full, .expected = error.InvalidPacket },
        .{ .bytes = &longer, .fd_count = full, .expected = error.InvalidPacket },
        .{ .bytes = ready_bytes, .fd_count = full, .expected = error.InvalidMessageKind },
        .{ .bytes = unknown_bytes, .fd_count = full, .expected = error.InvalidMessageKind },
        .{ .bytes = attach_bytes, .fd_count = 0, .expected = error.InvalidPacket },
        .{ .bytes = attach_bytes, .fd_count = full - 1, .expected = error.InvalidPacket },
        .{ .bytes = attach_bytes, .fd_count = full + 1, .expected = error.InvalidPacket },
    };
    for (cases) |case| {
        const open_before = try openFdCount();
        try ipc.packet.sendWithFds(pair[0], case.bytes, carried_fds[0..case.fd_count]);
        var scratch: [64]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch);
        try std.testing.expectError(case.expected, egress_attach.decode(&packet));
        try std.testing.expectEqual(case.fd_count, packet.fd_count);
        for (packet.fds[0..packet.fd_count]) |owned|
            try std.testing.expect(owned.isValid());
        packet.deinit();
        try std.testing.expectEqual(open_before, try openFdCount());
    }
}

/// A session on a wake set of its own. The session holds its own copy of
/// every wake descriptor, so the set closes once the session is built.
fn createSession() !egress_shared.SessionFds {
    var wake_set = try egress_shared.WakeSet.create();
    defer wake_set.deinit();
    return egress_shared.createSessionForWorker(&wake_set);
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

/// Fails unless both descriptors name the same file, which for every
/// descriptor of a half except the two eventfds is a file of its own.
fn expectSameFile(expected_fd: std.posix.fd_t, actual_fd: std.posix.fd_t) !void {
    const expected = try std.posix.fstat(expected_fd);
    const actual = try std.posix.fstat(actual_fd);
    try std.testing.expectEqual(expected.dev, actual.dev);
    try std.testing.expectEqual(expected.ino, actual.ino);
}

/// Fails unless each received eventfd is the one sent in its slot. Eventfds
/// share one anonymous inode, so a count written through the sent descriptor
/// and read through the received one tells the two apart.
fn expectSameEventfds(sent: RawFds, received: RawFds) !void {
    try writeCounter(sent.command_eventfd, 1);
    try writeCounter(sent.completion_eventfd, 2);
    try std.testing.expectEqual(@as(u64, 1), try readCounter(received.command_eventfd));
    try std.testing.expectEqual(@as(u64, 2), try readCounter(received.completion_eventfd));
}

fn writeCounter(eventfd: std.posix.fd_t, value: u64) !void {
    const written = try std.posix.write(eventfd, std.mem.asBytes(&value));
    try std.testing.expectEqual(@as(usize, @sizeOf(u64)), written);
}

fn readCounter(eventfd: std.posix.fd_t) !u64 {
    var value: u64 = 0;
    const read = try std.posix.read(eventfd, std.mem.asBytes(&value));
    try std.testing.expectEqual(@as(usize, @sizeOf(u64)), read);
    return value;
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
