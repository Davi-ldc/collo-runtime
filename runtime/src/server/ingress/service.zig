//! The server's HTTP/2 ingress service: one lane thread per listener, fixed
//! for the service's life, and the threads around them. A metrics thread
//! drains usage records, console lines and access records every tick and
//! flushes the analytics record files (`analytics_drain.zig`); a console
//! thread is the only writer of console lines to stderr while the service
//! runs; the launcher (`server/supervisor/launcher.zig`) turns pool claims
//! into published workers and watches the zygote; the reaper
//! (`server/supervisor/reaper/`) owns every worker retirement and watches
//! the workers no lane reads.
//!
//! This file holds `Service` and its lifecycle: `init`, `run`, which starts
//! every thread above and stops them in order, the stop flag, the fatal
//! error that stops the server, and the request ids. `init`, `run` and
//! `deinit` run on the service's thread, the one that calls `Server.run`
//! (the main thread under `collo serve`); `requestStop`,
//! `requestStopSignal`, `shouldStop`, `recordFatalError` and
//! `allocateRequestId` run on any thread. What the service reports about
//! itself is in `service_observability.zig`, and its side of the launcher's
//! and the reaper's `Deps`, with the posts that carry a pool's results to
//! the lanes, in `service_deps.zig`. `Service` declares the functions of
//! both that other threads and files call on it.
//!
//! The launcher and the reaper keep pointers to the service, so they are
//! set up in `run`, once the service has its address, and torn down before
//! `run` returns.
//!
//! Start order is console, metrics, reaper, launcher, lanes; a stop runs the
//! producers down before their consumers (`stopAndDrainForExit`): the lanes
//! finish their requests while the launcher still publishes workers to their
//! waiters, then the launcher ends its launches into the reaper's queue, then
//! the reaper stops and the exiting thread tears down what it left.
//!
//! Borrowed from `Server` (`server/main.zig`), all outliving this service:
//! the listeners, the supervisor, the egress gateway manager, whose loss
//! reports `Server.run` routes here only while the service exists
//! (`egressGatewayLost`, `egressSessionLost`), the TLS context, the
//! analytics sink, which `Server` closes after this service is gone and so
//! writes the tail each flusher left, and the route table, which every lane,
//! the launcher and the reaper read without locks until the last of them has
//! joined.

const std = @import("std");
const ipc = @import("collo_ipc");
const analytics_mod = @import("collo_server_analytics");
const routes_mod = @import("collo_server_routes");
const gateway = @import("collo_server_gateway");
const tls_mod = @import("../tls/root.zig");
const listener_mod = @import("../net/listener.zig");
const supervision = @import("collo_server_supervisor");
const runner = @import("runner/root.zig");
const analytics_drain = @import("analytics_drain.zig");
const service_deps = @import("service_deps.zig");
const service_observability = @import("service_observability.zig");

const launcher_mod = supervision.launcher;
const reaper_mod = supervision.reaper;
const scheduler_limits = supervision.scheduler_limits;

const LaneRunner = runner.LaneWorker(Service);
const Deps = service_deps.Methods(Service);
const Observability = service_observability.Methods(Service);

pub const Service = struct {
    allocator: std.mem.Allocator,
    listeners: *listener_mod.IngressListeners,
    supervisor: *supervision.Supervisor,
    /// Borrowed from `Server`. Each lane renews its egress lease from it when
    /// the gateway generation moves (`runner/ring_driver.zig`).
    egress_gateways: *gateway.Manager,
    routes: *const routes_mod.Routes,
    tls_context: *tls_mod.BoringSslContext,
    hard_timeout_grace_ns: u64,
    stop_requested: *std.atomic.Value(bool),
    lane_cpu_ids: []const usize,
    ingress_tcp_notsent_lowat_bytes: u32,
    lanes: []LaneRunner,
    /// Set up in `run` and torn down before `run` returns; `launcher_live`
    /// says when it may be used from outside `run`.
    launcher: launcher_mod.Launcher = undefined,
    /// Set up in `run` and torn down before `run` returns.
    reaper: reaper_mod.Reaper = undefined,
    /// Guards `launcher_live`, which `run` sets once the launcher is set up
    /// and clears before tearing it down, so neither the trace reader
    /// (`takeLaunchTraces`) nor a gateway's loss reports (`egressGatewayLost`,
    /// `egressSessionLost`) reach a launcher being set up or torn down.
    launcher_mutex: std.Thread.Mutex = .{},
    launcher_live: bool = false,
    /// What every launch sends the worker, read from the environment once,
    /// at `init`.
    worker_boot: ipc.WorkerRuntimeBootOptions,
    worker_tmpfs_size_bytes: ?u64,
    fatal_error: ?anyerror = null,
    fatal_error_mutex: std.Thread.Mutex = .{},
    next_request_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    /// Borrowed from `Server`; outlives this service.
    analytics: *analytics_mod.Sink,
    /// Metrics thread only.
    analytics_drain: analytics_drain.State = .{},
    on_serving: ?ServingCallback,

    /// Receives the bound listen address, with its actual port, once every
    /// lane is active. It runs on the thread inside `run` and must return
    /// promptly, because shutdown is not polled until it does.
    pub const ServingCallback = *const fn (std.net.Address) void;

    /// A post that cannot reach a lane: the lane id names no lane, or the
    /// lane's wake cannot be written. Both are lane faults to a lane, and
    /// stop the server from any other thread.
    pub const PostError = error{ InvalidLaneId, CommandEventfdCorrupt };

    /// Everything `init` borrows; each pointer must outlive the service.
    pub const Options = struct {
        listeners: *listener_mod.IngressListeners,
        supervisor: *supervision.Supervisor,
        egress_gateways: *gateway.Manager,
        routes: *const routes_mod.Routes,
        tls_context: *tls_mod.BoringSslContext,
        analytics: *analytics_mod.Sink,
        stop_requested: *std.atomic.Value(bool),
        /// One CPU per lane, in listener order.
        lane_cpu_ids: []const usize,
        hard_timeout_grace_ns: u64,
        ingress_tcp_notsent_lowat_bytes: u32,
        /// Called once when every lane is active; never when the lanes fail
        /// to start or a stop arrives before they do.
        on_serving: ?ServingCallback = null,
    };

    /// What `run` started, so that a stop on any path ends exactly that.
    const Started = struct {
        console: ?std.Thread = null,
        metrics: ?std.Thread = null,
        reaper: bool = false,
        launcher: bool = false,
        drained: bool = false,
    };

    /// Fails with `error.InvalidLaneCount` or `error.TooManyIngressLanes`
    /// for a listener set the lanes cannot serve, with
    /// `error.InvalidBootOptions` for boot options the environment sets
    /// wrong, and with `error.OutOfMemory`.
    pub fn init(allocator: std.mem.Allocator, options: Options) !Service {
        const listeners = options.listeners;
        const lane_cpu_ids = options.lane_cpu_ids;
        const lane_count = listeners.laneCount();
        if (lane_count == 0)
            return error.InvalidLaneCount;
        if (lane_count > std.math.maxInt(u16))
            return error.TooManyIngressLanes;
        if (lane_cpu_ids.len != lane_count)
            return error.InvalidLaneCount;

        const worker_boot = try launcher_mod.resolveWorkerRuntimeBootOptions();
        const worker_tmpfs_size_bytes = launcher_mod.resolveWorkerTmpfsSizeBytes();

        const lanes = try allocator.alloc(LaneRunner, lane_count);
        errdefer allocator.free(lanes);
        for (lanes, 0..) |*lane, index| {
            lane.* = .{
                .listener_index = @intCast(index),
                .cpu_id = lane_cpu_ids[index],
            };
        }

        return .{
            .allocator = allocator,
            .listeners = listeners,
            .supervisor = options.supervisor,
            .egress_gateways = options.egress_gateways,
            .routes = options.routes,
            .tls_context = options.tls_context,
            .hard_timeout_grace_ns = options.hard_timeout_grace_ns,
            .stop_requested = options.stop_requested,
            .lane_cpu_ids = lane_cpu_ids,
            .ingress_tcp_notsent_lowat_bytes = options.ingress_tcp_notsent_lowat_bytes,
            .lanes = lanes,
            .worker_boot = worker_boot,
            .worker_tmpfs_size_bytes = worker_tmpfs_size_bytes,
            .analytics = options.analytics,
            .on_serving = options.on_serving,
        };
    }

    pub fn deinit(self: *Service) void {
        for (self.lanes) |*lane|
            lane.deinit();
        self.allocator.free(self.lanes);
        self.* = undefined;
    }

    pub fn run(self: *Service) !void {
        try self.launcher.init(self.allocator, .{
            .deps = .{
                .ctx = self,
                .claim = Deps.launchClaim,
                .attachEgress = Deps.launchAttachEgress,
                .publish = Deps.launchPublish,
                .failed = Deps.launchFailed,
                .zygoteExited = Deps.launchZygoteExited,
                .egressCurrentGeneration = Deps.launchEgressCurrentGeneration,
                .egressPrewarm = Deps.launchEgressPrewarm,
                .egressBootEnded = Deps.launchEgressBootEnded,
                .nextStaleEgressWorker = Deps.launchNextStaleEgressWorker,
                .setWorkerEgress = Deps.launchSetWorkerEgress,
                .retireForEgress = Deps.launchRetireForEgress,
                .dropEgressSession = Deps.launchDropEgressSession,
            },
            .zygote_process = self.supervisor.zygote_process,
            .routes = self.routes,
            .worker_cgroup_root = self.supervisor.worker_cgroup_root,
            .boot = self.worker_boot,
            .tmpfs_size_bytes = self.worker_tmpfs_size_bytes,
            .launches_per_definition_max = scheduler_limits.capacity.pool_cold_starts_in_flight_max,
        });
        defer self.launcher.deinit();
        self.setLauncherLive(true);
        defer self.setLauncherLive(false);
        // The reaper's teardown of a failed launch ends with
        // `Launcher.leftoversReaped`, so the reaper is torn down first.
        try self.reaper.init(self.allocator, .{
            .supervisor = self.supervisor,
            .deps = .{
                .ctx = self,
                .postReleaseWorker = Deps.reaperPostReleaseWorker,
                .postWorkerDied = Deps.reaperPostWorkerDied,
                .submit = Deps.reaperSubmit,
                .leftoversReaped = Deps.reaperLeftoversReaped,
            },
        });
        defer self.reaper.deinit();

        var started: Started = .{};
        defer self.stopAndDrainForExit(&started);
        started.console = try std.Thread.spawn(.{}, Observability.consoleThreadMain, .{self});
        started.metrics = try std.Thread.spawn(.{}, Observability.metricsThreadMain, .{self});
        try self.reaper.start();
        started.reaper = true;
        try self.launcher.start();
        started.launcher = true;
        self.startAllLanes() catch |err| switch (err) {
            error.IngressServiceStopping => {},
            else => return err,
        };
        if (self.on_serving) |notify| {
            if (!self.shouldStop())
                notify(self.listeners.address());
        }

        while (!self.shouldStop()) {
            if (self.firstLaneError() != null)
                break;
            std.Thread.sleep(service_observability.metrics_drain_stop_poll_ns);
        }
        // Drained here rather than by the defer, so that an error recorded
        // while the threads stop is the one `run` returns.
        self.stopAndDrainForExit(&started);
        if (self.exitError()) |err|
            return err;
    }

    /// What `run` returns once every thread has stopped: the first fatal
    /// error the service recorded, else the first lane's error, else null
    /// for a stop that was only requested.
    pub fn exitError(self: *Service) ?anyerror {
        if (self.firstServiceError()) |err|
            return err;
        return self.firstLaneError();
    }

    /// Asks the service to stop, from any thread: raises the stop flag and
    /// wakes every running lane.
    pub fn requestStop(self: *Service) void {
        self.requestStopSignal();
        for (self.lanes) |*lane|
            wakeLaneForStop(lane);
    }

    pub fn shouldStop(self: *const Service) bool {
        return self.stop_requested.load(.acquire);
    }

    pub fn requestStopSignal(self: *Service) void {
        self.stop_requested.store(true, .release);
    }

    pub fn allocateRequestId(self: *Service) u64 {
        const request_id = self.next_request_id.fetchAdd(1, .monotonic);
        if (request_id == 0)
            return self.next_request_id.fetchAdd(1, .monotonic);
        return request_id;
    }

    // What other threads and files call on the service, from
    // `service_observability.zig` and `service_deps.zig`.
    pub const countersSnapshot = Observability.countersSnapshot;
    pub const takeLaunchTraces = Observability.takeLaunchTraces;
    pub const postToLane = Deps.postToLane;
    pub const postHandoff = Deps.postHandoff;
    pub const strandWaiters = Deps.strandWaiters;
    pub const announceWorkerDeath = Deps.announceWorkerDeath;
    pub const queueRetirement = Deps.queueRetirement;

    /// The egress manager's `Deps.gatewayLost` (`server/gateway/manager.zig`),
    /// with the service as `ctx`: hands the loss of gateway `generation` to
    /// the launcher, which reattaches the workers it served. Runs on the
    /// thread that saw the loss and returns at once. A loss reported while no
    /// launcher is set up needs no reattach, since no worker exists then.
    pub fn egressGatewayLost(ctx: *anyopaque, generation: u64) void {
        const self: *Service = @ptrCast(@alignCast(ctx));
        self.launcher_mutex.lock();
        defer self.launcher_mutex.unlock();
        if (self.launcher_live)
            self.launcher.gatewayLost(generation);
    }

    /// The egress manager's `Deps.sessionLost`, with the service as `ctx`:
    /// hands session `session_id` of gateway `generation`, which that gateway
    /// removed on its own, to the launcher, which gives its worker a new
    /// session. Runs on the gateway's control reader and returns at once; a
    /// loss reported while no launcher is set up has no worker to reattach.
    pub fn egressSessionLost(ctx: *anyopaque, generation: u64, session_id: u64) void {
        const self: *Service = @ptrCast(@alignCast(ctx));
        self.launcher_mutex.lock();
        defer self.launcher_mutex.unlock();
        if (self.launcher_live)
            self.launcher.egressSessionLost(generation, session_id);
    }

    fn setLauncherLive(self: *Service, live: bool) void {
        self.launcher_mutex.lock();
        defer self.launcher_mutex.unlock();
        self.launcher_live = live;
    }

    fn startAllLanes(self: *Service) !void {
        var started: usize = 0;
        errdefer self.requestStopSignal();

        for (self.lanes, 0..) |*lane, index| {
            const listener = self.listeners.get(index) orelse return error.InvalidLaneCount;
            try lane.prepareStart(self, listener);
            lane.thread = try std.Thread.spawn(.{}, LaneRunner.threadMain, .{lane});
            started += 1;
        }

        while (started != 0) {
            var active: usize = 0;
            for (self.lanes[0..started]) |*lane| {
                switch (lane.state()) {
                    .active => active += 1,
                    .failed => return lane.run_error orelse error.IngressLaneStartFailed,
                    .warming, .closed, .exited => {},
                }
            }
            if (active == started)
                return;
            if (self.shouldStop())
                return error.IngressServiceStopping;
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    fn stopAndJoinAllLanes(self: *Service) void {
        for (self.lanes) |*lane|
            wakeLaneForStop(lane);
        for (self.lanes) |*lane| {
            if (lane.thread) |thread| {
                thread.join();
                lane.thread = null;
            }
        }
    }

    /// Stops what `run` started, producers before their consumers. The lanes
    /// stop taking requests and serve the ones they hold; a request still
    /// waiting gets a worker the launcher publishes, or 503 at its deadline.
    /// The metrics and console threads end their last tick next, so the
    /// console drain's death path (`analytics_drain.zig`) queues no
    /// retirement after the reaper's last drain. The launcher then ends its
    /// launches in flight as `.stopping`, which queues what they left to the
    /// reaper. The reaper stops last, and what its queue still holds is torn
    /// down on this thread: shutdown owns the latency. Runs once.
    fn stopAndDrainForExit(self: *Service, started: *Started) void {
        if (started.drained)
            return;
        started.drained = true;
        self.requestStopSignal();
        self.stopAndJoinAllLanes();
        if (started.metrics) |thread|
            thread.join();
        if (started.console) |thread|
            thread.join();
        if (started.launcher) {
            self.launcher.stop();
            self.launcher.join();
        }
        if (started.reaper) {
            self.reaper.stop();
            self.reaper.join();
            _ = self.reaper.drainRetirements();
        }
        Observability.finalObservabilityFold(self);
    }

    fn firstLaneError(self: *Service) ?anyerror {
        for (self.lanes) |*lane| {
            if (lane.run_error) |err|
                return err;
        }
        return null;
    }

    pub fn recordFatalError(self: *Service, err: anyerror) void {
        self.fatal_error_mutex.lock();
        defer self.fatal_error_mutex.unlock();
        if (self.fatal_error == null)
            self.fatal_error = err;
        self.requestStopSignal();
    }

    fn firstServiceError(self: *Service) ?anyerror {
        self.fatal_error_mutex.lock();
        defer self.fatal_error_mutex.unlock();
        return self.fatal_error;
    }
};

/// Wakes a lane blocked in its ring wait, so it sees the stop flag. A lane
/// that is not running has nothing to wake, and a full queue already holds
/// commands with their wakes pending.
fn wakeLaneForStop(lane: *LaneRunner) void {
    _ = lane.post(.shutdown) catch |err| woken: {
        // The lane's eventfd is broken: the lane meets the same failure on
        // its next drain and stops with it.
        std.log.err("failed to wake ingress lane {d} for shutdown: {s}", .{ lane.listener_index, @errorName(err) });
        break :woken false;
    };
}
