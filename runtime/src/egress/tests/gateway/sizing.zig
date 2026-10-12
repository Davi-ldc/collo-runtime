//! Tests of the gateway's sizing (`egress/gateway/sizing.zig`): the session cap against the
//! open-file limit, charged the descriptors a mapped endpoint keeps, and against
//! `vm.max_map_count`, charged its mappings; the address space a plan derives from what it admits;
//! the clamp of the default shard count; and a plan that two processes in one environment compute
//! alike. The plan's use at boot is covered by local-e2e. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

const loop_support = @import("support/loop.zig");

const sizing = gateway.sizing;
const supervisor_limits = gateway.supervisor_limits;

/// A page size the plans below are computed for; the plan only multiplies by it.
const page_size: usize = 4096;
/// A `vm.max_map_count` no session count reaches: the kernel's largest.
const unbounded_map_count: usize = std.math.maxInt(i32);

test "the session cap charges each session the descriptors its endpoint keeps once mapped" {
    const footprint = sizing.SessionFootprint.ofGatewayEndpoint(page_size);
    try std.testing.expectEqual(ipc.egress_shared.gateway_held_fd_count, footprint.fds);
    const threads = sizing.EngineThreadCounts.defaults().total();
    const shard_count: usize = 2;
    const reserved = sizing.reserved_gateway_fds + shard_count * sizing.estimatedShardFdBudget(threads);

    const plan = sizing.Plan.fromEnvironment(.{
        .open_files = reserved + 3 * ipc.egress_shared.gateway_held_fd_count,
        .max_map_count = unbounded_map_count,
        .cpus = 1,
        .default_shards = shard_count,
        .page_size = page_size,
    });
    try std.testing.expectEqual(shard_count, plan.shard_count);
    try std.testing.expectEqual(@as(usize, 3), plan.sessions_max);
    try std.testing.expectEqual(@as(u64, reserved + 3 * ipc.egress_shared.gateway_held_fd_count), plan.open_files);
}

test "a mapped gateway endpoint keeps exactly the descriptors the plan charges" {
    var session = try loop_support.createSession();
    defer session.deinit();
    const before = try openDescriptorCount();
    var gateway_raw = try loop_support.dupEgressRawFds(session.rawForGateway());
    var endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer endpoint.deinit();
    const after = try openDescriptorCount();

    const charged = sizing.SessionFootprint.ofGatewayEndpoint(std.heap.pageSize()).fds;
    try std.testing.expectEqual(charged, endpoint.heldFdCount());
    // The mapping closed every other descriptor the attach carried.
    try std.testing.expectEqual(charged, after - before);
}

test "a plan admits no more sessions than vm.max_map_count can map" {
    const mappings = ipc.egress_shared.gateway_mapping_count;
    try std.testing.expectEqual(mappings, sizing.SessionFootprint.ofGatewayEndpoint(page_size).mappings);
    const inputs = sizing.Plan.Inputs{
        .open_files = limits.process.EGRESS_GATEWAY_OPEN_FILES_MAX,
        .max_map_count = sizing.reserved_mappings + 7 * mappings,
        .cpus = 1,
        .default_shards = 2,
        .page_size = page_size,
    };
    try std.testing.expectEqual(@as(usize, 7), sizing.Plan.fromEnvironment(inputs).sessions_max);

    var one_short = inputs;
    one_short.max_map_count -= 1;
    try std.testing.expectEqual(@as(usize, 6), sizing.Plan.fromEnvironment(one_short).sessions_max);

    // Never below one session, and never above the cap however many mappings there are.
    var none = inputs;
    none.max_map_count = 0;
    try std.testing.expectEqual(@as(usize, 1), sizing.Plan.fromEnvironment(none).sessions_max);
    var unbounded = inputs;
    unbounded.max_map_count = unbounded_map_count;
    try std.testing.expectEqual(sizing.sessions_max, sizing.Plan.fromEnvironment(unbounded).sessions_max);
}

test "a plan's address space holds every session it admits beside its shards, stacks and upload budget" {
    const plan = sizing.Plan.fromEnvironment(.{
        .open_files = limits.process.EGRESS_GATEWAY_OPEN_FILES_MAX,
        .max_map_count = 65530,
        .cpus = 4,
        .default_shards = 4,
        .page_size = page_size,
    });
    const footprint = sizing.SessionFootprint.ofGatewayEndpoint(page_size);
    const session_bytes = @as(u64, plan.sessions_max) * footprint.bytes();
    const shard_bytes = @as(u64, plan.shard_count) *
        (supervisor_limits.shard_memory.budget_bytes + plan.engine_threads.stackBytes());
    const expected = session_bytes + shard_bytes + supervisor_limits.upload_memory.budget_bytes +
        sizing.reserved_address_space_bytes;
    try std.testing.expectEqual(expected, plan.address_space_bytes);
    try std.testing.expect(plan.address_space_bytes <= limits.process.EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX);

    // Each session admitted past these grows the limit by its mapped bytes
    // and its record.
    var smaller_inputs = sizing.Plan.Inputs{
        .open_files = limits.process.EGRESS_GATEWAY_OPEN_FILES_MAX,
        .max_map_count = sizing.reserved_mappings + footprint.mappings * (plan.sessions_max - 1),
        .cpus = 4,
        .default_shards = 4,
        .page_size = page_size,
    };
    const smaller = sizing.Plan.fromEnvironment(smaller_inputs);
    try std.testing.expectEqual(plan.sessions_max - 1, smaller.sessions_max);
    try std.testing.expectEqual(plan.address_space_bytes - footprint.bytes(), smaller.address_space_bytes);
    smaller_inputs.max_map_count = 0;
    try std.testing.expect(sizing.Plan.fromEnvironment(smaller_inputs).address_space_bytes < smaller.address_space_bytes);
}

test "the session cap never falls below one session or rises above sessions_max" {
    const fds = sizing.SessionFootprint.ofGatewayEndpoint(page_size).fds;
    const shard_count: usize = 2;
    const threads = sizing.EngineThreadCounts.defaults().total();
    const reserved = sizing.reserved_gateway_fds + shard_count * sizing.estimatedShardFdBudget(threads);
    try std.testing.expectEqual(@as(usize, 1), sizing.sessionsForOpenFiles(reserved + fds, shard_count, threads, fds));
    try std.testing.expectEqual(@as(usize, 1), sizing.sessionsForOpenFiles(0, shard_count, threads, fds));
    try std.testing.expectEqual(sizing.sessions_max, sizing.sessionsForOpenFiles(
        std.math.maxInt(u32),
        shard_count,
        threads,
        fds,
    ));
    // One session per pooled worker of every definition a server can hold.
    try std.testing.expectEqual(
        limits.server.worker_definitions_max * limits.pool.pool_workers_max,
        sizing.sessions_max,
    );
}

test "the shard clamp trims the default count until the session floor fits" {
    const threads = sizing.EngineThreadCounts.defaults().total();
    const fds = sizing.SessionFootprint.ofGatewayEndpoint(page_size).fds;
    // A generous open-file limit never clamps.
    try std.testing.expectEqual(@as(usize, 8), sizing.clampShardsToSessionFloor(8, threads, 65536, fds, 1));
    // A tight one walks the default down, never below 2 shards.
    try std.testing.expectEqual(@as(usize, 2), sizing.clampShardsToSessionFloor(8, threads, 256, fds, 1));
    // A looser limit never yields fewer shards.
    var previous: usize = 0;
    var open_files: usize = 256;
    while (open_files <= 8192) : (open_files += 256) {
        const clamped = sizing.clampShardsToSessionFloor(8, threads, open_files, fds, 1);
        try std.testing.expect(clamped >= previous);
        previous = clamped;
    }
    // The floor is a session per core once the cores outnumber `sessions_floor_min`: a limit
    // that fits that floor beside 8 shards keeps them, one descriptor less does not.
    const cpus = 4 * sizing.sessions_floor_min;
    const reserved = sizing.reserved_gateway_fds + 8 * sizing.estimatedShardFdBudget(threads);
    const fits = reserved + cpus * fds;
    try std.testing.expectEqual(@as(usize, 8), sizing.clampShardsToSessionFloor(8, threads, fits, fds, cpus));
    try std.testing.expect(sizing.clampShardsToSessionFloor(8, threads, fits - 1, fds, cpus) < 8);
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
    try std.testing.expectEqual(first.engine_threads.resolvers, second.engine_threads.resolvers);
    try std.testing.expectEqual(first.sessions_max, second.sessions_max);
    try std.testing.expectEqual(first.open_files, second.open_files);
    try std.testing.expectEqual(first.address_space_bytes, second.address_space_bytes);
    try std.testing.expect(first.shard_count >= 1);
    try std.testing.expect(first.shard_count <= gateway.shard.default_max_shards);
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
