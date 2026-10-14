//! Tests of the gateway's sizing (`egress/gateway/sizing.zig`): the default shard count from the
//! CPUs, the parse of cgroup v2 `cpu.max` that bounds them, the session cap against the open-file
//! limit, charged the descriptors a mapped endpoint keeps, the clamp of the shard count to the
//! session floor, the open-file limit the gateway takes, and a plan that two processes in one
//! environment compute alike. The plan's use at boot is covered by local-e2e and the sandbox's
//! limits in `sandbox.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

const gateway_support = @import("support/gateway.zig");

const sizing = gateway.sizing;

const fds_per_session = ipc.egress_shared.gateway_held_fd_count;

test "the default shard count is half the cores, at least 2 and at most shards_max" {
    try std.testing.expectEqual(@as(usize, 8), sizing.shards_max);
    try std.testing.expectEqual(@as(usize, 1), sizing.defaultShardCountForCpus(0));
    try std.testing.expectEqual(@as(usize, 1), sizing.defaultShardCountForCpus(1));
    try std.testing.expectEqual(@as(usize, 2), sizing.defaultShardCountForCpus(2));
    try std.testing.expectEqual(@as(usize, 2), sizing.defaultShardCountForCpus(3));
    try std.testing.expectEqual(@as(usize, 2), sizing.defaultShardCountForCpus(4));
    try std.testing.expectEqual(@as(usize, 4), sizing.defaultShardCountForCpus(8));
    try std.testing.expectEqual(@as(usize, 8), sizing.defaultShardCountForCpus(16));
    try std.testing.expectEqual(@as(usize, 8), sizing.defaultShardCountForCpus(22));
    try std.testing.expectEqual(@as(usize, 8), sizing.defaultShardCountForCpus(64));
}

test "cpu.max parses quota and period into whole cores rounding up" {
    try std.testing.expectEqual(@as(?usize, 4), sizing.parseCpuMaxCores("400000 100000\n"));
    try std.testing.expectEqual(@as(?usize, 1), sizing.parseCpuMaxCores("50000 100000\n"));
    try std.testing.expectEqual(@as(?usize, 3), sizing.parseCpuMaxCores("250000 100000\n"));
    try std.testing.expectEqual(@as(?usize, 1), sizing.parseCpuMaxCores("100000 100000"));
}

test "cpu.max unlimited or malformed yields no quota" {
    try std.testing.expectEqual(@as(?usize, null), sizing.parseCpuMaxCores("max 100000\n"));
    try std.testing.expectEqual(@as(?usize, null), sizing.parseCpuMaxCores(""));
    try std.testing.expectEqual(@as(?usize, null), sizing.parseCpuMaxCores("garbage"));
    try std.testing.expectEqual(@as(?usize, null), sizing.parseCpuMaxCores("100000"));
    try std.testing.expectEqual(@as(?usize, null), sizing.parseCpuMaxCores("0 100000"));
    try std.testing.expectEqual(@as(?usize, null), sizing.parseCpuMaxCores("100000 0"));
}

test "the session cap charges each session the descriptors its endpoint keeps once mapped" {
    // Four CPUs give the default of two shards, which a session floor of 16 never clamps further.
    const shard_count: usize = 2;
    const reserved = sizing.reserved_gateway_fds + shard_count * sizing.shard_fd_budget;
    const open_files: u64 = reserved + 3 * fds_per_session;
    const plan = sizing.Plan.fromEnvironment(.{ .open_files = open_files, .cpus = 4 });
    try std.testing.expectEqual(shard_count, plan.shard_count);
    try std.testing.expectEqual(@as(usize, 3), plan.sessions_max);
    try std.testing.expectEqual(open_files, plan.open_files);

    // One descriptor short of the third session leaves two.
    const short = sizing.Plan.fromEnvironment(.{ .open_files = open_files - 1, .cpus = 4 });
    try std.testing.expectEqual(@as(usize, 2), short.sessions_max);
}

test "a plan at the gateway's own open-file cap takes every session the server can hold, on any CPU count" {
    for ([_]usize{ 1, 2, 4, 8, 16, 64 }) |cpus| {
        const plan = sizing.Plan.fromEnvironment(.{
            .open_files = limits.process.EGRESS_GATEWAY_OPEN_FILES_MAX,
            .cpus = cpus,
        });
        try std.testing.expectEqual(sizing.defaultShardCountForCpus(cpus), plan.shard_count);
        try std.testing.expectEqual(sizing.sessions_max, plan.sessions_max);
    }
}

test "a mapped gateway endpoint keeps exactly the descriptors the plan charges" {
    var session = try gateway_support.createSession();
    defer session.deinit();
    const before = try openDescriptorCount();
    var gateway_raw = try gateway_support.dupEgressRawFds(session.rawForGateway());
    var endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer endpoint.deinit();
    const after = try openDescriptorCount();

    try std.testing.expectEqual(fds_per_session, endpoint.heldFdCount());
    // The mapping closed every other descriptor the attach carried.
    try std.testing.expectEqual(fds_per_session, after - before);
}

test "the session cap never falls below one session or rises above sessions_max" {
    const shard_count: usize = 2;
    const reserved = sizing.reserved_gateway_fds + shard_count * sizing.shard_fd_budget;
    try std.testing.expectEqual(@as(usize, 1), sizing.sessionsForOpenFiles(reserved + fds_per_session, shard_count, fds_per_session));
    try std.testing.expectEqual(@as(usize, 1), sizing.sessionsForOpenFiles(0, shard_count, fds_per_session));
    try std.testing.expectEqual(
        sizing.sessions_max,
        sizing.sessionsForOpenFiles(std.math.maxInt(u32), shard_count, fds_per_session),
    );
    // One session per pooled worker of every definition a server can hold.
    try std.testing.expectEqual(
        limits.server.worker_definitions_max * limits.pool.pool_workers_max,
        sizing.sessions_max,
    );
    // An open-file limit below the reserves still plans one session rather than none.
    try std.testing.expectEqual(@as(usize, 1), sizing.Plan.fromEnvironment(.{ .open_files = 0, .cpus = 4 }).sessions_max);
}

test "the shard clamp trims the default count until the session floor fits" {
    // A generous open-file limit never clamps.
    try std.testing.expectEqual(@as(usize, 8), sizing.clampShardsToSessionFloor(8, 65536, fds_per_session, 1));
    // A tight one walks the default down, never below 2 shards.
    try std.testing.expectEqual(@as(usize, 2), sizing.clampShardsToSessionFloor(8, 256, fds_per_session, 1));
    // A looser limit never yields fewer shards.
    var previous: usize = 0;
    var open_files: usize = 256;
    while (open_files <= 8192) : (open_files += 256) {
        const clamped = sizing.clampShardsToSessionFloor(8, open_files, fds_per_session, 1);
        try std.testing.expect(clamped >= previous);
        previous = clamped;
    }
    // The floor is a session per core once the cores outnumber `sessions_floor_min`: a limit
    // that fits that floor beside 8 shards keeps them, one descriptor less does not.
    const cpus = 4 * sizing.sessions_floor_min;
    const reserved = sizing.reserved_gateway_fds + 8 * sizing.shard_fd_budget;
    const fits = reserved + cpus * fds_per_session;
    try std.testing.expectEqual(@as(usize, 8), sizing.clampShardsToSessionFloor(8, fits, fds_per_session, cpus));
    try std.testing.expect(sizing.clampShardsToSessionFloor(8, fits - 1, fds_per_session, cpus) < 8);
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
    try std.testing.expectEqual(first.sessions_max, second.sessions_max);
    try std.testing.expectEqual(first.open_files, second.open_files);
    try std.testing.expect(first.shard_count >= 1);
    try std.testing.expect(first.shard_count <= sizing.shards_max);
    try std.testing.expect(first.sessions_max >= 1);
    try std.testing.expect(first.sessions_max <= sizing.sessions_max);
}

/// The descriptors this process holds, counted in `/proc/self/fd`. The directory's own descriptor
/// is among them on every count.
fn openDescriptorCount() !usize {
    var descriptors = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer descriptors.close();
    var iterator = descriptors.iterate();
    var count: usize = 0;
    while (try iterator.next()) |_|
        count += 1;
    return count;
}
