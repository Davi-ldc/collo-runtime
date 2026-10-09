//! The control wire between the server and the gateway (`egress/gateway/control.zig`): an attach
//! carries its session's descriptors and comes back as an attach ack, and a removal report names
//! a session, never 0, the two packets the gateway sends after its ready report; the hello carries
//! the token key and every policy entry in id
//! order; a `request_ended` batch fills to its bound and leaves as one packet; shutdown carries no
//! descriptor. Each decoder refuses a packet whose length, reserved bytes, counts, ids, flags or
//! descriptors break the wire's rules, a kind only the other side sends, and the numbers of
//! retired kinds. The order the gateway takes packets in, the hello first and once, is its control
//! flow's (`runtime/control_flow.zig`), and the attach ack's session rule and the server's control
//! client are covered in `server/tests/gateway/` (lane server-gateway-control-test). Lane:
//! egress-gateway-test.

const std = @import("std");
const os = @import("collo_os");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");

const control = gateway.control;
const policy = gateway.policy;
const egress_token = ipc.egress_token;

const test_key = keyFrom(0x21);

test "egress gateway control attach transfers shared endpoint fds" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var shared = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer shared.deinit();

    var scratch: [256]u8 = undefined;
    const security_cell_id: control.SecurityCellId = [_]u8{42} ** 16;
    try control.sendAttachWorker(
        control_pair[0],
        99,
        security_cell_id,
        shared.rawForGateway(),
    );

    var received = try ipc.recvPacketWithFdsScratch(
        std.testing.allocator,
        control_pair[1],
        &scratch,
    );
    defer received.deinit();

    const decoded = try control.decode(&received);
    switch (decoded) {
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

test "egress gateway control attach ack carries request id and session" {
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

test "a removal report carries the session it names and never session 0" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    try std.testing.expectError(error.InvalidEgressGatewayControl, control.sendSessionRemoved(control_pair[0], 0));
    try control.sendSessionRemoved(control_pair[0], 4242);

    var scratch: [256]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer packet.deinit();
    try std.testing.expectEqual(@sizeOf(control.Header) + @sizeOf(control.SessionRemoved), packet.bytes.len);
    switch (try control.decodeGatewayToServerPacket(&packet)) {
        .session_removed => |removed| try std.testing.expectEqual(@as(u64, 4242), removed.session_id),
        .attach_ack => return error.TestUnexpectedControlPacket,
    }
}

test "the hello carries the key and every policy entry in id order" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    // Each entry's flags differ from its neighbors', so an entry read at another index would not
    // match.
    var table: policy.PolicyTable = .{ .count = 3 };
    table.entries[0] = policy.public_https;
    table.entries[1] = .{ .kind = .any_host, .allow_private_networks = true, .allow_http = false };
    table.entries[2] = .{ .kind = .any_host, .allow_private_networks = false, .allow_http = true };
    try control.sendHello(control_pair[0], &test_key, &table);

    var scratch: [control.hello_bytes_max]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer packet.deinit();
    try std.testing.expectEqual(helloBytes(3), packet.bytes.len);
    const hello = switch (try control.decode(&packet)) {
        .hello => |hello| hello,
        else => return error.UnexpectedControlMessage,
    };
    try std.testing.expectEqualSlices(u8, &test_key.bytes, &hello.key.bytes);
    try expectTablesEqual(&table, &hello.table);
}

test "a hello with every entry a table holds fills the largest hello exactly" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var table: policy.PolicyTable = .{ .count = policy.policies_max };
    for (table.entries[0..policy.policies_max], 0..) |*entry, index| {
        entry.* = .{
            .kind = .any_host,
            .allow_private_networks = index % 2 == 1,
            .allow_http = index % 3 == 1,
        };
    }
    try control.sendHello(control_pair[0], &test_key, &table);

    var scratch: [control.hello_bytes_max]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer packet.deinit();
    try std.testing.expectEqual(control.hello_bytes_max, packet.bytes.len);
    const hello = switch (try control.decode(&packet)) {
        .hello => |hello| hello,
        else => return error.UnexpectedControlMessage,
    };
    try expectTablesEqual(&table, &hello.table);
}

test "a hello that breaks the wire's rules is refused" {
    const entries = [_]control.PolicyEntry{
        policyEntry(0, 0, 0),
        policyEntry(1, 1, 1),
    };
    const fixed = control.HelloHeader{ .key = test_key, .policy_count = entries.len };
    var buffer: [helloBytes(policy.policies_max + 1)]u8 = undefined;

    // The hello every case below breaks in one place decodes.
    {
        var packet = receivedFrom(writeHello(&buffer, fixed, &entries));
        const hello = switch (try control.decode(&packet)) {
            .hello => |hello| hello,
            else => return error.UnexpectedControlMessage,
        };
        try std.testing.expectEqual(@as(u16, entries.len), hello.table.count);
    }

    {
        var packet = try receivedWithDescriptor(writeHello(&buffer, fixed, &entries));
        defer packet.deinit();
        try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&packet));
    }

    // A length other than the count gives: a byte short, a byte over, and short of the fixed part.
    const whole = writeHello(&buffer, fixed, &entries);
    try expectRefused(buffer[0 .. whole.len - 1]);
    buffer[whole.len] = 0;
    try expectRefused(buffer[0 .. whole.len + 1]);
    try expectRefused(buffer[0 .. helloBytes(0) - 1]);

    {
        var broken = fixed;
        broken._reserved0 = 1;
        try expectRefused(writeHello(&buffer, broken, &entries));
    }
    {
        var broken = fixed;
        broken.key = .{ .bytes = @splat(0) };
        try expectRefused(writeHello(&buffer, broken, &entries));
    }
    {
        var broken = fixed;
        broken.policy_count = 0;
        try expectRefused(writeHello(&buffer, broken, &.{}));
    }
    {
        var many: [policy.policies_max + 1]control.PolicyEntry = undefined;
        for (&many, 0..) |*entry, index|
            entry.* = policyEntry(@intCast(index), 0, 0);
        var broken = fixed;
        broken.policy_count = many.len;
        try expectRefused(writeHello(&buffer, broken, &many));
    }

    // One entry broken at a time: an id other than its index, either way round, an unknown kind,
    // a flag other than 0 or 1, and a nonzero reserved byte.
    var first_id_one = entries;
    first_id_one[0].id = 1;
    try expectRefused(writeHello(&buffer, fixed, &first_id_one));
    var second_breaks: [6]control.PolicyEntry = @splat(entries[1]);
    second_breaks[0].id = 0;
    second_breaks[1].kind = 0;
    second_breaks[2].kind = control.policy_kind_any_host + 1;
    second_breaks[3].allow_private_networks = 2;
    second_breaks[4].allow_http = 0xff;
    second_breaks[5]._reserved0[2] = 1;
    for (second_breaks) |broken| {
        const pair = [_]control.PolicyEntry{ entries[0], broken };
        try expectRefused(writeHello(&buffer, fixed, &pair));
    }
}

test "a request_ended batch leaves as one packet that decodes to its entries" {
    const control_pair = try os.fd.socketPairType(
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
    );
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const batch = try std.testing.allocator.create(control.RequestEndedBatch);
    defer std.testing.allocator.destroy(batch);
    batch.* = .{};
    try std.testing.expect(batch.isEmpty());

    // Two requests of one session and a boot token, whose request id and generation are 0.
    const entries = [_]control.RequestEndedEntry{
        .{ .session_id = 7, .request_id = 41, .request_generation = 3 },
        .{ .session_id = 7, .request_id = 0, .request_generation = 0 },
        .{ .session_id = 9, .request_id = 41, .request_generation = 4 },
    };
    for (entries) |entry|
        try std.testing.expect(batch.append(entry));
    try std.testing.expect(!batch.isEmpty());
    try batch.sendAndClear(control_pair[0]);
    try std.testing.expect(batch.isEmpty());

    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer packet.deinit();
    try std.testing.expectEqual(requestEndedBytes(entries.len), packet.bytes.len);
    const ended = switch (try control.decode(&packet)) {
        .request_ended => |ended| ended,
        else => return error.UnexpectedControlMessage,
    };
    try std.testing.expectEqual(entries.len, ended.count);
    for (entries, 0..) |expected, index|
        try std.testing.expectEqual(expected, ended.entry(index));
    try std.testing.expectError(
        error.WouldBlock,
        ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch),
    );
}

test "a request_ended batch holds its bound of entries and empties when it sends, even if the send fails" {
    const control_pair = try os.fd.socketPairType(
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
    );
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const batch = try std.testing.allocator.create(control.RequestEndedBatch);
    defer std.testing.allocator.destroy(batch);
    batch.* = .{};

    for (0..control.request_ended_entries_max) |index|
        try std.testing.expect(batch.append(endedEntryAt(index)));
    // A full batch refuses the next entry and keeps what it holds, so the caller sends first.
    try std.testing.expect(!batch.append(endedEntryAt(control.request_ended_entries_max)));
    try std.testing.expectEqual(control.request_ended_entries_max, batch.count);
    try batch.sendAndClear(control_pair[0]);
    try std.testing.expect(batch.isEmpty());

    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    {
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
        defer packet.deinit();
        try std.testing.expectEqual(control.request_ended_bytes_max, packet.bytes.len);
        const ended = switch (try control.decode(&packet)) {
            .request_ended => |ended| ended,
            else => return error.UnexpectedControlMessage,
        };
        try std.testing.expectEqual(control.request_ended_entries_max, ended.count);
        try std.testing.expectEqual(endedEntryAt(0), ended.entry(0));
        const last = control.request_ended_entries_max - 1;
        try std.testing.expectEqual(endedEntryAt(last), ended.entry(last));
    }

    // A send the socket refuses empties the batch all the same: its entries are lost, which
    // costs their requests' fetches until the tokens' deadlines, and none is sent twice.
    const closed_pair = try os.fd.socketPairType(
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
    );
    defer std.posix.close(closed_pair[0]);
    std.posix.close(closed_pair[1]);
    try std.testing.expect(batch.append(endedEntryAt(0)));
    try std.testing.expectError(error.PeerClosed, batch.sendAndClear(closed_pair[0]));
    try std.testing.expect(batch.isEmpty());
}

test "clear drops a batch's entries without sending them" {
    const control_pair = try os.fd.socketPairType(
        std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
    );
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const batch = try std.testing.allocator.create(control.RequestEndedBatch);
    defer std.testing.allocator.destroy(batch);
    batch.* = .{};

    try std.testing.expect(batch.append(endedEntryAt(1)));
    try std.testing.expect(batch.append(endedEntryAt(2)));
    batch.clear();
    try std.testing.expect(batch.isEmpty());
    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    try std.testing.expectError(
        error.WouldBlock,
        ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch),
    );

    // Entries appended after the clear are the only ones the next send carries.
    try std.testing.expect(batch.append(endedEntryAt(3)));
    try batch.sendAndClear(control_pair[0]);
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer packet.deinit();
    const ended = switch (try control.decode(&packet)) {
        .request_ended => |ended| ended,
        else => return error.UnexpectedControlMessage,
    };
    try std.testing.expectEqual(@as(usize, 1), ended.count);
    try std.testing.expectEqual(endedEntryAt(3), ended.entry(0));
}

test "a request_ended packet that breaks the wire's rules is refused" {
    const entries = [_]control.RequestEndedEntry{
        .{ .session_id = 3, .request_id = 10, .request_generation = 1 },
        .{ .session_id = 3, .request_id = 0, .request_generation = 0 },
    };
    const fixed = control.RequestEndedHeader{ .count = entries.len };
    var buffer: [requestEndedBytes(control.request_ended_entries_max + 1)]u8 = undefined;

    // The packet every case below breaks in one place decodes.
    {
        var packet = receivedFrom(writeRequestEnded(&buffer, fixed, &entries));
        const ended = switch (try control.decode(&packet)) {
            .request_ended => |ended| ended,
            else => return error.UnexpectedControlMessage,
        };
        try std.testing.expectEqual(entries.len, ended.count);
    }

    {
        var packet = try receivedWithDescriptor(writeRequestEnded(&buffer, fixed, &entries));
        defer packet.deinit();
        try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&packet));
    }

    // A length other than the count gives: a byte short, a byte over, and short of the fixed part.
    const whole = writeRequestEnded(&buffer, fixed, &entries);
    try expectRefused(buffer[0 .. whole.len - 1]);
    buffer[whole.len] = 0;
    try expectRefused(buffer[0 .. whole.len + 1]);
    try expectRefused(buffer[0 .. requestEndedBytes(0) - 1]);

    {
        var broken = fixed;
        broken._reserved0 = 1;
        try expectRefused(writeRequestEnded(&buffer, broken, &entries));
    }
    {
        var broken = fixed;
        broken.count = 0;
        try expectRefused(writeRequestEnded(&buffer, broken, &.{}));
    }
    {
        var many: [control.request_ended_entries_max + 1]control.RequestEndedEntry = undefined;
        for (&many, 0..) |*entry, index|
            entry.* = endedEntryAt(index);
        var broken = fixed;
        broken.count = many.len;
        try expectRefused(writeRequestEnded(&buffer, broken, &many));
    }

    // One entry broken at a time: no session, and a request id and generation that are not both
    // zero, as a boot token's are, or both nonzero.
    var second_breaks: [3]control.RequestEndedEntry = @splat(entries[0]);
    second_breaks[0].session_id = 0;
    second_breaks[1].request_id = 0;
    second_breaks[2].request_generation = 0;
    for (second_breaks) |broken| {
        const pair = [_]control.RequestEndedEntry{ entries[1], broken };
        try expectRefused(writeRequestEnded(&buffer, fixed, &pair));
    }
}

test "the control kinds keep their numbers and retired numbers decode as nothing" {
    try std.testing.expectEqual(@as(usize, 7), std.meta.fields(control.Kind).len);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(control.Kind.attach_worker));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(control.Kind.shutdown));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(control.Kind.attach_worker_ack));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(control.Kind.gateway_ready));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(control.Kind.hello));
    try std.testing.expectEqual(@as(u32, 10), @intFromEnum(control.Kind.request_ended));
    try std.testing.expectEqual(@as(u32, 11), @intFromEnum(control.Kind.session_removed));

    // 3, 4, 6 and 8 are retired numbers, which `Kind` never assigns again, and 0 and 12 name no
    // kind. Each packet below is ack-sized and carries a well-formed ack body, so only its kind is
    // wrong.
    for ([_]u32{ 0, 3, 4, 6, 8, 12 }) |number| {
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
        var packet = receivedFrom(writeSessionRemoved(&buffer, 9));
        switch (try control.decodeGatewayToServerPacket(&packet)) {
            .session_removed => |removed| try std.testing.expectEqual(@as(u64, 9), removed.session_id),
            .attach_ack => return error.TestUnexpectedControlPacket,
        }
    }
    {
        // A report names a session, so 0 is refused, and so is a report of another length.
        var no_session = receivedFrom(writeSessionRemoved(&buffer, 0));
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&no_session),
        );
        const report = writeSessionRemoved(&buffer, 9);
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
        var with_descriptor = try receivedWithDescriptor(writeSessionRemoved(&buffer, 9));
        defer with_descriptor.deinit();
        try std.testing.expectError(
            error.InvalidEgressGatewayControl,
            control.decodeGatewayToServerPacket(&with_descriptor),
        );
    }
    {
        var packet = try receivedWithDescriptor(writeAck(&buffer, ack_kind));
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
    const others = [_]control.Kind{ .gateway_ready, .hello, .request_ended, .attach_worker, .shutdown };
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
    var report = receivedFrom(writeSessionRemoved(&buffer, 9));
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
    var with_descriptor = try receivedWithDescriptor(writeHeader(&buffer, @intFromEnum(control.Kind.shutdown)));
    defer with_descriptor.deinit();
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&with_descriptor));
}

test "egress gateway control shutdown carries no fds" {
    const control_pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    try control.sendShutdown(control_pair[0]);

    var scratch: [256]u8 = undefined;
    var received = try ipc.recvPacketWithFdsScratch(
        std.testing.allocator,
        control_pair[1],
        &scratch,
    );
    defer received.deinit();

    const decoded = try control.decode(&received);
    try std.testing.expect(decoded == .shutdown);
}

/// A key whose bytes all differ, so a key read shifted or truncated would not match.
fn keyFrom(seed: u8) egress_token.Key {
    var key: egress_token.Key = undefined;
    for (&key.bytes, 0..) |*byte, index|
        byte.* = seed +% @as(u8, @intCast(index * 7));
    return key;
}

fn expectTablesEqual(expected: *const policy.PolicyTable, actual: *const policy.PolicyTable) !void {
    try std.testing.expectEqual(expected.count, actual.count);
    for (expected.slice(), actual.slice()) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqual(want.allow_private_networks, got.allow_private_networks);
        try std.testing.expectEqual(want.allow_http, got.allow_http);
    }
}

fn helloBytes(entry_count: usize) usize {
    return @sizeOf(control.Header) + @sizeOf(control.HelloHeader) +
        entry_count * @sizeOf(control.PolicyEntry);
}

fn requestEndedBytes(entry_count: usize) usize {
    return @sizeOf(control.Header) + @sizeOf(control.RequestEndedHeader) +
        entry_count * @sizeOf(control.RequestEndedEntry);
}

fn policyEntry(id: u16, allow_private_networks: u8, allow_http: u8) control.PolicyEntry {
    return .{
        .id = id,
        .kind = control.policy_kind_any_host,
        .allow_private_networks = allow_private_networks,
        .allow_http = allow_http,
    };
}

/// Entry `index` of a run whose entries all differ, every one a request's.
fn endedEntryAt(index: usize) control.RequestEndedEntry {
    return .{
        .session_id = 100 + index,
        .request_id = 1 + index,
        .request_generation = 2 + index,
    };
}

/// A hello written field by field, so a test can break any of them.
fn writeHello(buffer: []u8, fixed: control.HelloHeader, entries: []const control.PolicyEntry) []u8 {
    var cursor = writeHeader(buffer, @intFromEnum(control.Kind.hello)).len;
    cursor += ipc.packet.writeStruct(buffer[cursor..], &fixed);
    for (entries) |*entry|
        cursor += ipc.packet.writeStruct(buffer[cursor..], entry);
    return buffer[0..cursor];
}

/// A `request_ended` packet written field by field, so a test can break any of them.
fn writeRequestEnded(
    buffer: []u8,
    fixed: control.RequestEndedHeader,
    entries: []const control.RequestEndedEntry,
) []u8 {
    var cursor = writeHeader(buffer, @intFromEnum(control.Kind.request_ended)).len;
    cursor += ipc.packet.writeStruct(buffer[cursor..], &fixed);
    for (entries) |*entry|
        cursor += ipc.packet.writeStruct(buffer[cursor..], entry);
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

/// A removal report for `session_id` written field by field, so a test can name session 0.
fn writeSessionRemoved(buffer: []u8, session_id: u64) []u8 {
    var cursor = writeHeader(buffer, @intFromEnum(control.Kind.session_removed)).len;
    const body = control.SessionRemoved{ .session_id = session_id };
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

/// `receivedFrom` with one descriptor, an eventfd that the packet's `deinit` closes.
fn receivedWithDescriptor(bytes: []u8) !ipc.ReceivedPacket {
    var packet = receivedFrom(bytes);
    packet.fds[0] = os.fd.OwnedFd.fromRaw(try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC));
    packet.fd_count = 1;
    return packet;
}

fn expectRefused(bytes: []u8) !void {
    var packet = receivedFrom(bytes);
    try std.testing.expectError(error.InvalidEgressGatewayControl, control.decode(&packet));
}
