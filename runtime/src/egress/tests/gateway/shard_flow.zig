//! The gateway's shard supervision and collection (`runtime/shard_flow.zig`): a shard-scoped
//! failure stops that shard, ends every fetch it ran with an error (a stopped one with its abort
//! ack), leaves the other shards' fetches and every upload still assembling alone, and runs the
//! engine again on its threads, so later fetches reach it; past the restart backstop the failure
//! is returned and ends the gateway. A hung-up wake eventfd and an owner-loop fault the engine
//! latched count as shard failures. Collection
//! pumps a fetch only for a token whose handle names its live record, so a token kept past its
//! fetch's end pumps nothing even after the slot holds another fetch. Lane: egress-gateway-test.
//! The backstop's window is covered in `shard.zig`, the pump in `body_pump.zig` and the counts at
//! every ending in `fetch_flow.zig`.

const std = @import("std");
const gateway = @import("collo_egress_gateway");

const policy_image = @import("support/policy_image.zig");
const support = @import("support/gateway.zig");

const runtime = gateway.runtime;
const Harness = support.Harness;

/// The first fetch id at or after `from` whose loopback URL hashes to shard `shard_index` under
/// the harness's cell and the standard policy.
fn fetchIdOnShard(harness: *Harness, shard_index: usize, from: u64) u64 {
    const isolation = gateway.policy.PoolIsolation{
        .security_cell_id = support.security_cell_id,
        .policy_id = gateway.policy.poolPolicyId(policy_image.public_https_id),
    };
    var fetch_id = from;
    while (true) : (fetch_id += 1) {
        var url_buffer: [support.loopback_url_bytes_max]u8 = undefined;
        if (harness.gateway.shards.selectIndex(isolation, support.loopbackUrl(&url_buffer, fetch_id)) == shard_index)
            return fetch_id;
    }
}

test "a shard failure ends that shard's fetches, a stopped one with its ack, and leaves other shards and uploads alone" {
    var harness = try Harness.init(.{ .shard_count = 2 });
    defer harness.deinit();

    _ = try harness.startRunningFetch(1, 1, 0);
    const stopped = try harness.startRunningFetch(2, 2, 0);
    // The stop waits for the task to settle, which no engine thread does here.
    runtime.fetch_flow.end(harness.gateway, stopped.handle, .stopped);
    _ = try harness.startRunningFetch(3, 3, 1);
    try harness.expectAdmitted(.{ .fetch_id = 4, .body_id = 4, .token = harness.token(.{}), .pooled_body_len = 64 });
    try harness.expectNoMoreCompletionPackets();

    try runtime.shard_flow.superviseShardFailure(harness.gateway, 0, error.EgressGatewayShardFailed);

    // The table's slots are walked in order, so the packets follow the records' slots.
    try harness.expectFetchError(1, 1, "egress internal error");
    try harness.expectAbortAck(2, 2);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(1) == null);
    try std.testing.expect(harness.record(2) == null);
    try std.testing.expect(harness.record(3).?.stage == .running);
    try std.testing.expect(harness.record(4).?.stage == .assembling);
    try std.testing.expectEqual(@as(u32, 2), harness.session().fetches.len);
}

test "a restarted shard serves the fetches admitted after its restart" {
    var harness = try Harness.init(.{ .shard_count = 2 });
    defer harness.deinit();

    // Neither engine started, so the restart is shard 0's first run.
    try runtime.shard_flow.superviseShardFailure(harness.gateway, 0, error.EgressGatewayShardFailed);

    const on_restarted = fetchIdOnShard(&harness, 0, 100);
    try harness.expectAdmitted(.{ .fetch_id = on_restarted, .body_id = 1, .token = harness.token(.{}) });
    try std.testing.expect(harness.record(on_restarted).?.stage == .running);

    // The other shard never ran, so its engine still refuses the handover.
    const on_other = fetchIdOnShard(&harness, 1, on_restarted + 1);
    try std.testing.expect(try harness.sendFetchStart(.{ .fetch_id = on_other, .body_id = 2, .token = harness.token(.{}) }));
    try harness.expectFetchError(on_other, 2, "EgressEngineUnavailable");
}

test "the fourth shard failure inside the backstop's window is returned to end the gateway" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try std.testing.expectEqual(@as(usize, 3), gateway.containment.shard_restart.max_restarts_in_window);

    for (0..3) |_|
        try runtime.shard_flow.superviseShardFailure(harness.gateway, 0, error.EgressGatewayShardFailed);
    try std.testing.expectError(
        error.EgressGatewayShardFailed,
        runtime.shard_flow.superviseShardFailure(harness.gateway, 0, error.EgressGatewayShardFailed),
    );
}

test "an owner-loop fault the engine latched restarts the shard after the pass and fails its running fetches" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const engine = &harness.gateway.shards.get(0).engine;
    const run_before = engine.run;

    _ = try harness.startRunningFetch(7, 8, 0);
    // The owner's run failed, as a data wait on a dead ring does, and latched its fault.
    engine.inner.noteOwnerFault(error.EgressDataRingDead);
    try runtime.shard_flow.handleShardReady(harness.gateway, 0, std.posix.POLL.IN);
    try harness.expectFetchError(7, 8, "egress internal error");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(7) == null);
    try std.testing.expect(engine.run != run_before);
    try std.testing.expect(engine.takeOwnerFault() == null);
}

test "a hung-up shard wake eventfd is supervised as a shard failure" {
    var harness = try Harness.init(.{});
    defer harness.deinit();

    _ = try harness.startRunningFetch(5, 6, 0);
    try runtime.shard_flow.handleShardReady(harness.gateway, 0, std.posix.POLL.HUP);
    try harness.expectFetchError(5, 6, "egress internal error");
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(harness.record(5) == null);
}

test "a ready token kept past its fetch's end pumps nothing, even once its slot holds another fetch" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const engine = &harness.gateway.shards.get(0).engine;

    // The engine settled the task as canceled, so it let go of the fetch, and the stop retires
    // the record at once.
    const ended = try harness.startRunningFetch(1, 1, 0);
    harness.settleCanceled(ended);
    runtime.fetch_flow.end(harness.gateway, ended.handle, .stopped);
    try harness.expectAbortAck(1, 1);

    // The new fetch takes the freed slot under a new generation.
    const current = try harness.startRunningFetch(2, 2, 0);
    try std.testing.expect(current.handle != ended.handle);
    try harness.settleSuccess(current, 200);

    _ = engine.ready.enqueueTask(.{ .task = current.task, .generation = ended.handle });
    try runtime.shard_flow.collectShardReady(harness.gateway, 0);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.record(2).?.head_sent);

    // The token the current fetch's task carries pumps it.
    _ = engine.ready.enqueueTask(.{ .task = current.task, .generation = current.handle });
    try runtime.shard_flow.collectShardReady(harness.gateway, 0);
    try std.testing.expectEqual(@as(u16, 200), try harness.expectHead(2));
    try std.testing.expect(harness.record(2).?.head_sent);
}

test "a ready token whose handle names a fetch of another task or shard pumps nothing" {
    var harness = try Harness.init(.{ .shard_count = 2 });
    defer harness.deinit();

    const on_one = try harness.startRunningFetch(1, 1, 1);
    try harness.settleSuccess(on_one, 200);
    const on_zero = try harness.startRunningFetch(2, 2, 0);
    try harness.settleSuccess(on_zero, 200);

    // Shard 0 gets a token naming shard 1's record, then one naming its own record with the
    // other fetch's task.
    const engine = &harness.gateway.shards.get(0).engine;
    _ = engine.ready.enqueueTask(.{ .task = on_one.task, .generation = on_one.handle });
    _ = engine.ready.enqueueTask(.{ .task = on_one.task, .generation = on_zero.handle });
    try runtime.shard_flow.collectShardReady(harness.gateway, 0);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.record(1).?.head_sent);
    try std.testing.expect(!harness.record(2).?.head_sent);
}

test "a scan request pumps every running fetch of the shard and only those" {
    var harness = try Harness.init(.{ .shard_count = 2 });
    defer harness.deinit();

    const on_zero = try harness.startRunningFetch(1, 1, 0);
    try harness.settleSuccess(on_zero, 200);
    const on_one = try harness.startRunningFetch(2, 2, 1);
    try harness.settleSuccess(on_one, 200);

    _ = harness.gateway.shards.get(0).engine.ready.requestScan();
    try runtime.shard_flow.collectShardReady(harness.gateway, 0);
    try std.testing.expectEqual(@as(u16, 200), try harness.expectHead(1));
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expect(!harness.record(2).?.head_sent);
}
