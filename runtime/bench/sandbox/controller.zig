//! The sandbox benchmark's controller: the `cold`, `memory` and `all` modes of
//! `sandbox-bench`, run on one thread outside every measured cgroup. Each trial
//! gets a fresh `collo-bench-*` scope from `wsl-config` and a runtime daemon
//! (`daemon.zig`) in the scope's `main` cgroup. The controller drives the
//! daemon over its stdin and stdout (`protocol.zig`), sends it HTTP/2 requests
//! through the loopback client and writes every result to stdout as one JSON
//! line, the stream `run.sh` validates. It refuses to run unless built with
//! ReleaseFast.
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
const Workload = @import("workload.zig").Workload;
const process = @import("collo_os").process;
const build_options = @import("collo_bench_build_options");

pub const Mode = enum { cold, memory, all };
const sample_limit = 256;
const rounds_limit = 16;
const settle_ms_max = 60_000;
/// Bounds each daemon reply and the daemon's exit after a shutdown.
const operation_timeout_ms = 30_000;
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
/// (`ready`), or ones that have each served the workload's load requests
/// (`after_load`). An `after_load` trial also samples its added worker at
/// WorkerReady, before that worker's load.
const MemoryPhase = enum { ready, after_load };
/// When a process set is read: `before` holds the existing population just
/// before the insertion, so per-process sums pair with the cgroup delta.
const Moment = enum { before, ready, after_load };

const Settings = struct {
    workload: Workload,
    rounds: usize,
    samples: usize,
    requests: usize,
    /// Pause before every resting memory snapshot, so allocator scavengers can
    /// return memory freed by the last operation before the stability window.
    settle_ns: u64,
};

pub fn run(allocator: std.mem.Allocator, mode: Mode) !void {
    if (!std.mem.eql(u8, build_options.optimize_mode_name, "ReleaseFast")) {
        std.debug.print("microbench requires -Doptimize=ReleaseFast\n", .{});
        return error.BenchmarkRequiresReleaseFast;
    }
    const workload = try Workload.fromEnvironment();
    const settle_ms = try setting("COLLO_BENCH_SETTLE_MS", .{
        .default = 0,
        .minimum = 0,
        .maximum = settle_ms_max,
    });
    const settings = Settings{
        .workload = workload,
        .rounds = try setting("COLLO_BENCH_ROUNDS", .{ .default = 3, .maximum = rounds_limit }),
        .samples = try setting("COLLO_BENCH_SAMPLES", .{ .default = 32, .maximum = sample_limit }),
        .requests = try setting("COLLO_BENCH_LOAD_REQUESTS", .{
            .default = workload.loadRequestsDefault(),
            .maximum = 1000,
        }),
        .settle_ns = settle_ms * std.time.ns_per_ms,
    };
    const executable = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    const tool = if (std.posix.getenv("COLLO_BENCH_WSL_CONFIG")) |override|
        if (override.len != 0) try allocator.dupe(u8, override) else return error.InvalidToolPath
    else
        try std.fs.path.join(allocator, &.{ std.fs.path.dirname(executable).?, "wsl-config" });
    defer allocator.free(tool);
    try emit(.{
        .schema = "collo.microbench.v1",
        .kind = "metadata",
        .mode = @tagName(mode),
        .workload = @tagName(settings.workload),
        .rounds = settings.rounds,
        .samples_per_round = settings.samples,
        .load_requests_per_instance = settings.requests,
        .settle_ms = settle_ms,
        .runtime_optimize = build_options.optimize_mode_name,
        .arch = build_options.target_arch_name,
        .clock = "CLOCK_MONOTONIC",
        .network = "loopback TLS+h2; established connection; /__collo/healthz preflight",
        .engine = "warm zygote; resident local code",
        .memory_scope = "dedicated runtime cgroup including server, zygote, gateway and workers",
        .memory_stat_accounting = "anon/file/kernel are categories; shmem is within file; " ++
            "pagetables/kernel_stack/slab are within kernel; use memory.current for totals",
        .stability_tolerance_bytes = stability_tolerance_bytes,
        .stability_window_samples = stable_samples,
        .memory_settle = "settle_ms pause before each resting snapshot, then the stability window",
        .memory_phase_comparison = "phase cohorts are independent; load_growth pairs the same target",
        .file_cache = "warm executable/library cache; preexisting external charges excluded",
        .swap = "disabled in measured subtree",
        .sampler_pid = std.os.linux.getpid(),
    });
    if (mode == .cold or mode == .all)
        try runCold(allocator, executable, tool, settings);
    if (mode == .memory or mode == .all)
        try runMemory(allocator, executable, tool, settings);
    try emit(.{ .schema = "collo.microbench.v1", .kind = "complete", .mode = @tagName(mode) });
}

fn runCold(
    allocator: std.mem.Allocator,
    executable: []const u8,
    tool: []const u8,
    settings: Settings,
) !void {
    var creation: std.ArrayList(u64) = .empty;
    defer creation.deinit(allocator);
    var dispatch: std.ArrayList(u64) = .empty;
    defer dispatch.deinit(allocator);
    var total: std.ArrayList(u64) = .empty;
    defer total.deinit(allocator);
    for (0..settings.rounds) |round| {
        var session = try Session.start(allocator, executable, tool, .cold, settings.workload);
        errdefer session.close() catch |err| std.debug.print("cleanup failed: {s}\n", .{@errorName(err)});
        try requireCount(&session, 0);
        var seen_workers: [sample_limit]u64 = undefined;
        for (0..settings.samples) |index| {
            const route: u32 = @intCast(index % protocol.route_count_max);
            const response = try session.get(route);
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
    settings: Settings,
) !void {
    const requests = settings.requests;
    for ([_]MemoryPhase{ .ready, .after_load }) |phase| {
        for (0..settings.rounds) |round| {
            // The order rotates between rounds, so no population always runs first.
            for (0..populations.len) |index| {
                const population = populations[(index + round) % populations.len];
                var session = try Session.start(
                    allocator,
                    executable,
                    tool,
                    .memory,
                    settings.workload,
                );
                errdefer session.close() catch |err|
                    std.debug.print("cleanup failed: {s}\n", .{@errorName(err)});
                try requireCount(&session, 0);
                const idle = try restingGroup(session.scope, settings.settle_ns);
                for (0..population) |route| {
                    const worker = (try prepare(&session, @intCast(route), null)).worker;
                    if (phase == .after_load) try load(&session, worker, requests);
                }
                try requireCount(&session, population);
                var peak = try memory.PeakCounter.init(session.scope);
                defer peak.deinit();
                // Two cycles add, measure and drop the worker of the same route, so
                // the output holds both a fresh insertion and a recreation.
                for (0..2) |cycle| {
                    const before = try restingGroup(session.scope, settings.settle_ns);
                    var existing = try session.command(.{ .op = .snapshot });
                    defer existing.deinit();
                    if (existing.value.workers.len != population)
                        return error.UnexpectedWorkerCount;
                    try emitProcessSet(
                        &session,
                        existing.value.workers,
                        phase,
                        .before,
                        round,
                        cycle,
                        population,
                    );
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
                    try emitProcessSet(
                        &session,
                        ready_inventory.value.workers,
                        phase,
                        .ready,
                        round,
                        cycle,
                        population,
                    );
                    const after = if (phase == .after_load) blk: {
                        try load(&session, added, requests);
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
                    if (phase == .after_load) try emitProcessSet(
                        &session,
                        snapshot.value.workers,
                        phase,
                        .after_load,
                        round,
                        cycle,
                        population,
                    );
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

fn load(session: *Session, worker: protocol.Worker, requests: usize) !void {
    for (0..requests) |_| _ = try session.get(worker.route);
    var reply = try session.command(.{ .op = .snapshot });
    defer reply.deinit();
    try requireWorker(reply.value.workers, worker);
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

const ProcessSample = struct {
    phase: MemoryPhase,
    moment: Moment,
    round: usize,
    cycle: usize,
    population: u32,
};

fn emitProcessSet(
    session: *Session,
    workers: []const protocol.Worker,
    phase: MemoryPhase,
    moment: Moment,
    round: usize,
    cycle: usize,
    population: u32,
) !void {
    const sample = ProcessSample{
        .phase = phase,
        .moment = moment,
        .round = round,
        .cycle = cycle,
        .population = population,
    };
    try emitProcess(session, session.server_pid, "server", null, sample);
    try emitProcess(session, session.ready.zygote_pid, "zygote", null, sample);
    try emitProcess(session, session.ready.gateway_pid, "gateway", null, sample);
    for (workers) |worker| try emitProcess(session, worker.pid, "sandbox", worker, sample);
}

fn emitProcess(
    session: *Session,
    pid: u32,
    role: []const u8,
    worker: ?protocol.Worker,
    sample: ProcessSample,
) !void {
    try requireMembership(pid, session.scope);
    const snapshot = try memory.readProcess(pid);
    if (snapshot.swap_bytes != 0) return error.SwapContaminatedMeasurement;
    try emit(.{
        .schema = "collo.microbench.v1",
        .kind = "process_memory",
        .phase = @tagName(sample.phase),
        .moment = @tagName(sample.moment),
        .scope = session.scope,
        .worker = worker,
        .round = sample.round,
        .cycle = sample.cycle,
        .population_before = sample.population,
        .pid = pid,
        .role = role,
        .memory = snapshot,
        .uss_bytes = try snapshot.ussBytes(),
        .shared_mapped_bytes = try snapshot.sharedBytes(),
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
    if (pid == 0 or !std.mem.startsWith(u8, scope, "/sys/fs/cgroup/"))
        return error.InvalidScopeMembership;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/cgroup", .{pid});
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var buffer: [4097]u8 = undefined;
    const count = try file.readAll(&buffer);
    if (count == buffer.len) return error.InvalidScopeMembership;
    const relative = scope["/sys/fs/cgroup".len..];
    var lines = std.mem.tokenizeScalar(u8, buffer[0..count], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::")) continue;
        const member = line[3..];
        return std.mem.eql(u8, member, relative) or
            (member.len > relative.len and member[relative.len] == '/' and
                std.mem.startsWith(u8, member, relative));
    }
    return error.InvalidScopeMembership;
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
    workload: Workload,
    ready: protocol.Ready,
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
        workload: Workload,
    ) !Session {
        const scope = try std.fmt.allocPrint(
            allocator,
            "/sys/fs/cgroup/collo-dev/collo-bench-{d}-{d}",
            .{ std.os.linux.getpid(), try process.monotonicNowNs() },
        );
        var owns_scope = true;
        errdefer if (owns_scope) allocator.free(scope);
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
        try environment.put(Workload.environment_name, @tagName(workload));
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
            .workload = workload,
            .ready = undefined,
            .live = true,
        };
        owns_scope = false;
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
        if (result.ready.port == 0 or result.ready.zygote_pid == result.server_pid or
            result.ready.gateway_pid == result.server_pid or
            result.ready.gateway_pid == result.ready.zygote_pid)
            return error.InvalidRuntimeIdentity;
        if (result.ready.workload != workload) return error.WorkloadMismatch;
        try requireSamplerExcluded(scope);
        try requireMembership(result.server_pid, main_path);
        try requireMembership(result.ready.zygote_pid, main_path);
        try requireMembership(result.ready.gateway_pid, main_path);
        if (protocol.collo_bench_client_open(result.ready.port, protocol.hostname, &result.client) != 0)
            return error.HttpPreflightFailed;
        try emit(.{
            .schema = "collo.microbench.v1",
            .kind = "runtime_metadata",
            .mode = @tagName(mode),
            .scope = scope,
            .server_pid = result.server_pid,
            .artifact_topology = @tagName(result.ready.artifact_topology),
            .resident_pack_count = result.ready.resident_pack_count,
        });
        return result;
    }

    fn get(self: *Session, route: u32) !protocol.ClientReply {
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}{d}", .{ protocol.route_prefix, route });
        const expected_body = self.workload.expectedBody();
        var result: protocol.ClientReply = undefined;
        if (protocol.collo_bench_client_get(self.client.?, path, expected_body.ptr, &result) != 0)
            return error.HttpRequestFailed;
        // Client streams are odd and increase (RFC 9113 §5.1.1), so a reply on
        // any other stream id cannot belong to this request.
        if (result.status != 200 or result.body_len != expected_body.len or
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
    std.debug.assert(bounds.minimum <= bounds.default);
    std.debug.assert(bounds.default <= bounds.maximum);
    const text = std.posix.getenv(name) orelse return bounds.default;
    const value = try std.fmt.parseUnsigned(usize, text, 10);
    if (value < bounds.minimum or value > bounds.maximum) return error.InvalidBenchmarkSetting;
    return value;
}

/// Writes `value` as one JSON line on stdout, the stream `run.sh` validates.
pub fn emit(value: anytype) !void {
    try protocol.writeRecord(std.fs.File.stdout(), value);
}
