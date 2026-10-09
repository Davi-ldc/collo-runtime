//! Proves the runtime stands on its own and prices what that costs: one warm
//! zygote, N workers born from it by `clone3` with the JSC heap inherited
//! copy-on-write, and every worker answering a request whose body is checked
//! byte for byte. This process is the host, and the host module is the only
//! thing between it and the workers: there is no server and no gateway. The
//! bench builds the route's module pack itself, and egress rides a session
//! nobody serves, so `fetch` fails closed. A run that completes
//! with exit 0 is one in which every response was byte for byte the expected
//! one; any divergence aborts with a nonzero exit and prints the body
//! received. Numbers already printed by earlier rounds prove nothing on
//! their own.
//!
//! Three scenarios, each printed as a human block plus one JSON line:
//! `zygote_spawn` (spawn-to-serving wall and the idle zygote's memory),
//! `worker_cold_start` per worker count and round (fork-to-ready and
//! first-response percentiles; the set's PSS, private-dirty and shared-clean
//! totals at ready and after the first response, plus the PSS and
//! private-dirty each worker adds over the idle zygote, which is the
//! copy-on-write yield), and `warm_sequential` (back-to-back requests on
//! one warm worker). Memory is reported in KiB in the JSON and MiB in the
//! human block.
//!
//! Knobs: COLLO_BENCH_WORKER_COUNTS (default 1,4,16), COLLO_BENCH_ROUNDS
//! (default 3), COLLO_BENCH_WARM_REQUESTS (default 200). COLLO_BENCH_EXECUTABLE
//! selects an absolute Collo executable; otherwise the build-time path is used.
//! Workers are born in leaves under COLLO_BENCH_CGROUP_ROOT, else
//! COLLO_TEST_WORKER_CGROUP_ROOT, else COLLO_WORKER_CGROUP_ROOT, else under a
//! subtree carved out of this process's own delegated cgroup.

const std = @import("std");
const host = @import("collo_host");
const ipc = @import("collo_ipc");
const zygote = @import("collo_zygote");
const process = @import("collo_os").process;
const process_options = @import("collo_process_options");
const bench_common = @import("common.zig");
const bench_metadata = @import("metadata.zig");
const proc_memory = @import("proc_memory.zig");

/// The box every worker boots in. Stated, not defaulted: per-worker numbers
/// only compare across runs while the workers keep booting under the same
/// limits.
const worker_memory_limit_bytes: u64 = 512 * 1024 * 1024;
const worker_cpu_max_cores: u32 = 1;
/// What the boot token beside every worker's session carries, since a launch
/// that sends a session sends a boot token with it (`host.launch.LaunchEgress`). No
/// gateway serves the session, so nothing ever verifies the token.
const bench_boot_egress: host.launch.BootEgress = .{
    .key = .{ .bytes = @splat(0x5a) },
    .session_id = 1,
    .policy_id = 0,
    .budget = 1,
};
/// Deadline the worker enforces on each request.
const request_budget_ns: u64 = 30 * std.time.ns_per_s;
/// The host outlives the worker's deadline by this margin, so a request that
/// times out surfaces as the worker's own completion status instead of the
/// host giving up first with `ResponseNotFinalized`.
const response_wall_grace_ms: u32 = 5_000;
const response_wall_ms: u32 =
    @as(u32, @intCast(request_budget_ns / std.time.ns_per_ms)) + response_wall_grace_ms;
/// Caps on one response read. The entry answers with a few dozen body bytes
/// and a handful of headers, so a read that trips either cap is a bench
/// failure, never a legitimate response.
const max_response_body_bytes: usize = 1024 * 1024;
const max_response_headers_bytes: usize = 64 * 1024;
/// PSS comes from `smaps_rollup`, which walks the page tables at read time;
/// the pause lets a freshly forked or freshly served worker finish touching
/// pages before the walk, so a reading is a resting state, not a transient.
/// A measurement pause only: every launch and request is complete before it
/// starts, and nothing waits on it for correctness.
const memory_settle_ns: u64 = 100 * std.time.ns_per_ms;
/// Bounds on the environment knobs, so a typo cannot fork the machine flat.
const worker_count_max: usize = 256;
const rounds_max: usize = 64;
const warm_requests_max: usize = 100_000;
const default_worker_counts = [_]usize{ 1, 4, 16 };
const default_rounds: usize = 3;
const default_warm_requests: usize = 200;
/// Streams multiplex requests on one ingress connection; this host keeps one
/// request in flight per worker, and the request id is the identity the
/// completion record is matched on.
const stream_id: u32 = 1;
const authority = "localhost";
const request_path_max: usize = 64;
const expected_body_max: usize = 128;

const entry_specifier = ipc.module_pack.route_specifier_prefix ++ "bench/host_lifecycle.js";
/// Echoes method and pathname, so the body proves the handler ran for this
/// very request rather than that some worker answered something.
const entry_source =
    \\export default function handle(request) {
    \\  const url = new URL(request.url);
    \\  return new Response(`host_lifecycle ${request.method} ${url.pathname}\n`, {
    \\    headers: { "content-type": "text/plain" },
    \\  });
    \\}
;
const expected_body_prefix = "host_lifecycle GET ";
const expected_content_type = "content-type: text/plain";

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    try bench_metadata.print(allocator, "host_lifecycle");

    const executable_path = try resolveExecutable(allocator);
    defer allocator.free(executable_path);

    const settings = try Settings.fromEnv(allocator);
    defer settings.deinit(allocator);

    const pack_fd = try host.dispatch.createModulePackFd(allocator, entry_specifier, entry_source);
    defer std.posix.close(pack_fd);

    // Every worker is born inside its own leaf of this subtree; without a
    // delegated subtree there is no worker to measure.
    var cgroup_root = try host.WorkerCgroupRoot.init(allocator, cgroupPlacement());
    defer cgroup_root.deinit(allocator);

    // The machine before anything of ours exists: the zygote's own
    // system-wide cost is measured over this reading.
    const system_idle = try proc_memory.readSystem(allocator);

    // The spawn returns on the zygote's ready message, after the warmup
    // corpus ran, so this wall is spawn-to-serving.
    var spawn_timer = try std.time.Timer.start();
    var spawned = try zygote.host_client.spawnZygote(.{
        .executable_path = executable_path,
        .warmup_corpus = true,
    });
    defer spawned.deinit();
    const spawn_to_serving_ns = spawn_timer.read();
    std.debug.print("{f}\n", .{std.json.fmt(.{
        .bench = "host_lifecycle",
        .scenario = "executable",
        .path = executable_path,
    }, .{})});
    std.Thread.sleep(memory_settle_ns);
    const zygote_idle = try proc_memory.readProcess(allocator, spawned.pid);
    const system_zygote = try proc_memory.readSystem(allocator);
    printZygoteSpawn(spawn_to_serving_ns, zygote_idle, SystemDelta.between(system_zygote, system_idle));

    var ids = Ids{};
    const ctx = Context{
        .allocator = allocator,
        .spawned = &spawned,
        .cgroup_root = &cgroup_root,
        .ids = &ids,
        .pack_fd = pack_fd,
        .system_zygote = system_zygote,
    };
    for (settings.worker_counts) |worker_count| {
        var round: usize = 1;
        while (round <= settings.rounds) : (round += 1)
            try runColdStartRound(ctx, zygote_idle, worker_count, round);
    }
    try runWarmSequential(ctx, settings.warm_requests);
}

fn resolveExecutable(allocator: std.mem.Allocator) ![]u8 {
    const path = std.posix.getenv("COLLO_BENCH_EXECUTABLE") orelse
        process_options.collo_executable_path;
    if (!std.fs.path.isAbsolute(path))
        return error.BenchmarkExecutableMustBeAbsolute;
    return std.fs.cwd().realpathAlloc(allocator, path);
}

const Settings = struct {
    worker_counts: []usize,
    rounds: usize,
    warm_requests: usize,

    fn fromEnv(allocator: std.mem.Allocator) !Settings {
        const worker_counts = try bench_common.parseCommaSeparatedUsizeList(
            allocator,
            "COLLO_BENCH_WORKER_COUNTS",
            &default_worker_counts,
        );
        errdefer allocator.free(worker_counts);
        for (worker_counts) |count| {
            if (count > worker_count_max)
                return error.InvalidBenchSetting;
        }
        return .{
            .worker_counts = worker_counts,
            .rounds = try envUsize("COLLO_BENCH_ROUNDS", default_rounds, rounds_max),
            .warm_requests = try envUsize(
                "COLLO_BENCH_WARM_REQUESTS",
                default_warm_requests,
                warm_requests_max,
            ),
        };
    }

    fn deinit(self: Settings, allocator: std.mem.Allocator) void {
        allocator.free(self.worker_counts);
    }
};

/// Identities this host hands out. A fork job id names a cgroup leaf and a
/// request id names a completion record, so neither is ever reused.
const Ids = struct {
    next_fork_job_id: u64 = 1,
    next_request_id: u64 = 1,

    fn forkJobId(self: *Ids) u64 {
        defer self.next_fork_job_id += 1;
        return self.next_fork_job_id;
    }

    fn requestId(self: *Ids) u64 {
        defer self.next_request_id += 1;
        return self.next_request_id;
    }
};

const Worker = struct {
    handle: host.WorkerHandle,
    /// Host ends of the egress session. The worker holds dups and polls the
    /// session's liveness fd, so these stay open for as long as the worker
    /// lives, and the memory read is of a worker with a live session, as in
    /// production.
    egress: ipc.egress_shared.SessionFds,
    fork_to_ready_ns: u64,
    first_response_ns: u64 = 0,

    fn deinit(self: *Worker) void {
        self.handle.deinit();
        self.egress.deinit();
        self.* = undefined;
    }
};

/// What every scenario needs from the host: the zygote that forks, the
/// subtree the leaves go under, the identities handed out, and the entry
/// pack every worker boots with. One per run; scenarios share it.
const Context = struct {
    allocator: std.mem.Allocator,
    spawned: *zygote.host_client.SpawnedZygote,
    cgroup_root: *host.WorkerCgroupRoot,
    ids: *Ids,
    pack_fd: std.posix.fd_t,
    /// The machine with the idle zygote and nothing else of ours: every
    /// system-wide increment a round reports is over this reading.
    system_zygote: proc_memory.SystemMemory,
};

/// What a set of processes cost the whole machine between two
/// /proc/meminfo readings, signed because MemAvailable also moves with
/// page-cache activity that is not ours. `anon` plus `slab` plus
/// `page_tables` is the part no cache heuristic can hide: process heaps,
/// kernel objects (namespaces, cgroups, rings) and the page tables of the
/// copy-on-write mappings.
const SystemDelta = struct {
    used_kib: i64,
    anon_kib: i64,
    slab_kib: i64,
    page_tables_kib: i64,
    kernel_stack_kib: i64,

    fn between(after: proc_memory.SystemMemory, before: proc_memory.SystemMemory) SystemDelta {
        return .{
            .used_kib = signedDelta(after.used_kib, before.used_kib),
            .anon_kib = signedDelta(after.anon_kib, before.anon_kib),
            .slab_kib = signedDelta(after.slab_kib, before.slab_kib),
            .page_tables_kib = signedDelta(after.page_tables_kib, before.page_tables_kib),
            .kernel_stack_kib = signedDelta(after.kernel_stack_kib, before.kernel_stack_kib),
        };
    }

    const fields = [_]struct { name: []const u8, field: []const u8 }{
        .{ .name = "used", .field = "used_kib" },
        .{ .name = "anon", .field = "anon_kib" },
        .{ .name = "slab", .field = "slab_kib" },
        .{ .name = "page_tables", .field = "page_tables_kib" },
        .{ .name = "kernel_stack", .field = "kernel_stack_kib" },
    };
};

fn printSystemDeltaLines(moment: []const u8, delta: SystemDelta, divisor: usize) void {
    inline for (SystemDelta.fields) |entry| {
        const value = @field(delta, entry.field);
        std.debug.print("\n  system_{s}_added_{s}_mib: ", .{ entry.name, moment });
        printSignedMibValue(value);
        if (divisor > 1) {
            std.debug.print("\n  system_{s}_added_per_worker_{s}_mib: ", .{ entry.name, moment });
            printSignedMibValue(divSigned(value, divisor));
        }
    }
}

fn printJsonSystemDelta(moment: []const u8, delta: SystemDelta, divisor: usize) void {
    inline for (SystemDelta.fields) |entry| {
        const value = @field(delta, entry.field);
        std.debug.print(",\"system_{s}_added_{s}_kib\":{d}", .{ entry.name, moment, value });
        if (divisor > 1) {
            std.debug.print(
                ",\"system_{s}_added_per_worker_{s}_kib\":{d}",
                .{ entry.name, moment, divSigned(value, divisor) },
            );
        }
    }
}

fn runColdStartRound(
    ctx: Context,
    zygote_idle: proc_memory.Metrics,
    worker_count: usize,
    round: usize,
) !void {
    std.debug.assert(worker_count != 0);
    std.debug.assert(worker_count <= worker_count_max);
    const workers = try ctx.allocator.alloc(Worker, worker_count);
    defer ctx.allocator.free(workers);
    var launched: usize = 0;
    defer {
        for (workers[0..launched]) |*worker|
            worker.deinit();
    }

    for (workers) |*worker| {
        worker.* = try launchWorker(ctx);
        launched += 1;
    }
    std.Thread.sleep(memory_settle_ns);
    const ready_set = try measureSet(ctx, workers);
    const system_ready = try proc_memory.readSystem(ctx.allocator);

    for (workers, 0..) |*worker, index| {
        var path_buffer: [request_path_max]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/cold/{d}/{d}", .{ round, index });
        worker.first_response_ns = try requestChecked(ctx, &worker.handle, path);
    }
    std.Thread.sleep(memory_settle_ns);
    const hello_set = try measureSet(ctx, workers);
    const system_hello = try proc_memory.readSystem(ctx.allocator);

    const fork_samples = try ctx.allocator.alloc(u64, workers.len);
    defer ctx.allocator.free(fork_samples);
    const response_samples = try ctx.allocator.alloc(u64, workers.len);
    defer ctx.allocator.free(response_samples);
    for (workers, fork_samples, response_samples) |worker, *fork_sample, *response_sample| {
        fork_sample.* = worker.fork_to_ready_ns;
        response_sample.* = worker.first_response_ns;
    }
    std.mem.sort(u64, fork_samples, {}, std.sort.asc(u64));
    std.mem.sort(u64, response_samples, {}, std.sort.asc(u64));

    printColdStart(.{
        .worker_count = worker_count,
        .round = round,
        .fork_to_ready = Percentiles.ofSorted(fork_samples),
        .first_response = Percentiles.ofSorted(response_samples),
        .zygote_idle = zygote_idle,
        .ready_added = SetIncrement.perWorker(ready_set, zygote_idle, worker_count),
        .hello_added = SetIncrement.perWorker(hello_set, zygote_idle, worker_count),
        .ready_set_total = ready_set.total(),
        .hello_set_total = hello_set.total(),
        .system_at_ready = SystemDelta.between(system_ready, ctx.system_zygote),
        .system_after_hello = SystemDelta.between(system_hello, ctx.system_zygote),
    });
}

/// K back-to-back requests on one warm worker. Each sample runs from
/// `sendRequest` to `readResponse` returning, and requests per second is
/// over the whole loop, so both carry the host's own share (dispatch work,
/// request assembly) on top of the worker's.
fn runWarmSequential(ctx: Context, request_count: usize) !void {
    std.debug.assert(request_count != 0);
    std.debug.assert(request_count <= warm_requests_max);
    var worker = try launchWorker(ctx);
    defer worker.deinit();

    // The first request on a worker is a cold first response (the cold-start
    // scenario already prices it); it primes the worker and is not a sample.
    _ = try requestChecked(ctx, &worker.handle, "/warm/prime");

    const samples = try ctx.allocator.alloc(u64, request_count);
    defer ctx.allocator.free(samples);
    var timer = try std.time.Timer.start();
    for (samples, 0..) |*sample, index| {
        var path_buffer: [request_path_max]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/warm/{d}", .{index});
        sample.* = try requestChecked(ctx, &worker.handle, path);
    }
    const total_ns = timer.read();
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    const requests_per_second = if (total_ns == 0)
        0
    else
        (@as(u64, request_count) * std.time.ns_per_s) / total_ns;
    printWarmSequential(request_count, Percentiles.ofSorted(samples), requests_per_second);
}

/// The production launch minus the server: leaf first so the child is born
/// inside it, fork, then WorkerInit with the entry pack as the route. The
/// entry is evaluated before ready, so the first request never waits on
/// module work.
fn launchWorker(ctx: Context) !Worker {
    var timer = try std.time.Timer.start();
    const fork_job_id = ctx.ids.forkJobId();
    const leaf_fd = try ctx.cgroup_root.createWorkerDir(fork_job_id, .{
        .memory_limit_bytes = worker_memory_limit_bytes,
    });
    var leaf_owned = true;
    errdefer if (leaf_owned) {
        std.posix.close(leaf_fd);
        ctx.cgroup_root.removeWorkerDir(fork_job_id);
    };
    var forked = try zygote.host_client.requestForkWithJobId(ctx.spawned, fork_job_id, leaf_fd);
    forked.fork_job_id = fork_job_id;
    forked.cgroup_dir_fd = leaf_fd;
    leaf_owned = false;
    var forked_owned = true;
    errdefer if (forked_owned) host.terminateForkedWorkerBestEffort(&forked);

    // The session holds its own copy of every wake descriptor, so the set
    // closes once the session is built.
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var egress = try ipc.egress_shared.createSessionForWorker(&wake_set);
    errdefer egress.deinit();
    const handle = try host.runToReady(
        ctx.allocator,
        ctx.spawned,
        &forked,
        worker_memory_limit_bytes,
        .{
            .cpu_max_cores = worker_cpu_max_cores,
            .egress = .{ .attached = .{
                .shared_fds = egress.rawForWorker(),
                .boot = bench_boot_egress,
            } },
            .route_entry = .{ .fd = ctx.pack_fd, .specifier = entry_specifier },
        },
    );
    // The launch took every fd the fork reply carried.
    forked_owned = false;
    forked.deinit();
    return .{
        .handle = handle,
        .egress = egress,
        .fork_to_ready_ns = timer.read(),
    };
}

/// One GET to `path`, timed from the send to the response in hand. The body
/// is checked byte for byte against what the entry must have produced for
/// this path; the content-type header by prefix.
fn requestChecked(ctx: Context, handle: *host.WorkerHandle, path: []const u8) !u64 {
    const request_id = ctx.ids.requestId();
    var expected_buffer: [expected_body_max]u8 = undefined;
    const expected_body = try std.fmt.bufPrint(
        &expected_buffer,
        expected_body_prefix ++ "{s}\n",
        .{path},
    );

    // The worker rejects a request without a host header, as any ingress
    // would; a local run is addressed to `localhost`.
    const request = host.dispatch.Request{
        .method = "GET",
        .path = path,
        .headers = &.{.{ .name = "host", .value = authority }},
    };
    var dispatch = try host.dispatch.initDispatchWork(ctx.allocator, .{
        .request_id = request_id,
        .route_entry_specifier = entry_specifier,
        .deadline_monotonic_ns = (try process.monotonicNowNs()) + request_budget_ns,
        .authority = authority,
        .request = request,
    });
    defer dispatch.deinit();

    var timer = try std.time.Timer.start();
    try host.dispatch.sendRequest(handle.control_fd, &dispatch, stream_id, request);
    var response = try readOne(ctx.allocator, handle, request_id);
    defer response.deinit();
    const elapsed_ns = timer.read();

    try checkResponse(&response, expected_body, path);
    return elapsed_ns;
}

/// The one place the response read's budgets live.
fn readOne(
    allocator: std.mem.Allocator,
    handle: *host.WorkerHandle,
    request_id: u64,
) !host.dispatch.Response {
    return host.dispatch.readResponse(allocator, handle.completionChannels(), request_id, .{
        .wall_ms = response_wall_ms,
        .max_body_bytes = max_response_body_bytes,
        .max_headers_bytes = max_response_headers_bytes,
    });
}

/// Completion status, HTTP status and body are exact; the content-type
/// header is matched by prefix, so a charset parameter would pass.
fn checkResponse(
    response: *const host.dispatch.Response,
    expected_body: []const u8,
    path: []const u8,
) !void {
    if (response.doneStatus() != .ok) {
        std.debug.print("response for {s} finished with status {s}\n", .{
            path,
            @tagName(response.doneStatus()),
        });
        return error.UnexpectedResponse;
    }
    if (response.status != 200) {
        std.debug.print("response for {s} has HTTP status {d}\n", .{ path, response.status });
        return error.UnexpectedResponse;
    }
    if (std.mem.indexOf(u8, response.headers_wire, expected_content_type) == null) {
        std.debug.print("response for {s} lacks '{s}' in headers:\n{s}\n", .{
            path,
            expected_content_type,
            response.headers_wire,
        });
        return error.UnexpectedResponse;
    }
    if (!std.mem.eql(u8, response.body, expected_body)) {
        std.debug.print("response body for {s} differs\nexpected: {s}received: {s}\n", .{
            path,
            expected_body,
            response.body,
        });
        return error.UnexpectedResponse;
    }
}

/// Memory of the set under measurement: the zygote plus every worker it
/// forked. This process is left out; it is the host, not the product.
const SetMemory = struct {
    zygote_process: proc_memory.Metrics,
    workers: proc_memory.Metrics,

    fn total(self: SetMemory) proc_memory.Metrics {
        return self.zygote_process.add(self.workers);
    }
};

fn measureSet(ctx: Context, workers: []const Worker) !SetMemory {
    std.debug.assert(workers.len <= worker_count_max);
    var worker_sum = proc_memory.Metrics{};
    for (workers) |worker|
        worker_sum = worker_sum.add(try proc_memory.readProcess(ctx.allocator, worker.handle.pid));
    return .{
        .zygote_process = try proc_memory.readProcess(ctx.allocator, ctx.spawned.pid),
        .workers = worker_sum,
    };
}

/// What one worker adds to the set over the idle zygote. Signed because the
/// zygote's own PSS drops as workers start sharing its pages.
const SetIncrement = struct {
    pss_kib: i64,
    private_dirty_kib: i64,

    fn perWorker(
        measured: SetMemory,
        zygote_idle: proc_memory.Metrics,
        worker_count: usize,
    ) SetIncrement {
        std.debug.assert(worker_count != 0);
        const measured_total = measured.total();
        return .{
            .pss_kib = divSigned(
                signedDelta(measured_total.pss_kib, zygote_idle.pss_kib),
                worker_count,
            ),
            .private_dirty_kib = divSigned(
                signedDelta(measured_total.private_dirty_kib, zygote_idle.private_dirty_kib),
                worker_count,
            ),
        };
    }
};

const Percentiles = struct {
    p50: u64,
    p95: u64,
    p99: u64,
    max: u64,

    fn ofSorted(sorted: []const u64) Percentiles {
        std.debug.assert(sorted.len != 0);
        return .{
            .p50 = bench_common.percentileNearestRank(u64, sorted, 50),
            .p95 = bench_common.percentileNearestRank(u64, sorted, 95),
            .p99 = bench_common.percentileNearestRank(u64, sorted, 99),
            .max = sorted[sorted.len - 1],
        };
    }
};

/// The WSL runner exports COLLO_TEST_WORKER_CGROUP_ROOT and `collo serve`
/// reads COLLO_WORKER_CGROUP_ROOT, each naming a process-free delegated
/// directory. Without one, the subtree is carved out of this process's own
/// delegated cgroup, as `collo serve` does.
fn cgroupPlacement() host.cgroup_root.Placement {
    inline for (.{
        "COLLO_BENCH_CGROUP_ROOT",
        "COLLO_TEST_WORKER_CGROUP_ROOT",
        "COLLO_WORKER_CGROUP_ROOT",
    }) |name| {
        if (std.posix.getenv(name)) |value| {
            if (value.len != 0)
                return .{ .env_root = value };
        }
    }
    return .delegated;
}

fn envUsize(name: []const u8, default: usize, max: usize) !usize {
    const raw = std.posix.getenv(name) orelse return default;
    const parsed = try std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10);
    if (parsed == 0)
        return error.InvalidBenchSetting;
    if (parsed > max)
        return error.InvalidBenchSetting;
    return parsed;
}

fn printZygoteSpawn(
    spawn_to_serving_ns: u64,
    zygote_idle: proc_memory.Metrics,
    system: SystemDelta,
) void {
    std.debug.print(
        \\host_lifecycle
        \\  scenario: zygote_spawn
    , .{});
    printMsLine("spawn_to_serving", spawn_to_serving_ns);
    printMibLine("zygote_pss", zygote_idle.pss_kib);
    printMibLine("zygote_rss", zygote_idle.rss_kib);
    printMibLine("zygote_private_dirty", zygote_idle.private_dirty_kib);
    printSystemDeltaLines("by_zygote", system, 1);
    std.debug.print("\n", .{});

    std.debug.print("{{\"bench\":\"host_lifecycle\",\"scenario\":\"zygote_spawn\"", .{});
    printJsonNumber("spawn_to_serving_ns", @intCast(spawn_to_serving_ns));
    printJsonNumber("zygote_pss_kib", @intCast(zygote_idle.pss_kib));
    printJsonNumber("zygote_rss_kib", @intCast(zygote_idle.rss_kib));
    printJsonNumber("zygote_private_dirty_kib", @intCast(zygote_idle.private_dirty_kib));
    printJsonSystemDelta("by_zygote", system, 1);
    std.debug.print("}}\n", .{});
}

const ColdStartReport = struct {
    worker_count: usize,
    round: usize,
    fork_to_ready: Percentiles,
    first_response: Percentiles,
    /// The baseline every per-worker increment is measured against.
    zygote_idle: proc_memory.Metrics,
    ready_added: SetIncrement,
    hello_added: SetIncrement,
    ready_set_total: proc_memory.Metrics,
    hello_set_total: proc_memory.Metrics,
    /// What the whole machine gave up for the set, over the idle zygote.
    system_at_ready: SystemDelta,
    system_after_hello: SystemDelta,
};

fn printColdStart(report: ColdStartReport) void {
    std.debug.print(
        \\host_lifecycle
        \\  scenario: worker_cold_start
        \\  worker_count: {d}
        \\  round: {d}
    , .{ report.worker_count, report.round });
    printPercentileLines("fork_to_ready", report.fork_to_ready);
    printPercentileLines("first_response", report.first_response);
    std.debug.print("\n  baseline: idle zygote (pss ", .{});
    printMibValue(report.zygote_idle.pss_kib);
    std.debug.print(" MiB, private_dirty ", .{});
    printMibValue(report.zygote_idle.private_dirty_kib);
    std.debug.print(" MiB)", .{});
    printIncrementLines("ready_added", report.ready_added);
    printIncrementLines("hello_added", report.hello_added);
    printSetTotalLines("at_ready", report.ready_set_total);
    printSetTotalLines("after_hello", report.hello_set_total);
    printSystemDeltaLines("at_ready", report.system_at_ready, report.worker_count);
    printSystemDeltaLines("after_hello", report.system_after_hello, report.worker_count);
    std.debug.print("\n", .{});

    std.debug.print(
        "{{\"bench\":\"host_lifecycle\",\"scenario\":\"worker_cold_start\"" ++
            ",\"worker_count\":{d},\"round\":{d}",
        .{ report.worker_count, report.round },
    );
    printJsonPercentiles("fork_to_ready_ns", report.fork_to_ready);
    printJsonPercentiles("first_response_ns", report.first_response);
    printJsonNumber("zygote_idle_pss_kib", @intCast(report.zygote_idle.pss_kib));
    printJsonNumber(
        "zygote_idle_private_dirty_kib",
        @intCast(report.zygote_idle.private_dirty_kib),
    );
    printJsonIncrement("ready_added", report.ready_added);
    printJsonIncrement("hello_added", report.hello_added);
    printJsonSetTotal("at_ready", report.ready_set_total);
    printJsonSetTotal("after_hello", report.hello_set_total);
    printJsonSystemDelta("at_ready", report.system_at_ready, report.worker_count);
    printJsonSystemDelta("after_hello", report.system_after_hello, report.worker_count);
    std.debug.print("}}\n", .{});
}

fn printIncrementLines(label: []const u8, added: SetIncrement) void {
    std.debug.print("\n  {s}_pss_per_worker_mib: ", .{label});
    printSignedMibValue(added.pss_kib);
    std.debug.print("\n  {s}_private_dirty_per_worker_mib: ", .{label});
    printSignedMibValue(added.private_dirty_kib);
}

fn printJsonIncrement(label: []const u8, added: SetIncrement) void {
    std.debug.print(",\"{s}_pss_per_worker_kib\":{d}", .{ label, added.pss_kib });
    std.debug.print(
        ",\"{s}_private_dirty_per_worker_kib\":{d}",
        .{ label, added.private_dirty_kib },
    );
}

/// The set's PSS, private-dirty and shared-clean at one moment: shared-clean
/// is the copy-on-write complement of private-dirty, the part of the zygote
/// the workers still share untouched.
fn printSetTotalLines(moment: []const u8, total: proc_memory.Metrics) void {
    std.debug.print("\n  set_pss_{s}_mib: ", .{moment});
    printMibValue(total.pss_kib);
    std.debug.print("\n  set_private_dirty_{s}_mib: ", .{moment});
    printMibValue(total.private_dirty_kib);
    std.debug.print("\n  set_shared_clean_{s}_mib: ", .{moment});
    printMibValue(total.shared_clean_kib);
}

fn printJsonSetTotal(moment: []const u8, total: proc_memory.Metrics) void {
    std.debug.print(",\"set_pss_{s}_kib\":{d}", .{ moment, total.pss_kib });
    std.debug.print(",\"set_private_dirty_{s}_kib\":{d}", .{ moment, total.private_dirty_kib });
    std.debug.print(",\"set_shared_clean_{s}_kib\":{d}", .{ moment, total.shared_clean_kib });
}

fn printPercentileLines(label: []const u8, percentiles: Percentiles) void {
    std.debug.print("\n  {s}_p50_ms: ", .{label});
    printMsValue(percentiles.p50);
    std.debug.print("\n  {s}_p95_ms: ", .{label});
    printMsValue(percentiles.p95);
    std.debug.print("\n  {s}_p99_ms: ", .{label});
    printMsValue(percentiles.p99);
    std.debug.print("\n  {s}_max_ms: ", .{label});
    printMsValue(percentiles.max);
}

fn printJsonPercentiles(label: []const u8, percentiles: Percentiles) void {
    std.debug.print(",\"{s}_p50\":{d}", .{ label, percentiles.p50 });
    std.debug.print(",\"{s}_p95\":{d}", .{ label, percentiles.p95 });
    std.debug.print(",\"{s}_p99\":{d}", .{ label, percentiles.p99 });
    std.debug.print(",\"{s}_max\":{d}", .{ label, percentiles.max });
}

fn printWarmSequential(request_count: usize, latency: Percentiles, requests_per_second: u64) void {
    std.debug.print(
        \\host_lifecycle
        \\  scenario: warm_sequential
        \\  requests: {d}
    , .{request_count});
    printPercentileLines("latency", latency);
    std.debug.print("\n  requests_per_second: {d}\n", .{requests_per_second});

    std.debug.print(
        "{{\"bench\":\"host_lifecycle\",\"scenario\":\"warm_sequential\",\"requests\":{d}",
        .{request_count},
    );
    printJsonPercentiles("latency_ns", latency);
    printJsonNumber("requests_per_second", @intCast(requests_per_second));
    std.debug.print("}}\n", .{});
}

fn printJsonNumber(name: []const u8, value: i64) void {
    std.debug.print(",\"{s}\":{d}", .{ name, value });
}

fn printMsLine(label: []const u8, ns: u64) void {
    std.debug.print("\n  {s}_ms: ", .{label});
    printMsValue(ns);
}

/// Nanoseconds as milliseconds with microsecond resolution.
fn printMsValue(ns: u64) void {
    std.debug.print("{d}.{d:0>3}", .{
        ns / std.time.ns_per_ms,
        (ns % std.time.ns_per_ms) / std.time.ns_per_us,
    });
}

fn printMibLine(label: []const u8, kib: u64) void {
    std.debug.print("\n  {s}_mib: ", .{label});
    printMibValue(kib);
}

fn printSignedMibValue(kib: i64) void {
    if (kib < 0) {
        std.debug.print("-", .{});
        printMibValue(@intCast(-kib));
    } else {
        printMibValue(@intCast(kib));
    }
}

/// KiB as MiB with two decimals, rounded to nearest.
fn printMibValue(kib: u64) void {
    const scaled = (kib * 100 + 512) / 1024;
    std.debug.print("{d}.{d:0>2}", .{ scaled / 100, scaled % 100 });
}

fn signedDelta(after: u64, before: u64) i64 {
    return @as(i64, @intCast(after)) - @as(i64, @intCast(before));
}

fn divSigned(value: i64, divisor: usize) i64 {
    return @divTrunc(value, @as(i64, @intCast(divisor)));
}
