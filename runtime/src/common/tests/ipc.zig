//! The IPC codecs in `common/ipc`: message kinds, the DispatchWork encoding
//! and its hostile-input bounds, the ingress channel and its shared payload
//! rings, the egress fetch messages and shared rings, the egress token's
//! place in DispatchWork and the fetch start, and packet framing. The fork
//! and WorkerInit handshakes, a request's `request_done`, the token itself,
//! the `egress_attach`, `worker_retiring` and `response_credit` packets with
//! the credit window, the definition artifact (`module_pack.zig`) with its
//! routes section and each route's bindings, the copy of a pool slot and the
//! field contracts of `messages.zig` have their own files under `ipc/`.
//! Everything runs over in-process socketpairs and memfds.

const std = @import("std");
const ipc = @import("collo_ipc");
const cmsg = @import("collo_os").cmsg;
const fd_mod = @import("collo_os").fd;

test {
    _ = @import("ipc/egress.zig");
    _ = @import("ipc/egress_attach.zig");
    _ = @import("ipc/egress_token.zig");
    _ = @import("ipc/messages.zig");
    _ = @import("ipc/module_pack.zig");
    _ = @import("ipc/request_done.zig");
    _ = @import("ipc/response_credit.zig");
    _ = @import("ipc/route_bindings.zig");
    _ = @import("ipc/route_table.zig");
    _ = @import("ipc/slot_snapshot.zig");
    _ = @import("ipc/worker_retiring.zig");
    _ = @import("ipc/zygote_worker.zig");
}

/// Decode scratch for the egress decoders (this binary's tests are
/// single-threaded, so one instance serves them all).
var worker_decode_scratch: ipc.WorkerEgressDecodeScratch = .{};
var gateway_decode_scratch: ipc.GatewayEgressDecodeScratch = .{};

const DispatchPacketHeader = ipc.DispatchPacketHeader;
const DispatchWork = ipc.DispatchWork;
const MessageKind = ipc.MessageKind;
const RequestHeader = ipc.RequestHeader;
const ReceivedPacket = ipc.ReceivedPacket;
const RouteCapture = ipc.RouteCapture;
const ZygoteReady = ipc.ZygoteReady;
const collectReceivedControlFds = ipc.collectReceivedControlFds;
const decodeDispatchWork = ipc.decodeDispatchWork;
const encodeDispatchWorkInto = ipc.encodeDispatchWorkInto;
const max_fds_per_message = ipc.max_fds_per_message;
const max_message_bytes = ipc.max_message_bytes;
const max_request_header_count = ipc.max_request_header_count;
const recvPacketWithFdsScratch = ipc.recvPacketWithFdsScratch;
const recvZygoteReady = ipc.recvZygoteReady;
const ingress_channel = ipc.ingress_channel;
const egress_token = ipc.egress_token;

/// The key the tests mint tokens under: fixed, so no test reads the system's
/// random source, and nonzero, since the zero key verifies nothing.
const token_key: egress_token.Key = .{ .bytes = @splat(0x5c) };

/// A request token's bytes, as a lane writes them into `DispatchWork`.
fn requestTokenBytes(request_id: u64, request_generation: u64) egress_token.Bytes {
    const token = egress_token.mint(&token_key, .{
        .kind = .request,
        .policy_id = 0,
        .session_id = 7,
        .request_id = request_id,
        .request_generation = request_generation,
        .deadline_monotonic_ns = 5_000_000_000,
    });
    return egress_token.asBytes(&token).*;
}

/// A boot token's bytes, as the host writes them into WorkerInit and an
/// evaluation's dispatch copies them.
fn bootTokenBytes() egress_token.Bytes {
    const token = egress_token.mint(&token_key, .{
        .kind = .boot,
        .policy_id = 0,
        .session_id = 7,
        .request_id = 0,
        .request_generation = 0,
        .deadline_monotonic_ns = 9_000_000_000,
    });
    return egress_token.asBytes(&token).*;
}

/// Fails naming `field` when it does not sit at `expected` in `T`, so a moved
/// field shows by name in the failure.
fn expectOffset(comptime T: type, comptime field: []const u8, expected: usize) !void {
    const actual = @offsetOf(T, field);
    if (actual == expected)
        return;
    std.debug.print("{s}.{s} is at offset {d}, pinned at {d}\n", .{
        @typeName(T),
        field,
        actual,
        expected,
    });
    return error.TestUnexpectedOffset;
}

/// A session on a wake set of its own. The session holds its own copy of
/// every wake descriptor, so the set closes once the session is built.
fn createEgressSession() !ipc.egress_shared.SessionFds {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    return ipc.egress_shared.createSessionForWorker(&wake_set);
}

/// A copy of `fds` that the caller owns, one new descriptor per field, so a
/// test can map a half while the session keeps its own. It names no field, so
/// it follows `RawFds` whatever descriptors a half holds.
fn dupEgressRawFds(fds: ipc.egress_shared.RawFds) !ipc.egress_shared.RawFds {
    var copy: ipc.egress_shared.RawFds = .{};
    errdefer copy.close();
    inline for (std.meta.fields(ipc.egress_shared.RawFds)) |field| {
        var owned = try fd_mod.OwnedFd.dupCloexec(@field(fds, field.name));
        @field(copy, field.name) = owned.release();
    }
    return copy;
}

fn fdHasHangup(raw_fd: std.posix.fd_t) !bool {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = raw_fd,
        .events = std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    _ = try std.posix.poll(&pollfds, 0);
    return (pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
}

fn createRouteMemfd(bytes: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        "test-route-entry",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);
    try writeAllFd(fd, bytes);
    try std.posix.lseek_SET(fd, 0);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    return fd;
}

test "route memfd helper seals module bytes read-only" {
    const route_fd = try createRouteMemfd("export default 1;");
    defer std.posix.close(route_fd);

    try fd_mod.requireSeals(route_fd, fd_mod.memfd_readonly_seals);
}

test "packet queue owns packets and enforces byte limits" {
    var queue = ipc.outbound_queue.PacketQueue{};
    defer queue.deinit(std.testing.allocator);

    try queue.pushWithLimit(std.testing.allocator, "abc", 2, 6);
    try queue.pushWithLimit(std.testing.allocator, "de", 2, 6);
    try std.testing.expectError(
        error.PacketQueueFull,
        queue.pushWithLimit(std.testing.allocator, "f", 2, 6),
    );
    try std.testing.expectEqual(@as(usize, 2), queue.count());
    try std.testing.expectEqual(@as(usize, 5), queue.bytes);
    try std.testing.expectEqualStrings("abc", queue.front().?);

    queue.popFront(std.testing.allocator);
    try std.testing.expectEqualStrings("de", queue.front().?);
    queue.popFront(std.testing.allocator);
    try std.testing.expect(!queue.hasPackets());
}

test "reserved packet queue admits control packets when normal budget is full" {
    var queue = ipc.outbound_queue.ReservedPacketQueue{};
    defer queue.deinit(std.testing.allocator);

    const limits = ipc.outbound_queue.PriorityLimits{
        .normal_packets = 1,
        .normal_bytes = 8,
        .high_packets = 2,
        .high_bytes = 16,
    };

    try queue.pushWithLimit(std.testing.allocator, "normal", .normal, limits);
    try std.testing.expectError(
        error.PacketQueueFull,
        queue.pushWithLimit(std.testing.allocator, "overflow", .normal, limits),
    );
    try queue.pushWithLimit(std.testing.allocator, "cancel", .high, limits);
    try queue.pushWithLimit(std.testing.allocator, "credit", .high, limits);
    try std.testing.expectEqual(@as(usize, 1), queue.normal_packets);
    try std.testing.expectEqual(@as(usize, 2), queue.high_packets);
    try std.testing.expectEqualStrings("normal", queue.front().?);
    queue.popFront(std.testing.allocator);
    try std.testing.expectEqualStrings("cancel", queue.front().?);
    queue.popFront(std.testing.allocator);
    try std.testing.expectEqualStrings("credit", queue.front().?);
}

test "ingress channel descriptors preserve stream identity and shared byte ranges" {
    const identity = ingress_channel.RequestIdentity{
        .request_id = 42,
        .request_generation = 7,
        .request_lane_id = 3,
        .request_slot = 9,
    };

    const begin = ingress_channel.Descriptor.requestBegin(identity, 1, 128, 64, 5, true);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.request_begin), begin.op);
    try std.testing.expect(begin.hasFlag(ingress_channel.flags.end_headers));
    try std.testing.expect(begin.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqual(@as(u32, 1), begin.stream_id);
    try std.testing.expectEqual(@as(u64, 128), begin.shared_offset);
    try std.testing.expectEqual(@as(u32, 64), begin.byte_len);
    try std.testing.expectEqual(@as(u32, 5), begin.aux);

    const chunk = ingress_channel.Descriptor.requestBodyChunk(identity, 1, 192, 16, false);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.request_body_chunk), chunk.op);
    try std.testing.expect(!chunk.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqual(@as(u64, 192), chunk.shared_offset);
    try std.testing.expectEqual(@as(u32, 16), chunk.byte_len);

    const head = ingress_channel.Descriptor.responseHead(identity, 1, 256, 40, 201, 2, false);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_head), head.op);
    try std.testing.expectEqual(@as(?u16, 201), head.responseStatus());
    try std.testing.expectEqual(@as(?u16, 2), head.responseHeaderCount());

    const end = ingress_channel.Descriptor.responseEnd(identity, 1);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_end), end.op);
    try std.testing.expect(end.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqual(@as(u32, 0), end.byte_len);
    try std.testing.expectEqual(@as(u64, 0), end.shared_offset);
}

test "ingress channel descriptor packets do not require fd transfer" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const identity = ingress_channel.RequestIdentity{
        .request_id = 77,
        .request_generation = 8,
        .request_lane_id = 2,
        .request_slot = 4,
    };
    const descriptor = ingress_channel.Descriptor.requestBodyChunk(identity, 11, 4096, 512, true);

    var scratch: [128]u8 = undefined;
    try ingress_channel.sendDescriptor(pair[0], descriptor, &scratch);

    var recv_scratch: [128]u8 = undefined;
    var received = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    defer received.deinit();
    try std.testing.expectEqual(@as(usize, 0), received.fd_count);

    const decoded = try ingress_channel.decodeDescriptor(received.bytes);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.request_body_chunk), decoded.op);
    try std.testing.expect(decoded.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqual(@as(u32, 11), decoded.stream_id);
    try std.testing.expectEqual(@as(u64, 4096), decoded.shared_offset);
    try std.testing.expectEqual(@as(u32, 512), decoded.byte_len);
    try std.testing.expectEqual(@as(u64, 77), decoded.request_id);
}

test "ingress channel packets carry inline stream payloads without request fd" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const identity = ingress_channel.RequestIdentity{
        .request_id = 88,
        .request_generation = 9,
        .request_lane_id = 5,
        .request_slot = 7,
    };
    const descriptor = ingress_channel.Descriptor.requestBodyChunk(identity, 13, 0, 5, true);

    var scratch: [128]u8 = undefined;
    try ingress_channel.sendDescriptorPayload(pair[0], descriptor, "hello", &scratch);

    var recv_scratch: [128]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    try std.testing.expectEqual(@as(usize, 0), packet.fd_count);
    var received = try ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet);
    defer received.deinit();

    try std.testing.expect(received.descriptor.hasFlag(ingress_channel.flags.inline_bytes));
    try std.testing.expect(received.descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqual(@as(u32, 5), received.descriptor.byte_len);
    try std.testing.expectEqualStrings("hello", received.payload);
}

test "ingress channel batch detection rejects short packets without panic" {
    const bytes = [_]u8{
        @intFromEnum(MessageKind.ingress_channel),
        0,
        0,
        0,
        0x31,
        0x42,
        0x32,
    };
    try std.testing.expect(!ingress_channel.isDescriptorBatchPacket(&bytes));
    try std.testing.expect(!ingress_channel.isDescriptorBatchPacket(""));
}

test "ingress channel encoders reject partially overlapping payload scratch" {
    const identity = ingress_channel.RequestIdentity{
        .request_id = 94,
        .request_generation = 15,
        .request_lane_id = 11,
        .request_slot = 13,
    };
    var scratch: [128]u8 = undefined;
    @memset(&scratch, 'x');
    const descriptor = ingress_channel.Descriptor.requestBodyChunk(identity, 33, 0, 8, true);

    try std.testing.expectError(
        error.InvalidPacket,
        ingress_channel.encodeDescriptorPayloadInto(&scratch, descriptor, scratch[1..9]),
    );

    const entry = ingress_channel.BatchEntry{
        .descriptor = ingress_channel.Descriptor.responseChunk(identity, 33, 0, 8, true),
        .payload = scratch[1..9],
    };
    try std.testing.expectError(
        error.InvalidPacket,
        ingress_channel.encodeDescriptorBatchPayloadsInto(&scratch, &.{entry}),
    );
}

test "ingress channel stream lifecycle uses bidirectional shared rings without client fd" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    try fd_mod.requireSeals(ring_fd, fd_mod.memfd_size_seals);
    var server_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer server_ring.deinit();
    var worker_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer worker_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 93,
        .request_generation = 14,
        .request_lane_id = 10,
        .request_slot = 12,
    };
    const headers = [_]RequestHeader{
        .{ .name = "host", .value = "demo.test" },
        .{ .name = "content-length", .value = "32785" },
    };
    var dispatch = try DispatchWork.initOwned(std.testing.allocator, .{
        .request_id = identity.request_id,
        .request_generation = identity.request_generation,
        .worker_id = 1,
        .worker_generation = 1,
        .request_lane_id = identity.request_lane_id,
        .request_slot = identity.request_slot,
        .worker_slot = 0,
        .authority = "demo.test",
        .deadline_monotonic_ns = 123,
        .method = "POST",
        .path = "/h2-lifecycle",
        .raw_query = "",
        .request_headers = &headers,
        .body_framing = .ingress_channel,
        .route_captures = &.{},
        .route_index = 0,
    });
    defer dispatch.deinit();

    var payload_scratch: [max_message_bytes]u8 = undefined;
    var scratch: [max_message_bytes]u8 = undefined;
    var view = dispatch.view();
    const dispatch_payload = try encodeDispatchWorkInto(&payload_scratch, &view);
    const begin = ingress_channel.Descriptor.requestBegin(
        identity,
        31,
        0,
        @intCast(dispatch_payload.len),
        @intCast(headers.len),
        false,
    );
    try ingress_channel.sendDescriptorPayload(pair[0], begin, dispatch_payload, &scratch);

    const request_body = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 17);
    defer std.testing.allocator.free(request_body);
    for (request_body, 0..) |*byte, index|
        byte.* = @intCast((index * 3) % 251);
    const body = ingress_channel.Descriptor.requestBodyChunk(identity, 31, 0, @intCast(request_body.len), true);
    try ingress_channel.sendDescriptorPayloadRequireRing(
        pair[0],
        body,
        request_body,
        &scratch,
        server_ring.writer(.server_to_worker),
    );

    var recv_scratch: [max_message_bytes]u8 = undefined;
    var begin_packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    try std.testing.expectEqual(@as(usize, 0), begin_packet.fd_count);
    var begin_received = try ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &begin_packet, .{
        .server_to_worker = &worker_ring,
    });
    defer begin_received.deinit();
    var decoded_dispatch = try ingress_channel.decodeDispatchPayload(std.testing.allocator, &begin_received);
    defer decoded_dispatch.deinit();
    try std.testing.expectEqual(@as(u64, 93), decoded_dispatch.request_id);
    try std.testing.expectEqualStrings("POST", decoded_dispatch.method);
    try std.testing.expectEqual(ipc.RequestBodyFraming.ingress_channel, decoded_dispatch.body_framing);

    var body_packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    var body_received = try ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &body_packet, .{
        .server_to_worker = &worker_ring,
    });
    defer body_received.deinit();
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.request_body_chunk), body_received.descriptor.op);
    try std.testing.expect(body_received.descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqualSlices(u8, request_body, body_received.payload);

    const response_headers = [_]ingress_channel.ResponseHeader{
        .{ .name = "content-type", .value = "text/plain" },
    };
    var response_head_scratch: [256]u8 = undefined;
    const response_head_payload = try ingress_channel.encodeResponseHeadInto(&response_head_scratch, 202, &response_headers);
    const response_head = ingress_channel.Descriptor.responseHead(
        identity,
        31,
        0,
        @intCast(response_head_payload.len),
        202,
        @intCast(response_headers.len),
        false,
    );
    try ingress_channel.sendDescriptorPayload(pair[1], response_head, response_head_payload, &scratch);

    const response_body = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 19);
    defer std.testing.allocator.free(response_body);
    @memset(response_body, 'r');
    const response_chunk = ingress_channel.Descriptor.responseChunk(identity, 31, 0, @intCast(response_body.len), true);
    try ingress_channel.sendDescriptorPayloadRequireRing(
        pair[1],
        response_chunk,
        response_body,
        &scratch,
        worker_ring.writer(.worker_to_server),
    );

    var response_head_packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[0], &recv_scratch);
    var response_head_received = try ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &response_head_packet, .{
        .worker_to_server = &server_ring,
    });
    defer response_head_received.deinit();
    var decoded_head = try ingress_channel.decodeResponseHead(std.testing.allocator, response_head_received.payload);
    defer decoded_head.deinit();
    try std.testing.expectEqual(@as(u16, 202), decoded_head.status);
    try std.testing.expectEqualStrings("text/plain", decoded_head.headers[0].value);

    var response_body_packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[0], &recv_scratch);
    var response_body_received = try ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &response_body_packet, .{
        .worker_to_server = &server_ring,
    });
    defer response_body_received.deinit();
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_chunk), response_body_received.descriptor.op);
    try std.testing.expect(response_body_received.descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqualSlices(u8, response_body, response_body_received.payload);
}

test "ingress channel batches multiple inline descriptors in one packet" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const identity = ingress_channel.RequestIdentity{
        .request_id = 92,
        .request_generation = 13,
        .request_lane_id = 9,
        .request_slot = 11,
    };
    const headers = [_]ingress_channel.ResponseHeader{
        .{ .name = "content-type", .value = "text/plain" },
    };
    var head_payload_scratch: [128]u8 = undefined;
    const head_payload = try ingress_channel.encodeResponseHeadInto(&head_payload_scratch, 204, &headers);
    const head = ingress_channel.Descriptor.responseHead(identity, 21, 0, @intCast(head_payload.len), 204, @intCast(headers.len), false);
    const chunk = ingress_channel.Descriptor.responseChunk(identity, 21, 0, 5, true);
    const entries = [_]ingress_channel.BatchEntry{
        .{ .descriptor = head, .payload = head_payload },
        .{ .descriptor = chunk, .payload = "hello" },
    };

    var scratch: [512]u8 = undefined;
    try ingress_channel.sendDescriptorBatchPayloads(pair[0], &entries, &scratch);

    var recv_scratch: [512]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    try std.testing.expectEqual(@as(usize, 0), packet.fd_count);
    try std.testing.expect(ingress_channel.isDescriptorBatchPacket(packet.bytes));
    var batch = try ingress_channel.decodeReceivedBatchPacket(std.testing.allocator, &packet);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_head), batch.items[0].descriptor.op);
    try std.testing.expect(batch.items[0].descriptor.hasFlag(ingress_channel.flags.inline_bytes));
    var decoded_head = try ingress_channel.decodeResponseHead(std.testing.allocator, batch.items[0].payload);
    defer decoded_head.deinit();
    try std.testing.expectEqual(@as(u16, 204), decoded_head.status);
    try std.testing.expectEqualStrings("content-type", decoded_head.headers[0].name);
    try std.testing.expectEqualStrings("text/plain", decoded_head.headers[0].value);

    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_chunk), batch.items[1].descriptor.op);
    try std.testing.expect(batch.items[1].descriptor.hasFlag(ingress_channel.flags.inline_bytes));
    try std.testing.expect(batch.items[1].descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqualStrings("hello", batch.items[1].payload);
}

test "ingress channel large payloads require shared ring storage" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const identity = ingress_channel.RequestIdentity{
        .request_id = 89,
        .request_generation = 10,
        .request_lane_id = 6,
        .request_slot = 8,
    };
    const payload = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 17);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index|
        byte.* = @intCast(index % 251);

    const descriptor = ingress_channel.Descriptor.responseChunk(identity, 15, 0, @intCast(payload.len), true);

    var scratch: [128]u8 = undefined;
    try std.testing.expectError(
        error.IngressSharedPayloadUnavailable,
        ingress_channel.sendDescriptorPayloadMaybeShared(pair[0], descriptor, payload, &scratch),
    );
}

test "ingress channel rejects fd-backed payload descriptors" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const payload_fd = try createRouteMemfd("tiny");
    defer std.posix.close(payload_fd);

    const identity = ingress_channel.RequestIdentity{
        .request_id = 89,
        .request_generation = 10,
        .request_lane_id = 6,
        .request_slot = 8,
    };
    const descriptor = ingress_channel.Descriptor.responseChunk(
        identity,
        15,
        0,
        4,
        true,
    );

    var scratch: [128]u8 = undefined;
    const encoded = try ingress_channel.encodeDescriptorInto(&scratch, descriptor);
    try ipc.packet.sendWithFds(pair[0], encoded, &.{payload_fd});

    var recv_scratch: [128]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    try std.testing.expectEqual(@as(usize, 1), packet.fd_count);
    try std.testing.expectError(
        error.InvalidPacket,
        ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet),
    );
}

test "ingress channel large payloads use pre-mapped shared ring when available" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer sender_ring.deinit();
    var receiver_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer receiver_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 90,
        .request_generation = 11,
        .request_lane_id = 7,
        .request_slot = 9,
    };
    const payload = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 31);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index|
        byte.* = @intCast((index * 7) % 251);

    const descriptor = ingress_channel.Descriptor.responseChunk(identity, 17, 0, @intCast(payload.len), true);

    var scratch: [128]u8 = undefined;
    try ingress_channel.sendDescriptorPayloadMaybeSharedWithRing(
        pair[0],
        descriptor,
        payload,
        &scratch,
        sender_ring.writer(.worker_to_server),
    );

    var recv_scratch: [128]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    try std.testing.expectEqual(@as(usize, 0), packet.fd_count);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var received = try ingress_channel.decodeReceivedPacketWithSharedPayload(failing.allocator(), &packet, .{
        .worker_to_server = &receiver_ring,
    });

    try std.testing.expect(received.descriptor.hasFlag(ingress_channel.flags.inline_bytes));
    try std.testing.expect(!received.descriptor.hasFlag(ingress_channel.flags.shared_ring));
    try std.testing.expect(received.descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expect(!received.payload_owned);
    try std.testing.expectEqual(@as(u32, 17), received.descriptor.stream_id);
    try std.testing.expectEqualSlices(u8, payload, received.payload);

    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity - payload.len,
        try receiver_ring.availableCapacity(.worker_to_server),
    );
    received.deinit();
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity,
        try receiver_ring.availableCapacity(.worker_to_server),
    );
}

test "ingress channel batches shared ring descriptors without memfd fallback" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer sender_ring.deinit();
    var receiver_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer receiver_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 93,
        .request_generation = 14,
        .request_lane_id = 10,
        .request_slot = 12,
    };
    const first_payload = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 11);
    defer std.testing.allocator.free(first_payload);
    const second_payload = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 19);
    defer std.testing.allocator.free(second_payload);
    @memset(first_payload, 0x31);
    @memset(second_payload, 0x42);

    const entries = [_]ingress_channel.BatchEntry{
        .{
            .descriptor = ingress_channel.Descriptor.responseChunk(identity, 23, 0, @intCast(first_payload.len), false),
            .payload = first_payload,
        },
        .{
            .descriptor = ingress_channel.Descriptor.responseChunk(identity, 23, 0, @intCast(second_payload.len), true),
            .payload = second_payload,
        },
    };

    var scratch: [512]u8 = undefined;
    try ingress_channel.sendDescriptorBatchRingPayloads(pair[0], &entries, &scratch, sender_ring.writer(.worker_to_server));

    var recv_scratch: [512]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    try std.testing.expectEqual(@as(usize, 0), packet.fd_count);
    try std.testing.expect(ingress_channel.isDescriptorBatchPacket(packet.bytes));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var batch = try ingress_channel.decodeReceivedBatchPacketWithSharedPayload(failing.allocator(), &packet, .{
        .worker_to_server = &receiver_ring,
    });

    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expect(batch.items[0].descriptor.hasFlag(ingress_channel.flags.inline_bytes));
    try std.testing.expect(!batch.items[0].descriptor.hasFlag(ingress_channel.flags.shared_ring));
    try std.testing.expect(!batch.items[0].descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expect(!batch.items[0].payload_owned);
    try std.testing.expectEqualSlices(u8, first_payload, batch.items[0].payload);
    try std.testing.expect(batch.items[1].descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expect(!batch.items[1].payload_owned);
    try std.testing.expectEqualSlices(u8, second_payload, batch.items[1].payload);

    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity - first_payload.len - second_payload.len,
        try receiver_ring.availableCapacity(.worker_to_server),
    );
    batch.deinit();
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity,
        try receiver_ring.availableCapacity(.worker_to_server),
    );
}

test "ingress channel borrowed shared ring payload is released only on received deinit" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer sender_ring.deinit();
    var receiver_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer receiver_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 195,
        .request_generation = 16,
        .request_lane_id = 12,
        .request_slot = 14,
    };
    const payload = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_ring_capacity);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);

    var scratch: [128]u8 = undefined;
    try ingress_channel.sendDescriptorPayloadRequireRing(
        pair[0],
        ingress_channel.Descriptor.responseChunk(identity, 27, 0, @intCast(payload.len), false),
        payload,
        &scratch,
        sender_ring.writer(.worker_to_server),
    );

    var recv_scratch: [128]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    var received = try ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &packet, .{
        .worker_to_server = &receiver_ring,
    });
    try std.testing.expect(!received.payload_owned);
    try std.testing.expectEqual(@as(usize, 0), try sender_ring.availableCapacity(.worker_to_server));

    const second_payload = payload[0 .. ingress_channel.shared_payload_threshold + 1];
    try std.testing.expectError(
        error.IngressSharedPayloadRingFull,
        ingress_channel.sendDescriptorPayloadRequireRing(
            pair[0],
            ingress_channel.Descriptor.responseChunk(identity, 27, 0, @intCast(second_payload.len), true),
            second_payload,
            &scratch,
            sender_ring.writer(.worker_to_server),
        ),
    );

    received.deinit();
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity,
        try sender_ring.availableCapacity(.worker_to_server),
    );
}

test "ingress channel shared ring reserves padding instead of wrapping payload" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer sender_ring.deinit();
    var receiver_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer receiver_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 197,
        .request_generation = 18,
        .request_lane_id = 14,
        .request_slot = 16,
    };
    const tail_padding_len: usize = 8 * 1024;
    const filler_len = ingress_channel.shared_payload_ring_capacity - tail_padding_len;
    const filler = try std.testing.allocator.alloc(u8, filler_len);
    defer std.testing.allocator.free(filler);
    @memset(filler, 0x17);

    var scratch: [128]u8 = undefined;
    try ingress_channel.sendDescriptorPayloadRequireRing(
        pair[0],
        ingress_channel.Descriptor.responseChunk(identity, 31, 0, @intCast(filler.len), false),
        filler,
        &scratch,
        sender_ring.writer(.worker_to_server),
    );

    var recv_scratch: [128]u8 = undefined;
    var filler_packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    var filler_received = try ingress_channel.decodeReceivedPacketWithSharedPayload(
        std.testing.allocator,
        &filler_packet,
        .{ .worker_to_server = &receiver_ring },
    );
    try std.testing.expect(!filler_received.payload_owned);
    try std.testing.expectEqual(
        tail_padding_len,
        try sender_ring.availableCapacity(.worker_to_server),
    );
    filler_received.deinit();
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity,
        try sender_ring.availableCapacity(.worker_to_server),
    );

    const body = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 113);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*byte, index|
        byte.* = @intCast((index * 11) % 251);

    try ingress_channel.sendDescriptorPayloadRequireRing(
        pair[0],
        ingress_channel.Descriptor.responseChunk(identity, 31, 0, @intCast(body.len), true),
        body,
        &scratch,
        sender_ring.writer(.worker_to_server),
    );
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity - tail_padding_len - body.len,
        try sender_ring.availableCapacity(.worker_to_server),
    );

    var body_packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    var body_received = try ingress_channel.decodeReceivedPacketWithSharedPayload(
        std.testing.allocator,
        &body_packet,
        .{ .worker_to_server = &receiver_ring },
    );
    try std.testing.expect(!body_received.payload_owned);
    try std.testing.expect(body_received.descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expectEqualSlices(u8, body, body_received.payload);
    body_received.deinit();
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity,
        try sender_ring.availableCapacity(.worker_to_server),
    );
}

test "ingress channel shared ring refuses writes that would need unavailable padding" {
    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var writer_view = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer writer_view.deinit();
    var reader_view = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer reader_view.deinit();

    const direction: ingress_channel.SharedPayloadDirection = .worker_to_server;
    const payload = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 1);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x52);

    // The writer stops `tail_padding_len` short of the ring's end and the
    // reader frees all but `payload.len` bytes, so the payload would have to
    // skip the tail and needs more than is free.
    const tail_padding_len: usize = 8 * 1024;
    const free_len = payload.len;
    const write_cursor = ingress_channel.shared_payload_ring_capacity - tail_padding_len;
    const used_len = ingress_channel.shared_payload_ring_capacity - free_len;
    const read_cursor = write_cursor - used_len;
    const filler = try std.testing.allocator.alloc(u8, write_cursor);
    defer std.testing.allocator.free(filler);
    @memset(filler, 0x17);
    _ = try writer_view.write(direction, filler);
    var release: ingress_channel.SharedPayloadReadRelease = .{
        .view = &reader_view,
        .direction = direction,
        .byte_len = read_cursor,
    };
    release.release();

    const ring = &writer_view.header.rings[@intFromEnum(direction)];
    try std.testing.expectEqual(free_len, try writer_view.availableCapacity(direction));
    try std.testing.expectError(
        error.IngressSharedPayloadRingFull,
        writer_view.write(direction, payload),
    );
    try std.testing.expectEqual(@as(u64, write_cursor), ring.write_cursor);
    try std.testing.expectEqual(@as(u64, read_cursor), ring.read_cursor);
}

test "ingress channel batch rollback cancels padded shared ring reservation" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer sender_ring.deinit();
    var receiver_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer receiver_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 198,
        .request_generation = 19,
        .request_lane_id = 15,
        .request_slot = 17,
    };
    const tail_padding_len: usize = 8 * 1024;
    const filler_len = ingress_channel.shared_payload_ring_capacity - tail_padding_len;
    const filler = try std.testing.allocator.alloc(u8, filler_len);
    defer std.testing.allocator.free(filler);
    @memset(filler, 0x33);

    var scratch: [512]u8 = undefined;
    try ingress_channel.sendDescriptorPayloadRequireRing(
        pair[0],
        ingress_channel.Descriptor.responseChunk(identity, 33, 0, @intCast(filler.len), false),
        filler,
        &scratch,
        sender_ring.writer(.worker_to_server),
    );
    var recv_scratch: [128]u8 = undefined;
    var filler_packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    var filler_received = try ingress_channel.decodeReceivedPacketWithSharedPayload(
        std.testing.allocator,
        &filler_packet,
        .{ .worker_to_server = &receiver_ring },
    );
    filler_received.deinit();

    const body = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 89);
    defer std.testing.allocator.free(body);
    @memset(body, 0x61);
    const entries = [_]ingress_channel.BatchEntry{
        .{
            .descriptor = ingress_channel.Descriptor.responseChunk(identity, 33, 0, @intCast(body.len), true),
            .payload = body,
        },
    };

    try std.testing.expectError(
        error.InvalidHandle,
        ingress_channel.sendDescriptorBatchRingPayloads(
            -1,
            &entries,
            &scratch,
            sender_ring.writer(.worker_to_server),
        ),
    );
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity,
        try sender_ring.availableCapacity(.worker_to_server),
    );
    const ring = sender_ring.header.rings[@intFromEnum(ingress_channel.SharedPayloadDirection.worker_to_server)];
    try std.testing.expectEqual(@as(u64, @intCast(filler_len)), ring.read_cursor);
    try std.testing.expectEqual(@as(u64, @intCast(filler_len)), ring.write_cursor);
}

test "ingress channel batch decode releases borrowed ring bytes on later allocation failure" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer sender_ring.deinit();
    var receiver_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer receiver_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 196,
        .request_generation = 17,
        .request_lane_id = 13,
        .request_slot = 15,
    };
    const body = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 64);
    defer std.testing.allocator.free(body);
    @memset(body, 0x6b);

    const headers = [_]ingress_channel.ResponseHeader{
        .{ .name = "x-mode", .value = "h2" },
    };
    var head_payload_storage: [256]u8 = undefined;
    const head_payload = try ingress_channel.encodeResponseHeadInto(&head_payload_storage, 200, &headers);
    const entries = [_]ingress_channel.BatchEntry{
        .{
            .descriptor = ingress_channel.Descriptor.responseChunk(identity, 29, 0, @intCast(body.len), false),
            .payload = body,
        },
        .{
            .descriptor = ingress_channel.Descriptor.responseHead(identity, 29, 0, @intCast(head_payload.len), 200, @intCast(headers.len), true),
            .payload = head_payload,
        },
    };

    var scratch: [512]u8 = undefined;
    try ingress_channel.sendDescriptorBatchPayloadsWithRing(pair[0], &entries, &scratch, sender_ring.writer(.worker_to_server));
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity - body.len,
        try sender_ring.availableCapacity(.worker_to_server),
    );

    var recv_scratch: [512]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(
        error.OutOfMemory,
        ingress_channel.decodeReceivedBatchPacketWithSharedPayload(failing.allocator(), &packet, .{
            .worker_to_server = &receiver_ring,
        }),
    );
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity,
        try sender_ring.availableCapacity(.worker_to_server),
    );
}

test "ingress channel batches inline response head with shared ring body" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer sender_ring.deinit();
    var receiver_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer receiver_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 94,
        .request_generation = 15,
        .request_lane_id = 11,
        .request_slot = 13,
    };
    const headers = [_]ingress_channel.ResponseHeader{
        .{ .name = "x-mode", .value = "h2" },
    };
    var head_payload_storage: [256]u8 = undefined;
    const head_payload = try ingress_channel.encodeResponseHeadInto(&head_payload_storage, 200, &headers);
    const body = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 23);
    defer std.testing.allocator.free(body);
    @memset(body, 'z');

    const entries = [_]ingress_channel.BatchEntry{
        .{
            .descriptor = ingress_channel.Descriptor.responseHead(identity, 25, 0, @intCast(head_payload.len), 200, @intCast(headers.len), false),
            .payload = head_payload,
        },
        .{
            .descriptor = ingress_channel.Descriptor.responseChunk(identity, 25, 0, @intCast(body.len), true),
            .payload = body,
        },
    };

    var scratch: [512]u8 = undefined;
    try ingress_channel.sendDescriptorBatchPayloadsWithRing(pair[0], &entries, &scratch, sender_ring.writer(.worker_to_server));

    var recv_scratch: [512]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    try std.testing.expectEqual(@as(usize, 0), packet.fd_count);
    try std.testing.expect(ingress_channel.isDescriptorBatchPacket(packet.bytes));
    var batch = try ingress_channel.decodeReceivedBatchPacketWithSharedPayload(std.testing.allocator, &packet, .{
        .worker_to_server = &receiver_ring,
    });
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_head), batch.items[0].descriptor.op);
    try std.testing.expect(batch.items[0].descriptor.hasFlag(ingress_channel.flags.inline_bytes));
    var decoded_head = try ingress_channel.decodeResponseHead(std.testing.allocator, batch.items[0].payload);
    defer decoded_head.deinit();
    try std.testing.expectEqual(@as(u16, 200), decoded_head.status);
    try std.testing.expectEqualStrings("x-mode", decoded_head.headers[0].name);
    try std.testing.expectEqualStrings("h2", decoded_head.headers[0].value);

    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_chunk), batch.items[1].descriptor.op);
    try std.testing.expect(batch.items[1].descriptor.hasFlag(ingress_channel.flags.end_stream));
    try std.testing.expect(!batch.items[1].payload_owned);
    try std.testing.expectEqualSlices(u8, body, batch.items[1].payload);
}

test "ingress channel mixed ring batch spills small chunks when inline budget is full" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer sender_ring.deinit();
    var receiver_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer receiver_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 95,
        .request_generation = 16,
        .request_lane_id = 12,
        .request_slot = 14,
    };
    const first_payload = "inline-body";
    const second_payload = "ring-body";
    const entries = [_]ingress_channel.BatchEntry{
        .{
            .descriptor = ingress_channel.Descriptor.requestBodyChunk(identity, 27, 0, @intCast(first_payload.len), false),
            .payload = first_payload,
        },
        .{
            .descriptor = ingress_channel.Descriptor.requestBodyChunk(identity, 27, 0, @intCast(second_payload.len), true),
            .payload = second_payload,
        },
    };

    const scratch_len = try std.math.add(usize, try ingress_channel.batchPayloadOffset(entries.len), first_payload.len);
    const scratch = try std.testing.allocator.alloc(u8, scratch_len);
    defer std.testing.allocator.free(scratch);
    try ingress_channel.sendDescriptorBatchPayloadsWithRing(pair[0], &entries, scratch, sender_ring.writer(.server_to_worker));

    var recv_scratch: [512]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    try std.testing.expect(ingress_channel.isDescriptorBatchPacket(packet.bytes));
    var batch = try ingress_channel.decodeReceivedBatchPacketWithSharedPayload(std.testing.allocator, &packet, .{
        .server_to_worker = &receiver_ring,
    });
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqualSlices(u8, first_payload, batch.items[0].payload);
    try std.testing.expect(batch.items[0].payload_owned);
    try std.testing.expectEqualSlices(u8, second_payload, batch.items[1].payload);
    try std.testing.expect(!batch.items[1].payload_owned);
    try std.testing.expect(batch.items[1].descriptor.hasFlag(ingress_channel.flags.end_stream));
}

test "ingress channel required ring reports backpressure instead of falling back to memfd" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var sender_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer sender_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 91,
        .request_generation = 12,
        .request_lane_id = 8,
        .request_slot = 10,
    };
    const payload = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_ring_capacity);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0xa5);
    const descriptor = ingress_channel.Descriptor.responseChunk(identity, 19, 0, @intCast(payload.len), false);

    var scratch: [128]u8 = undefined;
    try ingress_channel.sendDescriptorPayloadRequireRing(
        pair[0],
        descriptor,
        payload,
        &scratch,
        sender_ring.writer(.worker_to_server),
    );
    try std.testing.expectEqual(@as(usize, 0), try sender_ring.availableCapacity(.worker_to_server));

    const second_payload = payload[0 .. ingress_channel.shared_payload_threshold + 1];
    try std.testing.expectError(
        error.IngressSharedPayloadRingFull,
        ingress_channel.sendDescriptorPayloadRequireRing(
            pair[0],
            descriptor,
            second_payload,
            &scratch,
            sender_ring.writer(.worker_to_server),
        ),
    );
}

/// A payload of `len` bytes starting at ring position `start`, with no
/// skipped tail.
fn spanAt(start: u64, len: u32) ingress_channel.SharedPayloadSpan {
    return .{
        .offset = start % ingress_channel.shared_payload_ring_capacity,
        .len = len,
        .reserved_len = len,
        .end_cursor = start + len,
    };
}

test "held ring payloads leave the ring in ring order whatever order their answers come in" {
    var holds: ingress_channel.SharedPayloadHolds = .{};
    const first = spanAt(0, 40_000);
    const passed = spanAt(40_000, 50_000);
    const second = spanAt(90_000, 60_000);

    try std.testing.expect(holds.hold(first));
    // Consumed at once, but it sits behind a held payload, so it waits too.
    try std.testing.expectEqual(@as(u64, 0), holds.pass(passed));
    try std.testing.expect(holds.hold(second));
    try std.testing.expectEqual(@as(?u64, 150_000), holds.cursor());

    // The newer answer frees nothing while the older payload waits.
    try std.testing.expectEqual(@as(?u64, 0), holds.answer(second.offset, second.len));
    try std.testing.expect(!holds.isEmpty());
    try std.testing.expectEqual(@as(?u64, 150_000), holds.answer(first.offset, first.len));
    try std.testing.expect(holds.isEmpty());
    // The cursor stays at the end of what was decoded.
    try std.testing.expectEqual(@as(?u64, 150_000), holds.cursor());
    try std.testing.expectEqual(@as(u64, 70_000), holds.pass(spanAt(150_000, 70_000)));
}

test "an answer that matches no held payload releases nothing and changes nothing" {
    var holds: ingress_channel.SharedPayloadHolds = .{};
    const held = spanAt(0, 40_000);
    try std.testing.expect(holds.hold(held));
    try std.testing.expectEqual(@as(?u64, null), holds.answer(held.offset + 1, held.len));
    try std.testing.expectEqual(@as(?u64, null), holds.answer(held.offset, held.len + 1));
    try std.testing.expectEqual(@as(?u64, 40_000), holds.answer(held.offset, held.len));
    try std.testing.expectEqual(@as(?u64, null), holds.answer(held.offset, held.len));
}

test "a reader holds at most capacity payloads, and clear forgets them without releasing" {
    const Holds = ingress_channel.SharedPayloadHolds;
    var holds: Holds = .{};
    const len: u32 = ingress_channel.shared_payload_threshold + 1;
    var start: u64 = 0;
    var held: usize = 0;
    while (held < Holds.capacity) : (held += 1) {
        try std.testing.expect(holds.hold(spanAt(start, len)));
        start += len;
    }
    try std.testing.expect(!holds.hold(spanAt(start, len)));
    try std.testing.expectEqual(@as(?u64, start), holds.cursor());
    holds.clear();
    try std.testing.expect(holds.isEmpty());
    try std.testing.expectEqual(@as(?u64, null), holds.cursor());
}

test "a reader that keeps an account decodes past held ring payloads and frees ring bytes only as answers come" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var worker_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer worker_ring.deinit();
    var server_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer server_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 7,
        .request_generation = 3,
        .request_lane_id = 1,
        .request_slot = 5,
    };
    const lens = [_]u32{
        ingress_channel.shared_payload_threshold + 11,
        ingress_channel.shared_payload_threshold + 23,
        ingress_channel.shared_payload_threshold + 37,
    };
    var payloads: [lens.len][]u8 = undefined;
    for (&payloads, lens, 0..) |*payload, len, index| {
        payload.* = try std.testing.allocator.alloc(u8, len);
        @memset(payload.*, @intCast(0x40 + index));
    }
    defer for (payloads) |payload| std.testing.allocator.free(payload);

    var send_scratch: [512]u8 = undefined;
    for (payloads) |payload| {
        const descriptor = ingress_channel.Descriptor.responseChunk(identity, 9, 0, @intCast(payload.len), false);
        try ingress_channel.sendDescriptorPayloadRequireRing(pair[0], descriptor, payload, &send_scratch, worker_ring.writer(.worker_to_server));
    }
    const total: usize = lens[0] + lens[1] + lens[2];

    var holds: ingress_channel.SharedPayloadHolds = .{};
    var spans: [lens.len]ingress_channel.SharedPayloadSpan = undefined;
    var recv_scratch: [512]u8 = undefined;
    for (payloads, 0..) |payload, index| {
        var packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
        var received = try ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &packet, .{
            .worker_to_server = &server_ring,
            .worker_to_server_holds = &holds,
        });
        defer received.deinit();
        try std.testing.expectEqualSlices(u8, payload, received.payload);
        // The account owns the release.
        try std.testing.expectEqual(@as(u64, 0), received.shared_release.byte_len);
        spans[index] = received.ring_span orelse return error.TestExpectedRingSpan;
        try std.testing.expectEqual(@as(u32, @intCast(payload.len)), spans[index].len);
        try std.testing.expectEqualSlices(
            u8,
            payload,
            try server_ring.heldPayload(.worker_to_server, spans[index].offset, spans[index].len),
        );
        // The middle payload is consumed at once; the other two are held.
        if (index == 1) {
            try std.testing.expectEqual(@as(u64, 0), holds.pass(spans[index]));
        } else {
            try std.testing.expect(holds.hold(spans[index]));
        }
    }
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity - total,
        try server_ring.availableCapacity(.worker_to_server),
    );

    try std.testing.expectEqual(@as(?u64, 0), holds.answer(spans[2].offset, spans[2].len));
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity - total,
        try server_ring.availableCapacity(.worker_to_server),
    );
    const freed = holds.answer(spans[0].offset, spans[0].len) orelse return error.TestExpectedRelease;
    try std.testing.expectEqual(@as(u64, total), freed);
    var release = ingress_channel.SharedPayloadReadRelease{
        .view = &server_ring,
        .direction = .worker_to_server,
        .byte_len = freed,
    };
    release.release();
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity,
        try server_ring.availableCapacity(.worker_to_server),
    );
}

test "a batch decoded with an account starts after the held payloads and leaves the release to the account" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var worker_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer worker_ring.deinit();
    var server_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer server_ring.deinit();

    const identity = ingress_channel.RequestIdentity{
        .request_id = 8,
        .request_generation = 4,
        .request_lane_id = 0,
        .request_slot = 2,
    };
    const held_payload = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 5);
    defer std.testing.allocator.free(held_payload);
    @memset(held_payload, 0x51);
    const batch_payloads = [_][]u8{
        try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 7),
        try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 9),
    };
    defer for (batch_payloads) |payload| std.testing.allocator.free(payload);
    @memset(batch_payloads[0], 0x62);
    @memset(batch_payloads[1], 0x73);

    var send_scratch: [512]u8 = undefined;
    try ingress_channel.sendDescriptorPayloadRequireRing(
        pair[0],
        ingress_channel.Descriptor.responseChunk(identity, 11, 0, @intCast(held_payload.len), false),
        held_payload,
        &send_scratch,
        worker_ring.writer(.worker_to_server),
    );
    const entries = [_]ingress_channel.BatchEntry{
        .{
            .descriptor = ingress_channel.Descriptor.responseChunk(identity, 11, 0, @intCast(batch_payloads[0].len), false),
            .payload = batch_payloads[0],
        },
        .{
            .descriptor = ingress_channel.Descriptor.responseChunk(identity, 11, 0, @intCast(batch_payloads[1].len), true),
            .payload = batch_payloads[1],
        },
    };
    try ingress_channel.sendDescriptorBatchRingPayloads(pair[0], &entries, &send_scratch, worker_ring.writer(.worker_to_server));

    var holds: ingress_channel.SharedPayloadHolds = .{};
    var recv_scratch: [512]u8 = undefined;
    var single_packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    var single = try ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &single_packet, .{
        .worker_to_server = &server_ring,
        .worker_to_server_holds = &holds,
    });
    const held_span = single.ring_span orelse return error.TestExpectedRingSpan;
    single.deinit();
    try std.testing.expect(holds.hold(held_span));

    var batch_packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
    var batch = try ingress_channel.decodeReceivedBatchPacketWithSharedPayload(std.testing.allocator, &batch_packet, .{
        .worker_to_server = &server_ring,
        .worker_to_server_holds = &holds,
    });
    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    for (batch.items, batch_payloads) |*item, payload| {
        try std.testing.expectEqualSlices(u8, payload, item.payload);
        try std.testing.expectEqual(@as(u64, 0), holds.pass(item.ring_span orelse return error.TestExpectedRingSpan));
    }
    batch.deinit();
    const total = held_payload.len + batch_payloads[0].len + batch_payloads[1].len;
    try std.testing.expectEqual(
        ingress_channel.shared_payload_ring_capacity - total,
        try server_ring.availableCapacity(.worker_to_server),
    );
    try std.testing.expectEqual(@as(?u64, total), holds.answer(held_span.offset, held_span.len));
}

test "a payload that skips the ring's tail behind a held one frees the tail with it" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var worker_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer worker_ring.deinit();
    var server_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer server_ring.deinit();

    const capacity = ingress_channel.shared_payload_ring_capacity;
    const tail_len: usize = 40_000;
    const lens = [_]usize{ capacity - tail_len, 33_000, 33_000 };
    const identity = ingress_channel.RequestIdentity{
        .request_id = 9,
        .request_generation = 2,
        .request_lane_id = 1,
        .request_slot = 4,
    };
    const payload = try std.testing.allocator.alloc(u8, lens[0]);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);

    var holds: ingress_channel.SharedPayloadHolds = .{};
    var spans: [lens.len]ingress_channel.SharedPayloadSpan = undefined;
    var send_scratch: [512]u8 = undefined;
    var recv_scratch: [512]u8 = undefined;
    for (lens, 0..) |len, index| {
        const descriptor = ingress_channel.Descriptor.responseChunk(identity, 13, 0, @intCast(len), false);
        try ingress_channel.sendDescriptorPayloadRequireRing(pair[0], descriptor, payload[0..len], &send_scratch, worker_ring.writer(.worker_to_server));
        var packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
        var received = try ingress_channel.decodeReceivedPacketWithSharedPayload(std.testing.allocator, &packet, .{
            .worker_to_server = &server_ring,
            .worker_to_server_holds = &holds,
        });
        spans[index] = received.ring_span orelse return error.TestExpectedRingSpan;
        received.deinit();
        switch (index) {
            // The first payload moves both cursors next to the ring's end.
            0 => {
                var release = ingress_channel.SharedPayloadReadRelease{
                    .view = &server_ring,
                    .direction = .worker_to_server,
                    .byte_len = holds.pass(spans[index]),
                };
                release.release();
            },
            1 => try std.testing.expect(holds.hold(spans[index])),
            else => try std.testing.expectEqual(@as(u64, 0), holds.pass(spans[index])),
        }
    }
    // The last payload did not fit the tail, so it starts the ring again and
    // reserves the tail it skipped.
    try std.testing.expectEqual(@as(u64, 0), spans[2].offset);
    try std.testing.expectEqual(@as(u64, tail_len - lens[1] + lens[2]), spans[2].reserved_len);

    const freed = holds.answer(spans[1].offset, spans[1].len) orelse return error.TestExpectedRelease;
    try std.testing.expectEqual(@as(u64, tail_len + lens[2]), freed);
    var release = ingress_channel.SharedPayloadReadRelease{
        .view = &server_ring,
        .direction = .worker_to_server,
        .byte_len = freed,
    };
    release.release();
    try std.testing.expectEqual(capacity, try server_ring.availableCapacity(.worker_to_server));
}

test "a held payload is read back only inside its ring" {
    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    var view = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer view.deinit();
    const capacity = ingress_channel.shared_payload_ring_capacity;

    try std.testing.expectEqual(@as(usize, 16), (try view.heldPayload(.worker_to_server, capacity - 16, 16)).len);
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, view.heldPayload(.worker_to_server, capacity - 16, 17));
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, view.heldPayload(.worker_to_server, capacity, 1));
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, view.heldPayload(.worker_to_server, std.math.maxInt(u64), 0));
}

/// The server's and the worker's views of one payload memfd.
const PayloadViews = struct {
    fd: std.posix.fd_t,
    server: ingress_channel.SharedPayloadView,
    worker: ingress_channel.SharedPayloadView,

    fn init() !PayloadViews {
        const fd = try ingress_channel.createSharedPayloadMemfd();
        errdefer std.posix.close(fd);
        var server = try ingress_channel.mapSharedPayloadReadWrite(fd, .server);
        errdefer server.deinit();
        const worker = try ingress_channel.mapSharedPayloadReadWrite(fd, .worker);
        return .{ .fd = fd, .server = server, .worker = worker };
    }

    fn deinit(self: *PayloadViews) void {
        self.worker.deinit();
        self.server.deinit();
        std.posix.close(self.fd);
    }

    /// The cursors of `direction` in shared memory, where either side can
    /// rewrite them.
    fn ring(self: *PayloadViews, direction: ingress_channel.SharedPayloadDirection) *ingress_channel.SharedPayloadRingHeader {
        return &self.server.header.rings[@intFromEnum(direction)];
    }
};

test "a read cursor above the server's write cursor fails the server's next write" {
    var views = try PayloadViews.init();
    defer views.deinit();
    const payload = [_]u8{0x5a} ** (ingress_channel.shared_payload_threshold + 1);
    _ = try views.server.write(.server_to_worker, &payload);

    // The worker claims to have read past everything the server wrote.
    @atomicStore(u64, &views.ring(.server_to_worker).read_cursor, payload.len + 1, .release);
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, views.server.write(.server_to_worker, &payload));
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, views.server.availableCapacity(.server_to_worker));
}

test "a write cursor the worker rewinds moves neither the server's next payload nor its cancellation" {
    var views = try PayloadViews.init();
    defer views.deinit();
    const ring = views.ring(.server_to_worker);
    const payload = [_]u8{0x11} ** 64;
    const first = try views.server.write(.server_to_worker, &payload);
    try std.testing.expectEqual(@as(u64, 0), first.offset);

    @atomicStore(u64, &ring.write_cursor, 0, .release);
    const second = try views.server.write(.server_to_worker, &payload);
    try std.testing.expectEqual(@as(u64, payload.len), second.offset);
    try std.testing.expectEqual(@as(u64, 2 * payload.len), @atomicLoad(u64, &ring.write_cursor, .acquire));

    @atomicStore(u64, &ring.write_cursor, 0, .release);
    views.server.cancelLastWrite(.server_to_worker, payload.len);
    try std.testing.expectEqual(@as(u64, payload.len), @atomicLoad(u64, &ring.write_cursor, .acquire));
    const third = try views.server.write(.server_to_worker, &payload);
    try std.testing.expectEqual(@as(u64, payload.len), third.offset);
}

test "the server's read cursor moves only by its own releases, and a write cursor that contradicts it fails the read" {
    var views = try PayloadViews.init();
    defer views.deinit();
    const payload = [_]u8{0x22} ** 128;
    const reservation = try views.worker.write(.worker_to_server, &payload);
    try std.testing.expectEqual(@as(u64, 0), views.server.readCursor(.worker_to_server));
    const borrowed = try views.server.readBorrowAt(.worker_to_server, 0, reservation.offset, payload.len);
    try std.testing.expectEqualSlices(u8, &payload, borrowed.bytes);

    // The worker moves its write cursor behind the payload the server
    // checked. The release still frees that payload and stores the server's
    // cursor; rewinding the stored copy does not move the server's next read.
    const ring = views.ring(.worker_to_server);
    @atomicStore(u64, &ring.write_cursor, 1, .release);
    var release: ingress_channel.SharedPayloadReadRelease = .{
        .view = &views.server,
        .direction = .worker_to_server,
        .byte_len = borrowed.reserved_len,
    };
    release.release();
    try std.testing.expectEqual(@as(u64, payload.len), @atomicLoad(u64, &ring.read_cursor, .acquire));
    @atomicStore(u64, &ring.read_cursor, 0, .release);
    try std.testing.expectEqual(@as(u64, payload.len), views.server.readCursor(.worker_to_server));

    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, views.server.availableCapacity(.worker_to_server));
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, views.server.readBorrowAt(.worker_to_server, payload.len, payload.len, 16));
    // A write cursor that claims more than the ring holds.
    @atomicStore(u64, &ring.write_cursor, payload.len + ingress_channel.shared_payload_ring_capacity + 1, .release);
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, views.server.readBorrowAt(.worker_to_server, payload.len, payload.len, 16));
}

test "a payload past the writer's cursor reads short" {
    var views = try PayloadViews.init();
    defer views.deinit();
    const payload = [_]u8{0x33} ** 64;
    _ = try views.worker.write(.worker_to_server, &payload);
    try std.testing.expectError(error.ShortRead, views.server.readBorrowAt(.worker_to_server, 0, 0, payload.len + 1));
}

/// Reads the worker's payload at `reservation` from the server's side and
/// releases it, as a reader frees a payload once its consumer is done.
fn releaseWorkerPayload(views: *PayloadViews, reservation: ingress_channel.SharedPayloadWriteReservation, len: usize, credit_eventfd: std.posix.fd_t) !void {
    const cursor = views.server.readCursor(.worker_to_server);
    const borrowed = try views.server.readBorrowAt(.worker_to_server, cursor, reservation.offset, @intCast(len));
    var release: ingress_channel.SharedPayloadReadRelease = .{
        .view = &views.server,
        .direction = .worker_to_server,
        .byte_len = borrowed.reserved_len,
        .credit_eventfd = credit_eventfd,
    };
    release.release();
}

/// Whether the eventfd was signalled since its last read, which clears it.
fn takeEventFdSignal(fd: std.posix.fd_t) !bool {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return err,
    };
    return value != 0;
}

test "a release signals the writer's credit eventfd only while the writer waits, once per wait" {
    var views = try PayloadViews.init();
    defer views.deinit();
    const credit = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(credit);
    const small = [_]u8{0x66} ** 64;
    const large = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_ring_capacity / 2 + 1);
    defer std.testing.allocator.free(large);
    @memset(large, 0x77);

    // No writer waits, so a release makes no system call.
    const first = try views.worker.write(.worker_to_server, &small);
    try releaseWorkerPayload(&views, first, small.len, credit);
    try std.testing.expect(!try takeEventFdSignal(credit));

    // A second large payload finds no room behind the first; the writer
    // marks itself waiting and checks again, and the release wakes it.
    const held = try views.worker.write(.worker_to_server, large);
    try std.testing.expect(!try views.worker.fits(.worker_to_server, large.len));
    views.worker.markWriterWaiting(.worker_to_server);
    try std.testing.expect(!try views.worker.fits(.worker_to_server, large.len));
    try releaseWorkerPayload(&views, held, large.len, credit);
    try std.testing.expect(try takeEventFdSignal(credit));
    try std.testing.expect(try views.worker.fits(.worker_to_server, large.len));

    // The release took the mark, so the next one signals nothing.
    const last = try views.worker.write(.worker_to_server, &small);
    try releaseWorkerPayload(&views, last, small.len, credit);
    try std.testing.expect(!try takeEventFdSignal(credit));
}

test "a memfd whose rings are not empty does not map" {
    var written = try PayloadViews.init();
    defer written.deinit();
    const payload = [_]u8{0x44} ** 8;
    _ = try written.server.write(.server_to_worker, &payload);
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, ingress_channel.mapSharedPayloadReadWrite(written.fd, .worker));

    var released = try PayloadViews.init();
    defer released.deinit();
    @atomicStore(u64, &released.ring(.worker_to_server).read_cursor, 1, .release);
    try std.testing.expectError(error.InvalidIngressSharedPayloadRing, ingress_channel.mapSharedPayloadReadWrite(released.fd, .server));
}

test "ingress channel response head payload round trips status and headers" {
    const headers = [_]ingress_channel.ResponseHeader{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "x-demo", .value = "yes" },
    };
    var scratch: [256]u8 = undefined;
    const encoded = try ingress_channel.encodeResponseHeadInto(&scratch, 201, &headers);

    var decoded = try ingress_channel.decodeResponseHead(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u16, 201), decoded.status);
    try std.testing.expectEqual(@as(usize, 2), decoded.headers.len);
    try std.testing.expectEqualStrings("content-type", decoded.headers[0].name);
    try std.testing.expectEqualStrings("text/plain", decoded.headers[0].value);
    try std.testing.expectEqualStrings("x-demo", decoded.headers[1].name);
    try std.testing.expectEqualStrings("yes", decoded.headers[1].value);
}

test "decoded dispatch work stores slices in one compact packet copy" {
    const headers = [_]RequestHeader{
        .{ .name = "host", .value = "demo.test" },
        .{ .name = "x-test", .value = "yes" },
    };
    const captures = [_]RouteCapture{.{ .name = "slug", .value = "hello" }};
    const view = ipc.DispatchWorkView{
        .request_id = 15,
        .worker_slot = 0,
        .authority = "demo.test",
        .deadline_monotonic_ns = 123,
        .method = "POST",
        .path = "/hello",
        .raw_query = "a=1",
        .request_headers = &headers,
        .body_framing = .ingress_channel,
        .route_captures = &captures,
        .route_index = 0,
    };

    var scratch: [max_message_bytes]u8 = undefined;
    const packet = try encodeDispatchWorkInto(&scratch, &view);
    var decoded = try decodeDispatchWork(std.testing.allocator, packet);
    defer decoded.deinit();

    try std.testing.expectEqual(packet.len, decoded.storage.len);
    try std.testing.expect(sliceWithin(decoded.storage, decoded.authority));
    try std.testing.expect(sliceWithin(decoded.storage, decoded.method));
    try std.testing.expect(sliceWithin(decoded.storage, decoded.path));
    try std.testing.expect(sliceWithin(decoded.storage, decoded.raw_query));
    try std.testing.expect(sliceWithin(decoded.storage, decoded.request_headers[0].name));
    try std.testing.expect(sliceWithin(decoded.storage, decoded.request_headers[0].value));
    try std.testing.expect(sliceWithin(decoded.storage, decoded.route_captures[0].name));
    try std.testing.expect(sliceWithin(decoded.storage, decoded.route_captures[0].value));
    try std.testing.expect(decoded.method.ptr != view.method.ptr);
    try std.testing.expectEqualStrings("POST", decoded.method);
    try std.testing.expectEqualStrings("hello", decoded.route_captures[0].value);
}

test "a dispatch packet ends at its route captures, names its route in the header, and the decoder refuses a byte after it" {
    const headers = [_]RequestHeader{.{ .name = "accept", .value = "*/*" }};
    const captures = [_]RouteCapture{.{ .name = "id", .value = "7" }};
    const view = ipc.DispatchWorkView{
        .request_id = 9,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 3,
        .worker_slot = 6,
        .worker_id = 4,
        .worker_generation = 5,
        .authority = "example.test",
        .deadline_monotonic_ns = 1_000,
        .method = "GET",
        .path = "/",
        .raw_query = "",
        .request_headers = &headers,
        .body_framing = .none,
        .route_captures = &captures,
        .route_index = 63,
    };
    var scratch: [max_message_bytes]u8 = undefined;
    const encoded = try encodeDispatchWorkInto(&scratch, &view);
    const sections_len = view.authority.len + view.method.len + view.path.len + view.raw_query.len +
        @sizeOf(ipc.messages.NameValuePacket) + headers[0].name.len + headers[0].value.len +
        @sizeOf(ipc.messages.NameValuePacket) + captures[0].name.len + captures[0].value.len;
    try std.testing.expectEqual(@sizeOf(DispatchPacketHeader) + sections_len, encoded.len);
    const header = std.mem.bytesToValue(DispatchPacketHeader, encoded[0..@sizeOf(DispatchPacketHeader)]);
    try std.testing.expectEqual(@as(u16, 63), header.route_index);
    try std.testing.expectEqual(@as(u8, 6), header.worker_slot);

    var decoded = try decodeDispatchWork(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u16, 63), decoded.route_index);
    try std.testing.expectEqual(@as(u8, 6), decoded.worker_slot);
    try std.testing.expectEqualStrings("*/*", decoded.request_headers[0].value);
    try std.testing.expectEqualStrings("7", decoded.route_captures[0].value);

    scratch[encoded.len] = 0;
    try std.testing.expectError(error.InvalidPacket, decodeDispatchWork(std.testing.allocator, scratch[0 .. encoded.len + 1]));
}

test "the dispatch header keeps its pinned size and offsets, with the egress token at 24" {
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(DispatchPacketHeader));
    try expectOffset(DispatchPacketHeader, "kind", 0);
    try expectOffset(DispatchPacketHeader, "request_slot", 4);
    try expectOffset(DispatchPacketHeader, "request_id", 8);
    try expectOffset(DispatchPacketHeader, "request_generation", 16);
    try expectOffset(DispatchPacketHeader, "egress_token", 24);
    try expectOffset(DispatchPacketHeader, "worker_id", 80);
    try expectOffset(DispatchPacketHeader, "worker_generation", 88);
    try expectOffset(DispatchPacketHeader, "deadline_monotonic_ns", 96);
    try expectOffset(DispatchPacketHeader, "_reserved0", 104);
    try expectOffset(DispatchPacketHeader, "request_lane_id", 108);
    try expectOffset(DispatchPacketHeader, "route_index", 110);
    try expectOffset(DispatchPacketHeader, "authority_len", 112);
    try expectOffset(DispatchPacketHeader, "method_len", 116);
    try expectOffset(DispatchPacketHeader, "path_len", 120);
    try expectOffset(DispatchPacketHeader, "raw_query_len", 124);
    try expectOffset(DispatchPacketHeader, "route_capture_count", 128);
    try expectOffset(DispatchPacketHeader, "route_captures_bytes_len", 132);
    try expectOffset(DispatchPacketHeader, "worker_slot", 136);
    try expectOffset(DispatchPacketHeader, "_reserved1", 137);
    try expectOffset(DispatchPacketHeader, "_reserved2", 138);
    try expectOffset(DispatchPacketHeader, "request_header_count", 140);
    try expectOffset(DispatchPacketHeader, "request_headers_bytes_len", 144);
    try expectOffset(DispatchPacketHeader, "body_framing", 148);
    try std.testing.expectEqual(
        egress_token.token_bytes,
        @sizeOf(@FieldType(DispatchPacketHeader, "egress_token")),
    );
}

test "dispatch work carries a minted egress token through encode and decode unchanged" {
    const minted = requestTokenBytes(41, 3);
    var dispatch = try DispatchWork.initOwned(std.testing.allocator, .{
        .request_id = 41,
        .request_generation = 3,
        .worker_slot = 0,
        .egress_token = minted,
        .authority = "demo.test",
        .deadline_monotonic_ns = 5_000_000_000,
        .method = "GET",
        .path = "/token",
        .raw_query = "",
        .request_headers = &.{},
        .body_framing = .none,
        .route_captures = &.{},
        .route_index = 0,
    });
    defer dispatch.deinit();
    try std.testing.expectEqualSlices(u8, &minted, &dispatch.egress_token);

    var scratch: [max_message_bytes]u8 = undefined;
    var view = dispatch.view();
    const encoded = try encodeDispatchWorkInto(&scratch, &view);
    try std.testing.expectEqualSlices(
        u8,
        &minted,
        encoded[@offsetOf(DispatchPacketHeader, "egress_token")..][0..egress_token.token_bytes],
    );
    var decoded = try decodeDispatchWork(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &minted, &decoded.egress_token);

    // The bytes still verify, so the trip changed none of them.
    const token = egress_token.fromBytes(&decoded.egress_token);
    const fields = try egress_token.verify(&token_key, &token);
    try std.testing.expectEqual(@as(u64, 41), fields.request_id);
    try std.testing.expectEqual(@as(u64, 3), fields.request_generation);
}

test "dispatch work without a token carries none through encode and decode" {
    const view = ipc.DispatchWorkView{
        .request_id = 42,
        .worker_slot = 0,
        .authority = "demo.test",
        .deadline_monotonic_ns = 1,
        .method = "GET",
        .path = "/",
        .raw_query = "",
        .request_headers = &.{},
        .body_framing = .none,
        .route_captures = &.{},
        .route_index = 0,
    };
    try std.testing.expect(egress_token.isNone(&view.egress_token));

    var owned = try DispatchWork.initOwned(std.testing.allocator, view);
    defer owned.deinit();
    try std.testing.expect(egress_token.isNone(&owned.egress_token));

    var scratch: [max_message_bytes]u8 = undefined;
    const encoded = try encodeDispatchWorkInto(&scratch, &view);
    var decoded = try decodeDispatchWork(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expect(egress_token.isNone(&decoded.egress_token));
}

test "a boot context's dispatch work keeps its own copy of the boot token" {
    var boot_token = bootTokenBytes();
    const minted = boot_token;
    var boot = try DispatchWork.initBoot(std.testing.allocator, 1, &boot_token);
    defer boot.deinit();

    // The caller's bytes change after the call and the copy does not.
    @memset(&boot_token, 0);
    try std.testing.expectEqualSlices(u8, &minted, &boot.egress_token);
    const token = egress_token.fromBytes(&boot.egress_token);
    const fields = try egress_token.verify(&token_key, &token);
    try std.testing.expectEqual(egress_token.Kind.boot, fields.kind);
    try std.testing.expectEqual(@as(u64, 0), fields.request_id);
    try std.testing.expectEqual(@as(u64, 0), fields.request_generation);
    try std.testing.expectEqual(@as(u16, 0), boot.route_index);

    var detached = try DispatchWork.initBoot(std.testing.allocator, 1, &egress_token.none);
    defer detached.deinit();
    try std.testing.expect(egress_token.isNone(&detached.egress_token));
}

test "dispatch capture section is validated before capture allocation" {
    var packet: [@sizeOf(DispatchPacketHeader) + 1]u8 = undefined;
    var header = std.mem.zeroes(DispatchPacketHeader);
    header.kind = @intFromEnum(MessageKind.dispatch_work);
    header.request_id = 1;
    header.deadline_monotonic_ns = 1;
    header.authority_len = 1;
    header.route_capture_count = 1;
    header.route_captures_bytes_len = 0;

    var cursor: usize = 0;
    cursor += writeStruct(packet[cursor..], &header);
    cursor += writeSlice(packet[cursor..], "d");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.InvalidPacket, decodeDispatchWork(failing.allocator(), packet[0..cursor]));
}

test "dispatch request header count is bounded before header allocation" {
    var packet: [@sizeOf(DispatchPacketHeader)]u8 = undefined;
    var header = std.mem.zeroes(DispatchPacketHeader);
    header.kind = @intFromEnum(MessageKind.dispatch_work);
    header.request_id = 1;
    header.deadline_monotonic_ns = 1;
    header.request_header_count = max_request_header_count + 1;

    var cursor: usize = 0;
    cursor += writeStruct(packet[cursor..], &header);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.TooManyRequestHeaders, decodeDispatchWork(failing.allocator(), packet[0..cursor]));
}

test "dispatch decode refuses a nonzero word at offset 104, where no dispatch field lives" {
    const view = ipc.DispatchWorkView{
        .request_id = 3,
        .worker_slot = 0,
        .authority = "demo.test",
        .deadline_monotonic_ns = 1,
        .method = "GET",
        .path = "/",
        .raw_query = "",
        .request_headers = &.{},
        .body_framing = .none,
        .route_captures = &.{},
        .route_index = 0,
    };
    var scratch: [max_message_bytes]u8 = undefined;
    const encoded = try encodeDispatchWorkInto(&scratch, &view);
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(DispatchPacketHeader, "_reserved0"));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(@FieldType(DispatchPacketHeader, "_reserved0")));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, encoded[104..108]);

    // Either end of the word is refused.
    for ([_]u32{ 1, 1 << 31 }) |word| {
        std.mem.writeInt(u32, encoded[104..108], word, @import("builtin").cpu.arch.endian());
        try std.testing.expectError(error.InvalidPacket, decodeDispatchWork(std.testing.allocator, encoded));
    }
}

test "dispatch decode refuses an empty authority and a nonzero reserved field" {
    const view = ipc.DispatchWorkView{
        .request_id = 3,
        .worker_slot = 0,
        .authority = "demo.test",
        .deadline_monotonic_ns = 1,
        .method = "GET",
        .path = "/",
        .raw_query = "",
        .request_headers = &.{},
        .body_framing = .none,
        .route_captures = &.{},
        .route_index = 0,
    };
    var scratch: [max_message_bytes]u8 = undefined;
    const encoded = try encodeDispatchWorkInto(&scratch, &view);
    var decoded = try decodeDispatchWork(std.testing.allocator, encoded);
    decoded.deinit();

    const valid_header = std.mem.bytesToValue(DispatchPacketHeader, encoded[0..@sizeOf(DispatchPacketHeader)]);
    var header = valid_header;
    header._reserved0 = 1;
    _ = writeStruct(encoded, &header);
    try std.testing.expectError(error.InvalidPacket, decodeDispatchWork(std.testing.allocator, encoded));
    header = valid_header;
    header._reserved1 = 1;
    _ = writeStruct(encoded, &header);
    try std.testing.expectError(error.InvalidPacket, decodeDispatchWork(std.testing.allocator, encoded));
    header = valid_header;
    header._reserved2 = 1;
    _ = writeStruct(encoded, &header);
    try std.testing.expectError(error.InvalidPacket, decodeDispatchWork(std.testing.allocator, encoded));
    _ = writeStruct(encoded, &valid_header);

    var empty_view = view;
    empty_view.authority = "";
    const empty = try encodeDispatchWorkInto(&scratch, &empty_view);
    try std.testing.expectError(error.MissingAuthority, decodeDispatchWork(std.testing.allocator, empty));
}

test "dispatch work names a worker slot below the pool's slot count, and every end refuses one past it" {
    // The page's live slots are one per pool slot (`limits.server.worker_concurrency_max`),
    // and this test binary reaches the limits only through the page.
    const last_slot: u8 = @intCast(@import("collo_worker_state").page.LIVE_SLOT_COUNT - 1);
    var view = ipc.DispatchWorkView{
        .request_id = 5,
        .worker_slot = last_slot,
        .authority = "demo.test",
        .deadline_monotonic_ns = 1,
        .method = "GET",
        .path = "/",
        .raw_query = "",
        .request_headers = &.{},
        .body_framing = .none,
        .route_captures = &.{},
        .route_index = 0,
    };
    var scratch: [max_message_bytes]u8 = undefined;
    const encoded = try encodeDispatchWorkInto(&scratch, &view);
    var decoded = try decodeDispatchWork(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(last_slot, decoded.worker_slot);
    var owned = try DispatchWork.initOwned(std.testing.allocator, view);
    defer owned.deinit();
    try std.testing.expectEqual(last_slot, owned.view().worker_slot);

    // The encoder and the owned copy refuse a slot no pool has; the worker's
    // decoder refuses one a broken server wrote.
    view.worker_slot = last_slot + 1;
    try std.testing.expectError(error.InvalidWorkerSlot, encodeDispatchWorkInto(&scratch, &view));
    try std.testing.expectError(error.InvalidWorkerSlot, DispatchWork.initOwned(std.testing.allocator, view));
    for ([_]u8{ last_slot + 1, std.math.maxInt(u8) }) |slot| {
        var header = std.mem.bytesToValue(DispatchPacketHeader, encoded[0..@sizeOf(DispatchPacketHeader)]);
        header.worker_slot = slot;
        _ = writeStruct(encoded, &header);
        try std.testing.expectError(error.InvalidWorkerSlot, decodeDispatchWork(std.testing.allocator, encoded));
    }
}

test "dispatch encode rejects too many request headers" {
    var scratch: [max_message_bytes]u8 = undefined;
    var empty: [0]u8 = .{};
    var headers: [max_request_header_count + 1]RequestHeader = undefined;
    var captures: [0]RouteCapture = .{};
    for (&headers) |*header| {
        header.* = .{ .name = "", .value = "" };
    }
    var message = DispatchWork{
        .allocator = std.testing.allocator,
        .request_id = 1,
        .worker_slot = 0,
        .authority = empty[0..],
        .deadline_monotonic_ns = 1,
        .method = empty[0..],
        .path = empty[0..],
        .raw_query = empty[0..],
        .request_headers = headers[0..],
        .body_framing = .none,
        .route_captures = captures[0..],
        .route_index = 0,
    };

    var view = message.view();
    try std.testing.expectError(error.TooManyRequestHeaders, encodeDispatchWorkInto(&scratch, &view));
}

test "dispatch encode rejects overflowing length accumulation" {
    var scratch: [max_message_bytes]u8 = undefined;
    var empty: [0]u8 = .{};
    var captures: [0]RouteCapture = .{};
    const huge = @as([*]u8, @ptrFromInt(1))[0..std.math.maxInt(usize)];
    var message = DispatchWork{
        .allocator = std.testing.allocator,
        .request_id = 1,
        .worker_slot = 0,
        .authority = empty[0..],
        .deadline_monotonic_ns = 1,
        .method = huge,
        .path = empty[0..],
        .raw_query = empty[0..],
        .request_headers = &.{},
        .body_framing = .none,
        .route_captures = captures[0..],
        .route_index = 0,
    };

    var view = message.view();
    try std.testing.expectError(error.MessageTooLarge, encodeDispatchWorkInto(&scratch, &view));
}

test "scratch packet receive does not duplicate payload onto heap" {
    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    try sendWithFds(control_pair[0], "abc", &.{});

    var scratch: [max_message_bytes]u8 = undefined;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var packet = try recvPacketWithFdsScratch(failing.allocator(), control_pair[1], &scratch);
    defer packet.deinit();

    try std.testing.expectEqualStrings("abc", packet.bytes);
    try std.testing.expectEqual(@intFromPtr(&scratch), @intFromPtr(packet.bytes.ptr));
    try std.testing.expect(packet.owned_buffer == null);
}

test "scratch packet receive treats peer close as typed EOF" {
    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[1]);
    std.posix.close(control_pair[0]);

    var scratch: [max_message_bytes]u8 = undefined;
    try std.testing.expectError(error.PeerClosed, recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch));
}

test "a zero-length datagram with descriptors closes them, fails with EmptyPacketWithFds and leaves the channel open" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const carried = try fd_mod.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(carried[0]);
    defer std.posix.close(carried[1]);

    try sendEmptyWithFds(pair[0], &.{ carried[0], carried[1], carried[0] });
    try sendWithFds(pair[0], "next", &.{});

    var scratch: [max_message_bytes]u8 = undefined;
    const before = try openFdCount();
    try std.testing.expectError(
        error.EmptyPacketWithFds,
        recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch),
    );
    try std.testing.expectEqual(before, try openFdCount());

    var packet = try recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch);
    defer packet.deinit();
    try std.testing.expectEqualStrings("next", packet.bytes);
}

test "a zero-length datagram with more descriptors than one receive holds closes those that arrived" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const carried = try fd_mod.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(carried[0]);
    defer std.posix.close(carried[1]);

    var fds: [max_fds_per_message + 1]std.posix.fd_t = undefined;
    @memset(&fds, carried[0]);
    try sendEmptyWithFds(pair[0], &fds);

    var scratch: [max_message_bytes]u8 = undefined;
    const before = try openFdCount();
    try std.testing.expectError(
        error.EmptyPacketWithFds,
        recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch),
    );
    try std.testing.expectEqual(before, try openFdCount());
}

test "a zero-length datagram without descriptors reads as PeerClosed, as an end of stream does" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);

    try sendWithFds(pair[0], "", &.{});
    var scratch: [max_message_bytes]u8 = undefined;
    try std.testing.expectError(
        error.PeerClosed,
        recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch),
    );

    std.posix.close(pair[0]);
    try std.testing.expectError(
        error.PeerClosed,
        recvPacketWithFdsScratch(std.testing.allocator, pair[1], &scratch),
    );
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

/// Sends a datagram of no bytes with `fds` as SCM_RIGHTS, up to one more
/// descriptor than a receive takes.
fn sendEmptyWithFds(socket: std.posix.fd_t, fds: []const std.posix.fd_t) !void {
    const payload_len_max = @sizeOf(std.posix.fd_t) * (max_fds_per_message + 1);
    var control: [cmsg.space(payload_len_max)]u8 align(@alignOf(cmsg.Cmsghdr)) =
        std.mem.zeroes([cmsg.space(payload_len_max)]u8);
    std.debug.assert(fds.len <= max_fds_per_message + 1);
    writeRightsControlMessage(&control, 0, fds);
    const iov = [1]std.posix.iovec_const{.{ .base = "".ptr, .len = 0 }};
    const msg = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = cmsg.space(@sizeOf(std.posix.fd_t) * fds.len),
        .flags = 0,
    };
    try std.testing.expectEqual(@as(usize, 0), try sendmsgCompat(socket, &msg, std.posix.MSG.NOSIGNAL));
}

test "packet receive collects chained rights control messages" {
    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    const fd_pair = try fd_mod.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(fd_pair[0]);
    defer std.posix.close(fd_pair[1]);

    const one_fd_len = @sizeOf(std.posix.fd_t);
    var control: [cmsg.space(one_fd_len) * 2]u8 align(@alignOf(cmsg.Cmsghdr)) =
        std.mem.zeroes([cmsg.space(one_fd_len) * 2]u8);
    writeRightsControlMessage(&control, 0, &.{fd_pair[0]});
    writeRightsControlMessage(&control, cmsg.space(one_fd_len), &.{fd_pair[1]});

    const payload = "abc";
    const iov = [1]std.posix.iovec_const{
        .{
            .base = payload.ptr,
            .len = payload.len,
        },
    };
    const msg = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    try std.testing.expectEqual(payload.len, try sendmsgCompat(control_pair[0], &msg, std.posix.MSG.NOSIGNAL));

    var scratch: [max_message_bytes]u8 = undefined;
    var packet = try recvPacketWithFdsScratch(std.testing.allocator, control_pair[1], &scratch);
    defer packet.deinit();

    try std.testing.expectEqualStrings(payload, packet.bytes);
    try std.testing.expectEqual(@as(usize, 2), packet.fd_count);
}

test "unexpected chained ancillary data closes received rights" {
    const fd_pair = try fd_mod.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    var rights_fd: ?std.posix.fd_t = fd_pair[0];
    defer if (rights_fd) |fd| std.posix.close(fd);
    defer std.posix.close(fd_pair[1]);

    const rights_offset = cmsg.space(0);
    var control: [cmsg.space(0) + cmsg.space(@sizeOf(std.posix.fd_t))]u8 align(@alignOf(cmsg.Cmsghdr)) =
        std.mem.zeroes([cmsg.space(0) + cmsg.space(@sizeOf(std.posix.fd_t))]u8);
    writeControlMessageHeader(&control, 0, std.posix.SOL.SOCKET, cmsg.scm_credentials, 0);
    writeRightsControlMessage(&control, rights_offset, &.{fd_pair[0]});

    var result = ReceivedPacket{
        .allocator = std.testing.allocator,
        .bytes = &.{},
        .owned_buffer = null,
        .fds = [_]fd_mod.OwnedFd{.{}} ** max_fds_per_message,
        .fd_count = 0,
    };
    try std.testing.expectError(error.UnexpectedAncillaryData, collectReceivedControlFds(&control, control.len, &result));
    try std.testing.expectEqual(@as(usize, 0), result.fd_count);

    const rc = std.c.fcntl(fd_pair[0], std.posix.F.GETFD);
    try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(rc));
    rights_fd = null;
}

test "a session's worker half and gateway half talk through the rings each maps" {
    var session = try createEgressSession();
    defer session.deinit();

    var worker_raw = try dupEgressRawFds(session.rawForWorker());
    var gateway_raw = try dupEgressRawFds(session.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();
    var endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer endpoint.deinit();

    _ = try gateway_endpoint.completion.writePacket("head");
    var buffer: [16]u8 = undefined;
    const packet = (try endpoint.completion.readPacket(&buffer)) orelse return error.MissingEgressSharedPacket;
    try std.testing.expectEqualStrings("head", packet);
}

test "egress shared gateway retained body-pool data fd is cloexec" {
    var fds = try createEgressSession();
    defer fds.deinit();

    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    const flags = try std.posix.fcntl(
        gateway_endpoint.body_pool.data_fd,
        std.posix.F.GETFD,
        0,
    );
    try std.testing.expect((flags & std.posix.FD_CLOEXEC) != 0);
}

test "egress shared ring round trips command packets" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    var payload = [_]u8{ 1, 2, 3, 4 };
    _ = try worker_endpoint.command.writePacket(&payload);
    var scratch: [16]u8 = undefined;
    const read = (try gateway_endpoint.command.readPacket(&scratch)) orelse return error.MissingPacket;
    try std.testing.expectEqualSlices(u8, &payload, read);

    const pool_offset = try gateway_endpoint.body_pool.writeChunk("body-bytes");
    var body_buffer: [16]u8 = undefined;
    try worker_endpoint.body_pool.copyChunk(pool_offset, body_buffer[0.."body-bytes".len]);
    try worker_endpoint.body_pool.releaseChunk(pool_offset, "body-bytes".len);
    try std.testing.expectEqualStrings("body-bytes", body_buffer[0.."body-bytes".len]);
}

test "egress shared body pool transaction rolls back unpublished chunks" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    var transaction = try gateway_endpoint.body_pool.beginWriteTransaction();
    const hidden_offset = try transaction.writeChunk("hidden");
    try std.testing.expectEqual(
        ipc.egress_shared.body_pool_block_size,
        (try gateway_endpoint.body_pool.usage()).used,
    );
    var hidden_buffer: [6]u8 = undefined;
    try std.testing.expectError(
        error.InvalidEgressSharedRing,
        worker_endpoint.body_pool.copyChunk(hidden_offset, &hidden_buffer),
    );
    transaction.rollback();

    var committed = try gateway_endpoint.body_pool.beginWriteTransaction();
    const visible_offset = try committed.writeChunk("visible");
    try committed.publish();
    committed.commit();

    var visible_buffer: [7]u8 = undefined;
    try worker_endpoint.body_pool.copyChunk(visible_offset, &visible_buffer);
    try std.testing.expectEqualStrings("visible", &visible_buffer);
    try worker_endpoint.body_pool.releaseChunk(visible_offset, visible_buffer.len);
}

test "egress shared body pool transaction can roll back after publish" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    var transaction = try gateway_endpoint.body_pool.beginWriteTransaction();
    const offset = try transaction.writeChunk("rollback");
    try transaction.publish();

    var visible_buffer: [8]u8 = undefined;
    try worker_endpoint.body_pool.copyChunk(offset, &visible_buffer);
    try std.testing.expectEqualStrings("rollback", &visible_buffer);

    transaction.rollback();
    try std.testing.expectEqual(
        @as(usize, 0),
        (try gateway_endpoint.body_pool.usage()).used,
    );
    try std.testing.expectError(
        error.InvalidEgressSharedRing,
        worker_endpoint.body_pool.copyChunk(offset, &visible_buffer),
    );
}

test "egress shared body pool block size holds one h2 frame" {
    // One pool block per HTTP/2 DATA frame payload: a release maps 1:1 to a
    // flow-control credit (the h2 constant is cross-checked by the gateway
    // suite; this module stays import-free of the http stack).
    try std.testing.expectEqual(@as(usize, 16 * 1024), ipc.egress_shared.body_pool_block_size);
    try std.testing.expectEqual(@as(usize, 512), ipc.egress_shared.body_pool_block_count);
}

const ExtentCollector = struct {
    extents: [8]ipc.egress_shared.BodyPoolView.ReleasedExtent = undefined,
    count: usize = 0,

    fn observe(self: *ExtentCollector, extent: ipc.egress_shared.BodyPoolView.ReleasedExtent) void {
        self.extents[self.count] = extent;
        self.count += 1;
    }
};

test "egress shared body pool observed drain reports each freed extent once" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    const first = try gateway_endpoint.body_pool.writeChunk("alpha");
    const second = try gateway_endpoint.body_pool.writeChunk("beta!");

    // Out-of-order release: the observer must see extents in release order
    // with the worker's handles and lengths intact.
    try worker_endpoint.body_pool.releaseChunk(second, "beta!".len);
    try worker_endpoint.body_pool.releaseChunk(first, "alpha".len);

    var collector = ExtentCollector{};
    const drained = try gateway_endpoint.body_pool.drainReleasedChunksObserved(&collector, ExtentCollector.observe);
    try std.testing.expectEqual(@as(usize, 2), drained);
    try std.testing.expectEqual(@as(usize, 2), collector.count);
    try std.testing.expectEqual(second, collector.extents[0].handle);
    try std.testing.expectEqual(@as(u32, "beta!".len), collector.extents[0].len);
    try std.testing.expectEqual(@as(u32, 1), collector.extents[0].block_count);
    try std.testing.expectEqual(first, collector.extents[1].handle);
    try std.testing.expectEqual(@as(usize, 0), (try gateway_endpoint.body_pool.usage()).used);

    // Nothing left: a second drain reports nothing.
    var empty = ExtentCollector{};
    try std.testing.expectEqual(@as(usize, 0), try gateway_endpoint.body_pool.drainReleasedChunksObserved(&empty, ExtentCollector.observe));
}

test "egress shared body pool free blocks probe does not consume releases" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    const handle = try gateway_endpoint.body_pool.writeChunk("bytes");
    try std.testing.expectEqual(
        ipc.egress_shared.body_pool_block_count - 1,
        gateway_endpoint.body_pool.freeBlocks(),
    );
    try worker_endpoint.body_pool.releaseChunk(handle, "bytes".len);
    // The probe must not free the slot behind the observer's back.
    try std.testing.expectEqual(
        ipc.egress_shared.body_pool_block_count - 1,
        gateway_endpoint.body_pool.freeBlocks(),
    );
    var collector = ExtentCollector{};
    _ = try gateway_endpoint.body_pool.drainReleasedChunksObserved(&collector, ExtentCollector.observe);
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_count, gateway_endpoint.body_pool.freeBlocks());
}

test "egress shared body pool usage probe does not consume releases" {
    // usage() never advances the release cursor. The gateway reads usage
    // several times per iteration for backpressure; if that consumed releases
    // through the no-op observer, the flow-control credits that ride the
    // observed drain would be lost and h2 streams would stall until
    // FetchReadTimeout.
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    const handle = try gateway_endpoint.body_pool.writeChunk("bytes");
    try worker_endpoint.body_pool.releaseChunk(handle, "bytes".len);

    // Probe usage repeatedly: none of these may consume the queued release.
    var probe: usize = 0;
    while (probe < 5) : (probe += 1) {
        try std.testing.expectEqual(
            ipc.egress_shared.body_pool_block_size,
            (try gateway_endpoint.body_pool.usage()).used,
        );
    }

    // The release is still pending: the single observed drain sees it and
    // hands the extent to the observer (the credit ack).
    var collector = ExtentCollector{};
    const freed = try gateway_endpoint.body_pool.drainReleasedChunksObserved(&collector, ExtentCollector.observe);
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expectEqual(@as(usize, 1), collector.count);
    try std.testing.expectEqual(handle, collector.extents[0].handle);
    try std.testing.expectEqual(@as(usize, 0), (try gateway_endpoint.body_pool.usage()).used);
}

test "egress shared body pool hole punch reclaims pages and keeps neighbors readable" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    var block: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    @memset(&block, 0xa1);
    const left = try gateway_endpoint.body_pool.writeChunk(&block);
    @memset(&block, 0xb2);
    const middle = try gateway_endpoint.body_pool.writeChunk(&block);
    @memset(&block, 0xc3);
    const right = try gateway_endpoint.body_pool.writeChunk(&block);

    const resident_before = (try std.posix.fstat(gateway_endpoint.body_pool.data_fd)).blocks;
    try worker_endpoint.body_pool.releaseChunk(middle, block.len);
    var collector = ExtentCollector{};
    try std.testing.expectEqual(@as(usize, 1), try gateway_endpoint.body_pool.drainReleasedChunksObserved(&collector, ExtentCollector.observe));
    try gateway_endpoint.body_pool.punchFreeRange(
        @intCast(collector.extents[0].block_index),
        @intCast(collector.extents[0].block_count),
    );
    const resident_after = (try std.posix.fstat(gateway_endpoint.body_pool.data_fd)).blocks;
    try std.testing.expect(resident_after < resident_before);

    // Published neighbors are untouched.
    var readback: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    try worker_endpoint.body_pool.copyChunk(left, &readback);
    try std.testing.expect(std.mem.allEqual(u8, &readback, 0xa1));
    try worker_endpoint.body_pool.copyChunk(right, &readback);
    try std.testing.expect(std.mem.allEqual(u8, &readback, 0xc3));

    // Punching an occupied range is refused.
    try std.testing.expectError(
        error.InvalidEgressSharedRing,
        gateway_endpoint.body_pool.punchFreeRange(0, ipc.egress_shared.body_pool_block_count),
    );

    // The punched block is reusable and readable after a new write.
    @memset(&block, 0xd4);
    const reused = try gateway_endpoint.body_pool.writeChunk(&block);
    try worker_endpoint.body_pool.copyChunk(reused, &readback);
    try std.testing.expect(std.mem.allEqual(u8, &readback, 0xd4));
}

test "egress shared body pool releases chunks out of order" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    const first = try gateway_endpoint.body_pool.writeChunk("first");
    const second = try gateway_endpoint.body_pool.writeChunk("second");
    const third = try gateway_endpoint.body_pool.writeChunk("third");
    try std.testing.expectEqual(
        ipc.egress_shared.body_pool_block_size * 3,
        (try gateway_endpoint.body_pool.usage()).used,
    );

    try worker_endpoint.body_pool.releaseChunk(second, "second".len);
    try worker_endpoint.body_pool.releaseChunk(third, "third".len);
    try gateway_endpoint.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(
        ipc.egress_shared.body_pool_block_size,
        (try gateway_endpoint.body_pool.usage()).used,
    );

    var buffer: [5]u8 = undefined;
    try worker_endpoint.body_pool.copyChunk(first, &buffer);
    try std.testing.expectEqualStrings("first", &buffer);
    try worker_endpoint.body_pool.releaseChunk(first, buffer.len);
    try gateway_endpoint.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(@as(usize, 0), (try gateway_endpoint.body_pool.usage()).used);
}

test "egress shared body pool transaction splits fragmented chunks" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    var block: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    @memset(&block, 0x5a);
    var handles: [ipc.egress_shared.body_pool_slot_count]ipc.egress_shared.BodyPoolHandle = undefined;
    for (&handles) |*handle| {
        handle.* = try gateway_endpoint.body_pool.writeChunk(&block);
    }
    for (handles, 0..) |handle, index| {
        if (index % 2 == 1)
            try worker_endpoint.body_pool.releaseChunk(handle, block.len);
    }
    try gateway_endpoint.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(
        ipc.egress_shared.body_pool_capacity / 2,
        (try gateway_endpoint.body_pool.usage()).used,
    );

    var payload: [ipc.egress_shared.body_pool_block_size * 2]u8 = undefined;
    @memset(payload[0..ipc.egress_shared.body_pool_block_size], 0x11);
    @memset(payload[ipc.egress_shared.body_pool_block_size..], 0x22);
    var transaction = try gateway_endpoint.body_pool.beginWriteTransaction();
    var committed = false;
    defer if (!committed) transaction.rollback();

    var segments_storage: [2]ipc.egress_shared.BodyPoolWriteTransaction.Segment = undefined;
    const segments = try transaction.writeChunkContiguousSegments(&payload, segments_storage[0..]);
    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_size, segments[0].len);
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_size, segments[1].len);
    try transaction.publish();

    var first: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    var second: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    try worker_endpoint.body_pool.copyChunk(segments[0].seq, &first);
    try worker_endpoint.body_pool.copyChunk(segments[1].seq, &second);
    try std.testing.expect(std.mem.allEqual(u8, &first, 0x11));
    try std.testing.expect(std.mem.allEqual(u8, &second, 0x22));
    transaction.commit();
    committed = true;

    try worker_endpoint.body_pool.releaseChunk(segments[0].seq, segments[0].len);
    try worker_endpoint.body_pool.releaseChunk(segments[1].seq, segments[1].len);
    for (handles, 0..) |handle, index| {
        if (index % 2 == 0)
            try worker_endpoint.body_pool.releaseChunk(handle, block.len);
    }
    try gateway_endpoint.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(@as(usize, 0), (try gateway_endpoint.body_pool.usage()).used);
}

test "egress shared endpoint enforces worker and gateway sides" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    var scratch: [16]u8 = undefined;
    try std.testing.expectError(error.EgressSharedWrongSide, worker_endpoint.completion.writePacket("bad"));
    try std.testing.expectError(error.EgressSharedWrongSide, gateway_endpoint.command.writePacket("bad"));
    try std.testing.expectError(error.EgressSharedWrongSide, gateway_endpoint.completion.readPacket(&scratch));
    try std.testing.expectError(error.EgressSharedWrongSide, worker_endpoint.body_pool.writeChunk("bad"));
    try std.testing.expectError(error.EgressSharedWrongSide, gateway_endpoint.body_pool.copyChunk(0, scratch[0..1]));
}

test "egress shared liveness survives server handoff fds closing" {
    var session_fds = try createEgressSession();
    defer session_fds.deinit();

    var gateway_raw = try dupEgressRawFds(session_fds.rawForGateway());
    errdefer gateway_raw.close();
    var worker_raw = try dupEgressRawFds(session_fds.rawForWorker());
    errdefer worker_raw.close();

    session_fds.deinit();

    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);

    try std.testing.expect(!try fdHasHangup(gateway_endpoint.peer_liveness_fd));
    try std.testing.expect(!try fdHasHangup(worker_endpoint.liveness_fd));

    worker_endpoint.deinit();
    try std.testing.expect(try fdHasHangup(gateway_endpoint.peer_liveness_fd));
}

test "egress command ring reserves capacity for control packets" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer endpoint.deinit();

    var filler: [4096]u8 = undefined;
    @memset(&filler, 0xaa);
    while (true) {
        _ = endpoint.command.writePacketReserved(&filler, ipc.egress_shared.command_control_reserve_bytes) catch |err| switch (err) {
            error.EgressSharedRingFull => break,
            else => return err,
        };
    }

    var control = [_]u8{ 1, 2, 3, 4 };
    _ = try endpoint.command.writePacket(&control);
}

test "egress shared ring reports empty transition for eventfd coalescing" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    const first_write = try worker_endpoint.command.writePacket("one");
    try std.testing.expect(first_write.ring_was_empty);
    const second_write = try worker_endpoint.command.writePacket("two");
    try std.testing.expect(!second_write.ring_was_empty);

    var scratch: [16]u8 = undefined;
    const first = (try gateway_endpoint.command.readPacket(&scratch)).?;
    try std.testing.expectEqualStrings("one", first);
    const second = (try gateway_endpoint.command.readPacket(&scratch)).?;
    try std.testing.expectEqualStrings("two", second);

    const third_write = try worker_endpoint.command.writePacket("three");
    try std.testing.expect(third_write.ring_was_empty);
}

test "egress shared control mappings are directional" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(worker_endpoint.command.meta_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(worker_endpoint.command.consumer_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(worker_endpoint.completion.meta_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(worker_endpoint.completion.producer_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(worker_endpoint.body_pool.meta_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(worker_endpoint.body_pool.producer_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(gateway_endpoint.command.producer_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(gateway_endpoint.completion.consumer_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
}

test "egress shared consumer data mappings cannot be upgraded writable" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(worker_endpoint.completion.data_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(worker_endpoint.body_pool.data_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
    try std.testing.expectError(
        error.AccessDenied,
        std.posix.mprotect(gateway_endpoint.command.data_bytes, std.posix.PROT.READ | std.posix.PROT.WRITE),
    );
}

test "egress shared mapper rejects writable fds in read-only slots" {
    var fds = try createEgressSession();
    defer fds.deinit();

    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    defer worker_raw.close();
    const gateway_source = fds.rawForGateway();
    var writable_consumer = try fd_mod.OwnedFd.dupCloexec(gateway_source.command_consumer_fd);
    std.posix.close(worker_raw.command_consumer_fd);
    worker_raw.command_consumer_fd = writable_consumer.release();
    try std.testing.expectError(error.InvalidEgressSharedFdAccess, ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw));

    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    defer gateway_raw.close();
    const worker_source = fds.rawForWorker();
    var writable_producer = try fd_mod.OwnedFd.dupCloexec(worker_source.command_producer_fd);
    std.posix.close(gateway_raw.command_producer_fd);
    gateway_raw.command_producer_fd = writable_producer.release();
    try std.testing.expectError(error.InvalidEgressSharedFdAccess, ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw));
}

test "egress shared endpoint validates session metadata across planes" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();
    gateway_endpoint.command.setSession(7, 7);
    gateway_endpoint.completion.setSession(7, 7);
    gateway_endpoint.body_pool.setSession(7, 7);
    gateway_endpoint.upload_pool.setSession(7, 7);

    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    try worker_endpoint.validateConsistentSession();

    var other_fds = try createEgressSession();
    defer other_fds.deinit();
    var other_gateway_raw = try dupEgressRawFds(other_fds.rawForGateway());
    var other_gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&other_gateway_raw);
    defer other_gateway_endpoint.deinit();
    other_gateway_endpoint.command.setSession(8, 8);
    other_gateway_endpoint.completion.setSession(8, 8);
    other_gateway_endpoint.body_pool.setSession(8, 8);
    other_gateway_endpoint.upload_pool.setSession(8, 8);

    var mixed_raw = try dupEgressRawFds(fds.rawForWorker());
    defer mixed_raw.close();
    var donor_raw = try dupEgressRawFds(other_fds.rawForWorker());
    defer donor_raw.close();
    std.posix.close(mixed_raw.body_pool_control_fd);
    std.posix.close(mixed_raw.body_pool_producer_fd);
    std.posix.close(mixed_raw.body_pool_consumer_fd);
    std.posix.close(mixed_raw.body_pool_data_fd);
    mixed_raw.body_pool_control_fd = donor_raw.body_pool_control_fd;
    mixed_raw.body_pool_producer_fd = donor_raw.body_pool_producer_fd;
    mixed_raw.body_pool_consumer_fd = donor_raw.body_pool_consumer_fd;
    mixed_raw.body_pool_data_fd = donor_raw.body_pool_data_fd;
    donor_raw.body_pool_control_fd = -1;
    donor_raw.body_pool_producer_fd = -1;
    donor_raw.body_pool_consumer_fd = -1;
    donor_raw.body_pool_data_fd = -1;

    var mixed_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&mixed_raw);
    defer mixed_endpoint.deinit();
    try std.testing.expectError(error.InvalidEgressSharedEndpoint, mixed_endpoint.validateConsistentSession());
}

test "egress shared body pool stale release marks only that endpoint fatal" {
    var first_fds = try createEgressSession();
    defer first_fds.deinit();
    var first_worker_raw = try dupEgressRawFds(first_fds.rawForWorker());
    var first_worker = try ipc.egress_shared.mapEndpointTakeForWorker(&first_worker_raw);
    defer first_worker.deinit();
    var first_gateway_raw = try dupEgressRawFds(first_fds.rawForGateway());
    var first_gateway = try ipc.egress_shared.mapEndpointTakeForGateway(&first_gateway_raw);
    defer first_gateway.deinit();

    var second_fds = try createEgressSession();
    defer second_fds.deinit();
    var second_worker_raw = try dupEgressRawFds(second_fds.rawForWorker());
    var second_worker = try ipc.egress_shared.mapEndpointTakeForWorker(&second_worker_raw);
    defer second_worker.deinit();
    var second_gateway_raw = try dupEgressRawFds(second_fds.rawForGateway());
    var second_gateway = try ipc.egress_shared.mapEndpointTakeForGateway(&second_gateway_raw);
    defer second_gateway.deinit();

    const first_seq = try first_gateway.body_pool.writeChunk("first");
    try first_worker.body_pool.releaseChunk(first_seq, "first".len);
    try first_gateway.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(@as(usize, 0), (try first_gateway.body_pool.usage()).used);
    try std.testing.expectError(error.InvalidEgressSharedRing, first_worker.body_pool.releaseChunk(first_seq, "first".len));
    try std.testing.expectEqual(ipc.egress_shared.FatalState.ring_corrupt, first_worker.body_pool.fatalState());
    try std.testing.expectError(error.EgressSharedRingFatal, first_gateway.body_pool.usage());

    const second_seq = try second_gateway.body_pool.writeChunk("alive");
    var buffer: [5]u8 = undefined;
    try second_worker.body_pool.copyChunk(second_seq, &buffer);
    try std.testing.expectEqualStrings("alive", &buffer);
    try second_worker.body_pool.releaseChunk(second_seq, buffer.len);
    try std.testing.expectEqual(ipc.egress_shared.FatalState.none, second_worker.body_pool.fatalState());
}

test "an upload pool write cursor the worker sets to its maximum marks the pool corrupt instead of overflowing" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    const handle = try worker_endpoint.upload_pool.writeChunk("upload");
    try std.testing.expectEqualStrings("upload", try gateway_endpoint.upload_pool.borrowContiguousChunk(handle, "upload".len));
    // The worker maps the release queue writable. Equal cursors pass the
    // queue's room checks, so only the step past the maximum is left.
    const queue = worker_endpoint.upload_pool.consumer;
    @atomicStore(u64, &queue.release_read_seq, std.math.maxInt(u64), .release);
    @atomicStore(u64, &queue.release_write_seq, std.math.maxInt(u64), .release);

    try std.testing.expectError(
        error.InvalidEgressSharedRing,
        gateway_endpoint.upload_pool.releaseChunk(handle, "upload".len),
    );
    try std.testing.expectEqual(ipc.egress_shared.FatalState.ring_corrupt, gateway_endpoint.upload_pool.fatalState());
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), @atomicLoad(u64, &queue.release_write_seq, .acquire));
}

test "a body pool read cursor the worker rewinds replays a freed release into a corrupt pool, never a second free" {
    var fds = try createEgressSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();

    const handle = try gateway_endpoint.body_pool.writeChunk("first");
    try worker_endpoint.body_pool.releaseChunk(handle, "first".len);
    try gateway_endpoint.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_count, gateway_endpoint.body_pool.freeBlocks());

    // The worker writes the drained release back into the entry the drain
    // cleared and rewinds the gateway's read cursor over it.
    const queue = worker_endpoint.body_pool.consumer;
    queue.releases[0].handle = handle;
    queue.releases[0].len = "first".len;
    @atomicStore(u64, &queue.release_read_seq, 0, .release);

    try std.testing.expectError(error.InvalidEgressSharedRing, gateway_endpoint.body_pool.drainReleasedChunks());
    try std.testing.expectEqual(ipc.egress_shared.FatalState.ring_corrupt, gateway_endpoint.body_pool.fatalState());
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_count, gateway_endpoint.body_pool.freeBlocks());
}

test "egress shared command ring corruption is isolated to offending worker endpoint" {
    var first_fds = try createEgressSession();
    defer first_fds.deinit();
    var first_worker_raw = try dupEgressRawFds(first_fds.rawForWorker());
    var first_worker = try ipc.egress_shared.mapEndpointTakeForWorker(&first_worker_raw);
    defer first_worker.deinit();
    var first_gateway_raw = try dupEgressRawFds(first_fds.rawForGateway());
    var first_gateway = try ipc.egress_shared.mapEndpointTakeForGateway(&first_gateway_raw);
    defer first_gateway.deinit();

    var second_fds = try createEgressSession();
    defer second_fds.deinit();
    var second_worker_raw = try dupEgressRawFds(second_fds.rawForWorker());
    var second_worker = try ipc.egress_shared.mapEndpointTakeForWorker(&second_worker_raw);
    defer second_worker.deinit();
    var second_gateway_raw = try dupEgressRawFds(second_fds.rawForGateway());
    var second_gateway = try ipc.egress_shared.mapEndpointTakeForGateway(&second_gateway_raw);
    defer second_gateway.deinit();

    @atomicStore(u64, &first_worker.command.producer.write_seq, ipc.egress_shared.command_ring_capacity + 1, .release);
    var scratch: [32]u8 = undefined;
    try std.testing.expectError(error.InvalidEgressSharedRing, first_gateway.command.readPacket(&scratch));
    try std.testing.expectEqual(ipc.egress_shared.FatalState.ring_corrupt, first_gateway.command.fatalState());

    _ = try second_worker.command.writePacket("ok");
    const packet = (try second_gateway.command.readPacket(&scratch)).?;
    try std.testing.expectEqualStrings("ok", packet);
    try std.testing.expectEqual(ipc.egress_shared.FatalState.none, second_gateway.command.fatalState());
}

test "egress shared completion ring full does not poison another worker endpoint" {
    var first_fds = try createEgressSession();
    defer first_fds.deinit();
    var first_gateway_raw = try dupEgressRawFds(first_fds.rawForGateway());
    var first_gateway = try ipc.egress_shared.mapEndpointTakeForGateway(&first_gateway_raw);
    defer first_gateway.deinit();

    var second_fds = try createEgressSession();
    defer second_fds.deinit();
    var second_gateway_raw = try dupEgressRawFds(second_fds.rawForGateway());
    var second_gateway = try ipc.egress_shared.mapEndpointTakeForGateway(&second_gateway_raw);
    defer second_gateway.deinit();

    var filler: [4096]u8 = undefined;
    @memset(&filler, 0xee);
    var observed_full = false;
    while (true) {
        _ = first_gateway.completion.writePacket(&filler) catch |err| switch (err) {
            error.EgressSharedRingFull => {
                observed_full = true;
                break;
            },
            else => return err,
        };
    }

    try std.testing.expect(observed_full);
    _ = try second_gateway.completion.writePacket("still-alive");
    try std.testing.expectEqual(ipc.egress_shared.FatalState.none, first_gateway.completion.fatalState());
    try std.testing.expectEqual(ipc.egress_shared.FatalState.none, second_gateway.completion.fatalState());
}

test "egress gateway IPC packets round trip without fd transfer" {
    var scratch: [max_message_bytes]u8 = undefined;
    const headers = [_]RequestHeader{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "x-demo", .value = "yes" },
    };

    const token = requestTokenBytes(22, 33);
    const start_bytes = try ipc.encodeEgressFetchStartInto(&scratch, .{
        .fetch_id = 11,
        .egress_token = token,
        .body_id = 44,
        .flags = 0,
        .method = "POST",
        .url = "https://example.test/api",
        .headers = &headers,
        .body = "hello",
    });
    const start = try ipc.decodeEgressFetchStart(&gateway_decode_scratch, start_bytes);
    try std.testing.expectEqual(@as(u64, 11), start.fetch_id);
    try std.testing.expectEqualSlices(u8, &token, &start.egress_token);
    try std.testing.expectEqual(@as(u64, 44), start.body_id);
    try std.testing.expectEqual(@as(u32, 0), start.flags);
    try std.testing.expectEqualStrings("POST", start.method);
    try std.testing.expectEqualStrings("https://example.test/api", start.url);
    try std.testing.expectEqualStrings("x-demo", start.headers[1].name);
    try std.testing.expectEqualStrings("yes", start.headers[1].value);
    try std.testing.expectEqualStrings("hello", start.body);

    const head_bytes = try ipc.encodeEgressFetchHeadInto(&scratch, .{
        .fetch_id = 11,
        .body_id = 44,
        .status = 201,
        .flags = ipc.egress_fetch_head_flag_redirected,
        .status_text = "Created",
        .url = "https://example.test/api",
        .headers = &headers,
    });
    const head = try ipc.decodeEgressFetchHead(&worker_decode_scratch, head_bytes);
    try std.testing.expectEqual(@as(u16, 201), head.status);
    try std.testing.expectEqual(ipc.egress_fetch_head_flag_redirected, head.flags);
    try std.testing.expectEqualStrings("Created", head.status_text);
    try std.testing.expectEqualStrings("accept", head.headers[0].name);

    var bad_head_bytes = try ipc.encodeEgressFetchHeadInto(&scratch, .{
        .fetch_id = 11,
        .body_id = 44,
        .status = 200,
        .flags = ipc.egress_fetch_head_flag_redirected,
        .status_text = "OK",
        .url = "https://example.test/api",
        .headers = &headers,
    });
    const bad_flags_offset = @offsetOf(ipc.EgressFetchHeadHeader, "flags");
    const invalid_flags: u32 = ipc.valid_egress_fetch_head_flags << 1;
    @memcpy(bad_head_bytes[bad_flags_offset..][0..@sizeOf(u32)], std.mem.asBytes(&invalid_flags));
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchHead(&worker_decode_scratch, bad_head_bytes));

    const batch_bytes = try ipc.encodeEgressBodyChunkBatchInto(&scratch, .{ .chunks = &.{
        .{
            .fetch_id = 11,
            .body_id = 44,
            .body_pool_offset = 777,
            .len = 5,
        },
        .{
            .fetch_id = 11,
            .body_id = 44,
            .body_pool_offset = 782,
            .len = 7,
        },
    } });
    const batch = try ipc.decodeEgressBodyChunkBatch(&worker_decode_scratch, batch_bytes);
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expectEqual(@as(u64, 777), batch[0].body_pool_offset);
    try std.testing.expectEqual(@as(usize, 7), batch[1].len);
    try std.testing.expectEqual(@as(u64, 782), batch[1].body_pool_offset);

    var bad_chunk_bytes: [@sizeOf(ipc.EgressBodyChunkBatchHeader) + @sizeOf(ipc.EgressBodyChunkBatchDescriptor)]u8 = undefined;
    @memcpy(bad_chunk_bytes[0..@sizeOf(ipc.EgressBodyChunkBatchHeader)], batch_bytes[0..@sizeOf(ipc.EgressBodyChunkBatchHeader)]);
    @memcpy(
        bad_chunk_bytes[@sizeOf(ipc.EgressBodyChunkBatchHeader)..],
        batch_bytes[@sizeOf(ipc.EgressBodyChunkBatchHeader)..][0..@sizeOf(ipc.EgressBodyChunkBatchDescriptor)],
    );
    const one_chunk: u32 = 1;
    @memcpy(bad_chunk_bytes[@offsetOf(ipc.EgressBodyChunkBatchHeader, "count")..][0..@sizeOf(u32)], std.mem.asBytes(&one_chunk));
    const nonzero_reserved: u32 = 1;
    const reserved_offset = @sizeOf(ipc.EgressBodyChunkBatchHeader) + @offsetOf(ipc.EgressBodyChunkBatchDescriptor, "_reserved0");
    @memcpy(bad_chunk_bytes[reserved_offset..][0..@sizeOf(u32)], std.mem.asBytes(&nonzero_reserved));
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressBodyChunkBatch(&worker_decode_scratch, &bad_chunk_bytes));

    const end_message = ipc.EgressBodyEnd.init(11, 44);
    const end = try ipc.decodeEgressBodyEnd(std.mem.asBytes(&end_message));
    try std.testing.expectEqual(@as(u64, 11), end.fetch_id);
    try std.testing.expectEqual(@as(u64, 44), end.body_id);

    var bad_end_message = end_message;
    bad_end_message._reserved0 = 1;
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressBodyEnd(std.mem.asBytes(&bad_end_message)));

    const error_bytes = try ipc.encodeEgressFetchErrorInto(&scratch, .{
        .fetch_id = 11,
        .body_id = 44,
        .message = "blocked",
    });
    const failure = try ipc.decodeEgressFetchError(error_bytes);
    try std.testing.expectEqualStrings("blocked", failure.message);
    try std.testing.expectEqual(@as(u64, 11), failure.fetch_id);

    const abort_ack_message = ipc.EgressAbortAck.init(11, 44);
    const abort_ack = try ipc.decodeEgressAbortAck(std.mem.asBytes(&abort_ack_message));
    try std.testing.expectEqual(@as(u64, 11), abort_ack.fetch_id);
    try std.testing.expectEqual(@as(u64, 44), abort_ack.body_id);

    var bad_abort_ack_message = abort_ack_message;
    bad_abort_ack_message._reserved0 = 1;
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressAbortAck(std.mem.asBytes(&bad_abort_ack_message)));
}

test "the fetch start header keeps its pinned size and offsets, with the egress token last" {
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(ipc.EgressFetchStartHeader));
    try std.testing.expectEqual(
        @sizeOf(ipc.EgressFetchStartHeader),
        ipc.fetch_limits.request_start_header_bytes,
    );
    try expectOffset(ipc.EgressFetchStartHeader, "fetch_id", 8);
    try expectOffset(ipc.EgressFetchStartHeader, "body_id", 16);
    try expectOffset(ipc.EgressFetchStartHeader, "method_len", 24);
    try expectOffset(ipc.EgressFetchStartHeader, "request_headers_bytes_len", 36);
    try expectOffset(ipc.EgressFetchStartHeader, "body_len", 40);
    try expectOffset(ipc.EgressFetchStartHeader, "egress_token", 48);
    try std.testing.expectEqual(
        @sizeOf(ipc.EgressFetchStartHeader),
        @offsetOf(ipc.EgressFetchStartHeader, "egress_token") + egress_token.token_bytes,
    );
}

test "the fetch start decoder copies the token, so later writes to the packet do not reach it" {
    var scratch: [max_message_bytes]u8 = undefined;
    const token = requestTokenBytes(5, 6);
    const start_bytes = try ipc.encodeEgressFetchStartInto(&scratch, .{
        .fetch_id = 1,
        .egress_token = token,
        .body_id = 2,
        .method = "GET",
        .url = "https://example.test/",
        .headers = &.{},
        .body = "",
    });
    const token_offset = @offsetOf(ipc.EgressFetchStartHeader, "egress_token");
    const token_in_packet = start_bytes[token_offset..][0..egress_token.token_bytes];
    try std.testing.expectEqualSlices(u8, &token, token_in_packet);

    const start = try ipc.decodeEgressFetchStart(&gateway_decode_scratch, start_bytes);
    // The worker can still write the ring slot the packet came from; the
    // gateway verifies the copy it decoded.
    @memset(token_in_packet, 0xff);
    try std.testing.expectEqualSlices(u8, &token, &start.egress_token);
}

test "egress gateway fetch start config reserves envelope bytes inside shared packet" {
    var scratch: [max_message_bytes]u8 = undefined;
    const method = "MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM";
    const url = try std.testing.allocator.alloc(u8, ipc.fetch_limits.request_url_bytes_max);
    defer std.testing.allocator.free(url);
    @memset(url, 'u');
    const header_value_len = ipc.fetch_limits.request_headers_bytes_max -
        @sizeOf(ipc.messages.NameValuePacket) -
        1;
    const header_value = try std.testing.allocator.alloc(u8, header_value_len);
    defer std.testing.allocator.free(header_value);
    @memset(header_value, 'h');
    const headers = [_]RequestHeader{.{ .name = "x", .value = header_value }};

    const body = try std.testing.allocator.alloc(u8, ipc.fetch_limits.request_body_inline_bytes_max);
    defer std.testing.allocator.free(body);
    @memset(body, 0xaa);

    const exact = try ipc.encodeEgressFetchStartInto(&scratch, .{
        .fetch_id = 1,
        .egress_token = requestTokenBytes(2, 3),
        .body_id = 5,
        .flags = 0,
        .method = method,
        .url = url,
        .headers = &headers,
        .body = body,
    });
    try std.testing.expectEqual(ipc.fetch_limits.request_packet_bytes_max, exact.len);

    const too_large_body = try std.testing.allocator.alloc(
        u8,
        ipc.fetch_limits.request_body_inline_bytes_max + 1,
    );
    defer std.testing.allocator.free(too_large_body);
    try std.testing.expectError(error.EgressGatewayRequestBodyLimitExceeded, ipc.encodeEgressFetchStartInto(&scratch, .{
        .fetch_id = 1,
        .egress_token = requestTokenBytes(2, 3),
        .body_id = 5,
        .flags = 0,
        .method = "POST",
        .url = "https://example.test/upload",
        .headers = &.{},
        .body = too_large_body,
    }));
}

test "egress gateway fetch decoders enforce structural byte caps" {
    var scratch: [max_message_bytes]u8 = undefined;

    var start_bytes = try ipc.encodeEgressFetchStartInto(&scratch, .{
        .fetch_id = 1,
        .egress_token = requestTokenBytes(2, 3),
        .body_id = 5,
        .flags = 0,
        .method = "GET",
        .url = "https://example.test/",
        .headers = &.{},
        .body = "",
    });
    const oversized_method_len: u32 = @intCast(ipc.fetch_limits.request_method_bytes_max + 1);
    @memcpy(
        start_bytes[@offsetOf(ipc.EgressFetchStartHeader, "method_len")..][0..@sizeOf(u32)],
        std.mem.asBytes(&oversized_method_len),
    );
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchStart(&gateway_decode_scratch, start_bytes));

    var head_bytes = try ipc.encodeEgressFetchHeadInto(&scratch, .{
        .fetch_id = 1,
        .body_id = 5,
        .flags = 0,
        .status = 200,
        .status_text = "OK",
        .url = "https://example.test/",
        .headers = &.{},
    });
    const oversized_status_len: u32 = @intCast(ipc.fetch_limits.response_status_text_bytes_max + 1);
    @memcpy(
        head_bytes[@offsetOf(ipc.EgressFetchHeadHeader, "status_text_len")..][0..@sizeOf(u32)],
        std.mem.asBytes(&oversized_status_len),
    );
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchHead(&worker_decode_scratch, head_bytes));
}

test "egress gateway fetch start rejects unknown flags" {
    var scratch: [max_message_bytes]u8 = undefined;
    const start_bytes = try ipc.encodeEgressFetchStartInto(&scratch, .{
        .fetch_id = 1,
        .egress_token = requestTokenBytes(2, 3),
        .body_id = 5,
        // Only the unknown bit: body_pooled (a now-valid flag) with an empty
        // pooled body is rejected at encode time, so blanket-setting the
        // valid mask would never reach the decoder.
        .flags = 1 << 16,
        .method = "GET",
        .url = "https://example.test/",
        .headers = &.{},
        .body = "",
    });
    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchStart(&gateway_decode_scratch, start_bytes));
}

test "egress gateway fetch start rejects malformed header field lengths" {
    var scratch: [max_message_bytes]u8 = undefined;
    var start_bytes = try ipc.encodeEgressFetchStartInto(&scratch, .{
        .fetch_id = 1,
        .egress_token = requestTokenBytes(2, 3),
        .body_id = 5,
        .flags = 0,
        .method = "GET",
        .url = "https://example.test/",
        .headers = &.{.{ .name = "x", .value = "y" }},
        .body = "",
    });

    const header = ipc.packet.readStruct(ipc.EgressFetchStartHeader, start_bytes[0..@sizeOf(ipc.EgressFetchStartHeader)]);
    const header_storage_start =
        @sizeOf(ipc.EgressFetchStartHeader) +
        @as(usize, @intCast(header.method_len)) +
        @as(usize, @intCast(header.url_len));
    const bad_name_len = header.request_headers_bytes_len;
    const bad_value_len: u32 = 1;
    @memcpy(
        start_bytes[header_storage_start + @offsetOf(ipc.messages.NameValuePacket, "name_len") ..][0..@sizeOf(u32)],
        std.mem.asBytes(&bad_name_len),
    );
    @memcpy(
        start_bytes[header_storage_start + @offsetOf(ipc.messages.NameValuePacket, "value_len") ..][0..@sizeOf(u32)],
        std.mem.asBytes(&bad_value_len),
    );

    try std.testing.expectError(error.InvalidEgressPacket, ipc.decodeEgressFetchStart(&gateway_decode_scratch, start_bytes));
}

test "invalid message kind is rejected" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const bad = ZygoteReady{ .kind = 99 };
    try sendExact(pair[0], std.mem.asBytes(&bad));
    try std.testing.expectError(error.InvalidMessageKind, recvZygoteReady(pair[1]));
}

test "no-fd packet receive rejects ancillary data" {
    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    const fd_pair = try fd_mod.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(fd_pair[0]);
    defer std.posix.close(fd_pair[1]);

    const ready = ZygoteReady{ .kind = @intFromEnum(MessageKind.zygote_ready) };
    try sendWithFds(control_pair[0], std.mem.asBytes(&ready), &.{fd_pair[0]});
    try std.testing.expectError(error.UnexpectedAncillaryData, recvZygoteReady(control_pair[1]));
}

test "message kind 8 names no message and does not decode" {
    // A request's completion is a descriptor of the ingress channel
    // (`request_done`), so a peer that sends kind 8 is broken.
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(8));
}

test "message kinds 9 and 10 name no message and do not decode" {
    // A worker resolves every `import()` from the packs it registered, so no
    // module travels on the control channel and a peer that sends either kind
    // is broken.
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(9));
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(10));
}

test "message kinds 24 and 25 name no message, like the other holes and the next unassigned value" {
    // A worker reads its files with plain syscalls, so no file request or
    // answer travels between processes and a peer that sends either kind is
    // broken. Kinds 8, 9 and 10 have tests of their own,
    // `ipc/egress_attach.zig` pins 26, `ipc/worker_retiring.zig` pins 27 and
    // `ipc/response_credit.zig` pins 28.
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(24));
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(25));
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(13));
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(21));
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(22));
    try std.testing.expectError(error.InvalidMessageKind, ipc.decodeMessageKind(29));
}

fn writeControlMessageHeader(
    control: []align(@alignOf(cmsg.Cmsghdr)) u8,
    offset: usize,
    level: c_int,
    message_type: c_int,
    payload_len: usize,
) void {
    const header: *cmsg.Cmsghdr = @ptrCast(@alignCast(control[offset..].ptr));
    header.* = .{
        .len = cmsg.len(payload_len),
        .level = level,
        .type = message_type,
    };
}

fn writeRightsControlMessage(
    control: []align(@alignOf(cmsg.Cmsghdr)) u8,
    offset: usize,
    fds: []const std.posix.fd_t,
) void {
    const payload_len = @sizeOf(std.posix.fd_t) * fds.len;
    writeControlMessageHeader(control, offset, std.posix.SOL.SOCKET, cmsg.scm_rights, payload_len);
    const payload_start = offset + cmsg.dataOffset();
    const fd_ptr: [*]std.posix.fd_t = @ptrCast(@alignCast(control[payload_start..].ptr));
    for (fds, 0..) |fd, index|
        fd_ptr[index] = fd;
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    try fd_mod.writeAllRaw(fd, bytes);
}

fn writeStruct(dest: []u8, value: anytype) usize {
    const bytes = std.mem.asBytes(value);
    @memcpy(dest[0..bytes.len], bytes);
    return bytes.len;
}

fn writeSlice(dest: []u8, value: []const u8) usize {
    @memcpy(dest[0..value.len], value);
    return value.len;
}

fn sendExact(fd: std.posix.fd_t, bytes: []const u8) !void {
    const written = try sendCompat(fd, bytes, std.posix.MSG.NOSIGNAL);
    if (written != bytes.len)
        return error.ShortWrite;
}

fn sendWithFds(fd: std.posix.fd_t, bytes: []const u8, fds: []const std.posix.fd_t) !void {
    if (fds.len == 0) {
        try sendExact(fd, bytes);
        return;
    }
    if (fds.len > max_fds_per_message)
        return error.TooManyFds;

    var control: [cmsg.space(@sizeOf(std.posix.fd_t) * max_fds_per_message)]u8 align(@alignOf(cmsg.Cmsghdr)) =
        std.mem.zeroes([cmsg.space(@sizeOf(std.posix.fd_t) * max_fds_per_message)]u8);
    writeRightsControlMessage(&control, 0, fds);

    const iov = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const msg = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = cmsg.space(@sizeOf(std.posix.fd_t) * fds.len),
        .flags = 0,
    };
    const written = try sendmsgCompat(fd, &msg, std.posix.MSG.NOSIGNAL);
    if (written != bytes.len)
        return error.ShortWrite;
}

fn sliceWithin(container: []const u8, slice: []const u8) bool {
    if (slice.len == 0)
        return true;
    const base = @intFromPtr(container.ptr);
    const end = base + container.len;
    const ptr = @intFromPtr(slice.ptr);
    return ptr >= base and ptr + slice.len <= end;
}

fn sendCompat(fd: std.posix.fd_t, bytes: []const u8, flags: u32) !usize {
    while (true) {
        const rc = std.c.send(fd, bytes.ptr, bytes.len, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF, .NOTSOCK => return error.InvalidHandle,
            .CONNRESET, .CONNREFUSED, .PIPE, .NOTCONN, .TIMEDOUT => return error.PeerClosed,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn sendmsgCompat(fd: std.posix.fd_t, msg: *const std.posix.msghdr_const, flags: u32) !usize {
    while (true) {
        const rc = std.c.sendmsg(fd, msg, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .BADF, .NOTSOCK => return error.InvalidHandle,
            .CONNRESET, .CONNREFUSED, .PIPE, .NOTCONN, .TIMEDOUT => return error.PeerClosed,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn recvmsgCompat(fd: std.posix.fd_t, msg: *std.posix.msghdr, flags: u32) !usize {
    while (true) {
        const rc = std.c.recvmsg(fd, msg, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF, .NOTSOCK => return error.InvalidHandle,
            .CONNRESET, .CONNREFUSED, .PIPE, .NOTCONN, .TIMEDOUT => return error.PeerClosed,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}
