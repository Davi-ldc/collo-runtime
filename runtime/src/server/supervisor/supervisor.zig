//! The worker supervisor: one pool of worker processes per worker definition
//! of the server configuration, the records of those workers, their usage
//! records and the hooks into the egress gateway manager. One instance lives
//! in the server process, and the ingress lanes, the launcher, the reaper,
//! the metrics thread and the exiting thread all call into it.
//!
//! - `routes` is borrowed: the server builds it at boot and frees it only
//!   after every thread that reads the supervisor has stopped
//!   (`server/routes/root.zig`). Worker records borrow their definition's
//!   name from it, and usage records borrow route patterns.
//! - `pools[d]` is definition `d`'s pool, built at `init` and kept until
//!   `deinit`. Each pool locks itself (`pool.zig` states its lock order), and
//!   the supervisor has no lock of its own: a lane's dispatch and finish take
//!   only their pool's mutex, the worker's request table lock and, when they
//!   drain or write a floor, the worker's `metrics_mutex`.
//! - `records` holds every worker record, entry `e` of pool `d` at
//!   `d * pool_workers_max + e`, the entry a `LaunchTicket` names. Allocated
//!   at `init` and freed at `deinit`, so a record pointer stays
//!   dereferenceable for the server's life; `worker_table.zig` says who may
//!   read a record when.
//! - `next_worker_id` and `next_worker_generation` belong to the launcher
//!   thread, which alone builds records (`worker_registry.buildRecord`).
//! - Usage records take no lock of this struct. `usage` locks itself and
//!   owns the exactly-once index, `analytics` locks its own streams, each
//!   worker record's request table has its own leaf lock, and
//!   `usage_counters` are atomics.
//! - `egress_gateway` is set once by the server before the launcher starts
//!   and read without a lock after that.
//! - A live worker's egress session changes when the launcher attaches it to
//!   a new gateway (`setWorkerEgress`) or takes it off a session its gateway
//!   removed (`dropEgressSession`), and is read by the lanes that mint its
//!   tokens (`workerEgress`), all under its pool's mutex.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const zygote = @import("collo_zygote");
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const server_lifecycle = @import("collo_server_lifecycle");
const pool_limits = @import("collo_limits").pool;
const worker_shared_page = @import("collo_worker_state").page;
const cgroup_root = @import("collo_host").cgroup_root;
/// The analytics module `Supervisor.init` takes a sink from.
pub const analytics = @import("collo_server_analytics");

const launcher = @import("launcher.zig");
const pool = @import("pool.zig");
const reaping = @import("reaper/reaping.zig");
const scheduler_limits = @import("scheduler_limits.zig");
const worker_table = @import("worker_table.zig");
const usage_drain = @import("usage_drain.zig");
const usage_log = @import("usage_log.zig");
const worker_factory = @import("worker_factory.zig");
const worker_registry = @import("worker_registry.zig");

const WorkerRecord = worker_table.Record;
const Routes = routes_mod.Routes;
const WorkerCgroupRoot = cgroup_root.WorkerCgroupRoot;

pub const WorkerPool = pool.Pool(WorkerRecord);
pub const SettleOutcome = usage_drain.SettleOutcome;

const pool_workers_max = scheduler_limits.capacity.pool_workers_max;

comptime {
    // A launch ticket names its entry in a byte, and each pool's options
    // must pass `Pool.init`, which refuses what its docs exclude.
    std.debug.assert(pool_workers_max >= 1);
    std.debug.assert(pool_workers_max <= pool.entries_max);
    std.debug.assert(scheduler_limits.capacity.pool_cold_starts_in_flight_max >= 1);
    std.debug.assert(scheduler_limits.capacity.pool_cold_starts_in_flight_max <= pool_workers_max);
    std.debug.assert(pool_limits.pool_waiters_max >= 1);
}

/// How long past a request's deadline its lane waits for the worker's own
/// 504 before it faults the worker (`deadline_grace_expired` in
/// `server/ingress/fault.zig`).
const default_hard_timeout_grace_ns: u64 = 250 * std.time.ns_per_ms;
/// How long a worker may stay idle before the reaper retires it.
const default_worker_idle_ttl_ns: u64 = 10 * 60 * std.time.ns_per_s;

pub const EgressGatewayAttachment = server_lifecycle.EgressGatewayAttachment;

/// The egress gateway manager (`server/gateway/manager.zig`) as the launcher
/// and the launch path reach it, through a context pointer, since this
/// module does not import the manager's. `server/main.zig` sets it with the
/// manager's callbacks; a supervisor without it attaches no worker to a
/// gateway.
pub const EgressGatewayHooks = struct {
    ctx: *anyopaque,
    /// `Manager.attachWorker`: one attach round trip for a new session of a
    /// worker of the named definition, built on the worker's wake set.
    attach: *const fn (
        ctx: *anyopaque,
        definition_name: []const u8,
        wake_set: *const ipc.egress_shared.WakeSet,
    ) anyerror!EgressGatewayAttachment,
    /// `Manager.currentGeneration`: the current gateway's generation, 0
    /// while none is current.
    currentGeneration: *const fn (ctx: *anyopaque) u64,
    /// `Manager.keyFor`: copies the token key of gateway `generation` into
    /// `out`, false once that gateway is no longer current.
    keyFor: *const fn (ctx: *anyopaque, generation: u64, out: *ipc.egress_token.Key) bool,
    /// `Manager.prewarm`: spawns a gateway when none is current.
    prewarm: *const fn (ctx: *anyopaque) anyerror!void,
    /// `Manager.requestEnded` for the boot token of session `session_id`.
    bootEnded: *const fn (ctx: *anyopaque, generation: u64, session_id: u64) void,
};

/// A worker's egress session as a lane mints its tokens: its gateway's
/// generation and its id, 0 for none.
pub const WorkerEgress = struct {
    generation: u64,
    session_id: u64,
};

/// The settings `Supervisor.init` copies into the supervisor.
pub const Config = struct {
    hard_timeout_grace_ns: u64 = default_hard_timeout_grace_ns,
    worker_idle_ttl_ns: u64 = default_worker_idle_ttl_ns,
    reaper_interval_ns: u64 = reaping.default_interval_ns,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    /// Borrowed; the caller of `init` keeps it alive past the supervisor.
    /// The launcher forks from it, and the health answer reads its pidfd.
    zygote_process: *zygote.host_client.SpawnedZygote,
    /// Borrowed; see the file header.
    routes: *const Routes,
    /// One pool per worker definition, `pools[d]` for definition `d`, built
    /// at `init` and kept until `deinit`.
    pools: []WorkerPool,
    /// Every worker record: entry `e` of pool `d` is
    /// `records[d * scheduler_limits.capacity.pool_workers_max + e]`, the
    /// entry a `LaunchTicket` names. Allocated at `init` and never freed
    /// while the server runs, so a pointer stays dereferenceable after its
    /// worker leaves; holders tell workers apart by `Record.key`.
    records: []WorkerRecord,
    /// Assigned when a record is built, on the launcher thread only.
    next_worker_id: u64,
    next_worker_generation: u64,
    /// Memory usage in percent of the node's limit (`scheduler_limits.memory`),
    /// cached by the reaper thread for the memory gate, since reading /proc
    /// on every growth check would cost a syscall per request that waits.
    cached_used_percent: std.atomic.Value(u8) = .init(0),
    /// Wakes the reaper for demand reclaim when a launch meets the memory
    /// ladder at or above the high water. The reaper owns the eventfd:
    /// `Reaper.init` publishes it here and `Reaper.deinit` stores -1 before it
    /// closes it, after the launcher, the one producer (`claimLaunch`), has
    /// joined (`reaper/root.zig`). Atomic, so the launcher never reads a torn
    /// value. -1 means unwired, and the nudge then does nothing.
    demand_reclaim_eventfd: std.atomic.Value(std.posix.fd_t) = .init(-1),
    /// Borrowed: the server opens the sink before the supervisor and closes it
    /// after `deinit` (`server/main.zig`). A worker's final drain writes its
    /// last console lines into it, and the usage log appends usage records to
    /// it.
    analytics: *analytics.Sink,
    /// The usage log: the producer side of `usage.jsonl` and the exactly-once
    /// index. Self contained and self locked; the supervisor hands it records
    /// and asks it questions, and owns none of its state.
    usage: usage_log.UsageLog,
    usage_counters: usage_drain.Counters = .{},
    hard_timeout_grace_ns: u64,
    worker_idle_ttl_ns: u64 = default_worker_idle_ttl_ns,
    reaper_interval_ns: u64 = reaping.default_interval_ns,
    memory_pressure_state: reaping.MemoryPressureState = .{},
    /// Set by `setEgressGatewayHooks`; null in fixtures without a gateway.
    egress_gateway: ?EgressGatewayHooks = null,
    /// Borrowed; the caller of `init` owns it and keeps it alive past the
    /// supervisor. null only in fixtures that never launch: a fork with no
    /// prepared leaf has no launch path.
    worker_cgroup_root: ?*WorkerCgroupRoot = null,

    /// Builds one empty pool per definition of `routes` and every record,
    /// vacant. `routes` and `analytics_sink` are borrowed and must outlive
    /// the supervisor; the sink must be open before the first worker exists.
    /// Fails with `error.OutOfMemory`, or with `error.InvalidPoolOptions`
    /// for a definition whose `concurrency` the pool refuses, which the
    /// configuration parser rules out; either way nothing stays allocated.
    pub fn init(
        allocator: std.mem.Allocator,
        zygote_process: *zygote.host_client.SpawnedZygote,
        routes: *const Routes,
        analytics_sink: *analytics.Sink,
        supervisor_config: Config,
        worker_cgroup_root: ?*WorkerCgroupRoot,
    ) error{ OutOfMemory, InvalidPoolOptions }!Supervisor {
        const definition_count = routes.definitionCount();
        const pools = try allocator.alloc(WorkerPool, definition_count);
        errdefer allocator.free(pools);
        var pools_built: usize = 0;
        errdefer for (pools[0..pools_built]) |*definition_pool|
            definition_pool.deinit();
        for (pools, 0..) |*definition_pool, index| {
            const definition = routes.definition(@intCast(index));
            try definition_pool.init(allocator, .{
                .concurrency = definition.settings.limits.concurrency,
                .workers_max = pool_workers_max,
                .launches_max = scheduler_limits.capacity.pool_cold_starts_in_flight_max,
                .waiters_max = pool_limits.pool_waiters_max,
            });
            pools_built += 1;
        }

        const records = try allocator.alloc(WorkerRecord, @as(usize, definition_count) * pool_workers_max);
        errdefer allocator.free(records);
        for (records, 0..) |*record, index| {
            const definition: config.DefinitionIndex = @intCast(index / pool_workers_max);
            record.* = WorkerRecord.vacant(definition, routes.definition(definition).name);
        }

        const usage = try usage_log.UsageLog.init(allocator, analytics_sink);
        return .{
            .allocator = allocator,
            .zygote_process = zygote_process,
            .routes = routes,
            .pools = pools,
            .records = records,
            .next_worker_id = 1,
            .next_worker_generation = 1,
            .analytics = analytics_sink,
            .usage = usage,
            .hard_timeout_grace_ns = supervisor_config.hard_timeout_grace_ns,
            .worker_idle_ttl_ns = supervisor_config.worker_idle_ttl_ns,
            .reaper_interval_ns = supervisor_config.reaper_interval_ns,
            .worker_cgroup_root = worker_cgroup_root,
        };
    }

    /// Tears down, on the calling thread, every worker a record still holds
    /// (`worker_registry.teardown`), then frees the pools and the records.
    /// The caller is the server's teardown, after every thread that calls
    /// into the supervisor has stopped and the reaper's retire queue was
    /// drained, with the analytics sink still open: each teardown drains the
    /// worker's last usage records and console lines into it.
    pub fn deinit(self: *Supervisor) void {
        for (self.records) |*record| {
            if (record.id != 0)
                worker_registry.teardown(self, record);
        }
        for (self.pools) |*definition_pool|
            definition_pool.deinit();
        self.allocator.free(self.records);
        self.allocator.free(self.pools);
        // The sink stays open: the server closes it after this returns, and
        // that close writes and syncs what the teardowns above appended.
        self.usage.deinit();
        self.* = undefined;
    }

    /// The pool of `definition`, which the server's route table assigned.
    pub fn poolFor(self: *Supervisor, definition: config.DefinitionIndex) *WorkerPool {
        std.debug.assert(definition < self.pools.len);
        return &self.pools[definition];
    }

    /// The records of `definition`'s pool, one per table entry, in entry
    /// order.
    pub fn recordsOf(self: *Supervisor, definition: config.DefinitionIndex) []WorkerRecord {
        std.debug.assert(definition < self.pools.len);
        const first = @as(usize, definition) * pool_workers_max;
        return self.records[first..][0..pool_workers_max];
    }

    /// The record storage of the entry `ticket` holds in `definition`'s pool.
    pub fn ticketRecord(self: *Supervisor, definition: config.DefinitionIndex, ticket: pool.LaunchTicket) *WorkerRecord {
        std.debug.assert(ticket.entry < pool_workers_max);
        return &self.recordsOf(definition)[ticket.entry];
    }

    /// The reaper's verdict on the node's memory for pool growth: usage below
    /// `fork_deny_percent`, as the reaper last read it. A lane passes it to
    /// `Pool.growthWanted`; the launcher's claim reads it again
    /// (`claimLaunch`).
    pub fn memoryGate(self: *const Supervisor) bool {
        return self.cached_used_percent.load(.monotonic) < scheduler_limits.memory.fork_deny_percent;
    }

    /// Claims a launch for `definition` when its pool wants one under the
    /// memory gate (`Pool.launchStarted`), and returns its ticket, or null.
    /// At or above `autoscale_high_water_percent` a launch still proceeds,
    /// since the room up to the deny level exists to absorb load while more
    /// nodes come up, but it wakes demand reclaim so idle workers give memory
    /// back at the speed of demand; a claim the gate refuses wakes it too.
    /// The launcher thread calls it (`Deps.claim` in `launcher.zig`).
    pub fn claimLaunch(self: *Supervisor, definition: config.DefinitionIndex) ?pool.LaunchTicket {
        const used_percent = self.cached_used_percent.load(.monotonic);
        const gate_allows = used_percent < scheduler_limits.memory.fork_deny_percent;
        const ticket = self.poolFor(definition).launchStarted(gate_allows);
        if (!gate_allows) {
            self.nudgeDemandReclaim();
        } else if (ticket != null and used_percent >= scheduler_limits.memory.autoscale_high_water_percent) {
            self.nudgeDemandReclaim();
        }
        return ticket;
    }

    /// Settles the usage of the request `request_id` that ended on `worker`,
    /// as `outcome` says, and frees or parks its entry in the worker's
    /// request table (`usage_drain.settleRequest`). The lane that finishes
    /// the request calls it before it gives the request's slot back
    /// (`Pool.release`); it takes only the worker's own locks, and never
    /// fails.
    pub fn settleRequest(self: *Supervisor, worker: *WorkerRecord, request_id: u64, outcome: SettleOutcome) void {
        usage_drain.settleRequest(self.usageDrain(), worker, request_id, outcome);
    }

    /// The status the floors of a dead worker's requests carry: `.memory`
    /// when its sentinel or the kernel ended it for memory, `.crash`
    /// otherwise (`usage_drain.classifyWorkerDeath`). It reads a cgroup file,
    /// so a lane that runs a worker's death calls it once for the worker.
    pub fn classifyWorkerDeath(self: *Supervisor, worker: *WorkerRecord) worker_shared_page.CompletedStatus {
        return usage_drain.classifyWorkerDeath(self.usageDrain(), worker);
    }

    /// Drains every worker's usage ring into the usage log, writing the
    /// usage stream out only when a batch finds it full
    /// (`usage_drain.drainAll`). The exiting thread calls it once the lanes,
    /// the launcher and the metrics thread joined; the server's close of the
    /// sink writes and syncs the rest.
    pub fn drainAllWorkerUsage(self: *Supervisor) void {
        usage_drain.drainAll(self.usageDrain(), self.records);
    }

    /// What the usage drain reaches (`usage_drain.UsageDrain`), all of it
    /// borrowed from this supervisor.
    pub fn usageDrain(self: *Supervisor) usage_drain.UsageDrain {
        return .{
            .allocator = self.allocator,
            .usage = &self.usage,
            .routes = self.routes,
            .counters = &self.usage_counters,
        };
    }

    /// Wakes the reaper for demand reclaim: a launch met the memory ladder at
    /// or above the high water, so idle workers should give memory back at
    /// the speed of demand instead of waiting out the soft-plan sustain.
    /// Eventfd writes coalesce; without wiring, the periodic pass is all
    /// that reclaims.
    pub fn nudgeDemandReclaim(self: *Supervisor) void {
        const fd = self.demand_reclaim_eventfd.load(.acquire);
        if (fd < 0)
            return;
        var one: u64 = 1;
        _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
            error.WouldBlock => {},
            else => std.log.warn("demand reclaim nudge failed: {s}", .{@errorName(err)}),
        };
    }

    /// Installs the egress gateway hooks. The server calls it once, before
    /// the launcher starts.
    pub fn setEgressGatewayHooks(self: *Supervisor, hooks: EgressGatewayHooks) void {
        self.egress_gateway = hooks;
    }

    /// Attaches a worker of `definition_index` to the egress gateway with a
    /// new session built on `wake_set`, the worker's wake set. The worker
    /// definition is the egress security cell, so workers of one definition
    /// share connection pools and never another definition's. null when no
    /// gateway is wired. The launcher thread calls it, for a launch and for
    /// each reattach.
    pub fn attachEgressGatewayForDefinition(
        self: *Supervisor,
        definition_index: config.DefinitionIndex,
        wake_set: *const ipc.egress_shared.WakeSet,
    ) !?EgressGatewayAttachment {
        const hooks = self.egress_gateway orelse return null;
        return try hooks.attach(hooks.ctx, self.routes.definition(definition_index).name, wake_set);
    }

    /// The current egress gateway's generation, 0 while none is current or
    /// none is wired.
    pub fn currentEgressGatewayGeneration(self: *Supervisor) u64 {
        const hooks = self.egress_gateway orelse return 0;
        return hooks.currentGeneration(hooks.ctx);
    }

    /// The egress session of `worker`, which the caller holds a slot of, read
    /// whole under its pool's mutex, since the launcher rewrites it while the
    /// worker serves (`setWorkerEgress`). Session 0 when the pool no longer
    /// holds the worker. A lane reads it at each dispatch.
    pub fn workerEgress(self: *Supervisor, worker: *WorkerRecord) WorkerEgress {
        var reader: EgressReader = .{};
        _ = self.poolFor(worker.definition_index).visitWorker(worker, &reader);
        return reader.egress;
    }

    /// The next live worker that needs a session of gateway `generation`:
    /// the first, in definition and table order, of a definition with an
    /// egress grant whose session is of another gateway. Its control socket
    /// and its wake set are duplicated under its pool's mutex, so its
    /// teardown cannot close either between the read and the dup; a failed
    /// dup leaves `control` invalid, which the launcher answers by retiring
    /// the worker. null when none is left. A worker handed to
    /// `retireForEgress` has left service, so it is never returned again.
    /// Launcher thread only (`Deps.nextStaleEgressWorker` in `launcher.zig`).
    pub fn nextStaleEgressWorker(self: *Supervisor, generation: u64) ?launcher.ReattachTarget {
        std.debug.assert(generation != 0);
        for (self.pools, 0..) |*definition_pool, index| {
            const definition: config.DefinitionIndex = @intCast(index);
            if (!worker_factory.definitionHasEgressGrant(self.routes.definition(definition)))
                continue;
            var finder: StaleEgressFinder = .{ .generation = generation };
            const record = definition_pool.findLive(&finder) orelse continue;
            return .{
                .definition = definition,
                .record = record,
                .worker_key = finder.worker_key,
                .control = finder.control,
                .wake_set = finder.wake_set,
            };
        }
        return null;
    }

    /// Writes session `session_id` of gateway `generation` into the record of
    /// `target`'s worker under its pool's mutex and returns true, so the
    /// lanes mint its tokens for that session from then on; false, writing
    /// nothing, once the worker left service or its record holds another
    /// worker. Launcher thread only (`Deps.setWorkerEgress`).
    pub fn setWorkerEgress(
        self: *Supervisor,
        target: *const launcher.ReattachTarget,
        generation: u64,
        session_id: u64,
    ) bool {
        var writer: EgressWriter = .{
            .worker_key = target.worker_key,
            .egress = .{ .generation = generation, .session_id = session_id },
        };
        _ = self.poolFor(target.definition).visitWorker(target.record, &writer);
        return writer.written;
    }

    /// Takes `target`'s worker out of service because no gateway could give
    /// it a session (`Pool.retireForEgress`) and returns the death, which the
    /// caller announces to the lanes that hold or read the worker, queueing
    /// the retirement at once when none does. null, changing nothing, once
    /// the worker left service or its record holds another worker. Launcher
    /// thread only (`Deps.retireForEgress`).
    pub fn retireForEgress(self: *Supervisor, target: *const launcher.ReattachTarget) ?WorkerPool.Death {
        return self.poolFor(target.definition).retireForEgress(target.record, target.worker_key);
    }

    /// Takes the live worker whose session is `session_id` of gateway
    /// `generation`, which that gateway removed, off the session under its
    /// pool's mutex: its record names no session from then on, so the lanes
    /// mint it no token and the next reattach pass, which takes every live
    /// worker off the current gateway, gives it a new one. Returns whether a
    /// live worker held that session; generations never repeat, so the pair
    /// names one session for the server's life. Launcher thread only
    /// (`Deps.dropEgressSession`).
    pub fn dropEgressSession(self: *Supervisor, generation: u64, session_id: u64) bool {
        std.debug.assert(generation != 0);
        for (self.pools) |*definition_pool| {
            var dropper: EgressSessionDropper = .{ .generation = generation, .session_id = session_id };
            if (definition_pool.findLive(&dropper) != null)
                return true;
        }
        return false;
    }

    /// Copies the token key of gateway `generation` into `out` for a launch's
    /// boot token, and returns false when that gateway is no longer current
    /// or none is wired.
    pub fn egressGatewayKeyFor(self: *Supervisor, generation: u64, out: *ipc.egress_token.Key) bool {
        const hooks = self.egress_gateway orelse return false;
        return hooks.keyFor(hooks.ctx, generation, out);
    }

    /// Spawns an egress gateway when none is current, as the launcher does
    /// after a loss; does nothing when none is wired.
    pub fn prewarmEgressGateway(self: *Supervisor) !void {
        const hooks = self.egress_gateway orelse return;
        try hooks.prewarm(hooks.ctx);
    }

    /// Ends the boot token of egress session `session_id` of gateway
    /// `generation` at the gateway, best effort, when its worker reports
    /// `WorkerReady`; does nothing when none is wired.
    pub fn endEgressGatewayBootToken(self: *Supervisor, generation: u64, session_id: u64) void {
        const hooks = self.egress_gateway orelse return;
        hooks.bootEnded(hooks.ctx, generation, session_id);
    }
};

// The visitors that run under a pool's mutex (`Pool.findLive`,
// `Pool.visitWorker`): each reads or writes only a record's egress session
// and duplicates its descriptors.

/// Picks the first worker whose session is not of gateway `generation` and
/// takes its key and dups of its control socket and wake set.
const StaleEgressFinder = struct {
    generation: u64,
    worker_key: server_lifecycle.WorkerKey = undefined,
    control: fd_mod.OwnedFd = .{},
    wake_set: ipc.egress_shared.WakeSet = .{},

    pub fn visit(self: *StaleEgressFinder, worker: *WorkerRecord) bool {
        if (worker.egress_gateway_generation == self.generation)
            return false;
        self.worker_key = worker.key();
        self.control = fd_mod.OwnedFd.dupCloexec(worker.handle.control_fd) catch return true;
        self.wake_set = worker.egress_wake_set.dup() catch {
            self.control.deinit();
            return true;
        };
        return true;
    }
};

/// Picks the worker whose session is `session_id` of gateway `generation`
/// and leaves its record with no session.
const EgressSessionDropper = struct {
    generation: u64,
    session_id: u64,

    pub fn visit(self: *EgressSessionDropper, worker: *WorkerRecord) bool {
        if (worker.egress_gateway_generation != self.generation)
            return false;
        if (worker.egress_gateway_session_id != self.session_id)
            return false;
        worker.egress_gateway_generation = 0;
        worker.egress_gateway_session_id = 0;
        return true;
    }
};

/// Copies a worker's egress session.
const EgressReader = struct {
    egress: WorkerEgress = .{ .generation = 0, .session_id = 0 },

    pub fn visit(self: *EgressReader, worker: *WorkerRecord, state: pool.EntryState) void {
        _ = state;
        self.egress = .{
            .generation = worker.egress_gateway_generation,
            .session_id = worker.egress_gateway_session_id,
        };
    }
};

/// Writes a worker's egress session when the record still holds the worker
/// `worker_key` names and it still serves.
const EgressWriter = struct {
    worker_key: server_lifecycle.WorkerKey,
    egress: WorkerEgress,
    written: bool = false,

    pub fn visit(self: *EgressWriter, worker: *WorkerRecord, state: pool.EntryState) void {
        if (state != .live)
            return;
        if (!worker.key().eql(self.worker_key))
            return;
        worker.egress_gateway_generation = self.egress.generation;
        worker.egress_gateway_session_id = self.egress.session_id;
        self.written = true;
    }
};
