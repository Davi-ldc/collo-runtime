//! How large the egress gateway is: how many shards it runs and how many worker sessions it
//! holds at once. Nothing configures these numbers. Only the gateway computes its `Plan`
//! (`runtime/root.zig`), from the CPU affinity, the cgroup's CPU quota and the hard open-file limit
//! it inherits from the server, before its sandbox hides `/proc` and `/sys`, and the sandbox applies
//! the plan's open-file limit (`sandbox.zig`). The server reads only `sessions_max` here, the most
//! sessions any gateway holds.
//!
//! Open files are the one resource the plan divides: an attach whose descriptors the kernel
//! cannot install fails the control receive, and the gateway ends on a control error. Each session
//! keeps `ipc.egress_shared.gateway_held_fd_count` descriptors once its endpoint is mapped, so the
//! plan lowers the session cap to what the open-file limit holds beside the fixed reserves. Memory
//! needs no plan: each shard allocates through a budgeted allocator, pooled uploads through
//! another (`containment.zig`), and a session's records are bounded by its caps
//! (`sessions.zig`), so the address space is left unlimited. An attach that still fails to map is
//! refused alone (`runtime/control_flow.zig`).
//!
//! The file imports only the standard library, `collo_ipc` and `collo_limits`, because the server
//! compiles it.

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

const process_limits = limits.process;

/// Sessions one gateway may ever hold: one per pooled worker of every worker definition, the
/// most workers a server holds at once. A definition without a network grant attaches no session,
/// so this is an upper bound.
pub const sessions_max: usize = limits.server.worker_definitions_max * limits.pool.pool_workers_max;

/// The most shards a gateway runs.
pub const shards_max: usize = 8;

/// Descriptors kept out of the session budget for everything else the gateway opens: the control
/// socket, the readiness ring, the trust store and resolver files, outbound sockets beyond the
/// shards' estimates, plus the descriptors of one attach in flight, since the server sends the
/// next attach only after the ack. An outbound socket that finds the limit full fails its fetch.
pub const reserved_gateway_fds: usize = 128 + ipc.egress_shared.shared_fd_count;
pub const shard_base_fd_budget: usize = 16;
pub const per_engine_thread_fd_budget: usize = 8;
/// Threads of one shard's engine: the owner thread, which runs every dial, stream and exchange of
/// the shard, and the DNS cache's two resolver threads (`egress/client/engine/root.zig`).
pub const engine_threads_per_shard: usize = 3;
/// The default shard count leaves room for at least one session per core, and never for fewer
/// than this many sessions.
pub const sessions_floor_min: usize = 16;

pub const Plan = struct {
    shard_count: usize,
    /// Sessions the gateway holds at once: at least 1, at most `sessions_max`.
    sessions_max: usize,
    /// The open-file limit the sandbox applies (`openFilesLimit`).
    open_files: u64,

    /// The plan for the calling process's environment. Call it before the gateway's sandbox,
    /// which hides the cgroup files the CPU count reads. Fails when the open-file limit cannot be
    /// read.
    pub fn compute() !Plan {
        return fromEnvironment(.{
            .open_files = try openFilesLimit(),
            .cpus = effectiveCpuCount(),
        });
    }

    /// The plan for the environment `inputs` describes; `compute` reads it from the process.
    pub fn fromEnvironment(inputs: Inputs) Plan {
        const open_files: usize = std.math.cast(usize, inputs.open_files) orelse std.math.maxInt(usize);
        const shard_count = clampShardsToSessionFloor(
            defaultShardCountForCpus(inputs.cpus),
            open_files,
            ipc.egress_shared.gateway_held_fd_count,
            inputs.cpus,
        );
        std.debug.assert(shard_count >= 1);
        std.debug.assert(shard_count <= shards_max);
        return .{
            .shard_count = shard_count,
            .sessions_max = sessionsForOpenFiles(
                open_files,
                shard_count,
                ipc.egress_shared.gateway_held_fd_count,
            ),
            .open_files = inputs.open_files,
        };
    }

    /// What `fromEnvironment` reads.
    pub const Inputs = struct {
        open_files: u64,
        /// CPUs the gateway may run on: affinity bounded by the cgroup's quota.
        cpus: usize,
    };
};

/// Half the cores, at least 2 and at most `shards_max`, and 1 on one core. Each shard's owner
/// thread runs its fetches one event at a time, so more shards spread them over more cores, and
/// the cap bounds the per-shard thread, ring and descriptor cost; `Plan.fromEnvironment` also
/// lowers the default to fit the open-file budget it shares with worker sessions.
pub fn defaultShardCountForCpus(cpus: usize) usize {
    if (cpus <= 1)
        return 1;
    return @max(@as(usize, 2), @min(cpus / 2, shards_max));
}

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
    open_files: usize,
    fds_per_session: usize,
    cpus: usize,
) usize {
    const sessions_floor = @max(cpus, sessions_floor_min);
    var shards = shards_in;
    while (shards > 2) : (shards -= 1) {
        if (sessionsForOpenFiles(open_files, shards, fds_per_session) >= sessions_floor)
            break;
    }
    return shards;
}

/// Sessions of `fds_per_session` descriptors that fit in `open_files` next to `shard_count`
/// shards: at least 1, at most `sessions_max`.
pub fn sessionsForOpenFiles(open_files: usize, shard_count: usize, fds_per_session: usize) usize {
    std.debug.assert(fds_per_session >= 1);
    const reserved = reserved_gateway_fds + shard_count * shard_fd_budget;
    if (open_files <= reserved + fds_per_session)
        return 1;
    return @min(sessions_max, (open_files - reserved) / fds_per_session);
}

/// Descriptors one shard holds.
pub const shard_fd_budget: usize = shard_base_fd_budget + per_engine_thread_fd_budget * engine_threads_per_shard;

/// Affinity-visible CPUs bounded by this process's cgroup v2 `cpu.max` quota: a gateway limited
/// to 4 cores on a 64-cpu machine must size for 4, where affinity alone reports 64. Any read or
/// parse failure falls back to the affinity count.
fn effectiveCpuCount() usize {
    const affinity = std.Thread.getCpuCount() catch 1;
    const quota_cores = ownCgroupCpuQuotaCores() orelse return affinity;
    return @max(@as(usize, 1), @min(affinity, quota_cores));
}

fn ownCgroupCpuQuotaCores() ?usize {
    var path_buffer: [4096]u8 = undefined;
    const cgroup_path = ownCgroupV2Path(&path_buffer) orelse return null;
    return cgroupCpuQuotaCoresForPath(cgroup_path);
}

/// This process's cgroup v2 path: the "0::<path>" line of /proc/self/cgroup.
fn ownCgroupV2Path(buffer: []u8) ?[]const u8 {
    var file_buffer: [4096]u8 = undefined;
    const contents = std.fs.cwd().readFile("/proc/self/cgroup", &file_buffer) catch return null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::"))
            continue;
        const path = line["0::".len..];
        if (path.len == 0 or path.len > buffer.len)
            return null;
        @memcpy(buffer[0..path.len], path);
        return buffer[0..path.len];
    }
    return null;
}

/// Tightest `cpu.max` quota across the cgroup and its ancestors, in whole cores (rounded up).
/// null means no quota anywhere ("max" or unreadable). Each pass drops one path component, so at
/// most one pass per component of `cgroup_path` plus the root runs.
fn cgroupCpuQuotaCoresForPath(cgroup_path: []const u8) ?usize {
    var tightest: ?usize = null;
    var remaining = cgroup_path;
    while (true) {
        var file_path_buffer: [4096 + 32]u8 = undefined;
        const file_path = std.fmt.bufPrint(
            &file_path_buffer,
            "/sys/fs/cgroup{s}/cpu.max",
            .{remaining},
        ) catch return tightest;
        var contents_buffer: [128]u8 = undefined;
        if (std.fs.cwd().readFile(file_path, &contents_buffer)) |contents| {
            if (parseCpuMaxCores(contents)) |cores|
                tightest = if (tightest) |current| @min(current, cores) else cores;
        } else |_| {}
        if (remaining.len == 0)
            return tightest;
        const cut = std.mem.lastIndexOfScalar(u8, remaining, '/') orelse return tightest;
        remaining = remaining[0..cut];
    }
}

/// Parses a cgroup v2 `cpu.max` file ("max <period>" or "<quota_us> <period_us>") into whole
/// cores, rounding up; null when unlimited or malformed.
pub fn parseCpuMaxCores(contents: []const u8) ?usize {
    var parts = std.mem.tokenizeAny(u8, contents, " \t\r\n");
    const quota_text = parts.next() orelse return null;
    if (std.mem.eql(u8, quota_text, "max"))
        return null;
    const quota_us = std.fmt.parseUnsigned(u64, quota_text, 10) catch return null;
    const period_text = parts.next() orelse return null;
    const period_us = std.fmt.parseUnsigned(u64, period_text, 10) catch return null;
    if (quota_us == 0 or period_us == 0)
        return null;
    return @intCast((quota_us + period_us - 1) / period_us);
}

comptime {
    // At its own open-file cap a gateway with the most shards still takes every session the
    // server can hold, so the plan lowers the session cap only under a lower inherited limit.
    std.debug.assert(sessionsForOpenFiles(
        process_limits.EGRESS_GATEWAY_OPEN_FILES_MAX,
        shards_max,
        ipc.egress_shared.gateway_held_fd_count,
    ) == sessions_max);
}
