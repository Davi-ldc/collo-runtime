//! The gateway's worker sessions (`runtime/session_flow.zig`): attaching one registers its two
//! polls and reserves its place in the attention list; a liveness hang-up or a command ring that
//! fails removes it and tells the server why (`liveness_closed` for the first, `protocol_violation`
//! for every other removal), an attach whose ack never left removes it silently, and
//! a session marked for drop goes at the end of the pass. The attention list measures each
//! session the pass wrote to: a completion ring at `hard_percent` keeps the session queued and
//! drops it once it stayed there for `hard_drop_grace_ns`, a worker that drains in time clears
//! the mark, and a session whose body pool gained room has every fetch that waited for room
//! pumped again. A worker whose parked command found the ring full gets its completion eventfd
//! written once the ring drained, and a collection pass wakes each worker once. Lane:
//! egress-gateway-test. The control socket's side of attaches is covered in `control_flow.zig`
//! and the body drain's room check in `body_pump.zig`.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");

const support = @import("support/gateway.zig");

const runtime = gateway.runtime;
const session_flow = runtime.session_flow;
const Harness = support.Harness;

/// Writes packets onto the session's completion ring through the gateway's own path until the
/// ring sits between `hard_percent` and full: three of the largest packets and one of 900 KiB.
fn fillCompletionRing(harness: *Harness) !void {
    const packet = try std.testing.allocator.alloc(u8, ipc.egress_shared.max_packet_bytes);
    defer std.testing.allocator.free(packet);
    @memset(packet, 0x5a);
    for (0..3) |_|
        try session_flow.queuePacket(harness.gateway, harness.session(), packet);
    try session_flow.queuePacket(harness.gateway, harness.session(), packet[0 .. 900 * 1024]);
    const usage = try harness.session().endpoint.completion.usage();
    try std.testing.expect(usage.atLeastPercent(session_flow.hard_percent));
    try std.testing.expect(usage.used < usage.capacity);
}

/// Reads every packet the gateway left on the completion ring, as a worker that caught up does.
fn drainCompletionRing(harness: *Harness) !void {
    while (try harness.worker_endpoint.completion.readPacket(harness.read_buffer)) |_| {}
}

/// Takes the count a nonblocking eventfd holds, 0 when it holds none.
fn takeEventfd(fd: std.posix.fd_t) !u64 {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
        error.WouldBlock => return 0,
        else => return err,
    };
    return value;
}

const Delivered = struct {
    heads: usize = 0,
    descriptors: usize = 0,
    bytes: usize = 0,
    body_ends: usize = 0,
    errors: usize = 0,
};

/// Reads every completion packet as the worker does, returning each body extent to the pool once
/// counted, and tallies what arrived.
fn consumeCompletions(harness: *Harness) !Delivered {
    const scratch = try std.testing.allocator.create(ipc.WorkerEgressDecodeScratch);
    defer std.testing.allocator.destroy(scratch);
    var delivered = Delivered{};
    while (try harness.worker_endpoint.completion.readPacket(harness.read_buffer)) |packet| {
        const kind = try ipc.decodeMessageKind(ipc.packet.readStruct(u32, packet[0..@sizeOf(u32)]));
        switch (kind) {
            .egress_fetch_head => delivered.heads += 1,
            .egress_body_chunk_batch => {
                for (try ipc.decodeEgressBodyChunkBatch(scratch, packet)) |chunk| {
                    delivered.descriptors += 1;
                    delivered.bytes += chunk.len;
                    try harness.worker_endpoint.body_pool.releaseChunk(chunk.body_pool_offset, chunk.len);
                }
            },
            .egress_body_end => delivered.body_ends += 1,
            .egress_fetch_error => delivered.errors += 1,
            else => return error.UnexpectedEgressPacket,
        }
    }
    return delivered;
}

/// Queues `count` chunks of `chunk_bytes` bytes on the fetch's response queue, allocated as an
/// engine allocates them, and completes the queue.
fn queueBody(harness: *Harness, fetch: support.RunningFetch, count: usize, chunk_bytes: usize) !void {
    const allocator = harness.gateway.shards.get(0).engine.allocator;
    for (0..count) |_| {
        const chunk = try allocator.alloc(u8, chunk_bytes);
        errdefer allocator.free(chunk);
        @memset(chunk, 0xb7);
        _ = try fetch.queue.appendOwnedChunk(allocator, chunk, .none);
    }
    _ = fetch.queue.complete();
}

test "an attached session has its two polls registered and a reserved attention slot, and removal drops both" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    var peer = try harness.attachPeer();
    defer peer.deinit();
    try std.testing.expect(harness.gateway.readiness.sessions.contains(harness.session_id));
    try std.testing.expect(harness.gateway.readiness.sessions.contains(peer.session_id));
    try std.testing.expect(harness.gateway.attention.capacity >= harness.gateway.sessions.len());

    // A session whose attach ack never left goes without a report: the server never learned it.
    const index = harness.gateway.sessions.indexOf(peer.session_id).?;
    try session_flow.removeSession(harness.gateway, index, .attach_ack_failed);
    try harness.expectNoServerPacket();
    try std.testing.expect(!harness.gateway.readiness.sessions.contains(peer.session_id));
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.sessions.len());
}

test "a liveness hang-up removes the session and reports it, and a liveness completion without one changes nothing" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const session_id = harness.session_id;

    const quiet: gateway.readiness.Ready = .{ .session = .{ .session_id = session_id, .source = .liveness, .revents = 0 } };
    try session_flow.handleSessionReady(harness.gateway, quiet.session);
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.sessions.len());
    try harness.expectNoServerPacket();

    const hung_up: gateway.readiness.Ready = .{ .session = .{
        .session_id = session_id,
        .source = .liveness,
        .revents = std.posix.POLL.HUP,
    } };
    try session_flow.handleSessionReady(harness.gateway, hung_up.session);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
    try std.testing.expect(!harness.gateway.readiness.sessions.contains(session_id));
    // The pipe tells an exit from a detach no better than this, so the report says only that.
    try harness.expectSessionRemovedReport(session_id, .liveness_closed);

    // A completion for a session that is gone is dropped.
    try session_flow.handleSessionReady(harness.gateway, hung_up.session);
    try harness.expectNoServerPacket();
}

test "a command ring carrying a packet shorter than a kind removes the session and reports it" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const session_id = harness.session_id;

    try harness.writeCommand(&[_]u8{ 1, 2 });
    const ready: gateway.readiness.Ready = .{ .session = .{
        .session_id = session_id,
        .source = .command,
        .revents = std.posix.POLL.IN,
    } };
    try session_flow.handleSessionReady(harness.gateway, ready.session);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
    try harness.expectSessionRemovedReport(session_id, .protocol_violation);
}

test "a session marked for drop twice is counted once and goes with a report at the end of the pass" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const session_id = harness.session_id;

    session_flow.markForDrop(harness.gateway, harness.session(), "first reason");
    session_flow.markForDrop(harness.gateway, harness.session(), "second reason");
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.sessions.drops_pending);
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.sessions.len());

    try session_flow.removeDroppedSessions(harness.gateway);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.drops_pending);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
    try harness.expectSessionRemovedReport(session_id, .protocol_violation);
    try harness.expectNoServerPacket();
}

test "a completion ring left at the hard mark for the grace drops the session, and not a moment before" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const session_id = harness.session_id;
    const grace = session_flow.hard_drop_grace_ns;
    const start: u64 = 1_000;

    try fillCompletionRing(&harness);
    const session = harness.session();
    try std.testing.expect(session.attention_queued);

    try session_flow.processAttention(harness.gateway, start);
    try std.testing.expectEqual(start, session.hard_since_ns);
    // The session stays queued, so the next pass, at most a tick away, looks again.
    try std.testing.expect(session.attention_queued);
    try std.testing.expectEqual(@as(usize, 1), harness.gateway.attention.items.len);

    try session_flow.processAttention(harness.gateway, start + grace - 1);
    try std.testing.expect(!session.drop_pending);
    try std.testing.expectEqual(start, session.hard_since_ns);

    try session_flow.processAttention(harness.gateway, start + grace);
    try std.testing.expect(session.drop_pending);
    try std.testing.expect(!session.attention_queued);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.attention.items.len);

    try session_flow.removeDroppedSessions(harness.gateway);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
    try harness.expectSessionRemovedReport(session_id, .protocol_violation);
}

test "a worker that drains its completion ring within the grace clears the hard mark and keeps its session" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const start: u64 = 1_000;

    try fillCompletionRing(&harness);
    try session_flow.processAttention(harness.gateway, start);
    try std.testing.expectEqual(start, harness.session().hard_since_ns);

    try drainCompletionRing(&harness);
    try session_flow.processAttention(harness.gateway, start + session_flow.hard_drop_grace_ns);
    const session = harness.session();
    try std.testing.expectEqual(@as(u64, 0), session.hard_since_ns);
    try std.testing.expect(!session.drop_pending);
    try std.testing.expect(!session.attention_queued);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.attention.items.len);
}

test "a session whose body pool gained room has every fetch that waited for room pumped before the next wait" {
    // The response queue's byte limit is the policy's response cap, so a body of nearly the whole
    // pool needs a larger cap than the production one.
    var harness = try Harness.init(.{ .policy = .{ .max_response_body_bytes = 16 * 1024 * 1024 } });
    defer harness.deinit();
    const chunk_bytes = gateway.policy.production.max_body_chunk_bytes;
    const block = ipc.egress_shared.body_pool_block_size;
    const pool_blocks = ipc.egress_shared.body_pool_slot_count;
    // 125 chunks of 64 KiB take 500 of the pool's 512 blocks. The drain keeps room for its
    // largest pull, 256 KiB, before every pull, so the 12 blocks left stop both fetches.
    const big_chunks: usize = 125;
    try std.testing.expectEqual(@as(usize, 4), chunk_bytes / block);
    try std.testing.expectEqual(@as(usize, 512), pool_blocks);

    const big = try harness.startRunningFetch(1, 1, 0);
    try harness.settleSuccess(big, 200);
    try queueBody(&harness, big, big_chunks, chunk_bytes);
    try runtime.body_pump.pump(harness.gateway, big.handle);

    const small = try harness.startRunningFetch(2, 2, 0);
    try harness.settleSuccess(small, 200);
    try queueBody(&harness, small, 1, block);
    try runtime.body_pump.pump(harness.gateway, small.handle);

    // Every byte of the first body went out, but neither body end did: both fetches wait for
    // room, and the small one published nothing.
    try std.testing.expect(harness.record(1).?.ending == null);
    try std.testing.expect(harness.record(2).?.ending == null);
    try std.testing.expectEqual(@as(u32, big_chunks), harness.session().extents.outstanding);
    const first = try consumeCompletions(&harness);
    try std.testing.expectEqual(@as(usize, 2), first.heads);
    try std.testing.expectEqual(big_chunks, first.descriptors);
    try std.testing.expectEqual(big_chunks * chunk_bytes, first.bytes);
    try std.testing.expectEqual(@as(usize, 0), first.body_ends);

    // The worker returned every extent; the release drain queues the session, and the pass's
    // attention step pumps both fetches.
    runtime.release_flow.drainReleases(harness.gateway, harness.session());
    try std.testing.expect(harness.session().rescan_pending);
    try std.testing.expect(harness.session().attention_queued);
    try session_flow.processAttention(harness.gateway, 0);

    const second = try consumeCompletions(&harness);
    try std.testing.expectEqual(@as(usize, 0), second.heads);
    try std.testing.expectEqual(@as(usize, 1), second.descriptors);
    try std.testing.expectEqual(block, second.bytes);
    try std.testing.expectEqual(@as(usize, 2), second.body_ends);
    try std.testing.expectEqual(@as(usize, 0), second.errors);
    try std.testing.expectEqual(@as(u32, 0), harness.session().fetches.len);
    try std.testing.expect(!harness.session().rescan_pending);
}

test "a worker whose parked command found the command ring full gets one completion wake once the ring drained" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const packet = try std.testing.allocator.alloc(u8, 600 * 1024);
    defer std.testing.allocator.free(packet);
    @memset(packet, 0);

    _ = try takeEventfd(harness.worker_endpoint.completion_eventfd);
    // Nothing was dropped yet, so the gateway owes no wake.
    session_flow.wakeWorkerAfterCommandDrops(harness.session());
    try std.testing.expectEqual(@as(u64, 0), try takeEventfd(harness.worker_endpoint.completion_eventfd));

    // The second packet does not fit, and the worker's ring counts the drop.
    try harness.writeCommand(packet);
    try std.testing.expectError(error.EgressSharedRingFull, harness.worker_endpoint.command.writePacket(packet));
    session_flow.wakeWorkerAfterCommandDrops(harness.session());
    try std.testing.expectEqual(@as(u64, 1), try takeEventfd(harness.worker_endpoint.completion_eventfd));

    // The same count owes no second wake.
    session_flow.wakeWorkerAfterCommandDrops(harness.session());
    try std.testing.expectEqual(@as(u64, 0), try takeEventfd(harness.worker_endpoint.completion_eventfd));
}

test "a collection pass that writes several packets to a worker wakes it once" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const engine = &harness.gateway.shards.get(0).engine;

    var fetches: [2]support.RunningFetch = undefined;
    for (&fetches, 1..) |*fetch, id| {
        fetch.* = try harness.startRunningFetch(id, id, 0);
        try harness.settleSuccess(fetch.*, 200);
        try queueBody(&harness, fetch.*, 1, 1024);
        _ = engine.ready.enqueueTask(.{ .task = fetch.task, .generation = fetch.handle });
    }
    _ = try takeEventfd(harness.worker_endpoint.completion_eventfd);

    try runtime.shard_flow.collectShardReady(harness.gateway, 0);
    try std.testing.expectEqual(@as(u64, 1), try takeEventfd(harness.worker_endpoint.completion_eventfd));
    try std.testing.expect(!harness.session().completion_notify_pending);
    try std.testing.expect(!harness.gateway.coalesce_completion_notifies);

    const delivered = try consumeCompletions(&harness);
    try std.testing.expectEqual(@as(usize, 2), delivered.heads);
    try std.testing.expectEqual(@as(usize, 2), delivered.descriptors);
    try std.testing.expectEqual(@as(usize, 2), delivered.body_ends);
}
