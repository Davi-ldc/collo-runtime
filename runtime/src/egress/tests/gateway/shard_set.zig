//! The shard set's bookkeeping (`egress/gateway/shard_set.zig`): a failed start stops the shards
//! already started, in reverse order, and each worker session counts its admitted fetches per
//! shard, dropping a shard from its list when the last of them is gone. A real set over shard
//! engines is started in `shard_lifecycle.zig` and collected by the shard supervisor in
//! `shard_chaos.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");

test "egress gateway shard rollback stops started shards in reverse order" {
    var stop_order: [3]usize = undefined;
    var stop_count: usize = 0;
    var shards = [_]FakeShard{
        .{ .id = 0, .stop_order = &stop_order, .stop_count = &stop_count },
        .{ .id = 1, .stop_order = &stop_order, .stop_count = &stop_count },
        .{ .id = 2, .stop_order = &stop_order, .stop_count = &stop_count },
    };

    gateway.shard_set.testing.stopStartedSlice(FakeShard, &shards, 2);

    try std.testing.expectEqual(@as(usize, 2), stop_count);
    try std.testing.expectEqual(@as(usize, 1), stop_order[0]);
    try std.testing.expectEqual(@as(usize, 0), stop_order[1]);
    try std.testing.expect(shards[0].stopped);
    try std.testing.expect(shards[1].stopped);
    try std.testing.expect(!shards[2].stopped);
}

test "egress gateway shard set tracks worker shard refs" {
    var set = try gateway.shard_set.Set.init(std.testing.allocator, 4, .{
        .h2_connector_count = 0,
    }, gateway.supervisor_limits.shard_memory.budget_bytes);
    defer set.deinit(std.testing.allocator);

    try set.recordWorkerFetch(std.testing.allocator, 7, 1);
    try set.recordWorkerFetch(std.testing.allocator, 7, 1);
    try set.recordWorkerFetch(std.testing.allocator, 7, 3);
    try set.recordWorkerFetch(std.testing.allocator, 8, 2);

    try std.testing.expectEqual(@as(usize, 2), gateway.shard_set.testing.workerShardCount(&set, 7));
    try std.testing.expectEqual(
        @as(usize, 2),
        gateway.shard_set.testing.workerShardRefCount(&set, 7, 1),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        gateway.shard_set.testing.workerShardRefCount(&set, 7, 3),
    );

    set.removeWorkerFetch(std.testing.allocator, 7, 1);
    try std.testing.expectEqual(
        @as(usize, 1),
        gateway.shard_set.testing.workerShardRefCount(&set, 7, 1),
    );
    set.removeWorkerFetch(std.testing.allocator, 7, 1);
    try std.testing.expectEqual(
        @as(usize, 0),
        gateway.shard_set.testing.workerShardRefCount(&set, 7, 1),
    );
    try std.testing.expectEqual(@as(usize, 1), gateway.shard_set.testing.workerShardCount(&set, 7));

    set.removeWorkerFetch(std.testing.allocator, 7, 3);
    try std.testing.expectEqual(@as(usize, 0), gateway.shard_set.testing.workerShardCount(&set, 7));
    try std.testing.expectEqual(@as(usize, 1), gateway.shard_set.testing.workerShardCount(&set, 8));
}

const FakeShard = struct {
    id: usize,
    stop_order: *[3]usize,
    stop_count: *usize,
    stopped: bool = false,

    pub fn stop(self: *FakeShard) void {
        self.stop_order[self.stop_count.*] = self.id;
        self.stop_count.* += 1;
        self.stopped = true;
    }
};
