//! The field contracts of `common/ipc/messages.zig` that other files carry:
//! the request done statuses through a request's `request_done` and the
//! value past the last, the fetch error's cause through its codec and the
//! causes and reserved bytes the decoder refuses, and the pooled upload bytes
//! a session may have in flight. WorkerInit's fields cross the init socket in
//! `zygote_worker.zig`, beside its descriptor table.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

test "the request done statuses 7 to 9 name the endings no request's own code chose, and fit a byte" {
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(ipc.RequestDoneStatus.cpu_exceeded));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(ipc.RequestDoneStatus.worker_retiring));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(ipc.RequestDoneStatus.worker_stopped));
    try std.testing.expectEqual(u8, @typeInfo(ipc.RequestDoneStatus).@"enum".tag_type);
}

test "each new done status crosses a request_done, and the value past the last is refused at both ends" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = 1,
        .request_generation = 1,
        .request_lane_id = 1,
        .request_slot = 1,
    };

    var scratch: [256]u8 = undefined;
    const statuses = [_]ipc.RequestDoneStatus{ .cpu_exceeded, .worker_retiring, .worker_stopped };
    for (statuses) |status| {
        const done = ipc.RequestDone{ .status = status, .http_status = 503 };
        try ipc.ingress_channel.sendRequestDone(pair[0], identity, 1, done, &scratch);
        var recv_scratch: [256]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
        var received = try ipc.ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet);
        defer received.deinit();
        const read = try ipc.ingress_channel.decodeRequestDone(received.payload);
        try std.testing.expectEqual(status, read.status);
        try std.testing.expectEqual(@as(u16, 503), read.http_status);
    }

    // A worker cannot build the value past the last, and the server's
    // decoder refuses a payload that carries it.
    var past = ipc.ingress_channel.encodeRequestDone(.{ .status = .worker_stopped, .http_status = 503 });
    past.status = @intFromEnum(ipc.RequestDoneStatus.worker_stopped) + 1;
    try std.testing.expectError(error.InvalidPacket, ipc.ingress_channel.decodeRequestDone(std.mem.asBytes(&past)));
}

test "a fetch error carries its cause through the codec, failed by default" {
    var scratch: [256]u8 = undefined;
    const failed = try ipc.decodeEgressFetchError(try ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 3,
        .body_id = 4,
        .message = "fetch failed: ConnectionRefused",
    }));
    try std.testing.expectEqual(ipc.EgressFetchErrorCause.failed, failed.cause);
    try std.testing.expectEqualStrings("fetch failed: ConnectionRefused", failed.message);

    const denied = try ipc.decodeEgressFetchError(try ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 5,
        .body_id = 6,
        .message = "fetch to https://a.test denied by the network setting",
        .cause = .network_denied,
        .ready_at_mono_ns = 8,
    }));
    try std.testing.expectEqual(ipc.EgressFetchErrorCause.network_denied, denied.cause);
    try std.testing.expectEqual(@as(u64, 5), denied.fetch_id);
    try std.testing.expectEqual(@as(u64, 8), denied.ready_at_mono_ns);
}

test "a fetch error message past its cap is refused by the encoder and the decoder alike" {
    const cap = ipc.fetch_limits.response_error_message_bytes_max;
    var scratch: [@sizeOf(ipc.EgressFetchErrorHeader) + cap + 1]u8 = undefined;
    const longest = [_]u8{'m'} ** cap;
    const at_cap = try ipc.decodeEgressFetchError(try ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 1,
        .body_id = 2,
        .message = &longest,
    }));
    try std.testing.expectEqual(cap, at_cap.message.len);

    const past = [_]u8{'m'} ** (cap + 1);
    try std.testing.expectError(error.InvalidEgressPacket, ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 1,
        .body_id = 2,
        .message = &past,
    }));
    // The same packet written by hand, as a broken gateway could.
    const header = ipc.EgressFetchErrorHeader{
        .kind = @intFromEnum(ipc.MessageKind.egress_fetch_error),
        .message_len = cap + 1,
        .fetch_id = 1,
        .body_id = 2,
    };
    @memcpy(scratch[0..@sizeOf(ipc.EgressFetchErrorHeader)], std.mem.asBytes(&header));
    @memcpy(scratch[@sizeOf(ipc.EgressFetchErrorHeader)..], &past);
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchError(&scratch));
}

test "the fetch error decoder refuses a cause it does not name and a nonzero reserved field" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ipc.EgressFetchErrorHeader));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(ipc.EgressFetchErrorHeader, "cause"));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(ipc.EgressFetchErrorCause.failed));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(ipc.EgressFetchErrorCause.network_denied));

    var scratch: [128]u8 = undefined;
    const encoded = try ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 1,
        .body_id = 2,
        .message = "x",
    });
    const cause_offset = @offsetOf(ipc.EgressFetchErrorHeader, "cause");
    const reserved_offset = @offsetOf(ipc.EgressFetchErrorHeader, "_reserved0");

    // The packet's structs cross as native-endian bytes.
    const native = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(u32, encoded[cause_offset..][0..4], 2, native);
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchError(encoded));
    std.mem.writeInt(u32, encoded[cause_offset..][0..4], std.math.maxInt(u32), native);
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchError(encoded));

    std.mem.writeInt(u32, encoded[cause_offset..][0..4], 1, native);
    const denied = try ipc.decodeEgressFetchError(encoded);
    try std.testing.expectEqual(ipc.EgressFetchErrorCause.network_denied, denied.cause);
    std.mem.writeInt(u32, encoded[reserved_offset..][0..4], 1, native);
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchError(encoded));
}

test "a session's pooled bytes in flight are twice the largest pooled body" {
    const fetch_limits = ipc.fetch_limits;
    try std.testing.expectEqual(
        2 * fetch_limits.request_body_pooled_bytes_max,
        fetch_limits.request_body_pooled_in_flight_bytes_max,
    );
}
