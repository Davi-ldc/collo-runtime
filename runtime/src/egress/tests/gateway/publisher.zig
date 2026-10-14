//! Publication into a worker's endpoint (`egress/gateway/publisher.zig`) over a real shared-memory
//! endpoint: a body batch appears whole or not at all, and leaves no pool bytes behind when the
//! ring is full or the descriptor packet does not encode; an empty chunk is refused; extents
//! mirror descriptors, with each chunk's credit on its last extent; a chunk splits across a
//! fragmented pool and stays one extent otherwise; and completion-eventfd wakes coalesce while the
//! ring holds unread packets. The ring and the pool themselves are covered in
//! `common/tests/ipc.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");

const support = @import("support/gateway.zig");

const body_credit = @import("collo_egress_client").core.body_credit;
const publisher = gateway.publisher;

/// Shared by this file's tests, which run one at a time; a decoded batch points into it until
/// the next decode.
var test_decode_scratch: ipc.WorkerEgressDecodeScratch = .{};

const ExtentStorage = [ipc.egress_shared.body_pool_slot_count]publisher.PublishedExtent;

/// Both views of one session: the worker's, which reads what the gateway publishes, and the
/// gateway's, which publishes.
const Views = struct {
    worker: ipc.egress_shared.Endpoint,
    gateway: ipc.egress_shared.Endpoint,

    fn init() !Views {
        var fds = try support.createSession();
        defer fds.deinit();
        var worker_raw = try support.dupEgressRawFds(fds.rawForWorker());
        var worker = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
        errdefer worker.deinit();
        var gateway_raw = try support.dupEgressRawFds(fds.rawForGateway());
        const gateway_view = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
        return .{ .worker = worker, .gateway = gateway_view };
    }

    fn deinit(self: *Views) void {
        self.worker.deinit();
        self.gateway.deinit();
        self.* = undefined;
    }
};

test "a body batch commits its bytes and descriptors together, each extent mirroring its descriptor" {
    var views = try Views.init();
    defer views.deinit();

    const chunks = [_]publisher.BodyChunkPayload{
        .{ .bytes = "hello", .credit = body_credit.h2Data(1, 3, 5, true) },
        .{ .bytes = "world" },
    };
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    const result = try publisher.publishBodyChunkBatch(&views.gateway, 11, 22, &chunks, &scratch, &extents);
    try std.testing.expectEqual(@as(usize, 2), result.extents);

    var packet_buffer: [1024]u8 = undefined;
    const packet = (try views.worker.completion.readPacket(&packet_buffer)) orelse
        return error.MissingEgressBodyChunkBatch;
    const decoded = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(u64, 11), decoded[0].fetch_id);
    try std.testing.expectEqual(@as(u64, 22), decoded[0].body_id);
    try std.testing.expectEqual(@as(usize, 5), decoded[0].len);

    // Each extent matches its descriptor's handle and length, and a chunk that did not split
    // carries its credit on its only extent.
    for (decoded, extents[0..result.extents]) |descriptor, extent| {
        try std.testing.expectEqual(descriptor.body_pool_offset, extent.handle);
        try std.testing.expectEqual(@as(u32, @intCast(descriptor.len)), extent.len);
    }
    switch (extents[0].credit) {
        .h2_data => |credit| {
            try std.testing.expectEqual(@as(u64, 1), credit.source_id);
            try std.testing.expectEqual(@as(u32, 3), credit.stream_id);
            try std.testing.expectEqual(@as(usize, 5), credit.encoded_bytes);
            try std.testing.expect(credit.update_stream_window);
        },
        else => return error.MissingExtentCredit,
    }
    try std.testing.expect(extents[1].credit.isNone());

    var first: [5]u8 = undefined;
    var second: [5]u8 = undefined;
    try views.worker.body_pool.copyChunk(decoded[0].body_pool_offset, &first);
    try views.worker.body_pool.copyChunk(decoded[1].body_pool_offset, &second);
    try std.testing.expectEqualStrings("hello", &first);
    try std.testing.expectEqualStrings("world", &second);
    try views.worker.body_pool.releaseChunk(decoded[0].body_pool_offset, decoded[0].len);
    try views.worker.body_pool.releaseChunk(decoded[1].body_pool_offset, decoded[1].len);
}

test "a batch with an empty chunk is refused and writes nothing" {
    var views = try Views.init();
    defer views.deinit();

    const chunks = [_]publisher.BodyChunkPayload{
        .{ .bytes = "kept" },
        .{ .bytes = "" },
    };
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    try std.testing.expectError(
        error.InvalidEgressPacket,
        publisher.publishBodyChunkBatch(&views.gateway, 11, 22, &chunks, &scratch, &extents),
    );
    try std.testing.expectEqual(@as(usize, 0), (try views.gateway.body_pool.usage()).used);
    var packet_buffer: [1024]u8 = undefined;
    try std.testing.expect((try views.worker.completion.readPacket(&packet_buffer)) == null);
}

test "packets written while the ring holds unread ones ask for one completion wake" {
    var views = try Views.init();
    defer views.deinit();

    const first = ipc.EgressAbortAck.init(11, 22);
    const second = ipc.EgressAbortAck.init(33, 44);
    const third = ipc.EgressAbortAck.init(55, 66);

    try publishPacketAndNotifyIfNeeded(&views.gateway, std.mem.asBytes(&first), true);
    try publishPacketAndNotifyIfNeeded(&views.gateway, std.mem.asBytes(&second), false);
    try std.testing.expectEqual(@as(u64, 1), try readEventfdValue(views.worker.completion_eventfd));

    var packet_buffer: [1024]u8 = undefined;
    _ = (try views.worker.completion.readPacket(&packet_buffer)) orelse return error.MissingEgressAbortAck;
    _ = (try views.worker.completion.readPacket(&packet_buffer)) orelse return error.MissingEgressAbortAck;
    try std.testing.expect((try views.worker.completion.readPacket(&packet_buffer)) == null);

    try publishPacketAndNotifyIfNeeded(&views.gateway, std.mem.asBytes(&third), true);
    try std.testing.expectEqual(@as(u64, 1), try readEventfdValue(views.worker.completion_eventfd));
    _ = (try views.worker.completion.readPacket(&packet_buffer)) orelse return error.MissingEgressAbortAck;
}

test "body batches written while the ring holds unread ones ask for one completion wake" {
    var views = try Views.init();
    defer views.deinit();

    var scratch: [1024]u8 = undefined;
    try publishBodyChunkAndNotifyIfNeeded(&views.gateway, 11, 22, "first", &scratch, true);
    try publishBodyChunkAndNotifyIfNeeded(&views.gateway, 33, 44, "second", &scratch, false);
    try std.testing.expectEqual(@as(u64, 1), try readEventfdValue(views.worker.completion_eventfd));

    var packet_buffer: [1024]u8 = undefined;
    try drainBodyBatchPacket(&views.worker, &packet_buffer);
    try drainBodyBatchPacket(&views.worker, &packet_buffer);
    try std.testing.expect((try views.worker.completion.readPacket(&packet_buffer)) == null);

    try publishBodyChunkAndNotifyIfNeeded(&views.gateway, 55, 66, "third", &scratch, true);
    try std.testing.expectEqual(@as(u64, 1), try readEventfdValue(views.worker.completion_eventfd));
    try drainBodyBatchPacket(&views.worker, &packet_buffer);
}

test "a body batch whose descriptor ring is full writes no pool bytes" {
    var views = try Views.init();
    defer views.deinit();

    var filler: [4096]u8 = undefined;
    @memset(&filler, 0xee);
    var observed_full = false;
    while (true) {
        _ = views.gateway.completion.writePacket(&filler) catch |err| switch (err) {
            error.EgressSharedRingFull => {
                observed_full = true;
                break;
            },
            else => return err,
        };
    }
    try std.testing.expect(observed_full);

    const chunks = [_]publisher.BodyChunkPayload{.{ .bytes = "hidden" }};
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    try std.testing.expectError(
        error.EgressSharedRingFull,
        publisher.publishBodyChunkBatch(&views.gateway, 11, 22, &chunks, &scratch, &extents),
    );
    try std.testing.expectEqual(@as(usize, 0), (try views.gateway.body_pool.usage()).used);
}

test "a body batch whose descriptor packet does not encode rolls its pool bytes back" {
    var views = try Views.init();
    defer views.deinit();

    const chunks = [_]publisher.BodyChunkPayload{.{ .bytes = "hidden" }};
    var tiny_scratch: [1]u8 = undefined;
    var extents: ExtentStorage = undefined;
    try std.testing.expectError(
        error.EgressIpcScratchTooSmall,
        publisher.publishBodyChunkBatch(&views.gateway, 11, 22, &chunks, &tiny_scratch, &extents),
    );
    try std.testing.expectEqual(@as(usize, 0), (try views.gateway.body_pool.usage()).used);
}

test "a body chunk stays one contiguous extent across slab reuse" {
    var views = try Views.init();
    defer views.deinit();

    const filler = try std.testing.allocator.alloc(u8, ipc.egress_shared.body_pool_capacity - 3);
    defer std.testing.allocator.free(filler);
    @memset(filler, 0xaa);
    const filler_offset = try views.gateway.body_pool.writeChunk(filler);
    try views.worker.body_pool.releaseChunk(filler_offset, filler.len);
    // The publisher never drains releases, because only the release drain in
    // `runtime/release_flow.zig` may advance the release cursor; this drain stands in for it.
    try views.gateway.body_pool.drainReleasedChunks();

    const chunks = [_]publisher.BodyChunkPayload{.{ .bytes = "wrap-body" }};
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    const result = try publisher.publishBodyChunkBatch(&views.gateway, 31, 41, &chunks, &scratch, &extents);
    try std.testing.expectEqual(@as(usize, 1), result.extents);

    var packet_buffer: [1024]u8 = undefined;
    const packet = (try views.worker.completion.readPacket(&packet_buffer)) orelse
        return error.MissingEgressBodyChunkBatch;
    const decoded = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(@as(u64, 31), decoded[0].fetch_id);
    try std.testing.expectEqual(@as(u64, 41), decoded[0].body_id);
    try std.testing.expectEqual(@as(usize, "wrap-body".len), decoded[0].len);

    var first: ["wrap-body".len]u8 = undefined;
    try views.worker.body_pool.copyChunk(decoded[0].body_pool_offset, &first);
    try std.testing.expectEqualStrings("wrap-body", &first);
    try views.worker.body_pool.releaseChunk(decoded[0].body_pool_offset, decoded[0].len);
}

test "a chunk splits across a fragmented pool and its credit rides the last extent" {
    var views = try Views.init();
    defer views.deinit();

    var block: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    @memset(&block, 0x7a);
    var handles: [ipc.egress_shared.body_pool_slot_count]ipc.egress_shared.BodyPoolHandle = undefined;
    for (&handles) |*handle|
        handle.* = try views.gateway.body_pool.writeChunk(&block);
    for (handles, 0..) |handle, index| {
        if (index % 2 == 1)
            try views.worker.body_pool.releaseChunk(handle, block.len);
    }
    // Released chunks free their space only when a drain advances the release cursor, which the
    // publisher never does.
    try views.gateway.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(
        ipc.egress_shared.body_pool_capacity / 2,
        (try views.gateway.body_pool.usage()).used,
    );

    var payload: [ipc.egress_shared.body_pool_block_size * 2]u8 = undefined;
    @memset(payload[0..ipc.egress_shared.body_pool_block_size], 0x33);
    @memset(payload[ipc.egress_shared.body_pool_block_size..], 0x44);
    const chunk_credit = body_credit.h2Data(7, 9, payload.len, true);
    const chunks = [_]publisher.BodyChunkPayload{.{ .bytes = &payload, .credit = chunk_credit }};
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    const result = try publisher.publishBodyChunkBatch(&views.gateway, 51, 61, &chunks, &scratch, &extents);
    try std.testing.expectEqual(@as(usize, 2), result.extents);

    var packet_buffer: [1024]u8 = undefined;
    const packet = (try views.worker.completion.readPacket(&packet_buffer)) orelse
        return error.MissingEgressBodyChunkBatch;
    const decoded = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_size, decoded[0].len);
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_size, decoded[1].len);

    // The extents mirror the descriptors, and the chunk's credit rides on the last segment of
    // the split: the HTTP/2 window must not refill before the worker returns the extent that
    // holds the chunk's final bytes.
    for (decoded, extents[0..result.extents]) |descriptor, extent| {
        try std.testing.expectEqual(descriptor.body_pool_offset, extent.handle);
        try std.testing.expectEqual(@as(u32, @intCast(descriptor.len)), extent.len);
    }
    try std.testing.expect(extents[0].credit.isNone());
    switch (extents[1].credit) {
        .h2_data => |credit| {
            try std.testing.expectEqual(@as(u64, 7), credit.source_id);
            try std.testing.expectEqual(@as(u32, 9), credit.stream_id);
            try std.testing.expectEqual(payload.len, credit.encoded_bytes);
        },
        else => return error.MissingExtentCredit,
    }

    var first: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    var second: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    try views.worker.body_pool.copyChunk(decoded[0].body_pool_offset, &first);
    try views.worker.body_pool.copyChunk(decoded[1].body_pool_offset, &second);
    try std.testing.expect(std.mem.allEqual(u8, &first, 0x33));
    try std.testing.expect(std.mem.allEqual(u8, &second, 0x44));

    try views.worker.body_pool.releaseChunk(decoded[0].body_pool_offset, decoded[0].len);
    try views.worker.body_pool.releaseChunk(decoded[1].body_pool_offset, decoded[1].len);
    for (handles, 0..) |handle, index| {
        if (index % 2 == 0)
            try views.worker.body_pool.releaseChunk(handle, block.len);
    }
    try views.gateway.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(@as(usize, 0), (try views.gateway.body_pool.usage()).used);
}

test "the worst-case batch size covers one descriptor per pool block" {
    // The body drain reserves this much ring space before it pulls a chunk it cannot put back,
    // so it must cover the descriptors of a chunk spread over single blocks.
    const blocks = publisher.blockCountForBytes(3 * ipc.egress_shared.body_pool_block_size + 1);
    try std.testing.expectEqual(@as(usize, 4), blocks);
    try std.testing.expectEqual(@as(usize, 1), publisher.blockCountForBytes(1));
    try std.testing.expect(publisher.worstCaseBatchPacketBytes(blocks) >=
        @sizeOf(ipc.EgressBodyChunkBatchHeader) + blocks * @sizeOf(ipc.EgressBodyChunkBatchDescriptor));
}

fn publishPacketAndNotifyIfNeeded(
    endpoint: *ipc.egress_shared.Endpoint,
    bytes: []const u8,
    expected_eventfd_notify_required: bool,
) !void {
    const result = try publisher.queuePacket(endpoint, bytes);
    try std.testing.expectEqual(expected_eventfd_notify_required, result.eventfd_notify_required);
    ipc.egress_shared.notifyAfterPacketWrite(endpoint.completion_eventfd, result);
}

fn publishBodyChunkAndNotifyIfNeeded(
    endpoint: *ipc.egress_shared.Endpoint,
    fetch_id: u64,
    body_id: u64,
    bytes: []const u8,
    scratch: []u8,
    expected_eventfd_notify_required: bool,
) !void {
    const chunks = [_]publisher.BodyChunkPayload{.{ .bytes = bytes }};
    var extents: ExtentStorage = undefined;
    const result = try publisher.publishBodyChunkBatch(endpoint, fetch_id, body_id, &chunks, scratch, &extents);
    try std.testing.expectEqual(@as(usize, 1), result.extents);
    try std.testing.expectEqual(expected_eventfd_notify_required, result.write.eventfd_notify_required);
    ipc.egress_shared.notifyAfterPacketWrite(endpoint.completion_eventfd, result.write);
}

fn drainBodyBatchPacket(endpoint: *ipc.egress_shared.Endpoint, packet_buffer: []u8) !void {
    const packet = (try endpoint.completion.readPacket(packet_buffer)) orelse
        return error.MissingEgressBodyChunkBatch;
    const decoded = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    for (decoded) |chunk|
        try endpoint.body_pool.releaseChunk(chunk.body_pool_offset, chunk.len);
}

fn readEventfdValue(fd: std.posix.fd_t) !u64 {
    var value: u64 = 0;
    const bytes_read = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
        error.WouldBlock => return 0,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, @sizeOf(u64)), bytes_read);
    return value;
}
