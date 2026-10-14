//! The gateway's drain of a session's body-pool releases (`runtime/release_flow.zig`), against a
//! real endpoint whose worker side the test plays. Each extent the worker returns takes its entry
//! out of the session's extent ledger, whose shard gets the extent's flow-control credit back
//! once, whether or not the fetch that published it has ended, unless the shard restarted since,
//! which drops the credit (read through the engine's credit counts); a release the ledger cannot
//! match marks the session for drop; a drain that freed blocks queues the session for a pass that
//! pumps its waiting fetches, and one that freed nothing changes nothing. Lane:
//! egress-gateway-test. The drain that stops for pool room and resumes is covered in
//! `body_pump.zig`, and the ledger itself in `sessions.zig`.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const egress = @import("collo_egress_client");

const support = @import("support/gateway.zig");

const body_credit = egress.body_credit;
const fetch_table = gateway.fetch_table;
const publisher = gateway.publisher;
const runtime = gateway.runtime;
const Harness = support.Harness;

/// Publishes `bytes` as one chunk carrying `credit`, issued by shard 0's current engine run, for a
/// fetch the table does not hold, as an ended fetch's body still sits in the worker's pool, and
/// returns the extents the worker reads.
fn publishUnheld(
    harness: *Harness,
    bytes: []const u8,
    credit: body_credit.Handle,
    extents_out: []ipc.EgressBodyChunkView,
) !usize {
    const ended = fetch_table.Fetch{
        .session_id = harness.session_id,
        .fetch_id = 41,
        .body_id = 42,
        .shard_index = 0,
        .upload_bytes = 0,
        .stage = .admitting,
    };
    const run = harness.gateway.shards.get(0).engine.run;
    _ = try runtime.session_flow.publishBody(harness.gateway, harness.session(), &ended, run, &.{.{
        .bytes = bytes,
        .credit = credit,
    }});
    const scratch = try std.testing.allocator.create(ipc.WorkerEgressDecodeScratch);
    defer std.testing.allocator.destroy(scratch);
    const packet = (try harness.worker_endpoint.completion.readPacket(harness.read_buffer)) orelse
        return error.MissingQueuedBodyChunks;
    const chunks = try ipc.decodeEgressBodyChunkBatch(scratch, packet);
    @memcpy(extents_out[0..chunks.len], chunks);
    return chunks.len;
}

test "an extent returned after its fetch ended gives its ledger entry and credit back and marks nothing" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const fetch = try harness.startRunningFetch(1, 2, 0);
    try harness.settleSuccess(fetch, 200);
    const allocator = harness.gateway.shards.get(0).engine.allocator;
    const owned = try allocator.dupe(u8, "body bytes");
    _ = fetch.queue.appendOwnedChunk(allocator, owned, body_credit.h2Data(3, 1, 10, true)) catch |err| {
        allocator.free(owned);
        return err;
    };
    _ = fetch.queue.complete();
    try runtime.body_pump.pump(harness.gateway, fetch.handle);
    _ = try harness.expectHead(1);
    var body: [16]u8 = undefined;
    var extents: [4]ipc.EgressBodyChunkView = undefined;
    const received = try harness.expectBodyChunks(1, &body, &extents);
    try harness.expectBodyEnd(1, 2);

    // The fetch ended with its body end, and the ledger still holds the extent and its credit.
    try std.testing.expect(harness.record(1) == null);
    const session = harness.session();
    try std.testing.expectEqual(@as(u32, 1), session.extents.outstanding);
    const engine = &harness.gateway.shards.get(0).engine;
    try std.testing.expectEqual(@as(u64, 0), engine.credits_returned);

    try harness.releaseExtents(extents[0..received.extents]);
    runtime.release_flow.drainReleases(harness.gateway, session);
    // The extent's credit, and only it, went back to the engine once.
    try std.testing.expectEqual(@as(u64, 1), engine.credits_returned);
    try std.testing.expectEqual(@as(u64, 10), engine.credit_bytes_returned);
    try std.testing.expectEqual(@as(u32, 0), session.extents.outstanding);
    try std.testing.expect(session.extents.entries == null);
    try std.testing.expect(!session.drop_pending);
    try std.testing.expectEqual(@as(usize, 0), (try session.endpoint.body_pool.usage()).used);
}

test "a release the ledger cannot match marks the session for drop, and the session goes with a report" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    var extents: [4]ipc.EgressBodyChunkView = undefined;
    const count = try publishUnheld(&harness, "unmatched", .none, &extents);
    try std.testing.expectEqual(@as(usize, 1), count);

    // The gateway's private copy loses the entry, as a corrupt or forged release would find it.
    const session = harness.session();
    try std.testing.expect(session.extents.take(harness.gateway.allocator, .{
        .handle = extents[0].body_pool_offset,
        .len = @intCast(extents[0].len),
        .block_index = 0,
        .block_count = 0,
    }) != null);

    try harness.releaseExtents(extents[0..count]);
    runtime.release_flow.drainReleases(harness.gateway, session);
    try std.testing.expect(session.drop_pending);

    const session_id = harness.session_id;
    try runtime.session_flow.removeDroppedSessions(harness.gateway);
    try harness.expectSessionRemovedReport(session_id, .protocol_violation);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.sessions.len());
}

test "a drain that freed blocks queues the session for a rescan, which the attention pass clears" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    var extents: [4]ipc.EgressBodyChunkView = undefined;
    const count = try publishUnheld(&harness, "freed", body_credit.h1Resume(9), &extents);
    const session = harness.session();
    // The publication queued the session to measure its completion ring; the pass takes it off.
    try runtime.session_flow.processAttention(harness.gateway, 1);
    try std.testing.expect(!session.attention_queued);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.attention.items.len);

    try harness.releaseExtents(extents[0..count]);
    runtime.release_flow.drainReleases(harness.gateway, session);
    try std.testing.expect(session.rescan_pending);
    try std.testing.expect(session.attention_queued);
    try std.testing.expectEqualSlices(u64, &.{harness.session_id}, harness.gateway.attention.items);

    try runtime.session_flow.processAttention(harness.gateway, 1);
    try std.testing.expect(!session.rescan_pending);
    try std.testing.expect(!session.attention_queued);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.attention.items.len);
    try std.testing.expect(!session.drop_pending);
}

test "a drain that freed nothing changes nothing" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const session = harness.session();

    runtime.release_flow.drainReleases(harness.gateway, session);
    try std.testing.expect(!session.rescan_pending);
    try std.testing.expect(!session.attention_queued);
    try std.testing.expect(!session.drop_pending);
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.attention.items.len);
    try std.testing.expect(session.extents.entries == null);
}

test "extents of two publications returned out of order in one drain each leave the ledger, and the session stays" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    var first: [4]ipc.EgressBodyChunkView = undefined;
    const first_count = try publishUnheld(&harness, "first", body_credit.h2Data(1, 1, 5, true), &first);
    var second: [4]ipc.EgressBodyChunkView = undefined;
    const second_count = try publishUnheld(&harness, "second", body_credit.h2Data(1, 3, 6, true), &second);
    const session = harness.session();
    try std.testing.expectEqual(@as(u32, @intCast(first_count + second_count)), session.extents.outstanding);

    try harness.releaseExtents(second[0..second_count]);
    try harness.releaseExtents(first[0..first_count]);
    runtime.release_flow.drainReleases(harness.gateway, session);
    try std.testing.expectEqual(@as(u32, 0), session.extents.outstanding);
    try std.testing.expect(!session.drop_pending);
    try std.testing.expectEqual(@as(u64, 11), harness.gateway.shards.get(0).engine.credit_bytes_returned);
}

// Each engine run numbers its credit sources afresh, and a credit used to keep only its shard,
// so an extent held across a restart gave its credit to whichever stream of the new run took the
// same source and stream ids: more window than that stream's consumer released, or a failed
// assertion in the engine.
test "an extent held across its shard's restart gives its credit to nothing of the new run" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const engine = &harness.gateway.shards.get(0).engine;
    var extents: [4]ipc.EgressBodyChunkView = undefined;
    const count = try publishUnheld(&harness, "before the restart", body_credit.h2Data(1, 1, 18, true), &extents);
    const run_before = engine.run;

    try runtime.shard_flow.superviseShardFailure(harness.gateway, 0, error.EgressGatewayShardFailed);
    try std.testing.expect(engine.run != run_before);
    const session = harness.session();
    try std.testing.expectEqual(@as(u32, 1), session.extents.outstanding);

    try harness.releaseExtents(extents[0..count]);
    runtime.release_flow.drainReleases(harness.gateway, session);
    try std.testing.expectEqual(@as(u64, 0), engine.credits_returned);
    try std.testing.expectEqual(@as(u64, 1), engine.stale_credits_dropped);
    // The extent itself still leaves the ledger, and the session stays.
    try std.testing.expectEqual(@as(u32, 0), session.extents.outstanding);
    try std.testing.expect(!session.drop_pending);
}
