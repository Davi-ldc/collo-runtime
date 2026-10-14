//! Shared construction kit for supervisor tests, run on the test thread: a
//! supervisor over routes and an analytics sink of its own, worker records
//! whose handles can actually be torn down, cgroup leaves that name nothing
//! or hold the files a test writes (`LeafDir`), a worker page a test writes
//! as the worker would (`WorkerPage`), the publish a launch makes into a
//! definition's pool, the egress attachment a gateway hands a launch, and a
//! temporary analytics directory whose `workers.jsonl` a test reads back.
//!
//! The routes come from a configuration of `definition_names.len` worker
//! definitions, one route each, built from entry modules written to a
//! temporary directory, so the supervisor reads real names, limits and
//! sealed packs. No zygote runs: `inert_zygote` stands in, and nothing here
//! forks a worker through it.
//!
//! The build compiles this file as module `supervisor_fixture` twice, once
//! against the JSC-linked module set and once against the stub set of the
//! JSC-free suites (`createSupervisorFixtureModule` in
//! `runtime/build/tests.zig`). It may import only the modules that function
//! gives it, and nothing here may need the engine.

const std = @import("std");
const host = @import("collo_host");
const supervision = @import("collo_server_supervisor");
const analytics = @import("collo_server_analytics");
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const lifecycle = @import("collo_server_lifecycle");
const zygote_mod = @import("collo_zygote");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const os_fd = @import("collo_os").fd;
const worker_shared_page = @import("collo_worker_state").page;

const Supervisor = supervision.Supervisor;
const worker_table = supervision.worker_table;
const WorkerRecord = worker_table.Record;
const WorkerHandle = host.WorkerHandle;

/// The worker definitions of the fixture configuration, in definition-index
/// order. Each has one route, `/<name>/*`.
pub const definition_names = [_][]const u8{ "demo", "beta", "gamma" };

/// The route pattern of each fixture definition, in the same order.
pub const route_patterns = [_][]const u8{ "/demo/*", "/beta/*", "/gamma/*" };

/// The definition `newWorker` and the supervisor tests use unless they ask
/// for another.
pub const default_definition: config.DefinitionIndex = 0;

const entry_source = "export default { fetch() { return new Response(\"ok\"); } };\n";

/// Stand-in for the zygote a production supervisor spawns. No test asks a
/// zygote to fork, and no path a test drives reads this; the invalid
/// descriptors mean a path that started to would fail on EBADF rather than on
/// undefined memory. Shared because it is never written; a per-supervisor copy
/// would only add an address the fixture has to keep stable.
var inert_zygote = zygote_mod.host_client.SpawnedZygote{
    .pid = 0,
    .pidfd = -1,
    .control_fd = null,
    .trace_read_fd = null,
    .trace_write_fd = null,
};

/// The settings every fixture definition gets, through the configuration's
/// top-level `settings`.
pub const RoutesOptions = struct {
    /// Requests one worker runs at once: the pool's slots per worker.
    concurrency: u8 = 2,
    /// Each request's deadline.
    timeout_ms: u32 = 30_000,
    memory_mib: u32 = 128,
    /// Each request's CPU budget, or none.
    cpu_ms: ?u32 = null,
    /// Whether each definition, in `definition_names` order, keeps the
    /// top-level `network` grant of any public host; one without it drops the
    /// grant with an empty allow list, so its workers get no egress session.
    granted: [definition_names.len]bool = @splat(true),
};

/// The fixture's routes with the temporary directory their entry modules
/// live in. Heap-pinned, because the supervisor borrows `routes` by pointer.
pub const OwnedRoutes = struct {
    tmp: std.testing.TmpDir,
    routes: routes_mod.Routes,

    /// Writes one entry module per fixture definition and builds the routes
    /// from a configuration naming them all, with the default limits.
    pub fn create(allocator: std.mem.Allocator) !*OwnedRoutes {
        return createWith(allocator, .{});
    }

    /// `create` with the limits `options` gives every definition.
    pub fn createWith(allocator: std.mem.Allocator, options: RoutesOptions) !*OwnedRoutes {
        const owned = try allocator.create(OwnedRoutes);
        errdefer allocator.destroy(owned);
        owned.tmp = std.testing.tmpDir(.{});
        errdefer owned.tmp.cleanup();

        var source: std.array_list.Aligned(u8, null) = .empty;
        defer source.deinit(allocator);
        try source.print(
            allocator,
            "{{\"settings\": {{\"network\": {{\"allow\": [\"*\"]}}, \"limits\": {{\"concurrency\": {d}, \"timeoutMs\": {d}, \"memoryMiB\": {d}",
            .{ options.concurrency, options.timeout_ms, options.memory_mib },
        );
        if (options.cpu_ms) |cpu_ms|
            try source.print(allocator, ", \"cpuMs\": {d}", .{cpu_ms});
        try source.appendSlice(allocator, "}}, \"workers\": {");
        for (definition_names, route_patterns, options.granted, 0..) |name, pattern, granted, index| {
            var entry_name_buffer: [64]u8 = undefined;
            const entry_name = try std.fmt.bufPrint(&entry_name_buffer, "{s}.js", .{name});
            try owned.tmp.dir.writeFile(.{ .sub_path = entry_name, .data = entry_source });
            if (index != 0)
                try source.append(allocator, ',');
            const settings = if (granted) "" else ", \"settings\": {\"network\": {\"allow\": []}}";
            try source.print(allocator, "\"{s}\": {{\"routes\": {{\"{s}\": {{\"entry\": \"./{s}\"}}}}{s}}}", .{ name, pattern, entry_name, settings });
        }
        try source.appendSlice(allocator, "}}");

        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = try owned.tmp.dir.realpath(".", &directory_buffer);
        const config_path = try std.fs.path.join(allocator, &.{ directory, "collo.json" });
        defer allocator.free(config_path);

        var diagnostic: config.Diagnostic = .{};
        const parsed = config.parse(allocator, source.items, config_path, &diagnostic) catch |err| {
            std.debug.print("fixture configuration rejected: {s}\n", .{diagnostic.message()});
            return err;
        };
        owned.routes.init(allocator, parsed, &diagnostic) catch |err| {
            std.debug.print("fixture routes rejected: {s}\n", .{diagnostic.message()});
            return err;
        };
        return owned;
    }

    pub fn destroy(self: *OwnedRoutes, allocator: std.mem.Allocator) void {
        self.routes.deinit();
        self.tmp.cleanup();
        allocator.destroy(self);
    }

    /// The `OwnedRoutes` a fixture supervisor borrows its routes from.
    pub fn of(supervisor: *const Supervisor) *OwnedRoutes {
        return @constCast(@as(*const OwnedRoutes, @fieldParentPtr("routes", supervisor.routes)));
    }
};

/// A supervisor built by `Supervisor.init` over the fixture routes and a sink
/// of its own with no analytics directory: console lines go to stderr and
/// worker lines are counted and dropped. One empty pool per definition. The
/// counterpart teardown is `deinitMinimal`.
pub fn minimalSupervisor(allocator: std.mem.Allocator) !Supervisor {
    return minimalSupervisorWith(allocator, .{});
}

/// `minimalSupervisor` whose sink keeps its record files in
/// `analytics_directory`, an existing directory such as `AnalyticsDir.path`.
pub fn minimalSupervisorWithAnalytics(allocator: std.mem.Allocator, analytics_directory: ?[]const u8) !Supervisor {
    return minimalSupervisorWith(allocator, .{ .analytics_directory = analytics_directory });
}

pub const SupervisorOptions = struct {
    analytics_directory: ?[]const u8 = null,
    routes: RoutesOptions = .{},
    supervisor: supervision.Config = .{},
};

/// The general form of `minimalSupervisor`.
pub fn minimalSupervisorWith(allocator: std.mem.Allocator, options: SupervisorOptions) !Supervisor {
    const owned_routes = try OwnedRoutes.createWith(allocator, options.routes);
    errdefer owned_routes.destroy(allocator);
    const sink = try allocator.create(analytics.Sink);
    errdefer allocator.destroy(sink);
    try sink.open(allocator, .{ .directory = options.analytics_directory });
    errdefer sink.close();
    return Supervisor.init(allocator, &inert_zygote, &owned_routes.routes, sink, options.supervisor, null);
}

/// Releases what `minimalSupervisor` built: `Supervisor.deinit`, which tears
/// down every worker still in a pool's table, then the sink and the routes.
/// A record a test built outside the supervisor's table (`stackWorker`,
/// `newWorker`) stays the test's.
pub fn deinitMinimal(supervisor: *Supervisor) void {
    const allocator = supervisor.allocator;
    const sink = supervisor.analytics;
    const owned_routes = OwnedRoutes.of(supervisor);
    supervisor.deinit();
    sink.close();
    allocator.destroy(sink);
    owned_routes.destroy(allocator);
}

/// A stack worker record of `definition_index` for tests that never tear it
/// down and never publish it: no handle, no scratch. The caller fills
/// `handle` when the code under test reads it.
pub fn stackWorker(id: u64, generation: u64, definition_index: config.DefinitionIndex) WorkerRecord {
    return .{
        .id = id,
        .generation = generation,
        .definition_index = definition_index,
        .name = definition_names[definition_index],
        .handle = undefined,
    };
}

/// Zero-length stand-in for the ingress payload mapping. `SharedPayloadView`
/// teardown unmaps only a non-empty slice, so this is the shape that owns
/// nothing; the header is addressed rather than undefined for the same reason
/// the zygote above is.
var inert_payload_bytes: [0]u8 align(std.heap.page_size_min) = .{};
var inert_payload_header: ipc.ingress_channel.SharedPayloadHeader = std.mem.zeroes(ipc.ingress_channel.SharedPayloadHeader);

var handle_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Reaps `child_pid`, waiting for its exit. Goes through `std.c.waitpid`
/// rather than `std.posix.waitpid`, which treats ECHILD as `unreachable`: the
/// aggregate binary also runs `zygote/tests/fork_loop.zig`, which installs
/// SA_NOCLDWAIT for the length of one test and restores the previous action
/// without checking the result. A child the kernel already reaped is
/// therefore a state to tolerate, not to panic the whole run over.
fn collectExitedChild(child_pid: std.posix.pid_t) void {
    var status: c_int = 0;
    _ = std.c.waitpid(child_pid, &status, 0);
}

/// A fresh path under /tmp: the pid separates test processes that run at the
/// same time, and the sequence separates the paths one process asks for.
///
/// FIXME: the sequence restarts at 0 in every process, so directories that a
/// crashed earlier run with the same pid left behind make the caller's
/// `makeDirAbsolute` fail with `error.PathAlreadyExists`.
fn uniqueTempPath(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/{s}-{d}-{d}", .{
        prefix,
        std.os.linux.getpid(),
        handle_sequence.fetchAdd(1, .monotonic),
    });
}

/// An empty directory at a fresh path, for a test that needs a real directory
/// descriptor. Iterating, like the descriptors production hands to the reaper.
pub fn openScratchDir(allocator: std.mem.Allocator, out_path: *[]u8) !std.fs.Dir {
    const path = try uniqueTempPath(allocator, "collo-test-cgroup");
    errdefer allocator.free(path);
    try std.fs.makeDirAbsolute(path);
    errdefer removeScratchDir(path);
    const dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    out_path.* = path;
    return dir;
}

/// Removes a scratch directory a failed setup made, or reports that it stays
/// on disk.
fn removeScratchDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch |err|
        std.log.warn("supervisor fixture left {s} on disk: {s}", .{ path, @errorName(err) });
}

/// The workers directory every inert handle names its cgroup leaf under: a
/// directory made, opened and removed again at first use, so its descriptor
/// stays valid while every lookup inside it fails with ENOENT, no leaf can
/// ever exist there, and nothing stays on disk. The descriptor lives as long
/// as the test process. Test thread only.
var inert_workers_dir_fd: std.posix.fd_t = -1;

fn inertWorkersDir(allocator: std.mem.Allocator) !std.posix.fd_t {
    if (inert_workers_dir_fd >= 0)
        return inert_workers_dir_fd;
    const path = try uniqueTempPath(allocator, "collo-test-inert-leaves");
    defer allocator.free(path);
    try std.fs.makeDirAbsolute(path);
    const dir_fd = std.posix.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) catch |err| {
        removeScratchDir(path);
        return err;
    };
    std.fs.deleteDirAbsolute(path) catch |err| {
        std.posix.close(dir_fd);
        return err;
    };
    inert_workers_dir_fd = dir_fd;
    return dir_fd;
}

/// A cgroup leaf that names nothing (`inertWorkersDir`), under a job id no
/// other inert leaf of the process has.
pub fn inertLeaf(allocator: std.mem.Allocator) !host.cgroup_root.WorkerLeaf {
    return .{
        .workers_dir_fd = try inertWorkersDir(allocator),
        .job_id = handle_sequence.fetchAdd(1, .monotonic),
    };
}

/// A temporary workers directory whose cgroup leaves are plain directories
/// holding files a test writes, so the figures the server reads off a leaf
/// (`cgroup.readLeafFigure` through `WorkerLeaf.readFile`) and the death
/// classification (`Record.classifyDeath`) read real files. A handle that
/// names one of these leaves removes it at its teardown
/// (`WorkerHandle.deinit`) with an rmdir, which a plain directory allows only
/// once empty and which otherwise retries and warns: the owner empties each
/// leaf (`emptyLeaf`) before the teardown of the handle that names it, and
/// deinits the directory only after every such handle is gone, since each
/// keeps the directory's descriptor. Test thread only.
pub const LeafDir = struct {
    tmp: std.testing.TmpDir,

    /// A file of a leaf and what it holds.
    pub const File = struct {
        name: []const u8,
        data: []const u8,
    };

    /// The `memory.events.local` of a worker that met no memory event.
    pub const quiet_memory_events: File = .{
        .name = "memory.events.local",
        .data = "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n",
    };

    pub fn init() LeafDir {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    pub fn deinit(self: *LeafDir) void {
        self.tmp.cleanup();
        self.* = undefined;
    }

    /// A new leaf holding `files`, under a job id no other fixture leaf of
    /// the process has.
    pub fn leaf(self: *LeafDir, files: []const File) !host.cgroup_root.WorkerLeaf {
        const made: host.cgroup_root.WorkerLeaf = .{
            .workers_dir_fd = self.tmp.dir.fd,
            .job_id = handle_sequence.fetchAdd(1, .monotonic),
        };
        var name_buffer: [host.cgroup_root.WorkerLeaf.name_bytes_max]u8 = undefined;
        try self.tmp.dir.makeDir(made.name(&name_buffer));
        for (files) |file|
            try self.writeFile(made, file);
        return made;
    }

    /// Writes `file` into `target`, replacing what it held.
    pub fn writeFile(self: *LeafDir, target: host.cgroup_root.WorkerLeaf, file: File) !void {
        var name_buffer: [host.cgroup_root.WorkerLeaf.name_bytes_max]u8 = undefined;
        var leaf_dir = try self.tmp.dir.openDir(target.name(&name_buffer), .{});
        defer leaf_dir.close();
        try leaf_dir.writeFile(.{ .sub_path = file.name, .data = file.data });
    }

    /// Leaves `target` an empty directory, which its handle's teardown then
    /// removes with one rmdir.
    pub fn emptyLeaf(self: *LeafDir, target: host.cgroup_root.WorkerLeaf) !void {
        var name_buffer: [host.cgroup_root.WorkerLeaf.name_bytes_max]u8 = undefined;
        const name = target.name(&name_buffer);
        try self.tmp.dir.deleteTree(name);
        try self.tmp.dir.makeDir(name);
    }
};

/// A worker handle `handle.deinit` can take apart end to end: every
/// descriptor teardown closes is real, and its cgroup leaf names nothing.
///
/// The pidfd names a child that has already exited, which is the state every
/// teardown path here assumes: the exit poll returns immediately instead of
/// waiting out PROCESS_EXIT_WAIT_MS, and the SIGKILL teardown sends comes back
/// ESRCH, which it swallows. `control_fd` is a socketpair whose peer is
/// closed, so a send to the worker fails as it does for a worker whose
/// process is gone.
///
/// `pid` is 0 while the pidfd is real, and the split is deliberate. Teardown
/// signals and waits through the descriptor. Besides log lines, only the
/// memory-pressure victim score reads the number, and it opens
/// `/proc/<pid>/smaps_rollup`. The child has been reaped, so its number
/// belongs to the kernel again and may already name an unrelated process,
/// and scoring would then read somebody else's memory. Zero is the value
/// `readWorkerPrivateRssBytes` already refuses as no process to inspect,
/// which is exactly true here and makes the score depend only on idle age
/// and pool position.
///
/// The cgroup leaf lies in a workers directory no leaf can exist in
/// (`inertWorkersDir`), so a test never reaches into the delegated cgroup
/// subtree the kernel lanes own and leaves nothing on disk: the teardown's
/// cgroup kill and rmdir find nothing, and neither do the death
/// classification's reading of `memory.events.local` and the worker line's
/// readings of `cpu.stat` and `memory.peak`.
pub fn inertHandle(allocator: std.mem.Allocator) !WorkerHandle {
    return inertHandleWithLeaf(try inertLeaf(allocator));
}

/// `inertHandle` naming `leaf` as its cgroup leaf, for a test whose leaf
/// reads find real files (`LeafDir`).
pub fn inertHandleWithLeaf(leaf: host.cgroup_root.WorkerLeaf) !WorkerHandle {
    const child_pid = try std.posix.fork();
    if (child_pid == 0) {
        // `exit_group`, never libc `exit`: this binary links libc and may be
        // multithreaded, fork clones only the calling thread, and libc's exit
        // runs the inherited atexit handlers and flushes the inherited stdio
        // buffers. A lock held by a thread that did not survive the fork then
        // deadlocks the child, and the parent's wait below has no timeout.
        std.os.linux.exit_group(0);
    }
    // If the descriptor cannot be opened the child still has to be collected,
    // or it stays a zombie for the life of the run.
    errdefer collectExitedChild(child_pid);
    const pidfd = try process.openPidFd(@intCast(child_pid));
    errdefer std.posix.close(pidfd);
    collectExitedChild(child_pid);

    const pair = try os_fd.socketPairType(std.posix.SOCK.SEQPACKET);
    errdefer std.posix.close(pair[0]);
    std.posix.close(pair[1]);

    const completion_eventfd = try std.posix.eventfd(0, 0);
    errdefer std.posix.close(completion_eventfd);
    const credit_eventfd = try std.posix.eventfd(0, 0);
    errdefer std.posix.close(credit_eventfd);

    // Mapped, then closed, as a launch does once the child holds its copy.
    const metrics_fd = try worker_shared_page.createMemfd("collo-test-metrics");
    defer std.posix.close(metrics_fd);
    var metrics = try worker_shared_page.mapHostReader(metrics_fd);
    errdefer metrics.deinit();

    return .{
        .pid = 0,
        .pidfd = pidfd,
        .control_fd = pair[0],
        .leaf = leaf,
        .completion_eventfd = completion_eventfd,
        .ingress_payload_credit_eventfd = credit_eventfd,
        .ingress_payload = .{ .bytes = &inert_payload_bytes, .header = &inert_payload_header, .side = .server },
        .metrics = metrics,
    };
}

pub const WorkerOptions = struct {
    id: u64 = 1,
    generation: u64 = 1,
    definition_index: config.DefinitionIndex = default_definition,
    created_mono_ns: u64 = 0,
    /// The worker's cgroup leaf, one that names nothing (`inertLeaf`) when
    /// null. A `LeafDir` leaf must be emptied before `destroyWorker`
    /// (`LeafDir.emptyLeaf`).
    leaf: ?host.cgroup_root.WorkerLeaf = null,
};

/// A heap worker record occupied by a worker with a handle `handle.deinit`
/// can take apart, in no pool. The test owns it: `destroyWorker` takes it
/// apart.
pub fn newWorker(allocator: std.mem.Allocator, options: WorkerOptions) !*WorkerRecord {
    var handle = try inertHandleWithLeaf(options.leaf orelse try inertLeaf(allocator));
    errdefer handle.deinit();
    const worker = try allocator.create(WorkerRecord);
    worker.* = WorkerRecord.vacant(options.definition_index, definition_names[options.definition_index]);
    worker.occupy(.{
        .key = .{ .worker_id = options.id, .worker_generation = options.generation },
        .handle = handle,
        .dispatch_send_scratch = &.{},
        .egress_gateway_generation = 0,
        .egress_gateway_session_id = 0,
        .egress_wake_set = .{},
        .created_mono_ns = options.created_mono_ns,
    });
    return worker;
}

/// Takes apart a record `newWorker` built, as the reaper's teardown does once
/// its last console drain is done.
pub fn destroyWorker(allocator: std.mem.Allocator, worker: *WorkerRecord) void {
    unmapForDrains(worker);
    worker.vacate(allocator);
    allocator.destroy(worker);
}

/// Marks the worker's page unmapped for every drain, which the teardown's
/// last console drain does before a record is vacated.
pub fn unmapForDrains(worker: *WorkerRecord) void {
    worker.metrics_mutex.lock();
    defer worker.metrics_mutex.unlock();
    worker.page_mapped = false;
}

/// A worker page a test writes as the worker would: `attach` gives a record
/// a fresh page, whose host reader replaces the one its handle holds and
/// whose writer the result keeps. The record's teardown unmaps the reader;
/// `deinit` unmaps the writer.
pub const WorkerPage = struct {
    fd: std.posix.fd_t,
    writer: worker_shared_page.WorkerWriterView,

    pub fn attach(worker: *WorkerRecord) !WorkerPage {
        const fd = try worker_shared_page.createMemfd("collo-test-worker-page");
        errdefer std.posix.close(fd);
        var writer = try worker_shared_page.mapWorkerWriter(fd);
        errdefer writer.deinit();
        const reader = try worker_shared_page.mapHostReader(fd);
        worker.metrics_mutex.lock();
        defer worker.metrics_mutex.unlock();
        if (worker.handle.metrics) |*previous|
            previous.deinit();
        worker.handle.metrics = reader;
        return .{ .fd = fd, .writer = writer };
    }

    pub fn deinit(self: *WorkerPage) void {
        self.writer.deinit();
        std.posix.close(self.fd);
    }
};

/// Where a definition's pool keeps the record of table entry `entry`, the
/// entry a `LaunchTicket` names.
pub fn recordFor(supervisor: *Supervisor, definition: config.DefinitionIndex, entry: u8) *WorkerRecord {
    const records = supervisor.recordsOf(definition);
    std.debug.assert(entry < records.len);
    return &records[entry];
}

pub const RecordOptions = struct {
    created_mono_ns: u64 = 0,
    /// The worker's own boot, which a request that rode its cold start
    /// reports (`Record.boot_work_ns`).
    boot_work_ns: u64 = 0,
    /// Bytes of the record's dispatch send scratch, which `Record.vacate`
    /// frees with the supervisor's allocator; 0 leaves it empty. A record a
    /// lane dispatches through needs `ipc.max_message_bytes`.
    send_scratch_bytes: usize = 0,
    /// The egress session the record names, 0 for none.
    egress_gateway_generation: u64 = 0,
    egress_gateway_session_id: u64 = 0,
    /// The worker's wake set, which the record owns once it is built; empty
    /// for a test that never reattaches the worker.
    egress_wake_set: ipc.egress_shared.WakeSet = .{},
};

/// Occupies the record storage of `ticket`'s entry with a worker holding
/// `handle` and `options.egress_wake_set`, as a launch's publish does, with
/// the next worker id and generation, and returns it unpublished. On failure
/// the handle and the wake set are the caller's again.
pub fn buildRecord(
    supervisor: *Supervisor,
    definition: config.DefinitionIndex,
    ticket: supervision.pool.LaunchTicket,
    handle: WorkerHandle,
    options: RecordOptions,
) !*WorkerRecord {
    const scratch: []u8 = if (options.send_scratch_bytes == 0)
        &.{}
    else
        try supervisor.allocator.alloc(u8, options.send_scratch_bytes);
    const record = supervisor.ticketRecord(definition, ticket);
    record.occupy(.{
        .key = .{
            .worker_id = supervisor.next_worker_id,
            .worker_generation = supervisor.next_worker_generation,
        },
        .handle = handle,
        .dispatch_send_scratch = scratch,
        .egress_gateway_generation = options.egress_gateway_generation,
        .egress_gateway_session_id = options.egress_gateway_session_id,
        .egress_wake_set = options.egress_wake_set,
        .created_mono_ns = options.created_mono_ns,
        .boot_work_ns = options.boot_work_ns,
    });
    supervisor.next_worker_id += 1;
    supervisor.next_worker_generation = lifecycle.nextGeneration(supervisor.next_worker_generation);
    return record;
}

/// The request key of the placeholder waiter `publishWorker` queues: a lane
/// and a slot no lane has, so it can never name a real request.
const placeholder_waiter = lifecycle.RequestKey{
    .lane_id = std.math.maxInt(u16),
    .slot = lifecycle.invalid_slot,
    .generation = 0,
};

pub const PublishOptions = struct {
    definition_index: config.DefinitionIndex = default_definition,
    /// When the pool stamps the worker idle.
    now_ns: u64 = 0,
    record: RecordOptions = .{},
};

/// The ticket of a launch `worker_pool` starts under an open memory gate, a
/// worker more beside live ones allowed as a scale-out verdict would, or
/// null when the pool wants none.
pub fn startLaunch(worker_pool: *supervision.WorkerPool) ?supervision.pool.LaunchTicket {
    return switch (worker_pool.launchStarted(true, true)) {
        .started => |ticket| ticket,
        .watch, .none => null,
    };
}

/// Publishes a worker holding `handle` into its definition's pool the way a
/// launch does (`launchStarted`, the record built in the ticket's entry,
/// `publish`) and returns its record, idle on the free list with no reader.
/// The pool must be quiet: no free slot, no waiter and no launch in flight,
/// since a launch needs a waiter to claim its entry; the placeholder waiter
/// that claims it leaves before the publish. The handle and the record's wake
/// set belong to the published record, and on failure they are closed here.
pub fn publishWorker(supervisor: *Supervisor, handle: WorkerHandle, options: PublishOptions) !*WorkerRecord {
    var owned_handle = handle;
    errdefer owned_handle.deinit();
    var owned_wake_set = options.record.egress_wake_set;
    errdefer owned_wake_set.deinit();
    const worker_pool = supervisor.poolFor(options.definition_index);
    const before = worker_pool.snapshot();
    if (before.slots_free != 0 or before.waiters != 0 or before.launching != 0)
        return error.PoolNotQuiet;
    switch (worker_pool.acquire(placeholder_waiter.lane_id, placeholder_waiter, std.math.maxInt(u64))) {
        .wait => {},
        .acquired, .full => return error.PoolNotQuiet,
    }
    const ticket = startLaunch(worker_pool) orelse {
        _ = worker_pool.cancelWaiter(placeholder_waiter);
        return error.PoolTableFull;
    };
    if (!worker_pool.cancelWaiter(placeholder_waiter))
        return error.PlaceholderWaiterLost;
    const record = buildRecord(supervisor, options.definition_index, ticket, owned_handle, options.record) catch |err| {
        worker_pool.launchEnded(ticket) catch unreachable;
        return err;
    };
    const handoffs = worker_pool.publish(ticket, record, options.now_ns) catch unreachable;
    std.debug.assert(handoffs.len == 0);
    return record;
}

/// A worker a launch published while requests waited for it, with the slots
/// the publish handed to those waiters, which the caller delivers to their
/// lanes as `dispatch_ready`.
pub const LaunchedWorker = struct {
    record: *WorkerRecord,
    handoffs: supervision.WorkerPool.Handoffs,
};

/// Publishes a worker holding `handle` the way a launch that waiting requests
/// asked for does: the claim needs a waiter (`launchStarted`), and the
/// publish hands the worker's slots to the waiters, oldest first. The handle
/// and the record's wake set belong to the published record, and on failure
/// they are closed here.
pub fn publishLaunchedWorker(supervisor: *Supervisor, handle: WorkerHandle, options: PublishOptions) !LaunchedWorker {
    var owned_handle = handle;
    errdefer owned_handle.deinit();
    var owned_wake_set = options.record.egress_wake_set;
    errdefer owned_wake_set.deinit();
    const worker_pool = supervisor.poolFor(options.definition_index);
    const ticket = startLaunch(worker_pool) orelse return error.LaunchNotClaimed;
    const record = buildRecord(supervisor, options.definition_index, ticket, owned_handle, options.record) catch |err| {
        worker_pool.launchEnded(ticket) catch unreachable;
        return err;
    };
    const handoffs = worker_pool.publish(ticket, record, options.now_ns) catch unreachable;
    return .{ .record = record, .handoffs = handoffs };
}

/// `publishWorker` with an inert handle, for tests that never talk to the
/// worker.
pub fn publishInertWorker(supervisor: *Supervisor, options: PublishOptions) !*WorkerRecord {
    const handle = inertHandle(supervisor.allocator) catch |err| {
        var unused_wake_set = options.record.egress_wake_set;
        unused_wake_set.deinit();
        return err;
    };
    return publishWorker(supervisor, handle, options);
}

/// The worker's half of `session` as the attachment a gateway hands a launch
/// for session `session_id` of gateway `generation` (`Manager.attachWorker`
/// in `server/gateway/manager.zig`). The gateway's half closes here, since no
/// gateway reads it in a test.
pub fn egressAttachment(
    session: *ipc.egress_shared.SessionFds,
    generation: u64,
    session_id: u64,
) lifecycle.EgressGatewayAttachment {
    const half = session.takeWorkerHalf();
    return .{
        .command_control = os_fd.OwnedFd.fromRaw(half.command_control_fd),
        .command_producer = os_fd.OwnedFd.fromRaw(half.command_producer_fd),
        .command_consumer = os_fd.OwnedFd.fromRaw(half.command_consumer_fd),
        .command_data = os_fd.OwnedFd.fromRaw(half.command_data_fd),
        .completion_control = os_fd.OwnedFd.fromRaw(half.completion_control_fd),
        .completion_producer = os_fd.OwnedFd.fromRaw(half.completion_producer_fd),
        .completion_consumer = os_fd.OwnedFd.fromRaw(half.completion_consumer_fd),
        .completion_data = os_fd.OwnedFd.fromRaw(half.completion_data_fd),
        .body_pool_control = os_fd.OwnedFd.fromRaw(half.body_pool_control_fd),
        .body_pool_producer = os_fd.OwnedFd.fromRaw(half.body_pool_producer_fd),
        .body_pool_consumer = os_fd.OwnedFd.fromRaw(half.body_pool_consumer_fd),
        .body_pool_data = os_fd.OwnedFd.fromRaw(half.body_pool_data_fd),
        .upload_pool_control = os_fd.OwnedFd.fromRaw(half.upload_pool_control_fd),
        .upload_pool_producer = os_fd.OwnedFd.fromRaw(half.upload_pool_producer_fd),
        .upload_pool_consumer = os_fd.OwnedFd.fromRaw(half.upload_pool_consumer_fd),
        .upload_pool_data = os_fd.OwnedFd.fromRaw(half.upload_pool_data_fd),
        .command_event = os_fd.OwnedFd.fromRaw(half.command_eventfd),
        .completion_event = os_fd.OwnedFd.fromRaw(half.completion_eventfd),
        .liveness = os_fd.OwnedFd.fromRaw(half.liveness_fd),
        .peer_liveness = os_fd.OwnedFd.fromRaw(half.peer_liveness_fd),
        .generation = generation,
        .session_id = session_id,
    };
}

/// The request table entry a lane records for `request_id` dispatched to the
/// first route of the worker's definition: lane 0, with a slot derived from
/// the id and generation 1.
pub fn dispatchedRequest(request_id: u64) supervision.request_table.Dispatched {
    return .{
        .request_id = request_id,
        .request_key = .{ .lane_id = 0, .slot = @truncate(request_id), .generation = 1 },
        .route = 0,
    };
}

/// A temporary analytics directory. A test hands `path` to a sink, then reads
/// back exactly what reached `workers.jsonl`.
pub const AnalyticsDir = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    pub fn init(allocator: std.mem.Allocator) !AnalyticsDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realpathAlloc(allocator, ".");
        return .{ .tmp = tmp, .path = path };
    }

    pub fn deinit(self: *AnalyticsDir, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.tmp.cleanup();
    }

    /// Parses every worker line in `workers.jsonl`, after flushing `sink`; a
    /// test whose sink is already closed, which wrote everything out, passes
    /// null. A line that is not exactly one worker line, with every field and
    /// no other, fails the call, so the parse doubles as a check of the line
    /// format. The lines `fillStream` wrote are skipped.
    pub fn readWorkers(self: *AnalyticsDir, allocator: std.mem.Allocator, sink: ?*analytics.Sink) !WorkerLines {
        if (sink) |open_sink|
            open_sink.flush(process.monotonicNowNsOrZero());
        return self.readLines(WorkerLine, allocator, .workers);
    }

    fn readLines(self: *AnalyticsDir, comptime Line: type, allocator: std.mem.Allocator, stream: analytics.Stream) !Lines(Line) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        // Every stream but the console has a file.
        const file_name = analytics.sink.fileName(stream).?;
        const contents = self.tmp.dir.readFileAlloc(arena_allocator, file_name, 16 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return .{ .arena = arena, .items = &.{} },
            else => return err,
        };
        var items: std.array_list.Aligned(Line, null) = .empty;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or std.mem.startsWith(u8, line, filler_prefix))
                continue;
            try items.append(arena_allocator, try std.json.parseFromSliceLeaky(Line, arena_allocator, line, .{}));
        }
        return .{ .arena = arena, .items = items.items };
    }
};

const filler_prefix = "{\"filler\"";

/// Takes all but `leave_free` bytes of the sink's `stream` with one filler
/// line, as if producers had appended that much since the last flush. The
/// sink must keep a file for `stream` whose buffer is empty, as it is when
/// opened or just flushed; one that holds more than `leave_free` bytes fails
/// with `error.StreamNotEmpty`. `AnalyticsDir` skips the filler when it reads
/// the file.
pub fn fillStream(allocator: std.mem.Allocator, sink: *analytics.Sink, stream: analytics.Stream, leave_free: usize) !void {
    const buffer_bytes = analytics.sink.bufferBytesMax(stream);
    std.debug.assert(buffer_bytes > leave_free + filler_prefix.len + 1);
    // The line takes its bytes plus the newline the sink adds.
    const filler = try allocator.alloc(u8, buffer_bytes - leave_free - 1);
    defer allocator.free(filler);
    @memset(filler, ' ');
    @memcpy(filler[0..filler_prefix.len], filler_prefix);
    if (!sink.tryAppend(stream, filler))
        return error.StreamNotEmpty;
}

/// Makes every write to a regular file fail, as a file system that takes no
/// more writes does, from `begin` until `end`. A file size limit of zero
/// refuses each write with EFBIG, and the kernel also sends SIGXFSZ with
/// each refusal, which would end the test binary, so it is ignored meanwhile.
/// Both are process-wide, so `end` runs before the test writes a file again.
pub const FileWritesRefused = struct {
    previous_limit: std.posix.rlimit,
    previous_action: std.posix.Sigaction,

    pub fn begin() !FileWritesRefused {
        var refused: FileWritesRefused = undefined;
        std.posix.sigaction(std.posix.SIG.XFSZ, &.{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, &refused.previous_action);
        errdefer std.posix.sigaction(std.posix.SIG.XFSZ, &refused.previous_action, null);
        refused.previous_limit = try std.posix.getrlimit(.FSIZE);
        try std.posix.setrlimit(.FSIZE, .{ .cur = 0, .max = refused.previous_limit.max });
        return refused;
    }

    pub fn end(self: *const FileWritesRefused) void {
        // Back to a soft limit the hard limit already allowed, which cannot
        // fail.
        std.posix.setrlimit(.FSIZE, self.previous_limit) catch unreachable;
        std.posix.sigaction(std.posix.SIG.XFSZ, &self.previous_action, null);
    }
};

/// One line of `workers.jsonl`, field for field.
pub const WorkerLine = struct {
    ts: u64,
    worker: []const u8,
    worker_id: u64,
    worker_generation: u64,
    started_ts: u64,
    life_ns: u64,
    worker_cpu_ns: ?u64,
    memory_peak_bytes: ?u64,
    ending: []const u8,
};

/// The parsed lines of one record file, which live in `arena`.
pub fn Lines(comptime Line: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []const Line,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

pub const WorkerLines = Lines(WorkerLine);
