//! The engine's owner thread for one run: its state and its loop. Each
//! iteration takes what producers queued (submitted fetches, cancels, credit
//! sources with released credit), collects DNS answers, rebuilds the watch
//! list when anything watched changed, and waits once on the data driver,
//! whose result it routes to the HTTP/2 streams (`h2.zig`), the HTTP/1
//! fetches (`h1.zig`) or the dials (`dial.zig`).
//!
//! Every fetch the owner holds is held in exactly one place: a dial's
//! waiters, the HTTP/2 streams, the HTTP/1 fetches, the pool waiters or the
//! retries. Each place owns the fetch's `Hop`, which holds the engine's task
//! reference and the hop's plan, so moving a fetch moves both and settling
//! it releases both. A cancel finds the fetch wherever it is. Each HTTP/2
//! stream and HTTP/1 fetch holds one credit source from its start to its end
//! (`credit_sources.zig`), so a credit reaches it, or nothing, in O(1).
//!
//! Streams and HTTP/1 fetches are heap objects, which watch contexts and
//! credit sources point at; every change to what is watched sets
//! `watch_dirty`, and the list is rebuilt before the next wait. When the run
//! ends, or fails, `settleAll` settles every fetch, retires every source and
//! releases every wire and socket through the data driver before the state
//! is freed, so nothing of a run reaches the next.
//!
//! Thread: the engine's owner thread alone.

const std = @import("std");
const core = @import("collo_egress_core");
const data_io = @import("../io/bio_data.zig");
const pool_mod = @import("../transport/h2/pool.zig");
const transport = @import("../transport/root.zig");
const task_model = @import("../task.zig");
const root = @import("root.zig");
const result = @import("result.zig");
const h2 = @import("h2.zig");
const h1 = @import("h1.zig");
const dial = @import("dial.zig");

const Engine = root.Engine;
const RequestPlan = transport.RequestPlan;
const Task = task_model.Task;
const Wire = transport.Wire;
const monotonicNowNs = transport.config.monotonicNowNs;

/// One hop of a fetch the owner holds, not yet or no longer tied to a
/// connection: the task, the hop's plan and the HTTP/2 retry bookkeeping.
/// A hop holds the engine's task reference from `init` to `deinit`, so the
/// task, its config and its response queue stay alive while the owner works
/// on the fetch, even after the gateway retires it.
pub const Hop = struct {
    task_ref: *Task,
    plan: RequestPlan,
    /// Transparent HTTP/2 retries already spent on this fetch.
    h2_retries: u8 = 0,
    /// Pool-wait deadline, fixed at the first HTTP/2 pool park (0 = never
    /// parked). Re-parks under sustained saturation must not renew it, or a
    /// fetch without a request deadline would never expire.
    pool_deadline_mono_ns: u64 = 0,

    /// Takes `plan` and a reference to `task`, which `deinit` releases.
    pub fn init(task_ref: *Task, plan: RequestPlan) Hop {
        return .{ .task_ref = task_ref, .plan = plan };
    }

    pub fn deinit(self: *Hop) void {
        self.plan.deinit();
        self.task_ref.release();
        self.* = undefined;
    }

    /// The pool-wait deadline: `fresh_deadline_mono_ns` at the first park,
    /// the same instant at every later one.
    pub fn poolParkDeadline(self: *Hop, fresh_deadline_mono_ns: u64) u64 {
        if (self.pool_deadline_mono_ns == 0)
            self.pool_deadline_mono_ns = fresh_deadline_mono_ns;
        return self.pool_deadline_mono_ns;
    }

    pub fn task(self: *const Hop) *Task {
        return self.task_ref;
    }

    /// The config the fetch was submitted with.
    pub fn config(self: *const Hop) *const transport.Config {
        return &self.task_ref.engine.config;
    }

    pub fn readyToken(self: *const Hop) Task.ReadyToken {
        return self.task_ref.readyToken();
    }
};

pub const Watch = union(enum) {
    /// A pooled HTTP/2 entry, with the stream whose deadline the source
    /// carries, if any.
    entry: struct {
        entry: *pool_mod.Entry,
        stream: ?*h2.Stream,
        /// The stream's effective deadline when the list was built.
        deadline_mono_ns: u64 = std.math.maxInt(u64),
    },
    h1: *h1.Fetch,
    /// An idle pooled HTTP/1 wire, watched so a close or a stray byte that
    /// arrives while it idles makes it unclean.
    idle_http1: *Wire,
    /// The earliest deadline among the pool waiters, which `maintain`
    /// enforces.
    pool_wait,
    dial: *dial.Dial,
    attempt: struct {
        dial: *dial.Dial,
        slot: usize,
    },
};

pub fn run(engine: *Engine, driver: *data_io.Driver) void {
    var owner: Owner = undefined;
    owner.init(engine, driver);
    defer owner.deinit();
    owner.loop() catch |err| {
        // Producers are refused before the fault is visible, so whoever sees
        // the fault also sees the run ending.
        engine.refuseProducers();
        owner.settleAll(err);
        engine.noteOwnerFault(err);
        return;
    };
    owner.settleAll(error.EgressEngineStopped);
}

pub const Owner = struct {
    engine: *Engine,
    allocator: std.mem.Allocator,
    driver: *data_io.Driver,
    pool: pool_mod.Pool,
    http1_pool: transport.Http1Pool,
    h2_streams: std.ArrayListUnmanaged(*h2.Stream) = .empty,
    h1_fetches: std.ArrayListUnmanaged(*h1.Fetch) = .empty,
    dials: std.ArrayListUnmanaged(*dial.Dial) = .empty,
    origins: std.ArrayListUnmanaged(*dial.Origin) = .empty,
    pool_waiters: std.ArrayListUnmanaged(Hop) = .empty,
    retries: std.ArrayListUnmanaged(Hop) = .empty,
    /// What the next data wait watches, one per entry of `watches`.
    watch_sources: std.ArrayListUnmanaged(data_io.Source) = .empty,
    watches: std.ArrayListUnmanaged(Watch) = .empty,
    watch_dirty: bool = true,
    origin_use_counter: u64 = 0,

    fn init(self: *Owner, engine: *Engine, driver: *data_io.Driver) void {
        self.* = .{
            .engine = engine,
            .allocator = engine.allocator,
            .driver = driver,
            .pool = pool_mod.Pool.init(engine.allocator, .{}, &engine.hpack_scratch),
            .http1_pool = undefined,
        };
        self.http1_pool = transport.Http1Pool.init(engine.allocator, .{
            .context = self,
            .release_fn = releaseHttp1Wire,
            .refresh_fn = refreshIdleHttp1Wire,
        });
    }

    /// Runs after `settleAll`, which emptied every list of fetches, dials
    /// and entries and retired every credit source.
    fn deinit(self: *Owner) void {
        std.debug.assert(self.engine.credit_sources.live == 0);
        std.debug.assert(self.h2_streams.items.len == 0);
        std.debug.assert(self.h1_fetches.items.len == 0);
        std.debug.assert(self.dials.items.len == 0);
        std.debug.assert(self.pool_waiters.items.len == 0);
        std.debug.assert(self.retries.items.len == 0);
        self.http1_pool.deinit();
        self.pool.deinit();
        for (self.origins.items) |origin|
            self.allocator.destroy(origin);
        self.origins.deinit(self.allocator);
        self.h2_streams.deinit(self.allocator);
        self.h1_fetches.deinit(self.allocator);
        self.dials.deinit(self.allocator);
        self.pool_waiters.deinit(self.allocator);
        self.retries.deinit(self.allocator);
        self.watch_sources.deinit(self.allocator);
        self.watches.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns when the run ends. An error means the owner can no longer
    /// work: its data driver failed (a dead ring fails every wait), or the
    /// watch list could not be built at the shard's memory budget. The
    /// caller settles everything and latches the fault, so the shard
    /// supervisor restarts the engine instead of the owner spinning on a
    /// failure that repeats.
    fn loop(self: *Owner) !void {
        while (true) {
            const work = self.engine.takeWork() orelse return;
            self.applyWork(work);
            if (self.engine.dns_answered.swap(false, .acq_rel))
                dial.collectAnswers(self);
            h2.drainRetries(self);
            if (self.watch_dirty)
                self.maintain();
            // Dials created by anything above start here, outside every
            // fetch's own handling. A start that fails at once can queue
            // retries, whose restarts can create dials; each fetch's retry
            // budget bounds the exchange.
            while (dial.beginNew(self))
                h2.drainRetries(self);
            if (self.watch_dirty) {
                try self.buildWatchList();
                self.watch_dirty = false;
            }
            const wait_result = try self.driver.wait(self.watch_sources.items, self.engine.wake_fd);
            self.handleWaitResult(wait_result);
            h2.drainRetries(self);
        }
    }

    /// Starts the submitted fetches in submission order, then applies the
    /// cancels, which may name any of them, then the taken credit.
    fn applyWork(self: *Owner, work: root.Work) void {
        var submitted = work.submitted;
        while (submitted) |task| {
            submitted = task.engine.next_submitted;
            task.engine.next_submitted = null;
            self.startFetch(task);
            self.watch_dirty = true;
        }
        var canceled = work.canceled;
        while (canceled) |task| {
            canceled = task.engine.next_canceled;
            task.engine.next_canceled = null;
            self.cancelTask(task);
            task.release();
            self.watch_dirty = true;
        }
        var credited = work.credited;
        while (self.engine.credit_sources.claimNext(&credited)) |claim| {
            switch (claim.target) {
                .h2 => |stream| h2.applyCredit(self, stream, claim.credit),
                .h1 => |fetch| h1.applyResume(self, fetch, claim.credit),
            }
            self.watch_dirty = true;
        }
    }

    /// Prepares a submitted fetch's first hop and routes it. The submitted
    /// list held the engine's reference to `task`, which the hop takes, or
    /// which a failed preparation releases.
    fn startFetch(self: *Owner, task: *Task) void {
        const plan = transport.prepareRequest(
            self.allocator,
            task.url,
            task.method,
            task.headers,
            task.engine.config,
        ) catch |err| {
            result.publishFailure(task, err, self.engine.wake_ctx, self.engine.wake_fn.?);
            task.release();
            return;
        };
        self.routeHop(Hop.init(task, plan));
    }

    /// Prepares the next hop of a fetch whose task now names it (after a
    /// redirect) and routes it; takes `hop` and replaces its plan. On a
    /// preparation error the fetch fails.
    pub fn routeNextHop(self: *Owner, hop: Hop) void {
        var next = hop;
        const plan = transport.prepareRequest(
            self.allocator,
            next.task().url,
            next.task().method,
            next.task().headers,
            next.config().*,
        ) catch |err| {
            self.failHop(&next, err);
            return;
        };
        next.plan.deinit();
        next.plan = plan;
        self.routeHop(next);
    }

    /// Sends a hop down the path its origin takes: HTTP/2 for an https
    /// origin not known to speak only http/1.1, HTTP/1 otherwise.
    pub fn routeHop(self: *Owner, hop: Hop) void {
        if (self.usesHttp2(&hop))
            h2.start(self, hop)
        else
            h1.start(self, hop, null);
    }

    pub fn usesHttp2(self: *Owner, hop: *const Hop) bool {
        if (hop.plan.target.protocol != .tls)
            return false;
        if (!hop.config().enable_http2)
            return false;
        return !dial.knownHttp1Only(self, &hop.plan.origin_key);
    }

    /// Settles a hop that failed before any result was published, and
    /// releases it.
    pub fn failHop(self: *Owner, hop: *Hop, err: anyerror) void {
        result.publishFailure(hop.task(), err, self.engine.wake_ctx, self.engine.wake_fn.?);
        hop.deinit();
    }

    /// Settles a hop the gateway canceled before any result was published,
    /// and releases it.
    pub fn cancelHop(self: *Owner, hop: *Hop) void {
        result.completeCanceled(hop.task(), self.engine.wake_ctx, self.engine.wake_fn.?);
        hop.deinit();
    }

    /// Applies a cancel message: finds `task`'s fetch wherever the owner
    /// holds it and ends it. A fetch the owner no longer holds finished, and
    /// nothing remains to cancel.
    fn cancelTask(self: *Owner, task: *Task) void {
        if (h2.cancelTask(self, task)) return;
        if (h1.cancelTask(self, task)) return;
        if (dial.cancelTask(self, task)) return;
        if (takeHopFor(&self.pool_waiters, task)) |hop| {
            var canceled = hop;
            self.cancelHop(&canceled);
            return;
        }
        if (takeHopFor(&self.retries, task)) |hop| {
            var canceled = hop;
            self.cancelHop(&canceled);
            return;
        }
    }

    /// Owner-side upkeep on every iteration that changed what is watched,
    /// and on every watchdog tick.
    fn maintain(self: *Owner) void {
        const now_ns = monotonicNowNs() catch std.math.maxInt(u64);
        h2.evictExpiredEntries(self, now_ns);
        h2.expirePoolWaiters(self, now_ns);
        h2.drainPoolWaiters(self);
        h2.drainRetries(self);
    }

    fn buildWatchList(self: *Owner) !void {
        self.watch_sources.clearRetainingCapacity();
        self.watches.clearRetainingCapacity();
        const idle_http1 = self.http1_pool.idleEntries();
        var capacity = self.pool.entries.items.len + self.h1_fetches.items.len + idle_http1.len + 1;
        for (self.dials.items) |pending_dial|
            capacity += pending_dial.watchCount();
        // Sources point into `watches`, so both are sized before either is
        // filled and neither moves while the list is in use.
        try self.watches.ensureTotalCapacity(self.allocator, capacity);
        try self.watch_sources.ensureTotalCapacity(self.allocator, capacity);

        h2.appendWatches(self);
        h1.appendWatches(self);
        for (idle_http1) |entry| {
            self.appendWatch(.{ .idle_http1 = entry.wire }, .{
                .context = undefined,
                .io = .{ .wire = entry.wire },
                .deadline_mono_ns = entry.expires_mono_ns,
                .want_read = true,
            });
        }
        if (h2.earliestPoolWaiterDeadline(self)) |deadline| {
            self.appendWatch(.pool_wait, .{
                .context = undefined,
                .deadline_mono_ns = deadline,
            });
        }
        for (self.dials.items) |pending_dial|
            dial.appendWatches(self, pending_dial);
    }

    /// Appends one watch and its source, whose context is set to the watch.
    /// The capacity was reserved by `buildWatchList`.
    pub fn appendWatch(self: *Owner, watch: Watch, source: data_io.Source) void {
        self.watches.appendAssumeCapacity(watch);
        var watched = source;
        watched.context = @ptrCast(&self.watches.items[self.watches.items.len - 1]);
        self.watch_sources.appendAssumeCapacity(watched);
    }

    fn handleWaitResult(self: *Owner, wait_result: data_io.Result) void {
        switch (wait_result) {
            // A wake changes nothing by itself: the work and DNS answers it
            // announces are taken at the top of the next iteration.
            .wake => {
                self.engine.drainWake();
                return;
            },
            .tick => {},
            .expired => |context| switch (watchOf(context).*) {
                .entry => |watched| h2.entryExpired(self, watched.entry, watched.stream),
                .h1 => |fetch| h1.expired(self, fetch),
                .idle_http1 => self.evictIdleHttp1(),
                // The iteration's upkeep expires the pool waiters.
                .pool_wait => {},
                .dial => |pending_dial| dial.deadlineReached(self, pending_dial),
                .attempt => |watched| dial.deadlineReached(self, watched.dial),
            },
            .failed => |failure| switch (watchOf(failure.context).*) {
                .entry => |watched| h2.entryFailed(self, watched.entry, watched.stream, failure.err),
                .h1 => |fetch| h1.failed(self, fetch, failure.err),
                // The driver marked the wire unclean when it ingested the
                // failure (`io/bio_data.zig:applyReceiveResult`).
                .idle_http1 => self.evictIdleHttp1(),
                .pool_wait => {},
                .dial => |pending_dial| dial.failed(self, pending_dial, failure.err),
                // A connect poll reports every outcome as readiness; the
                // socket's own error tells the attempt's fate.
                .attempt => |watched| dial.attemptReady(self, watched.dial, watched.slot),
            },
            .ready => |ready| switch (watchOf(ready.context).*) {
                .entry => |watched| h2.entryReady(self, watched.entry, watched.stream, ready.readable, ready.writable),
                .h1 => |fetch| h1.drive(self, fetch),
                .idle_http1 => self.evictIdleHttp1(),
                .pool_wait => {},
                .dial => |pending_dial| dial.stepHandshake(self, pending_dial),
                .attempt => |watched| dial.attemptReady(self, watched.dial, watched.slot),
            },
        }
        self.watch_dirty = true;
    }

    fn evictIdleHttp1(self: *Owner) void {
        self.http1_pool.evictUnusable(monotonicNowNs() catch std.math.maxInt(u64));
    }

    /// Releases a wire registered in the data driver: freed here once the
    /// driver confirms its cancel, or freed by the driver after the kernel
    /// lets go of its buffers.
    pub fn releaseWire(self: *Owner, wire: *Wire) void {
        if (self.driver.cancelConnectionForClose(wire))
            wire.deinit();
    }

    fn releaseHttp1Wire(context: ?*anyopaque, wire: *Wire) void {
        const self: *Owner = @ptrCast(@alignCast(context.?));
        self.releaseWire(wire);
    }

    /// Brings an idle pooled wire up to date with its socket before the pool
    /// leases it (`Driver.refreshIdleWire`).
    fn refreshIdleHttp1Wire(context: ?*anyopaque, wire: *Wire) bool {
        const self: *Owner = @ptrCast(@alignCast(context.?));
        return self.driver.refreshIdleWire(wire);
    }

    pub fn wake(self: *Owner, event: root.WakeEvent) void {
        self.engine.wake(event);
    }

    /// Settles every fetch the owner holds with `err` and releases every
    /// wire and socket, leaving the lists empty for `deinit`. HTTP/1 fetches
    /// go first, since a fetch waiting on a dial leaves it on the way; then
    /// the dials with their remaining waiters, the HTTP/2 streams with their
    /// entries, the pool waiters and the retries.
    fn settleAll(self: *Owner, err: anyerror) void {
        h1.settleAll(self, err);
        dial.settleAll(self, err);
        h2.settleAll(self, err);
        while (self.pool_waiters.pop()) |hop| {
            var failed = hop;
            self.failHop(&failed, err);
        }
        while (self.retries.pop()) |hop| {
            var failed = hop;
            self.failHop(&failed, err);
        }
        while (self.pool.entries.items.len != 0)
            self.pool.removeEntry(self.pool.entries.items[0], self.driver);
        self.watches.clearRetainingCapacity();
        self.watch_sources.clearRetainingCapacity();
    }
};

fn watchOf(context: *anyopaque) *Watch {
    return @ptrCast(@alignCast(context));
}

fn takeHopFor(list: *std.ArrayListUnmanaged(Hop), task: *Task) ?Hop {
    for (list.items, 0..) |hop, index| {
        if (hop.task_ref == task)
            return list.orderedRemove(index);
    }
    return null;
}
