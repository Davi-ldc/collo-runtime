//! The sandbox benchmark's controller: the `cold`, `memory`, `idle`,
//! `regions` and `all` modes of `sandbox-bench`, run outside every measured
//! cgroup. Each trial gets a fresh `collo-bench-*` scope from `wsl-config`
//! and a runtime daemon (`daemon.zig`) in the scope's `main` cgroup. The
//! controller drives the daemon over its stdin and stdout (`protocol.zig`),
//! sends it HTTP/2 requests through the loopback client and writes every
//! result to stdout as one JSON line, the stream `run.sh` validates. It
//! refuses to run unless built with ReleaseFast. Everything runs on one
//! thread, except the origin (`origin.zig`), which serves on a thread of its
//! own when the workload fetches.
//!
//! A sample is recorded only when it can be attributed. The controller checks
//! that it is outside the scope, that the server, the zygote and the gateway
//! are in `main` and every worker under `workers`, that worker identities do
//! not change between steps, and that no swap, memory pressure or OOM event
//! touched a measurement; any violation ends the run with an error. A scope is
//! removed only once its processes have exited, and cleanup kills nothing
//! outside it.

const std = @import("std");
const memory = @import("memory.zig");
const timing = @import("timing.zig");
const protocol = @import("protocol.zig");
const node = @import("node.zig");
const workload_mod = @import("workload.zig");
const Origin = @import("origin.zig").Origin;
const local_origin = @import("../local_origin.zig");
const process = @import("collo_os").process;
const build_options = @import("collo_bench_build_options");

const Workload = workload_mod.Workload;
const Exchange = workload_mod.Exchange;

pub const Mode = enum { cold, memory, all, idle, regions };
const sample_limit = 256;
const rounds_limit = 16;
const settle_ms_max = 60_000;
const idle_window_ms_default = 30_000;
const idle_window_ms_min = 1_000;
const idle_window_ms_max = 600_000;
/// The pause between an `idle` target's load and the start of its window.
/// A thread releases its allocator cache after
/// `thread_cache_idle_release_ns` (`common/limits/worker.zig`) without work,
/// and the libpas scavenger then needs its epoch delay and two empty passes
/// before it sleeps, so the window starts once every thread can be asleep.
const idle_settle_ms = 1_500;
/// Bounds each daemon reply and the daemon's exit after a shutdown.
const operation_timeout_ms = 30_000;
/// Bounds each blocking read or write of the HTTP client. The server answers
/// every request by its deadline, so a transport that waits longer than that
/// and this margin has failed.
const client_timeout_ms = node.request_timeout_ms + 5_000;
/// A resting snapshot needs this many consecutive samples, `stable_interval_ns`
/// apart, whose `memory.current` and every stat field each vary by at most
/// `stability_tolerance_bytes`.
const stable_samples = 5;
/// The most samples one snapshot may take; one that has not settled by then
/// fails the run.
const stable_attempts = 25;
const stable_interval_ns = 20 * std.time.ns_per_ms;
const stability_tolerance_bytes = 64 * 1024;
/// Workers present before the measured insertion; rounds rotate their order.
const populations = [_]u32{ 0, 1, 4, 16 };
/// The workers a memory trial measures: ones that have served no request
/// (`ready`), or ones that have each run the workload's load (`after_load`).
/// An `after_load` trial also samples its added worker at WorkerReady,
/// before that worker's load.
const MemoryPhase = enum { ready, after_load };
/// When a process set is read: `before` holds the existing population just
/// before the insertion, so per-process sums pair with the cgroup delta. A
/// `regions` trial reads its worker right after each step (`after_step`) and
/// again after the idle window (`after_idle`).
const Moment = enum { before, ready, after_load, after_step, after_idle };

const Settings = struct {
    workload: Workload,
    load: workload_mod.Load,
    network: node.Network,
    concurrency: u8,
    /// The origin the controller serves, when the workload fetches.
    origin: ?node.Origin,
    rounds: usize,
    samples: usize,
    /// Pause before every resting memory snapshot, so allocator scavengers can
    /// return memory freed by the last operation before the stability window.
    settle_ns: u64,
    /// How long an `idle` target is watched, and how long a `regions` worker
    /// rests before its second sample of each step.
    idle_window_ns: u64,
};

pub fn run(allocator: std.mem.Allocator, mode: Mode) !void {
    if (!std.mem.eql(u8, build_options.optimize_mode_name, "ReleaseFast")) {
        std.debug.print("microbench requires -Doptimize=ReleaseFast\n", .{});
        return error.BenchmarkRequiresReleaseFast;
    }
    const workload = try Workload.fromEnvironment();
    const load_requests: ?u32 = if (try optionalSetting("COLLO_BENCH_LOAD_REQUESTS", .{
        .default = 1,
        .maximum = workload_mod.load_requests_max,
    })) |count| @as(u32, @intCast(count)) else null;
    const network = try node.Network.fromEnvironment();
    if (workload.needsOrigin() and network == .none) return error.FetchWorkloadNeedsNetworkGrant;
    const settle_ms = try setting("COLLO_BENCH_SETTLE_MS", .{
        .default = 0,
        .minimum = 0,
        .maximum = settle_ms_max,
    });
    const idle_window_ms = try setting("COLLO_BENCH_IDLE_WINDOW_MS", .{
        .default = idle_window_ms_default,
        .minimum = idle_window_ms_min,
        .maximum = idle_window_ms_max,
    });
    var origin_server: Origin = undefined;
    var origin_running = false;
    defer if (origin_running) {
        _ = origin_server.stop();
    };
    if (workload.needsOrigin()) {
        try origin_server.start(try local_origin.routableLocalIpv4());
        origin_running = true;
    }
    const settings = Settings{
        .workload = workload,
        .load = try workload.load(load_requests),
        .network = network,
        .concurrency = try node.concurrencyFromEnvironment(),
        .origin = if (origin_running)
            .{ .address = origin_server.address, .port = origin_server.port }
        else
            null,
        .rounds = try setting("COLLO_BENCH_ROUNDS", .{ .default = 3, .maximum = rounds_limit }),
        .samples = try setting("COLLO_BENCH_SAMPLES", .{ .default = 32, .maximum = sample_limit }),
        .settle_ns = settle_ms * std.time.ns_per_ms,
        .idle_window_ns = idle_window_ms * std.time.ns_per_ms,
    };
    const executable = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    const tool = if (std.posix.getenv("COLLO_BENCH_WSL_CONFIG")) |override|
        if (override.len != 0) try allocator.dupe(u8, override) else return error.InvalidToolPath
    else
        try std.fs.path.join(allocator, &.{ std.fs.path.dirname(executable).?, "wsl-config" });
    defer allocator.free(tool);
    var origin_buffer: [node.Origin.text_bytes_max]u8 = undefined;
    const origin_text: ?[]const u8 = if (settings.origin) |origin|
        std.fmt.bufPrint(&origin_buffer, "{f}", .{origin}) catch unreachable
    else
        null;
    try emit(.{
        .schema = "collo.microbench.v1",
        .kind = "metadata",
        .mode = @tagName(mode),
        .workload = @tagName(settings.workload),
        .load_steps = settings.load.steps(),
        .load_requests_per_instance = settings.load.requestCount(),
        .network = @tagName(settings.network),
        .concurrency = settings.concurrency,
        .origin = origin_text,
        .rounds = settings.rounds,
        .samples_per_round = settings.samples,
        .settle_ms = settle_ms,
        .idle_settle_ms = idle_settle_ms,
        .idle_window_ms = idle_window_ms,
        .runtime_optimize = build_options.optimize_mode_name,
        .arch = build_options.target_arch_name,
        .clock = "CLOCK_MONOTONIC",
        .ingress = "loopback TLS+h2; established connection; /__collo/healthz preflight",
        .engine = "warm zygote; resident local code",
        .memory_scope = "dedicated runtime cgroup including server, zygote, gateway and workers",
        .memory_stat_accounting = "anon/file/kernel are categories; shmem is within file; " ++
            "pagetables/kernel_stack/slab are within kernel; use memory.current for totals",
        .region_accounting = "per process and memfd name; rss/pss/dirty are summed only with " ++
            "themselves; allocated counts each memfd once; shmem is charged to the first toucher",
        .stability_tolerance_bytes = stability_tolerance_bytes,
        .stability_window_samples = stable_samples,
        .memory_settle = "settle_ms pause before each resting snapshot, then the stability window",
        .memory_phase_comparison = "phase cohorts are independent; load_growth pairs the same target",
        .file_cache = "warm executable/library cache; preexisting external charges excluded",
        .swap = "disabled in measured subtree",
        .sampler_pid = std.os.linux.getpid(),
    });
    switch (mode) {
        .cold => try runCold(allocator, executable, tool, &settings),
        .memory => try runMemory(allocator, executable, tool, &settings),
        .all => {
            try runCold(allocator, executable, tool, &settings);
            try runMemory(allocator, executable, tool, &settings);
        },
        .idle => try runIdle(allocator, executable, tool, &settings),
        .regions => try runRegions(allocator, executable, tool, &settings),
    }
    if (origin_running) {
        const served = origin_server.stop();
        try emit(.{ .schema = "collo.microbench.v1", .kind = "origin_summary", .served = served });
        if (served.failures != 0) return error.OriginRefusedRequests;
    }
    try emit(.{ .schema = "collo.microbench.v1", .kind = "complete", .mode = @tagName(mode) });
}

fn runCold(
    allocator: std.mem.Allocator,
    executable: []const u8,
    tool: []const u8,
    settings: *const Settings,
) !void {
    var creation: std.ArrayList(u64) = .empty;
    defer creation.deinit(allocator);
    var dispatch: std.ArrayList(u64) = .empty;
    defer dispatch.deinit(allocator);
    var total: std.ArrayList(u64) = .empty;
    defer total.deinit(allocator);
    for (0..settings.rounds) |round| {
        var session = try Session.start(allocator, executable, tool, .cold, settings);
        errdefer session.close() catch |err| std.debug.print("cleanup failed: {s}\n", .{@errorName(err)});
        try requireCount(&session, 0);
        var seen_workers: [sample_limit]u64 = undefined;
        for (0..settings.samples) |index| {
            const route: u32 = @intCast(index % protocol.route_count_max);
            const response = try session.exchange(route, settings.workload.coldExchange());
            var collected = try session.command(.{
                .op = .collect,
                .route = route,
                .stream_id = response.stream_id,
                .sent_ns = response.sent_ns,
            });
            defer collected.deinit();
            const trace = collected.value.trace orelse return error.MissingColdTrace;
            const handler = collected.value.handler orelse return error.MissingHandlerMark;
            if (trace.request_id == 0 or trace.request_id != handler.request_id or
                trace.worker_id != handler.worker_id or
                trace.worker_generation != handler.worker_generation or
                trace.request_stream_id != response.stream_id or
                trace.route_index != route or trace.worker_pid == 0 or
                trace.worker_pid != trace.launched_worker_pid)
                return error.SampleIdentityMismatch;
            const worker = protocol.Worker{
                .route = route,
                .pid = trace.worker_pid,
                .worker_id = trace.worker_id,
                .worker_generation = trace.worker_generation,
            };
            var active = try session.command(.{ .op = .snapshot });
            defer active.deinit();
            if (active.value.workers.len != 1) return error.UnexpectedWorkerCount;
            try requireWorker(active.value.workers, worker);
            for (seen_workers[0..index]) |seen| {
                if (seen == worker.worker_id) return error.ReusedColdWorker;
            }
            seen_workers[index] = worker.worker_id;
            const timeline = timing.Timeline{
                .request_sent_ns = response.sent_ns,
                .worker_ready_ns = trace.ready_received_ns,
                .handler_enter_ns = handler.handler_started_ns,
                .response_received_ns = response.response_ns,
            };
            const elapsed = try timeline.durations();
            try emit(.{
                .schema = "collo.microbench.v1",
                .kind = "cold_sample",
                .round = round,
                .sample = index,
                .request_id = trace.request_id,
                .worker_id = trace.worker_id,
                .worker_generation = trace.worker_generation,
                .worker_pid = trace.worker_pid,
                .stream_id = response.stream_id,
                .timeline = timeline,
                .durations = elapsed,
                .host_arrived_ns = trace.arrived_ns,
                .host_published_ns = trace.publish_ns,
                .host_delivered_ns = trace.delivered_ns,
            });
            try creation.append(allocator, elapsed.creation_ns);
            try dispatch.append(allocator, elapsed.dispatch_ns);
            try total.append(allocator, elapsed.total_ns);
            try drop(&session, worker);
            try requireCount(&session, 0);
        }
        try session.close();
    }
    std.mem.sort(u64, creation.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, dispatch.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, total.items, {}, std.sort.asc(u64));
    try emit(.{
        .schema = "collo.microbench.v1",
        .kind = "cold_summary",
        .creation = try timing.Percentiles.fromSorted(creation.items),
        .dispatch = try timing.Percentiles.fromSorted(dispatch.items),
        .total = try timing.Percentiles.fromSorted(total.items),
    });
}

fn runMemory(
    allocator: std.mem.Allocator,
    executable: []const u8,
    tool: []const u8,
    settings: *const Settings,
) !void {
    const requests = settings.load.requestCount();
    for ([_]MemoryPhase{ .ready, .after_load }) |phase| {
        for (0..settings.rounds) |round| {
            // The order rotates between rounds, so no population always runs first.
            for (0..populations.len) |index| {
                const population = populations[(index + round) % populations.len];
                var session = try Session.start(allocator, executable, tool, .memory, settings);
                errdefer session.close() catch |err|
                    std.debug.print("cleanup failed: {s}\n", .{@errorName(err)});
                try requireCount(&session, 0);
                const idle = try restingGroup(session.scope, settings.settle_ns);
                for (0..population) |route| {
                    const worker = (try prepare(&session, @intCast(route), null)).worker;
                    if (phase == .after_load) try load(&session, worker, &settings.load);
                }
                try requireCount(&session, population);
                var peak = try memory.PeakCounter.init(session.scope);
                defer peak.deinit();
                // Two cycles add, measure and drop the worker of the same route, so
                // the output holds both a fresh insertion and a recreation.
                for (0..2) |cycle| {
                    const context = Context{
                        .phase = @tagName(phase),
                        .moment = .before,
                        .round = round,
                        .cycle = cycle,
                        .population = population,
                    };
                    const before = try restingGroup(session.scope, settings.settle_ns);
                    var existing = try session.command(.{ .op = .snapshot });
                    defer existing.deinit();
                    if (existing.value.workers.len != population)
                        return error.UnexpectedWorkerCount;
                    try emitProcessSet(&session, existing.value.workers, context);
                    try emitRegionSet(&session, null, context);
                    const prepared = try prepare(&session, population, &peak);
                    const added = prepared.worker;
                    const creation_peak = prepared.creation_peak_bytes.?;
                    var ready_inventory = try session.command(.{ .op = .snapshot });
                    defer ready_inventory.deinit();
                    if (ready_inventory.value.workers.len != population + 1)
                        return error.UnexpectedWorkerCount;
                    try requireWorker(ready_inventory.value.workers, added);
                    // A prepared worker is published at WorkerReady without a
                    // request, so only `load` runs its handler.
                    const ready = try restingGroup(session.scope, settings.settle_ns);
                    try requireNoPressure(before.snapshot, ready.snapshot);
                    try emitProcessSet(&session, ready_inventory.value.workers, context.at(.ready));
                    try emitRegionSet(&session, added, context.at(.ready));
                    const after = if (phase == .after_load) blk: {
                        try load(&session, added, &settings.load);
                        break :blk try restingGroup(session.scope, settings.settle_ns);
                    } else ready;
                    const operation_peak = try peak.read();
                    try requireNoPressure(ready.snapshot, after.snapshot);
                    var snapshot = try session.command(.{ .op = .snapshot });
                    defer snapshot.deinit();
                    try requireSameInventory(ready_inventory.value.workers, snapshot.value.workers);
                    try emit(.{
                        .schema = "collo.microbench.v1",
                        .kind = "memory_sample",
                        .phase = @tagName(phase),
                        .round = round,
                        .cycle = cycle,
                        .population_before = population,
                        .population_after = population + 1,
                        .population_history = .{
                            .existing_count = population,
                            .existing_phase = @tagName(phase),
                            .existing_requests_per_instance = if (phase == .after_load) requests else 0,
                            .target_initial_phase = "ready",
                            .target_requests_before_load = 0,
                            .target_final_phase = @tagName(phase),
                            .target_requests_after_load = if (phase == .after_load) requests else 0,
                        },
                        .scope = session.scope,
                        .worker = added,
                        .idle = idle,
                        .before = before,
                        .ready = ready,
                        .after = after,
                        .load_growth_bytes = try memory.signedDelta(
                            after.snapshot.current_bytes,
                            ready.snapshot.current_bytes,
                        ),
                        .marginal_bytes = try memory.signedDelta(
                            after.snapshot.current_bytes,
                            before.snapshot.current_bytes,
                        ),
                        .amortized_bytes = try memory.amortizedDelta(
                            after.snapshot.current_bytes,
                            idle.snapshot.current_bytes,
                            population + 1,
                        ),
                        .creation_peak_bytes = creation_peak,
                        .creation_peak_added_bytes = try memory.signedDelta(
                            creation_peak,
                            before.snapshot.current_bytes,
                        ),
                        .operation_peak_bytes = operation_peak,
                    });
                    if (phase == .after_load) {
                        try emitProcessSet(&session, snapshot.value.workers, context.at(.after_load));
                        try emitRegionSet(&session, added, context.at(.after_load));
                    }
                    try drop(&session, added);
                    try requireCount(&session, population);
                    const removed = try restingGroup(session.scope, settings.settle_ns);
                    try requireNoPressure(after.snapshot, removed.snapshot);
                    try emit(.{
                        .schema = "collo.microbench.v1",
                        .kind = "memory_teardown",
                        .phase = @tagName(phase),
                        .round = round,
                        .cycle = cycle,
                        .population = population,
                        .snapshot = removed,
                        .retained_bytes = try memory.signedDelta(
                            removed.snapshot.current_bytes,
                            before.snapshot.current_bytes,
                        ),
                    });
                }
                try session.close();
            }
        }
    }
}

/// One loaded worker per round, left alone after its load: a settle of
/// `idle_settle_ms`, then a window of `Settings.idle_window_ns` over which
/// its leaf's CPU and its tasks' context switches are the work an idle
/// worker still does, and its Private_Dirty what it keeps.
fn runIdle(
    allocator: std.mem.Allocator,
    executable: []const u8,
    tool: []const u8,
    settings: *const Settings,
) !void {
    for (0..settings.rounds) |round| {
        var session = try Session.start(allocator, executable, tool, .idle, settings);
        errdefer session.close() catch |err| std.debug.print("cleanup failed: {s}\n", .{@errorName(err)});
        try requireCount(&session, 0);
        const worker = (try prepare(&session, 0, null)).worker;
        try load(&session, worker, &settings.load);
        var leaf_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const leaf = try workerLeaf(&session, worker, &leaf_buffer);
        std.Thread.sleep(idle_settle_ms * std.time.ns_per_ms);
        const group_start = try memory.readGroup(session.scope);
        const start = try probeIdle(worker, leaf);
        std.Thread.sleep(settings.idle_window_ns);
        const end = try probeIdle(worker, leaf);
        const group_end = try memory.readGroup(session.scope);
        try requireNoPressure(group_start, group_end);
        var inventory = try session.command(.{ .op = .snapshot });
        defer inventory.deinit();
        try requireSameInventory(&.{worker}, inventory.value.workers);
        try emit(.{
            .schema = "collo.microbench.v1",
            .kind = "idle_sample",
            .round = round,
            .scope = session.scope,
            .worker = worker,
            .leaf = leaf,
            .load_requests = settings.load.requestCount(),
            .settle_ms = idle_settle_ms,
            .window_ms = settings.idle_window_ns / std.time.ns_per_ms,
            .start = start,
            .end = end,
            .cpu_usage_usec_delta = try memory.signedDelta(end.cpu.usage_usec, start.cpu.usage_usec),
            .context_switches_delta = try memory.signedDelta(
                try end.switches.total(),
                try start.switches.total(),
            ),
            .private_dirty_delta_bytes = try memory.signedDelta(
                end.memory.private_dirty_bytes,
                start.memory.private_dirty_bytes,
            ),
        });
        try drop(&session, worker);
        try requireCount(&session, 0);
        try session.close();
    }
}

/// What an idle worker is doing at one instant.
const IdleProbe = struct {
    monotonic_ns: u64,
    memory: memory.ProcessMemory,
    /// The worker's leaf cgroup, which holds only the worker.
    cpu: memory.CpuStat,
    switches: memory.ProcessSwitches,
};

fn probeIdle(worker: protocol.Worker, leaf: []const u8) !IdleProbe {
    return .{
        .monotonic_ns = try process.monotonicNowNs(),
        .memory = try memory.readProcess(worker.pid),
        .cpu = try memory.readCpuStat(leaf),
        .switches = try memory.readProcessSwitches(worker.pid),
    };
}

/// One worker per round runs the workload's steps in order. It is sampled
/// at WorkerReady and after each step, each sample taken twice: right after
/// the step and again after the idle window, so the regions a step left
/// resident show apart from what idleness gives back.
fn runRegions(
    allocator: std.mem.Allocator,
    executable: []const u8,
    tool: []const u8,
    settings: *const Settings,
) !void {
    for (0..settings.rounds) |round| {
        var session = try Session.start(allocator, executable, tool, .regions, settings);
        errdefer session.close() catch |err| std.debug.print("cleanup failed: {s}\n", .{@errorName(err)});
        try requireCount(&session, 0);
        const worker = (try prepare(&session, 0, null)).worker;
        var previous = try sampleStep(&session, worker, settings, round, "ready", null);
        for (settings.load.steps()) |step| {
            try runStep(&session, worker, step);
            previous = try sampleStep(&session, worker, settings, round, @tagName(step.exchange), previous);
        }
        try drop(&session, worker);
        try requireCount(&session, 0);
        try session.close();
    }
}

/// Emits `worker`'s two samples of `step` and returns the cgroup reading of
/// the second; `previous` is the one before them, against which no pressure
/// event may have happened.
fn sampleStep(
    session: *Session,
    worker: protocol.Worker,
    settings: *const Settings,
    round: usize,
    step: []const u8,
    previous: ?memory.GroupMemory,
) !memory.GroupMemory {
    var last = previous;
    for ([_]Moment{ .after_step, .after_idle }) |moment| {
        if (moment == .after_idle) std.Thread.sleep(settings.idle_window_ns);
        const group = try restingGroup(session.scope, settings.settle_ns);
        if (last) |earlier| try requireNoPressure(earlier, group.snapshot);
        last = group.snapshot;
        var inventory = try session.command(.{ .op = .snapshot });
        defer inventory.deinit();
        try requireSameInventory(&.{worker}, inventory.value.workers);
        const context = Context{ .phase = "regions", .moment = moment, .step = step, .round = round };
        try emit(.{
            .schema = "collo.microbench.v1",
            .kind = "region_sample",
            .phase = context.phase,
            .moment = @tagName(moment),
            .step = step,
            .round = round,
            .scope = session.scope,
            .worker = worker,
            .group = group,
        });
        try emitProcessSet(session, inventory.value.workers, context);
        try emitRegionSet(session, worker, context);
    }
    return last.?;
}

const PreparedWorker = struct {
    worker: protocol.Worker,
    creation_peak_bytes: ?u64,
};

fn prepare(session: *Session, route: u32, peak: ?*memory.PeakCounter) !PreparedWorker {
    var before = try session.command(.{ .op = .snapshot });
    defer before.deinit();
    for (before.value.workers) |worker| {
        if (worker.route == route) return error.WorkerAlreadyPrepared;
    }
    if (peak) |counter| try counter.reset();
    var reply = try session.command(.{ .op = .prepare, .route = route });
    defer reply.deinit();
    // The peak is read before the inventory check and memory sampling add work.
    const creation_peak: ?u64 = if (peak) |counter| try counter.read() else null;
    var after = try session.command(.{ .op = .snapshot });
    defer after.deinit();
    if (after.value.workers.len != before.value.workers.len + 1)
        return error.UnexpectedWorkerCount;
    for (before.value.workers) |worker| try requireWorker(after.value.workers, worker);
    for (after.value.workers) |worker| {
        if (worker.route == route) return .{ .worker = worker, .creation_peak_bytes = creation_peak };
    }
    return error.MissingAddedWorker;
}

fn drop(session: *Session, expected: protocol.Worker) !void {
    var before = try session.command(.{ .op = .snapshot });
    defer before.deinit();
    try requireWorker(before.value.workers, expected);
    var reply = try session.command(.{ .op = .drop, .worker_id = expected.worker_id });
    defer reply.deinit();
    var after = try session.command(.{ .op = .snapshot });
    defer after.deinit();
    if (after.value.workers.len + 1 != before.value.workers.len)
        return error.UnexpectedWorkerCount;
    for (after.value.workers) |worker| {
        if (worker.worker_id == expected.worker_id) return error.WorkerNotDropped;
        try requireWorker(before.value.workers, worker);
    }
}

fn load(session: *Session, worker: protocol.Worker, plan: *const workload_mod.Load) !void {
    for (plan.steps()) |step| try runStep(session, worker, step);
    var reply = try session.command(.{ .op = .snapshot });
    defer reply.deinit();
    try requireWorker(reply.value.workers, worker);
}

fn runStep(session: *Session, worker: protocol.Worker, step: workload_mod.Step) !void {
    for (0..step.requests) |_| _ = try session.exchange(worker.route, step.exchange);
}

fn restingGroup(scope: []const u8, settle_ns: u64) !StableGroup {
    std.Thread.sleep(settle_ns);
    return stableGroup(scope);
}

const StableGroup = struct {
    snapshot: memory.GroupMemory,
    samples: usize,
    min_bytes: u64,
    max_bytes: u64,
    stat_min: memory.MemoryStat,
    stat_max: memory.MemoryStat,
    stable: bool,
};

fn stableGroup(scope: []const u8) !StableGroup {
    var window: [stable_samples]memory.GroupMemory = undefined;
    var result: StableGroup = undefined;
    for (0..stable_attempts) |index| {
        const snapshot = try memory.readGroup(scope);
        if (snapshot.swap_bytes != 0) return error.SwapContaminatedMeasurement;
        if (index != 0) try requireNoPressure(window[(index - 1) % window.len], snapshot);
        window[index % window.len] = snapshot;
        if (index + 1 >= window.len) {
            result = .{
                .snapshot = snapshot,
                .samples = index + 1,
                .min_bytes = snapshot.current_bytes,
                .max_bytes = snapshot.current_bytes,
                .stat_min = snapshot.stat,
                .stat_max = snapshot.stat,
                .stable = true,
            };
            for (window) |sample| {
                result.min_bytes = @min(result.min_bytes, sample.current_bytes);
                result.max_bytes = @max(result.max_bytes, sample.current_bytes);
                inline for (@typeInfo(memory.MemoryStat).@"struct".fields) |field| {
                    @field(result.stat_min, field.name) = @min(
                        @field(result.stat_min, field.name),
                        @field(sample.stat, field.name),
                    );
                    @field(result.stat_max, field.name) = @max(
                        @field(result.stat_max, field.name),
                        @field(sample.stat, field.name),
                    );
                }
            }
            result.stable = result.max_bytes - result.min_bytes <= stability_tolerance_bytes;
            inline for (@typeInfo(memory.MemoryStat).@"struct".fields) |field| {
                if (@field(result.stat_max, field.name) - @field(result.stat_min, field.name) >
                    stability_tolerance_bytes) result.stable = false;
            }
            // A window within the tolerance bounds the sampling uncertainty; it
            // does not prove the runtime was idle.
            if (result.stable) return result;
        }
        std.Thread.sleep(stable_interval_ns);
    }
    try emit(.{
        .schema = "collo.microbench.v1",
        .kind = "memory_unstable",
        .scope = scope,
        .tolerance_bytes = stability_tolerance_bytes,
        .range = result,
        .window = window,
    });
    return error.UnstableMemoryMeasurement;
}

fn requireNoPressure(before: memory.GroupMemory, after: memory.GroupMemory) !void {
    if (after.swap_bytes != 0 or after.events.high != before.events.high or
        after.events.max != before.events.max or after.events.oom != before.events.oom or
        after.events.oom_kill != before.events.oom_kill)
        return error.MemoryPressureContaminatedMeasurement;
}

/// Where one set of process and region records sits in a run.
const Context = struct {
    /// A `MemoryPhase` name, or `regions`.
    phase: []const u8,
    moment: Moment,
    /// The step a `regions` sample follows: `ready` or an exchange name.
    step: ?[]const u8 = null,
    round: usize,
    cycle: usize = 0,
    population: u32 = 0,

    fn at(self: Context, moment: Moment) Context {
        var result = self;
        result.moment = moment;
        return result;
    }
};

fn emitProcessSet(session: *Session, workers: []const protocol.Worker, context: Context) !void {
    try emitProcess(session, session.server_pid, "server", null, context);
    try emitProcess(session, session.ready.zygote_pid, "zygote", null, context);
    if (session.ready.gateway_pid) |pid| try emitProcess(session, pid, "gateway", null, context);
    for (workers) |worker| try emitProcess(session, worker.pid, "sandbox", worker, context);
}

fn emitProcess(
    session: *Session,
    pid: u32,
    role: []const u8,
    worker: ?protocol.Worker,
    context: Context,
) !void {
    try requireMembership(pid, session.scope);
    const snapshot = try memory.readProcess(pid);
    if (snapshot.swap_bytes != 0) return error.SwapContaminatedMeasurement;
    try emit(.{
        .schema = "collo.microbench.v1",
        .kind = "process_memory",
        .phase = context.phase,
        .moment = @tagName(context.moment),
        .step = context.step,
        .scope = session.scope,
        .worker = worker,
        .round = context.round,
        .cycle = context.cycle,
        .population_before = context.population,
        .pid = pid,
        .role = role,
        .memory = snapshot,
        .uss_bytes = try snapshot.ussBytes(),
        .shared_mapped_bytes = try snapshot.sharedBytes(),
    });
}

/// The scratch one region reading needs; a session keeps one, since the
/// mapping lists are too large for the stack.
const RegionScratch = struct {
    target: [memory.region_mappings_max]memory.RegionMapping,
    process: [memory.region_mappings_max]memory.RegionMapping,
    allocated: [memory.region_mappings_max]u64,
    all: memory.RegionTable,
    within: memory.RegionTable,
};

/// Records which cgroup holds the node's shared regions, then the regions
/// of the target worker, the server and the gateway. The server's and the
/// gateway's records also carry their share of the target's regions: the
/// mappings of the memfds the target maps too.
fn emitRegionSet(session: *Session, target: ?protocol.Worker, context: Context) !void {
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_buffer, "{s}/main", .{session.scope});
    var leaf_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const leaf: ?[]const u8 = if (target) |worker| try workerLeaf(session, worker, &leaf_buffer) else null;
    try emit(.{
        .schema = "collo.microbench.v1",
        .kind = "cgroup_memory",
        .phase = context.phase,
        .moment = @tagName(context.moment),
        .step = context.step,
        .scope = session.scope,
        .round = context.round,
        .cycle = context.cycle,
        .population_before = context.population,
        .target = target,
        .runtime = try memory.readGroup(session.scope),
        .main = try memory.readGroup(main_path),
        .worker_leaf = if (leaf) |path| try memory.readGroup(path) else null,
    });
    const scratch = session.regions;
    var target_mappings: []const memory.RegionMapping = &.{};
    if (target) |worker| {
        try requireMembership(worker.pid, session.scope);
        target_mappings = try memory.readRegionMappings(worker.pid, &scratch.target);
        try emitRegions(session, worker.pid, "sandbox", target, target_mappings, null, context);
    }
    const within: ?[]const memory.RegionMapping = if (target != null) target_mappings else null;
    try requireMembership(session.server_pid, session.scope);
    const server_mappings = try memory.readRegionMappings(session.server_pid, &scratch.process);
    try emitRegions(session, session.server_pid, "server", target, server_mappings, within, context);
    if (session.ready.gateway_pid) |pid| {
        try requireMembership(pid, session.scope);
        const gateway_mappings = try memory.readRegionMappings(pid, &scratch.process);
        try emitRegions(session, pid, "gateway", target, gateway_mappings, within, context);
    }
}

fn emitRegions(
    session: *Session,
    pid: u32,
    role: []const u8,
    target: ?protocol.Worker,
    mappings: []const memory.RegionMapping,
    within: ?[]const memory.RegionMapping,
    context: Context,
) !void {
    const scratch = session.regions;
    const allocated = scratch.allocated[0..mappings.len];
    try memory.readRegionAllocations(pid, mappings, allocated);
    try scratch.all.tabulate(mappings, allocated, null);
    if (within) |set| try scratch.within.tabulate(mappings, allocated, set);
    try emit(.{
        .schema = "collo.microbench.v1",
        .kind = "region_memory",
        .phase = context.phase,
        .moment = @tagName(context.moment),
        .step = context.step,
        .scope = session.scope,
        .round = context.round,
        .cycle = context.cycle,
        .population_before = context.population,
        .target = target,
        .pid = pid,
        .role = role,
        .regions = scratch.all.items(),
        .target_regions = if (within != null) scratch.within.items() else null,
    });
}

fn requireMembership(pid: u32, scope: []const u8) !void {
    if (!try processInScope(pid, scope)) return error.ProcessOutsideMeasuredScope;
}

fn requireSamplerExcluded(scope: []const u8) !void {
    if (try processInScope(@intCast(std.os.linux.getpid()), scope))
        return error.SamplerInsideMeasuredScope;
}

fn processInScope(pid: u32, scope: []const u8) !bool {
    if (!std.mem.startsWith(u8, scope, cgroup_mount)) return error.InvalidScopeMembership;
    var buffer: [cgroup_file_bytes_max + 1]u8 = undefined;
    const member = try cgroupMember(pid, &buffer);
    const relative = scope[cgroup_mount.len..];
    return std.mem.eql(u8, member, relative) or
        (member.len > relative.len and member[relative.len] == '/' and
            std.mem.startsWith(u8, member, relative));
}

const cgroup_mount = "/sys/fs/cgroup";
const cgroup_file_bytes_max = 4096;

/// The cgroup v2 path of `pid` below `cgroup_mount`, from its
/// `/proc/<pid>/cgroup`, as a slice of `buffer`.
fn cgroupMember(pid: u32, buffer: *[cgroup_file_bytes_max + 1]u8) ![]const u8 {
    if (pid == 0) return error.InvalidScopeMembership;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/cgroup", .{pid});
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const count = try file.readAll(buffer);
    if (count == buffer.len) return error.InvalidScopeMembership;
    var lines = std.mem.tokenizeScalar(u8, buffer[0..count], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) return line[3..];
    }
    return error.InvalidScopeMembership;
}

/// The cgroup directory of `worker`, a leaf under the scope's `workers`, as
/// a slice of `out`.
fn workerLeaf(session: *Session, worker: protocol.Worker, out: []u8) ![]const u8 {
    var workers_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const workers = try std.fmt.bufPrint(&workers_buffer, "{s}/workers", .{session.scope});
    try requireMembership(worker.pid, workers);
    var buffer: [cgroup_file_bytes_max + 1]u8 = undefined;
    const member = try cgroupMember(worker.pid, &buffer);
    return std.fmt.bufPrint(out, "{s}{s}", .{ cgroup_mount, member });
}

fn validateWorkers(session: *Session, workers: []const protocol.Worker) !void {
    if (workers.len > protocol.route_count_max) return error.UnexpectedWorkerCount;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, "{s}/workers", .{session.scope});
    for (workers, 0..) |worker, index| {
        if (worker.worker_id == 0 or worker.worker_generation == 0 or
            worker.route >= protocol.route_count_max) return error.InvalidWorkerIdentity;
        try requireMembership(worker.pid, root);
        for (workers[0..index]) |previous| {
            if (previous.worker_id == worker.worker_id or previous.pid == worker.pid or
                previous.route == worker.route) return error.DuplicateWorkerIdentity;
        }
    }
}

fn sameWorker(a: protocol.Worker, b: protocol.Worker) bool {
    return a.worker_id == b.worker_id and a.worker_generation == b.worker_generation and
        a.pid == b.pid and a.route == b.route;
}

fn requireWorker(workers: []const protocol.Worker, expected: protocol.Worker) !void {
    for (workers) |worker| {
        if (sameWorker(worker, expected)) return;
    }
    return error.WorkerIdentityChanged;
}

fn requireSameInventory(before: []const protocol.Worker, after: []const protocol.Worker) !void {
    if (before.len != after.len) return error.UnexpectedWorkerCount;
    for (before) |worker| try requireWorker(after, worker);
}

fn requireCount(session: *Session, expected: usize) !void {
    var reply = try session.command(.{ .op = .snapshot });
    defer reply.deinit();
    if (reply.value.workers.len != expected) return error.UnexpectedWorkerCount;
}

const Session = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    tool: []const u8,
    /// The trial's cgroup directory, owned by the session.
    scope: []u8,
    /// The daemon's pid, which runs the server: `wsl-config run` execs the
    /// daemon in place, so it keeps the pid of the spawned child.
    server_pid: u32,
    ready: protocol.Ready,
    /// Owned by the session.
    regions: *RegionScratch,
    client: ?*protocol.Client = null,
    live: bool = false,
    ready_received: bool = false,
    child_reaped: bool = false,
    last_stream_id: u32 = 0,

    fn start(
        allocator: std.mem.Allocator,
        executable: []const u8,
        tool: []const u8,
        mode: Mode,
        settings: *const Settings,
    ) !Session {
        const scope = try std.fmt.allocPrint(
            allocator,
            "/sys/fs/cgroup/collo-dev/collo-bench-{d}-{d}",
            .{ std.os.linux.getpid(), try process.monotonicNowNs() },
        );
        var owns_scope = true;
        errdefer if (owns_scope) allocator.free(scope);
        const regions = try allocator.create(RegionScratch);
        var owns_regions = true;
        errdefer if (owns_regions) allocator.destroy(regions);
        try runTool(allocator, &.{ tool, "scope-create", scope });
        errdefer if (owns_scope) {
            runTool(allocator, &.{ tool, "scope-remove", scope }) catch |err|
                std.debug.print("cannot remove scope {s}: {s}\n", .{ scope, @errorName(err) });
        };
        try requireSamplerExcluded(scope);
        var environment = try std.process.getEnvMap(allocator);
        defer environment.deinit();
        const main_path = try std.fmt.allocPrint(allocator, "{s}/main", .{scope});
        defer allocator.free(main_path);
        const workers_path = try std.fmt.allocPrint(allocator, "{s}/workers", .{scope});
        defer allocator.free(workers_path);
        // The placement contract behind the two cgroup paths is in
        // `dev/wsl/cgroup_env.zig`. Only cold trials need the handler-entry
        // marker (`COLLO_BENCH_HANDLER` in `server/supervisor/launcher.zig`).
        try environment.put("COLLO_TEST_CGROUP", main_path);
        try environment.put("COLLO_BENCH_CGROUP_ROOT", workers_path);
        try environment.put("COLLO_BENCH_HANDLER", if (mode == .cold) "1" else "0");
        // The daemon reads every knob again; it gets the values this run
        // validated, which its ready line must echo.
        try environment.put(Workload.environment_name, @tagName(settings.workload));
        try environment.put(node.Network.environment_name, @tagName(settings.network));
        var concurrency_buffer: [4]u8 = undefined;
        try environment.put(
            node.concurrency_environment_name,
            std.fmt.bufPrint(&concurrency_buffer, "{d}", .{settings.concurrency}) catch unreachable,
        );
        if (settings.origin) |origin| {
            var origin_buffer: [node.Origin.text_bytes_max]u8 = undefined;
            try environment.put(
                node.Origin.environment_name,
                std.fmt.bufPrint(&origin_buffer, "{f}", .{origin}) catch unreachable,
            );
        } else {
            environment.remove(node.Origin.environment_name);
        }
        var child = std.process.Child.init(&.{ tool, "run", "--", executable, "daemon" }, allocator);
        child.env_map = &environment;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        var result = Session{
            .allocator = allocator,
            .child = child,
            .tool = tool,
            .scope = scope,
            .server_pid = @intCast(child.id),
            .ready = undefined,
            .regions = regions,
            .live = true,
        };
        owns_scope = false;
        owns_regions = false;
        // `environment` is freed when `start` returns; the child got its copy
        // at spawn.
        result.child.env_map = null;
        errdefer result.close() catch |err|
            std.debug.print("startup cleanup failed: {s}\n", .{@errorName(err)});
        var reply = try result.receive();
        defer reply.deinit();
        if (reply.value.op != .ready) return error.ExpectedDaemonReady;
        result.ready = reply.value.ready orelse return error.ExpectedDaemonReady;
        result.ready_received = true;
        if (result.ready.port == 0 or result.ready.zygote_pid == result.server_pid)
            return error.InvalidRuntimeIdentity;
        if (result.ready.workload != settings.workload) return error.WorkloadMismatch;
        if (result.ready.network != settings.network) return error.NetworkMismatch;
        if (result.ready.concurrency != settings.concurrency) return error.ConcurrencyMismatch;
        switch (settings.network) {
            .granted => {
                const gateway = result.ready.gateway_pid orelse return error.GatewayMissing;
                if (gateway == result.server_pid or gateway == result.ready.zygote_pid)
                    return error.InvalidRuntimeIdentity;
            },
            .none => if (result.ready.gateway_pid != null) return error.GatewayWithoutGrant,
        }
        try requireSamplerExcluded(scope);
        try requireMembership(result.server_pid, main_path);
        try requireMembership(result.ready.zygote_pid, main_path);
        if (result.ready.gateway_pid) |gateway| try requireMembership(gateway, main_path);
        if (protocol.collo_bench_client_open(
            result.ready.port,
            protocol.hostname,
            client_timeout_ms,
            &result.client,
        ) != 0)
            return error.HttpPreflightFailed;
        try emit(.{
            .schema = "collo.microbench.v1",
            .kind = "runtime_metadata",
            .mode = @tagName(mode),
            .scope = scope,
            .server_pid = result.server_pid,
            .gateway_pid = result.ready.gateway_pid,
            .network = @tagName(result.ready.network),
            .concurrency = result.ready.concurrency,
            .artifact_topology = @tagName(result.ready.artifact_topology),
            .resident_pack_count = result.ready.resident_pack_count,
        });
        return result;
    }

    /// Sends `kind` to the route's worker and checks the response the client
    /// accepted against what the exchange promises.
    fn exchange(self: *Session, route: u32, kind: Exchange) !protocol.ClientReply {
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}{d}{s}", .{
            protocol.route_prefix, route, kind.query(),
        });
        const expected = kind.response();
        const request = protocol.ClientExchange{
            .path = path.ptr,
            .expected_body = switch (expected) {
                .exact => |bytes| bytes.ptr,
                .patterned => null,
            },
            .expected_body_len = expected.byteCount(),
            .request_body_len = kind.requestBodyBytes(),
            .pattern_block_bytes = workload_mod.pattern_block_bytes,
        };
        var result: protocol.ClientReply = undefined;
        if (protocol.collo_bench_client_exchange(self.client.?, &request, &result) != 0)
            return error.HttpRequestFailed;
        // Client streams are odd and increase (RFC 9113 §5.1.1), so a reply on
        // any other stream id cannot belong to this request.
        if (result.status != 200 or result.body_len != expected.byteCount() or
            result.reserved != 0 or result.sent_ns == 0 or result.response_ns < result.sent_ns or
            result.stream_id <= self.last_stream_id or result.stream_id & 1 == 0)
            return error.InvalidHttpSample;
        self.last_stream_id = result.stream_id;
        return result;
    }

    fn command(self: *Session, command_value: protocol.Command) !std.json.Parsed(protocol.Reply) {
        var buffer: [protocol.command_bytes_max]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "{f}\n", .{std.json.fmt(command_value, .{})});
        const input = self.child.stdin orelse return error.DaemonClosed;
        try input.writeAll(bytes);
        var reply = try self.receive();
        errdefer reply.deinit();
        if (!std.mem.eql(u8, @tagName(reply.value.op), @tagName(command_value.op)))
            return error.UnexpectedReplyOperation;
        if (command_value.op == .snapshot) try validateWorkers(self, reply.value.workers);
        return reply;
    }

    fn receive(self: *Session) !std.json.Parsed(protocol.Reply) {
        var buffer: [protocol.reply_bytes_max]u8 = undefined;
        const bytes = try readLine(self.child.stdout.?.handle, &buffer, operation_timeout_ms);
        const parsed = try std.json.parseFromSlice(protocol.Reply, self.allocator, bytes, .{
            .allocate = .alloc_always,
        });
        errdefer parsed.deinit();
        if (parsed.value.op == .failed) {
            std.debug.print("benchmark daemon error: {s}\n", .{parsed.value.error_name orelse "unknown"});
            return error.DaemonOperationFailed;
        }
        return parsed;
    }

    /// Ends the trial and frees the session on every path. When the graceful
    /// shutdown fails, it kills the scope, reaps the daemon and removes the
    /// emptied scope; the error is then the last cleanup step that failed, or
    /// the shutdown's own error when cleanup succeeded.
    fn close(self: *Session) !void {
        if (!self.live) return;
        defer {
            closeChildPipes(&self.child);
            self.allocator.free(self.scope);
            self.allocator.destroy(self.regions);
            self.live = false;
        }
        protocol.collo_bench_client_close(self.client);
        self.client = null;
        self.closeGracefully() catch |cause| {
            std.debug.print("graceful teardown of {s} failed: {s}; stopping its scope\n", .{
                self.scope, @errorName(cause),
            });
            if (self.child.stdin) |input| {
                input.close();
                self.child.stdin = null;
            }
            var cleanup_error: ?anyerror = null;
            self.killScope() catch |err| {
                std.debug.print("cannot stop scope {s}: {s}\n", .{ self.scope, @errorName(err) });
                cleanup_error = err;
            };
            if (!self.child_reaped) {
                _ = self.waitForExit(5000) catch |err| blk: {
                    std.debug.print("cannot reap daemon {d}: {s}\n", .{
                        self.server_pid, @errorName(err),
                    });
                    cleanup_error = err;
                    break :blk std.process.Child.Term{ .Exited = 1 };
                };
            }
            self.removeStoppedScope() catch |err| {
                std.debug.print("retained scope {s}: {s}\n", .{ self.scope, @errorName(err) });
                cleanup_error = err;
            };
            return cleanup_error orelse cause;
        };
    }

    fn closeGracefully(self: *Session) !void {
        if (!self.ready_received) return error.DaemonStartupIncomplete;
        var reply = try self.command(.{ .op = .shutdown });
        reply.deinit();
        try requireSuccess(try self.waitForExit(operation_timeout_ms));
        try runTool(self.allocator, &.{ self.tool, "scope-remove", self.scope });
    }

    fn killScope(self: *Session) !void {
        try requireSamplerExcluded(self.scope);
        try runTool(self.allocator, &.{ self.tool, "scope-kill", self.scope });
    }

    fn waitForExit(self: *Session, timeout_ms: i32) !std.process.Child.Term {
        const term = waitChild(&self.child, timeout_ms) catch |err| {
            self.child_reaped = self.child.term != null;
            return err;
        };
        self.child_reaped = true;
        return term;
    }

    fn removeStoppedScope(self: *Session) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/cgroup.events", .{self.scope});
        // `cgroup.kill` only sends SIGKILL, and the processes leave as they
        // exit, so the scope is removed once `cgroup.events` reports it
        // unpopulated; `scope-remove` keeps refusing a populated scope.
        for (0..250) |_| {
            const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
            var buffer: [256]u8 = undefined;
            const count = file.readAll(&buffer) catch |err| {
                file.close();
                return err;
            };
            file.close();
            if (count == buffer.len) return error.InvalidScopeEvents;
            var lines = std.mem.tokenizeScalar(u8, buffer[0..count], '\n');
            while (lines.next()) |line| {
                if (std.mem.eql(u8, line, "populated 0")) {
                    try runTool(self.allocator, &.{ self.tool, "scope-remove", self.scope });
                    return;
                }
            }
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
        return error.ScopeStillPopulated;
    }
};

fn closeChildPipes(child: *std.process.Child) void {
    inline for (.{ "stdin", "stdout", "stderr" }) |field| {
        if (@field(child, field)) |file| file.close();
        @field(child, field) = null;
    }
    if (child.err_pipe) |fd| std.posix.close(fd);
    child.err_pipe = null;
}

fn waitChild(child: *std.process.Child, timeout_ms: i32) !std.process.Child.Term {
    const pid = child.id;
    const pidfd = try process.openPidFd(@intCast(pid));
    defer std.posix.close(pidfd);
    if (!try process.waitForPidFdExit(pidfd, timeout_ms)) return error.ChildExitTimeout;
    return child.wait() catch |err| {
        // `Child.wait` returns a spawn failure, such as a failed exec, before
        // it reaps the child. The pidfd has already reported the exit, so this
        // waitpid reaps it without blocking.
        _ = std.posix.waitpid(pid, 0);
        closeChildPipes(child);
        return err;
    };
}

fn runTool(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var child = std.process.Child.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    defer closeChildPipes(&child);
    const term = waitChild(&child, 5000) catch |err| {
        std.debug.print("cgroup tool pid {d} failed: {s}\n", .{ child.id, @errorName(err) });
        return err;
    };
    try requireSuccess(term);
}

fn requireSuccess(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
}

fn readLine(fd: std.posix.fd_t, buffer: []u8, timeout_ms: u32) ![]const u8 {
    const deadline = (try process.monotonicNowNs()) + @as(u64, timeout_ms) * std.time.ns_per_ms;
    var length: usize = 0;
    while (length < buffer.len) {
        const now = try process.monotonicNowNs();
        if (now >= deadline) return error.ProtocolTimeout;
        var poll = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const remaining_ms: i32 = @intCast(@min((deadline - now) / std.time.ns_per_ms + 1, timeout_ms));
        if (try std.posix.poll(&poll, remaining_ms) == 0) continue;
        const count = try std.posix.read(fd, buffer[length .. length + 1]);
        if (count == 0) return error.DaemonClosed;
        if (buffer[length] == '\n') return buffer[0..length];
        length += count;
    }
    return error.ProtocolLineTooLong;
}

const SettingBounds = struct {
    default: usize,
    minimum: usize = 1,
    maximum: usize,
};

/// Reads the decimal environment variable `name`, or `bounds.default` when it
/// is unset. A value outside `bounds` fails with
/// `error.InvalidBenchmarkSetting`.
fn setting(name: [:0]const u8, bounds: SettingBounds) !usize {
    return try optionalSetting(name, bounds) orelse bounds.default;
}

/// `setting`, but null when `name` is unset.
fn optionalSetting(name: [:0]const u8, bounds: SettingBounds) !?usize {
    std.debug.assert(bounds.minimum <= bounds.default);
    std.debug.assert(bounds.default <= bounds.maximum);
    const text = std.posix.getenv(name) orelse return null;
    const value = try std.fmt.parseUnsigned(usize, text, 10);
    if (value < bounds.minimum or value > bounds.maximum) return error.InvalidBenchmarkSetting;
    return value;
}

/// Writes `value` as one JSON line on stdout, the stream `run.sh` validates.
pub fn emit(value: anytype) !void {
    try protocol.writeRecord(std.fs.File.stdout(), value);
}
