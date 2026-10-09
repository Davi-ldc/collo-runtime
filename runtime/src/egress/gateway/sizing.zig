//! How large the egress gateway is: how many shards it runs, how many engine threads each shard
//! has, and how many worker endpoints it accepts. Nothing configures these numbers. Only the
//! gateway computes its `Plan` (`runtime/root.zig`), from the cgroup, CPU affinity and hard
//! open-file limit it inherits from the server, before its sandbox hides `/proc`, where the
//! cgroup's CPU quota is read. The server reads only `workers_max` here, which bounds the session
//! losses its launcher queues (`lost_sessions_max` in `server/supervisor/launcher.zig`).
//!
//! Each attach delivers `fds_per_worker_endpoint` descriptors, of which the gateway keeps the body
//! pool's data memfd, the two eventfds and the two liveness ends once it maps them
//! (`mapEndpointTakeForGateway` in `common/ipc/egress_shared/endpoint.zig`). The worker budget
//! charges every endpoint the full `fds_per_worker_endpoint`, and shard rings, engine threads and
//! outbound sockets draw on the same open-file limit, so that limit bounds both the worker cap
//! and the default shard count. The gateway's limit is `openFilesLimit`, which `sandbox.zig`
//! applies before the first thread starts.

const std = @import("std");
const ipc = @import("collo_ipc");
const process_limits = @import("collo_limits").process;

const engine_mod = @import("engine.zig");
const shard_mod = @import("shard.zig");

/// Worker endpoints one gateway accepts, however many its open-file limit would allow.
pub const workers_max: usize = 256;
pub const fds_per_worker_endpoint: usize = ipc.egress_shared.shared_fd_count;
/// Descriptors kept out of the worker budget for everything else the gateway opens, plus one
/// endpoint's worth of room for an attach in flight.
pub const reserved_gateway_fds: usize = 128 + fds_per_worker_endpoint;
pub const shard_base_fd_budget: usize = 16;
pub const per_engine_thread_fd_budget: usize = 8;
/// The default shard count leaves room for at least one worker per core, and never for fewer
/// than this many workers.
pub const workers_floor_min: usize = 16;

pub const Plan = struct {
    shard_count: usize,
    engine_threads: EngineThreadCounts,
    /// Worker endpoints the gateway accepts at once; at least 1, at most `workers_max`.
    workers_max: usize,

    /// The plan for the calling process's environment. Call it before the gateway's sandbox,
    /// which hides the cgroup files the CPU count reads.
    pub fn compute() !Plan {
        const open_files: usize = @intCast(try openFilesLimit());
        const engine_threads = EngineThreadCounts.defaults();
        const cpus = std.Thread.getCpuCount() catch 1;
        const shard_count = clampShardsToWorkerFloor(
            shard_mod.defaultShardCount(),
            engine_threads.total(),
            open_files,
            cpus,
        );
        std.debug.assert(shard_count >= 1);
        std.debug.assert(shard_count <= shard_mod.default_max_shards);
        return .{
            .shard_count = shard_count,
            .engine_threads = engine_threads,
            .workers_max = maxWorkersForOpenFiles(open_files, shard_count, engine_threads.total()),
        };
    }
};

/// Engine threads of one shard: the connector pool plus the owner thread that runs both
/// protocols.
pub const EngineThreadCounts = struct {
    h2_connectors: usize,

    pub fn defaults() EngineThreadCounts {
        const config = engine_mod.Config{};
        return .{ .h2_connectors = config.h2_connector_count };
    }

    pub fn total(self: EngineThreadCounts) usize {
        return self.h2_connectors + 1;
    }
};

/// The open-file limit the gateway runs with: `EGRESS_GATEWAY_OPEN_FILES_MAX`, or the hard limit
/// the calling process holds when that is lower. The gateway inherits the server's hard limit, and
/// `sandbox.zig` sets the gateway's soft and hard limits to it.
pub fn openFilesLimit() !u64 {
    const inherited = try std.posix.getrlimit(.NOFILE);
    return @min(process_limits.EGRESS_GATEWAY_OPEN_FILES_MAX, inherited.max);
}

/// Lowers `shards_in` until at least `max(cpus, workers_floor_min)` worker endpoints fit in
/// `open_files`, but never below 2 shards.
pub fn clampShardsToWorkerFloor(
    shards_in: usize,
    shard_engine_thread_count: usize,
    open_files: usize,
    cpus: usize,
) usize {
    const workers_floor = @max(cpus, workers_floor_min);
    var shards = shards_in;
    while (shards > 2) : (shards -= 1) {
        if (maxWorkersForOpenFiles(open_files, shards, shard_engine_thread_count) >= workers_floor)
            break;
    }
    return shards;
}

/// Worker endpoints that fit in `open_files` next to `shard_count` shards of
/// `shard_engine_thread_count` engine threads each: at least 1, at most `workers_max`.
pub fn maxWorkersForOpenFiles(
    open_files: usize,
    shard_count: usize,
    shard_engine_thread_count: usize,
) usize {
    const reserved = reserved_gateway_fds + shard_count * estimatedShardFdBudget(shard_engine_thread_count);
    if (open_files <= reserved + fds_per_worker_endpoint)
        return 1;
    return @min(workers_max, (open_files - reserved) / fds_per_worker_endpoint);
}

/// Descriptors one shard holds with `engine_thread_count` engine threads
/// (`EngineThreadCounts.total`).
pub fn estimatedShardFdBudget(engine_thread_count: usize) usize {
    return shard_base_fd_budget + per_engine_thread_fd_budget * engine_thread_count;
}

comptime {
    // At its own open-file cap, a gateway with the most shards still takes every worker.
    std.debug.assert(maxWorkersForOpenFiles(
        process_limits.EGRESS_GATEWAY_OPEN_FILES_MAX,
        shard_mod.default_max_shards,
        EngineThreadCounts.defaults().total(),
    ) == workers_max);
}
