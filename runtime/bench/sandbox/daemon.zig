//! The measured runtime node of the sandbox benchmark: the `daemon` mode of
//! `sandbox-bench`, which the controller (`controller.zig`) starts once per
//! trial through `wsl-config run` and drives over stdin and stdout
//! (`protocol.zig`).
//!
//! The daemon writes a configuration with one worker definition per sampler
//! route, builds the routes from it at boot as the server's boot does, and
//! serves them through the production server: ingress, the launcher, the
//! pools and the reaper. `wsl-config run` places this process in the trial's
//! `main` cgroup before exec, so the trial accounts for every pack, channel
//! and child the daemon creates. Boot fails unless the zygote and the gateway
//! sit in that same cgroup and the worker root is its `workers` sibling.
//!
//! A prepare publishes a worker without dispatching to its handler. A launch
//! starts only for a waiting request (`Pool.launchStarted`), so the daemon
//! queues a placeholder waiter in the definition's pool, submits the launch
//! and cancels the waiter once the launcher has claimed it. The placeholder's
//! key matches no request lane 0 ever holds, so if the publish hands it the
//! worker's slot first, lane 0 gives the slot back as it does for any
//! `dispatch_ready` whose request is gone, and the worker ends idle either
//! way. A drop retires an idle worker as the reaper does
//! (`Pool.retireIdle`), then waits until its process, its cgroup leaf, its
//! pool entry and its gateway session are gone.
//!
//! A cold sample's host stamps come from the launcher's trace of the launch
//! (`Launcher.takeTraces`), and its request from the handler mark the fresh
//! worker publishes on its page. A launch serves a pool rather than a
//! request, so the daemon ties the two by the worker, which the trace names
//! by its pid: the launch's worker is the one whose handler ran first after
//! the client's send, which holds because the controller sends one request
//! at a time into an empty pool.
//!
//! Sampler route `i` is worker definition `i` (`writeConfig`), whose single
//! route is `/sandbox/<i>`, so every identity the daemon reports carries the
//! definition index as the route.
//!
//! The main thread runs each command to completion before it reads the next.
//! A server thread runs `Server.run`, and a trace thread drains the zygote's
//! trace pipe. The main thread reads the pools and their records while the
//! server runs; a record it reads is live in its pool, and nothing retires a
//! live worker but this daemon's drop, the reaper's idle TTL, which outlasts
//! every trial, and memory pressure, which a trial that sees it is invalid
//! for anyway.

const std = @import("std");
const host = @import("collo_host");
const zygote = @import("collo_zygote");
const os = @import("collo_os");
const cgroup = @import("collo_cgroup");
const server_main = @import("collo_server_main");
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const supervision = @import("collo_server_supervisor");
const protocol = @import("protocol.zig");
const Workload = @import("workload.zig").Workload;

const WorkerRecord = supervision.worker_table.Record;
const LaunchTrace = supervision.launcher.LaunchTrace;
/// Bounds the waits for the server's start, a worker's launch, a launch
/// record and a worker's retirement.
const timeout_ns: u64 = 5 * std.time.ns_per_s;
/// The interval between checks while one of those waits runs.
const poll_ns: u64 = std.time.ns_per_ms;
/// The global limits of the generated configuration: every worker's memory
/// and every request's deadline.
const worker_memory_mib: u32 = 512;
const request_timeout_ms: u32 = 5_000;
/// The lane a prepare's placeholder waiter names: the daemon's server runs
/// one lane.
const placeholder_lane: supervision.pool.LaneId = 0;
/// A request key no request of `placeholder_lane` ever holds: a request
/// slot's generation starts at 1 and never returns to 0
/// (`nextGeneration` in `server/ingress/slab.zig`), so the lane finds the
/// slot vacant or of another generation and treats the request as gone.
const placeholder_waiter = supervision.pool.RequestKey{
    .lane_id = placeholder_lane,
    .slot = 0,
    .generation = 0,
};

pub fn run(allocator: std.mem.Allocator) !void {
    var daemon: Daemon = undefined;
    try daemon.init(allocator);
    var active = true;
    defer if (active) daemon.deinit() catch |err|
        std.log.err("benchmark daemon cleanup failed: {s}", .{@errorName(err)});

    try writeReply(.{ .op = .ready, .ready = daemon.ready });
    var input_buffer: [protocol.command_bytes_max + 1]u8 = undefined;
    var input = std.fs.File.stdin().readerStreaming(&input_buffer);
    while (true) {
        var parse_buffer: [16 * 1024]u8 = undefined;
        var arena = std.heap.FixedBufferAllocator.init(&parse_buffer);
        const parsed = (protocol.readCommand(&input.interface, arena.allocator()) catch |err| {
            try writeReply(.{ .op = .failed, .error_name = @errorName(err) });
            if (err == error.CommandTooLarge) return err;
            continue;
        }) orelse return;
        defer parsed.deinit();
        const command = parsed.value;
        if (command.op == .shutdown) {
            active = false;
            daemon.deinit() catch |err| {
                try writeReply(.{ .op = .failed, .error_name = @errorName(err) });
                return err;
            };
            // A shutdown reply promises that the zygote and the gateway exited,
            // the worker cgroups are gone and the daemon's files are removed.
            try writeReply(.{ .op = .shutdown });
            return;
        }
        daemon.command(command) catch |err|
            try writeReply(.{ .op = .failed, .error_name = @errorName(err) });
    }
}

const Daemon = struct {
    allocator: std.mem.Allocator,
    paths: Paths = undefined,
    main_cgroup: []u8 = undefined,
    worker_root: host.WorkerCgroupRoot = undefined,
    spawned: zygote.host_client.SpawnedZygote = undefined,
    /// Owns the routes built from the configuration (`Server.routes`).
    runtime: server_main.Server = undefined,
    ready: protocol.Ready = undefined,
    server_thread: ?std.Thread = null,
    trace_thread: ?std.Thread = null,
    stop_trace: std.atomic.Value(bool) = .init(false),
    server_failed: std.atomic.Value(bool) = .init(false),
    trace_failed: std.atomic.Value(bool) = .init(false),
    gateway_watch: os.fd.OwnedFd = .{},
    zygote_watch: os.fd.OwnedFd = .{},
    worker_buffer: [protocol.route_count_max]protocol.Worker = undefined,
    launch_buffer: [64]LaunchTrace = undefined,

    fn init(self: *Daemon, allocator: std.mem.Allocator) !void {
        self.* = .{ .allocator = allocator };
        const worker_parent = std.posix.getenv("COLLO_BENCH_CGROUP_ROOT") orelse
            return error.BenchmarkCgroupRootRequired;
        const workload = try Workload.fromEnvironment();
        self.main_cgroup = try validatePlacement(allocator, worker_parent);
        errdefer allocator.free(self.main_cgroup);
        self.paths = try Paths.init(allocator);
        errdefer self.paths.deinit(allocator) catch |err|
            std.log.warn("benchmark files cleanup failed: {s}", .{@errorName(err)});
        try writeConfig(self.paths, workload);

        // Every pack is built before any child exists, as the server's boot
        // builds its routes before it spawns the zygote.
        var diagnostic: config.Diagnostic = .{};
        const loaded = config.load(allocator, self.paths.config, &diagnostic) catch |err| {
            std.log.err("benchmark configuration rejected: {s}", .{diagnostic.message()});
            return err;
        };
        var routes: routes_mod.Routes = undefined;
        routes.init(allocator, loaded, &diagnostic) catch |err| {
            std.log.err("benchmark routes failed to build: {s}", .{diagnostic.message()});
            return err;
        };
        var routes_owned = true;
        defer if (routes_owned) routes.deinit();
        if (routes.definitionCount() != protocol.route_count_max) return error.RouteCountMismatch;

        self.worker_root = try host.WorkerCgroupRoot.init(
            allocator,
            .{ .env_root = worker_parent },
        );
        errdefer self.worker_root.deinit(allocator);
        const executable = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(executable);
        self.spawned = try zygote.host_client.spawnZygote(.{
            .executable_path = executable,
            .warmup_corpus = true,
        });
        errdefer self.spawned.deinit();
        self.zygote_watch = try os.fd.OwnedFd.dupCloexec(self.spawned.pidfd);
        errdefer self.zygote_watch.deinit();
        try requireProcessPlacement(allocator, self.spawned.pid, self.main_cgroup);
        self.trace_thread = try std.Thread.spawn(.{}, traceMain, .{self});
        errdefer self.stopTrace();
        // `Server.init` owns the routes from here on, failure included.
        routes_owned = false;
        self.runtime = try server_main.Server.init(allocator, &self.spawned, .{
            .worker_cgroup_root = &self.worker_root,
            .routes = routes,
            // One lane on any machine, so the node's fixed memory and the
            // sampled cold starts never depend on how many CPUs or receive
            // queues it has.
            .ingress_lane_override = 1,
            .tls_certificate = .{
                .cert_chain = .{ .inline_pem = server_certificate },
                .private_key = .{ .inline_pem = server_key },
            },
            .egress_gateway = .{ .executable_path = executable },
        });
        errdefer self.runtime.deinit();
        // The gateway starts now rather than at the first worker attach, so it
        // is part of every trial's idle baseline instead of the first
        // prepare's delta, and its pid can be checked against the trial's
        // cgroup.
        try self.runtime.prewarmEgressGateway();
        const manager = self.runtime.egress_gateways;
        manager.mutex.lock();
        const gateway = manager.current orelse {
            manager.mutex.unlock();
            return error.GatewayNotReady;
        };
        const gateway_pid = gateway.process.pid;
        self.gateway_watch = os.fd.OwnedFd.dupCloexec(gateway.process.pidfd) catch |err| {
            manager.mutex.unlock();
            return err;
        };
        manager.mutex.unlock();
        errdefer self.gateway_watch.deinit();
        try requireProcessPlacement(allocator, gateway_pid, self.main_cgroup);
        self.ready = .{
            .port = self.runtime.port(),
            .zygote_pid = self.spawned.pid,
            .gateway_pid = gateway_pid,
            .workload = workload,
        };
        self.server_thread = try std.Thread.spawn(.{}, serverMain, .{self});
        errdefer self.stopServer();
        try self.waitForService();
        if ((try self.snapshot()).len != 0) return error.WorkerBornBeforeReady;
    }

    fn command(self: *Daemon, request: protocol.Command) !void {
        try self.checkAlive();
        switch (request.op) {
            .snapshot => try writeReply(.{ .op = .snapshot, .workers = try self.snapshot() }),
            .prepare => {
                try self.prepare(try requireRoute(request.route));
                try writeReply(.{ .op = .prepare, .workers = try self.snapshot() });
            },
            .drop => {
                try self.drop(request);
                try writeReply(.{ .op = .drop, .workers = try self.snapshot() });
            },
            .collect => try self.collect(request),
            .shutdown => unreachable,
        }
    }

    /// The live workers of every pool, one per sampler route at most, sorted
    /// by route.
    fn snapshot(self: *Daemon) ![]const protocol.Worker {
        const supervisor = &self.runtime.supervisor;
        var count: usize = 0;
        for (0..protocol.route_count_max) |route_index| {
            const definition = routeKey(@intCast(route_index)).definition;
            const worker_pool = supervisor.poolFor(definition);
            for (supervisor.recordsOf(definition)) |*record| {
                const view = worker_pool.inspect(record) orelse continue;
                if (view.state != .live or os.process.pidFdHasExited(record.handle.pidfd))
                    return error.BenchmarkWorkerDied;
                if (count == self.worker_buffer.len) return error.WorkerCapacityExceeded;
                self.worker_buffer[count] = identity(record);
                count += 1;
            }
        }
        const result = self.worker_buffer[0..count];
        std.mem.sort(protocol.Worker, result, {}, workerLessThan);
        for (result[0..count], 0..) |item, index| {
            if (index != 0 and result[index - 1].route == item.route)
                return error.MultipleWorkersForRoute;
        }
        return result;
    }

    fn prepare(self: *Daemon, route_index: u32) !void {
        for (try self.snapshot()) |item| {
            if (item.route == route_index) return error.WorkerAlreadyExists;
        }
        const definition = routeKey(route_index).definition;
        const worker_pool = self.runtime.supervisor.poolFor(definition);
        const before = worker_pool.snapshot();
        if (before.workers_live != 0 or before.waiters != 0 or before.launching != 0)
            return error.PoolNotEmpty;
        // Traces of earlier launches would be mistaken for this one's.
        _ = self.runtime.takeLaunchTraces(&self.launch_buffer);

        const deadline_ns = try deadlineNs();
        switch (worker_pool.acquire(placeholder_lane, placeholder_waiter, deadline_ns)) {
            .wait => {},
            .acquired, .full => return error.PoolNotEmpty,
        }
        try self.submitLaunch(definition);
        // Once the launcher holds the claim, the waiter has done its job.
        // Cancelling it first would leave the claim nothing to serve and the
        // launcher would refuse it (`Pool.growthWanted`). A launch that
        // finished between two looks published the worker to the waiter,
        // whose slot lane 0 gives back.
        while (true) {
            const progress = worker_pool.snapshot();
            if (progress.launching != 0 or progress.workers_live != 0) break;
            if (try os.process.monotonicNowNs() >= deadline_ns) {
                _ = worker_pool.cancelWaiter(placeholder_waiter);
                return error.LaunchNotClaimed;
            }
            try self.checkAlive();
            std.Thread.sleep(poll_ns);
        }
        _ = worker_pool.cancelWaiter(placeholder_waiter);

        const launch = try self.awaitLaunch(definition, 0, deadline_ns);
        const record = try self.awaitIdleWorker(definition, launch, deadline_ns);
        if (record.egress_gateway_session_id == 0) return error.WorkerGatewayMissing;
        if (record.handle.metrics) |*metrics| {
            if (metrics.loadBenchHandler() != null) return error.HandlerRanDuringPrepare;
        } else return error.WorkerMetricsMissing;
    }

    fn collect(self: *Daemon, request: protocol.Command) !void {
        const route_index = try requireRoute(request.route);
        const stream_id = request.stream_id orelse return error.StreamIdRequired;
        const sent_ns = request.sent_ns orelse return error.SendTimestampRequired;
        if (stream_id == 0 or sent_ns == 0) return error.InvalidCorrelation;
        const definition = routeKey(route_index).definition;
        const deadline_ns = try deadlineNs();
        // A launch the client's request did not start was claimed before the
        // send.
        const launch = try self.awaitLaunch(definition, sent_ns, deadline_ns);
        while (try os.process.monotonicNowNs() < deadline_ns) {
            try self.checkAlive();
            // The pool's only worker is the launched one, or the request was
            // not a fresh cold start.
            const record = findWorker(&self.runtime.supervisor, definition, launch.pid) orelse
                return error.NotAFreshColdStart;
            const metrics = if (record.handle.metrics) |*value|
                value
            else
                return error.WorkerMetricsMissing;
            if (metrics.loadBenchHandler()) |handler| {
                if (handler.worker_id != record.id or handler.worker_generation != record.generation)
                    return error.HandlerIdentityMismatch;
                try writeReply(.{
                    .op = .collect,
                    .trace = coldTrace(launch, record, handler.request_id, stream_id, route_index),
                    .handler = .{
                        .request_id = handler.request_id,
                        .worker_id = handler.worker_id,
                        .worker_generation = handler.worker_generation,
                        .handler_started_ns = handler.handler_started_ns,
                    },
                    .workers = try self.snapshot(),
                });
                return;
            }
            std.Thread.sleep(poll_ns);
        }
        return error.ColdStartObservationTimeout;
    }

    fn submitLaunch(self: *Daemon, definition: config.DefinitionIndex) !void {
        self.runtime.active_service_mutex.lock();
        defer self.runtime.active_service_mutex.unlock();
        const service = self.runtime.active_service orelse return error.ServerNotRunning;
        service.launcher.submit(definition, .waiter);
    }

    /// Waits for the one launch of `definition` claimed at or after
    /// `claimed_after_ns` to finish, and returns its trace. A second such
    /// launch, or a failed one, fails the command: the controller never asks
    /// for more than one worker of a route at a time.
    fn awaitLaunch(
        self: *Daemon,
        definition: config.DefinitionIndex,
        claimed_after_ns: u64,
        deadline_ns: u64,
    ) !LaunchTrace {
        while (try os.process.monotonicNowNs() < deadline_ns) {
            try self.checkAlive();
            var found: ?LaunchTrace = null;
            const count = self.runtime.takeLaunchTraces(&self.launch_buffer);
            for (self.launch_buffer[0..count]) |launch| {
                if (launch.definition != definition or launch.claimed_ns < claimed_after_ns) continue;
                if (found != null) return error.AmbiguousLaunch;
                if (launch.failure) |failure| {
                    std.log.err("benchmark launch failed: {s}", .{@tagName(failure)});
                    return error.LaunchFailed;
                }
                found = launch;
            }
            if (found) |launch| return launch;
            std.Thread.sleep(poll_ns);
        }
        return error.LaunchObservationTimeout;
    }

    /// Waits until the worker `launch` published is live and holds no slot,
    /// which it reaches once lane 0 gives back a slot the publish handed the
    /// placeholder waiter, and returns its record.
    fn awaitIdleWorker(
        self: *Daemon,
        definition: config.DefinitionIndex,
        launch: LaunchTrace,
        deadline_ns: u64,
    ) !*WorkerRecord {
        const supervisor = &self.runtime.supervisor;
        while (try os.process.monotonicNowNs() < deadline_ns) {
            try self.checkAlive();
            const record = findWorker(supervisor, definition, launch.pid) orelse
                return error.LaunchedWorkerGone;
            const view = supervisor.poolFor(definition).inspect(record) orelse
                return error.LaunchedWorkerGone;
            if (view.state != .live) return error.BenchmarkWorkerDied;
            if (view.slots_held == 0) return record;
            std.Thread.sleep(poll_ns);
        }
        return error.WorkerNotIdle;
    }

    /// The one live worker a drop names, by id or by route.
    fn selectWorker(self: *Daemon, request: protocol.Command) !*WorkerRecord {
        const supervisor = &self.runtime.supervisor;
        var found: ?*WorkerRecord = null;
        for (0..protocol.route_count_max) |route_index| {
            if (request.route) |selected_route| {
                if (selected_route != route_index) continue;
            }
            const definition = routeKey(@intCast(route_index)).definition;
            const worker_pool = supervisor.poolFor(definition);
            for (supervisor.recordsOf(definition)) |*record| {
                const view = worker_pool.inspect(record) orelse continue;
                if (view.state != .live) continue;
                if (request.worker_id) |id| {
                    if (record.id != id) continue;
                }
                if (found != null) return error.AmbiguousWorker;
                found = record;
            }
        }
        return found orelse error.WorkerNotFound;
    }

    fn drop(self: *Daemon, request: protocol.Command) !void {
        if ((request.worker_id == null) == (request.route == null))
            return error.WorkerSelectorRequired;
        if (request.route) |route_index| _ = try requireRoute(route_index);
        const record = try self.selectWorker(request);
        const worker_pool = self.runtime.supervisor.poolFor(record.definition_index);
        var pidfd = try os.fd.OwnedFd.dupCloexec(record.handle.pidfd);
        defer pidfd.deinit();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}", .{record.handle.cgroup_dir});
        const worker_key = record.key();
        const deadline_ns = try deadlineNs();

        // The response that preceded the drop may still be finishing on its
        // lane, so the worker can hold a slot for a moment longer.
        while (true) {
            switch (worker_pool.retireIdle(record)) {
                .not_idle => {},
                .retire => {
                    try self.queueRetirement(record);
                    break;
                },
                .release_reader => |tenure| {
                    try self.releaseReader(worker_key, tenure);
                    break;
                },
            }
            if (try os.process.monotonicNowNs() >= deadline_ns) return error.WorkerRetirementTimeout;
            try self.checkAlive();
            std.Thread.sleep(poll_ns);
        }
        if (!try os.process.waitForPidFdExit(pidfd.fd(), 2000)) return error.WorkerExitTimeout;
        while (try os.process.monotonicNowNs() < deadline_ns) {
            const missing = try pathMissing(path);
            const removed = worker_pool.inspect(record) == null;
            // The gateway drops its side of the session only when it sees the
            // worker's liveness descriptor hang up, later and asynchronously,
            // so this fence proves only that the worker exited, its cgroup is
            // gone and its pool entry is free.
            if (missing and removed) return;
            std.Thread.sleep(poll_ns);
        }
        return error.WorkerResourcesNotRetired;
    }

    /// Hands a worker that no lane reads to the reaper, as its idle pass does.
    fn queueRetirement(self: *Daemon, record: *WorkerRecord) !void {
        self.runtime.active_service_mutex.lock();
        defer self.runtime.active_service_mutex.unlock();
        const service = self.runtime.active_service orelse return error.ServerNotRunning;
        service.reaper.queueRetirement(record, .idle);
    }

    /// Asks the lane that reads a retiring worker to give its role up; that
    /// lane queues the retirement (`release_worker` in
    /// `server/ingress/lane_commands.zig`).
    fn releaseReader(
        self: *Daemon,
        worker_key: server_main.lifecycle.WorkerKey,
        tenure: supervision.pool.ReaderTenure,
    ) !void {
        self.runtime.active_service_mutex.lock();
        defer self.runtime.active_service_mutex.unlock();
        const service = self.runtime.active_service orelse return error.ServerNotRunning;
        const posted = try service.postToLane(tenure.lane, .{ .release_worker = .{
            .worker_key = worker_key,
            .epoch = tenure.epoch,
        } });
        if (!posted) return error.ReaderReleaseRefused;
    }

    fn checkAlive(self: *Daemon) !void {
        if (self.server_failed.load(.acquire)) return error.ServerFailed;
        if (self.trace_failed.load(.acquire)) return error.TraceDrainFailed;
        if (os.process.pidFdHasExited(self.zygote_watch.fd())) return error.ZygoteDied;
        if (os.process.pidFdHasExited(self.gateway_watch.fd())) return error.GatewayDied;
    }

    fn waitForService(self: *Daemon) !void {
        const deadline_ns = try deadlineNs();
        while (try os.process.monotonicNowNs() < deadline_ns) {
            try self.checkAlive();
            self.runtime.active_service_mutex.lock();
            const active = self.runtime.active_service != null;
            self.runtime.active_service_mutex.unlock();
            if (active) return;
            std.Thread.sleep(poll_ns);
        }
        return error.ServerReadyTimeout;
    }

    fn stopServer(self: *Daemon) void {
        if (self.server_thread) |thread| {
            self.runtime.requestStop();
            thread.join();
            self.server_thread = null;
        }
    }

    fn stopTrace(self: *Daemon) void {
        self.stop_trace.store(true, .release);
        if (self.trace_thread) |thread| thread.join();
        self.trace_thread = null;
    }

    fn deinit(self: *Daemon) !void {
        var worker_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path_len = self.worker_root.workers_dir_path.len;
        std.debug.assert(path_len <= worker_path_buffer.len);
        @memcpy(worker_path_buffer[0..path_len], self.worker_root.workers_dir_path);
        self.stopServer();
        self.runtime.deinit();
        self.worker_root.deinit(self.allocator);
        self.stopTrace();
        self.spawned.deinit();
        const children_exited = os.process.pidFdHasExited(self.gateway_watch.fd()) and
            os.process.pidFdHasExited(self.zygote_watch.fd());
        const workers_removed = pathMissing(worker_path_buffer[0..path_len]) catch false;
        self.gateway_watch.deinit();
        self.zygote_watch.deinit();
        self.allocator.free(self.main_cgroup);
        try self.paths.deinit(self.allocator);
        if (!children_exited) return error.RuntimeChildrenStillAlive;
        if (!workers_removed) return error.WorkerResourcesNotRetired;
        if (self.server_failed.load(.acquire)) return error.ServerFailed;
        if (self.trace_failed.load(.acquire)) return error.TraceDrainFailed;
    }
};

fn serverMain(daemon: *Daemon) void {
    daemon.runtime.run() catch |err| {
        daemon.server_failed.store(true, .release);
        std.log.err("benchmark server failed: {s}", .{@errorName(err)});
    };
}

fn traceMain(daemon: *Daemon) void {
    drainTrace(daemon) catch |err| {
        daemon.trace_failed.store(true, .release);
        std.log.err("benchmark trace drain failed: {s}", .{@errorName(err)});
    };
}

/// Keeps the zygote's trace pipe empty and discards what it reads, as the
/// server's boot does (`TraceDrain` in `server/boot/trace_drain.zig`): both
/// ends are nonblocking, so without a reader the pipe fills and every later
/// event is dropped. End of file fails the trial, since the daemon holds a
/// write end until after this thread stops.
fn drainTrace(daemon: *Daemon) !void {
    const fd = daemon.spawned.trace_read_fd orelse return error.TraceDescriptorMissing;
    var bytes: [4096]u8 = undefined;
    while (!daemon.stop_trace.load(.acquire)) {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&descriptors, 20) == 0) continue;
        if (try std.posix.read(fd, &bytes) == 0) return error.TraceClosed;
    }
}

/// The route of sampler route `route_index`: the only route of the
/// definition with the same index.
fn routeKey(route_index: u32) config.RouteKey {
    std.debug.assert(route_index < protocol.route_count_max);
    return .{ .definition = @intCast(route_index), .route = 0 };
}

/// The live worker of `definition` whose process is `pid`, as a launch trace
/// names it, or null. A pid names one live process at a time, and a live
/// worker's process has not exited.
fn findWorker(
    supervisor: *supervision.Supervisor,
    definition: config.DefinitionIndex,
    pid: u32,
) ?*WorkerRecord {
    if (pid == 0) return null;
    const worker_pool = supervisor.poolFor(definition);
    for (supervisor.recordsOf(definition)) |*record| {
        const view = worker_pool.inspect(record) orelse continue;
        if (view.state != .live) continue;
        if (record.handle.pid == pid) return record;
    }
    return null;
}

fn identity(record: *const WorkerRecord) protocol.Worker {
    return .{
        .route = record.definition_index,
        .pid = record.handle.pid,
        .worker_id = record.id,
        .worker_generation = record.generation,
    };
}

fn workerLessThan(_: void, left: protocol.Worker, right: protocol.Worker) bool {
    return left.route < right.route;
}

/// The cold sample's host record. The launcher traces the launch, not the
/// request it served, so the request is the handler mark's and the stream the
/// controller's own. The daemon's server runs one lane, and the connection
/// fields name no connection. `arrived_ns` is the launch's claim, the first
/// host stamp after the request reached a pool with no worker, and
/// `delivered_ns` is 0, since the dispatch that follows the publish runs on
/// the lane and the launcher never sees it.
fn coldTrace(
    launch: LaunchTrace,
    record: *const WorkerRecord,
    request_id: u64,
    stream_id: u32,
    route_index: u32,
) protocol.ColdTrace {
    return .{
        .request_id = request_id,
        .request_stream_id = stream_id,
        .request_lane_id = placeholder_lane,
        .connection_slot = 0,
        .connection_generation = 0,
        .worker_id = record.id,
        .worker_generation = record.generation,
        .worker_pid = record.handle.pid,
        .launched_worker_pid = launch.pid,
        .route_index = route_index,
        .arrived_ns = launch.claimed_ns,
        .ready_received_ns = launch.ready_received_ns,
        .ready_ns = launch.ready_received_ns,
        .publish_ns = launch.published_ns,
        .delivered_ns = 0,
    };
}

fn requireRoute(route: ?u32) !u32 {
    const value = route orelse return error.RouteRequired;
    if (value >= protocol.route_count_max) return error.InvalidRoute;
    return value;
}

fn pathMissing(path: []const u8) !bool {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    return false;
}

fn deadlineNs() !u64 {
    return std.math.add(u64, try os.process.monotonicNowNs(), timeout_ns);
}

fn writeReply(reply: protocol.Reply) !void {
    var buffer: [protocol.reply_bytes_max]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    try output.print("{f}\n", .{std.json.fmt(reply, .{})});
    try os.fd.writeAllRaw(std.posix.STDOUT_FILENO, output.buffered());
}

/// Returns this process's cgroup path, owned by the caller, after checking
/// that it is a `main` leaf whose `workers` sibling is `worker_parent`.
fn validatePlacement(allocator: std.mem.Allocator, worker_parent: []const u8) ![]u8 {
    const current = try cgroup.path.workerDirForPid(allocator, @intCast(std.os.linux.getpid()));
    errdefer allocator.free(current);
    if (!std.mem.eql(u8, std.fs.path.basename(current), "main")) return error.InvalidDaemonCgroup;
    const parent = std.fs.path.dirname(current) orelse return error.InvalidDaemonCgroup;
    const expected = try std.fmt.allocPrint(allocator, "{s}/workers", .{parent});
    defer allocator.free(expected);
    const actual = try std.fs.cwd().realpathAlloc(allocator, worker_parent);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, expected, actual)) return error.WorkersOutsideMeasuredScope;
    return current;
}

fn requireProcessPlacement(allocator: std.mem.Allocator, pid: u32, expected: []const u8) !void {
    const actual = try cgroup.path.workerDirForPid(allocator, pid);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, expected, actual)) return error.ProcessOutsideMeasuredScope;
}

/// The daemon's files under `COLLO_BENCH_CACHE_ROOT`, removed at shutdown.
const Paths = struct {
    root: []u8,
    /// The directory of the configuration and of the entry module its routes
    /// share.
    routes: []u8,
    config: []u8,

    fn init(allocator: std.mem.Allocator) !Paths {
        const parent = std.posix.getenv("COLLO_BENCH_CACHE_ROOT") orelse
            return error.BenchmarkCacheRootRequired;
        if (!std.fs.path.isAbsolute(parent)) return error.CacheRootMustBeAbsolute;
        const root = try std.fmt.allocPrint(allocator, "{s}/collo-sandbox-{d}-{d}", .{
            parent, std.os.linux.getpid(), try os.process.monotonicNowNs(),
        });
        errdefer allocator.free(root);
        try std.posix.mkdir(root, 0o700);
        errdefer std.fs.deleteTreeAbsolute(root) catch |err|
            std.log.warn("benchmark root cleanup failed: {s}", .{@errorName(err)});
        const routes = try std.fmt.allocPrint(allocator, "{s}/routes", .{root});
        errdefer allocator.free(routes);
        const config_path = try std.fmt.allocPrint(allocator, "{s}/collo.json", .{routes});
        return .{ .root = root, .routes = routes, .config = config_path };
    }

    fn deinit(self: Paths, allocator: std.mem.Allocator) !void {
        defer inline for (@typeInfo(Paths).@"struct".fields) |field|
            allocator.free(@field(self, field.name));
        try std.fs.deleteTreeAbsolute(self.root);
    }
};

/// Writes the workload's entry module and a configuration with
/// `route_count_max` worker definitions, `sandbox-<i>`, each with the one
/// route `/sandbox/<i>` on that entry. Pools are keyed by definition, so
/// every route gets a pool and a pack of its own while all packs hold the
/// same source under different specifiers.
fn writeConfig(paths: Paths, workload: Workload) !void {
    try std.fs.makeDirAbsolute(paths.routes);
    var dir = try std.fs.openDirAbsolute(paths.routes, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "sandbox.js", .data = workload.entrySource() });

    var buffer: [16 * 1024]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    try output.print(
        "{{\"globalSettings\":{{\"limits\":{{\"memoryMiB\":{d},\"timeoutMs\":{d}}}}},\"workers\":{{",
        .{ worker_memory_mib, request_timeout_ms },
    );
    for (0..protocol.route_count_max) |index| {
        if (index != 0) try output.writeByte(',');
        try output.print(
            "\"sandbox-{d}\":{{\"routes\":{{\"" ++ protocol.route_prefix ++ "{d}\":{{\"entry\":\"./sandbox.js\"}}}}}}",
            .{ index, index },
        );
    }
    try output.writeAll("}}\n");
    try dir.writeFile(.{ .sub_path = "collo.json", .data = output.buffered() });
}

const server_certificate =
    \\-----BEGIN CERTIFICATE-----
    \\MIICBjCCAaygAwIBAgIUQ5fx+RiwnspylCKC0QDwz2kaoGAwCgYIKoZIzj0EAwIw
    \\GDEWMBQGA1UEAwwNQ29sbG8gVGVzdCBDQTAeFw0yNjA1MTMwMjQ4MjhaFw0zNjA1
    \\MTAwMjQ4MjhaMBkxFzAVBgNVBAMMDnB1YmxpYy5leGFtcGxlMFkwEwYHKoZIzj0C
    \\AQYIKoZIzj0DAQcDQgAEKoqKcVXsYm4l18TDNdKKcGLV/ePZBWFOm+ulhQd0ckud
    \\tclm4qorUP6/N1RAbvqVMipwFEEjkOQwd6ApE10rL6OB0jCBzzAMBgNVHRMBAf8E
    \\AjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATBaBgNVHREE
    \\UzBRgg5wdWJsaWMuZXhhbXBsZYIUdmlzaWJsZS5leGFtcGxlLnRlc3SCFHByaXZh
    \\dGUuZXhhbXBsZS50ZXN0ghNzZWNyZXQuZXhhbXBsZS50ZXN0MB0GA1UdDgQWBBTD
    \\9ErWlI10XYtNvLjM5NlMdP7eyjAfBgNVHSMEGDAWgBRZ42OYS6d+R6iUqwrY9Hxa
    \\iv8cEzAKBggqhkjOPQQDAgNIADBFAiEAiImGbZC66AcESwxmsZhDlAo2b5crBxjh
    \\zk/SekKb44gCID1K94T7kY1RreA05puQ6Q4ONZOfJOJlyNYo5pWU2giB
    \\-----END CERTIFICATE-----
    \\
;

const server_key =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEIHOLdElJrG8GzNeXYapu5Ony94W9g/MsEz/WTqGQN1m1oAoGCCqGSM49
    \\AwEHoUQDQgAEKoqKcVXsYm4l18TDNdKKcGLV/ePZBWFOm+ulhQd0ckudtclm4qor
    \\UP6/N1RAbvqVMipwFEEjkOQwd6ApE10rLw==
    \\-----END EC PRIVATE KEY-----
    \\
;
