//! One shard engine (`egress/gateway/engine.zig`) driven from the test's thread with fake sinks,
//! and without engine threads except where the transport must run: worker messages reach only
//! their own session's fetches, the end of a request cancels exactly its own fetches, the
//! transport checks each fetch against the network policy entry it was submitted with, the
//! active table's indexes survive swap removal, a ready queue asks for a wake only when it stops
//! being empty, the body drain batches chunks and pauses for pool room instead of losing a chunk,
//! a fetch past body end retires on its last returned extent, an allocation failure in one
//! fetch's drain fails only that fetch, and submit and init leave nothing behind when they fail,
//! an upload body going back to the allocator it came with.
//! A real worker endpoint is covered in `thin_demux.zig`, shard restarts in `shard_lifecycle.zig`
//! and `shard_chaos.zig`, and the admission that verifies a token before it submits in
//! `worker_flow.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const engine_test = @import("support/engine.zig");
const egress = @import("collo_egress_client");
const ipc = @import("collo_ipc");

const body_credit = egress.core.body_credit;

test "egress gateway fetch identity is scoped by worker session" {
    const key = gateway.active_fetch.WorkerScopedFetch{
        .worker_session_id = 10,
        .fetch_id = 1,
        .body_id = 2,
    };

    try std.testing.expect(key.matchesFetch(10, 1));
    try std.testing.expect(!key.matchesFetch(20, 1));
    try std.testing.expect(key.matchesBody(10, 1, 2));
    try std.testing.expect(!key.matchesBody(20, 1, 2));
    try std.testing.expect(!key.matchesBody(10, 1, 3));
}

// The release observer's merge (`PendingCreditAck.tryMerge`) must apply the
// rule of `active_fetch.CreditBatch.add`, which gives the reason: HTTP/2
// credits fold together only when their `update_stream_window` flags match.
test "egress gateway release-flow credit acks merge only when the window flag matches" {
    const PendingCreditAck = gateway.testing.body_release_flow.PendingCreditAck;

    var ack = PendingCreditAck{
        .shard_index = 0,
        .fetch_id = 7,
        .credit = body_credit.h2Data(9, 5, 64, true),
    };
    // The same shard, source, stream and flag merge, and the bytes add up.
    try std.testing.expect(ack.tryMerge(0, body_credit.h2Data(9, 5, 32, true)));
    try std.testing.expectEqual(@as(usize, 96), ack.credit.h2_data.encoded_bytes);
    try std.testing.expect(ack.credit.h2_data.update_stream_window);

    // The final END_STREAM credit, whose flag is clear, must not fold into a
    // run whose flag is set.
    try std.testing.expect(!ack.tryMerge(0, body_credit.h2Data(9, 5, 16, false)));
    try std.testing.expectEqual(@as(usize, 96), ack.credit.h2_data.encoded_bytes);
    try std.testing.expect(ack.credit.h2_data.update_stream_window);

    // Nor may a credit with the flag set fold into a run with it clear, while
    // credits with the flag clear still merge with each other.
    var final_ack = PendingCreditAck{
        .shard_index = 0,
        .fetch_id = 7,
        .credit = body_credit.h2Data(9, 5, 16, false),
    };
    try std.testing.expect(!final_ack.tryMerge(0, body_credit.h2Data(9, 5, 32, true)));
    try std.testing.expect(final_ack.tryMerge(0, body_credit.h2Data(9, 5, 8, false)));
    try std.testing.expectEqual(@as(usize, 24), final_ack.credit.h2_data.encoded_bytes);
    try std.testing.expect(!final_ack.credit.h2_data.update_stream_window);

    // A different shard, stream, source or protocol never merges.
    try std.testing.expect(!ack.tryMerge(1, body_credit.h2Data(9, 5, 8, true)));
    try std.testing.expect(!ack.tryMerge(0, body_credit.h2Data(9, 6, 8, true)));
    try std.testing.expect(!ack.tryMerge(0, body_credit.h2Data(8, 5, 8, true)));
    try std.testing.expect(!ack.tryMerge(0, body_credit.h1Resume(9)));

    // HTTP/1 resumes deduplicate by source: one resume covers the whole run.
    var h1_ack = PendingCreditAck{
        .shard_index = 2,
        .fetch_id = 3,
        .credit = body_credit.h1Resume(41),
    };
    try std.testing.expect(h1_ack.tryMerge(2, body_credit.h1Resume(41)));
    try std.testing.expect(!h1_ack.tryMerge(2, body_credit.h1Resume(42)));
    try std.testing.expect(!h1_ack.tryMerge(1, body_credit.h1Resume(41)));
}

test "egress gateway engine control messages are scoped by worker session" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 1, 1);
    try engine_test.notePublishedExtents(&engine, 1, 1, 1, 2);
    try engine_test.notePublishedExtents(&engine, 2, 1, 1, 2);

    // An extent release from worker session 2 must not touch session 1's fetch,
    // although their fetch and body ids are the same.
    engine.releaseExtentCredit(2, 1, 1, body_credit.h2Data(9, 7, 64, true));
    try std.testing.expectEqual(@as(usize, 2), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 2, 1, 1));

    engine.cancelFetch(1, ipc.EgressCancel.init(1, 6));
    try std.testing.expect(engine_test.activeFetchCanceled(&engine, 1, 1));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 1, 1));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 2, 1));

    engine.releaseBody(2, ipc.EgressReleaseBody.init(1, 1));
    try std.testing.expect(engine_test.activeFetchCanceled(&engine, 2, 1));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 2, 1));
    try std.testing.expect(engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(engine.hasActiveBody(2, 1, 1));

    // Cancellation does not invent or drop extent bookkeeping.
    try std.testing.expectEqual(@as(usize, 2), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 2, 1, 1));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));
}

test "egress gateway active indexes survive swap removal" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 2, 2);
    try engine_test.markActiveTerminalDone(&engine, 1, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expect(completed.items[0].matchesBody(1, 1, 1));
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(engine.hasActiveBody(2, 2, 2));

    completed.clearRetainingCapacity();
    try engine_test.markActiveTerminalDone(&engine, 2, 2, 2);
    try engine_test.wakeActiveTask(&engine, 2, 2, 2);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expect(completed.items[0].matchesBody(2, 2, 2));
    try std.testing.expect(!engine.hasActiveBody(2, 2, 2));
}

test "egress gateway active indexes remain usable after swap removal" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 2, 2);
    try engine_test.markActiveTerminalDone(&engine, 1, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(engine.hasActiveBody(2, 2, 2));

    engine.cancelFetch(2, ipc.EgressCancel.init(2, 6));
    try std.testing.expect(engine_test.activeFetchCanceled(&engine, 2, 2));
}

test "egress gateway active buckets handle many fetches for one worker" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();

    const fetch_count: usize = 2048;
    for (0..fetch_count) |index| {
        const id: u64 = @intCast(index + 1);
        try engine_test.injectActive(&engine, 7, id, id + 10_000);
    }

    engine.detachWorker(7);
    for (0..fetch_count) |index| {
        const id: u64 = @intCast(index + 1);
        try std.testing.expect(engine_test.activeFetchCanceled(&engine, 7, id));
        try engine_test.markActiveTaskDone(&engine, 7, id);
    }
    engine_test.wakeGeneric(&engine);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(fetch_count, completed.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));
}

test "egress gateway request end cancels exactly that request's fetches after a swap removal" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();

    // Session 1 runs fetches 1 and 3 for request 5 and fetch 2 for request 6. Session 2's fetch 4
    // names the same request id and generation, and fetch 5 a later generation of request 5, so
    // only the whole key tells them apart. Fetch 3 comes last in the table.
    try engine_test.injectActiveRequest(&engine, 1, 1, 1, .{ .request_id = 5, .request_generation = 1 });
    try engine_test.injectActiveRequest(&engine, 1, 2, 2, .{ .request_id = 6, .request_generation = 1 });
    try engine_test.injectActiveRequest(&engine, 2, 4, 4, .{ .request_id = 5, .request_generation = 1 });
    try engine_test.injectActiveRequest(&engine, 1, 5, 5, .{ .request_id = 5, .request_generation = 2 });
    try engine_test.injectActiveRequest(&engine, 1, 3, 3, .{ .request_id = 5, .request_generation = 1 });

    // Fetch 1 retires first, so the swap removal moves fetch 3 into its index, and the request's
    // bucket must find fetch 3 where it now is.
    try engine_test.markActiveTerminalDone(&engine, 1, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);
    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expectEqual(
        gateway.budgets.BudgetKey{ .session_id = 1, .request_id = 5, .request_generation = 1 },
        engine_test.activeFetchBudgetKey(&engine, 1, 3, 3).?,
    );

    engine.cancelRequest(.{ .session_id = 1, .request_id = 5, .request_generation = 1 });
    try std.testing.expect(engine_test.activeFetchCanceled(&engine, 1, 3));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 1, 3));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 1, 2));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 2, 4));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 1, 5));

    // A request with no fetch here, or ended a second time, cancels nothing more.
    engine.cancelRequest(.{ .session_id = 3, .request_id = 5, .request_generation = 1 });
    engine.cancelRequest(.{ .session_id = 1, .request_id = 5, .request_generation = 1 });
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 1, 2));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 2, 4));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 1, 5));
}

test "egress gateway body pool pressure pauses the fetch without canceling" {
    SenderLog.reset();
    PressureState.reset();
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setWorkerPressureProbe(fakeWorkerPressureProbe);

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.appendReadyBodyChunk(&engine, 1, 1, 1, "body");

    // The pool has less room than one drain can take, so the destructive drain
    // must not run.
    PressureState.pool_free_bytes = engine.policy.max_body_chunk_bytes - 1;
    engine_test.wakeGeneric(&engine);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 0), completed.items.len);
    try std.testing.expectEqual(@as(usize, 0), SenderLog.calls);
    try std.testing.expect(engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 1, 1));
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, 1, 1, 1));

    // Room returns, as the release drain gives it back in production, and the
    // same fetch resumes draining: a full pool pauses a fetch, never cancels it.
    PressureState.pool_free_bytes = std.math.maxInt(usize);
    engine.wakeForWorkerPressureChange(1);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 0), completed.items.len);
    try std.testing.expectEqual(@as(usize, 1), SenderLog.calls);
    try std.testing.expectEqual(@as(usize, "body".len), SenderLog.chunk_bytes);
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 1, 1));
    try std.testing.expect(engine.hasActiveBody(1, 1, 1));
}

test "egress gateway worker detach with outstanding extents leaks nothing" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.appendReadyBodyChunk(&engine, 1, 1, 1, "queued-but-never-published");
    try engine_test.notePublishedExtents(&engine, 1, 1, 1, 3);

    engine.detachWorker(1);

    try std.testing.expect(engine_test.activeFetchCanceled(&engine, 1, 1));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 1, 1));
    // Detaching does not release the extents, which go away with the worker's
    // pool mapping; the fetch must still leave the table.
    try std.testing.expectEqual(@as(usize, 3), engine_test.outstandingExtents(&engine, 1, 1, 1));

    try engine_test.markActiveTaskDone(&engine, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expect(completed.items[0].matchesBody(1, 1, 1));
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));

    // A release that raced the detach arrives after the fetch retired: its
    // credit is dropped, and nothing crashes or detaches again.
    engine.releaseExtentCredit(1, 1, 1, body_credit.h2Data(3, 5, 128, true));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.leakedBodyCreditBytes(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));
}

test "egress gateway scoped lifecycle stress drains tables and extents" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .queue_capacity = 16,
        .h2_connector_count = 0,
        .ready_event_capacity = 8,
    });
    defer engine.deinit();

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);

    var completed_total: usize = 0;
    for (0..10_000) |index| {
        const worker_session_id: u64 = @intCast(index + 1);
        const fetch_id: u64 = @intCast((index % 17) + 1);
        const body_id: u64 = @intCast((index % 11) + 1);

        try engine_test.injectActive(&engine, worker_session_id, fetch_id, body_id);
        try engine_test.notePublishedExtents(&engine, worker_session_id, fetch_id, body_id, 2);
        try std.testing.expectEqual(@as(usize, 2), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));

        // Messages from another session must not touch this fetch.
        engine.releaseExtentCredit(worker_session_id + 1, fetch_id, body_id, body_credit.h2Data(1, 1, 16, true));
        engine.cancelFetch(worker_session_id + 1, ipc.EgressCancel.init(fetch_id, 1));
        engine.releaseBody(worker_session_id + 1, ipc.EgressReleaseBody.init(fetch_id, body_id));
        try std.testing.expectEqual(@as(usize, 2), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));
        try std.testing.expect(!engine_test.activeFetchTerminal(&engine, worker_session_id, fetch_id));

        switch (index % 3) {
            0 => engine.detachWorker(worker_session_id),
            1 => engine.cancelFetch(worker_session_id, ipc.EgressCancel.init(fetch_id, 2)),
            else => engine.releaseBody(worker_session_id, ipc.EgressReleaseBody.init(fetch_id, body_id)),
        }
        try std.testing.expect(engine_test.activeFetchTerminal(&engine, worker_session_id, fetch_id));

        // One of the two extents comes back before the task settles.
        engine.releaseExtentCredit(worker_session_id, fetch_id, body_id, body_credit.h2Data(1, 1, 16, true));
        try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, worker_session_id, fetch_id, body_id));

        try engine_test.markActiveTaskDone(&engine, worker_session_id, fetch_id);
        try engine_test.wakeActiveTask(&engine, worker_session_id, fetch_id, body_id);
        try engine.collectReadyCompleted(&completed);
        completed_total += completed.items.len;
        completed.clearRetainingCapacity();

        try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));

        // The second release arrives after retire and is dropped quietly.
        engine.releaseExtentCredit(worker_session_id, fetch_id, body_id, body_credit.h2Data(1, 1, 16, true));
    }

    try std.testing.expectEqual(@as(usize, 10_000), completed_total);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));
    try std.testing.expectEqual(@as(usize, 0), engine_test.readyPendingEventCount(&engine));
    try std.testing.expect(!engine_test.readyScanPending(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.leakedBodyCreditBytes(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));
}

test "egress gateway ready events process only the selected active task" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 2, 2);
    try engine_test.markActiveTerminalDone(&engine, 1, 1, 1);
    try engine_test.markActiveTerminalDone(&engine, 2, 2, 2);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expect(completed.items[0].matchesBody(1, 1, 1));
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(engine.hasActiveBody(2, 2, 2));
}

test "egress gateway worker pressure wake scans only that worker" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 2, 2);
    try engine_test.markActiveTerminalDone(&engine, 1, 1, 1);
    try engine_test.markActiveTerminalDone(&engine, 2, 2, 2);

    engine.wakeForWorkerPressureChange(1);
    engine.wakeForWorkerPressureChange(1);
    try std.testing.expectEqual(@as(usize, 1), engine_test.readyWorkerScanPendingCount(&engine));
    try std.testing.expect(!engine_test.readyScanPending(&engine));

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expect(completed.items[0].matchesBody(1, 1, 1));
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(engine.hasActiveBody(2, 2, 2));
    try std.testing.expectEqual(@as(usize, 0), engine_test.readyWorkerScanPendingCount(&engine));
    try std.testing.expect(!engine_test.readyScanPending(&engine));
}

test "egress gateway ready event overflow falls back to active scan" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .queue_capacity = 1,
        .h2_connector_count = 0,
        .ready_event_capacity = 1,
    });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 2, 2);
    try engine_test.markActiveTerminalDone(&engine, 1, 1, 1);
    try engine_test.markActiveTerminalDone(&engine, 2, 2, 2);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);
    try engine_test.wakeActiveTask(&engine, 2, 2, 2);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 2), completed.items.len);
    try std.testing.expectEqual(@as(u64, 1), engine_test.readyOverflowScanTotal(&engine));
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
    try std.testing.expect(!engine.hasActiveBody(2, 2, 2));
}

test "egress gateway extent release maps to the right fetch and decrements outstanding" {
    SenderLog.reset();
    PressureState.reset();
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 1, 2, 2);
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "alpha", body_credit.h2Data(1, 1, 5, true));
    try engine_test.appendReadyBodyChunk(&engine, 1, 2, 2, "beta");
    engine_test.wakeGeneric(&engine);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 2), SenderLog.calls);
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 1, 2, 2));

    engine.releaseExtentCredit(1, 1, 1, body_credit.h2Data(1, 1, 5, true));
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 1, 2, 2));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
}

test "egress gateway empty final DATA chunk publishes nothing and strands no extent" {
    // An END_STREAM carried by its own zero-byte DATA frame queues an empty
    // chunk whose zero-byte credit surfaces the stream's deferred `.end`. The
    // chunk has no pool extent for the credit to ride, so `drainBody` must
    // release it at once; a dropped credit would hang the fetch until its
    // deadline.
    SenderLog.reset();
    PressureState.reset();
    PacketLog.reset();
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);

    try engine_test.injectActive(&engine, 1, 1, 1);
    // A data frame, then a zero-byte frame that carries END_STREAM.
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "payload", body_credit.h2Data(1, 1, 7, true));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 0, false));
    try engine_test.markActiveBodyComplete(&engine, 1, 1, 1);
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    engine_test.wakeGeneric(&engine);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    // Exactly one publish: the empty chunk produces no descriptor or extent.
    try std.testing.expectEqual(@as(usize, 1), SenderLog.calls);
    try std.testing.expectEqual(@as(usize, "payload".len), SenderLog.chunk_bytes);
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expect(engine_test.activeFetchBodyEndSent(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));

    // The one extent comes back and the fetch retires with nothing left over.
    engine.releaseExtentCredit(1, 1, 1, body_credit.h2Data(1, 1, 7, true));
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
}

test "egress gateway batches multiple ready chunks into one publication" {
    SenderLog.reset();
    PressureState.reset();
    PacketLog.reset();
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);
    engine.setWorkerPressureProbe(fakeWorkerPressureProbe);

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "alpha", body_credit.h2Data(1, 1, 5, true));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "beta", body_credit.h2Data(1, 1, 4, true));
    try engine_test.appendReadyBodyChunk(&engine, 1, 1, 1, "gamma");
    try engine_test.markActiveBodyComplete(&engine, 1, 1, 1);
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    engine_test.wakeGeneric(&engine);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    // Three drained chunks go out in one publish call with three payloads.
    // Each credited chunk's credit rides its own payload, and the body end
    // follows the batch exactly once.
    try std.testing.expectEqual(@as(usize, 1), SenderLog.calls);
    try std.testing.expectEqual(@as(usize, 3), SenderLog.entries);
    try std.testing.expectEqual(@as(usize, "alpha".len + "beta".len + "gamma".len), SenderLog.chunk_bytes);
    try std.testing.expectEqual(@as(usize, 2), SenderLog.credited_entries);
    try std.testing.expectEqual(@as(usize, 3), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expect(engine_test.activeFetchBodyEndSent(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), PacketLog.body_end_packets);
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));

    // Every extent comes back, and the last return retires the fetch.
    engine.releaseExtentCredit(1, 1, 1, body_credit.h2Data(1, 1, 5, true));
    engine.releaseExtentCredit(1, 1, 1, body_credit.h2Data(1, 1, 4, true));
    engine.releaseExtentCredit(1, 1, 1, .none);
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
}

test "egress gateway body batch flushes before accepting the chunk past capacity" {
    SenderLog.reset();
    PressureState.reset();
    PacketLog.reset();
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);
    engine.setWorkerPressureProbe(fakeWorkerPressureProbe);

    try engine_test.injectActive(&engine, 1, 1, 1);
    var index: usize = 0;
    while (index < gateway.body_pump.body_chunk_batch_max + 1) : (index += 1)
        try engine_test.appendReadyBodyChunk(&engine, 1, 1, 1, "x");
    try engine_test.markActiveBodyComplete(&engine, 1, 1, 1);
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    engine_test.wakeGeneric(&engine);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 2), SenderLog.calls);
    try std.testing.expectEqual(gateway.body_pump.body_chunk_batch_max + 1, SenderLog.entries);
    try std.testing.expectEqual(gateway.body_pump.body_chunk_batch_max + 1, SenderLog.chunk_bytes);
    try std.testing.expectEqual(
        gateway.body_pump.body_chunk_batch_max + 1,
        engine_test.outstandingExtents(&engine, 1, 1, 1),
    );
}

test "egress gateway pool headroom of one quantum publishes per chunk without dropping" {
    SenderLog.reset();
    PressureState.reset();
    PacketLog.reset();
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);
    engine.setWorkerPressureProbe(fakeWorkerPressureProbe);

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.appendReadyBodyChunk(&engine, 1, 1, 1, "alpha");
    try engine_test.appendReadyBodyChunk(&engine, 1, 1, 1, "beta");
    try engine_test.markActiveBodyComplete(&engine, 1, 1, 1);
    try engine_test.markActiveTaskDone(&engine, 1, 1);

    // Room for exactly one drain, the stream pump's
    // `default_max_pending_decoded_bytes`: the batch can never hold a drained
    // chunk and also reserve room for the next drain, so it publishes each
    // chunk on its own, without pausing or dropping one.
    PressureState.pool_free_bytes = 256 * 1024;
    engine_test.wakeGeneric(&engine);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expectEqual(@as(usize, 2), SenderLog.calls);
    try std.testing.expectEqual(@as(usize, 2), SenderLog.entries);
    try std.testing.expectEqual(@as(usize, "alpha".len + "beta".len), SenderLog.chunk_bytes);
    try std.testing.expectEqual(@as(usize, 2), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expect(engine_test.activeFetchBodyEndSent(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), PacketLog.body_end_packets);
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 1, 1));
}

test "egress gateway ready queues request a wake only on empty transitions" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 2, 2);

    // Task-ready queue: only an enqueue into the empty queue asks for a signal.
    try std.testing.expect(try engine_test.enqueueReadyTaskWake(&engine, 1, 1, 1));
    try std.testing.expect(!try engine_test.enqueueReadyTaskWake(&engine, 2, 2, 2));

    // Worker-scan queue: the same rule, and a session already queued is not
    // queued again.
    try std.testing.expect(engine.ready.enqueueWorkerScan(1));
    try std.testing.expect(!engine.ready.enqueueWorkerScan(1));
    try std.testing.expect(!engine.ready.enqueueWorkerScan(2));

    // Scan bit: setting it while it is set asks for no wake.
    try std.testing.expect(engine.ready.requestScan(false));
    try std.testing.expect(!engine.ready.requestScan(false));

    // A collection pass drains all three sources; each next producer must
    // signal again.
    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    try std.testing.expect(try engine_test.enqueueReadyTaskWake(&engine, 1, 1, 1));
    try std.testing.expect(engine.ready.enqueueWorkerScan(1));
    try std.testing.expect(engine.ready.requestScan(false));
}

test "egress gateway extent release after fetch retire is tolerated" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.notePublishedExtents(&engine, 1, 1, 1, 1);
    engine.cancelFetch(1, ipc.EgressCancel.init(1, 4));
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 1), completed.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));

    // The worker's releases drain after the fetch retired. The pool handle
    // already authenticated each release, so the credit is dropped, and
    // nothing leaks or crashes however many arrive.
    engine.releaseExtentCredit(1, 1, 1, body_credit.h2Data(2, 9, 4096, true));
    engine.releaseExtentCredit(1, 1, 1, .none);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));
}

test "egress gateway fetch retires only at body end with zero outstanding extents" {
    SenderLog.reset();
    PressureState.reset();
    PacketLog.reset();
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);

    try engine_test.injectActive(&engine, 1, 1, 1);
    // 96 KiB splits at `Policy.max_body_chunk_bytes`, `EGRESS_BODY_CHUNK_BYTES`
    // by default, into two published payloads.
    const big = try std.testing.allocator.alloc(u8, 96 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try engine_test.appendReadyBodyChunk(&engine, 1, 1, 1, big);
    try engine_test.markActiveBodyComplete(&engine, 1, 1, 1);
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    engine_test.wakeGeneric(&engine);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    // Body end went out and the task is done, but two extents are still out,
    // so the fetch must stay in the table for the release observer.
    try std.testing.expectEqual(@as(usize, 0), completed.items.len);
    try std.testing.expectEqual(@as(usize, 2), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expect(engine_test.activeFetchBodyEndSent(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), PacketLog.body_end_packets);
    try std.testing.expect(engine.hasActiveBody(1, 1, 1));

    engine.releaseExtentCredit(1, 1, 1, .none);
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 1, 1, 1));
    engine.wakeForWorkerPressureChange(1);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 0), completed.items.len);
    try std.testing.expect(engine.hasActiveBody(1, 1, 1));

    engine.releaseExtentCredit(1, 1, 1, .none);
    // The last extent returned after body end retires the fetch with no
    // further wake. In the gateway, the release observer then finds no active
    // body and removes the route (`runtime/body_release_flow.zig`).
    try std.testing.expect(!engine.hasActiveBody(1, 1, 1));
    engine.wakeForWorkerPressureChange(1);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 0), completed.items.len);
    // `drainBody` checks `body_end_sent`, so the end packet goes out once.
    try std.testing.expectEqual(@as(usize, 1), PacketLog.body_end_packets);
}

test "egress gateway extent credit release is tolerated when the inner engine cannot accept it" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 0 });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 42, 1, 2);
    try engine_test.notePublishedExtents(&engine, 42, 1, 2, 1);

    // With zero connector threads the inner engine is never available, and
    // releases against it must be absorbed without detaching the worker or
    // failing the fetch. The engine's warn-and-count branch for a refused
    // release never runs: `tryReleaseFetchBodyCredit` has no error path.
    engine.releaseExtentCredit(42, 1, 2, body_credit.h2Data(99, 7, 512, true));
    engine.releaseExtentCredit(42, 1, 2, body_credit.h1Resume(13));

    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, 42, 1, 2));
    try std.testing.expect(engine.hasActiveBody(42, 1, 2));
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 42, 1));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));
}

test "egress gateway queued body credit release failure still reports a worker fault" {
    // A credit released straight to the engine, as for chunks still queued at
    // a cancel or a teardown, never reached the pool, so a refused release
    // strands the engine's flow control and must report the worker.
    var fake = FailingCreditReleaseEngine{ .allocator = std.testing.allocator };
    const credit = body_credit.h2Data(99, 7, 512, true);
    var fetch = gateway.active_fetch.Fetch{
        .worker_session_id = 42,
        .budget_key = .{ .session_id = 42, .request_id = 1, .request_generation = 1 },
        .worker_attached = true,
        .task = undefined,
        .body = undefined,
        .fetch_id = 1,
        .body_id = 2,
    };

    fetch.releaseImmediateCredits(&fake, &.{credit});

    try std.testing.expectEqual(@as(u64, 1), fake.failures);
    try std.testing.expectEqual(@as(u64, 42), fake.failed_worker_session_id);
    try std.testing.expectEqual(@as(u64, 512), fake.leaked_bytes);
}

test "egress gateway submit rolls back active entry when inner engine is unavailable" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .queue_capacity = 4,
        .h2_connector_count = 0,
    });
    defer engine.deinit();

    try std.testing.expectError(
        error.EgressEngineUnavailable,
        engine.submit(submit_session_id, submit_start, submit_options),
    );
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));
}

test "egress gateway submit frees a refused upload body with the allocator it came with" {
    // The engine allocates through a counting allocator, as a shard's engine does, and each body
    // comes from the testing allocator, as the gateway's assembly buffers come from its own.
    var counting = gateway.counting_allocator.CountingAllocator{ .child = std.testing.allocator };
    var engine = try gateway.engine.Engine.init(counting.allocator(), .{
        .queue_capacity = 4,
        .h2_connector_count = 0,
    });
    defer engine.deinit();
    var pooled_start = submit_start;
    pooled_start.body = "";

    // Refused before a task takes the body: an identity of zero.
    var unnamed_start = pooled_start;
    unnamed_start.fetch_id = 0;
    const live_bytes_before = counting.liveBytes();
    try std.testing.expectError(
        error.InvalidEgressGatewayFetchIdentity,
        engine.submit(submit_session_id, unnamed_start, try uploadOptions(32)),
    );
    try std.testing.expectEqual(live_bytes_before, counting.liveBytes());

    // Refused after the task took it, by an inner engine without threads. An inline fetch refused
    // the same way first sizes the active table, which keeps its capacity.
    try std.testing.expectError(
        error.EgressEngineUnavailable,
        engine.submit(submit_session_id, submit_start, submit_options),
    );
    const live_bytes_sized = counting.liveBytes();
    try std.testing.expectError(
        error.EgressEngineUnavailable,
        engine.submit(submit_session_id, pooled_start, try uploadOptions(32)),
    );
    try std.testing.expectEqual(live_bytes_sized, counting.liveBytes());
}

/// `submit_options` with an assembled upload body of `len` bytes from the testing allocator, which
/// the submit owns from the call on.
fn uploadOptions(len: usize) !gateway.engine.SubmitOptions {
    var options = submit_options;
    const body = try std.testing.allocator.alloc(u8, len);
    @memset(body, 0x6b);
    options.owned_body = .{ .bytes = body, .allocator = std.testing.allocator };
    return options;
}

test "egress gateway checks each fetch against its own network policy entry" {
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{ .h2_connector_count = 1 });
    defer engine.deinit();
    var errors = FetchErrorLog{};
    engine.setPacketSender(&errors, recordFetchError);
    try engine.start();

    // Numeric hosts resolve without DNS and every case is refused before it connects, so nothing
    // leaves the host. The second and third fetches share a URL and differ only in their entry,
    // so no engine-wide policy could give both outcomes.
    const cases = [_]NetworkCase{
        .{
            .url = "https://10.0.0.1/",
            .network = gateway.policy.public_https,
            .refusal = "EgressDenied",
        },
        .{
            .url = "http://10.0.0.1/",
            .network = gateway.policy.public_https,
            .refusal = "PlainHttpFetchDisabled",
        },
        .{
            .url = "http://10.0.0.1/",
            .network = .{ .kind = .any_host, .allow_private_networks = false, .allow_http = true },
            .refusal = "EgressDenied",
        },
        // Loopback stays denied whatever an entry's flags allow.
        .{
            .url = "https://127.0.0.1/",
            .network = .{ .kind = .any_host, .allow_private_networks = true, .allow_http = true },
            .refusal = "EgressDenied",
        },
    };
    for (cases, 1..) |case, fetch_id| {
        try engine.submit(submit_session_id, .{
            .fetch_id = fetch_id,
            .egress_token = ipc.egress_token.none,
            .body_id = fetch_id,
            .method = "GET",
            .url = case.url,
            .headers = &.{},
            .body = "",
        }, .{
            .isolation = .{ .policy_id = @splat(@intCast(fetch_id)) },
            .network = case.network,
            .budget_key = .{
                .session_id = submit_session_id,
                .request_id = 1,
                .request_generation = 1,
            },
        });
    }

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    var rounds: usize = 0;
    while (errors.count < cases.len) : (rounds += 1) {
        if (rounds == wake_rounds_max)
            return error.TestTimeout;
        try waitForWake(engine.wake_fd);
        try engine.collectReadyCompleted(&completed);
    }
    for (cases, 1..) |case, fetch_id| {
        const message = errors.messageFor(fetch_id) orelse return error.TestUnexpectedResult;
        if (std.mem.indexOf(u8, message, case.refusal) == null) {
            std.debug.print("fetch {d} to {s} failed with \"{s}\"\n", .{ fetch_id, case.url, message });
            return error.TestUnexpectedResult;
        }
    }
}

test "egress gateway engine init cleans up allocation failures" {
    var success_seen = false;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var maybe_engine = gateway.engine.Engine.init(failing.allocator(), .{
            .queue_capacity = 4,
            .h2_connector_count = 1,
        }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        maybe_engine.deinit();
        success_seen = true;
        break;
    }
    try std.testing.expect(success_seen);
}

test "egress gateway submit is transactional under allocation failure" {
    var reached_inner_engine = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var maybe_engine = gateway.engine.Engine.init(failing.allocator(), .{
            .queue_capacity = 4,
            .h2_connector_count = 0,
        }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer maybe_engine.deinit();

        const submit_error: ?anyerror = if (maybe_engine.submit(
            submit_session_id,
            submit_start,
            submit_options,
        )) |_| null else |err| err;

        const err = submit_error orelse return error.UnexpectedEgressGatewaySubmitSuccess;
        switch (err) {
            error.OutOfMemory => {},
            error.EgressEngineUnavailable => {
                reached_inner_engine = true;
                try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&maybe_engine));
                break;
            },
            else => return err,
        }
        try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&maybe_engine));
    }
    try std.testing.expect(reached_inner_engine);
}

test "egress gateway OOM in one fetch's drain demotes it and its neighbor completes" {
    SenderLog.reset();
    PressureState.reset();
    PacketLog.reset();
    var fail_switch = FailSwitchAllocator{ .child = std.testing.allocator };
    var engine = try gateway.engine.Engine.init(fail_switch.allocator(), .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);
    engine.setWorkerPressureProbe(fakeWorkerPressureProbe);

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 2, 2);
    // Two empty credit-only chunks ahead of the data chunk give the doomed
    // fetch's drain three credits, more than `PullCredits.inline_slots` in
    // `egress/core/body_settlement.zig` holds inline, so the drain must
    // allocate its credit list and meets the injected failure.
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 1, false));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 2, false));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "doomed", body_credit.h2Data(1, 1, 6, true));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 2, 2, 2, "alive", body_credit.h2Data(2, 2, 5, true));
    try engine_test.markActiveBodyComplete(&engine, 2, 2, 2);
    try engine_test.markActiveTaskDone(&engine, 2, 2);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);

    // Only fetch 1's task is woken while every allocation fails, so the
    // failure lands in its pump, and the engine must turn it into that fetch's
    // terminal error instead of returning it from the pass.
    fail_switch.fail = true;
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);
    try engine.collectReadyCompleted(&completed);
    fail_switch.fail = false;

    try std.testing.expectEqual(@as(u64, 1), engine_test.demotedFetchErrors(&engine));
    try std.testing.expect(engine_test.activeFetchCanceled(&engine, 1, 1));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 1, 1));
    // The demoted fetch received its terminal error packet and published
    // nothing, so no extent can be left behind.
    try std.testing.expectEqual(@as(usize, 1), PacketLog.fetch_error_packets);
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expectEqual(@as(usize, 0), SenderLog.calls);
    // The neighbor on the same shard was untouched by the demotion.
    try std.testing.expect(!engine_test.activeFetchCanceled(&engine, 2, 2));
    try std.testing.expect(!engine_test.activeFetchTerminal(&engine, 2, 2));

    // The neighbor drains and completes normally once woken.
    try engine_test.wakeActiveTask(&engine, 2, 2, 2);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 1), SenderLog.calls);
    try std.testing.expectEqual(@as(usize, "alive".len), SenderLog.chunk_bytes);
    try std.testing.expectEqual(@as(usize, 1), SenderLog.credited_entries);
    try std.testing.expect(engine_test.activeFetchBodyEndSent(&engine, 2, 2, 2));
    try std.testing.expectEqual(@as(usize, 1), PacketLog.body_end_packets);
    engine.releaseExtentCredit(2, 2, 2, body_credit.h2Data(2, 2, 5, true));
    try std.testing.expect(!engine.hasActiveBody(2, 2, 2));

    // The demoted fetch retires through the normal path once its task
    // settles, and no extent is left out anywhere on the shard.
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));
    try std.testing.expectEqual(@as(u64, 1), engine_test.demotedFetchErrors(&engine));
}

test "egress gateway demote after published body extents reconciles and leaks nothing" {
    // A fetch whose body extents already reached the worker is demoted in
    // mid-stream. Its published extents must still come back through the
    // release path, which tolerates demoted and retired fetches, and nothing
    // may leak.
    SenderLog.reset();
    PressureState.reset();
    PacketLog.reset();
    var fail_switch = FailSwitchAllocator{ .child = std.testing.allocator };
    var engine = try gateway.engine.Engine.init(fail_switch.allocator(), .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);
    engine.setWorkerPressureProbe(fakeWorkerPressureProbe);

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "published", body_credit.h2Data(1, 1, 9, true));
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try engine.collectReadyCompleted(&completed);

    // The first chunk reached the worker: one extent is outstanding.
    try std.testing.expectEqual(@as(usize, 1), SenderLog.calls);
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 1, 1, 1));

    // More data arrives and its drain fails to allocate, which demotes the
    // fetch while the worker holds its extent. The two empty credit-only
    // chunks make the drain allocate its credit list, as in the test above.
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 1, false));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 2, false));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "doomed", body_credit.h2Data(1, 1, 6, true));
    fail_switch.fail = true;
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);
    try engine.collectReadyCompleted(&completed);
    fail_switch.fail = false;

    try std.testing.expectEqual(@as(u64, 1), engine_test.demotedFetchErrors(&engine));
    try std.testing.expect(engine_test.activeFetchCanceled(&engine, 1, 1));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), PacketLog.fetch_error_packets);
    // The published extent survives the demotion, and the fetch stays in the
    // table for the release observer.
    try std.testing.expectEqual(@as(usize, 1), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expect(engine.hasActiveBody(1, 1, 1));

    // The worker returns the published extent after the demotion: the credit
    // is accepted for the demoted fetch, and no extent is left out.
    engine.releaseExtentCredit(1, 1, 1, body_credit.h2Data(1, 1, 9, true));
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, 1, 1, 1));

    // The task settles and the normal retire path reaps the demoted fetch.
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));

    // A duplicate or late release after the fetch retired is dropped quietly,
    // with no failure counted and nothing leaked.
    engine.releaseExtentCredit(1, 1, 1, body_credit.h2Data(1, 1, 9, true));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.leakedBodyCreditBytes(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.workerForceDetachTotal(&engine));
}

test "egress gateway shard memory budget denial demotes the allocating fetch" {
    // The containment of the `FailSwitchAllocator` tests above, with the
    // `OutOfMemory` coming from the shard's own memory budget
    // (`counting_allocator.zig`) instead of a failure of every allocation.
    SenderLog.reset();
    PressureState.reset();
    PacketLog.reset();
    var counting = gateway.counting_allocator.CountingAllocator{ .child = std.testing.allocator };
    var engine = try gateway.engine.Engine.init(counting.allocator(), .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();
    engine.setBodyChunkBatchSender(countingBodyChunkBatchSender);
    engine.setPacketSender(null, recordingPacketSender);
    engine.setWorkerPressureProbe(fakeWorkerPressureProbe);

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.injectActive(&engine, 2, 2, 2);
    // The two empty credit-only chunks make the doomed fetch's drain allocate
    // its credit list, against the budget.
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 1, false));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "", body_credit.h2Data(1, 1, 2, false));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 1, 1, 1, "doomed", body_credit.h2Data(1, 1, 6, true));
    try engine_test.appendReadyBodyChunkWithCredit(&engine, 2, 2, 2, "alive", body_credit.h2Data(2, 2, 5, true));
    try engine_test.markActiveBodyComplete(&engine, 2, 2, 2);
    try engine_test.markActiveTaskDone(&engine, 2, 2);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);

    // The budget tightens to exactly the current live bytes, so it refuses
    // every allocation of the woken fetch's drain.
    const tightened = counting.liveBytes();
    counting.setBudget(tightened);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);
    try engine.collectReadyCompleted(&completed);
    // Nothing was admitted past the budget during the pass.
    try std.testing.expect(counting.liveBytes() <= tightened);
    counting.setBudget(0);

    // The engine demoted the allocating fetch with a terminal error packet,
    // and the shard and the neighbor kept running.
    try std.testing.expectEqual(@as(u64, 1), engine_test.demotedFetchErrors(&engine));
    try std.testing.expect(engine_test.activeFetchCanceled(&engine, 1, 1));
    try std.testing.expect(engine_test.activeFetchTerminal(&engine, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), PacketLog.fetch_error_packets);
    try std.testing.expectEqual(@as(usize, 0), engine_test.outstandingExtents(&engine, 1, 1, 1));
    try std.testing.expect(!engine_test.activeFetchTerminal(&engine, 2, 2));

    // With the budget lifted, the neighbor drains and completes normally.
    try engine_test.wakeActiveTask(&engine, 2, 2, 2);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 1), SenderLog.calls);
    try std.testing.expect(engine_test.activeFetchBodyEndSent(&engine, 2, 2, 2));
    engine.releaseExtentCredit(2, 2, 2, body_credit.h2Data(2, 2, 5, true));
    try std.testing.expect(!engine.hasActiveBody(2, 2, 2));

    // The demoted fetch retires cleanly once its task settles.
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);
    try engine.collectReadyCompleted(&completed);
    try std.testing.expectEqual(@as(usize, 0), engine_test.activeFetchCount(&engine));
    try std.testing.expectEqual(@as(u64, 0), engine_test.bodyCreditReleaseFailures(&engine));
}

test "egress gateway non-whitelisted publication errors stay fatal to the shard" {
    // Only the errors `isFetchDemotableError` lists are demoted. Without a
    // packet sender the head publish fails with
    // `EgressGatewayPacketSenderUnavailable`, a wiring fault rather than one
    // fetch's, which must leave the collection pass undemoted.
    var engine = try gateway.engine.Engine.init(std.testing.allocator, .{
        .h2_connector_count = 0,
    });
    defer engine.deinit();

    try engine_test.injectActive(&engine, 1, 1, 1);
    try engine_test.markActiveTaskDone(&engine, 1, 1);
    try engine_test.wakeActiveTask(&engine, 1, 1, 1);

    var completed: std.array_list.Aligned(gateway.active_fetch.WorkerScopedFetch, null) = .empty;
    defer completed.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.EgressGatewayPacketSenderUnavailable,
        engine.collectReadyCompleted(&completed),
    );
    try std.testing.expectEqual(@as(u64, 0), engine_test.demotedFetchErrors(&engine));
}

/// The session that offers the submit tests' fetch.
const submit_session_id: u64 = 77;

const submit_headers = [_]ipc.RequestHeader{
    .{ .name = "accept", .value = "application/json" },
    .{ .name = "x-test", .value = "yes" },
};

/// A fetch start as a worker sends it. `Engine.submit` never reads its token: admission
/// verified the token, and `submit_options` carries what it granted.
const submit_start = ipc.EgressFetchStartView{
    .fetch_id = 101,
    .egress_token = ipc.egress_token.none,
    .body_id = 505,
    .flags = 0,
    .max_body_bytes = 4096,
    .method = "POST",
    .url = "https://example.test/api",
    .headers = &submit_headers,
    .body = "body",
};

const submit_options = gateway.engine.SubmitOptions{
    .isolation = .{
        .security_cell_id = [_]u8{9} ** 16,
        .policy_id = [_]u8{8} ** 16,
    },
    .network = gateway.policy.public_https,
    .budget_key = .{
        .session_id = submit_session_id,
        .request_id = 202,
        .request_generation = 303,
    },
};

/// One fetch of the network policy test: the entry it runs under and the transport error its
/// failure message names.
const NetworkCase = struct {
    url: []const u8,
    network: gateway.policy.NetworkPolicy,
    refusal: []const u8,
};

/// Collection passes a threaded test waits for before it fails. Each pass follows a wake, and
/// every settled fetch wakes the engine at least once.
const wake_rounds_max: usize = 64;
/// How long one wait for an engine thread's wake lasts before the test fails.
const wake_timeout_ms: i32 = 5_000;

fn waitForWake(wake_fd: std.posix.fd_t) !void {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = wake_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&pollfds, wake_timeout_ms) == 0)
        return error.TestTimeout;
}

/// The fetch error packets an engine sent, kept by fetch id so a test can read why each fetch
/// failed. Only the collecting thread writes it.
const FetchErrorLog = struct {
    fetch_ids: [entries_max]u64 = undefined,
    messages: [entries_max][message_bytes_max]u8 = undefined,
    message_lens: [entries_max]usize = undefined,
    count: usize = 0,

    const entries_max: usize = 8;
    const message_bytes_max: usize = 128;

    fn messageFor(self: *const FetchErrorLog, fetch_id: u64) ?[]const u8 {
        for (self.fetch_ids[0..self.count], 0..) |logged_id, index| {
            if (logged_id == fetch_id)
                return self.messages[index][0..self.message_lens[index]];
        }
        return null;
    }
};

fn recordFetchError(ctx: ?*anyopaque, worker_session_id: u64, bytes: []const u8) anyerror!void {
    _ = worker_session_id;
    const log: *FetchErrorLog = @ptrCast(@alignCast(ctx.?));
    if (bytes.len < @sizeOf(u32))
        return error.InvalidEgressPacket;
    const kind = try ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)]));
    if (kind != .egress_fetch_error)
        return;
    const view = try ipc.decodeEgressFetchError(bytes);
    if (log.count == FetchErrorLog.entries_max)
        return error.TooManyFetchErrors;
    const len = @min(view.message.len, FetchErrorLog.message_bytes_max);
    @memcpy(log.messages[log.count][0..len], view.message[0..len]);
    log.message_lens[log.count] = len;
    log.fetch_ids[log.count] = view.fetch_id;
    log.count += 1;
}

/// Fails every allocation, resize and remap while `fail` is set.
/// `std.testing.FailingAllocator` counts setup allocations toward its
/// `fail_index`, which would tie a test to the engine's allocation order; the
/// switch confines the failure to one collection pass.
const FailSwitchAllocator = struct {
    child: std.mem.Allocator,
    fail: bool = false,

    fn allocator(self: *FailSwitchAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailSwitchAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail)
            return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailSwitchAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail)
            return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailSwitchAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail)
            return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailSwitchAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

const FailingCreditReleaseEngine = struct {
    allocator: std.mem.Allocator,
    failures: u64 = 0,
    failed_worker_session_id: u64 = 0,
    leaked_bytes: u64 = 0,

    pub fn releaseCredit(_: *FailingCreditReleaseEngine, _: body_credit.Handle) !void {
        return error.CreditReleaseFailed;
    }

    pub fn reportWorkerCreditReleaseFailure(
        self: *FailingCreditReleaseEngine,
        worker_session_id: u64,
        credit: body_credit.Handle,
        err: anyerror,
    ) void {
        std.debug.assert(err == error.CreditReleaseFailed);
        self.failures += 1;
        self.failed_worker_session_id = worker_session_id;
        self.leaked_bytes += switch (credit) {
            .h2_data => |h2| @as(u64, @intCast(h2.encoded_bytes)),
            .none, .h1_resume => 0,
        };
    }
};

const SenderLog = struct {
    var calls: usize = 0;
    var chunk_bytes: usize = 0;
    var entries: usize = 0;
    var credited_entries: usize = 0;

    fn reset() void {
        calls = 0;
        chunk_bytes = 0;
        entries = 0;
        credited_entries = 0;
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
    SenderLog.entries += chunks.len;
    for (chunks) |chunk| {
        SenderLog.chunk_bytes += chunk.bytes.len;
        if (!chunk.credit.isNone())
            SenderLog.credited_entries += 1;
    }
    // One pool extent per payload, as an unfragmented pool gives: a payload
    // lands in one contiguous run of blocks.
    return chunks.len;
}

const PressureState = struct {
    var pool_free_bytes: usize = std.math.maxInt(usize);

    fn reset() void {
        pool_free_bytes = std.math.maxInt(usize);
    }
};

fn fakeWorkerPressureProbe(ctx: ?*anyopaque, worker_session_id: u64) gateway.policy.WorkerPressure {
    _ = ctx;
    _ = worker_session_id;
    return .{ .pool_free_bytes = PressureState.pool_free_bytes };
}

const PacketLog = struct {
    var packets: usize = 0;
    var body_end_packets: usize = 0;
    var fetch_error_packets: usize = 0;

    fn reset() void {
        packets = 0;
        body_end_packets = 0;
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
    if (kind == .egress_body_end)
        PacketLog.body_end_packets += 1;
    if (kind == .egress_fetch_error)
        PacketLog.fetch_error_packets += 1;
}
