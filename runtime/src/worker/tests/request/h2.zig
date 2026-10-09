//! Covers the worker's HTTP/2 ingress pieces that need no VM: the check of a
//! request-begin descriptor against its dispatch (`request/http2/ingress.zig`),
//! the refusal of a request begin that carries a file descriptor, the
//! identity a request context takes from its dispatch, and the inline
//! head-and-body batch planner (`request/http2/response.zig`). Runs in the
//! JSC-free `worker-fast-test` lane.

const std = @import("std");
const ipc = @import("collo_ipc");
const worker_request = @import("collo_worker_request");

const h2_ingress = worker_request.http2.ingress;
const h2_response = worker_request.http2.response;

fn dispatchWork() !ipc.DispatchWork {
    const headers = [_]ipc.RequestHeader{
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "content-type", .value = "text/plain" },
    };
    return ipc.DispatchWork.initOwned(std.testing.allocator, .{
        .request_id = 55,
        .request_generation = 9,
        .request_lane_id = 3,
        .request_slot = 12,
        .authority = "demo.example.test",
        .deadline_monotonic_ns = 0,
        .method = "POST",
        .path = "/",
        .raw_query = "",
        .request_headers = &headers,
        .body_framing = .ingress_channel,
        .route_captures = &.{},
        .route_index = 0,
    });
}

fn identity() ipc.ingress_channel.RequestIdentity {
    return .{
        .request_id = 55,
        .request_generation = 9,
        .request_lane_id = 3,
        .request_slot = 12,
    };
}

fn responseIdentity() ipc.ingress_channel.RequestIdentity {
    return .{
        .request_id = 77,
        .request_generation = 3,
        .request_lane_id = 2,
        .request_slot = 9,
    };
}

test "worker validates h2 stream begin descriptor identity against dispatch payload" {
    var dispatch = try dispatchWork();
    defer dispatch.deinit();

    var descriptor = ipc.ingress_channel.Descriptor.requestBegin(identity(), 11, 0, 128, @intCast(dispatch.request_headers.len), false);
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    try h2_ingress.validateStreamBeginDescriptor(descriptor, &dispatch);

    var stream_zero = descriptor;
    stream_zero.stream_id = 0;
    try std.testing.expectError(error.InvalidH2StreamIdentity, h2_ingress.validateStreamBeginDescriptor(stream_zero, &dispatch));

    var wrong_request_id = descriptor;
    wrong_request_id.request_id += 1;
    try std.testing.expectError(error.InvalidH2StreamIdentity, h2_ingress.validateStreamBeginDescriptor(wrong_request_id, &dispatch));

    var wrong_generation = descriptor;
    wrong_generation.request_generation += 1;
    try std.testing.expectError(error.InvalidH2StreamIdentity, h2_ingress.validateStreamBeginDescriptor(wrong_generation, &dispatch));

    var wrong_header_count = descriptor;
    wrong_header_count.aux += 1;
    try std.testing.expectError(error.InvalidH2DispatchRequestHead, h2_ingress.validateStreamBeginDescriptor(wrong_header_count, &dispatch));
}

test "worker rejects invalid h2 stream begin descriptor shape" {
    var dispatch = try dispatchWork();
    defer dispatch.deinit();

    // A client opens only odd-numbered streams (RFC 9113 §5.1.1).
    var descriptor = ipc.ingress_channel.Descriptor.requestBegin(identity(), 10, 0, 128, @intCast(dispatch.request_headers.len), false);
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    try std.testing.expectError(error.InvalidH2StreamIdentity, h2_ingress.validateStreamBeginDescriptor(descriptor, &dispatch));

    // A request begin carries its head inline: the inline-bytes flag is
    // required and the shared-ring flag refused.
    descriptor = ipc.ingress_channel.Descriptor.requestBegin(identity(), 11, 0, 128, @intCast(dispatch.request_headers.len), false);
    try std.testing.expectError(error.InvalidH2WorkerInboundDescriptor, h2_ingress.validateStreamBeginDescriptor(descriptor, &dispatch));

    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes | ipc.ingress_channel.flags.shared_ring;
    try std.testing.expectError(error.InvalidH2WorkerInboundDescriptor, h2_ingress.validateStreamBeginDescriptor(descriptor, &dispatch));
}

test "worker refuses a stream begin whose dispatch carries no server request identity" {
    var dispatch = try dispatchWork();
    defer dispatch.deinit();

    // Descriptor and payload agree, so only the missing identity can fail
    // the check: generation 0 would make the request look like the boot
    // context.
    dispatch.request_generation = 0;
    var no_generation = identity();
    no_generation.request_generation = 0;
    var descriptor = ipc.ingress_channel.Descriptor.requestBegin(no_generation, 11, 0, 128, @intCast(dispatch.request_headers.len), false);
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    try std.testing.expectError(error.InvalidH2StreamIdentity, h2_ingress.validateStreamBeginDescriptor(descriptor, &dispatch));

    dispatch.request_generation = identity().request_generation;
    dispatch.request_id = 0;
    var no_request_id = identity();
    no_request_id.request_id = 0;
    descriptor = ipc.ingress_channel.Descriptor.requestBegin(no_request_id, 11, 0, 128, @intCast(dispatch.request_headers.len), false);
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    try std.testing.expectError(error.InvalidH2StreamIdentity, h2_ingress.validateStreamBeginDescriptor(descriptor, &dispatch));
}

test "a request begin that carries a file descriptor fails to decode and the descriptor is closed" {
    // A worker takes its definition's pack in WorkerInit, so both decoders the
    // worker's control loop uses refuse an ingress packet with a descriptor,
    // and consuming the packet closes it. The descriptor is a pipe's write
    // end: once the test has closed its own copy, the read end reports end of
    // file only if the decoder closed the copy it received.
    var dispatch = try dispatchWork();
    defer dispatch.deinit();
    const payload_scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(payload_scratch);
    var view = dispatch.view();
    const payload = try ipc.encodeDispatchWorkInto(payload_scratch, &view);
    const packet_scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(packet_scratch);
    const begin = ipc.ingress_channel.Descriptor.requestBegin(
        identity(),
        11,
        0,
        @intCast(payload.len),
        @intCast(dispatch.request_headers.len),
        true,
    );
    const encoded = try ipc.ingress_channel.encodeDescriptorPayloadInto(packet_scratch, begin, payload);

    var pair: [2]std.posix.fd_t = undefined;
    const socket_type = std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, socket_type, 0, &pair));
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer std.posix.close(pipe[0]);
    try ipc.packet.sendWithFds(pair[0], encoded, &.{pipe[1]});
    try ipc.packet.sendWithFds(pair[0], encoded, &.{pipe[1]});
    std.posix.close(pipe[1]);

    const allocator = std.testing.allocator;
    const receive_scratch = try allocator.alloc(u8, ipc.max_message_bytes);
    defer allocator.free(receive_scratch);
    var inline_packet = try ipc.recvPacketWithFdsScratch(allocator, pair[1], receive_scratch);
    try std.testing.expectEqual(@as(usize, 1), inline_packet.fd_count);
    try std.testing.expectError(
        error.InvalidPacket,
        ipc.ingress_channel.decodeReceivedPacket(allocator, &inline_packet),
    );
    var ring_packet = try ipc.recvPacketWithFdsScratch(allocator, pair[1], receive_scratch);
    try std.testing.expectEqual(@as(usize, 1), ring_packet.fd_count);
    try std.testing.expectError(
        error.InvalidPacket,
        ipc.ingress_channel.decodeReceivedPacketWithSharedPayload(allocator, &ring_packet, .{}),
    );

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(pipe[0], &byte));
}

test "a request context takes its stream and generation from the dispatch" {
    const headers = [_]ipc.RequestHeader{
        .{ .name = "host", .value = "demo.example.test" },
    };
    const dispatch = try ipc.DispatchWork.initOwned(std.testing.allocator, .{
        .request_id = 41,
        .request_generation = 5,
        .request_lane_id = 2,
        .request_slot = 3,
        .authority = "demo.example.test",
        .deadline_monotonic_ns = 0,
        .method = "GET",
        .path = "/",
        .raw_query = "",
        .request_headers = &headers,
        .body_framing = .ingress_channel,
        .route_captures = &.{},
        .route_index = 0,
    });

    // The context owns the dispatch from here on.
    var ctx = worker_request.context.RequestContext.initOwnedDispatch(
        std.testing.allocator,
        11,
        dispatch,
        .{ .index = 0, .generation = 1 },
        0,
    );
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u32, 11), ctx.ingress_channel_id);
    try std.testing.expectEqual(@as(u64, 5), ctx.request_generation);
    try std.testing.expectEqual(@as(u64, 41), ctx.exec.request_id);
    try std.testing.expectEqualStrings("demo.example.test", ctx.dispatch_work.authority);
}

test "worker h2 response planner batches small head and body descriptors" {
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var entries: [2]ipc.ingress_channel.BatchEntry = undefined;
    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "x-mode", .value = "h2" },
    };

    const planned = (try h2_response.tryEncodeInlineHeadBodyBatch(
        &scratch,
        responseIdentity(),
        13,
        201,
        &headers,
        "ok",
        ipc.ingress_channel.shared_payload_threshold,
        &entries,
    )) orelse return error.ExpectedInlineBatch;

    try std.testing.expectEqual(@as(usize, 2), planned.len);
    try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_head), planned[0].descriptor.op);
    try std.testing.expectEqual(@intFromEnum(ipc.ingress_channel.Op.response_chunk), planned[1].descriptor.op);
    try std.testing.expect(!planned[0].descriptor.hasFlag(ipc.ingress_channel.flags.end_stream));
    try std.testing.expect(planned[1].descriptor.hasFlag(ipc.ingress_channel.flags.end_stream));
    try std.testing.expectEqualStrings("ok", planned[1].payload);

    var decoded = try ipc.ingress_channel.decodeResponseHead(std.testing.allocator, planned[0].payload);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u16, 201), decoded.status);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("x-mode", decoded.headers[0].name);
    try std.testing.expectEqualStrings("h2", decoded.headers[0].value);
}

test "worker h2 response planner leaves head-only and large bodies to streaming path" {
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var entries: [2]ipc.ingress_channel.BatchEntry = undefined;

    try std.testing.expectEqual(@as(?[]const ipc.ingress_channel.BatchEntry, null), try h2_response.tryEncodeInlineHeadBodyBatch(
        &scratch,
        responseIdentity(),
        15,
        204,
        &.{},
        "",
        ipc.ingress_channel.shared_payload_threshold,
        &entries,
    ));

    const body = try std.testing.allocator.alloc(u8, ipc.ingress_channel.shared_payload_threshold + 1);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');
    try std.testing.expectEqual(@as(?[]const ipc.ingress_channel.BatchEntry, null), try h2_response.tryEncodeInlineHeadBodyBatch(
        &scratch,
        responseIdentity(),
        17,
        200,
        &.{},
        body,
        ipc.ingress_channel.shared_payload_threshold,
        &entries,
    ));
}
