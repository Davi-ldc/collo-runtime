//! Assembly of pooled request bodies in the gateway (`runtime/upload_flow.zig`): an admitted
//! body-pooled fetch waits in its record while the worker streams upload-pool extents, each copied
//! into a buffer from the gateway's budgeted upload allocator and released at once, and reaches
//! its shard's engine with the buffer once the announced length arrived. The record and the
//! copies of the start come from the same budget, and the session's bytes in flight count them
//! with the body; a full upload budget fails one start; an upload still
//! assembling at its token's deadline fails and frees its buffer; a running total that disagrees
//! fails the fetch and keeps the session, while an extent the pool rejects removes the session;
//! an extent for a fetch that ended goes back to the pool. Buffers never count against a shard's
//! budget. Lane: egress-gateway-test. Admission's other checks are covered in `command_flow.zig`
//! and the counts at every ending in `fetch_flow.zig`.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");

const support = @import("support/gateway.zig");

const runtime = gateway.runtime;
const Harness = support.Harness;

/// Hands one upload batch of `chunk` to the gateway's dispatch and returns whether the session
/// stays.
fn sendUploadChunk(harness: *Harness, chunk: ipc.EgressUploadChunkView) !bool {
    const bytes = try ipc.encodeEgressUploadChunkBatchInto(harness.encode_scratch, .{ .chunks = &.{chunk} });
    return harness.sendCommand(bytes);
}

// The copies of a pooled start's method, URL and headers used to come from the gateway's own
// heap, which no budget counts, and the session's upload bytes counted the body alone.
test "a pooled start's record, copies and buffer come from the upload budget and its upload bytes count them, until a stop ends it" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const headers = [_]ipc.RequestHeader{.{ .name = "x-upload", .value = "chunked-by-worker" }};
    var url_buffer: [support.loopback_url_bytes_max]u8 = undefined;
    const url = support.loopbackUrl(&url_buffer, 1);
    const start = try ipc.encodeEgressFetchStartInto(harness.encode_scratch, .{
        .fetch_id = 1,
        .egress_token = harness.token(.{}),
        .body_id = 1,
        .flags = ipc.egress_fetch_start_flag_body_pooled,
        .method = "POST",
        .url = url,
        .headers = &headers,
        .body = "",
        .pooled_body_len = 64,
    });
    try std.testing.expect(harness.sendCommand(start));
    try harness.expectNoMoreCompletionPackets();

    const held = ipc.fetch_limits.pooledStartHeldBytes("POST".len, url.len, &headers);
    try std.testing.expectEqual(64 + held, harness.session().upload_bytes_in_flight);
    // The buffer, the record and the copies, each no larger than what `held` counts for it.
    const live = harness.gateway.upload_memory.liveBytes();
    try std.testing.expect(live > 64 + "POST".len + url.len);
    try std.testing.expect(live <= 64 + held);

    // A stop ends the upload at once, since it holds no task, and returns all of it.
    try std.testing.expect(harness.sendStop(1));
    try harness.expectAbortAck(1, 1);
    try std.testing.expect(harness.record(1) == null);
    try std.testing.expectEqual(@as(u64, 0), harness.session().upload_bytes_in_flight);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.upload_memory.liveBytes());
}

test "an upload still assembling at its token's deadline fails and frees its buffer" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const deadline = support.live_deadline_ns - 3;

    try harness.expectAdmitted(.{
        .fetch_id = 1,
        .body_id = 2,
        .token = harness.token(.{ .deadline_monotonic_ns = deadline }),
        .pooled_body_len = 64,
    });
    // The buffer, with the record and the start's copies beside it.
    try std.testing.expect(harness.gateway.upload_memory.liveBytes() > 64);

    // Before its deadline a pass leaves the upload alone.
    runtime.upload_flow.expire(harness.gateway, deadline - 1);
    try std.testing.expect(harness.record(1) != null);
    try harness.expectNoMoreCompletionPackets();

    runtime.upload_flow.expire(harness.gateway, deadline);
    try harness.expectFetchError(1, 2, "egress upload deadline exceeded");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(1) == null);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.upload_memory.liveBytes());
    try std.testing.expectEqual(@as(u64, 0), harness.session().upload_bytes_in_flight);
    try std.testing.expect(harness.gateway.uploads_by_deadline.first == null);
}

test "uploads expire in deadline order whatever order they arrived in" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const base = support.live_deadline_ns - 100;

    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{ .deadline_monotonic_ns = base + 30 }), .pooled_body_len = 8 });
    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{ .deadline_monotonic_ns = base + 10 }), .pooled_body_len = 8 });
    try harness.expectAdmitted(.{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{ .deadline_monotonic_ns = base + 20 }), .pooled_body_len = 8 });

    runtime.upload_flow.expire(harness.gateway, base + 20);
    try harness.expectFetchError(2, 2, "egress upload deadline exceeded");
    try harness.expectFetchError(3, 3, "egress upload deadline exceeded");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(1) != null);
}

test "a full gateway upload budget refuses the next pooled start alone" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 1, .body_id = 1, .token = harness.token(.{}), .pooled_body_len = 64 });
    // The budget is now exactly what the first upload holds.
    const live = harness.gateway.upload_memory.liveBytes();
    harness.gateway.upload_memory.setBudget(live);
    try std.testing.expect(try harness.sendFetchStart(.{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{}), .pooled_body_len = 1 }));
    try harness.expectFetchError(2, 2, "OutOfMemory");
    try harness.expectNoMoreCompletionPackets();
    // The refused fetch holds no record, copy, buffer or upload bytes.
    try std.testing.expect(harness.record(2) == null);
    try std.testing.expectEqual(live, harness.gateway.upload_memory.liveBytes());
    try std.testing.expectEqual(support.pooledStartBytes(1, 64), harness.session().upload_bytes_in_flight);
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);
}

test "an extent whose running total disagrees fails its fetch and keeps the session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 7, .body_id = 8, .token = harness.token(.{}), .pooled_body_len = 32 });
    const handle = try harness.writeUploadExtent(&[_]u8{0xab} ** 32);
    // `body_bytes_total` must equal the bytes received so far (0) plus `len` (32).
    try std.testing.expect(try sendUploadChunk(&harness, .{
        .fetch_id = 7,
        .upload_pool_offset = handle,
        .len = 32,
        .body_bytes_total = 99,
    }));
    try harness.expectFetchError(7, 8, "egress upload ledger mismatch");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(7) == null);
    try std.testing.expect(!harness.session().drop_pending);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.upload_memory.liveBytes());
    // The gateway queued the extent's release; the worker's drain frees it.
    try harness.worker_endpoint.upload_pool.drainReleasedChunks();
    try std.testing.expectEqual(@as(usize, 0), (try harness.worker_endpoint.upload_pool.usage()).used);
}

test "an extent the pool rejects removes the session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 9, .body_id = 10, .token = harness.token(.{}), .pooled_body_len = 32 });
    // No published extent has this handle, which only corrupt shared state names.
    try std.testing.expect(!try sendUploadChunk(&harness, .{
        .fetch_id = 9,
        .upload_pool_offset = 0x7777_0000_0000_0003,
        .len = 32,
        .body_bytes_total = 32,
    }));
}

test "an extent for a fetch that ended goes back to the pool quietly" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const handle = try harness.writeUploadExtent(&[_]u8{0xcd} ** 16);
    try std.testing.expect(try sendUploadChunk(&harness, .{
        .fetch_id = 4242,
        .upload_pool_offset = handle,
        .len = 16,
        .body_bytes_total = 16,
    }));
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.session().drop_pending);
    try harness.worker_endpoint.upload_pool.drainReleasedChunks();
    try std.testing.expectEqual(@as(usize, 0), (try harness.worker_endpoint.upload_pool.usage()).used);
}

test "a body-pooled fetch waits for its body, then reaches the engine with its token's request and deadline" {
    var harness = try Harness.init(.{ .start_shards = true });
    defer harness.deinit();
    const deadline = support.live_deadline_ns - 11;
    const payload = [_]u8{0xee} ** 48;

    try harness.expectAdmitted(.{
        .fetch_id = 11,
        .body_id = 12,
        .token = harness.token(.{ .deadline_monotonic_ns = deadline }),
        .pooled_body_len = payload.len,
    });
    const waiting = harness.record(11).?;
    try std.testing.expect(waiting.stage == .assembling);
    try std.testing.expectEqual(deadline, waiting.stage.assembling.grant.deadline_mono_ns);

    // One extent carries the whole announced body, so the fetch goes to its engine with the
    // buffer handed to the task.
    const handle = try harness.writeUploadExtent(&payload);
    try std.testing.expect(try sendUploadChunk(&harness, .{
        .fetch_id = 11,
        .upload_pool_offset = handle,
        .len = payload.len,
        .body_bytes_total = payload.len,
    }));
    const running = harness.record(11) orelse return error.MissingRecord;
    try std.testing.expect(running.stage == .running);
    const task = running.stage.running.task;
    try std.testing.expectEqual(support.request_id, task.response_body.identity.request_id);
    try std.testing.expectEqual(support.request_generation, task.response_body.identity.request_generation);
    try std.testing.expectEqualSlices(u8, &payload, task.body);
    try std.testing.expect(harness.gateway.uploads_by_deadline.first == null);
}

test "removing the session frees its assembling uploads with their records and counts" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const session_id = harness.session_id;

    try harness.expectAdmitted(.{ .fetch_id = 31, .body_id = 32, .token = harness.token(.{}), .pooled_body_len = 64 });
    try runtime.session_flow.removeSession(harness.gateway, harness.gateway.sessions.indexOf(session_id).?, .dropped);
    try harness.expectSessionRemovedReport(session_id, .protocol_violation);

    // The testing allocator's leak check at `deinit` shows the buffer went with the record.
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.fetches.count());
    try std.testing.expectEqual(@as(u32, 0), harness.gateway.fetches.cellCount(support.security_cell_id));
    try std.testing.expect(harness.gateway.uploads_by_deadline.first == null);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.upload_memory.liveBytes());
}

test "an assembled upload the engine refuses frees its buffer without moving its shard's memory count" {
    // An engine that never started refuses the submission after the fetch's task took the
    // buffer, so the task ends inside the submit, on this thread.
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const shard_memory = harness.gateway.shards.get(0).memory;
    const live_bytes_before = shard_memory.liveBytes();
    const payload = [_]u8{0x5c} ** 48;

    try harness.expectAdmitted(.{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{}), .pooled_body_len = payload.len });
    const handle = try harness.writeUploadExtent(&payload);
    try std.testing.expect(try sendUploadChunk(&harness, .{
        .fetch_id = 2,
        .upload_pool_offset = handle,
        .len = payload.len,
        .body_bytes_total = payload.len,
    }));

    try harness.expectFetchError(2, 2, "EgressEngineUnavailable");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(2) == null);
    try std.testing.expectEqual(live_bytes_before, shard_memory.liveBytes());
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.upload_memory.liveBytes());
}

test "an upload stopped halfway leaves its shard's memory count unchanged" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const shard_memory = harness.gateway.shards.get(0).memory;
    const live_bytes_before = shard_memory.liveBytes();

    try harness.expectAdmitted(.{ .fetch_id = 3, .body_id = 3, .token = harness.token(.{}), .pooled_body_len = 64 });
    const handle = try harness.writeUploadExtent(&[_]u8{0x3c} ** 32);
    try std.testing.expect(try sendUploadChunk(&harness, .{
        .fetch_id = 3,
        .upload_pool_offset = handle,
        .len = 32,
        .body_bytes_total = 32,
    }));
    try std.testing.expect(harness.sendStop(3));
    try harness.expectAbortAck(3, 3);

    try std.testing.expect(harness.record(3) == null);
    try std.testing.expectEqual(live_bytes_before, shard_memory.liveBytes());
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.upload_memory.liveBytes());
}

test "a pooled start whose announced length is zero or above the policy's cap is refused before any buffer exists" {
    var harness = try Harness.init(.{ .policy = .{ .max_request_body_bytes = 1024 } });
    defer harness.deinit();

    // The wire codec refuses a pooled start of length zero, so the shape check is reached
    // through a decoded view handed to it directly.
    try std.testing.expectError(
        error.EgressGatewayRequestBodyLimitExceeded,
        gateway.policy.checkStart(support.pooledFetchView(1, 1, 0), harness.gateway.policy),
    );
    try harness.expectRefused(
        .{ .fetch_id = 2, .body_id = 2, .token = harness.token(.{}), .pooled_body_len = 1025 },
        "EgressGatewayRequestBodyLimitExceeded",
    );
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.upload_memory.liveBytes());
}
