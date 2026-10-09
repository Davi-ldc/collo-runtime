//! Publication into a worker's endpoint (`egress/gateway/publisher.zig`) over a real shared-memory
//! endpoint: a body batch appears whole or not at all, and leaves no pool bytes behind when the
//! ring is full or the descriptor packet does not encode; extents mirror descriptors, with each
//! chunk's credit on its last extent; a chunk splits across a fragmented pool and stays one extent
//! otherwise; and completion-eventfd wakes coalesce while the ring holds unread packets. The ring
//! and the pool themselves are covered in `common/tests/ipc.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");

const body_credit = @import("collo_egress_client").core.body_credit;

/// Shared by this file's tests, which run one at a time; a decoded batch
/// points into it until the next decode.
var test_decode_scratch: ipc.WorkerEgressDecodeScratch = .{};

const ExtentStorage = [ipc.egress.max_body_chunk_batch_count]gateway.publisher.PublishedExtent;

test "egress gateway publisher commits body bytes and descriptors atomically" {
    var fds = try createSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    const gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);

    var worker = gateway.sessions.Worker{
        .session_id = 1,
        .security_cell_id = [_]u8{1} ** 16,
        .endpoint = gateway_endpoint,
    };
    defer worker.deinit(std.testing.allocator);

    const chunks = [_]gateway.active_fetch.BodyChunkPayload{
        .{ .bytes = "hello", .billed_received_total = 5, .credit = body_credit.h2Data(1, 3, 5, true) },
        .{ .bytes = "world", .billed_received_total = 10 },
    };
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    const result = try gateway.publisher.publishBodyChunkBatch(
        &worker,
        11,
        22,
        &chunks,
        &scratch,
        &extents,
    );
    try std.testing.expectEqual(@as(usize, 2), result.extents);

    var packet_buffer: [1024]u8 = undefined;
    const packet = (try worker_endpoint.completion.readPacket(&packet_buffer)) orelse {
        return error.MissingEgressBodyChunkBatch;
    };
    const decoded = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(u64, 11), decoded[0].fetch_id);
    try std.testing.expectEqual(@as(u64, 22), decoded[0].body_id);
    try std.testing.expectEqual(@as(usize, 5), decoded[0].len);
    try std.testing.expectEqual(@as(u64, 10), decoded[1].billed_received_total);

    // Each extent matches its descriptor's handle and length, and a chunk that
    // did not split carries its credit on its only extent.
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
    try worker_endpoint.body_pool.copyChunk(decoded[0].body_pool_offset, &first);
    try worker_endpoint.body_pool.copyChunk(decoded[1].body_pool_offset, &second);
    try std.testing.expectEqualStrings("hello", &first);
    try std.testing.expectEqualStrings("world", &second);
    try worker_endpoint.body_pool.releaseChunk(decoded[0].body_pool_offset, decoded[0].len);
    try worker_endpoint.body_pool.releaseChunk(decoded[1].body_pool_offset, decoded[1].len);
}

test "egress gateway publisher coalesces completion wakes while packet ring is nonempty" {
    var fds = try createSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    const gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);

    var worker = gateway.sessions.Worker{
        .session_id = 1,
        .security_cell_id = [_]u8{5} ** 16,
        .endpoint = gateway_endpoint,
    };
    defer worker.deinit(std.testing.allocator);

    const first = ipc.EgressAbortAck.init(11, 22);
    const second = ipc.EgressAbortAck.init(33, 44);
    const third = ipc.EgressAbortAck.init(55, 66);

    try publishPacketAndNotifyIfNeeded(&worker, std.mem.asBytes(&first), true);
    try publishPacketAndNotifyIfNeeded(&worker, std.mem.asBytes(&second), false);
    try std.testing.expectEqual(@as(u64, 1), try readEventfdValue(worker_endpoint.completion_eventfd));

    var packet_buffer: [1024]u8 = undefined;
    _ = (try worker_endpoint.completion.readPacket(&packet_buffer)) orelse return error.MissingEgressAbortAck;
    _ = (try worker_endpoint.completion.readPacket(&packet_buffer)) orelse return error.MissingEgressAbortAck;
    try std.testing.expect((try worker_endpoint.completion.readPacket(&packet_buffer)) == null);

    try publishPacketAndNotifyIfNeeded(&worker, std.mem.asBytes(&third), true);
    try std.testing.expectEqual(@as(u64, 1), try readEventfdValue(worker_endpoint.completion_eventfd));
    _ = (try worker_endpoint.completion.readPacket(&packet_buffer)) orelse return error.MissingEgressAbortAck;
}

test "egress gateway publisher coalesces completion wakes while body batch ring is nonempty" {
    var fds = try createSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    const gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);

    var worker = gateway.sessions.Worker{
        .session_id = 1,
        .security_cell_id = [_]u8{6} ** 16,
        .endpoint = gateway_endpoint,
    };
    defer worker.deinit(std.testing.allocator);

    var scratch: [1024]u8 = undefined;
    try publishBodyChunkAndNotifyIfNeeded(&worker, 11, 22, "first", &scratch, true);
    try publishBodyChunkAndNotifyIfNeeded(&worker, 33, 44, "second", &scratch, false);
    try std.testing.expectEqual(@as(u64, 1), try readEventfdValue(worker_endpoint.completion_eventfd));

    var packet_buffer: [1024]u8 = undefined;
    try drainBodyBatchPacket(&worker_endpoint, &packet_buffer);
    try drainBodyBatchPacket(&worker_endpoint, &packet_buffer);
    try std.testing.expect((try worker_endpoint.completion.readPacket(&packet_buffer)) == null);

    try publishBodyChunkAndNotifyIfNeeded(&worker, 55, 66, "third", &scratch, true);
    try std.testing.expectEqual(@as(u64, 1), try readEventfdValue(worker_endpoint.completion_eventfd));
    try drainBodyBatchPacket(&worker_endpoint, &packet_buffer);
}

test "egress gateway publisher does not write body bytes when descriptor ring is full" {
    var fds = try createSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    const gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);

    var worker = gateway.sessions.Worker{
        .session_id = 1,
        .security_cell_id = [_]u8{2} ** 16,
        .endpoint = gateway_endpoint,
    };
    defer worker.deinit(std.testing.allocator);

    var filler: [4096]u8 = undefined;
    @memset(&filler, 0xee);
    var observed_full = false;
    while (true) {
        _ = worker.endpoint.completion.writePacket(&filler) catch |err| switch (err) {
            error.EgressSharedRingFull => {
                observed_full = true;
                break;
            },
            else => return err,
        };
    }
    try std.testing.expect(observed_full);

    const chunks = [_]gateway.active_fetch.BodyChunkPayload{
        .{ .bytes = "hidden", .billed_received_total = 6 },
    };
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    try std.testing.expectError(
        error.EgressSharedRingFull,
        gateway.publisher.publishBodyChunkBatch(&worker, 11, 22, &chunks, &scratch, &extents),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try worker.endpoint.body_pool.usage()).used,
    );
}

test "egress gateway publisher rolls back body bytes when descriptor encoding fails" {
    var fds = try createSession();
    defer fds.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    const gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);

    var worker = gateway.sessions.Worker{
        .session_id = 1,
        .security_cell_id = [_]u8{3} ** 16,
        .endpoint = gateway_endpoint,
    };
    defer worker.deinit(std.testing.allocator);

    const chunks = [_]gateway.active_fetch.BodyChunkPayload{
        .{ .bytes = "hidden", .billed_received_total = 6 },
    };
    var tiny_scratch: [1]u8 = undefined;
    var extents: ExtentStorage = undefined;
    try std.testing.expectError(
        error.EgressIpcScratchTooSmall,
        gateway.publisher.publishBodyChunkBatch(&worker, 11, 22, &chunks, &tiny_scratch, &extents),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try worker.endpoint.body_pool.usage()).used,
    );
}

test "egress gateway publisher keeps body chunks contiguous across slab reuse" {
    var fds = try createSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    const gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);

    var worker = gateway.sessions.Worker{
        .session_id = 1,
        .security_cell_id = [_]u8{4} ** 16,
        .endpoint = gateway_endpoint,
    };
    defer worker.deinit(std.testing.allocator);

    const filler = try std.testing.allocator.alloc(u8, ipc.egress_shared.body_pool_capacity - 3);
    defer std.testing.allocator.free(filler);
    @memset(filler, 0xaa);
    const filler_offset = try worker.endpoint.body_pool.writeChunk(filler);
    try worker_endpoint.body_pool.releaseChunk(filler_offset, filler.len);
    // The publisher never drains releases, because only the observed drain in
    // `runtime/body_release_flow.zig` may advance the release cursor; this
    // drain stands in for it.
    try worker.endpoint.body_pool.drainReleasedChunks();

    const chunks = [_]gateway.active_fetch.BodyChunkPayload{
        .{ .bytes = "wrap-body", .billed_received_total = 9 },
    };
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    const result = try gateway.publisher.publishBodyChunkBatch(&worker, 31, 41, &chunks, &scratch, &extents);
    try std.testing.expectEqual(@as(usize, 1), result.extents);

    var packet_buffer: [1024]u8 = undefined;
    const packet = (try worker_endpoint.completion.readPacket(&packet_buffer)) orelse {
        return error.MissingEgressBodyChunkBatch;
    };
    const decoded = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(@as(u64, 31), decoded[0].fetch_id);
    try std.testing.expectEqual(@as(u64, 41), decoded[0].body_id);
    try std.testing.expectEqual(@as(usize, "wrap-body".len), decoded[0].len);

    var first: ["wrap-body".len]u8 = undefined;
    try worker_endpoint.body_pool.copyChunk(decoded[0].body_pool_offset, &first);
    try std.testing.expectEqualStrings("wrap-body", &first);
    try worker_endpoint.body_pool.releaseChunk(decoded[0].body_pool_offset, decoded[0].len);
}

test "egress gateway publisher splits fragmented body pool chunks" {
    var fds = try createSession();
    defer fds.deinit();
    var worker_raw = try dupEgressRawFds(fds.rawForWorker());
    var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
    defer worker_endpoint.deinit();
    var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
    const gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);

    var worker = gateway.sessions.Worker{
        .session_id = 1,
        .security_cell_id = [_]u8{7} ** 16,
        .endpoint = gateway_endpoint,
    };
    defer worker.deinit(std.testing.allocator);

    var block: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    @memset(&block, 0x7a);
    var handles: [ipc.egress_shared.body_pool_slot_count]ipc.egress_shared.BodyPoolHandle = undefined;
    for (&handles) |*handle| {
        handle.* = try worker.endpoint.body_pool.writeChunk(&block);
    }
    for (handles, 0..) |handle, index| {
        if (index % 2 == 1)
            try worker_endpoint.body_pool.releaseChunk(handle, block.len);
    }
    // Released chunks free their space only when a drain advances the release
    // cursor, which the publisher never does.
    try worker.endpoint.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(
        ipc.egress_shared.body_pool_capacity / 2,
        (try worker.endpoint.body_pool.usage()).used,
    );

    var payload: [ipc.egress_shared.body_pool_block_size * 2]u8 = undefined;
    @memset(payload[0..ipc.egress_shared.body_pool_block_size], 0x33);
    @memset(payload[ipc.egress_shared.body_pool_block_size..], 0x44);
    const chunk_credit = body_credit.h2Data(7, 9, payload.len, true);
    const chunks = [_]gateway.active_fetch.BodyChunkPayload{
        .{ .bytes = &payload, .billed_received_total = payload.len, .credit = chunk_credit },
    };
    var scratch: [1024]u8 = undefined;
    var extents: ExtentStorage = undefined;
    const result = try gateway.publisher.publishBodyChunkBatch(&worker, 51, 61, &chunks, &scratch, &extents);
    try std.testing.expectEqual(@as(usize, 2), result.extents);

    var packet_buffer: [1024]u8 = undefined;
    const packet = (try worker_endpoint.completion.readPacket(&packet_buffer)) orelse {
        return error.MissingEgressBodyChunkBatch;
    };
    const decoded = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_size, decoded[0].len);
    try std.testing.expectEqual(ipc.egress_shared.body_pool_block_size, decoded[1].len);

    // The extents mirror the descriptors, and the chunk's credit rides on the
    // last segment of the split: the HTTP/2 window must not refill before the
    // worker returns the extent that holds the chunk's final bytes.
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
    try worker_endpoint.body_pool.copyChunk(decoded[0].body_pool_offset, &first);
    try worker_endpoint.body_pool.copyChunk(decoded[1].body_pool_offset, &second);
    try std.testing.expect(std.mem.allEqual(u8, &first, 0x33));
    try std.testing.expect(std.mem.allEqual(u8, &second, 0x44));

    try worker_endpoint.body_pool.releaseChunk(decoded[0].body_pool_offset, decoded[0].len);
    try worker_endpoint.body_pool.releaseChunk(decoded[1].body_pool_offset, decoded[1].len);
    for (handles, 0..) |handle, index| {
        if (index % 2 == 0)
            try worker_endpoint.body_pool.releaseChunk(handle, block.len);
    }
    try worker.endpoint.body_pool.drainReleasedChunks();
    try std.testing.expectEqual(@as(usize, 0), (try worker.endpoint.body_pool.usage()).used);
}

fn publishPacketAndNotifyIfNeeded(
    worker: *gateway.sessions.Worker,
    bytes: []const u8,
    expected_eventfd_notify_required: bool,
) !void {
    const result = try gateway.publisher.queuePacket(worker, bytes);
    try std.testing.expectEqual(
        expected_eventfd_notify_required,
        result.eventfd_notify_required,
    );
    ipc.egress_shared.notifyAfterPacketWrite(worker.endpoint.completion_eventfd, result);
}

fn publishBodyChunkAndNotifyIfNeeded(
    worker: *gateway.sessions.Worker,
    fetch_id: u64,
    body_id: u64,
    bytes: []const u8,
    scratch: []u8,
    expected_eventfd_notify_required: bool,
) !void {
    const chunks = [_]gateway.active_fetch.BodyChunkPayload{
        .{ .bytes = bytes, .billed_received_total = bytes.len },
    };
    var extents: ExtentStorage = undefined;
    const result = try gateway.publisher.publishBodyChunkBatch(
        worker,
        fetch_id,
        body_id,
        &chunks,
        scratch,
        &extents,
    );
    try std.testing.expectEqual(@as(usize, 1), result.extents);
    try std.testing.expectEqual(
        expected_eventfd_notify_required,
        result.write.eventfd_notify_required,
    );
    ipc.egress_shared.notifyAfterPacketWrite(worker.endpoint.completion_eventfd, result.write);
}

fn drainBodyBatchPacket(
    endpoint: *ipc.egress_shared.Endpoint,
    packet_buffer: []u8,
) !void {
    const packet = (try endpoint.completion.readPacket(packet_buffer)) orelse {
        return error.MissingEgressBodyChunkBatch;
    };
    const decoded = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    for (decoded) |chunk| {
        try endpoint.body_pool.releaseChunk(chunk.body_pool_offset, chunk.len);
    }
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

/// A session on a wake set of its own. The session holds its own copy of
/// every wake descriptor, so the set closes once the session is built.
fn createSession() !ipc.egress_shared.SessionFds {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    return ipc.egress_shared.createSessionForWorker(&wake_set);
}

fn dupEgressRawFds(fds: ipc.egress_shared.RawFds) !ipc.egress_shared.RawFds {
    var out = ipc.egress_shared.RawFds{};
    errdefer out.close();
    out.command_control_fd = try std.posix.dup(fds.command_control_fd);
    out.command_producer_fd = try std.posix.dup(fds.command_producer_fd);
    out.command_consumer_fd = try std.posix.dup(fds.command_consumer_fd);
    out.command_data_fd = try std.posix.dup(fds.command_data_fd);
    out.completion_control_fd = try std.posix.dup(fds.completion_control_fd);
    out.completion_producer_fd = try std.posix.dup(fds.completion_producer_fd);
    out.completion_consumer_fd = try std.posix.dup(fds.completion_consumer_fd);
    out.completion_data_fd = try std.posix.dup(fds.completion_data_fd);
    out.body_pool_control_fd = try std.posix.dup(fds.body_pool_control_fd);
    out.body_pool_producer_fd = try std.posix.dup(fds.body_pool_producer_fd);
    out.body_pool_consumer_fd = try std.posix.dup(fds.body_pool_consumer_fd);
    out.body_pool_data_fd = try std.posix.dup(fds.body_pool_data_fd);
    out.upload_pool_control_fd = try std.posix.dup(fds.upload_pool_control_fd);
    out.upload_pool_producer_fd = try std.posix.dup(fds.upload_pool_producer_fd);
    out.upload_pool_consumer_fd = try std.posix.dup(fds.upload_pool_consumer_fd);
    out.upload_pool_data_fd = try std.posix.dup(fds.upload_pool_data_fd);
    out.command_eventfd = try std.posix.dup(fds.command_eventfd);
    out.completion_eventfd = try std.posix.dup(fds.completion_eventfd);
    out.liveness_fd = try std.posix.dup(fds.liveness_fd);
    out.peer_liveness_fd = try std.posix.dup(fds.peer_liveness_fd);
    return out;
}
