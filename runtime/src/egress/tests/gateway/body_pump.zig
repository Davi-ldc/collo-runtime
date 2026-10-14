//! The gateway's pump from a fetch's task and response queue into packets for its worker
//! (`runtime/body_pump.zig`), driven on fetches the harness puts in the table without an engine
//! thread and read back from the worker's side of a real endpoint. The head goes out once the
//! task settles with success and arms the queue; a failure result ends the fetch with its message
//! and cause, and a canceled settlement with "fetch canceled"; pulled chunks publish as one batch
//! per flush, split at the policy's chunk size with the flow-control credit on the last extent,
//! and body end follows the queue's completion and retires the record. A credit-only chunk
//! publishes nothing. The drain never pulls a chunk the worker's body pool or completion ring
//! could not take: it stops with the queue armed, keeps the fetch and the session, and resumes
//! once the worker returns extents or, through the attention pass, reads its ring, so a body
//! several times the pool completes without loss. A head the ring has no room for waits the same
//! way, its fetch and session kept, until the attention pass finds the ring read. Response heads past the policy's limits fail
//! the fetch once the engine dropped its stream. Every credit goes back to the engine once, read
//! through the engine's credit counts: at once for a chunk without bytes, after the worker's
//! release for a published one, at retirement for a queued one, and from the batch when a
//! publication fails for memory, which fails that fetch alone. Lane: egress-gateway-test. The
//! counts each ending lowers are covered in `fetch_flow.zig` and the release drain in
//! `release_flow.zig`.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const http = @import("collo_http");
const ipc = @import("collo_ipc");
const egress = @import("collo_egress_client");

const support = @import("support/gateway.zig");

const body_credit = egress.body_credit;
const fetch_table = gateway.fetch_table;
const publisher = gateway.publisher;
const runtime = gateway.runtime;
const Harness = support.Harness;

const chunk_bytes_max = gateway.policy.production.max_body_chunk_bytes;

/// A pool's worth of zero bytes in `chunk_bytes_max` pieces, published for an unrelated fetch to
/// take pool room the test controls. It is never written.
const filler_bytes = [_]u8{0} ** chunk_bytes_max;

fn appendChunk(harness: *Harness, fetch: support.RunningFetch, bytes: []const u8, credit: body_credit.Handle) !void {
    const allocator = harness.gateway.shards.get(0).engine.allocator;
    const owned = try allocator.dupe(u8, bytes);
    errdefer allocator.free(owned);
    _ = try fetch.queue.appendOwnedChunk(allocator, owned, credit);
}

/// Appends `len` bytes of `value`, allocated as an engine appends them.
fn appendFilled(harness: *Harness, fetch: support.RunningFetch, value: u8, len: usize) !void {
    const allocator = harness.gateway.shards.get(0).engine.allocator;
    const owned = try allocator.alloc(u8, len);
    errdefer allocator.free(owned);
    @memset(owned, value);
    _ = try fetch.queue.appendOwnedChunk(allocator, owned, .none);
}

/// Settles `fetch`'s task with a head of status 200 and `headers`, copied into the task's result
/// arena as the engine copies a response's headers.
fn settleWithHeaders(fetch: support.RunningFetch, headers: []const http.Header) !void {
    const task = fetch.task;
    task.mutex.lock();
    defer task.mutex.unlock();
    const arena = task.resultAllocator();
    const copied = try arena.alloc(http.Header, headers.len);
    for (headers, copied) |header, *slot|
        slot.* = .{ .name = try arena.dupe(u8, header.name), .value = try arena.dupe(u8, header.value) };
    task.result = .{ .success = .{
        .status = 200,
        .url = try arena.dupe(u8, "https://origin.test/"),
        .headers = copied,
    } };
    task.done = true;
}

fn settleFailure(fetch: support.RunningFetch, message: []const u8, cause: egress.task.FailureCause) void {
    fetch.task.mutex.lock();
    defer fetch.task.mutex.unlock();
    fetch.task.result = .{ .failure = .{ .message = message, .cause = cause } };
    fetch.task.done = true;
}

fn packetKind(bytes: []const u8) !ipc.MessageKind {
    if (bytes.len < @sizeOf(u32))
        return error.ShortRead;
    return ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)]));
}

/// The worker's side of a body: reads every packet the gateway wrote for fetch `fetch_id`, checks
/// each extent's bytes against `expected` from `received` on and counts them. It returns the
/// oldest extents it holds to the pool until it holds at most `hold_bytes_max`, so a reader that
/// keeps extents stands in for a worker that consumes its body slowly. `readAll` returns whether
/// body end arrived.
const BodyReader = struct {
    harness: *Harness,
    scratch: *ipc.WorkerEgressDecodeScratch,
    hold_bytes_max: usize = 0,
    received: usize = 0,
    batches: usize = 0,
    /// Extents read and not yet returned, oldest first; the pool holds at most one per slot.
    held: [ipc.egress_shared.body_pool_slot_count]ipc.EgressBodyChunkView = undefined,
    held_len: usize = 0,
    held_bytes: usize = 0,

    fn init(harness: *Harness, hold_bytes_max: usize) !BodyReader {
        return .{
            .harness = harness,
            .scratch = try std.testing.allocator.create(ipc.WorkerEgressDecodeScratch),
            .hold_bytes_max = hold_bytes_max,
        };
    }

    fn deinit(self: *BodyReader) void {
        std.testing.allocator.destroy(self.scratch);
        self.* = undefined;
    }

    fn releaseOldest(self: *BodyReader) !void {
        std.debug.assert(self.held_len != 0);
        const oldest = self.held[0];
        try self.harness.worker_endpoint.body_pool.releaseChunk(oldest.body_pool_offset, oldest.len);
        std.mem.copyForwards(ipc.EgressBodyChunkView, self.held[0 .. self.held_len - 1], self.held[1..self.held_len]);
        self.held_len -= 1;
        self.held_bytes -= oldest.len;
    }

    fn readAll(self: *BodyReader, fetch_id: u64, expected: []const u8) !bool {
        const endpoint = &self.harness.worker_endpoint;
        while (try endpoint.completion.readPacket(self.harness.read_buffer)) |packet| {
            switch (try packetKind(packet)) {
                .egress_body_chunk_batch => {
                    self.batches += 1;
                    for (try ipc.decodeEgressBodyChunkBatch(self.scratch, packet)) |chunk| {
                        try std.testing.expectEqual(fetch_id, chunk.fetch_id);
                        const bytes = try endpoint.body_pool.borrowContiguousChunk(chunk.body_pool_offset, chunk.len);
                        try std.testing.expectEqualSlices(u8, expected[self.received..][0..bytes.len], bytes);
                        self.received += bytes.len;
                        self.held[self.held_len] = chunk;
                        self.held_len += 1;
                        self.held_bytes += chunk.len;
                        while (self.held_bytes > self.hold_bytes_max)
                            try self.releaseOldest();
                    }
                },
                .egress_body_end => {
                    const end = try ipc.decodeEgressBodyEnd(packet);
                    try std.testing.expectEqual(fetch_id, end.fetch_id);
                    return true;
                },
                else => return error.UnexpectedEgressPacket,
            }
        }
        return false;
    }
};

/// Reads one body chunk batch from the worker's side and copies its extents into `out`, without
/// reading or returning them; returns how many there were.
fn takeBatchExtents(harness: *Harness, out: []ipc.EgressBodyChunkView) !usize {
    const scratch = try std.testing.allocator.create(ipc.WorkerEgressDecodeScratch);
    defer std.testing.allocator.destroy(scratch);
    const packet = (try harness.worker_endpoint.completion.readPacket(harness.read_buffer)) orelse
        return error.MissingQueuedBodyChunks;
    const chunks = try ipc.decodeEgressBodyChunkBatch(scratch, packet);
    @memcpy(out[0..chunks.len], chunks);
    return chunks.len;
}

/// Publishes `chunk_count` filler chunks of `chunk_bytes_max` for a fetch the table does not hold,
/// as if an earlier fetch's body still sat in the worker's pool, and returns their extents from
/// the worker's side.
fn occupyPool(harness: *Harness, chunk_count: usize, extents_out: []ipc.EgressBodyChunkView) !usize {
    var payloads: [ipc.egress_shared.body_pool_slot_count]publisher.BodyChunkPayload = undefined;
    for (payloads[0..chunk_count]) |*payload|
        payload.* = .{ .bytes = &filler_bytes };
    const filler = fetch_table.Fetch{
        .session_id = harness.session_id,
        .fetch_id = 999,
        .body_id = 999,
        .shard_index = 0,
        .upload_bytes = 0,
        .stage = .admitting,
    };
    const run = harness.gateway.shards.get(0).engine.run;
    _ = try runtime.session_flow.publishBody(harness.gateway, harness.session(), &filler, run, payloads[0..chunk_count]);
    return takeBatchExtents(harness, extents_out);
}

test "one HTTP/2 DATA frame of the default frame size fits one body-pool block" {
    // 16384 is the initial SETTINGS_MAX_FRAME_SIZE of RFC 9113 section 6.5.2, which the egress
    // engine never raises, so an HTTP/2 chunk takes one block and one ring descriptor.
    try std.testing.expectEqual(@as(usize, 16384), ipc.egress_shared.body_pool_block_size);
}

test "the head goes out once the task settles with success, and the queue is armed for the body" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(1, 2, 0);

    // Before the task settles the pump has nothing to send.
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.record(1).?.head_sent);

    try harness.settleSuccess(fetch, 204);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try std.testing.expectEqual(@as(u16, 204), try harness.expectHead(1));
    try harness.expectNoMoreCompletionPackets();
    const record = harness.record(1).?;
    try std.testing.expect(record.head_sent);
    try std.testing.expect(record.pull_armed);
    try std.testing.expect(fetch.queue.pull_armed);
    try std.testing.expect(record.ending == null);

    // A second pump sends the head once only.
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try harness.expectNoMoreCompletionPackets();
}

test "a failure result ends the fetch with its message and keeps a denial's cause" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const failed = try harness.startRunningFetch(1, 2, 0);
    settleFailure(failed, "fetch failed: connection refused", .failed);
    try runtime.body_pump.pump(harness.gateway, failed.handle);
    try harness.expectFetchErrorWithCause(1, 2, "fetch failed: connection refused", .failed);

    const denied = try harness.startRunningFetch(3, 4, 0);
    settleFailure(denied, "egress denied https://10.0.0.1: the host is private", .network_denied);
    try runtime.body_pump.pump(harness.gateway, denied.handle);
    try harness.expectFetchErrorWithCause(3, 4, "egress denied https://10.0.0.1: the host is private", .network_denied);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(1) == null);
    try std.testing.expect(harness.record(3) == null);
}

test "a task the engine settled as canceled fails its fetch with fetch canceled" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(5, 6, 0);

    harness.settleCanceled(fetch);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try harness.expectFetchError(5, 6, "fetch canceled");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(5) == null);
}

test "queued chunks publish as one batch and body end follows the queue's completion" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(7, 8, 0);
    try harness.settleSuccess(fetch, 200);
    try appendChunk(&harness, fetch, "aaa", .none);
    try appendChunk(&harness, fetch, "bbb", .none);
    try appendChunk(&harness, fetch, "ccc", .none);
    _ = fetch.queue.complete();

    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try std.testing.expectEqual(@as(u16, 200), try harness.expectHead(7));
    var body: [16]u8 = undefined;
    var extents: [8]ipc.EgressBodyChunkView = undefined;
    const received = try harness.expectBodyChunks(7, &body, &extents);
    try std.testing.expectEqual(@as(usize, 3), received.extents);
    try std.testing.expectEqualStrings("aaabbbccc", body[0..received.bytes]);
    try harness.expectBodyEnd(7, 8);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(7) == null);
    try harness.releaseExtents(extents[0..received.extents]);
}

test "a credit-only chunk publishes nothing, and the body end that follows it still goes out" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(9, 10, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(9);

    // The empty final DATA frame of an HTTP/2 stream carries the credit that surfaces its end.
    var empty = [_]u8{};
    _ = try fetch.queue.appendOwnedChunk(
        harness.gateway.shards.get(0).engine.allocator,
        &empty,
        body_credit.h2Data(5, 1, 0, false),
    );
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expectEqual(@as(u32, 0), harness.session().extents.outstanding);

    _ = fetch.queue.complete();
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try harness.expectBodyEnd(9, 10);
    try harness.expectNoMoreCompletionPackets();
}

test "a chunk past the policy's chunk size splits into several extents with its credit on the last" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(11, 12, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(11);

    const credit = body_credit.h2Data(7, 3, chunk_bytes_max + 4096, true);
    const allocator = harness.gateway.shards.get(0).engine.allocator;
    const owned = try allocator.alloc(u8, chunk_bytes_max + 4096);
    @memset(owned, 0x5a);
    _ = fetch.queue.appendOwnedChunk(allocator, owned, credit) catch |err| {
        allocator.free(owned);
        return err;
    };
    try runtime.body_pump.pump(harness.gateway, fetch.handle);

    var extents: [ipc.egress_shared.body_pool_slot_count]ipc.EgressBodyChunkView = undefined;
    const count = try takeBatchExtents(&harness, &extents);
    try std.testing.expect(count >= 2);
    const ledger = harness.session().extents.entries.?;
    var total: usize = 0;
    for (extents[0..count], 0..) |extent, index| {
        total += extent.len;
        const entry = ledger[try ipc.egress_shared.slotIndexForHandle(extent.body_pool_offset)];
        try std.testing.expectEqual(@as(u32, @intCast(extent.len)), entry.len);
        if (index == count - 1) {
            try std.testing.expectEqual(credit, entry.credit);
        } else {
            try std.testing.expect(entry.credit.isNone());
        }
    }
    try std.testing.expectEqual(chunk_bytes_max + 4096, total);
    try harness.expectNoMoreCompletionPackets();
}

test "a drain that would not fit the pool stops with the fetch and the session kept, and resumes after the worker returns extents" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(13, 14, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(13);

    // An earlier body the worker has not read leaves the pool exactly the room of one largest
    // pull, so the drain takes one chunk, publishes it and stops before the next.
    const blocks_per_chunk = publisher.blockCountForBytes(chunk_bytes_max);
    const largest_pull_blocks = publisher.blockCountForBytes(egress.stream_pump.default_max_pending_decoded_bytes);
    const filler_chunks = (ipc.egress_shared.body_pool_slot_count - largest_pull_blocks) / blocks_per_chunk;
    var filler: [ipc.egress_shared.body_pool_slot_count]ipc.EgressBodyChunkView = undefined;
    const filler_count = try occupyPool(&harness, filler_chunks, &filler);
    try std.testing.expectEqual(largest_pull_blocks, harness.session().endpoint.body_pool.freeBlocks());

    try appendFilled(&harness, fetch, 0x11, chunk_bytes_max);
    try appendFilled(&harness, fetch, 0x22, chunk_bytes_max);
    _ = fetch.queue.complete();
    try runtime.body_pump.pump(harness.gateway, fetch.handle);

    const expected = try std.testing.allocator.alloc(u8, 2 * chunk_bytes_max);
    defer std.testing.allocator.free(expected);
    @memset(expected[0..chunk_bytes_max], 0x11);
    @memset(expected[chunk_bytes_max..], 0x22);
    var reader = try BodyReader.init(&harness, 0);
    defer reader.deinit();
    try std.testing.expect(!try reader.readAll(13, expected));
    try std.testing.expectEqual(chunk_bytes_max, reader.received);
    // The second chunk waits in the queue, armed, and nothing failed.
    const waiting = harness.record(13).?;
    try std.testing.expect(waiting.ending == null);
    try std.testing.expect(waiting.pull_armed);
    try std.testing.expect(!harness.session().drop_pending);

    // The worker reads the earlier body; the release drain sees the room and the attention pass
    // pumps the waiting fetch.
    for (filler[0..filler_count]) |extent|
        try harness.worker_endpoint.body_pool.releaseChunk(extent.body_pool_offset, extent.len);
    runtime.release_flow.drainReleases(harness.gateway, harness.session());
    try std.testing.expect(harness.session().rescan_pending);
    try runtime.session_flow.processAttention(harness.gateway, 1);
    try std.testing.expect(try reader.readAll(13, expected));
    try std.testing.expectEqual(2 * chunk_bytes_max, reader.received);
    try std.testing.expect(harness.record(13) == null);
}

test "a drain that would not fit the completion ring stops without failing the fetch, and resumes once the worker reads the ring" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(15, 16, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(15);

    // Packets the worker has not read leave the ring less room than one batch descriptor needs.
    const completion = &harness.session().endpoint.completion;
    var junk_packets: usize = 0;
    for ([_]usize{ 65_536, 4096, 256, 16, 1 }) |size| {
        while (true) : (junk_packets += 1) {
            _ = completion.writePacket(filler_bytes[0..size]) catch |err| switch (err) {
                error.EgressSharedRingFull => break,
                else => return err,
            };
        }
    }

    try appendChunk(&harness, fetch, "payload", .none);
    _ = fetch.queue.complete();
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    const waiting = harness.record(15).?;
    try std.testing.expect(waiting.ending == null);
    try std.testing.expect(!harness.session().drop_pending);

    // Reading the ring announces nothing to the gateway, so the stopped drain left the session
    // waiting in the attention list.
    try std.testing.expect(harness.session().ring_room_pending);
    try std.testing.expect(harness.session().attention_queued);

    var drained: usize = 0;
    while (try harness.worker_endpoint.completion.readPacket(harness.read_buffer)) |packet| : (drained += 1)
        try std.testing.expect(packet.len <= 65_536);
    try std.testing.expectEqual(junk_packets, drained);

    // The worker returned no extent, so only the attention pass's look at the ring brings the
    // fetch back.
    try runtime.session_flow.processAttention(harness.gateway, 1);
    try std.testing.expect(!harness.session().ring_room_pending);
    var reader = try BodyReader.init(&harness, 0);
    defer reader.deinit();
    try std.testing.expect(try reader.readAll(15, "payload"));
    try std.testing.expect(harness.record(15) == null);
}

test "a head the completion ring has no room for waits with its fetch and session kept, and goes out once the worker reads the ring" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(29, 30, 0);

    // Packets the worker has not read leave the ring no room for a head, as a worker in a long
    // turn leaves it while heads of its other fetches land.
    const completion = &harness.session().endpoint.completion;
    var junk_packets: usize = 0;
    for ([_]usize{ 65_536, 4096, 256, 16, 1 }) |size| {
        while (true) : (junk_packets += 1) {
            _ = completion.writePacket(filler_bytes[0..size]) catch |err| switch (err) {
                error.EgressSharedRingFull => break,
                else => return err,
            };
        }
    }

    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    const waiting = harness.record(29) orelse return error.TestHeadFetchEnded;
    try std.testing.expect(!waiting.head_sent);
    try std.testing.expect(waiting.ending == null);
    try std.testing.expect(!harness.session().drop_pending);
    try std.testing.expect(harness.session().ring_room_pending);
    try std.testing.expect(harness.session().attention_queued);

    var drained: usize = 0;
    while (try harness.worker_endpoint.completion.readPacket(harness.read_buffer)) |_|
        drained += 1;
    try std.testing.expectEqual(junk_packets, drained);

    // Reading the ring announces nothing, so the attention pass's look at it sends the head.
    try runtime.session_flow.processAttention(harness.gateway, 1);
    try std.testing.expectEqual(@as(u16, 200), try harness.expectHead(29));
    const sent = harness.record(29) orelse return error.TestHeadFetchEnded;
    try std.testing.expect(sent.head_sent);
    try std.testing.expect(!harness.session().drop_pending);
}

test "a session whose ring still lacks room for a drain stays in the attention list and keeps its fetch waiting" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(27, 28, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(27);

    const completion = &harness.session().endpoint.completion;
    for ([_]usize{ 65_536, 4096, 256, 16, 1 }) |size| {
        while (true) {
            _ = completion.writePacket(filler_bytes[0..size]) catch |err| switch (err) {
                error.EgressSharedRingFull => break,
                else => return err,
            };
        }
    }
    try appendChunk(&harness, fetch, "payload", .none);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try std.testing.expect(harness.session().ring_room_pending);

    // The worker has read nothing: the pass measures the ring, keeps the session listed and
    // pulls nothing.
    try runtime.session_flow.processAttention(harness.gateway, 1);
    try std.testing.expect(harness.session().ring_room_pending);
    try std.testing.expect(harness.session().attention_queued);
    try std.testing.expectEqual(@as(usize, 7), fetch.queue.queuedBytes());
    try std.testing.expect(harness.record(27).?.ending == null);
}

test "a body that fails after chunks went out ends with the queue's message, and chunks queued at the failure are dropped" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(17, 18, 0);
    try harness.settleSuccess(fetch, 200);
    try appendChunk(&harness, fetch, "abc", .none);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(17);
    var reader = try BodyReader.init(&harness, 0);
    defer reader.deinit();
    try std.testing.expect(!try reader.readAll(17, "abc"));
    try std.testing.expectEqual(@as(usize, 3), reader.received);

    try appendChunk(&harness, fetch, "def", .none);
    _ = fetch.queue.fail(harness.gateway.shards.get(0).engine.allocator, "stream reset by origin");
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try harness.expectFetchError(17, 18, "stream reset by origin");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(17) == null);
}

test "a body several times the pool completes through repeated release and pump rounds without loss or reordering" {
    const pool_bytes = ipc.egress_shared.body_pool_capacity;
    const total = 3 * pool_bytes;
    var harness = try Harness.init(.{ .policy = .{ .max_response_body_bytes = total } });
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(19, 20, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(19);

    const expected = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(expected);
    for (expected, 0..) |*byte, offset|
        byte.* = @intCast((offset / 4096 + offset) % 251);

    // The worker keeps three quarters of its pool unread, so most rounds the drain fills what is
    // left, stops for room, and goes on only after the worker returns its oldest extents.
    var reader = try BodyReader.init(&harness, pool_bytes - pool_bytes / 4);
    defer reader.deinit();
    // The engine stays at most this far ahead of the worker, as flow control keeps it.
    const ahead_max = 4 * 1024 * 1024;
    var appended: usize = 0;
    var finished = false;
    var rounds: usize = 0;
    while (!finished) : (rounds += 1) {
        if (rounds == 10_000)
            return error.TestTimeout;
        while (appended < total and appended - reader.received < ahead_max) {
            const len = @min(chunk_bytes_max, total - appended);
            try appendChunk(&harness, fetch, expected[appended..][0..len], .none);
            appended += len;
            if (appended == total)
                _ = fetch.queue.complete();
        }
        // The engine's wake after an append runs the pump; the worker's releases run the
        // release drain and then the attention pass.
        if (harness.record(19) != null)
            try runtime.body_pump.pump(harness.gateway, fetch.handle);
        finished = try reader.readAll(19, expected);
        runtime.release_flow.drainReleases(harness.gateway, harness.session());
        try runtime.session_flow.processAttention(harness.gateway, 1);
        if (!finished)
            finished = try reader.readAll(19, expected);
    }
    try std.testing.expectEqual(total, reader.received);
    try std.testing.expect(reader.batches > 3);
    try std.testing.expect(harness.record(19) == null);
    try std.testing.expect(!harness.session().drop_pending);
}

/// Plays the engine applying the gateway's cancel of `fetch`, whose head it published: it fails
/// the queue as it drops the stream, and the wake that failure asks for retires the record.
fn engineDropsStream(harness: *Harness, fetch: support.RunningFetch) void {
    _ = fetch.queue.fail(harness.gateway.shards.get(0).engine.allocator, "FetchAborted");
    runtime.fetch_flow.retireIfSettled(harness.gateway, fetch.handle);
}

test "a response head past the policy's header count or header bytes fails the fetch" {
    var harness = try Harness.init(.{ .policy = .{ .max_response_headers = 1, .max_response_header_bytes = 16 } });
    defer harness.deinit();

    // The refusal cancels the stream the engine still runs, and the error leaves once it let go.
    const counted = try harness.startRunningFetch(21, 22, 0);
    try settleWithHeaders(counted, &.{
        .{ .name = "a", .value = "1" },
        .{ .name = "b", .value = "2" },
    });
    try runtime.body_pump.pump(harness.gateway, counted.handle);
    engineDropsStream(&harness, counted);
    try harness.expectFetchError(21, 22, "too many response headers");

    const sized = try harness.startRunningFetch(23, 24, 0);
    try settleWithHeaders(sized, &.{.{ .name = "x-long", .value = "0123456789abcdef" }});
    try runtime.body_pump.pump(harness.gateway, sized.handle);
    engineDropsStream(&harness, sized);
    try harness.expectFetchError(23, 24, "response headers too large");

    const fitting = try harness.startRunningFetch(25, 26, 0);
    try settleWithHeaders(fitting, &.{.{ .name = "x", .value = "y" }});
    try runtime.body_pump.pump(harness.gateway, fitting.handle);
    try std.testing.expectEqual(@as(u16, 200), try harness.expectHead(25));
    try harness.expectNoMoreCompletionPackets();
}

test "every credit a body's chunks carry goes back to the engine once: at once without bytes, after the worker's release with them" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const engine = &harness.gateway.shards.get(0).engine;
    const fetch = try harness.startRunningFetch(31, 32, 0);
    try harness.settleSuccess(fetch, 200);
    try appendChunk(&harness, fetch, "abc", body_credit.h2Data(5, 1, 3, true));
    var empty = [_]u8{};
    _ = try fetch.queue.appendOwnedChunk(engine.allocator, &empty, body_credit.h2Data(5, 1, 2, true));
    try appendChunk(&harness, fetch, "defg", body_credit.h2Data(5, 1, 4, true));
    _ = fetch.queue.complete();
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(31);
    var body: [16]u8 = undefined;
    var extents: [8]ipc.EgressBodyChunkView = undefined;
    const received = try harness.expectBodyChunks(31, &body, &extents);
    try harness.expectBodyEnd(31, 32);

    // Only the credit without bytes is back; the others ride the extents the worker holds.
    try std.testing.expectEqual(@as(u64, 2), engine.credit_bytes_returned);
    try harness.releaseExtents(extents[0..received.extents]);
    runtime.release_flow.drainReleases(harness.gateway, harness.session());
    try std.testing.expectEqual(@as(u64, 2 + 3 + 4), engine.credit_bytes_returned);
    try std.testing.expectEqual(@as(u64, 0), engine.stale_credits_dropped);
}

test "a fetch that retires with chunks still queued gives each of their credits back once" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const engine = &harness.gateway.shards.get(0).engine;
    const fetch = try harness.startRunningFetch(33, 34, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(33);

    // Chunks arrive, and the worker stops the fetch before the gateway pulled them.
    try appendChunk(&harness, fetch, "abc", body_credit.h2Data(6, 1, 3, true));
    try appendChunk(&harness, fetch, "de", body_credit.h2Data(6, 1, 2, true));
    try std.testing.expect(harness.sendStop(33));
    try std.testing.expectEqual(@as(u64, 0), engine.credits_returned);

    engineDropsStream(&harness, fetch);
    try harness.expectAbortAck(33, 34);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expectEqual(@as(u64, 2), engine.credits_returned);
    try std.testing.expectEqual(@as(u64, 5), engine.credit_bytes_returned);
}

// The pump's one allocation is the session's extent ledger, from the gateway's own allocator, so
// its failure is the fetch's alone, and the batch that was publishing still owns its credits.
test "a publication that fails for memory fails the fetch alone, and every credit it staged goes back once" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const engine = &harness.gateway.shards.get(0).engine;
    const fetch = try harness.startRunningFetch(29, 30, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(29);
    try appendChunk(&harness, fetch, "abcd", body_credit.h2Data(4, 1, 4, true));
    try appendChunk(&harness, fetch, "efghij", body_credit.h2Data(4, 1, 6, true));
    _ = fetch.queue.complete();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const gateway_allocator = harness.gateway.allocator;
    const restarted = restarted: {
        harness.gateway.allocator = failing.allocator();
        defer harness.gateway.allocator = gateway_allocator;
        break :restarted try runtime.shard_flow.pumpOrSupervise(harness.gateway, fetch.handle);
    };
    try std.testing.expect(!restarted);
    try std.testing.expect(failing.has_induced_failure);

    try harness.expectFetchError(29, 30, "egress internal error");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(29) == null);
    try std.testing.expect(!harness.session().drop_pending);
    try std.testing.expectEqual(@as(u32, 0), harness.session().extents.outstanding);
    try std.testing.expectEqual(@as(u64, 2), engine.credits_returned);
    try std.testing.expectEqual(@as(u64, 10), engine.credit_bytes_returned);
}
