//! How large the egress gateway is: how many shards it runs, how many engine threads each shard
//! has, how many worker sessions it holds at once, and the open files and address space all of
//! that takes. Nothing configures these numbers. Only the gateway computes its `Plan`
//! (`runtime/root.zig`), from the cgroup, CPU affinity, hard open-file limit and
//! `vm.max_map_count` it inherits from the server, before its sandbox hides `/proc`, and the
//! sandbox applies the plan's open-file and address-space limits (`sandbox.zig`). The server
//! reads only `sessions_max` here, the most sessions any gateway holds, which bounds the session
//! losses its launcher queues (`lost_sessions_max` in `server/supervisor/launcher.zig`).
//!
//! What one session costs the gateway is its `SessionFootprint`, taken from the code that decides
//! it (`common/ipc/egress_shared/endpoint.zig`): the descriptors a mapped endpoint keeps, its
//! mappings and the bytes they map. The demand is `sessions_max`, one session per pooled worker of
//! every definition the server can hold. The plan lowers it to what the open-file limit and
//! `vm.max_map_count` hold beside the fixed reserves, so an attach past what the process can map
//! is refused before it is tried, and it derives the address-space limit from the same terms:
//! every admitted session's mapped bytes, the shards' memory budgets, the pooled-upload budget,
//! every thread's stack and a reserve for the rest of the process. That limit is a backstop: the
//! budgets bound the memory a gateway spends, and it catches what grows outside them. An attach
//! that still fails to map is refused alone (`runtime/control_flow.zig`).

const std = @import("std");
const egress_client = @import("collo_egress_client");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

const engine_mod = @import("engine.zig");
const sessions_mod = @import("sessions.zig");
const shard_mod = @import("shard.zig");
const supervisor_limits = @import("supervisor_limits.zig");

const process_limits = limits.process;

/// Sessions one gateway may ever hold: one per pooled worker of every worker definition, the
/// most workers a server holds at once. A definition without a network grant attaches no session,
/// so this is an upper bound.
pub const sessions_max: usize = limits.server.worker_definitions_max * limits.pool.pool_workers_max;

/// Descriptors kept out of the session budget for everything else the gateway opens: the control
/// socket, the readiness ring, the trust store and resolver files, outbound sockets beyond the
/// shards' estimates, plus the descriptors of one attach in flight, since the server sends the
/// next attach only after the ack. An outbound socket that finds the limit full fails its fetch.
pub const reserved_gateway_fds: usize = 128 + ipc.egress_shared.shared_fd_count;
pub const shard_base_fd_budget: usize = 16;
pub const per_engine_thread_fd_budget: usize = 8;
/// The default shard count leaves room for at least one session per core, and never for fewer
/// than this many sessions.
pub const sessions_floor_min: usize = 16;

/// Mappings the gateway holds besides its sessions: the binary and its libraries, the threads'
/// stacks and guard pages, the io_uring rings, and the heap's own mappings, which a shard's budget
/// bounds in bytes but not in count. The kernel merges adjacent anonymous mappings, so this covers
/// them with room to spare, at a sixteenth of the kernel's default `vm.max_map_count`.
pub const reserved_mappings: usize = 4096;

/// Address space the gateway reserves besides its sessions, its budgets and its threads' stacks:
/// the binary and its libraries, the main thread's stack, the rings, the decoded policy table and
/// the loop thread's own heap of session records, routes and budgets.
pub const reserved_address_space_bytes: u64 = 1024 * 1024 * 1024;

/// What one attached session costs the gateway once its endpoint is mapped.
pub const SessionFootprint = struct {
    /// Descriptors the mapped endpoint keeps open.
    fds: usize,
    /// Memory mappings the endpoint holds.
    mappings: usize,
    /// Bytes those mappings span.
    mapped_bytes: u64,
    /// The session's record on the loop thread's heap: its token budgets (`budgets.per_session_max`
    /// of them), its body-pool slot ledger and its strike window.
    record_bytes: u64,

    /// The footprint of a gateway endpoint on pages of `page_size` bytes.
    pub fn ofGatewayEndpoint(page_size: usize) SessionFootprint {
        return .{
            .fds = ipc.egress_shared.gateway_held_fd_count,
            .mappings = ipc.egress_shared.gateway_mapping_count,
            .mapped_bytes = ipc.egress_shared.gatewayMappedBytes(page_size),
            .record_bytes = @sizeOf(sessions_mod.Worker),
        };
    }

    /// The address space one session takes.
    pub fn bytes(self: SessionFootprint) u64 {
        return self.mapped_bytes + self.record_bytes;
    }
};

pub const Plan = struct {
    shard_count: usize,
    engine_threads: EngineThreadCounts,
    /// Sessions the gateway holds at once: at least 1, at most `sessions_max`.
    sessions_max: usize,
    /// The open-file limit the sandbox applies (`openFilesLimit`).
    open_files: u64,
    /// The address-space limit the sandbox applies (`addressSpaceBytes`).
    address_space_bytes: u64,

    /// The plan for the calling process's environment. Call it before the gateway's sandbox,
    /// which hides the cgroup files the CPU count reads and `vm.max_map_count`. Fails when the
    /// open-file limit or `/proc/sys/vm/max_map_count` cannot be read.
    pub fn compute() !Plan {
        const open_files = try openFilesLimit();
        return fromEnvironment(.{
            .open_files = open_files,
            .max_map_count = try readMaxMapCount(),
            .cpus = std.Thread.getCpuCount() catch 1,
            .default_shards = shard_mod.defaultShardCount(),
            .page_size = std.heap.pageSize(),
        });
    }

    /// The plan for the environment `inputs` describes; `compute` reads it from the process.
    pub fn fromEnvironment(inputs: Inputs) Plan {
        const footprint = SessionFootprint.ofGatewayEndpoint(inputs.page_size);
        const engine_threads = EngineThreadCounts.defaults();
        const open_files: usize = std.math.cast(usize, inputs.open_files) orelse std.math.maxInt(usize);
        const shard_count = clampShardsToSessionFloor(
            inputs.default_shards,
            engine_threads.total(),
            open_files,
            footprint.fds,
            inputs.cpus,
        );
        std.debug.assert(shard_count >= 1);
        std.debug.assert(shard_count <= shard_mod.default_max_shards);
        const sessions = @min(
            sessionsForOpenFiles(open_files, shard_count, engine_threads.total(), footprint.fds),
            sessionsForMappings(inputs.max_map_count, footprint.mappings),
        );
        return .{
            .shard_count = shard_count,
            .engine_threads = engine_threads,
            .sessions_max = sessions,
            .open_files = inputs.open_files,
            .address_space_bytes = addressSpaceBytes(sessions, footprint, shard_count, engine_threads),
        };
    }

    /// What `fromEnvironment` reads.
    pub const Inputs = struct {
        open_files: u64,
        max_map_count: usize,
        cpus: usize,
        default_shards: usize,
        page_size: usize,
    };
};

/// Threads of one shard: the engine's connector pool, the owner thread that runs both protocols,
/// and its DNS cache's resolver threads.
pub const EngineThreadCounts = struct {
    h2_connectors: usize,
    resolvers: usize,

    pub fn defaults() EngineThreadCounts {
        const config = engine_mod.Config{};
        const dns_config = egress_client.transport.DnsCacheConfig{};
        return .{
            .h2_connectors = config.h2_connector_count,
            .resolvers = dns_config.resolver_worker_count,
        };
    }

    /// The engine threads, owner included, which the open-file estimate charges.
    pub fn total(self: EngineThreadCounts) usize {
        return self.h2_connectors + 1;
    }

    /// The stacks the shard's threads reserve.
    pub fn stackBytes(self: EngineThreadCounts) u64 {
        const engine_stacks: u64 = @as(u64, self.total()) * egress_client.engine.thread_stack_bytes;
        const resolver_stacks: u64 = @as(u64, self.resolvers) * egress_client.dns_cache.resolver_thread_stack_bytes;
        return engine_stacks + resolver_stacks;
    }
};

/// The open-file limit the gateway runs with: `EGRESS_GATEWAY_OPEN_FILES_MAX`, or the hard limit
/// the calling process holds when that is lower. The gateway inherits the server's hard limit, and
/// `sandbox.zig` sets the gateway's soft and hard limits to it.
pub fn openFilesLimit() !u64 {
    const inherited = try std.posix.getrlimit(.NOFILE);
    return @min(process_limits.EGRESS_GATEWAY_OPEN_FILES_MAX, inherited.max);
}

/// Lowers `shards_in` until at least `max(cpus, sessions_floor_min)` sessions of `fds_per_session`
/// descriptors fit in `open_files`, but never below 2 shards.
pub fn clampShardsToSessionFloor(
    shards_in: usize,
    shard_engine_thread_count: usize,
    open_files: usize,
    fds_per_session: usize,
    cpus: usize,
) usize {
    const sessions_floor = @max(cpus, sessions_floor_min);
    var shards = shards_in;
    while (shards > 2) : (shards -= 1) {
        if (sessionsForOpenFiles(open_files, shards, shard_engine_thread_count, fds_per_session) >= sessions_floor)
            break;
    }
    return shards;
}

/// Sessions of `fds_per_session` descriptors that fit in `open_files` next to `shard_count`
/// shards of `shard_engine_thread_count` engine threads each: at least 1, at most `sessions_max`.
pub fn sessionsForOpenFiles(
    open_files: usize,
    shard_count: usize,
    shard_engine_thread_count: usize,
    fds_per_session: usize,
) usize {
    std.debug.assert(fds_per_session >= 1);
    const reserved = reserved_gateway_fds + shard_count * estimatedShardFdBudget(shard_engine_thread_count);
    if (open_files <= reserved + fds_per_session)
        return 1;
    return @min(sessions_max, (open_files - reserved) / fds_per_session);
}

/// Sessions of `mappings_per_session` mappings that fit under `max_map_count` beside
/// `reserved_mappings`: at least 1, at most `sessions_max`.
pub fn sessionsForMappings(max_map_count: usize, mappings_per_session: usize) usize {
    std.debug.assert(mappings_per_session >= 1);
    if (max_map_count <= reserved_mappings + mappings_per_session)
        return 1;
    return @min(sessions_max, (max_map_count - reserved_mappings) / mappings_per_session);
}

/// Descriptors one shard holds with `engine_thread_count` engine threads
/// (`EngineThreadCounts.total`).
pub fn estimatedShardFdBudget(engine_thread_count: usize) usize {
    return shard_base_fd_budget + per_engine_thread_fd_budget * engine_thread_count;
}

/// The address space a gateway of `sessions` sessions and `shard_count` shards reserves at most:
/// the sessions' mappings, each shard's memory budget, the pooled-upload budget, every shard's
/// thread stacks and `reserved_address_space_bytes`, never above
/// `EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX`.
pub fn addressSpaceBytes(
    sessions: usize,
    footprint: SessionFootprint,
    shard_count: usize,
    engine_threads: EngineThreadCounts,
) u64 {
    const session_bytes = @as(u64, sessions) * footprint.bytes();
    const shard_bytes = @as(u64, shard_count) *
        (supervisor_limits.shard_memory.budget_bytes + engine_threads.stackBytes());
    const total = session_bytes + shard_bytes + supervisor_limits.upload_memory.budget_bytes +
        reserved_address_space_bytes;
    return @min(total, process_limits.EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX);
}

/// `vm.max_map_count`, the most mappings one process may hold.
fn readMaxMapCount() !usize {
    var buffer: [32]u8 = undefined;
    const text = try std.fs.cwd().readFile("/proc/sys/vm/max_map_count", &buffer);
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    return std.fmt.parseUnsigned(usize, trimmed, 10) catch error.InvalidMaxMapCount;
}

comptime {
    // At its own open-file cap a gateway with the most shards still takes every session the
    // server can hold, and on 4 KiB pages its address space at that size stays below the
    // backstop, so the backstop never lowers what the plan admits. `vm.max_map_count` may still
    // cap the sessions (at the kernel's default of 65530, near 3,800).
    const footprint = SessionFootprint.ofGatewayEndpoint(4096);
    const threads = EngineThreadCounts.defaults();
    std.debug.assert(sessionsForOpenFiles(
        process_limits.EGRESS_GATEWAY_OPEN_FILES_MAX,
        shard_mod.default_max_shards,
        threads.total(),
        footprint.fds,
    ) == sessions_max);
    const session_bytes = @as(u64, sessions_max) * footprint.bytes();
    const shard_bytes = @as(u64, shard_mod.default_max_shards) *
        (supervisor_limits.shard_memory.budget_bytes + threads.stackBytes());
    std.debug.assert(session_bytes + shard_bytes + supervisor_limits.upload_memory.budget_bytes +
        reserved_address_space_bytes <= process_limits.EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX);
}
