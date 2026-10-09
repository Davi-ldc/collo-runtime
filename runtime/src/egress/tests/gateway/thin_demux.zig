//! The response body path between a shard engine and a worker over a real shared-memory endpoint
//! (`ipc.egress_shared`), with no engine threads. An engine with zero connector threads, whose
//! inner engine is never available, publishes encoded HTTP/2 body chunks; the test plays the
//! worker, reading the completion ring, borrowing pool extents, decoding them with
//! `encoded_body.Decoder` and releasing them; then it drives a release observer that turns each
//! returned extent back into a credit, which retires the fetch after its last extent. The drain
//! preflight that pauses publication while the pool or the ring lacks room is covered too. The
//! worker's decoding on its own is covered in `egress/tests/core/encoded_body.zig`. Lane:
//! egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const engine_test = @import("support/engine.zig");
const egress = @import("collo_egress_client");
const ipc = @import("collo_ipc");

/// Shared by this file's tests, which run one at a time; a decoded batch
/// points into it until the next decode.
var test_decode_scratch: ipc.WorkerEgressDecodeScratch = .{};

const body_credit = egress.core.body_credit;
const decompress = egress.core.decompress;
const encoded_body = egress.core.encoded_body;
const fetch_body = egress.core.fetch_body;

/// The identity type `fetch_body.Body.initOpen` takes, read off its signature.
const FetchBodyIdentity = @typeInfo(@TypeOf(fetch_body.Body.initOpen)).@"fn".params[1].type.?;

/// "hello world" compressed with gzip, the same bytes as `gzip_hello_world` in
/// `egress/tests/core/support.zig`.
const gzip_hello_world = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
    0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
};

test "thin demux body pool block size matches the h2 default max frame size" {
    // 16384 is the initial SETTINGS_MAX_FRAME_SIZE of RFC 9113 §6.5.2
    // (`http2.default_max_frame_size`), which the egress engine never raises,
    // so one HTTP/2 DATA frame always fits one pool block.
    try std.testing.expectEqual(@as(usize, 16384), ipc.egress_shared.body_pool_block_size);
}

test "thin demux ships encoded chunks through a real endpoint and retires on release" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var fixture = try EndpointFixture.init();
    defer fixture.deinit();

    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();
    var harness = Harness{ .worker = &fixture.worker };
    engine.setPacketSender(&harness, queuePacketToWorker);
    engine.setBodyChunkBatchSender(publishBodyChunkBatchToWorker);

    const fetch_id: u64 = 11;
    const body_id: u64 = 22;
    try engine_test.injectActive(&engine, worker_session_id, fetch_id, body_id);
    // Two encoded HTTP/2 DATA chunks, each carrying its flow-control credit.
    try engine_test.appendReadyBodyChunkWithCredit(
        &engine,
        worker_session_id,
        fetch_id,
        body_id,
        gzip_hello_world[0..10],
        body_credit.h2Data(5, 1, 10, true),
    );
    try engine_test.appendReadyBodyChunkWithCredit(
        &engine,
        worker_session_id,
        fetch_id,
        body_id,
        gzip_hello_world[10..],
        body_credit.h2Data(5, 1, gzip_hello_world.len - 10, true),
    );
    try engine_test.markActiveBodyComplete(&engine, worker_session_id, fetch_id, body_id);
    try engine_test.markActiveTaskDone(&engine, worker_session_id, fetch_id);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);

    engine_test.wakeGeneric(&engine);
    try engine.collectReadyCompleted(&completed);

    // Both extents are published and body end is sent, so the fetch waits for
    // the worker's releases.
    try std.testing.expectEqual(@as(usize, 0), completed.items.len);
    try std.testing.expectEqual(@as(usize, 2), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));
    try std.testing.expect(engine_test.activeFetchBodyEndSent(&engine, worker_session_id, fetch_id, body_id));
    try std.testing.expect(engine.hasActiveBody(worker_session_id, fetch_id, body_id));

    // The test plays the worker: it reads the completion ring, borrows each
    // extent, decodes it and releases it.
    var decoded_body = fetch_body.Body.initOpen(std.testing.allocator, testIdentity(body_id), 1024);
    defer decoded_body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    var decoder = try encoded_body.Decoder.init(.gzip, encoded_body.limitsFromHeadFields(0, 0, 0));
    defer decoder.deinit(std.testing.allocator);
    try std.testing.expect(!try decoded_body.beginPull(.{ .deferred = null }));

    // The whole drain, one batch packet and the body end, costs one eventfd
    // write: only a write into an empty ring signals.
    var notify_value: u64 = 0;
    _ = try std.posix.read(
        fixture.worker_endpoint.completion_eventfd,
        std.mem.asBytes(&notify_value),
    );
    try std.testing.expectEqual(@as(u64, 1), notify_value);

    var release_sink = WorkerReleaseSink{ .endpoint = &fixture.worker_endpoint };
    var chunk_packets: usize = 0;
    var chunk_descriptors: usize = 0;
    var body_end_packets: usize = 0;
    var packet_buffer: [4096]u8 = undefined;
    while (try fixture.worker_endpoint.completion.readPacket(&packet_buffer)) |packet| {
        switch (try packetKind(packet)) {
            .egress_body_chunk_batch => {
                chunk_packets += 1;
                const descriptors = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
                chunk_descriptors += descriptors.len;
                for (descriptors) |descriptor| {
                    try std.testing.expectEqual(fetch_id, descriptor.fetch_id);
                    try std.testing.expectEqual(body_id, descriptor.body_id);
                    const bytes = try fixture.worker_endpoint.body_pool.borrowContiguousChunk(
                        descriptor.body_pool_offset,
                        descriptor.len,
                    );
                    _ = try decoder.pushBorrowed(std.testing.allocator, &decoded_body, .{
                        .bytes = bytes,
                        .release = .{
                            .context = &release_sink,
                            .seq = descriptor.body_pool_offset,
                            .len = descriptor.len,
                            .release_fn = WorkerReleaseSink.releaseFn,
                        },
                    });
                }
            },
            .egress_body_end => {
                const end = try ipc.decodeEgressBodyEnd(packet);
                try std.testing.expectEqual(fetch_id, end.fetch_id);
                try std.testing.expectEqual(body_id, end.body_id);
                body_end_packets += 1;
            },
            else => return error.UnexpectedEgressPacket,
        }
    }
    // Both ready chunks went out in one publication, one pool transaction and
    // one ring packet, with one descriptor and extent per chunk.
    try std.testing.expectEqual(@as(usize, 1), chunk_packets);
    try std.testing.expectEqual(@as(usize, 2), chunk_descriptors);
    try std.testing.expectEqual(@as(usize, 1), body_end_packets);

    const finish = try decoder.finish(std.testing.allocator, &decoded_body);
    try std.testing.expect(finish.complete);
    _ = decoded_body.complete();

    var decoded_text: std.array_list.Aligned(u8, null) = .empty;
    defer decoded_text.deinit(std.testing.allocator);
    var pulls: usize = 0;
    while (decoded_text.items.len < "hello world".len) : (pulls += 1) {
        if (pulls > 8)
            return error.DecodedBodyIncomplete;
        try pullAppend(&decoded_body, &decoded_text);
    }
    try std.testing.expectEqualStrings("hello world", decoded_text.items);
    // Reading the whole body released both extents into the release queue.
    try std.testing.expectEqual(@as(usize, 2), release_sink.released);

    // The gateway's side: the observed release drain looks up each extent in
    // the slot ledger and releases its credit to the engine.
    var observer = ReleaseObserver{ .worker = &fixture.worker, .engine = &engine };
    const freed = try fixture.worker.endpoint.body_pool.drainReleasedChunksObserved(
        &observer,
        ReleaseObserver.observe,
    );
    try std.testing.expectEqual(@as(usize, 2), freed);
    try std.testing.expectEqual(@as(usize, 2), observer.credited);
    try std.testing.expectEqual(@as(usize, 0), observer.ledger_misses);
    // The unavailable inner engine absorbs the credits without a failure:
    // `tryReleaseFetchBodyCredit` returns at once while it is not started.
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));

    // The last extent returned after body end retires the fetch with no
    // further wake; in the gateway, the release observer then finds no active
    // body and removes the route.
    try std.testing.expect(!engine.hasActiveBody(worker_session_id, fetch_id, body_id));
    engine.wakeForWorkerPressureChange(worker_session_id);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 0), completed.items.len);

    // The pool is empty again, and punching the freed ranges while idle works.
    try std.testing.expectEqual(@as(usize, 0), (try fixture.worker.endpoint.body_pool.usage()).used);
    for (observer.punch_ranges[0..observer.punch_count]) |range|
        try fixture.worker.endpoint.body_pool.punchFreeRange(range.block_index, range.block_count);

    // `drainBody` checks `body_end_sent` when it drains again, so no second
    // body end, nor any other packet, follows the retirement.
    try std.testing.expectEqual(@as(?[]const u8, null), try fixture.worker_endpoint.completion.readPacket(&packet_buffer));
}

test "thin demux pool-full preflight pauses the drain and resumes after release" {
    var fixture = try EndpointFixture.init();
    defer fixture.deinit();

    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .h2_connector_count = 0,
        // A chunk quantum of the whole pool (`body_pool_capacity`) makes any
        // allocated block trip the drain preflight.
        .policy = .{ .max_body_chunk_bytes = ipc.egress_shared.body_pool_capacity },
    });
    defer engine.deinit();
    var harness = Harness{ .worker = &fixture.worker };
    engine.setPacketSender(&harness, queuePacketToWorker);
    engine.setBodyChunkBatchSender(publishBodyChunkBatchToWorker);
    engine.setWorkerPressureProbe(realPoolPressureProbe);

    // With one block in use, the preflight, which probes `freeBlocks` without
    // draining releases, must see less than one chunk quantum of room.
    var filler: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    @memset(&filler, 0xee);
    const filler_handle = try fixture.worker.endpoint.body_pool.writeChunk(&filler);
    fixture.worker.recordSlotCredit(filler_handle, filler.len, 0, 0, .none);

    const fetch_id: u64 = 33;
    const body_id: u64 = 44;
    try engine_test.injectActive(&engine, worker_session_id, fetch_id, body_id);
    try engine_test.appendReadyBodyChunk(&engine, worker_session_id, fetch_id, body_id, "paused-bytes");

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);

    engine_test.wakeGeneric(&engine);
    try engine.collectReadyCompleted(&completed);

    // The fetch is paused, neither canceled nor dropped: the chunk never left
    // the engine's body queue and nothing was published.
    var packet_buffer: [4096]u8 = undefined;
    try std.testing.expect((try fixture.worker_endpoint.completion.readPacket(&packet_buffer)) == null);
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, worker_session_id, fetch_id));
    try std.testing.expect(engine.hasActiveBody(worker_session_id, fetch_id, body_id));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));

    // The worker hands the filler block back, and only the observed release
    // drain returns its space, since `freeBlocks` never drains.
    try fixture.worker_endpoint.body_pool.releaseChunk(filler_handle, filler.len);
    var observer = ReleaseObserver{ .worker = &fixture.worker, .engine = &engine };
    const freed = try fixture.worker.endpoint.body_pool.drainReleasedChunksObserved(
        &observer,
        ReleaseObserver.observe,
    );
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expectEqual(@as(usize, 0), observer.credited);
    try std.testing.expectEqual(@as(usize, 0), observer.ledger_misses);

    // With the room back, the same fetch drains on the pressure wake.
    engine.wakeForWorkerPressureChange(worker_session_id);
    try engine.collectReadyCompleted(&completed);

    const packet = (try fixture.worker_endpoint.completion.readPacket(&packet_buffer)) orelse
        return error.MissingEgressBodyChunkBatch;
    const descriptors = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    try std.testing.expectEqual(@as(usize, 1), descriptors.len);
    try std.testing.expectEqual(@as(usize, "paused-bytes".len), descriptors[0].len);
    var copy: ["paused-bytes".len]u8 = undefined;
    try fixture.worker_endpoint.body_pool.copyChunk(descriptors[0].body_pool_offset, &copy);
    try std.testing.expectEqualStrings("paused-bytes", &copy);
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, worker_session_id, fetch_id));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));

    // Returning the extent runs the release once more: its credit goes back
    // and no extent is left out.
    try fixture.worker_endpoint.body_pool.releaseChunk(descriptors[0].body_pool_offset, descriptors[0].len);
    _ = try fixture.worker.endpoint.body_pool.drainReleasedChunksObserved(&observer, ReleaseObserver.observe);
    try std.testing.expectEqual(@as(usize, 1), observer.credited);
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));
    try std.testing.expectEqual(@as(usize, 0), (try fixture.worker.endpoint.body_pool.usage()).used);
}

test "thin demux ring preflight pauses a fragmented-pool drain without detaching" {
    var fixture = try EndpointFixture.init();
    defer fixture.deinit();

    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();
    var harness = Harness{ .worker = &fixture.worker };
    engine.setPacketSender(&harness, queuePacketToWorker);
    engine.setBodyChunkBatchSender(publishBodyChunkBatchToWorker);
    engine.setWorkerPressureProbe(realPoolPressureProbe);

    // Fragment the pool: fill it with single-block chunks, then release every
    // other one. Half the blocks are free but no two are adjacent, so a chunk
    // of several blocks must split into one segment, and one ring descriptor,
    // per block.
    var filler: [ipc.egress_shared.body_pool_block_size]u8 = undefined;
    @memset(&filler, 0xab);
    var handles: [ipc.egress_shared.body_pool_block_count]u64 = undefined;
    for (&handles) |*handle| {
        handle.* = try fixture.worker.endpoint.body_pool.writeChunk(&filler);
        fixture.worker.recordSlotCredit(handle.*, filler.len, 0, 0, .none);
    }
    var release_index: usize = 0;
    while (release_index < handles.len) : (release_index += 2) {
        try fixture.worker_endpoint.body_pool.releaseChunk(handles[release_index], filler.len);
    }
    var observer = ReleaseObserver{ .worker = &fixture.worker, .engine = &engine };
    const freed = try fixture.worker.endpoint.body_pool.drainReleasedChunksObserved(
        &observer,
        ReleaseObserver.observe,
    );
    try std.testing.expectEqual(handles.len / 2, freed);

    // Fill the completion ring until its free space, `target_free`, is far
    // below the preflight's reserve of one descriptor per pool block, though
    // above what one descriptor per chunk needs. A preflight that reserved per
    // chunk would drain the chunk, split it into three descriptors and find
    // the ring full only after the destructive drain, detaching the fetch.
    const target_free: usize = 120;
    // The ring's frame header (`FrameHeader` in `ipc/egress_shared/packet_ring.zig`).
    const ring_frame_overhead: usize = 8;
    const pad = try std.testing.allocator.alloc(u8, ipc.egress_shared.max_packet_bytes);
    defer std.testing.allocator.free(pad);
    @memset(pad, 0x55);
    while (true) {
        const usage = try fixture.worker.endpoint.completion.usage();
        const free = usage.capacity - usage.used;
        if (free <= target_free + ring_frame_overhead)
            break;
        const len = @min(pad.len, free - target_free - ring_frame_overhead);
        _ = try fixture.worker.endpoint.completion.writePacket(pad[0..len]);
    }

    const fetch_id: u64 = 55;
    const body_id: u64 = 66;
    try engine_test.injectActive(&engine, worker_session_id, fetch_id, body_id);
    const chunk = try std.testing.allocator.alloc(u8, 3 * ipc.egress_shared.body_pool_block_size);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 0xcd);
    try engine_test.appendReadyBodyChunk(&engine, worker_session_id, fetch_id, body_id, chunk);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);

    engine_test.wakeGeneric(&engine);
    try engine.collectReadyCompleted(&completed);

    // The fetch paused before the destructive drain: nothing was published or
    // lost, the fetch is alive and the worker untouched.
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, worker_session_id, fetch_id));
    try std.testing.expect(engine.hasActiveBody(worker_session_id, fetch_id, body_id));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));

    // The worker drains the ring; the pressure wake resumes the same fetch.
    const packet_buffer = try std.testing.allocator.alloc(u8, ipc.egress_shared.max_packet_bytes);
    defer std.testing.allocator.free(packet_buffer);
    var drained_pad_packets: usize = 0;
    while (try fixture.worker_endpoint.completion.readPacket(packet_buffer)) |_| {
        drained_pad_packets += 1;
    }
    try std.testing.expect(drained_pad_packets != 0);

    engine.wakeForWorkerPressureChange(worker_session_id);
    try engine.collectReadyCompleted(&completed);

    const packet = (try fixture.worker_endpoint.completion.readPacket(packet_buffer)) orelse
        return error.MissingEgressBodyChunkBatch;
    const descriptors = try ipc.decodeEgressBodyChunkBatch(&test_decode_scratch, packet);
    // The fragmented pool split the three-block chunk into three single-block
    // descriptors, the case the per-block reserve exists for.
    try std.testing.expectEqual(@as(usize, 3), descriptors.len);
    var published_bytes: usize = 0;
    for (descriptors) |descriptor| {
        try std.testing.expectEqual(fetch_id, descriptor.fetch_id);
        try std.testing.expectEqual(body_id, descriptor.body_id);
        published_bytes += descriptor.len;
    }
    try std.testing.expectEqual(chunk.len, published_bytes);
    try std.testing.expectEqual(@as(usize, 3), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, worker_session_id, fetch_id));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));
}

const worker_session_id: u64 = 1;

const EndpointFixture = struct {
    worker_endpoint: ipc.egress_shared.Endpoint,
    worker: gateway.sessions.Worker,

    fn init() !EndpointFixture {
        var fds = try createSession();
        defer fds.deinit();
        var worker_raw = try dupEgressRawFds(fds.rawForWorker());
        var worker_endpoint = try ipc.egress_shared.mapEndpointTakeForWorker(&worker_raw);
        errdefer worker_endpoint.deinit();
        var gateway_raw = try dupEgressRawFds(fds.rawForGateway());
        const gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
        return .{
            .worker_endpoint = worker_endpoint,
            .worker = .{
                .session_id = worker_session_id,
                .security_cell_id = [_]u8{1} ** 16,
                .endpoint = gateway_endpoint,
            },
        };
    }

    fn deinit(self: *EndpointFixture) void {
        self.worker.deinit(std.testing.allocator);
        self.worker_endpoint.deinit();
        self.* = undefined;
    }
};

/// The context of the engine's sinks below, which write packets and body
/// batches into the gateway's view of the endpoint as `runtime/shard_flow.zig`
/// does, slot ledger entries included, so a returned extent maps back to its
/// credit.
const Harness = struct {
    worker: *gateway.sessions.Worker,
};

fn queuePacketToWorker(ctx: ?*anyopaque, session_id: u64, bytes: []const u8) anyerror!void {
    const harness: *Harness = @ptrCast(@alignCast(ctx orelse return error.PeerClosed));
    std.debug.assert(session_id == harness.worker.session_id);
    const result = try gateway.publisher.queuePacket(harness.worker, bytes);
    ipc.egress_shared.notifyAfterPacketWrite(harness.worker.endpoint.completion_eventfd, result);
}

fn publishBodyChunkBatchToWorker(
    ctx: ?*anyopaque,
    session_id: u64,
    fetch_id: u64,
    body_id: u64,
    chunks: []const gateway.engine.BodyChunkPayload,
    scratch: []u8,
) anyerror!usize {
    const harness: *Harness = @ptrCast(@alignCast(ctx orelse return error.PeerClosed));
    std.debug.assert(session_id == harness.worker.session_id);
    var extents: [ipc.egress.max_body_chunk_batch_count]gateway.publisher.PublishedExtent = undefined;
    const result = try gateway.publisher.publishBodyChunkBatch(
        harness.worker,
        fetch_id,
        body_id,
        chunks,
        scratch,
        &extents,
    );
    for (extents[0..result.extents]) |extent|
        harness.worker.recordSlotCredit(extent.handle, extent.len, fetch_id, body_id, extent.credit);
    ipc.egress_shared.notifyAfterPacketWrite(harness.worker.endpoint.completion_eventfd, result.write);
    return result.extents;
}

/// The pool and ring half of `workerPressureProbeCallback` in
/// `runtime/root.zig`, without the worker's backpressure level.
fn realPoolPressureProbe(ctx: ?*anyopaque, session_id: u64) gateway.policy.WorkerPressure {
    const harness: *Harness = @ptrCast(@alignCast(ctx orelse return .{ .pause_pulls = true }));
    std.debug.assert(session_id == harness.worker.session_id);
    const ring_usage = harness.worker.endpoint.completion.usage() catch
        return .{ .pause_pulls = true };
    return .{
        .pool_free_bytes = harness.worker.endpoint.body_pool.freeBlocks() *
            ipc.egress_shared.body_pool_block_size,
        .completion_ring_free_bytes = ring_usage.capacity - ring_usage.used,
    };
}

/// The worker's extent release. Its write into the pool's release queue is
/// the credit acknowledgement the gateway waits for.
const WorkerReleaseSink = struct {
    endpoint: *ipc.egress_shared.Endpoint,
    released: usize = 0,

    fn releaseFn(context: ?*anyopaque, seq: u64, len: usize) void {
        const self: *WorkerReleaseSink = @ptrCast(@alignCast(context.?));
        self.endpoint.body_pool.releaseChunk(seq, len) catch |err|
            std.debug.panic("worker extent release failed: {s}", .{@errorName(err)});
        self.released += 1;
    }
};

/// A reduced copy of the release observer in `runtime/body_release_flow.zig`:
/// it looks up the slot ledger, releases each extent's credit to the engine
/// and records punch ranges, but neither merges acknowledgements nor removes
/// routes.
const ReleaseObserver = struct {
    worker: *gateway.sessions.Worker,
    engine: *gateway.engine.Engine,
    credited: usize = 0,
    ledger_misses: usize = 0,
    punch_ranges: [8]PunchRange = undefined,
    punch_count: usize = 0,

    const PunchRange = struct {
        block_index: usize,
        block_count: usize,
    };

    fn observe(self: *ReleaseObserver, extent: ipc.egress_shared.BodyPoolView.ReleasedExtent) void {
        if (self.punch_count < self.punch_ranges.len) {
            self.punch_ranges[self.punch_count] = .{
                .block_index = @intCast(extent.block_index),
                .block_count = @intCast(extent.block_count),
            };
            self.punch_count += 1;
        }
        const entry = switch (self.worker.takeSlotCredit(extent)) {
            .ok => |slot| slot,
            .empty, .mismatch => {
                self.ledger_misses += 1;
                return;
            },
        };
        if (entry.credit.isNone() and entry.fetch_id == 0)
            return;
        self.engine.releaseExtentCredit(
            self.worker.session_id,
            entry.fetch_id,
            entry.body_id,
            entry.credit,
        );
        self.credited += 1;
    }
};

fn testIdentity(body_id: u64) FetchBodyIdentity {
    return .{
        .request_id = 1,
        .request_generation = 1,
        .fetch_id = 11,
        .body_id = body_id,
    };
}

fn packetKind(packet: []const u8) !ipc.MessageKind {
    if (packet.len < @sizeOf(u32))
        return error.InvalidEgressPacket;
    return try ipc.decodeMessageKind(ipc.packet.readStruct(u32, packet[0..@sizeOf(u32)]));
}

/// Pulls at most one decoded chunk into `out`, as the tests in
/// `egress/tests/core/encoded_body.zig` do.
fn pullAppend(body: *fetch_body.Body, out: *std.array_list.Aligned(u8, null)) !void {
    _ = body.beginPull(.{ .deferred = null }) catch |err| switch (err) {
        error.FetchBodyReadInProgress => {},
        else => return err,
    };
    var pull = try body.drainReadyForPull(std.testing.allocator);
    defer pull.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), pull.credits.slice().len);
    if (pull.bytes.isPresent())
        try out.appendSlice(std.testing.allocator, pull.bytes.bytes());
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
