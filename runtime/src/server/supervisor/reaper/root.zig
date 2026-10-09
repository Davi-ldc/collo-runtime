//! The reaper: the node's one thread that retires workers. Every worker that
//! leaves its pool, whatever ended it, is torn down here, off every request
//! path: SIGKILL, the exit wait, the final drains of its usage and console
//! rings, and its descriptors, wake set, mappings and cgroup leaf released
//! (`worker_registry.teardown`), then `Pool.remove`, which frees its table
//! entry for a later launch. Its egress session needs nothing: the exit
//! hangs up the liveness pipe its gateway watches, and the gateway drops the
//! session. A failed launch's child and cgroup leaf are torn down here too
//! (`AbandonedChild.reap` in `host/launch.zig`).
//!
//! Work reaches the reaper three ways. Other threads queue what their pool
//! calls finished (`queueRetirement`): a lane whose `Pool.release`,
//! `Pool.transferReader` or `Pool.markDead` said `.retire`, or the
//! launcher's `Deps.retireForEgress`, whose `Pool.retireForEgress` did. The
//! launcher's failed launches queue their leftovers (`queueLeftovers`). The
//! reaper's own passes retire idle workers on its timer, on memory pressure
//! and on demand reclaim (`reaping.zig`), and it watches the pidfds of the
//! live workers no lane reads, rescanning them before every wait, so a lane
//! that gives up reading a worker only wakes it (`wakeForPidfdScan`); a lane
//! watches the pidfds of the workers it reads. When the reaper sees a death
//! first, it marks the worker dead in its pool and posts `worker_died` to
//! every lane that holds a slot of it or reads it.
//!
//! After a removal its definition's pool may grow again, and the reaper
//! submits a launch when the pool wants one. Waiters nothing can serve are
//! not the reaper's to answer: the lane or launcher that left a pool with no
//! live worker and no launch in flight strands them (`Pool.takeStranded`).
//! The lanes and the launcher are reached through `Deps`, since they belong
//! to the ingress service.
//!
//! The retire queue never fills: it holds at most one entry per record, since
//! a pool reports each finished worker once and keeps its entry until the
//! reaper's `remove`, plus one per launch the launcher's table holds, since
//! the launcher counts the leftovers it handed over until the reaper reports
//! them torn down (`Deps.leftoversReaped`).
//!
//! - `memory.zig`: the readings of node and worker memory and the victim
//!   score.
//! - `reaping.zig`: the idle and memory-pressure passes and their plans.
//!
//! Threads: `queueRetirement`, `queueLeftovers`, `wakeForPidfdScan`, `stop`
//! and `countersSnapshot` run on any thread; `init`, `start`, `join`,
//! `drainRetirements` and `deinit` on the thread that owns the reaper, the
//! ingress service's; everything else on the reaper thread, or on the
//! owner's thread while no reaper thread runs. `mutex` is a leaf: the reaper
//! takes a pool's mutex only inside a pool method, never with `mutex` held,
//! and calls `Deps` with neither held.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;
const lifecycle = @import("collo_server_lifecycle");
const config = @import("collo_server_config");

const pool = @import("../pool.zig");
const launcher = @import("../launcher.zig");
const scheduler_limits = @import("../scheduler_limits.zig");
const worker_table = @import("../worker_table.zig");
const supervisor_mod = @import("../supervisor.zig");
const worker_registry = @import("../worker_registry.zig");
const usage_drain = @import("../usage_drain.zig");

pub const memory = @import("memory.zig");
pub const reaping = @import("reaping.zig");

const Supervisor = supervisor_mod.Supervisor;
const WorkerPool = supervisor_mod.WorkerPool;
const WorkerRecord = worker_table.Record;

const pool_workers_max = scheduler_limits.capacity.pool_workers_max;

/// The PSI trigger, the demand-reclaim eventfd and the wake eventfd lead the
/// poll set; each watched pidfd follows.
const poll_fixed_sources: usize = 3;
const poll_wake: usize = 0;
const poll_demand_reclaim: usize = 1;
const poll_memory_pressure: usize = 2;

/// How long the thread waits before polling again after poll(2) failed,
/// which it does only when the kernel lacks memory for the poll table.
const poll_retry_ns: u64 = 10 * std.time.ns_per_ms;

/// Why a worker is retired. The reaper counts it, and a worker that died
/// gets its cgroup's CPU burn logged before the teardown removes the cgroup.
pub const RetireReason = enum {
    /// `Pool.markDead` took it out of service: a fault, its exit or its
    /// deadline's grace.
    died,
    /// `Pool.retireIdle` took it out of service: its idle TTL or memory
    /// pressure.
    idle,
    /// `Pool.retireForEgress` took it out of service: its gateway was lost
    /// and no other one could give it a session (`Launcher.gatewayLost` in
    /// `launcher.zig`).
    egress_reattach,
};

/// What the reaper calls to reach the lanes and the launcher. Each call gets
/// `ctx` back unchanged and runs on the thread that drives the reaper.
pub const Deps = struct {
    ctx: *anyopaque,
    /// Posts `release_worker{worker_key, epoch}` to `lane`, the reader of an
    /// idle worker the reaper retires. False when the lane's queue refused
    /// it; the reaper posts again on its next pass.
    postReleaseWorker: *const fn (ctx: *anyopaque, lane: pool.LaneId, worker_key: lifecycle.WorkerKey, epoch: pool.ReaderEpoch) bool,
    /// Posts `worker_died` for `worker_key`, whose process exited, to `lane`,
    /// which holds a slot of the worker or reads it. False when the lane's
    /// queue refused it; that lane then learns of the death from the
    /// worker's own channels or its requests' deadlines.
    postWorkerDied: *const fn (ctx: *anyopaque, lane: pool.LaneId, worker_key: lifecycle.WorkerKey) bool,
    /// Asks the launcher to claim launches for `definition`
    /// (`Launcher.submit`): the reaper's removal freed a table entry while
    /// the pool wants to grow, which it says with `.capacity`.
    submit: *const fn (ctx: *anyopaque, definition: config.DefinitionIndex, reason: launcher.GrowthReason) void,
    /// The leftovers of one failed launch are torn down:
    /// `Launcher.leftoversReaped`, which gives the launch table the room
    /// they held.
    leftoversReaped: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    /// Borrowed; outlives the reaper. Its pools, records, memory gate and
    /// usage drains are what the reaper works on.
    supervisor: *Supervisor,
    deps: Deps,
};

pub const Counters = struct {
    retired_died: u64 = 0,
    retired_idle: u64 = 0,
    retired_egress_reattach: u64 = 0,
    /// Failed launches whose child and leaf were torn down.
    leftovers_reaped: u64 = 0,
    /// Exits the reaper saw before any lane, among the workers no lane
    /// reads.
    deaths_seen: u64 = 0,
    /// Idle retirements by cause. A memory-pressure reap counts under the
    /// pressure it found, demand reclaim included.
    idle_ttl_retirements: u64 = 0,
    reaps_soft: u64 = 0,
    reaps_hard: u64 = 0,
    reaps_critical: u64 = 0,
    /// Demand-reclaim wakes that found memory pressure, counted before their
    /// reap runs, so one that retires nothing still counts.
    demand_reclaims: u64 = 0,
    /// Crossings of `autoscale_high_water_percent` in either direction, the
    /// node's scale-out signal.
    high_water_transitions: u64 = 0,
    launches_submitted: u64 = 0,
    release_posts_failed: u64 = 0,
    worker_died_posts_failed: u64 = 0,
    poll_failures: u64 = 0,
};

/// One entry of the retire queue.
const Retirement = union(enum) {
    worker: struct { record: *WorkerRecord, reason: RetireReason },
    leftovers: launcher.Leftovers,
};

/// A live worker no lane reads, whose pidfd the reaper polls.
const Watched = struct {
    record: *WorkerRecord,
    key: lifecycle.WorkerKey,
    pidfd: std.posix.fd_t,
};

/// An idle retirement that waits for its reader to give the role up.
const PendingRelease = struct {
    record: *WorkerRecord,
    key: lifecycle.WorkerKey,
    tenure: pool.ReaderTenure,
};

pub const Reaper = struct {
    gpa: std.mem.Allocator,
    supervisor: *Supervisor,
    deps: Deps,
    /// Guards the retire queue and `counters`.
    mutex: std.Thread.Mutex,
    /// A ring of `queue_len` entries from `queue_head`, oldest first, sized
    /// at `init` (see the file header).
    queue: []Retirement,
    queue_head: usize,
    queue_len: usize,
    counters: Counters,
    /// Written by `queueRetirement`, `queueLeftovers`, `wakeForPidfdScan`
    /// and `stop`.
    wake: fd_mod.OwnedFd,
    /// Written by `Supervisor.nudgeDemandReclaim`, which reads it from
    /// `Supervisor.demand_reclaim_eventfd`: `init` publishes it there and
    /// `deinit` withdraws it, after the launcher, its one producer, joined.
    demand_reclaim: fd_mod.OwnedFd,
    /// The PSI trigger, which wakes the reaper as soon as memory stalls.
    /// Null when the kernel has no PSI or refuses the trigger, as kernels
    /// before Linux 6.4 do for a process without `CAP_SYS_RESOURCE`
    /// (`MemoryPressureWake` in `memory.zig`), or once the trigger reported an
    /// error. Pressure is then read only by the interval pass and demand
    /// reclaim, so reaping loses latency and nothing else.
    memory_pressure_wake: ?memory.MemoryPressureWake,
    stop_requested: std.atomic.Value(bool),
    thread: ?std.Thread,

    // Reaper thread only.

    watched: []Watched,
    watched_len: usize,
    pending_releases: []PendingRelease,
    pending_releases_len: usize,
    pollfds: []std.posix.pollfd,
    next_pass_ns: u64,
    /// What a failed memory read stands on (`readPressure`).
    last_reading: memory.LastReading,
    /// The last memory reading was at or above the high water.
    above_high_water: bool,
    poll_failing: bool,

    /// Prepares the reaper in place: the retire queue and the reaper
    /// thread's tables, sized from the supervisor's pools, the wake and
    /// demand-reclaim eventfds and, when the kernel allows it, the PSI
    /// trigger. Publishes the demand-reclaim eventfd for
    /// `Supervisor.nudgeDemandReclaim`. The thread starts at `start`. Fails
    /// with `error.OutOfMemory` or an eventfd's error, leaving nothing
    /// allocated.
    pub fn init(self: *Reaper, gpa: std.mem.Allocator, options: Options) !void {
        const supervisor = options.supervisor;
        const definition_count: usize = supervisor.routes.definitionCount();
        const records_max = supervisor.records.len;
        std.debug.assert(records_max == definition_count * pool_workers_max);
        // The launcher's table: each pool's `launches_max` per definition
        // (`Launcher.init`), which bounds the leftovers it hands over.
        const leftovers_max = definition_count * scheduler_limits.capacity.pool_cold_starts_in_flight_max;

        const queue = try gpa.alloc(Retirement, records_max + leftovers_max);
        errdefer gpa.free(queue);
        const watched = try gpa.alloc(Watched, records_max);
        errdefer gpa.free(watched);
        const pending_releases = try gpa.alloc(PendingRelease, records_max);
        errdefer gpa.free(pending_releases);
        const pollfds = try gpa.alloc(std.posix.pollfd, poll_fixed_sources + records_max);
        errdefer gpa.free(pollfds);
        var wake = fd_mod.OwnedFd.fromRaw(try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        errdefer wake.deinit();
        const demand_reclaim = fd_mod.OwnedFd.fromRaw(try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        const memory_pressure_wake: ?memory.MemoryPressureWake = memory.MemoryPressureWake.init() catch |err| blk: {
            std.log.warn(
                "memory-pressure PSI trigger unavailable: {s}; the reaper reads memory on its interval and on demand reclaim only",
                .{memory.psiRefusalReason(err)},
            );
            break :blk null;
        };

        self.* = .{
            .gpa = gpa,
            .supervisor = supervisor,
            .deps = options.deps,
            .mutex = .{},
            .queue = queue,
            .queue_head = 0,
            .queue_len = 0,
            .counters = .{},
            .wake = wake,
            .demand_reclaim = demand_reclaim,
            .memory_pressure_wake = memory_pressure_wake,
            .stop_requested = .init(false),
            .thread = null,
            .watched = watched,
            .watched_len = 0,
            .pending_releases = pending_releases,
            .pending_releases_len = 0,
            .pollfds = pollfds,
            .next_pass_ns = 0,
            .last_reading = .{},
            .above_high_water = false,
            .poll_failing = false,
        };
        supervisor.demand_reclaim_eventfd.store(self.demand_reclaim.fd(), .release);
    }

    /// Starts the reaper thread. Fails with the spawn's error, and the reaper
    /// then stays stopped.
    pub fn start(self: *Reaper) std.Thread.SpawnError!void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Hands the reaper a worker its pool reported finished (`.retire`), to
    /// tear down and remove. Any thread; never blocks beyond `mutex`. Each
    /// finished worker is queued once, by the caller its pool answered.
    pub fn queueRetirement(self: *Reaper, worker: *WorkerRecord, reason: RetireReason) void {
        self.enqueue(.{ .worker = .{ .record = worker, .reason = reason } });
    }

    /// Hands the reaper what a failed launch left, which it owns from the
    /// call. Any thread; the caller is the launcher's `Deps.failed`. A
    /// `Leftovers` that holds no child or leaf needs nothing and is dropped.
    pub fn queueLeftovers(self: *Reaper, leftovers: launcher.Leftovers) void {
        if (!leftovers.holdsChild()) return;
        self.enqueue(.{ .leftovers = leftovers });
    }

    /// Wakes the reaper to rescan the pidfds it watches: a lane stopped
    /// reading a live worker (`Transfer.vacated`). Any thread.
    pub fn wakeForPidfdScan(self: *Reaper) void {
        self.signalWake();
    }

    /// Asks the thread to stop. Any thread. Retirements still queued wait for
    /// `drainRetirements`.
    pub fn stop(self: *Reaper) void {
        self.stop_requested.store(true, .release);
        self.signalWake();
    }

    /// Waits for the thread `start` spawned to exit after `stop`.
    pub fn join(self: *Reaper) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Carries out every queued retirement on the calling thread, while no
    /// reaper thread runs, and returns how many. At shutdown the service
    /// calls it after `join` and after every producer, the lanes and the
    /// launcher, joined, and the teardowns block here, since shutdown owns
    /// the latency.
    pub fn drainRetirements(self: *Reaper) usize {
        std.debug.assert(self.thread == null);
        var carried_out: usize = 0;
        while (self.dequeue()) |retirement| {
            var owned = retirement;
            self.carryOut(&owned);
            carried_out += 1;
        }
        return carried_out;
    }

    /// The idle pass at `now_ns`, on the calling thread while no reaper
    /// thread runs; the thread runs it on its timer. It asks again each
    /// reader that still holds a worker retiring idle, since a post can fail
    /// and a reader ignores a request for a tenure it no longer holds, then
    /// retires the idle workers past their idle TTL (`reaping.idleTtlPass`)
    /// and returns how many of those it retired.
    pub fn retireIdleWorkers(self: *Reaper, now_ns: u64) usize {
        std.debug.assert(self.thread == null);
        return self.idlePass(now_ns);
    }

    /// Withdraws the demand-reclaim eventfd from the supervisor, closes the
    /// reaper's descriptors and frees its tables, after `drainRetirements`.
    pub fn deinit(self: *Reaper) void {
        std.debug.assert(self.thread == null);
        std.debug.assert(self.queue_len == 0);
        self.supervisor.demand_reclaim_eventfd.store(-1, .release);
        if (self.memory_pressure_wake) |*wake| wake.deinit();
        self.demand_reclaim.deinit();
        self.wake.deinit();
        self.gpa.free(self.pollfds);
        self.gpa.free(self.pending_releases);
        self.gpa.free(self.watched);
        self.gpa.free(self.queue);
        self.* = undefined;
    }

    pub fn countersSnapshot(self: *Reaper) Counters {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.counters;
    }

    /// Takes an idle worker a pass chose out of service (`Pool.retireIdle`)
    /// and starts its retirement: torn down now when no lane reads it, or a
    /// `release_worker` to its reader, whose `transferReader` then queues it.
    /// False when the pool says it is no longer idle. Reaper thread only.
    pub fn retireIdleWorker(self: *Reaper, definition: config.DefinitionIndex, worker: *WorkerRecord) bool {
        switch (self.supervisor.poolFor(definition).retireIdle(worker)) {
            .not_idle => return false,
            .retire => self.retire(worker, .idle),
            .release_reader => |tenure| self.requestRelease(worker, tenure),
        }
        return true;
    }

    /// Adds `amount` to the counter `field`. Any thread.
    pub fn count(self: *Reaper, comptime field: []const u8, amount: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        @field(self.counters, field) += amount;
    }

    /// Reads node memory pressure for a pass, publishes it for the memory
    /// gate (`Supervisor.memoryGate`) and counts high-water crossings. A
    /// reading that did not happen never answers calm, since no pressure
    /// disarms the reap plans and demand reclaim exactly when they may be
    /// needed: a failed read acts on the last reading that succeeded, or as
    /// critical (`memory.LastReading`).
    fn readPressure(self: *Reaper) memory.MemoryPressure {
        const pressure = self.last_reading.settle(memory.readMemoryPressure(self.gpa));
        self.supervisor.cached_used_percent.store(pressure.used_percent, .monotonic);
        const above = pressure.used_percent >= scheduler_limits.memory.autoscale_high_water_percent;
        if (above != self.above_high_water) {
            self.above_high_water = above;
            self.count("high_water_transitions", 1);
        }
        return pressure;
    }

    fn signalWake(self: *Reaper) void {
        const one: u64 = 1;
        _ = std.posix.write(self.wake.fd(), std.mem.asBytes(&one)) catch |err| switch (err) {
            // The counter is at its maximum, so a wake is already pending.
            error.WouldBlock => return,
            // The periodic pass takes the queue anyway.
            else => std.log.err("reaper wake write failed: {s}", .{@errorName(err)}),
        };
    }

    fn enqueue(self: *Reaper, retirement: Retirement) void {
        self.mutex.lock();
        if (self.queue_len == self.queue.len) {
            self.mutex.unlock();
            // The bound in the file header rules this out; a worker dropped
            // here keeps its entry until `Supervisor.deinit` tears it down.
            std.log.err("reaper retire queue full; a {s} retirement is dropped", .{@tagName(retirement)});
            return;
        }
        self.queue[(self.queue_head + self.queue_len) % self.queue.len] = retirement;
        self.queue_len += 1;
        self.mutex.unlock();
        self.signalWake();
    }

    fn dequeue(self: *Reaper) ?Retirement {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue_len == 0) return null;
        const retirement = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % self.queue.len;
        self.queue_len -= 1;
        return retirement;
    }

    fn carryOut(self: *Reaper, retirement: *Retirement) void {
        switch (retirement.*) {
            .worker => |queued| self.retire(queued.record, queued.reason),
            .leftovers => |*leftovers| {
                leftovers.child.reap();
                self.deps.leftoversReaped(self.deps.ctx);
                self.count("leftovers_reaped", 1);
            },
        }
    }

    /// Tears a finished worker down, removes it from its pool, and submits a
    /// launch when the entry it freed lets the pool grow.
    fn retire(self: *Reaper, worker: *WorkerRecord, reason: RetireReason) void {
        const definition = worker.definition_index;
        const definition_pool = self.supervisor.poolFor(definition);
        // A finished worker never returns to service, so this check holds
        // until `remove`, which only this thread calls.
        const view = definition_pool.inspect(worker) orelse {
            std.log.err("a retirement names a record its pool does not hold: worker_id={d}", .{worker.id});
            return;
        };
        if (view.state == .live or view.slots_held != 0 or view.reader != null) {
            std.log.err("a retirement names a worker still in use: worker_id={d} state={s} slots_held={d}", .{
                worker.id,
                @tagName(view.state),
                view.slots_held,
            });
            return;
        }
        self.forgetPendingRelease(worker);
        if (reason == .died) {
            const drain = self.supervisor.usageDrain();
            usage_drain.noteWorkerDeathBurn(drain, worker, usage_drain.classifyWorkerDeath(drain, worker));
        }
        const worker_id = worker.id;
        worker_registry.teardown(self.supervisor, worker);
        // Checked above: dead or retiring, with no holder and no reader, which
        // a worker out of service never regains. A pool that refuses anyway
        // keeps the entry, and the definition one worker short.
        definition_pool.remove(worker) catch |err| {
            std.log.err("a retired worker's pool kept its entry: worker_id={d}: {s}", .{ worker_id, @errorName(err) });
            return;
        };
        switch (reason) {
            .died => self.count("retired_died", 1),
            .idle => self.count("retired_idle", 1),
            .egress_reattach => self.count("retired_egress_reattach", 1),
        }
        if (definition_pool.growthWanted(self.supervisor.memoryGate())) {
            self.deps.submit(self.deps.ctx, definition, .capacity);
            self.count("launches_submitted", 1);
        }
    }

    /// Asks the reader of an idle worker that just left service to give its
    /// role up, and keeps asking on each idle pass (`retryReleases`) until it
    /// does.
    fn requestRelease(self: *Reaper, worker: *WorkerRecord, tenure: pool.ReaderTenure) void {
        const key = worker.key();
        // Bounded by the records: a worker is retired idle once, and its
        // entry leaves the list before its storage serves another worker.
        std.debug.assert(self.pending_releases_len < self.pending_releases.len);
        self.pending_releases[self.pending_releases_len] = .{ .record = worker, .key = key, .tenure = tenure };
        self.pending_releases_len += 1;
        self.postRelease(key, tenure);
    }

    fn postRelease(self: *Reaper, key: lifecycle.WorkerKey, tenure: pool.ReaderTenure) void {
        if (!self.deps.postReleaseWorker(self.deps.ctx, tenure.lane, key, tenure.epoch))
            self.count("release_posts_failed", 1);
    }

    /// Posts `release_worker` again for each idle retirement whose worker
    /// still waits for the reader its tenure names, and forgets the ones
    /// whose reader let go.
    fn retryReleases(self: *Reaper) void {
        var kept: usize = 0;
        for (self.pending_releases[0..self.pending_releases_len]) |pending| {
            const view = self.supervisor.poolFor(pending.record.definition_index).inspect(pending.record) orelse continue;
            if (view.state != .retiring) continue;
            const reader = view.reader orelse continue;
            if (reader.lane != pending.tenure.lane or reader.epoch != pending.tenure.epoch) continue;
            self.postRelease(pending.key, pending.tenure);
            self.pending_releases[kept] = pending;
            kept += 1;
        }
        self.pending_releases_len = kept;
    }

    fn idlePass(self: *Reaper, now_ns: u64) usize {
        self.retryReleases();
        return reaping.idleTtlPass(self, now_ns);
    }

    fn forgetPendingRelease(self: *Reaper, worker: *WorkerRecord) void {
        var index: usize = 0;
        while (index < self.pending_releases_len) {
            if (self.pending_releases[index].record == worker) {
                self.pending_releases_len -= 1;
                self.pending_releases[index] = self.pending_releases[self.pending_releases_len];
            } else {
                index += 1;
            }
        }
    }

    fn threadMain(self: *Reaper) void {
        self.runPasses(process.monotonicNowNsOrZero());
        // The loop ends only on `stop`; every turn waits in `poll`, so it
        // never spins.
        while (!self.stop_requested.load(.acquire)) {
            self.waitAndHandle();
            self.processQueue();
        }
    }

    /// Carries out queued retirements until the queue is empty or a stop is
    /// asked; `drainRetirements` takes the rest.
    fn processQueue(self: *Reaper) void {
        while (!self.stop_requested.load(.acquire)) {
            var retirement = self.dequeue() orelse return;
            self.carryOut(&retirement);
        }
    }

    /// The periodic pass: a memory reading, the idle pass, then the reap plan
    /// the pressure calls for.
    fn runPasses(self: *Reaper, now_ns: u64) void {
        const pressure = self.readPressure();
        const ttl_retired = self.idlePass(now_ns);
        var pressure_retired: usize = 0;
        if (reaping.memoryPressurePlan(&self.supervisor.memory_pressure_state, now_ns, pressure)) |plan|
            pressure_retired = self.reapUnder(pressure.mode, now_ns, plan);
        self.next_pass_ns = now_ns +| self.supervisor.reaper_interval_ns;
        if (ttl_retired != 0 or pressure_retired != 0)
            std.log.info("reaper pass idle_workers={d} pressure_workers={d}", .{ ttl_retired, pressure_retired });
    }

    /// Demand reclaim, run when a launch met the memory gate at or above the
    /// high water or was refused by it (`Supervisor.claimLaunch`). The claim
    /// is the signal, so it skips the soft plan's sustain and retires a
    /// small batch of idle workers. Below soft pressure it does nothing.
    fn demandPass(self: *Reaper) void {
        const pressure = self.readPressure();
        if (pressure.mode == .none) return;
        self.count("demand_reclaims", 1);
        const retired = self.reapUnder(pressure.mode, process.monotonicNowNsOrZero(), reaping.demand_plan);
        if (retired != 0)
            std.log.info("demand reclaim retired={d} used_percent={d}", .{ retired, pressure.used_percent });
    }

    fn reapUnder(self: *Reaper, mode: memory.MemoryPressureMode, now_ns: u64, plan: reaping.MemoryPressurePlan) usize {
        const retired = reaping.reapWithPlan(self, now_ns, plan);
        switch (mode) {
            .none => {},
            .soft => self.count("reaps_soft", retired),
            .hard => self.count("reaps_hard", retired),
            .critical => self.count("reaps_critical", retired),
        }
        return retired;
    }

    /// Rescans the workers to watch, waits until a source is ready or the
    /// next pass is due, and handles what is ready.
    fn waitAndHandle(self: *Reaper) void {
        self.scanReaderless();
        const count_polled = self.buildPollSet();
        const now_ns = process.monotonicNowNsOrZero();
        const ready = std.posix.poll(self.pollfds[0..count_polled], msUntil(now_ns, self.next_pass_ns)) catch |err| {
            self.count("poll_failures", 1);
            if (!self.poll_failing)
                std.log.warn("reaper poll failed, retrying: {s}", .{@errorName(err)});
            self.poll_failing = true;
            std.Thread.sleep(poll_retry_ns);
            return;
        };
        self.poll_failing = false;
        if (self.stop_requested.load(.acquire)) return;

        var pressure_event = false;
        if (ready != 0) {
            if (self.pollfds[poll_wake].revents != 0)
                drainCounter(self.wake.fd(), "wake");
            if (self.pollfds[poll_memory_pressure].revents != 0)
                pressure_event = self.memoryPressureEvent(self.pollfds[poll_memory_pressure].revents);
            for (self.pollfds[poll_fixed_sources..count_polled], 0..) |polled, index| {
                if (polled.revents != 0)
                    self.workerExited(self.watched[index]);
            }
            if (self.pollfds[poll_demand_reclaim].revents != 0) {
                drainCounter(self.demand_reclaim.fd(), "demand reclaim");
                self.demandPass();
            }
        }
        const after_ns = process.monotonicNowNsOrZero();
        if (pressure_event or after_ns >= self.next_pass_ns)
            self.runPasses(after_ns);
    }

    /// True when the PSI trigger fired. A trigger in error stops serving,
    /// and from then on only the interval pass and demand reclaim read
    /// pressure.
    fn memoryPressureEvent(self: *Reaper, revents: i16) bool {
        if ((revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
            std.log.warn("memory-pressure PSI trigger failed; the reaper reads memory on its interval and on demand reclaim only", .{});
            if (self.memory_pressure_wake) |*wake| wake.deinit();
            self.memory_pressure_wake = null;
            return false;
        }
        return (revents & std.posix.POLL.PRI) != 0;
    }

    /// A watched worker's pidfd reported its exit. The first caller of
    /// `markDead` owns the death: the lanes that hold a slot of the worker
    /// or read it learn of it by `worker_died`, and a worker no lane holds
    /// is retired at once.
    fn workerExited(self: *Reaper, watched: Watched) void {
        const definition = watched.record.definition_index;
        const death = self.supervisor.poolFor(definition).markDead(watched.record, watched.key) orelse return;
        self.count("deaths_seen", 1);
        var failed: u64 = 0;
        for (death.slice()) |lane| {
            if (!self.deps.postWorkerDied(self.deps.ctx, lane, watched.key))
                failed += 1;
        }
        self.count("worker_died_posts_failed", failed);
        if (death.retire)
            self.retire(watched.record, .died);
    }

    /// Lists the live workers no lane reads, which are idle, since the first
    /// lane to take a slot of a worker becomes its reader.
    fn scanReaderless(self: *Reaper) void {
        self.watched_len = 0;
        for (self.supervisor.pools, 0..) |*definition_pool, definition| {
            var buffer: [pool_workers_max]WorkerPool.IdleWorker = undefined;
            for (definition_pool.idleWorkers(&buffer)) |idle| {
                if (idle.reader != null) continue;
                std.debug.assert(idle.worker.definition_index == definition);
                self.watched[self.watched_len] = .{
                    .record = idle.worker,
                    .key = idle.worker.key(),
                    .pidfd = idle.worker.handle.pidfd,
                };
                self.watched_len += 1;
            }
        }
    }

    fn buildPollSet(self: *Reaper) usize {
        self.pollfds[poll_wake] = .{ .fd = self.wake.fd(), .events = std.posix.POLL.IN, .revents = 0 };
        self.pollfds[poll_demand_reclaim] = .{ .fd = self.demand_reclaim.fd(), .events = std.posix.POLL.IN, .revents = 0 };
        // poll(2) ignores a negative descriptor, which keeps the layout fixed
        // without a PSI trigger.
        self.pollfds[poll_memory_pressure] = .{
            .fd = if (self.memory_pressure_wake) |wake| wake.fd else -1,
            .events = std.posix.POLL.PRI,
            .revents = 0,
        };
        for (self.watched[0..self.watched_len], 0..) |watched, index| {
            self.pollfds[poll_fixed_sources + index] = .{ .fd = watched.pidfd, .events = std.posix.POLL.IN, .revents = 0 };
        }
        return poll_fixed_sources + self.watched_len;
    }
};

/// Empties an eventfd's counter. A read that fails is logged; the eventfd
/// only wakes the thread, which finds its work in the queue and the pools.
fn drainCounter(fd: std.posix.fd_t, comptime name: []const u8) void {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => std.log.warn("reaper " ++ name ++ " eventfd read failed: {s}", .{@errorName(err)}),
    };
}

/// Milliseconds from `now_ns` until `deadline_ns`, rounded up.
fn msUntil(now_ns: u64, deadline_ns: u64) i32 {
    const remaining_ns = deadline_ns -| now_ns;
    // The divisor is a nonzero constant.
    const remaining_ms = std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch unreachable;
    return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
}
