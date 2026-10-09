//! The server facade: `Server` ties the route table, the ingress listeners,
//! the TLS context, the analytics sink, the worker supervisor and the egress
//! gateway manager together, and `run` blocks the calling thread while the
//! lane threads it starts serve HTTP/2, until `requestStop`, then drains the
//! requests in flight before it returns.
//! The caller of `Server.init` builds the routes, spawns the zygote, owns the
//! worker cgroup root and picks the listen address; the lane count follows
//! from that address (`net/lane_plan.zig`). It also decides the user the
//! process runs as, which the zygote and every worker share, and `Server`
//! does not check it: `boot/` refuses root before it spawns the zygote.
//! `boot/` is the `collo serve` boot that does all of that in order;
//! local-e2e and the sandbox benchmark construct a `Server` themselves.
//!
//! `init` returns the `Server` by value, and every part that other objects
//! point into lives on the heap, so the value may move until `run`. From
//! `run` on, the ingress service holds pointers into it and other threads
//! call `requestStop` and the snapshots, so it stays in place until `deinit`.
//!
//! `Server` owns the route table from `init` to `deinit`. The lanes, the
//! launcher, the reaper and the supervisor read it without locks, so it is
//! freed last, after `run` has joined the lanes, the launcher and the reaper
//! and after the supervisor's teardown.
//!
//! `Server` owns the analytics sink: it opens it before the supervisor, which
//! borrows it, and closes it in `deinit` after the supervisor's teardown,
//! because destroying a worker drains its last console lines into the sink.
//!
//! `Server` owns the egress gateway manager on the heap: the supervisor's
//! egress hooks, the service's lanes, which renew their leases from it, and
//! every gateway record point at it. While `run` runs, the manager reports a
//! lost gateway to the service, whose launcher spawns the next one and
//! reattaches the live workers; `run` clears that link before the service
//! goes.

const std = @import("std");
const analytics_mod = @import("collo_server_analytics");
const routes_mod = @import("collo_server_routes");
const supervision = @import("collo_server_supervisor");
const gateway = @import("collo_server_gateway");
const zygote = @import("collo_zygote");
const host = @import("collo_host");
const ktls = @import("tls/ktls.zig");
const tls_mod = @import("tls/root.zig");
const ingress_mod = @import("ingress/root.zig");
const listener_mod = @import("net/listener.zig");
const lane_plan_mod = @import("net/lane_plan.zig");

pub const boot = @import("boot/root.zig");
pub const analytics = analytics_mod;
pub const ingress = ingress_mod;
pub const ingress_state = ingress.state;
pub const connection_slot = ingress.runner.connection_slot;
pub const http2 = ingress.http2;
pub const listener = listener_mod;
pub const lane_plan = lane_plan_mod;
pub const reuseport_bpf = @import("net/reuseport_bpf.zig");
pub const lifecycle = @import("collo_server_lifecycle");
pub const tls = @import("tls/root.zig");
pub const ktls_mod = ktls;
pub const WorkerConfig = supervision.Config;

pub const Options = struct {
    /// The routes to serve, built at boot (`server/routes/root.zig`).
    /// `Server.init` takes ownership on every call, freeing them when it
    /// fails.
    routes: routes_mod.Routes,
    /// Existing directory the analytics sink appends `logs.jsonl`,
    /// `access.jsonl` and `usage.jsonl` to (`analytics/sink.zig`). null keeps
    /// only the console stream: worker console lines still reach stderr, and
    /// access and usage records are counted and dropped.
    analytics_directory: ?[]const u8 = null,
    /// Port 0 binds an ephemeral port; `port` and `address` report the one
    /// the kernel chose. The address also picks the interface whose receive
    /// queues size the lanes (`lane_plan.build`).
    listen: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
    listen_backlog: u31 = 128,
    /// Lane count chosen by the caller. Zero sizes the lanes from the listen
    /// address's interface or the schedulable CPUs, within the CPU and
    /// memory caps (`lane_plan.build`).
    ingress_lane_override: usize = 0,
    ingress_tcp_notsent_lowat_bytes: u32 = 64 * 1024,
    tls_certificate: tls_mod.CertificateConfig,
    worker: WorkerConfig = .{},
    egress_gateway: gateway.Config = .{},
    /// Borrowed delegated cgroup subtree for per-worker cgroups. The caller
    /// creates it before spawning the zygote, because a delegated placement
    /// moves only the calling process out of its cgroup and a zygote already
    /// there would block the controllers (`host/cgroup_root.zig`), and keeps
    /// it alive past the server. Required: a worker launch refuses a child
    /// born outside its own leaf, so a server without a root could never
    /// serve.
    worker_cgroup_root: *host.WorkerCgroupRoot,
    /// Told the bound address once every lane accepts connections
    /// (`Service.ServingCallback` in `ingress/service.zig`).
    on_serving: ?ingress_mod.Service.ServingCallback = null,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    /// Heap-pinned, like `analytics`: the supervisor, the lanes, the launcher
    /// and the reaper keep pointers to it while `Server` is returned by value.
    routes: *routes_mod.Routes,
    listeners: listener_mod.IngressListeners,
    lane_cpu_ids: []usize,
    ingress_tcp_notsent_lowat_bytes: u32,
    supervisor: supervision.Supervisor,
    egress_gateways: *gateway.Manager,
    /// Heap-pinned, because the supervisor and the ingress service keep
    /// pointers to it while `Server` itself is returned by value.
    analytics: *analytics_mod.Sink,
    tls_context: tls_mod.BoringSslContext,
    on_serving: ?ingress_mod.Service.ServingCallback,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The active ingress service lives on `run`'s stack. Publishing and
    /// clearing it under `active_service_mutex`, and only dereferencing it
    /// while holding that lock, lets `requestStop` and counter snapshots from
    /// other threads reach it without racing the stack object's teardown.
    active_service: ?*ingress_mod.Service = null,
    active_service_mutex: std.Thread.Mutex = .{},
    last_ingress_counters: ingress_mod.lane.CounterSnapshot = .{},

    /// The listeners are listening when this returns, so connections queue in
    /// their backlog until `run` starts the lanes.
    pub fn init(
        allocator: std.mem.Allocator,
        zygote_process: *zygote.host_client.SpawnedZygote,
        options: Options,
    ) !Server {
        const routes = allocator.create(routes_mod.Routes) catch |err| {
            var owned_routes = options.routes;
            owned_routes.deinit();
            return err;
        };
        routes.* = options.routes;
        errdefer {
            routes.deinit();
            allocator.destroy(routes);
        }

        var tls_context = try tls_mod.BoringSslContext.initForKernelKtls(allocator, options.tls_certificate);
        errdefer tls_context.deinit();

        var plan = try lane_plan_mod.build(
            allocator,
            options.listen,
            ingress_mod.runner.laneMemoryShape(),
            options.ingress_lane_override,
        );
        defer plan.deinit(allocator);
        logLanePlan(options.listen, plan);

        const lane_cpu_ids = try allocator.dupe(usize, plan.lane_cpu_ids);
        errdefer allocator.free(lane_cpu_ids);

        var listeners = try listener_mod.IngressListeners.init(allocator, .{
            .address = options.listen,
            .lane_count = plan.lane_count,
            .lane_cpu_ids = plan.lane_cpu_ids,
            .backlog = options.listen_backlog,
        });
        errdefer listeners.deinit();

        const gateway_manager = try allocator.create(gateway.Manager);
        errdefer allocator.destroy(gateway_manager);
        gateway_manager.init(allocator, options.egress_gateway);
        errdefer gateway_manager.deinit();

        const analytics_sink = try allocator.create(analytics_mod.Sink);
        errdefer allocator.destroy(analytics_sink);
        try analytics_sink.open(allocator, .{ .directory = options.analytics_directory });
        errdefer analytics_sink.close();

        var supervisor = try supervision.Supervisor.init(
            allocator,
            zygote_process,
            routes,
            analytics_sink,
            options.worker,
            options.worker_cgroup_root,
        );
        errdefer supervisor.deinit();
        supervisor.setEgressGatewayHooks(.{
            .ctx = gateway_manager,
            .attach = gateway.manager.attachWorkerCallback,
            .currentGeneration = gateway.manager.currentGenerationCallback,
            .keyFor = gateway.manager.keyForCallback,
            .prewarm = gateway.manager.prewarmCallback,
            .bootEnded = gateway.manager.bootEndedCallback,
        });

        return .{
            .allocator = allocator,
            .routes = routes,
            .listeners = listeners,
            .lane_cpu_ids = lane_cpu_ids,
            .ingress_tcp_notsent_lowat_bytes = options.ingress_tcp_notsent_lowat_bytes,
            .supervisor = supervisor,
            .egress_gateways = gateway_manager,
            .analytics = analytics_sink,
            .tls_context = tls_context,
            .on_serving = options.on_serving,
        };
    }

    /// Spawns the egress gateway before traffic (`Manager.prewarm` in
    /// `gateway/manager.zig`), so a broken gateway binary fails the
    /// caller here instead of failing a request. Without this call the gateway
    /// spawns on the first worker attach, which callers need when their binary
    /// cannot serve as the gateway through arg0 re-exec.
    pub fn prewarmEgressGateway(self: *Server) !void {
        try self.egress_gateways.prewarm();
    }

    pub fn requestStop(self: *Server) void {
        self.stop_requested.store(true, .release);
        self.active_service_mutex.lock();
        defer self.active_service_mutex.unlock();
        if (self.active_service) |service|
            service.requestStop();
    }

    pub fn run(self: *Server) !void {
        var service = try ingress_mod.Service.init(self.allocator, .{
            .listeners = &self.listeners,
            .supervisor = &self.supervisor,
            .egress_gateways = self.egress_gateways,
            .routes = self.routes,
            .tls_context = &self.tls_context,
            .analytics = self.analytics,
            .stop_requested = &self.stop_requested,
            .lane_cpu_ids = self.lane_cpu_ids,
            .hard_timeout_grace_ns = self.supervisor.hard_timeout_grace_ns,
            .ingress_tcp_notsent_lowat_bytes = self.ingress_tcp_notsent_lowat_bytes,
            .on_serving = self.on_serving,
        });
        defer service.deinit();
        // `clearDeps` returns once no report can reach the service, so it
        // runs before `service.deinit`. A gateway lost outside this window
        // needs no report: no worker exists before it, and after it the
        // server is stopping.
        self.egress_gateways.setDeps(.{
            .ctx = &service,
            .gatewayLost = ingress_mod.Service.egressGatewayLost,
            .sessionLost = ingress_mod.Service.egressSessionLost,
        });
        defer self.egress_gateways.clearDeps();
        defer {
            // Registered after `service.deinit`, so it runs first: the handle
            // is cleared under the lock before teardown begins, and no other
            // thread can reach the stack object after that.
            self.active_service_mutex.lock();
            self.active_service = null;
            self.active_service_mutex.unlock();
            self.last_ingress_counters = service.countersSnapshot();
        }
        self.active_service_mutex.lock();
        self.active_service = &service;
        self.active_service_mutex.unlock();
        try service.run();
    }

    pub fn deinit(self: *Server) void {
        self.supervisor.drainAllWorkerUsage();
        self.listeners.deinit();
        self.supervisor.deinit();
        // After the supervisor: its teardown drains each worker's last console
        // lines into the sink, and closing writes and syncs that tail.
        self.analytics.close();
        self.allocator.destroy(self.analytics);
        self.egress_gateways.deinit();
        self.allocator.destroy(self.egress_gateways);
        self.tls_context.deinit();
        self.allocator.free(self.lane_cpu_ids);
        // Last: nothing that reads the routes is left running.
        self.routes.deinit();
        self.allocator.destroy(self.routes);
        self.* = undefined;
    }

    pub fn port(self: *const Server) u16 {
        return self.listeners.port();
    }

    /// The bound listen address, with the actual port.
    pub fn address(self: *const Server) std.net.Address {
        return self.listeners.address();
    }

    /// Moves the live service's finished launches into `out`, oldest first
    /// (`Launcher.takeTraces` in `supervisor/launcher.zig`), for the sandbox
    /// benchmark and local-e2e, and returns how many; 0 when no service is
    /// running.
    pub fn takeLaunchTraces(self: *Server, out: []supervision.launcher.LaunchTrace) usize {
        self.active_service_mutex.lock();
        defer self.active_service_mutex.unlock();
        if (self.active_service) |service|
            return service.takeLaunchTraces(out);
        return 0;
    }

    /// The live service's ingress counters; once `run` has returned, its last
    /// ones, and zeros before the first `run`.
    pub fn countersSnapshot(self: *Server) ingress_mod.lane.CounterSnapshot {
        self.active_service_mutex.lock();
        defer self.active_service_mutex.unlock();
        if (self.active_service) |service|
            return service.countersSnapshot();
        return self.last_ingress_counters;
    }
};

fn logLanePlan(listen: std.net.Address, plan: lane_plan_mod.Plan) void {
    if (plan.interface) |interface| {
        std.log.info(
            "ingress lane plan listen={f} iface={s} rx_queues={d} tx_queues={d} allowed_cpu_count={d} mem_available_bytes={d} lane_count={d} lane_cpus={any}",
            .{
                listen,
                interface.name.slice(),
                interface.rx_queues,
                interface.tx_queues,
                plan.allowed_cpu_count,
                plan.mem_available_bytes,
                plan.lane_count,
                plan.lane_cpu_ids,
            },
        );
    } else {
        std.log.info(
            "ingress lane plan listen={f} iface=none allowed_cpu_count={d} mem_available_bytes={d} lane_count={d} lane_cpus={any}",
            .{
                listen,
                plan.allowed_cpu_count,
                plan.mem_available_bytes,
                plan.lane_count,
                plan.lane_cpu_ids,
            },
        );
    }
}
