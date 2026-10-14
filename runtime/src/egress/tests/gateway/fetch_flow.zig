//! How a gateway fetch ends (`runtime/fetch_flow.zig`): whichever way it ends, the worker gets one
//! terminal packet, or none when its session is gone, and the fetch's session count, cell count
//! and upload bytes drop at that instant, the lifetime the worker counts the fetch over. An ending
//! the gateway decides while the engine still holds the fetch, before or after its head, cancels
//! the fetch in the engine, and the record keeps its place under the cap until the engine let go;
//! a session that goes cancels what the engine still runs for it. With live engine threads and an
//! origin that holds its body open, a stop after the head and a session's removal each close the
//! origin's connection. A stop for a fetch the gateway no longer has changes nothing. A record
//! never outlives its terminal packet: the extents the worker still holds stay in the session's
//! ledger. Lane: egress-gateway-test. Admission is covered in `command_flow.zig`, the body drain
//! in `body_pump.zig`, uploads in `upload_flow.zig` and shard restarts in `shard_flow.zig`.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const egress = @import("collo_egress_client");
const http = @import("collo_http");

const holding_origin = @import("support/holding_origin.zig");
const policy_image = @import("support/policy_image.zig");
const support = @import("support/gateway.zig");

const runtime = gateway.runtime;
const Harness = support.Harness;
const HoldingOrigin = holding_origin.HoldingOrigin;

/// How long one wait for an engine thread's wake lasts before a live test fails, and how many
/// collection rounds it runs at most.
const wake_timeout_ms: i32 = 5_000;
const collection_rounds_max: usize = 64;
/// How long a live test waits for the origin to see its connection closed. The stall clock of
/// `liveTestPolicy` is far longer, so only the engine's cancel closes it in that time.
const close_timeout_ms: i32 = 5_000;

/// Production's limits with a stall clock no live test outlasts, so an engine closes the origin's
/// connection while a test watches only because the fetch was canceled.
fn liveTestPolicy() gateway.policy.Policy {
    var limits = gateway.policy.production;
    limits.socket_timeout_ms = 10 * 60 * 1000;
    return limits;
}

/// Runs a collection pass on shard 0 each time its wake eventfd turns readable, until the record
/// of fetch `fetch_id` has sent its head (`until_head`) or is gone.
fn collectUntil(harness: *Harness, fetch_id: u64, until_head: bool) !void {
    const wake_fd = harness.gateway.shards.get(0).engine.wake_fd;
    var rounds: usize = 0;
    while (true) : (rounds += 1) {
        const record = harness.record(fetch_id);
        if (record == null)
            return;
        if (until_head and record.?.head_sent)
            return;
        if (rounds == collection_rounds_max)
            return error.TestTimeout;
        var pollfds = [_]std.posix.pollfd{.{ .fd = wake_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&pollfds, wake_timeout_ms) == 0)
            return error.TestTimeout;
        try runtime.shard_flow.collectShardReady(harness.gateway, 0);
    }
}

/// Reads the completion ring up to its first packet that is not a body batch of fetch
/// `fetch_id`, returning each batch's extents to the pool as the worker does, and returns that
/// packet, which lies in the harness's read buffer, or null when no other packet waits.
fn nextPacketAfterBody(harness: *Harness, fetch_id: u64) !?[]const u8 {
    const scratch = try std.testing.allocator.create(ipc.WorkerEgressDecodeScratch);
    defer std.testing.allocator.destroy(scratch);
    while (try harness.worker_endpoint.completion.readPacket(harness.read_buffer)) |packet| {
        const kind = try ipc.decodeMessageKind(ipc.packet.readStruct(u32, packet[0..@sizeOf(u32)]));
        if (kind != .egress_body_chunk_batch)
            return packet;
        for (try ipc.decodeEgressBodyChunkBatch(scratch, packet)) |chunk| {
            try std.testing.expectEqual(fetch_id, chunk.fetch_id);
            try harness.worker_endpoint.body_pool.releaseChunk(chunk.body_pool_offset, chunk.len);
        }
    }
    return null;
}

/// Sends the hello granting `origin`, admits fetch `fetch_id` to it and collects until its head
/// went out, which it reads.
fn startHeldFetch(harness: *Harness, origin: *const HoldingOrigin, fetch_id: u64, body_id: u64) !void {
    const image = try policy_image.withOrigin(std.testing.allocator, try origin.ipv4(), origin.port);
    defer std.testing.allocator.free(image);
    try harness.sendHelloImage(image);
    try harness.drainControl();
    var url_buffer: [holding_origin.url_bytes_max]u8 = undefined;
    try harness.expectAdmitted(.{
        .fetch_id = fetch_id,
        .body_id = body_id,
        .token = harness.token(.{ .policy_id = policy_image.origin_id }),
        .url = origin.url(&url_buffer),
    });
    try collectUntil(harness, fetch_id, true);
    try std.testing.expectEqual(@as(u16, 200), try harness.expectHead(fetch_id));
}

fn expectNothingCounted(harness: *Harness) !void {
    const session = harness.session();
    try std.testing.expectEqual(@as(u32, 0), session.fetches.len);
    try std.testing.expectEqual(@as(u64, 0), session.upload_bytes_in_flight);
    try std.testing.expectEqual(@as(u32, 0), harness.gateway.fetches.cellCount(support.security_cell_id));
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.fetches.count());
}

fn appendChunk(harness: *Harness, fetch: support.RunningFetch, bytes: []const u8) !void {
    const allocator = harness.gateway.shards.get(0).engine.allocator;
    const owned = try allocator.dupe(u8, bytes);
    errdefer allocator.free(owned);
    _ = try fetch.queue.appendOwnedChunk(allocator, owned, .none);
}

fn settleFailure(fetch: support.RunningFetch, message: []const u8) void {
    fetch.task.mutex.lock();
    defer fetch.task.mutex.unlock();
    fetch.task.result = .{ .failure = .{ .message = message } };
    fetch.task.done = true;
}

test "a fetch that ends with body end lowers every count at once, while its extents stay in the session's ledger" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const fetch = try harness.startRunningFetch(1, 2, 0);
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);
    try std.testing.expectEqual(@as(u32, 1), harness.gateway.fetches.cellCount(support.security_cell_id));
    try harness.settleSuccess(fetch, 200);
    try appendChunk(&harness, fetch, "hello");
    _ = fetch.queue.complete();
    try runtime.body_pump.pump(harness.gateway, fetch.handle);

    try std.testing.expectEqual(@as(u16, 200), try harness.expectHead(1));
    var body: [16]u8 = undefined;
    var extents: [4]ipc.EgressBodyChunkView = undefined;
    const received = try harness.expectBodyChunks(1, &body, &extents);
    try std.testing.expectEqualStrings("hello", body[0..received.bytes]);
    try harness.expectBodyEnd(1, 2);
    try harness.expectNoMoreCompletionPackets();

    // The body end is the terminal packet: the record is gone with its counts, though the worker
    // has not returned the extent yet.
    try expectNothingCounted(&harness);
    try std.testing.expect(harness.gateway.fetches.get(fetch.handle) == null);
    try std.testing.expectEqual(@as(u32, 1), harness.session().extents.outstanding);

    try harness.releaseExtents(extents[0..received.extents]);
    runtime.release_flow.drainReleases(harness.gateway, harness.session());
    try std.testing.expectEqual(@as(u32, 0), harness.session().extents.outstanding);
    try std.testing.expect(!harness.session().drop_pending);
}

test "a fetch whose task fails lowers every count when its error packet leaves" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const fetch = try harness.startRunningFetch(3, 4, 0);
    settleFailure(fetch, "connection refused");
    try runtime.body_pump.pump(harness.gateway, fetch.handle);

    try harness.expectFetchError(3, 4, "connection refused");
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
}

test "a stopped fetch keeps its place under the cap until its task settles, then sends one abort ack" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const fetch = try harness.startRunningFetch(5, 6, 0);
    try std.testing.expect(harness.sendStop(5));

    // The task has not settled, so nothing goes out and the fetch still counts: the session's
    // cap bounds the tasks its stopped fetches keep in the engines.
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);
    // The stop canceled the queue, which refuses the engine's appends and leaves its end to the
    // engine.
    try std.testing.expect(fetch.queue.canceled);
    try std.testing.expectEqual(egress.core.response_queue.State.open, fetch.queue.state);

    // A second stop before the settlement adds nothing.
    try std.testing.expect(harness.sendStop(5));
    try harness.expectNoMoreCompletionPackets();

    harness.settleCanceled(fetch);
    runtime.fetch_flow.retireIfSettled(harness.gateway, fetch.handle);
    try harness.expectAbortAck(5, 6);
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
}

// The task's `done` turns true when the engine publishes the head, while the stream goes on, so
// a fetch past its head used to retire at the stop and leave its stream running in the shard.
test "a stop after the head keeps the record until the engine ends the response queue, then acks" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const fetch = try harness.startRunningFetch(25, 26, 0);
    try harness.settleSuccess(fetch, 200);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    try std.testing.expectEqual(@as(u16, 200), try harness.expectHead(25));

    try std.testing.expect(harness.sendStop(25));
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(25) != null);
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);
    try std.testing.expect(fetch.queue.canceled);

    // The engine applies the cancel: it fails the queue as it drops the stream, and the failure
    // asks for the wake that brings the record back.
    try std.testing.expect(fetch.queue.fail(harness.gateway.shards.get(0).engine.allocator, "FetchAborted"));
    runtime.fetch_flow.retireIfSettled(harness.gateway, fetch.handle);
    try harness.expectAbortAck(25, 26);
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
}

test "a response head the gateway refuses cancels the stream and fails the fetch once the engine let go" {
    var limits = gateway.policy.production;
    limits.max_response_headers = 0;
    var harness = try Harness.init(.{ .policy = limits });
    defer harness.deinit();

    const fetch = try harness.startRunningFetch(27, 28, 0);
    const headers = [_]http.Header{.{ .name = "x-one", .value = "1" }};
    try harness.settleSuccessWithHeaders(fetch, 200, &headers);
    try runtime.body_pump.pump(harness.gateway, fetch.handle);

    // The engine still streams the body the gateway will not deliver.
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(27) != null);
    try std.testing.expect(fetch.queue.canceled);

    try std.testing.expect(fetch.queue.fail(harness.gateway.shards.get(0).engine.allocator, "FetchAborted"));
    runtime.fetch_flow.retireIfSettled(harness.gateway, fetch.handle);
    try harness.expectFetchError(27, 28, "too many response headers");
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
}

test "a stop of a fetch the engine already let go of acks at once, and a stop after that changes nothing" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    // The engine published the head and then completed the queue as it dropped the stream.
    const fetch = try harness.startRunningFetch(7, 8, 0);
    try harness.settleSuccess(fetch, 200);
    _ = fetch.queue.complete();
    try std.testing.expect(harness.sendStop(7));
    try harness.expectAbortAck(7, 8);
    try expectNothingCounted(&harness);

    // The worker cannot see when the gateway ended a fetch, so a stop that crosses the terminal
    // packet keeps the session and draws nothing.
    try std.testing.expect(harness.sendStop(7));
    try std.testing.expect(harness.sendStop(999));
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.session().drop_pending);
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.sessions.len());
}

test "a fetch that is already ending keeps its first ending" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const fetch = try harness.startRunningFetch(9, 10, 0);
    runtime.fetch_flow.end(harness.gateway, fetch.handle, .stopped);
    runtime.fetch_flow.end(harness.gateway, fetch.handle, .{ .failed = .{ .message = "later failure" } });
    try harness.expectNoMoreCompletionPackets();

    harness.settleCanceled(fetch);
    runtime.fetch_flow.retireIfSettled(harness.gateway, fetch.handle);
    try harness.expectAbortAck(9, 10);
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
}

test "a fetch whose engine refuses the handover ends with that error and counts nothing" {
    // An engine that never started refuses every submission.
    var harness = try Harness.init(.{});
    defer harness.deinit();

    try std.testing.expect(try harness.sendFetchStart(.{
        .fetch_id = 11,
        .body_id = 12,
        .token = harness.token(.{}),
    }));
    try harness.expectFetchError(11, 12, "EgressEngineUnavailable");
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
}

test "an upload that expires lowers the session's count and upload bytes" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    try harness.expectAdmitted(.{
        .fetch_id = 13,
        .body_id = 14,
        .token = harness.token(.{}),
        .pooled_body_len = 4096,
    });
    try std.testing.expectEqual(support.pooledStartBytes(13, 4096), harness.session().upload_bytes_in_flight);
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);

    runtime.upload_flow.expire(harness.gateway, std.math.maxInt(u64));
    try harness.expectFetchError(13, 14, "egress upload deadline exceeded");
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
}

test "removing a session ends its fetches without a packet and leaves nothing counted" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    var peer = try harness.attachPeer();
    defer peer.deinit();
    const peer_session = harness.gateway.sessions.byId(peer.session_id).?;
    const peer_handle = try runtime.fetch_flow.insert(harness.gateway, peer_session, .{
        .session_id = peer.session_id,
        .fetch_id = 1,
        .body_id = 1,
        .shard_index = 0,
        .upload_bytes = 0,
        .stage = .admitting,
    });
    _ = peer_handle;

    const settled = try harness.startRunningFetch(15, 16, 0);
    try harness.settleSuccess(settled, 200);
    _ = try harness.startRunningFetch(17, 18, 0);
    try harness.expectAdmitted(.{
        .fetch_id = 19,
        .body_id = 20,
        .token = harness.token(.{}),
        .pooled_body_len = 1024,
    });
    try std.testing.expectEqual(@as(u32, 4), harness.gateway.fetches.cellCount(support.security_cell_id));

    const index = harness.gateway.sessions.indexOf(harness.session_id).?;
    try runtime.session_flow.removeSession(harness.gateway, index, .dropped);
    try harness.expectSessionRemovedReport(harness.session_id, .protocol_violation);
    try harness.expectNoMoreCompletionPackets();

    // Only the peer's record is left, in the same cell.
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.fetches.count());
    try std.testing.expectEqual(@as(u32, 1), harness.gateway.fetches.cellCount(support.security_cell_id));
    try std.testing.expect(harness.gateway.fetches.find(harness.session_id, 15) == null);
}

test "a shard restart ends its running fetches with an error and lowers their counts" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    const running = try harness.startRunningFetch(21, 22, 0);
    _ = running;
    try runtime.shard_flow.superviseShardFailure(harness.gateway, 0, error.EgressGatewayShardFailed);
    try harness.expectFetchError(21, 22, "egress internal error");
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
}

// Before the cancel reached streams past their head, the stop retired the record at once and
// the stream went on until its next append, its stall clock or its token's deadline; this origin
// sends nothing more, and the stall clock here outlasts the test.
test "a stop after the head closes the origin's connection, and the abort ack waits for the engine to let go" {
    var harness = try Harness.init(.{ .start_shards = true, .hello = false, .policy = liveTestPolicy() });
    defer harness.deinit();
    const origin = try HoldingOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    try startHeldFetch(&harness, origin, 1, 2);

    try std.testing.expect(harness.sendStop(1));
    // The head is out and the task done, but the engine still runs the stream: the record and
    // its place under the cap stay, and no ack goes out before a collection pass sees the
    // engine let go.
    try std.testing.expect(harness.record(1) != null);
    try std.testing.expectEqual(@as(u32, 1), harness.session().fetches.len);
    try std.testing.expect(try nextPacketAfterBody(&harness, 1) == null);

    try collectUntil(&harness, 1, false);
    const ack_packet = (try nextPacketAfterBody(&harness, 1)) orelse return error.MissingQueuedAbortAck;
    const ack = try ipc.decodeEgressAbortAck(ack_packet);
    try std.testing.expectEqual(@as(u64, 1), ack.fetch_id);
    try std.testing.expectEqual(@as(u64, 2), ack.body_id);
    try harness.expectNoMoreCompletionPackets();
    try expectNothingCounted(&harness);
    try std.testing.expect(try origin.waitClientClosed(close_timeout_ms));
}

// Before, a session's removal canceled only fetches before their head, and its extent ledger
// went with the credits a parked stream waited for.
test "removing a session closes the origin connection of its fetch past the head" {
    var harness = try Harness.init(.{ .start_shards = true, .hello = false, .policy = liveTestPolicy() });
    defer harness.deinit();
    const origin = try HoldingOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    try startHeldFetch(&harness, origin, 3, 4);

    const index = harness.gateway.sessions.indexOf(harness.session_id).?;
    try runtime.session_flow.removeSession(harness.gateway, index, .dropped);
    try harness.expectSessionRemovedReport(harness.session_id, .protocol_violation);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.fetches.count());
    try std.testing.expect(try origin.waitClientClosed(close_timeout_ms));
}
