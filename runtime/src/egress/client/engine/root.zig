//! The egress engine of one gateway shard. The gateway's loop thread submits
//! fetch tasks, cancels them and returns body credits; one owner thread runs
//! every fetch of the shard on one io_uring data driver: its dials (DNS
//! through the cache, TCP connects, TLS handshakes), its HTTP/2 streams and
//! its HTTP/1 exchanges. The DNS cache's two resolver threads are the only
//! other threads, and they block in `getaddrinfo` only.
//!
//! The owner's state for a run lives on its own stack (`owner.zig`) and no
//! other thread touches it, so pools, origins, dials, streams, exchanges and
//! their wires carry no locks. Producers reach the owner only through what
//! `mutex` guards here, and the wake eventfd its data wait polls, and none of
//! them ever waits for the owner, so the gateway's loop never stalls behind
//! an owner iteration (which may include a TLS handshake step):
//! - a submit links the task into the submitted list, which needs no room,
//!   and takes the engine's task reference, which the owner hands to the
//!   fetch's hop or releases, and which a stop releases for a task the owner
//!   never took;
//! - a cancel links the task into the canceled list, at most once per task;
//! - a credit merges into its source's released credit, and the source
//!   enters the dirty list, which runs through the sources themselves, at
//!   most once (`credit_sources.zig`), so no number of credits needs room.
//!
//! The first `start` creates the owner thread, its data ring and the resolver
//! threads, because the gateway's seccomp filter denies clone, clone3,
//! io_uring_setup and io_uring_register once its shards are up. Each later
//! start begins a new run on that thread and ring: `stop` ends the run, which
//! settles every fetch the engine held before it returns, and parks the
//! thread; only `deinit` joins it and closes the ring. A run that fails (its
//! data wait, or bookkeeping the owner cannot do without) settles its fetches
//! and latches `owner_fault`, which the gateway's shard supervisor answers by
//! restarting the engine. Source ids run on across runs, so no credit of a
//! run reaches a stream of the next.
//!
//! Files: `owner.zig` the owner loop and its state, `credit_sources.zig` the
//! credit sources, `dial.zig` dials and the origin records, `h2.zig` HTTP/2
//! streams, `h1.zig` HTTP/1 fetches, `result.zig` task settlement.

const std = @import("std");
const core = @import("collo_egress_core");
const data_io = @import("../io/bio_data.zig");
const http2 = @import("../transport/h2/codec/root.zig");
const transport = @import("../transport/root.zig");
const task_model = @import("../task.zig");
const owner_mod = @import("owner.zig");
pub const credit_sources = @import("credit_sources.zig");
pub const result = @import("result.zig");
pub const Hop = owner_mod.Hop;

const body_credit = core.body_credit;
const DnsCache = transport.DnsCache;
const CreditSources = credit_sources.CreditSources;
const Task = task_model.Task;

pub const WakeEvent = union(enum) {
    generic,
    task_ready: Task.ReadyToken,
};

pub const WakeFn = *const fn (?*anyopaque, WakeEvent) void;

/// A fetch to submit.
pub const Command = struct {
    task: *Task,
    config: transport.Config,
    /// What every wake for the fetch carries with the task: the gateway's
    /// handle of the fetch's record, which never names another record. Zero,
    /// which only tests leave, makes each of the fetch's wakes a request to
    /// look at every fetch of the shard.
    ready_generation: u64 = 0,
};

/// What one owner iteration takes from the producers.
pub const Work = struct {
    /// Linked through `Task.engine.next_submitted`, oldest first; each holds
    /// the engine's task reference.
    submitted: ?*Task,
    /// Linked through `Task.engine.next_canceled`; each holds a reference
    /// the cancel took.
    canceled: ?*Task,
    /// The sources whose released credit this iteration took, walked with
    /// `CreditSources.claimNext`.
    credited: credit_sources.Taken,
};

/// Error codes ride an atomic as their integer representation (0 = none).
const FaultInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

pub const Engine = struct {
    allocator: std.mem.Allocator,
    /// Guards the lists, the source table's producer side and the run state
    /// below. The owner never holds it while it waits or applies work.
    mutex: std.Thread.Mutex = .{},
    submitted_head: ?*Task = null,
    submitted_tail: ?*Task = null,
    canceled_head: ?*Task = null,
    credit_sources: CreditSources,
    /// Written by producers, polled by the owner's data wait.
    wake_fd: std.posix.fd_t,
    dns_cache: DnsCache,
    /// Set by a resolver thread after a lookup completes; the owner collects
    /// its tickets when it finds it set. One flag coalesces any number of
    /// completions, since the answers wait in the cache.
    dns_answered: std.atomic.Value(bool) = .init(false),
    hpack_scratch: http2.HpackScratch,
    /// Created by the first start, before the gateway's seccomp filter, and
    /// used by the owner thread alone.
    data_driver: ?data_io.Driver = null,
    owner_thread: ?std.Thread = null,
    /// A run is active: set by start, cleared by stop once the owner parked.
    started: bool = false,
    /// The active run is ending; the owner leaves its loop when it sees it.
    stopping: bool = false,
    /// Set by deinit after the last stop: the parked owner returns.
    exiting: bool = false,
    /// Bumped by every start, so the parked owner runs once per new value.
    run_epoch: u64 = 0,
    owner_running: bool = false,
    /// The owner parks here between runs.
    run_condition: std.Thread.Condition = .{},
    /// Stop waits here for the owner to finish its run.
    parked_condition: std.Thread.Condition = .{},
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?WakeFn = null,
    /// Fault latch, 0 while healthy. The owner sets it, with a generic wake,
    /// when its run fails; the gateway's next collection pass takes it.
    owner_fault: std.atomic.Value(FaultInt) = .init(0),

    /// `sources_max` is the most HTTP/2 streams and HTTP/1 fetches the
    /// engine runs at once, at most `credit_sources.capacity_max`; a fetch
    /// that finds every credit source taken fails with
    /// `error.EgressEngineSourcesExhausted`. A fetch holds at most one source
    /// at a time, so the most fetches the gateway admits to one shard is
    /// enough, and the table allocates only as many as run at once. Fails
    /// with `error.OutOfMemory` or the eventfd's error.
    pub fn init(allocator: std.mem.Allocator, sources_max: usize) !Engine {
        const sources = CreditSources.init(allocator, sources_max);
        var hpack_scratch = try http2.HpackScratch.init(allocator);
        errdefer hpack_scratch.deinit(allocator);
        const wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        return .{
            .allocator = allocator,
            .credit_sources = sources,
            .wake_fd = wake_fd,
            .dns_cache = DnsCache.init(allocator, .{}),
            .hpack_scratch = hpack_scratch,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.stop();
        self.joinOwner();
        if (self.data_driver) |*driver|
            driver.deinit();
        self.dns_cache.deinit();
        self.hpack_scratch.deinit(self.allocator);
        self.credit_sources.deinit();
        std.posix.close(self.wake_fd);
        self.* = undefined;
    }

    /// Begins a run. The first call creates the owner thread, its data ring
    /// and the DNS resolver threads; every later call reuses them and
    /// creates nothing, so it is safe under the gateway's seccomp filter.
    /// Fails with `error.EgressDataRingDead` when the ring died, since only a
    /// new process can replace it, and with `error.EgressIoUringUnsupported`
    /// when the kernel or its policy offers no ring with restrictions (Linux
    /// 5.10 or later, io_uring not disabled), which the caller reports.
    pub fn start(self: *Engine, wake_ctx: ?*anyopaque, wake_fn: WakeFn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.started)
            return;
        if (self.owner_thread == null) {
            try self.spawnOwnerLocked();
        } else if (self.data_driver.?.ringDead()) {
            return error.EgressDataRingDead;
        }
        std.debug.assert(self.credit_sources.live == 0);
        self.wake_ctx = wake_ctx;
        self.wake_fn = wake_fn;
        self.owner_fault.store(0, .release);
        self.stopping = false;
        self.started = true;
        self.owner_running = true;
        self.run_epoch += 1;
        self.run_condition.broadcast();
    }

    /// Ends the current run and returns once every fetch the engine held is
    /// settled and the owner parked. The thread, ring and resolvers stay for
    /// the next start. A no-op when no run is active.
    pub fn stop(self: *Engine) void {
        self.mutex.lock();
        if (!self.started) {
            self.mutex.unlock();
            return;
        }
        self.stopping = true;
        self.mutex.unlock();
        self.signalWake();

        self.mutex.lock();
        while (self.owner_running)
            self.parked_condition.wait(&self.mutex);
        self.mutex.unlock();
        self.settleQueuedOnStop();

        self.mutex.lock();
        self.started = false;
        self.stopping = false;
        self.wake_ctx = null;
        self.wake_fn = null;
        self.mutex.unlock();
    }

    /// Queues a fetch and takes a reference to its task, which the engine
    /// releases once, when it is done with the fetch. Fails, taking nothing,
    /// with `error.EgressEngineUnavailable` when no run is active (the engine
    /// never started, or stopped), so a submit never creates a thread, and
    /// with `error.EgressEngineStopped` while a run ends or after it failed,
    /// until `stop`. A task is submitted once.
    pub fn submit(self: *Engine, command: Command) !void {
        const task = command.task;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.started)
            return error.EgressEngineUnavailable;
        if (self.stopping)
            return error.EgressEngineStopped;
        std.debug.assert(!task.engine.submitted);
        task.engine.submitted = true;
        task.engine.config = command.config;
        task.engine.ready_generation = command.ready_generation;
        task.retain();
        if (self.submitted_tail) |tail|
            tail.engine.next_submitted = task
        else
            self.submitted_head = task;
        self.submitted_tail = task;
        self.signalWake();
    }

    /// Asks the owner to end `task`'s fetch: it closes whatever the fetch
    /// holds (a dial, a stream, an exchange) and settles the task, or does
    /// nothing when the fetch already finished. Holds a task reference until
    /// the owner applied it. Only the first cancel of a task counts. A no-op
    /// when no run is active or the run is ending, since stop settles every
    /// fetch. Never waits for the owner.
    pub fn cancel(self: *Engine, task: *Task) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.started or self.stopping)
            return;
        if (task.engine.cancel_queued)
            return;
        task.engine.cancel_queued = true;
        task.retain();
        task.engine.next_canceled = self.canceled_head;
        self.canceled_head = task;
        self.signalWake();
    }

    /// Returns a body chunk's flow-control credit to the source that issued
    /// it. A credit is the only wake for a body parked on its consumer, so a
    /// credit for a live source is never lost; one that names no live source,
    /// such as a credit of an ended stream or of an earlier run, changes
    /// nothing. Never waits for the owner. A no-op when no run is active.
    pub fn releaseFetchBodyCredit(self: *Engine, credit: body_credit.Handle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.started or self.stopping)
            return;
        if (self.credit_sources.release(credit))
            self.signalWake();
    }

    /// One-shot take of a recorded owner fault. The caller owns escalation;
    /// every start clears the latch.
    pub fn takeOwnerFault(self: *Engine) ?anyerror {
        const raw = self.owner_fault.swap(0, .acq_rel);
        if (raw == 0)
            return null;
        return @errorFromInt(raw);
    }

    /// Owner thread, when its run fails: from now on `submit` refuses, and
    /// cancels and credits change nothing, until `stop` settles what was
    /// queued.
    pub fn refuseProducers(self: *Engine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = true;
    }

    /// Records a failed run and wakes the gateway, whose next collection
    /// pass hands the fault to its shard supervisor. Runs on the owner thread
    /// before it reports its run finished, so stop has not cleared the wake
    /// callback yet.
    pub fn noteOwnerFault(self: *Engine, err: anyerror) void {
        self.owner_fault.store(@intCast(@intFromError(err)), .release);
        std.log.warn("egress engine owner run failed: {s}", .{@errorName(err)});
        if (self.wake_fn) |wake_fn|
            wake_fn(self.wake_ctx, .generic);
    }

    /// Owner thread: takes everything producers queued since the last call,
    /// or returns null once the run is ending.
    pub fn takeWork(self: *Engine) ?Work {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping)
            return null;
        const work: Work = .{
            .submitted = self.submitted_head,
            .canceled = self.canceled_head,
            .credited = self.credit_sources.take(),
        };
        self.submitted_head = null;
        self.submitted_tail = null;
        self.canceled_head = null;
        return work;
    }

    /// Owner thread: gives an HTTP/2 stream or an HTTP/1 fetch its credit
    /// source (`CreditSources.acquire`).
    pub fn acquireSource(self: *Engine, target: credit_sources.Target, stream_id: u32) error{ EgressEngineSourcesExhausted, OutOfMemory }!u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.credit_sources.acquire(target, stream_id);
    }

    /// Owner thread: frees a source whose stream or body ended.
    pub fn retireSource(self: *Engine, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.credit_sources.retire(id);
    }

    /// Wakes the owner's data wait. A saturated eventfd already holds a wake.
    pub fn signalWake(self: *Engine) void {
        var one: u64 = 1;
        _ = std.posix.write(self.wake_fd, std.mem.asBytes(&one)) catch |err| switch (err) {
            error.WouldBlock => return,
            else => |unexpected| {
                std.log.debug("failed to wake egress engine owner: {s}", .{@errorName(unexpected)});
                return;
            },
        };
    }

    /// Owner thread: empties the wake eventfd after a wake.
    pub fn drainWake(self: *Engine) void {
        var counter: u64 = 0;
        _ = std.posix.read(self.wake_fd, std.mem.asBytes(&counter)) catch |err| switch (err) {
            error.WouldBlock => return,
            else => |unexpected| {
                std.log.debug("failed to drain egress engine wake: {s}", .{@errorName(unexpected)});
                return;
            },
        };
    }

    /// Owner thread: wakes the gateway with `event`. Valid for the whole run.
    pub fn wake(self: *Engine, event: WakeEvent) void {
        self.wake_fn.?(self.wake_ctx, event);
    }

    /// Runs after the owner parked, while producers are refused: fails the
    /// fetches the owner never took and releases their references, drops the
    /// references cancels held, and drops the credit released since the
    /// owner's last take, whose sources all retired with the run.
    fn settleQueuedOnStop(self: *Engine) void {
        self.mutex.lock();
        var submitted = self.submitted_head;
        var canceled = self.canceled_head;
        self.submitted_head = null;
        self.submitted_tail = null;
        self.canceled_head = null;
        self.credit_sources.clear();
        self.mutex.unlock();
        while (submitted) |task| {
            submitted = task.engine.next_submitted;
            task.engine.next_submitted = null;
            result.publishFailure(task, error.EgressEngineStopped, self.wake_ctx, self.wake_fn.?);
            task.release();
        }
        while (canceled) |task| {
            canceled = task.engine.next_canceled;
            task.engine.next_canceled = null;
            task.release();
        }
    }

    /// First start only, called and returning with the mutex held. On
    /// failure nothing it created stays except resolver threads, which idle
    /// until the next attempt or deinit.
    fn spawnOwnerLocked(self: *Engine) !void {
        std.debug.assert(self.data_driver == null);
        self.data_driver = data_io.Driver.init(self.allocator) catch |err| switch (err) {
            error.UnsupportedKernel, error.PermissionDenied => return error.EgressIoUringUnsupported,
            else => return err,
        };
        errdefer {
            self.data_driver.?.deinit();
            self.data_driver = null;
        }
        self.dns_cache.setNotify(.{ .context = self, .function = dnsAnswered });
        try self.dns_cache.startResolvers();
        self.owner_thread = try std.Thread.spawn(
            .{ .stack_size = std.Thread.SpawnConfig.default_stack_size },
            ownerMain,
            .{self},
        );
    }

    /// Ends the parked owner thread. Runs after the last stop.
    fn joinOwner(self: *Engine) void {
        const thread = self.owner_thread orelse return;
        self.mutex.lock();
        std.debug.assert(!self.started);
        std.debug.assert(!self.owner_running);
        self.exiting = true;
        self.run_condition.broadcast();
        self.mutex.unlock();
        thread.join();
        self.owner_thread = null;
        self.exiting = false;
    }

    fn ownerMain(self: *Engine) void {
        var seen_epoch: u64 = 0;
        while (self.awaitRun(&seen_epoch)) {
            owner_mod.run(self, &self.data_driver.?);
            self.finishRun();
        }
    }

    /// Parks the owner until a run newer than `seen_epoch` starts (true) or
    /// deinit ends the thread (false).
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

    /// A run that ended on its own failure leaves no owner to take work, so
    /// it ends as a stopping run does: `submit` refuses, and cancels and
    /// credits change nothing, until `stop` settles what was queued.
    fn finishRun(self: *Engine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.owner_running);
        self.owner_running = false;
        self.stopping = true;
        self.parked_condition.broadcast();
    }

    fn dnsAnswered(context: ?*anyopaque) void {
        const self: *Engine = @ptrCast(@alignCast(context.?));
        self.dns_answered.store(true, .release);
        self.signalWake();
    }
};
