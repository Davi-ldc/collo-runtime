//! Tests of the gateway's sizing (`egress/gateway/sizing.zig`): the worker cap against the
//! open-file limit, the clamp of the default shard count, and a plan that two processes in one
//! environment compute alike. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const sizing = gateway.sizing;

test "the worker cap counts the shared endpoint's descriptors against the open-file limit" {
    try std.testing.expectEqual(ipc.egress_shared.shared_fd_count, sizing.fds_per_worker_endpoint);

    const shard_count: usize = 2;
    const shard_engine_thread_count: usize = 2;
    const shard_budget = shard_count * sizing.estimatedShardFdBudget(shard_engine_thread_count);
    const reserved = sizing.reserved_gateway_fds + shard_budget;
    try std.testing.expectEqual(@as(usize, 3), sizing.maxWorkersForOpenFiles(
        reserved + sizing.fds_per_worker_endpoint * 3,
        shard_count,
        shard_engine_thread_count,
    ));
    // Never below one worker, and never above the cap however many descriptors there are.
    try std.testing.expectEqual(@as(usize, 1), sizing.maxWorkersForOpenFiles(
        reserved + sizing.fds_per_worker_endpoint,
        shard_count,
        shard_engine_thread_count,
    ));
    try std.testing.expectEqual(@as(usize, 1), sizing.maxWorkersForOpenFiles(0, shard_count, shard_engine_thread_count));
    try std.testing.expectEqual(sizing.workers_max, sizing.maxWorkersForOpenFiles(
        std.math.maxInt(u32),
        shard_count,
        shard_engine_thread_count,
    ));
}

test "the shard clamp trims the default count until the worker floor fits" {
    const threads = sizing.EngineThreadCounts.defaults().total();
    // A generous open-file limit never clamps.
    try std.testing.expectEqual(@as(usize, 8), sizing.clampShardsToWorkerFloor(8, threads, 65536, 16));
    // A tight one walks the default down, never below 2 shards.
    try std.testing.expectEqual(@as(usize, 2), sizing.clampShardsToWorkerFloor(8, threads, 256, 16));
    // A looser limit never yields fewer shards.
    var previous: usize = 0;
    var open_files: usize = 256;
    while (open_files <= 8192) : (open_files += 256) {
        const clamped = sizing.clampShardsToWorkerFloor(8, threads, open_files, 16);
        try std.testing.expect(clamped >= previous);
        previous = clamped;
    }
}

test "the gateway's open-file limit never exceeds its cap or the inherited hard limit" {
    const inherited = try std.posix.getrlimit(.NOFILE);
    const open_files = try sizing.openFilesLimit();
    try std.testing.expect(open_files <= limits.process.EGRESS_GATEWAY_OPEN_FILES_MAX);
    try std.testing.expect(open_files <= inherited.max);
}

test "a plan computed twice in one environment is the same plan" {
    const first = try sizing.Plan.compute();
    const second = try sizing.Plan.compute();
    try std.testing.expectEqual(first.shard_count, second.shard_count);
    try std.testing.expectEqual(first.engine_threads.h2_connectors, second.engine_threads.h2_connectors);
    try std.testing.expectEqual(first.workers_max, second.workers_max);
    try std.testing.expect(first.shard_count >= 1);
    try std.testing.expect(first.shard_count <= gateway.shard.default_max_shards);
    try std.testing.expect(first.workers_max >= 1);
    try std.testing.expect(first.workers_max <= sizing.workers_max);
}
