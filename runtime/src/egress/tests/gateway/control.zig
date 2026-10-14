//! The control wire between the server and the gateway (`egress/gateway/control.zig`): an attach
//! carries its session's descriptors and comes back as an attach ack, and a removal report names
//! a session, never 0, the two packets the gateway sends after its ready report; the hello carries
//! the token key and exactly one descriptor, the policy image's memfd, with the image's length; a
//! `boot_ended` names one session, never 0, and carries no descriptor; shutdown carries no
//! descriptor. The kinds keep their numbers, and each decoder refuses a packet whose length,
//! reserved bytes, ids, key or descriptors break the wire's rules, a kind only the other side
//! sends, and a number no kind has. The order the gateway takes packets in, the hello first and
//! once, and its checks of the image the hello lends are its control flow's (`control_flow.zig`),
//! and the attach ack's session rule and the server's control client are covered in
//! `server/tests/gateway/` (lane server-gateway-control-test). Lane: egress-gateway-test.

const std = @import("std");
const os = @import("collo_os");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const network = @import("collo_egress_client").network;

const policy_image = @import("support/policy_image.zig");

const control = gateway.control;
const egress_token = ipc.egress_token;

const test_key = keyFrom(0x21);

test "an attach carries its request id, its security cell and the session's shared descriptors" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var shared = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer shared.deinit();

    var scratch: [256]u8 = undefined;
    const security_cell_id: control.SecurityCellId = [_]u8{42} ** 16;
    try control.sendAttachWorker(control_pair[0], 99, security_cell_id, shared.rawForGateway());

    var received = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer received.deinit();

    switch (try control.decode(&received)) {
        .attach_worker => |attach| {
            var fds = attach.fds;
            defer fds.close();
            try std.testing.expectEqual(@as(u64, 99), attach.request_id);
            try std.testing.expectEqualSlices(u8, &security_cell_id, &attach.security_cell_id);
            try std.testing.expectEqual(control.attach_worker_message_bytes, received.bytes.len);
            try std.testing.expect(fds.isValid());
        },
        else => return error.UnexpectedControlMessage,
    }
}

test "an attach ack carries its request id and the session it names" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    try control.sendAttachAck(control_pair[0], .ok, 77, 12345);

    var scratch: [256]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer packet.deinit();
    const ack = try attachAckOf(try control.decodeGatewayToServerPacket(&packet));
    try std.testing.expectEqual(@intFromEnum(control.AttachAckStatus.ok), ack.status);
    try std.testing.expectEqual(@as(u64, 77), ack.request_id);
    try std.testing.expectEqual(@as(u64, 12345), ack.worker_session_id);
}

test "a removal report carries the session it names and its cause, and never session 0" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        control.sendSessionRemoved(control_pair[0], 0, .liveness_closed),
    );
    for ([_]control.SessionRemovedCause{ .liveness_closed, .protocol_violation }) |cause| {
        try control.sendSessionRemoved(control_pair[0], 4242, cause);

        var scratch: [256]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
        defer packet.deinit();
        try std.testing.expectEqual(@sizeOf(control.Header) + @sizeOf(control.SessionRemoved), packet.bytes.len);
        switch (try control.decodeGatewayToServerPacket(&packet)) {
            .session_removed => |removed| {
                try std.testing.expectEqual(@as(u64, 4242), removed.session_id);
                try std.testing.expectEqual(cause, removed.cause);
            },
            .attach_ack => return error.TestUnexpectedControlPacket,
        }
    }
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(control.SessionRemovedCause.liveness_closed));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(control.SessionRemovedCause.protocol_violation));
}

test "a boot_ended packet round-trips the session it names and is never sent for session 0" {
    const control_pair = try os.fd.socketPairType(
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
    );
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    try std.testing.expectError(error.InvalidEgressGatewayControl, control.sendBootEnded(control_pair[0], 0));
    try control.sendBootEnded(control_pair[0], 31);

    var scratch: [256]u8 = undefined;
    {
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
        defer packet.deinit();
        try std.testing.expectEqual(@sizeOf(control.Header) + @sizeOf(control.BootEnded), packet.bytes.len);
        switch (try control.decode(&packet)) {
            .boot_ended => |ended| try std.testing.expectEqual(@as(u64, 31), ended.session_id),
            else => return error.UnexpectedControlMessage,
        }
    }
    // The refused send for session 0 left nothing on the socket.
    try std.testing.expectError(
        error.WouldBlock,
        ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch),
    );
}

test "a boot_ended packet for session 0, of another length or with a descriptor is refused" {
    var buffer: [@sizeOf(control.Header) + @sizeOf(control.BootEnded) + 1]u8 = undefined;

    // The packet every case below breaks in one place decodes.
    {
        var packet = receivedFrom(writeBootEnded(&buffer, 5));
        switch (try control.decode(&packet)) {
            .boot_ended => |ended| try std.testing.expectEqual(@as(u64, 5), ended.session_id),
            else => return error.UnexpectedControlMessage,
        }
    }

    try expectRefused(writeBootEnded(&buffer, 0));

    // A byte short, a byte over, and a bare header.
    const whole = writeBootEnded(&buffer, 5);
    try expectRefused(buffer[0 .. whole.len - 1]);
    buffer[whole.len] = 0;
    try expectRefused(buffer[0 .. whole.len + 1]);
    try expectRefused(writeHeader(&buffer, @intFromEnum(control.Kind.boot_ended)));

    var with_descriptor = try receivedWithDescriptors(writeBootEnded(&buffer, 5), 1);
    defer with_descriptor.deinit();
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&with_descriptor));
}

test "a hello round-trips its key and the policy image's memfd and length" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const image = try policy_image.standard(std.testing.allocator);
    defer std.testing.allocator.free(image);
    var memfd = try policy_image.memfdHolding(image, os.fd.memfd_readonly_seals);
    defer memfd.deinit();
    try control.sendHello(control_pair[0], &test_key, memfd.fd(), @intCast(image.len));

    var scratch: [256]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer packet.deinit();
    try std.testing.expectEqual(control.hello_bytes, packet.bytes.len);
    const hello = switch (try control.decode(&packet)) {
        .hello => |hello| hello,
        else => return error.UnexpectedControlMessage,
    };
    var table_fd = hello.table_fd;
    defer table_fd.deinit();
    try std.testing.expectEqualSlices(u8, &test_key.bytes, &hello.key.bytes);
    try std.testing.expectEqual(@as(u32, @intCast(image.len)), hello.table_bytes);
    // The descriptor names the server's memfd itself, seals included, not a copy of its bytes.
    const sent = try std.posix.fstat(memfd.fd());
    const received = try std.posix.fstat(table_fd.fd());
    try std.testing.expectEqual(sent.dev, received.dev);
    try std.testing.expectEqual(sent.ino, received.ino);
    try os.fd.requireSeals(table_fd.fd(), os.fd.memfd_readonly_seals);
}

test "a hello without its one descriptor, with a zero key, or with an image length of 0 or past the largest image is refused" {
    const fixed = control.HelloHeader{ .key = test_key, .table_bytes = 64 };
    var buffer: [control.hello_bytes + 1]u8 = undefined;

    // The hello every case below breaks in one place decodes and hands its descriptor over, and
    // so does one that names the largest image.
    for ([_]u32{ fixed.table_bytes, @intCast(network.table.image_bytes_max) }) |table_bytes| {
        var sized = fixed;
        sized.table_bytes = table_bytes;
        var packet = try receivedWithDescriptors(writeHello(&buffer, sized), 1);
        defer packet.deinit();
        const hello = switch (try control.decode(&packet)) {
            .hello => |hello| hello,
            else => return error.UnexpectedControlMessage,
        };
        var table_fd = hello.table_fd;
        defer table_fd.deinit();
        try std.testing.expect(table_fd.isValid());
        try std.testing.expectEqual(table_bytes, hello.table_bytes);
    }

    // No descriptor, and two.
    for ([_]usize{ 0, 2 }) |descriptor_count| {
        var packet = try receivedWithDescriptors(writeHello(&buffer, fixed), descriptor_count);
        defer packet.deinit();
        try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&packet));
    }

    // A length other than the hello's: a byte short and a byte over.
    const whole = writeHello(&buffer, fixed);
    try expectHelloRefused(buffer[0 .. whole.len - 1]);
    buffer[whole.len] = 0;
    try expectHelloRefused(buffer[0 .. whole.len + 1]);

    {
        var broken = fixed;
        broken.key = .{ .bytes = @splat(0) };
        try expectHelloRefused(writeHello(&buffer, broken));
    }
    {
        var broken = fixed;
        broken._reserved0 = 1;
        try expectHelloRefused(writeHello(&buffer, broken));
    }
    {
        var broken = fixed;
        broken.table_bytes = 0;
        try expectHelloRefused(writeHello(&buffer, broken));
    }
    {
        var broken = fixed;
        broken.table_bytes = @intCast(network.table.image_bytes_max + 1);
        try expectHelloRefused(writeHello(&buffer, broken));
    }
}

test "the control kinds are numbered 1 to 7 in flow order and no other number decodes" {
    try std.testing.expectEqual(@as(usize, 7), std.meta.fields(control.Kind).len);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(control.Kind.gateway_ready));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(control.Kind.hello));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(control.Kind.attach_worker));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(control.Kind.attach_worker_ack));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(control.Kind.boot_ended));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(control.Kind.session_removed));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(control.Kind.shutdown));

    // 0 and every number past 7 name no kind. Each packet below is ack-sized and carries a
    // well-formed ack body, so only its kind is wrong.
    for ([_]u32{ 0, 8, 9, 10, 11, 12, std.math.maxInt(u32) }) |number| {
        var buffer: [@sizeOf(control.Header) + @sizeOf(control.AttachAck)]u8 = undefined;
        var to_gateway = receivedFrom(writeAck(&buffer, number));
        try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&to_gateway));
        var to_server = receivedFrom(writeAck(&buffer, number));
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&to_server),
        );
    }
}

test "the server takes nothing from the gateway but attach acks and removal reports without descriptors" {
    var buffer: [@sizeOf(control.Header) + @sizeOf(control.AttachAck)]u8 = undefined;
    const ack_kind = @intFromEnum(control.Kind.attach_worker_ack);
    {
        var packet = receivedFrom(writeAck(&buffer, ack_kind));
        const ack = try attachAckOf(try control.decodeGatewayToServerPacket(&packet));
        try std.testing.expectEqual(@as(u64, 1), ack.request_id);
    }
    {
        var packet = receivedFrom(writeSessionRemoved(&buffer, removal_report));
        switch (try control.decodeGatewayToServerPacket(&packet)) {
            .session_removed => |removed| {
                try std.testing.expectEqual(@as(u64, 9), removed.session_id);
                try std.testing.expectEqual(control.SessionRemovedCause.protocol_violation, removed.cause);
            },
            .attach_ack => return error.TestUnexpectedControlPacket,
        }
    }
    {
        // A report names a session and a cause the enum names, with its reserved word zero, so
        // each of these is refused, and so is a report of another length.
        var broken_reports = [_]control.SessionRemoved{ removal_report, removal_report, removal_report, removal_report };
        broken_reports[0].session_id = 0;
        broken_reports[1].cause = 0;
        broken_reports[2].cause = 3;
        broken_reports[3]._reserved0 = 1;
        for (broken_reports) |broken| {
            var refused = receivedFrom(writeSessionRemoved(&buffer, broken));
            try std.testing.expectError(
                error.InvalidEgressGatewayControl,
                control.decodeGatewayToServerPacket(&refused),
            );
        }
        const report = writeSessionRemoved(&buffer, removal_report);
        var short = receivedFrom(report[0 .. report.len - 1]);
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&short),
        );
        var ack_sized = receivedFrom(writeAck(&buffer, @intFromEnum(control.Kind.session_removed)));
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&ack_sized),
        );
        var with_descriptor = try receivedWithDescriptors(writeSessionRemoved(&buffer, removal_report), 1);
        defer with_descriptor.deinit();
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&with_descriptor),
        );
    }
    {
        var packet = try receivedWithDescriptors(writeAck(&buffer, ack_kind), 1);
        defer packet.deinit();
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&packet),
        );
    }
    {
        var packet = receivedFrom(buffer[0 .. @sizeOf(control.Header) - 1]);
        try std.testing.expectError(error.ShortRead, control.decodeGatewayToServerPacket(&packet));
    }

    // The ready report, which the spawn reads before any control reader runs, and the kinds only
    // the server sends, both as a bare header and with an ack's body.
    const others = [_]control.Kind{ .gateway_ready, .hello, .boot_ended, .attach_worker, .shutdown };
    for (others) |kind| {
        const number = @intFromEnum(kind);
        var with_body = receivedFrom(writeAck(&buffer, number));
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&with_body),
        );
        var bare = receivedFrom(writeHeader(&buffer, number));
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&bare),
        );
    }
}

test "the gateway refuses the packets only it sends and malformed headers" {
    var buffer: [@sizeOf(control.Header) + @sizeOf(control.AttachAck)]u8 = undefined;

    var ack = receivedFrom(writeAck(&buffer, @intFromEnum(control.Kind.attach_worker_ack)));
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&ack));
    var ready = receivedFrom(writeHeader(&buffer, @intFromEnum(control.Kind.gateway_ready)));
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&ready));
    var report = receivedFrom(writeSessionRemoved(&buffer, removal_report));
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&report));

    var short = receivedFrom(buffer[0 .. @sizeOf(control.Header) - 1]);
    try std.testing.expectError(error.ShortRead, control.decode(&short));
    const other_magic_header = control.Header{
        .magic = control.magic +% 1,
        .kind = @intFromEnum(control.Kind.shutdown),
    };
    var other_magic = receivedFrom(buffer[0..ipc.packet.writeStruct(&buffer, &other_magic_header)]);
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&other_magic));

    // A shutdown is a bare header with no descriptor.
    _ = writeHeader(&buffer, @intFromEnum(control.Kind.shutdown));
    buffer[@sizeOf(control.Header)] = 0;
    var with_body = receivedFrom(buffer[0 .. @sizeOf(control.Header) + 1]);
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&with_body));
    var with_descriptor = try receivedWithDescriptors(writeHeader(&buffer, @intFromEnum(control.Kind.shutdown)), 1);
    defer with_descriptor.deinit();
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&with_descriptor));
}

test "a shutdown carries no descriptor and decodes as shutdown" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    try control.sendShutdown(control_pair[0]);

    var scratch: [256]u8 = undefined;
    var received = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer received.deinit();
    try std.testing.expectEqual(@as(usize, 0), received.fd_count);
    try std.testing.expect((try control.decode(&received)) == .shutdown);
}

test "the gateway's ready report is a bare header the spawn's check accepts and nothing else" {
    var buffer: [@sizeOf(control.Header) + 1]u8 = undefined;
    try control.decodeGatewayReady(writeHeader(&buffer, @intFromEnum(control.Kind.gateway_ready)));
    const whole = writeHeader(&buffer, @intFromEnum(control.Kind.gateway_ready));
    buffer[whole.len] = 0;
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decodeGatewayReady(buffer[0 .. whole.len + 1]));
    try std.testing.expectError(
        error.InvalidEgressGatewayControl,
        control.decodeGatewayReady(writeHeader(&buffer, @intFromEnum(control.Kind.hello))),
    );
}

/// A key whose bytes all differ, so a key read shifted or truncated would not match.
fn keyFrom(seed: u8) egress_token.Key {
    var key: egress_token.Key = undefined;
    for (&key.bytes, 0..) |*byte, index|
        byte.* = seed +% @as(u8, @intCast(index * 7));
    return key;
}

/// A hello written field by field, so a test can break any of them.
fn writeHello(buffer: []u8, fixed: control.HelloHeader) []u8 {
    var cursor = writeHeader(buffer, @intFromEnum(control.Kind.hello)).len;
    cursor += ipc.packet.writeStruct(buffer[cursor..], &fixed);
    return buffer[0..cursor];
}

/// A `boot_ended` packet for `session_id` written field by field, so a test can name session 0.
fn writeBootEnded(buffer: []u8, session_id: u64) []u8 {
    var cursor = writeHeader(buffer, @intFromEnum(control.Kind.boot_ended)).len;
    const body = control.BootEnded{ .session_id = session_id };
    cursor += ipc.packet.writeStruct(buffer[cursor..], &body);
    return buffer[0..cursor];
}

/// A header of kind `kind_number` followed by a well-formed `ok` ack body.
fn writeAck(buffer: []u8, kind_number: u32) []u8 {
    var cursor = writeHeader(buffer, kind_number).len;
    const body = control.AttachAck{
        .status = @intFromEnum(control.AttachAckStatus.ok),
        .request_id = 1,
        .worker_session_id = 1,
    };
    cursor += ipc.packet.writeStruct(buffer[cursor..], &body);
    return buffer[0..cursor];
}

/// A well-formed removal report, which a test copies to break one field.
const removal_report: control.SessionRemoved = .{
    .session_id = 9,
    .cause = @intFromEnum(control.SessionRemovedCause.protocol_violation),
};

/// A removal report with `body` written as it is, so a test can name session 0 or a cause the
/// enum does not.
fn writeSessionRemoved(buffer: []u8, body: control.SessionRemoved) []u8 {
    var cursor = writeHeader(buffer, @intFromEnum(control.Kind.session_removed)).len;
    cursor += ipc.packet.writeStruct(buffer[cursor..], &body);
    return buffer[0..cursor];
}

fn writeHeader(buffer: []u8, kind_number: u32) []u8 {
    const header = control.Header{ .magic = control.magic, .kind = kind_number };
    return buffer[0..ipc.packet.writeStruct(buffer, &header)];
}

/// The attach ack a packet the server decoded must be.
fn attachAckOf(message: control.GatewayToServer) !control.AttachAck {
    return switch (message) {
        .attach_ack => |ack| ack,
        .session_removed => error.TestUnexpectedControlPacket,
    };
}

/// A packet as the receive path hands it to a decoder, without descriptors.
fn receivedFrom(bytes: []u8) ipc.ReceivedPacket {
    return .{
        .allocator = std.testing.allocator,
        .bytes = bytes,
        .owned_buffer = null,
        .fds = @splat(.{}),
        .fd_count = 0,
    };
}

/// `receivedFrom` with `count` descriptors, eventfds that the packet's `deinit` closes unless a
/// decoder took them.
fn receivedWithDescriptors(bytes: []u8, count: usize) !ipc.ReceivedPacket {
    var packet = receivedFrom(bytes);
    errdefer packet.deinit();
    for (0..count) |index| {
        packet.fds[index] = os.fd.OwnedFd.fromRaw(try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC));
        packet.fd_count = index + 1;
    }
    return packet;
}

fn expectRefused(bytes: []u8) !void {
    var packet = receivedFrom(bytes);
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&packet));
}

/// A hello is refused whatever it carries once it breaks a rule, so each case carries the one
/// descriptor a hello must.
fn expectHelloRefused(bytes: []u8) !void {
    var packet = try receivedWithDescriptors(bytes, 1);
    defer packet.deinit();
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&packet));
}
