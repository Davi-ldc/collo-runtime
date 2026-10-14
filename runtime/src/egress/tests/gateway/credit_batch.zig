//! The batch of flow-control credits on their way back to the shard engines
//! (`egress/gateway/credit_batch.zig`), which the body drain and the release drain share: HTTP/2
//! credits merge only when shard, engine run, source, stream and window flag all match, the
//! zero-byte final credit keeps a slot of its own, HTTP/1 resumes dedupe per shard, run and
//! source, a full table flushes before it takes another credit, and a flush hands each credit of
//! the current run to its engine and drops one of a run that ended. The engines are built and
//! never started (run 0), so a credit the gateway hands over reaches an inner engine that drops
//! it, and the tests read the batch's slots and the engines' credit counts. Which credit an
//! extent or a pull carries is covered in `release_flow.zig` and `body_pump.zig`. Lane:
//! egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");

const body_credit = @import("collo_egress_client").core.body_credit;
const CreditBatch = gateway.credit_batch.CreditBatch;

/// The run of an engine that never started.
const current_run: gateway.engine.Run = 0;

fn shardSet() !gateway.shard.Set {
    return gateway.shard.Set.init(std.testing.allocator, 2, .{}, 0);
}

test "HTTP/2 credits of one stream merge, and another shard, run, source, stream or window flag keeps its own slot" {
    var shards = try shardSet();
    defer shards.deinit(std.testing.allocator);
    var batch = CreditBatch{};
    defer batch.flush(&shards);

    batch.add(&shards, 0, current_run, body_credit.h2Data(1, 3, 10, true));
    batch.add(&shards, 0, current_run, body_credit.h2Data(1, 3, 15, true));
    try std.testing.expectEqual(@as(usize, 1), batch.h2_len);
    try std.testing.expectEqual(@as(usize, 25), batch.h2[0].encoded_bytes);

    batch.add(&shards, 1, current_run, body_credit.h2Data(1, 3, 1, true));
    batch.add(&shards, 0, current_run, body_credit.h2Data(2, 3, 1, true));
    batch.add(&shards, 0, current_run, body_credit.h2Data(1, 5, 1, true));
    batch.add(&shards, 0, current_run, body_credit.h2Data(1, 3, 1, false));
    batch.add(&shards, 0, current_run + 1, body_credit.h2Data(1, 3, 1, true));
    try std.testing.expectEqual(@as(usize, 6), batch.h2_len);
    // The merged slot kept its sum; none of the others joined it.
    try std.testing.expectEqual(@as(usize, 25), batch.h2[0].encoded_bytes);
    try std.testing.expectEqual(@as(usize, 1), batch.h2[1].shard_index);
    try std.testing.expectEqual(@as(u64, 2), batch.h2[2].source_id);
    try std.testing.expectEqual(@as(u32, 5), batch.h2[3].stream_id);
    try std.testing.expect(!batch.h2[4].update_stream_window);
    try std.testing.expectEqual(current_run + 1, batch.h2[5].run);
}

test "the zero-byte final credit of a stream keeps a slot of its own, so its message still goes out" {
    var shards = try shardSet();
    defer shards.deinit(std.testing.allocator);
    var batch = CreditBatch{};
    defer batch.flush(&shards);

    batch.add(&shards, 0, current_run, body_credit.h2Data(1, 3, 64, true));
    // The stream's last DATA frame carries no bytes and no stream-window update; folding it into
    // the slot above would drop the message that surfaces the stream's end.
    batch.add(&shards, 0, current_run, body_credit.h2Data(1, 3, 0, false));
    try std.testing.expectEqual(@as(usize, 2), batch.h2_len);
    try std.testing.expectEqual(@as(usize, 64), batch.h2[0].encoded_bytes);
    try std.testing.expectEqual(@as(usize, 0), batch.h2[1].encoded_bytes);
    try std.testing.expect(!batch.h2[1].update_stream_window);
}

test "HTTP/1 resumes dedupe per shard, run and source" {
    var shards = try shardSet();
    defer shards.deinit(std.testing.allocator);
    var batch = CreditBatch{};
    defer batch.flush(&shards);

    batch.add(&shards, 0, current_run, body_credit.h1Resume(7));
    batch.add(&shards, 0, current_run, body_credit.h1Resume(7));
    try std.testing.expectEqual(@as(usize, 1), batch.h1_len);
    batch.add(&shards, 1, current_run, body_credit.h1Resume(7));
    batch.add(&shards, 0, current_run, body_credit.h1Resume(8));
    batch.add(&shards, 0, current_run + 1, body_credit.h1Resume(7));
    try std.testing.expectEqual(@as(usize, 4), batch.h1_len);
    try std.testing.expectEqual(@as(usize, 1), batch.h1[1].shard_index);
    try std.testing.expectEqual(@as(u64, 8), batch.h1[2].source_id);
    try std.testing.expectEqual(current_run + 1, batch.h1[3].run);
    try std.testing.expectEqual(@as(usize, 0), batch.h2_len);
}

test "a full table flushes before it takes another credit, so batching never fails" {
    var shards = try shardSet();
    defer shards.deinit(std.testing.allocator);
    var batch = CreditBatch{};
    defer batch.flush(&shards);

    for (0..CreditBatch.h2_slot_count) |stream|
        batch.add(&shards, 0, current_run, body_credit.h2Data(1, @intCast(stream + 1), 4, true));
    try std.testing.expectEqual(CreditBatch.h2_slot_count, batch.h2_len);
    batch.add(&shards, 0, current_run, body_credit.h2Data(9, 1, 4, true));
    try std.testing.expectEqual(@as(usize, 1), batch.h2_len);
    try std.testing.expectEqual(@as(u64, 9), batch.h2[0].source_id);
    try std.testing.expectEqual(@as(u64, CreditBatch.h2_slot_count), shards.get(0).engine.credits_returned);

    for (0..CreditBatch.h1_slot_count) |source|
        batch.add(&shards, 1, current_run, body_credit.h1Resume(source + 1));
    try std.testing.expectEqual(CreditBatch.h1_slot_count, batch.h1_len);
    batch.add(&shards, 1, current_run, body_credit.h1Resume(100));
    try std.testing.expectEqual(@as(usize, 1), batch.h1_len);
    try std.testing.expectEqual(@as(u64, 100), batch.h1[0].source_id);
    // That flush sent the HTTP/2 slots too.
    try std.testing.expectEqual(@as(usize, 0), batch.h2_len);
}

test "a credit of none adds nothing, and a flush empties the batch" {
    var shards = try shardSet();
    defer shards.deinit(std.testing.allocator);
    var batch = CreditBatch{};

    batch.add(&shards, 0, current_run, .none);
    try std.testing.expect(batch.isEmpty());
    batch.add(&shards, 0, current_run, body_credit.h2Data(1, 1, 1, true));
    batch.add(&shards, 1, current_run, body_credit.h1Resume(1));
    try std.testing.expect(!batch.isEmpty());
    batch.flush(&shards);
    try std.testing.expect(batch.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), batch.h2_len);
    try std.testing.expectEqual(@as(usize, 0), batch.h1_len);
}

// A worker can hold an extent across its shard's restart, and the next run numbers its streams
// afresh, so a credit of the run that ended must reach nothing of the new one.
test "a flush hands each credit of the current run to its engine and drops one of a run that ended" {
    var shards = try shardSet();
    defer shards.deinit(std.testing.allocator);
    var batch = CreditBatch{};

    batch.add(&shards, 0, current_run, body_credit.h2Data(1, 1, 40, true));
    batch.add(&shards, 0, current_run, body_credit.h1Resume(2));
    batch.add(&shards, 0, current_run +% 1, body_credit.h2Data(1, 1, 7, true));
    batch.add(&shards, 0, current_run +% 1, body_credit.h1Resume(2));
    batch.flush(&shards);

    const engine = &shards.get(0).engine;
    try std.testing.expectEqual(@as(u64, 2), engine.credits_returned);
    try std.testing.expectEqual(@as(u64, 40), engine.credit_bytes_returned);
    try std.testing.expectEqual(@as(u64, 2), engine.stale_credits_dropped);
    try std.testing.expectEqual(@as(u64, 0), shards.get(1).engine.credits_returned);
}
