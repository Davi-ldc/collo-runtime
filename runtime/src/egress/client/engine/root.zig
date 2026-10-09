//! The egress engine of one gateway shard. The gateway submits fetch tasks
//! and a fixed set of threads runs them: one owner thread runs every
//! request, HTTP/2 on the BIO/io_uring data path and HTTP/1 as nonblocking
//! exchange and body state machines parked on the same watch list, while
//! connector threads only dial, doing the blocking DNS, TCP and TLS work.
//!
//! Pooled sessions, HPACK state and flow-control windows are touched only by
//! the owner thread, so they need no locks. Every command a connector picks
//! up produces exactly one outcome, and a command's task is settled only
//! after the connector's last dereference of it, on every path including
//! stop. A fatal error that escapes the owner loop settles all owner work
//! and latches `owner_fault`, which the gateway's shard supervisor answers
//! by restarting the engine.
//!
//! The first `start` creates every thread, io_uring ring and DNS resolver
//! the engine will ever use, because the gateway's seccomp filter denies
//! clone, clone3, io_uring_setup and io_uring_register once its shards are
//! up. Each later start begins a new run on those same threads: `stop` ends
//! the run, settles what it left behind and parks the threads, and only
//! `deinit` joins them and closes the rings.
//!
//! This file holds the `Engine` with its public API, stop and queue drain.
//! `h2_engine.zig` holds the owner and connector loops and `H1TurnBudget`;
//! `h2_types.zig` the pending, watch, message and connect-group types;
//! `h2/queue.zig` the message and connect queues, the owner's wake and the
//! io_uring drivers; `h2/lifecycle.zig` pool-entry removal and pending
//! lookups; `http1_pool.zig` the HTTP/1 origin hints and resume-source ids;
//! `origin.zig` origin parsing; `result.zig` task settlement.

const std = @import("std");
const builtin = @import("builtin");
const bindings = @import("collo_bindings");
const core = @import("collo_egress_core");
const data_io = @import("collo_egress_data_io");
const readiness = @import("collo_egress_readiness");
const transport = @import("collo_egress_transport");
const task_model = @import("../task.zig");
const result_mod = @import("result.zig");
const body_credit = core.body_credit;
const h2_types_mod = @import("h2_types.zig").Types(Command);
const origin_mod = @import("origin.zig");

const H2Pending = h2_types_mod.Pending;
const H2Watch = h2_types_mod.Watch;
const H2Message = h2_types_mod.Message;
const H2Connected = h2_types_mod.Connected;
const H2ConnectOutcome = h2_types_mod.ConnectOutcome;
const H2ConnectGroup = h2_types_mod.ConnectGroup;
const H2ConnectKey = h2_types_mod.ConnectKey;
/// Exported so the deadline-policy test can check the h1 pending's two-clock
/// derivation without a full engine.
pub const H1Pending = h2_types_mod.H1Pending;
const H1Connected = h2_types_mod.H1Connected;
const Http1OriginHint = origin_mod.Http1OriginHint;

pub const WakeEvent = union(enum) {
    generic,
    task_ready: task_model.Task.ReadyToken,
};

/// Error codes ride atomics as their integer representation (0 = none).
const FaultInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

/// Per-turn h1 drive budget of the owner loop, exported for the
/// fairness-policy test. Its contract is documented on the type.
pub const H1TurnBudget = @import("h2_engine.zig").H1TurnBudget;

pub const WakeFn = *const fn (?*anyopaque, WakeEvent) void;

pub const Command = struct {
    task: *task_model.Task,
    config: transport.Config,
    ready_generation: u64 = 0,
    /// Connector-queue routing: set by the owner when dispatching an HTTP/1
    /// dial for an owner-loop pending, so the connector thread runs the plain
    /// or HTTP/1 TLS connect instead of the speculative HTTP/2 BIO connect.
    h1_connect: bool = false,
    /// Transparent HTTP/2 retries already spent on this command
    /// (REFUSED_STREAM, a GOAWAY that excludes the stream, a dead reused
    /// session).
    h2_retries: u8 = 0,
    /// Pool-wait deadline, fixed at the first HTTP/2 pool park (0 = never
    /// parked). Re-parks under sustained saturation must not renew it, or a
    /// command without a request deadline would never expire, breaking the
    /// H2PoolWaiter rule that a waiter fails at its own deadline.
    h2_pool_deadline_mono_ns: u64 = 0,

    /// Returns the pool-waiter deadline, fixing it on first park and
    /// preserving it across re-parks; `fresh_deadline_mono_ns` is only
    /// adopted when the command was never parked before.
    pub fn h2PoolParkDeadline(self: *Command, fresh_deadline_mono_ns: u64) u64 {
        if (self.h2_pool_deadline_mono_ns == 0)
            self.h2_pool_deadline_mono_ns = fresh_deadline_mono_ns;
        return self.h2_pool_deadline_mono_ns;
    }

    pub fn readyToken(self: Command) task_model.Task.ReadyToken {
        return .{
            .task = self.task,
            .generation = self.ready_generation,
        };
    }
};

/// Command parked because every HTTP/2 pool slot held an active connection;
/// resubmitted when capacity frees, failed at its own deadline.
pub const H2PoolWaiter = struct {
    command: Command,
    deadline_mono_ns: u64,
};

/// Thread sizing for the engine. Connectors are the only tunable class; the
/// owner thread is always spawned in addition. Zero connectors keeps the
/// engine constructible but permanently unavailable (`submit` and `start`
/// return `error.EgressEngineUnavailable`), which tests use to exercise the
/// JS-facing boundary without sockets or threads.
pub const ThreadConfig = struct {
    /// Connector (dialer) threads. Every dial, HTTP/1 and HTTP/2 alike, goes
    /// through this pool, so with a single connector one slow TLS handshake
    /// would hold up every other origin's connect. Two connectors keep dials
    /// concurrent at three engine threads per shard, owner included.
    connector_count: usize = 2,
};

/// Freelist cap for the shared HTTP/1 pool's body read buffers, each
/// `continuation_read_buffer_bytes` long. Every in-flight h1 body
/// continuation holds one buffer while it lives; the cap bounds only how
/// many released buffers stay cached for reuse, so a burst of concurrent
/// bodies wider than the cap costs one allocation and one free per extra
/// body.
const owner_read_buffer_retain: usize = 8;

/// Saturation counters for the owner thread.
///
/// Time counters and watch-list lengths are written only by the owner thread;
/// queue-depth maxima are written by producers under `Engine.mutex`. Readers
/// take `snapshotH2Stats()` from any thread, so every field is an atomic with
/// monotonic ordering: values are statistics, not synchronization.
pub const H2Stats = struct {
    busy_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    wait_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Busy-phase split (busy_ns ≈ process + maintain + handle): message
    /// batch processing, per-iteration maintenance (cancel/evict scans plus
    /// the watch-list rebuild), and data-wait result handling.
    process_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    maintain_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    handle_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    batches_nonempty: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    batch_messages_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_depth_enqueue_max: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_depth_drain_max: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// High-water of the connect (dial) queue: commands waiting for a
    /// connector thread, the saturation signal for
    /// `ThreadConfig.connector_count`. Writers hold `Engine.mutex` (see
    /// storeMax).
    connect_queue_depth_max: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    watch_list_len_last: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    watch_list_len_max: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Most drives any single h1 drive pass performed, bounded by the
    /// runnable count observed at the start of the pass and by the turn
    /// budget.
    h1_pass_drives_max: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Most drives in one h1 pass that yielded with their per-drive quantum
    /// exhausted mid-body. Unlike h1_pass_drives_max, which also counts
    /// drives that only dispatched a connect or parked on io, a yield proves
    /// the drive was streaming, so the fairness tests check the
    /// one-quantum-per-pass bound against this counter.
    h1_pass_yields_max: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Passes cut short by the per-turn budget (`H1TurnBudget`) with a
    /// runnable still waiting: a streaming pass drained the whole turn byte
    /// budget, or drove the most pendings a turn allows, and left work
    /// behind for the next turn. The fairness tests wait on it to know a
    /// burst has reached that regime.
    h1_turn_budget_exhausted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub const Snapshot = struct {
        busy_ns: u64,
        wait_ns: u64,
        process_ns: u64,
        maintain_ns: u64,
        handle_ns: u64,
        iterations: u64,
        batches_nonempty: u64,
        batch_messages_total: u64,
        queue_depth_enqueue_max: u64,
        queue_depth_drain_max: u64,
        connect_queue_depth_max: u64,
        watch_list_len_last: u64,
        watch_list_len_max: u64,
        h1_pass_drives_max: u64,
        h1_pass_yields_max: u64,
        h1_turn_budget_exhausted: u64,
    };

    pub fn addBusy(self: *H2Stats, delta_ns: u64) void {
        _ = self.busy_ns.fetchAdd(delta_ns, .monotonic);
    }

    pub fn addWait(self: *H2Stats, delta_ns: u64) void {
        _ = self.wait_ns.fetchAdd(delta_ns, .monotonic);
    }

    pub fn addProcess(self: *H2Stats, delta_ns: u64) void {
        _ = self.process_ns.fetchAdd(delta_ns, .monotonic);
    }

    pub fn addMaintain(self: *H2Stats, delta_ns: u64) void {
        _ = self.maintain_ns.fetchAdd(delta_ns, .monotonic);
    }

    pub fn addHandle(self: *H2Stats, delta_ns: u64) void {
        _ = self.handle_ns.fetchAdd(delta_ns, .monotonic);
    }

    pub fn countIteration(self: *H2Stats, batch_len: usize) void {
        _ = self.iterations.fetchAdd(1, .monotonic);
        if (batch_len == 0)
            return;
        _ = self.batches_nonempty.fetchAdd(1, .monotonic);
        _ = self.batch_messages_total.fetchAdd(@intCast(batch_len), .monotonic);
    }

    pub fn recordWatchLen(self: *H2Stats, len: usize) void {
        const value: u64 = @intCast(len);
        self.watch_list_len_last.store(value, .monotonic);
        storeMax(&self.watch_list_len_max, value);
    }

    pub fn recordH1PassDrives(self: *H2Stats, drives: usize) void {
        storeMax(&self.h1_pass_drives_max, @intCast(drives));
    }

    pub fn recordH1PassYields(self: *H2Stats, yields: usize) void {
        storeMax(&self.h1_pass_yields_max, @intCast(yields));
    }

    pub fn countH1TurnBudgetExhausted(self: *H2Stats) void {
        _ = self.h1_turn_budget_exhausted.fetchAdd(1, .monotonic);
    }

    pub fn recordQueueDepthEnqueue(self: *H2Stats, depth: usize) void {
        storeMax(&self.queue_depth_enqueue_max, @intCast(depth));
    }

    pub fn recordQueueDepthDrain(self: *H2Stats, depth: usize) void {
        storeMax(&self.queue_depth_drain_max, @intCast(depth));
    }

    pub fn recordConnectQueueDepth(self: *H2Stats, depth: usize) void {
        storeMax(&self.connect_queue_depth_max, @intCast(depth));
    }

    // Max writers either run on the owner thread or hold `Engine.mutex`, so a
    // load/store pair cannot lose a concurrent larger candidate.
    fn storeMax(value: *std.atomic.Value(u64), candidate: u64) void {
        if (candidate > value.load(.monotonic))
            value.store(candidate, .monotonic);
    }
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    h2_condition: std.Thread.Condition = .{},
    h2_connect_condition: std.Thread.Condition = .{},
    h2_queue: []H2Message,
    h2_batch: []H2Message,
    h2_connect_queue: []Command,
    h2_connectors: []std.Thread,
    h2_readiness_drivers: []?readiness.Driver,
    h2_data_drivers: []?data_io.Driver,
    dns_cache: transport.DnsCache,
    http1_origins: std.array_list.Aligned(Http1OriginHint, null) = .empty,
    /// Owner-thread scratch: commands pulled out of a failing entry that are
    /// eligible for a transparent retry; drained by h2Main within the same
    /// loop iteration.
    h2_retry_commands: std.array_list.Aligned(Command, null) = .empty,
    /// Owner-thread state: commands waiting for a pool slot instead of
    /// failing with Http2PoolExhausted; bounded by each command's deadline.
    h2_pool_waiters: std.array_list.Aligned(H2PoolWaiter, null) = .empty,
    /// Owner-thread state: HTTP/1 fetches executing on the owner loop. The
    /// exchange and body machines live on the heap. Watch contexts hold
    /// pointers into `items`, so every mutation must mark the watch list
    /// dirty before the next wait, as with the h2 pending list.
    h1_pending: std.array_list.Aligned(H1Pending, null) = .empty,
    /// Set by wakeCancellation so the owner runs its cancel sweep on the
    /// next iteration instead of waiting for a dirty event or the watchdog
    /// tick.
    cancel_sweep_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Fault latch, 0 while healthy. Set, together with a generic wake, when
    /// a fatal error escapes the owner loop, such as a watch-list allocation
    /// that keeps failing at the shard memory budget
    /// (`supervisor_limits.shard_memory`). The gateway's next collection
    /// pass takes it and hands the error to its shard supervisor, which
    /// restarts this engine in place instead of leaving a wedged owner.
    owner_fault: std.atomic.Value(FaultInt) = std.atomic.Value(FaultInt).init(0),
    /// Test-only fault seams (0 = disarmed, else @intFromError): the owner's
    /// next watch-list build, driver reconcile or data wait observes the
    /// stored error, so tests can exercise the fatal-error handlers without
    /// a broken allocator or a dead io_uring.
    test_h2_build_fault: if (builtin.is_test) std.atomic.Value(FaultInt) else void =
        if (builtin.is_test) std.atomic.Value(FaultInt).init(0) else {},
    test_h2_wait_fault: if (builtin.is_test) std.atomic.Value(FaultInt) else void =
        if (builtin.is_test) std.atomic.Value(FaultInt).init(0) else {},
    test_h2_sync_fault: if (builtin.is_test) std.atomic.Value(FaultInt) else void =
        if (builtin.is_test) std.atomic.Value(FaultInt).init(0) else {},
    /// HTTP/1 keep-alive pool. Only the owner thread touches it (lease,
    /// return, ALPN-h1 adoption); its internal mutex stays as cheap
    /// insurance. Created at start and torn down in stop after the owner has
    /// parked.
    http1_shared_pool: ?transport.Http1Pool = null,
    h2_wake_fd: std.posix.fd_t,
    h2_head: usize = 0,
    h2_len: usize = 0,
    h2_connect_head: usize = 0,
    h2_connect_len: usize = 0,
    /// Threads that exist, from the first start until deinit joins them;
    /// stop leaves them parked.
    started_h2_connectors: usize = 0,
    h2_worker: ?std.Thread = null,
    next_h2_credit_source_id: u64 = 1,
    next_http1_resume_source_id: u64 = 1,
    /// A run is active: set by start, cleared by stop once every thread
    /// parked.
    started: bool = false,
    /// The active run is ending; the thread loops return when they see it.
    stopping: bool = false,
    /// Parked threads wait here for the next run or for deinit.
    run_condition: std.Thread.Condition = .{},
    /// Stop waits here for the last running thread to park.
    parked_condition: std.Thread.Condition = .{},
    /// Bumped by every start. A parked thread runs its loop once per new
    /// value, so no thread runs twice in one run or misses one.
    run_epoch: u64 = 0,
    /// Threads that have not finished the current run. Start sets it to
    /// every thread, so stop cannot return before a thread that has not yet
    /// woken for the run.
    running_threads: usize = 0,
    /// Set by deinit after the last stop: parked threads return.
    exiting: bool = false,
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?WakeFn = null,
    pre_register_recv_buffers: bool = false,
    h2_stats: H2Stats = .{},

    pub const enqueueH2MessageLocked = h2_engine.enqueueH2MessageLocked;
    pub const enqueueH2MessageAssumeCapacityLocked = h2_engine.enqueueH2MessageAssumeCapacityLocked;
    pub const enqueueH2ConnectLocked = h2_engine.enqueueH2ConnectLocked;
    pub const enqueueH2Connect = h2_engine.enqueueH2Connect;
    pub const enqueueH2Connected = h2_engine.enqueueH2Connected;
    pub const waitForH2Command = h2_engine.waitForH2Command;
    pub const drainH2BatchNonBlocking = h2_engine.drainH2BatchNonBlocking;
    pub const popH2Connect = h2_engine.popH2Connect;
    pub const initH2Drivers = h2_engine.initH2Drivers;
    pub const deinitH2Drivers = h2_engine.deinitH2Drivers;
    pub const h2DataDriver = h2_engine.h2DataDriver;
    pub const h2ReadinessDriver = h2_engine.h2ReadinessDriver;
    pub const nextH2CreditSourceId = h2_engine.nextH2CreditSourceId;
    pub const h2ConnectMain = h2_engine.h2ConnectMain;
    pub const h2Main = h2_engine.h2Main;
    pub const signalH2Wake = h2_engine.signalH2Wake;
    const settleStoppedH1ConnectPendingByTask = h2_engine.settleStoppedH1ConnectPendingByTask;
    const settleStoppedH1ConnectPendings = h2_engine.settleStoppedH1ConnectPendings;

    pub fn init(allocator: std.mem.Allocator, queue_capacity: usize, thread_config: ThreadConfig) !Engine {
        const h2_queue = try allocator.alloc(H2Message, queue_capacity);
        errdefer allocator.free(h2_queue);
        const h2_batch = try allocator.alloc(H2Message, queue_capacity);
        errdefer allocator.free(h2_batch);
        const h2_connect_queue = try allocator.alloc(Command, queue_capacity);
        errdefer allocator.free(h2_connect_queue);
        const h2_connectors = try allocator.alloc(std.Thread, thread_config.connector_count);
        errdefer allocator.free(h2_connectors);
        // Readiness drivers serve only the connectors (TCP connect racing and
        // handshake waits); connector i owns slot i (see h2ConnectMain).
        const h2_readiness_drivers = try allocator.alloc(?readiness.Driver, thread_config.connector_count);
        errdefer allocator.free(h2_readiness_drivers);
        // Data-driver slot 0 belongs to the owner thread (`h2_worker`);
        // connector i uses slot i + 1 (see h2Main and h2ConnectMain).
        const h2_data_drivers = try allocator.alloc(?data_io.Driver, thread_config.connector_count + 1);
        errdefer allocator.free(h2_data_drivers);
        @memset(h2_readiness_drivers, null);
        @memset(h2_data_drivers, null);
        const h2_wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(h2_wake_fd);
        return .{
            .allocator = allocator,
            .h2_queue = h2_queue,
            .h2_batch = h2_batch,
            .h2_connect_queue = h2_connect_queue,
            .h2_connectors = h2_connectors,
            .h2_readiness_drivers = h2_readiness_drivers,
            .h2_data_drivers = h2_data_drivers,
            .dns_cache = transport.DnsCache.init(allocator, .{}),
            .h2_wake_fd = h2_wake_fd,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.stop();
        self.joinThreads();
        self.deinitH2Drivers();
        self.dns_cache.deinit();
        for (self.http1_origins.items) |*hint|
            hint.deinit(self.allocator);
        self.http1_origins.deinit(self.allocator);
        self.h2_retry_commands.deinit(self.allocator);
        self.h2_pool_waiters.deinit(self.allocator);
        self.h1_pending.deinit(self.allocator);
        self.allocator.free(self.h2_data_drivers);
        self.allocator.free(self.h2_readiness_drivers);
        self.allocator.free(self.h2_connectors);
        self.allocator.free(self.h2_connect_queue);
        self.allocator.free(self.h2_batch);
        self.allocator.free(self.h2_queue);
        std.posix.close(self.h2_wake_fd);
        self.* = undefined;
    }

    /// Ends the current run: every thread leaves its loop and parks, then
    /// whatever the run left queued is settled. The threads, rings and DNS
    /// resolvers stay for the next start. A no-op when no run is active.
    pub fn stop(self: *Engine) void {
        self.mutex.lock();
        if (!self.started) {
            self.mutex.unlock();
            return;
        }
        self.stopping = true;
        self.h2_condition.broadcast();
        self.h2_connect_condition.broadcast();
        self.mutex.unlock();
        self.signalH2Wake();

        self.mutex.lock();
        while (self.running_threads != 0)
            self.parked_condition.wait(&self.mutex);
        self.mutex.unlock();
        self.drainQueuesOnStop();
        if (self.http1_shared_pool) |*pool| {
            pool.deinit();
            self.http1_shared_pool = null;
        }

        self.mutex.lock();
        self.started = false;
        self.stopping = false;
        self.wake_ctx = null;
        self.wake_fn = null;
        self.mutex.unlock();
    }

    /// Ends the parked threads. Runs after the last stop, so no run is
    /// active and every thread is parked or about to park.
    fn joinThreads(self: *Engine) void {
        self.mutex.lock();
        std.debug.assert(!self.started and self.running_threads == 0);
        self.exiting = true;
        self.run_condition.broadcast();
        self.mutex.unlock();
        for (self.h2_connectors[0..self.started_h2_connectors]) |worker|
            worker.join();
        if (self.h2_worker) |worker|
            worker.join();
        self.h2_worker = null;
        self.started_h2_connectors = 0;
        self.exiting = false;
    }

    /// Runs after every engine thread parked: fails the commands nobody
    /// picked up and tears down connector outcomes nobody will adopt, each of
    /// which may own a live connection.
    fn drainQueuesOnStop(self: *Engine) void {
        const wake_fn = self.wake_fn orelse return;
        while (self.h2_len != 0) {
            var message = self.h2_queue[self.h2_head];
            self.h2_head = (self.h2_head + 1) % self.h2_queue.len;
            self.h2_len -= 1;
            switch (message) {
                .request => |command| failStoppedCommand(command, self.wake_ctx, wake_fn),
                // An unconsumed outcome is the dispatched command's
                // completion delivery. The owner's exit settlement skips a
                // command a connector may still be executing (see
                // failAllH2Connecting), so with the connector done and the
                // owner gone this is the only path left to settle it, after
                // tearing down its wire.
                .connected => |*connected| {
                    switch (connected.outcome) {
                        .h2, .h1 => |*wire| wire.deinit(),
                        .failure => {},
                    }
                    failStoppedCommand(connected.command, self.wake_ctx, wake_fn);
                },
                // An unconsumed h1 outcome is likewise the dial's completion
                // delivery. The owner's exit sweep skips `.awaiting_connect`
                // pendings because the connector dereferences command.task
                // for the whole dial (see failAllH1Pending), so the pending
                // survived to here and settles now, exactly once, after its
                // wire is torn down.
                .h1_connected => |*connected| {
                    switch (connected.outcome) {
                        .wire => |*wire| wire.deinit(),
                        .failure => {},
                    }
                    self.settleStoppedH1ConnectPendingByTask(connected.command.task, error.EgressEngineStopped);
                },
                .h1_resume, .body_credit, .body_cancel => {},
            }
        }
        while (self.h2_connect_len != 0) {
            const command = self.h2_connect_queue[self.h2_connect_head];
            self.h2_connect_head = (self.h2_connect_head + 1) % self.h2_connect_queue.len;
            self.h2_connect_len -= 1;
            // Never-popped commands settle here. The owner's exit settlement
            // skips every h2 group's dispatched command and every
            // `.awaiting_connect` h1 pending so that their completion
            // belongs to the connector side, which for a command no
            // connector picked up is this drain. An h1 dial settles through
            // its surviving owner-loop pending, since no outcome will ever
            // arrive for it; an h2 group command settles directly.
            if (command.h1_connect)
                self.settleStoppedH1ConnectPendingByTask(command.task, error.EgressEngineStopped)
            else
                failStoppedCommand(command, self.wake_ctx, wake_fn);
        }
        // Refused-handoff leftovers: a connector whose completion enqueue
        // stop refused tore down only the wire, because it must never touch
        // owner state, and left neither a queued outcome nor a queued
        // command. Its `.awaiting_connect` pending is whatever the two drains
        // above did not consume; with every thread parked, settle those
        // last, exactly once.
        self.settleStoppedH1ConnectPendings(error.EgressEngineStopped);
    }

    fn failStoppedCommand(command: Command, wake_ctx: ?*anyopaque, wake_fn: WakeFn) void {
        if (command.task.isCanceled())
            result_mod.completeCanceled(command.task, wake_ctx, wake_fn)
        else
            result_mod.publishFailure(command.task, error.EgressEngineStopped, wake_ctx, wake_fn);
    }

    pub fn submit(self: *Engine, command: Command, wake_ctx: ?*anyopaque, wake_fn: WakeFn) !void {
        try self.ensureStarted(wake_ctx, wake_fn);
        var queued_command = command;
        queued_command.ready_generation = command.task.ready_generation.load(.monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping)
            return error.EgressEngineStopped;

        // Every command starts on the owner loop, which routes it to the h2
        // or h1 path: the protocol choice reads the origin-hint table, which
        // the owner maintains.
        try self.enqueueH2MessageLocked(.{ .request = queued_command });
        self.h2_condition.signal();
        self.signalH2Wake();
    }

    /// Begins a run. The first call creates the threads, rings and DNS
    /// resolvers; every later call reuses them and creates nothing, so it is
    /// safe under the gateway's seccomp filter. Fails with
    /// `error.EgressDataRingDead` when one of the engine's rings died, since
    /// only a new process can replace it.
    pub fn start(self: *Engine, wake_ctx: ?*anyopaque, wake_fn: WakeFn) !void {
        try self.ensureStarted(wake_ctx, wake_fn);
    }

    /// Must run before the first start, which prepares the rings.
    pub fn setPreRegisterRecvBuffers(self: *Engine, value: bool) void {
        std.debug.assert(self.h2_worker == null);
        self.pre_register_recv_buffers = value;
    }

    pub fn snapshotH2Stats(self: *const Engine) H2Stats.Snapshot {
        return .{
            .busy_ns = self.h2_stats.busy_ns.load(.monotonic),
            .wait_ns = self.h2_stats.wait_ns.load(.monotonic),
            .process_ns = self.h2_stats.process_ns.load(.monotonic),
            .maintain_ns = self.h2_stats.maintain_ns.load(.monotonic),
            .handle_ns = self.h2_stats.handle_ns.load(.monotonic),
            .iterations = self.h2_stats.iterations.load(.monotonic),
            .batches_nonempty = self.h2_stats.batches_nonempty.load(.monotonic),
            .batch_messages_total = self.h2_stats.batch_messages_total.load(.monotonic),
            .queue_depth_enqueue_max = self.h2_stats.queue_depth_enqueue_max.load(.monotonic),
            .queue_depth_drain_max = self.h2_stats.queue_depth_drain_max.load(.monotonic),
            .connect_queue_depth_max = self.h2_stats.connect_queue_depth_max.load(.monotonic),
            .watch_list_len_last = self.h2_stats.watch_list_len_last.load(.monotonic),
            .watch_list_len_max = self.h2_stats.watch_list_len_max.load(.monotonic),
            .h1_pass_drives_max = self.h2_stats.h1_pass_drives_max.load(.monotonic),
            .h1_pass_yields_max = self.h2_stats.h1_pass_yields_max.load(.monotonic),
            .h1_turn_budget_exhausted = self.h2_stats.h1_turn_budget_exhausted.load(.monotonic),
        };
    }

    /// Records a fatal owner-loop escape and wakes the completion consumer
    /// (the gateway) so its next collection pass surfaces the fault to the
    /// shard supervisor. Runs on the owner thread before it reports its run
    /// finished, so stop() has not cleared the wake callback yet.
    pub fn noteOwnerFault(self: *Engine, err: anyerror) void {
        self.owner_fault.store(@intCast(@intFromError(err)), .release);
        std.log.warn("egress engine owner loop died: {s}", .{@errorName(err)});
        if (self.wake_fn) |wake_fn|
            wake_fn(self.wake_ctx, .generic);
    }

    /// One-shot take of a recorded owner-loop fault. The caller owns
    /// escalation; every start clears the latch, so a restarted engine
    /// starts healthy again.
    pub fn takeOwnerFault(self: *Engine) ?anyerror {
        const raw = self.owner_fault.swap(0, .acq_rel);
        if (raw == 0)
            return null;
        return @errorFromInt(raw);
    }

    /// Test-only: the owner's next watch-list build fails with `err`,
    /// exercising the fatal-error escape. Only analyzable in test builds.
    pub fn armTestH2BuildFault(self: *Engine, err: anyerror) void {
        self.test_h2_build_fault.store(@intCast(@intFromError(err)), .release);
    }

    /// Test-only: the owner's next data wait fails with `err`, exercising
    /// the handler that fails both pending lists and parks.
    pub fn armTestH2WaitFault(self: *Engine, err: anyerror) void {
        self.test_h2_wait_fault.store(@intCast(@intFromError(err)), .release);
    }

    /// Test-only: the owner's next driver reconcile (syncSources) fails with
    /// `err`, exercising the escape for sticky ring failures, which settles
    /// everything and latches the owner fault.
    pub fn armTestH2SyncFault(self: *Engine, err: anyerror) void {
        self.test_h2_sync_fault.store(@intCast(@intFromError(err)), .release);
    }

    pub fn wakeCancellation(self: *Engine) void {
        self.mutex.lock();
        self.h2_condition.signal();
        self.h2_connect_condition.broadcast();
        self.mutex.unlock();
        // Ask the owner for an immediate cancel sweep: an eventfd wake alone
        // is not watch-dirty, and a flag-only cancel would otherwise wait up
        // to one data-driver watchdog tick (`watchdog_tick_ns` in
        // io/bio_data.zig).
        self.cancel_sweep_requested.store(true, .release);
        self.signalH2Wake();
    }

    pub fn releaseFetchBodyCredit(self: *Engine, credit: body_credit.Handle) void {
        self.tryReleaseFetchBodyCredit(credit) catch |err| {
            std.log.warn("egress fetch body credit release failed: {s}", .{@errorName(err)});
        };
    }

    pub fn tryReleaseFetchBodyCredit(self: *Engine, credit: body_credit.Handle) !void {
        switch (credit) {
            .none => return,
            .h1_resume => |resume_credit| {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.stopping or !self.started)
                    return;
                // A resume credit is the only wake for a credit-parked h1
                // body; dropping one on a full queue would stall that fetch
                // until its deadline. Same blocking rule as `.h2_data`.
                while (self.h2_len == self.h2_queue.len and !self.stopping)
                    self.h2_condition.wait(&self.mutex);
                if (self.stopping)
                    return;
                self.enqueueH2MessageAssumeCapacityLocked(.{ .h1_resume = resume_credit.source_id });
                self.h2_condition.signal();
                self.signalH2Wake();
            },
            .h2_data => |h2_credit| {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.stopping or !self.started)
                    return;
                // A credit ack is the only trigger for a stream's deferred
                // `.end`; dropping one on a full queue would stall that fetch
                // until its deadline. Block the consumer until the owner
                // drains instead. The owner drains the whole queue every
                // iteration and never waits on a consumer, so this cannot
                // deadlock.
                while (self.h2_len == self.h2_queue.len and !self.stopping)
                    self.h2_condition.wait(&self.mutex);
                if (self.stopping)
                    return;
                self.enqueueH2MessageAssumeCapacityLocked(.{ .body_credit = h2_credit });
                self.h2_condition.signal();
                self.signalH2Wake();
            },
        }
    }

    pub fn cancelFetchBody(self: *Engine, identity: bindings.FetchBodyIdentity) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping or !self.started)
            return;
        while (self.h2_len == self.h2_queue.len and !self.stopping)
            self.h2_condition.wait(&self.mutex);
        if (self.stopping)
            return;
        self.enqueueH2MessageAssumeCapacityLocked(.{ .body_cancel = identity });
        self.h2_condition.signal();
        self.signalH2Wake();
    }

    fn ensureStarted(self: *Engine, wake_ctx: ?*anyopaque, wake_fn: WakeFn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.started)
            return;
        if (self.h2_connectors.len == 0)
            return error.EgressEngineUnavailable;
        if (self.h2_worker == null) {
            try self.spawnThreadsLocked();
        } else if (self.hasDeadDataRing()) {
            return error.EgressDataRingDead;
        }

        std.debug.assert(self.http1_shared_pool == null);
        self.http1_shared_pool = transport.Http1Pool.init(self.allocator);
        self.http1_shared_pool.?.read_buffer_retain_max = owner_read_buffer_retain;
        self.wake_ctx = wake_ctx;
        self.wake_fn = wake_fn;
        self.owner_fault.store(0, .release);
        self.stopping = false;
        self.started = true;
        self.run_epoch += 1;
        self.running_threads = 1 + self.started_h2_connectors;
        self.run_condition.broadcast();
    }

    /// First start only, called and returning with the mutex held. The new
    /// threads park until the caller begins the run. On failure, every
    /// thread spawned so far is joined and the rings are closed, so the
    /// next start tries again from nothing.
    fn spawnThreadsLocked(self: *Engine) !void {
        errdefer {
            self.exiting = true;
            self.run_condition.broadcast();
            self.mutex.unlock();
            for (self.h2_connectors[0..self.started_h2_connectors]) |worker|
                worker.join();
            if (self.h2_worker) |worker|
                worker.join();
            self.deinitH2Drivers();
            self.mutex.lock();
            self.h2_worker = null;
            self.started_h2_connectors = 0;
            self.exiting = false;
        }
        try self.initH2Drivers();
        try self.dns_cache.prestartWorkers();
        self.h2_worker = try std.Thread.spawn(.{}, ownerMain, .{self});
        while (self.started_h2_connectors < self.h2_connectors.len) : (self.started_h2_connectors += 1)
            self.h2_connectors[self.started_h2_connectors] = try std.Thread.spawn(.{}, connectorMain, .{ self, self.started_h2_connectors });
    }

    /// A ring that died delivers no completions, and none can be created
    /// under the gateway's seccomp filter, so a run never starts on one.
    /// Called with the mutex held and every thread parked.
    fn hasDeadDataRing(self: *Engine) bool {
        for (self.h2_data_drivers) |*slot| {
            if (slot.*) |*driver| {
                if (driver.ringDead())
                    return true;
            }
        }
        return false;
    }

    /// Owner-thread entry, one loop per run. A fatal error escaping the
    /// owner loop, such as a watch-list allocation that keeps failing at the
    /// shard memory budget, latches the owner fault instead of ending the
    /// run silently, so the shard supervisor restarts the engine rather than
    /// routing fetches at a wedged owner forever.
    fn ownerMain(self: *Engine) void {
        var seen_epoch: u64 = 0;
        while (self.awaitRun(&seen_epoch)) {
            self.h2Main() catch |err| self.noteOwnerFault(err);
            self.finishRun();
        }
    }

    /// Connector-thread entry, one loop per run.
    fn connectorMain(self: *Engine, connector_index: usize) void {
        var seen_epoch: u64 = 0;
        while (self.awaitRun(&seen_epoch)) {
            self.h2ConnectMain(connector_index);
            self.finishRun();
        }
    }

    /// Parks the calling engine thread until a run newer than `seen_epoch`
    /// starts (true) or deinit ends the threads (false).
    fn awaitRun(self: *Engine, seen_epoch: *u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.exiting and self.run_epoch == seen_epoch.*)
            self.run_condition.wait(&self.mutex);
        if (self.exiting)
            return false;
        seen_epoch.* = self.run_epoch;
        return true;
    }

    fn finishRun(self: *Engine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.running_threads != 0);
        self.running_threads -= 1;
        if (self.running_threads == 0)
            self.parked_condition.broadcast();
    }
};

const h2_engine = @import("h2_engine.zig").Methods(
    Engine,
    Command,
    H2Pending,
    H2Watch,
    H2Message,
    H2Connected,
    H2ConnectOutcome,
    H2ConnectGroup,
    H2ConnectKey,
    H1Pending,
    H1Connected,
    WakeEvent,
    WakeFn,
);
