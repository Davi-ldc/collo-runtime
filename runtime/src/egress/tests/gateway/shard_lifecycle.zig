//! The steps of a shard restart, each driven on its own without the supervisor: the restart
//! backstop's window, the teardown partition that keeps replay-safe fetches and fails or retires
//! the rest, the resubmission of a replay-safe fetch, and the in-place restart of one shard of a
//! set, which keeps its cumulative counters and leaves the other shard alone. The supervisor
//! running these steps over threaded engines, and a restart under the gateway's seccomp filter,
//! are covered in `shard_chaos.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const engine_test = @import("support/engine.zig");
const egress = @import("collo_egress_client");
const ipc = @import("collo_ipc");

const body_credit = egress.core.body_credit;
const fetch_body = egress.core.fetch_body;

const threadless_config = gateway.engine.Config{
    .h2_connector_count = 0,
};

test "shard restart backstop trips at the windowed maximum and recovers past the window" {
    const window = gateway.supervisor_limits.shard_restart.window_ns;
    var backstop = gateway.shard.RestartBackstop{};
    const base: u64 = 1_000;

    // Three restarts, `max_restarts_in_window`, fit inside the window.
    try std.testing.expect(backstop.admitRestartAt(base));
    try std.testing.expect(backstop.admitRestartAt(base + window / 4));
    try std.testing.expect(backstop.admitRestartAt(base + window / 2));
    // The next failure inside it trips the backstop, which counts the trip and
    // records no restart.
    try std.testing.expect(!backstop.admitRestartAt(base + (3 * window) / 4));
    try std.testing.expectEqual(@as(u64, 1), backstop.trips);
    // Once the window slides past the recorded restarts, restarting resumes.
    try std.testing.expect(backstop.admitRestartAt(base + window + window / 2 + 1));
    try std.testing.expectEqual(@as(u64, 1), backstop.trips);

    // A failed monotonic read (0) still occupies a slot, so a bad clock errs
    // toward tripping, never toward unlimited restarts.
    var degenerate = gateway.shard.RestartBackstop{};
    try std.testing.expect(degenerate.admitRestartAt(0));
    try std.testing.expect(degenerate.admitRestartAt(0));
    try std.testing.expect(degenerate.admitRestartAt(0));
    try std.testing.expect(!degenerate.admitRestartAt(0));
    try std.testing.expectEqual(@as(u64, 1), degenerate.trips);
}

test "teardown partition extracts replay-safe fetches and demotes the rest" {
    SenderLog.reset();
    PacketLog.reset();
    var engine = try gateway.engine.Engine.init(std.testing.allocator, threadless_config);
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);
    engine.setWorkerPressureProbe(unboundedPressureProbe);

    // Fetch 1 is replay-safe: idempotent, without a body, and nothing of its
    // response delivered.
    try engine_test.injectActiveRequest(&engine, 1, 1, 1, .{
        .request_deadline_mono_ns = 777,
        .request_id = 42,
        .request_generation = 7,
    });
    try engine_test.setActiveBodyEgressMeters(&engine, 1, 1, 1, .{
        .billed_sent = 5,
        .billed_received = 7,
        .cost = 3,
    });
    // Fetch 2 already delivered its head (`appendReadyBodyChunk` marks it
    // sent), so it is demoted with an error packet.
    try engine_test.injectActive(&engine, 2, 2, 2);
    try engine_test.appendReadyBodyChunk(&engine, 2, 2, 2, "queued");
    // Fetch 3 sends a request body with a method that is not idempotent, so it
    // is demoted.
    try engine_test.injectActiveRequest(&engine, 3, 3, 3, .{ .method = "POST", .body = "p" });
    // Fetch 4 is already terminal, canceled by its worker, so it retires
    // without a new packet.
    try engine_test.injectActive(&engine, 4, 4, 4);
    engine.cancelFetch(4, ipc.EgressCancel.init(4, 1));
    // Fetch 5 delivered its body end and one extent is still with the worker,
    // so it retires without a packet: an error after body end would contradict
    // the stream the worker already finished.
    try engine_test.injectActive(&engine, 5, 5, 5);
    try engine_test.appendReadyBodyChunk(&engine, 5, 5, 5, "done");
    try engine_test.markActiveBodyComplete(&engine, 5, 5, 5);
    try engine_test.wakeActiveTask(&engine, 5, 5, 5);
    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expect(engine_test.activeFetchBodyEndSent(&engine, 5, 5, 5));
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 5, 5, 5));
    const error_packets_before = PacketLog.fetch_error_packets;

    engine.stop();
    var replay: std.array_list.Aligned(gateway.engine.ReplayFetch, null) = .empty;
    defer {
        for (replay.items) |item|
            item.task.release();
        replay.deinit(std.testing.allocator);
    }
    var retired: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer retired.deinit(std.testing.allocator);
    try engine.partitionActivesForTeardown(std.testing.allocator, &replay, &retired, error.InjectedShardFault);

    // One replay-safe fetch, with its identity, the request its token named,
    // its admission deadline and only the dead attempt's `cost`: its
    // `billed_sent` and `billed_received` bytes travelled inside the TLS
    // ciphertext that `cost` already counts, so adding them would count them
    // twice (`partitionActivesForTeardown` in `engine.zig`).
    try std.testing.expectEqual(@as(usize, 1), replay.items.len);
    const item = replay.items[0];
    try std.testing.expectEqual(@as(u64, 1), item.worker_session_id);
    try std.testing.expectEqual(@as(u64, 1), item.fetch_id);
    try std.testing.expectEqual(@as(u64, 1), item.body_id);
    try std.testing.expectEqual(
        gateway.budgets.BudgetKey{ .session_id = 1, .request_id = 42, .request_generation = 7 },
        item.budget_key,
    );
    try std.testing.expectEqual(@as(u64, 777), item.request_deadline_mono_ns);
    try std.testing.expectEqual(@as(u64, 3), item.dead_attempt_cost);

    // Everything else retires: fetches 2..5, in table order.
    try std.testing.expectEqual(@as(usize, 4), retired.items.len);
    // Only fetches 2 and 3 were demoted with an error packet; the canceled one
    // and the one past body end got no new packet.
    try std.testing.expectEqual(@as(u64, 2), engine_test.demotedFetchErrors(&engine));
    try std.testing.expectEqual(error_packets_before + 2, PacketLog.fetch_error_packets);

    // Every fetch not replayed is terminal, so the table's teardown reaps them
    // without sending the worker anything more.
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 2, 2));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 3, 3));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 4, 4));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 5, 5));
}

test "redispatch resubmit rebuilds the request and rolls back on an unavailable engine" {
    var dying = try gateway.engine.Engine.init(std.testing.allocator, threadless_config);
    defer dying.deinit();

    try engine_test.injectActiveRequest(&dying, 7, 11, 13, .{
        .method = "HEAD",
        .request_deadline_mono_ns = 555,
        .request_id = 9,
        .request_generation = 4,
    });

    dying.stop();
    var replay: std.array_list.Aligned(gateway.engine.ReplayFetch, null) = .empty;
    defer {
        for (replay.items) |item|
            item.task.release();
        replay.deinit(std.testing.allocator);
    }
    var retired: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer retired.deinit(std.testing.allocator);
    try dying.partitionActivesForTeardown(std.testing.allocator, &replay, &retired, error.InjectedShardFault);
    try std.testing.expectEqual(@as(usize, 1), replay.items.len);
    try std.testing.expectEqual(@as(usize, 0), retired.items.len);

    // An engine without connector threads is never available, so the
    // resubmission reaches the inner submit and fails there. It must leave no
    // active entry behind and must not consume the caller's task reference,
    // which the deferred release above drops.
    var fresh = try gateway.engine.Engine.init(std.testing.allocator, threadless_config);
    defer fresh.deinit();
    try std.testing.expectError(
        error.EgressEngineUnavailable,
        fresh.resubmitReplayFetch(replay.items[0], .{}, gateway.policy.public_https),
    );
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&fresh));
}

test "shard restart reruns the engine in place and leaves neighbors untouched" {
    SenderLog.reset();
    PacketLog.reset();
    var set = try gateway.shard_set.Set.init(std.testing.allocator, 2, .{
        .h2_connector_count = 1,
    }, gateway.supervisor_limits.shard_memory.budget_bytes);
    defer set.deinit(std.testing.allocator);
    try set.startAll(
        null,
        recordingPacketSender,
        countingBodyChunkBatchSender,
        unboundedPressureProbe,
        ignoringFaultReporter,
    );

    const dying = set.get(0);
    const neighbor = set.get(1);
    try engine_test.injectActive(&dying.engine, 1, 1, 1);
    try engine_test.injectActiveRequest(&dying.engine, 2, 2, 2, .{ .method = "POST", .body = "p" });
    try engine_test.injectActive(&neighbor.engine, 3, 3, 3);

    // The supervisor's sequence without the route removal, which belongs to
    // the gateway loop: quarantine, stop, partition and restart in place
    // (`superviseShardFailure` in `runtime/shard_flow.zig`).
    dying.quarantined = true;
    dying.engine.stop();
    var replay: std.array_list.Aligned(gateway.engine.ReplayFetch, null) = .empty;
    defer {
        for (replay.items) |item|
            item.task.release();
        replay.deinit(std.testing.allocator);
    }
    var retired: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer retired.deinit(std.testing.allocator);
    try dying.engine.partitionActivesForTeardown(std.testing.allocator, &replay, &retired, error.InjectedShardFault);
    try dying.restart();
    dying.quarantined = false;

    // The restarted engine has an empty table, one more restart, and the
    // demotion count it carried over, which counts from gateway boot.
    try std.testing.expectEqual(@as(usize, 1), replay.items.len);
    try std.testing.expectEqual(@as(usize, 1), retired.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&dying.engine));
    try std.testing.expectEqual(@as(u64, 1), dying.restarts);
    try std.testing.expectEqual(@as(u64, 1), engine_test.demotedFetchErrors(&dying.engine));
    try std.testing.expectEqual(@as(u64, 0), neighbor.restarts);

    // The neighbor shard noticed nothing: its fetch is still in its table and
    // completes through the normal retire path.
    try std.testing.expect(neighbor.engine.hasActiveBody(3, 3, 3));
    try engine_test.markActiveTerminalDone(&neighbor.engine, 3, 3, 3);
    try engine_test.wakeActiveTask(&neighbor.engine, 3, 3, 3);
    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try neighbor.engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expect(completed.items[0].matchesBody(3, 3, 3));
}

const SenderLog = struct {
    var calls: usize = 0;

    fn reset() void {
        calls = 0;
    }
};

fn countingBodyChunkBatchSender(
    ctx: ?*anyopaque,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
    chunks: []const gateway.engine.BodyChunkPayload,
    scratch: []u8,
) anyerror!usize {
    _ = ctx;
    _ = worker_session_id;
    _ = fetch_id;
    _ = body_id;
    _ = scratch;
    SenderLog.calls += 1;
    // One pool extent per payload, as an unfragmented pool gives: a payload
    // lands in one contiguous run of blocks.
    return chunks.len;
}

const PacketLog = struct {
    var packets: usize = 0;
    var fetch_error_packets: usize = 0;

    fn reset() void {
        packets = 0;
        fetch_error_packets = 0;
    }
};

fn recordingPacketSender(ctx: ?*anyopaque, worker_session_id: u64, bytes: []const u8) anyerror!void {
    _ = ctx;
    _ = worker_session_id;
    PacketLog.packets += 1;
    if (bytes.len < @sizeOf(u32))
        return;
    const kind = ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)])) catch return;
    if (kind == .egress_fetch_error)
        PacketLog.fetch_error_packets += 1;
}

fn unboundedPressureProbe(ctx: ?*anyopaque, worker_session_id: u64) gateway.policy.WorkerPressure {
    _ = ctx;
    _ = worker_session_id;
    return .{ .pool_free_bytes = std.math.maxInt(usize) };
}

fn ignoringFaultReporter(ctx: ?*anyopaque, worker_session_id: u64, reason: []const u8) void {
    _ = ctx;
    _ = worker_session_id;
    _ = reason;
}
