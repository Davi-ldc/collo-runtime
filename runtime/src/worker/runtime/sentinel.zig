//! The worker's sentinel: a thread that stops the JavaScript of the owner
//! the VM thread works for once that owner passes its wall deadline or its
//! CPU deadline, and ends the worker when its cgroup reports memory pressure
//! or when the sentinel itself can no longer watch. The VM thread publishes
//! the owner whose window is open, one at a time (`publish`, which only
//! `owner.zig` calls); the sentinel keeps no table of requests. Only the
//! published owner can be stopped, because the engine's termination trap
//! stops whatever JavaScript the VM thread runs. A request whose deadline
//! passes while it does not run is answered by the event loop's own deadline
//! heap (`collectDueRequestDeadlines` in `scheduler/resources.zig`).
//!
//! It reads two clocks. The wall deadline is CLOCK_MONOTONIC. The CPU
//! deadline is on the VM thread's own CPU clock, whose id `init` builds once
//! from the VM thread's kernel thread id, read with the raw `gettid` syscall,
//! because glibc's cached id of the worker's main thread names the zygote's
//! thread after the worker's `clone3` (`process.threadCpuClockId` in
//! `common/os.zig`). The kernel lets any thread of the process read it. The
//! sentinel sleeps until the earlier of the two deadlines can come, which is
//! exact for the CPU deadline because a thread's CPU time never advances
//! faster than wall time, and re-reads both clocks when it wakes, so
//! preemption only adds wake-ups. An idle worker publishes no owner, and the
//! sentinel then sleeps with no timeout.
//!
//! The planned-wake rule. The sentinel learns of a new owner only when
//! woken. Under `owner_lease` it reads the publication and stores the time
//! it plans to wake; the VM thread stores a publication under the same lease
//! and then reads that time, and writes the command eventfd only when the
//! new owner can expire before it. The lease orders the two critical
//! sections, so either the sentinel plans from the new publication or the VM
//! thread sees the plan made from the old one and wakes it. In steady
//! service that is one write per idle-to-busy transition and one each time
//! an owner nearer its limit takes over, not one per turn.
//!
//! A fire records `Fired` once, writes the owner's CPU to the page's
//! running-owner section, and requests the VM's termination, all under the
//! lease, so the VM thread cannot hand the thread to another owner in
//! between. The VM is created with `forbidExecutionOnTermination`, so a fire
//! cannot be undone: every later JavaScript of any owner fails, and the
//! event loop retires the worker (`checkRetirement` in `retirement.zig`).
//!
//! Memory pressure means the `high` count of `memory.events.local` rose
//! above the count read at init, so the worker went past `memory.high`, its
//! configured memory limit. The sentinel then publishes the dead state with
//! reason `memory` on the shared page and exits the process at once with
//! `memory_pressure_exit_status`, without unwinding the VM thread.
//!
//! A sentinel that cannot watch any more ends its worker (`failWorker`): the
//! server relies on every worker having one, since it is the only thread
//! that can stop the VM thread. Its poll, its command read, its memory
//! events read and its CPU clock read are the failures it cannot recover
//! from. It publishes the dead state with reason `sentinel`, writes
//! `child.sentinel.failed=<cause>` to the trace fd and logs it, and exits
//! with `sentinel_failure_exit_status`.
//!
//! `start` runs before seccomp (`zygote/child_boot.zig`), which denies the
//! clone a later start would need. The sentinel's thread touches only this
//! state, the page's lifecycle and running-owner fields, the trace fd and the
//! VM's termination request, which takes no JavaScript lock.

const std = @import("std");
const bindings = @import("collo_bindings");
const cgroup = @import("collo_cgroup");
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const worker_shared_page = @import("collo_worker_state").page;

const poll_events: u32 = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
const memory_events_poll: u32 = std.posix.POLL.PRI | std.posix.POLL.HUP | std.posix.POLL.ERR;
const memory_pressure_exit_status: u8 = 125;
const sentinel_failure_exit_status: u8 = 124;
const no_planned_wake: u64 = std.math.maxInt(u64);

/// Why the sentinel stopped an owner.
pub const Cause = enum(u8) {
    /// The owner's wall deadline passed while it ran.
    deadline = 1,
    /// The owner's CPU deadline passed while it ran.
    cpu = 2,
};

/// The one fire of a worker's life: the owner it stopped and why.
pub const Fired = struct {
    owner_id: u64,
    cause: Cause,
};

/// Why the sentinel ended its worker (`failWorker`).
pub const FailureCause = enum {
    poll_failed,
    command_fd_invalid,
    command_read_failed,
    memory_events_invalid,
    memory_events_read_failed,
    cpu_clock_failed,
};

/// What the VM thread tells the sentinel about the owner whose window is
/// open (`owner.zig` builds it at every border).
pub const Publication = struct {
    /// The owner, 0 while the VM thread works for none.
    owner_id: u64 = 0,
    /// CLOCK_MONOTONIC instant past which the owner's JavaScript is stopped,
    /// 0 for none.
    wall_deadline_ns: u64 = 0,
    /// Reading of the VM thread's CPU clock past which the owner's
    /// JavaScript is stopped, 0 for none.
    cpu_deadline_ns: u64 = 0,
    /// The CPU the owner used before this window, for the running-owner CPU
    /// on the page.
    cpu_before_ns: u64 = 0,
    /// The VM thread's CPU clock when this window opened.
    window_cpu_start_ns: u64 = 0,
};

/// Hands the poll loop's first check back to `start`, so a descriptor the
/// poll rejects fails the worker's boot instead of leaving it without a
/// sentinel.
const StartSignal = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    ready: bool = false,
    err: ?anyerror = null,

    fn succeed(self: *StartSignal) void {
        self.complete(null);
    }

    fn fail(self: *StartSignal, err: anyerror) void {
        self.complete(err);
    }

    fn complete(self: *StartSignal, err: ?anyerror) void {
        self.mutex.lock();
        self.err = err;
        self.ready = true;
        self.condition.signal();
        self.mutex.unlock();
    }

    fn wait(self: *StartSignal) !void {
        self.mutex.lock();
        while (!self.ready)
            self.condition.wait(&self.mutex);
        const maybe_err = self.err;
        self.mutex.unlock();
        if (maybe_err) |err|
            return err;
    }
};

pub const Config = struct {
    /// The worker cgroup's `memory.events.local`, borrowed; null watches no
    /// memory pressure.
    memory_events_fd: ?std.posix.fd_t = null,
    metrics: ?*worker_shared_page.WorkerWriterView = null,
    trace_fd: ?std.posix.fd_t = null,
    /// The kernel id of the thread whose CPU the CPU deadline measures; null
    /// for the thread that calls `init`, which in a worker is the VM thread
    /// (`Observability.init`). A test names a stand-in thread here.
    vm_thread_tid: ?std.os.linux.pid_t = null,
    /// Replaces the VM termination request, so a test can observe fires.
    termination_hook: ?TerminationHook = null,
    /// Replaces the process exit after a failure, so a test can observe it;
    /// the sentinel's thread returns after calling it.
    failure_hook: ?FailureHook = null,
};

pub const TerminationHook = struct {
    ctx: *anyopaque,
    request: *const fn (*anyopaque) anyerror!void,
};

pub const FailureHook = struct {
    ctx: *anyopaque,
    fail: *const fn (*anyopaque, FailureCause) void,
};

pub const Sentinel = struct {
    termination_ctx: *anyopaque,
    termination_fn: *const fn (*anyopaque) anyerror!void,
    failure_hook: ?FailureHook,
    command_fd: std.posix.fd_t,
    memory_events_fd: ?std.posix.fd_t,
    metrics: ?*worker_shared_page.WorkerWriterView,
    trace_fd: ?std.posix.fd_t,
    memory_events_baseline: cgroup.memory.Events,
    vm_thread_cpu_clock: std.os.linux.clockid_t,
    thread: ?std.Thread = null,
    /// Guards `publication` and `planned_wake_mono_ns`, and serializes an
    /// owner change against a fire: the VM thread holds it only around its
    /// store in `publish`, and the sentinel holds it from its read of the
    /// publication through the termination request. It is the sentinel's
    /// only lock.
    owner_lease: std.Thread.Mutex,
    publication: Publication,
    /// The CLOCK_MONOTONIC instant the sentinel plans to wake at,
    /// `no_planned_wake` while it sleeps with no timeout.
    planned_wake_mono_ns: u64,
    /// `Fired`, stored once by the sentinel: the cause first, then the owner,
    /// whose release the VM thread's acquire load in `fired` pairs with. An
    /// owner id of 0 means no fire.
    fired_owner_id: std.atomic.Value(u64),
    fired_cause: std.atomic.Value(u8),
    stop_requested: std.atomic.Value(bool),

    /// Builds the sentinel on the calling thread, which must be the VM
    /// thread unless `config.vm_thread_tid` names it. Fails when the command
    /// eventfd cannot be created or `memory.events.local` cannot be read.
    pub fn init(vm: *bindings.Vm, config: Config) !Sentinel {
        const command_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(command_fd);

        const baseline = if (config.memory_events_fd) |fd| blk: {
            const snapshot = try cgroup.memory.readEvents(fd);
            traceEvent(config.trace_fd, "child.memory_events.registered");
            break :blk snapshot;
        } else cgroup.memory.Events{};

        const hook = config.termination_hook orelse TerminationHook{
            .ctx = vm,
            .request = requestVmTermination,
        };

        const vm_thread_tid = config.vm_thread_tid orelse std.os.linux.gettid();
        return .{
            .termination_ctx = hook.ctx,
            .termination_fn = hook.request,
            .failure_hook = config.failure_hook,
            .command_fd = command_fd,
            .memory_events_fd = config.memory_events_fd,
            .metrics = config.metrics,
            .trace_fd = config.trace_fd,
            .memory_events_baseline = baseline,
            .vm_thread_cpu_clock = process.threadCpuClockId(vm_thread_tid),
            .owner_lease = .{},
            .publication = .{},
            .planned_wake_mono_ns = no_planned_wake,
            .fired_owner_id = std.atomic.Value(u64).init(0),
            .fired_cause = std.atomic.Value(u8).init(0),
            .stop_requested = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *Sentinel) !void {
        if (self.thread != null)
            return;

        var start_signal = StartSignal{};
        self.thread = try std.Thread.spawn(.{}, sentinelPollLoop, .{ self, &start_signal });
        start_signal.wait() catch |err| {
            if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            }
            return err;
        };
        traceEvent(self.trace_fd, "child.sentinel.started");
    }

    pub fn deinit(self: *Sentinel) void {
        self.stop_requested.store(true, .release);
        self.wake();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        std.posix.close(self.command_fd);
        self.* = undefined;
    }

    /// The VM thread's side: makes `publication` the owner the sentinel
    /// watches, in place of the last one, and wakes the sentinel when the new
    /// owner can expire before the sentinel's planned wake. Called at every
    /// owner window's border (`owner.zig`); the lease is contended only while
    /// the sentinel checks or fires, so in the common case the call makes no
    /// syscall but the clock read a deadline needs.
    pub fn publish(self: *Sentinel, publication: Publication) void {
        self.owner_lease.lock();
        self.publication = publication;
        const planned_wake_mono_ns = self.planned_wake_mono_ns;
        self.owner_lease.unlock();
        if (self.fired_owner_id.load(.acquire) != 0)
            return;
        const expiry_mono_ns = earliestExpiry(publication, process.monotonicNowNsOrZero()) orelse return;
        if (expiry_mono_ns < planned_wake_mono_ns)
            self.wake();
    }

    /// The fire, once the sentinel stopped an owner; null before. The VM
    /// thread reads it to answer the requests the fire stopped and to retire
    /// the worker.
    pub fn fired(self: *const Sentinel) ?Fired {
        const owner_id = self.fired_owner_id.load(.acquire);
        if (owner_id == 0)
            return null;
        return .{
            .owner_id = owner_id,
            .cause = @enumFromInt(self.fired_cause.load(.monotonic)),
        };
    }

    /// The publication as the sentinel would read it, for tests.
    pub fn publishedOwnerId(self: *Sentinel) u64 {
        self.owner_lease.lock();
        defer self.owner_lease.unlock();
        return self.publication.owner_id;
    }

    fn wake(self: *Sentinel) void {
        var one: u64 = 1;
        const written = std.posix.write(self.command_fd, std.mem.asBytes(&one)) catch |err| switch (err) {
            // A full counter means a wake is already pending.
            error.WouldBlock => return,
            else => {
                std.log.warn("worker sentinel wake write failed: {s}", .{@errorName(err)});
                return;
            },
        };
        if (written != @sizeOf(u64))
            std.log.warn("worker sentinel wake write was short: {d}", .{written});
    }

    fn drainCommandFd(self: *Sentinel) !void {
        var value: u64 = 0;
        while (true) {
            const read = std.posix.read(self.command_fd, std.mem.asBytes(&value)) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (read != @sizeOf(u64))
                return error.ShortCommandRead;
        }
    }

    /// Checks the published owner against both clocks, fires when it passed
    /// a deadline, and returns how long to sleep before the earlier of its
    /// deadlines can come, null for no timeout. Writes the owner's CPU to
    /// the page on the way. Fails with `error.CpuClockFailed` when the VM
    /// thread's CPU clock cannot be read.
    fn checkOwner(self: *Sentinel) !?u64 {
        self.owner_lease.lock();
        defer self.owner_lease.unlock();
        const publication = self.publication;
        if (publication.owner_id == 0 or self.fired_owner_id.load(.monotonic) != 0) {
            self.planned_wake_mono_ns = no_planned_wake;
            return null;
        }
        const cpu_now_ns = try self.readVmThreadCpu();
        const now_ns = process.monotonicNowNsOrZero();
        self.publishRunningCpu(publication, cpu_now_ns);
        if (publication.wall_deadline_ns != 0 and now_ns >= publication.wall_deadline_ns) {
            self.fireLocked(publication.owner_id, .deadline);
            self.planned_wake_mono_ns = no_planned_wake;
            return null;
        }
        if (publication.cpu_deadline_ns != 0 and cpu_now_ns >= publication.cpu_deadline_ns) {
            self.fireLocked(publication.owner_id, .cpu);
            self.planned_wake_mono_ns = no_planned_wake;
            return null;
        }
        var wait_ns: ?u64 = null;
        if (publication.wall_deadline_ns != 0)
            wait_ns = publication.wall_deadline_ns - now_ns;
        if (publication.cpu_deadline_ns != 0) {
            const cpu_wait_ns = publication.cpu_deadline_ns - cpu_now_ns;
            wait_ns = @min(wait_ns orelse cpu_wait_ns, cpu_wait_ns);
        }
        self.planned_wake_mono_ns = if (wait_ns) |delta_ns| now_ns +| delta_ns else no_planned_wake;
        return wait_ns;
    }

    /// Caller holds the lease. Records the fire, then requests the VM's
    /// termination; the lease keeps `owner_id` the running owner until the
    /// request is made.
    fn fireLocked(self: *Sentinel, owner_id: u64, cause: Cause) void {
        std.debug.assert(owner_id != 0);
        self.fired_cause.store(@intFromEnum(cause), .monotonic);
        self.fired_owner_id.store(owner_id, .release);
        traceEventFmt(self.trace_fd, "child.sentinel.fired={d},{s}", .{ owner_id, @tagName(cause) });
        self.termination_fn(self.termination_ctx) catch |err|
            std.log.warn("VM termination request failed owner_id={d}: {s}", .{ owner_id, @errorName(err) });
    }

    /// The published owner's CPU so far on the page: its CPU before the
    /// window plus the window up to `cpu_now_ns`. Caller holds the lease.
    fn publishRunningCpu(self: *Sentinel, publication: Publication, cpu_now_ns: u64) void {
        const metrics = self.metrics orelse return;
        if (publication.owner_id == 0)
            return;
        const window_ns = cpu_now_ns -| publication.window_cpu_start_ns;
        metrics.publishRunningOwnerCpu(publication.owner_id, publication.cpu_before_ns +| window_ns);
    }

    /// `publishRunningCpu` for the exits, which have no reading of their
    /// own; a clock that cannot be read leaves the page as the last wake
    /// wrote it.
    fn publishRunningCpuBestEffort(self: *Sentinel) void {
        self.owner_lease.lock();
        defer self.owner_lease.unlock();
        const cpu_now_ns = self.readVmThreadCpu() catch return;
        self.publishRunningCpu(self.publication, cpu_now_ns);
    }

    fn readVmThreadCpu(self: *Sentinel) !u64 {
        return process.threadCpuNs(self.vm_thread_cpu_clock) catch error.CpuClockFailed;
    }

    fn handleMemoryEvents(self: *Sentinel) !void {
        const fd = self.memory_events_fd orelse return;
        const events = try cgroup.memory.readEvents(fd);
        const fatal_field = events.highPressureFieldSince(self.memory_events_baseline) orelse return;

        traceEventFmt(self.trace_fd, "child.memory_pressure.detected={s}", .{fatal_field});
        self.publishRunningCpuBestEffort();
        if (self.metrics) |metrics|
            metrics.setState(.dead, .memory);
        traceEvent(self.trace_fd, "child.memory_state_published");
        traceEvent(self.trace_fd, "child.memory_exit");
        std.c._exit(memory_pressure_exit_status);
    }

    /// Ends the worker for a failure the sentinel cannot recover from. With
    /// a failure hook, as tests install, it calls the hook instead of
    /// exiting, and the caller's thread then returns.
    fn failWorker(self: *Sentinel, cause: FailureCause) void {
        self.publishRunningCpuBestEffort();
        if (self.metrics) |metrics|
            metrics.setState(.dead, .sentinel);
        traceEventFmt(self.trace_fd, "child.sentinel.failed={s}", .{@tagName(cause)});
        std.log.err("worker sentinel failed: {s}", .{@tagName(cause)});
        if (self.failure_hook) |hook| {
            hook.fail(hook.ctx, cause);
            return;
        }
        std.c._exit(sentinel_failure_exit_status);
    }

    fn sentinelPollLoop(self: *Sentinel, start_signal: *StartSignal) void {
        self.validatePollBackend() catch |err| {
            std.log.err("worker sentinel poll backend validation failed: {s}", .{@errorName(err)});
            start_signal.fail(err);
            return;
        };
        start_signal.succeed();
        traceEvent(self.trace_fd, "child.sentinel.poll_backend");

        // Ends only when `deinit` asks or a failure ends the worker; every
        // iteration blocks in `ppoll` until a deadline, a wake or an event.
        while (true) {
            const wait_ns = self.checkOwner() catch {
                self.failWorker(.cpu_clock_failed);
                return;
            };

            var pollfds: [2]std.posix.pollfd = undefined;
            const poll_count = self.pollSet(&pollfds);
            var timeout: std.posix.timespec = undefined;
            const timeout_ptr: ?*const std.posix.timespec = if (wait_ns) |delta_ns| blk: {
                timeout = timespecFromNs(delta_ns);
                break :blk &timeout;
            } else null;
            _ = std.posix.ppoll(pollfds[0..poll_count], timeout_ptr, null) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => {
                    self.failWorker(.poll_failed);
                    return;
                },
            };

            if ((pollfds[0].revents & @as(i16, @intCast(std.posix.POLL.NVAL))) != 0) {
                self.failWorker(.command_fd_invalid);
                return;
            }
            if (poll_count > 1 and (pollfds[1].revents & @as(i16, @intCast(std.posix.POLL.NVAL))) != 0) {
                self.failWorker(.memory_events_invalid);
                return;
            }
            if ((pollfds[0].revents & @as(i16, @intCast(poll_events))) != 0) {
                self.drainCommandFd() catch {
                    self.failWorker(.command_read_failed);
                    return;
                };
                if (self.stop_requested.load(.acquire))
                    return;
            }
            if (poll_count > 1 and (pollfds[1].revents & @as(i16, @intCast(memory_events_poll))) != 0) {
                self.handleMemoryEvents() catch {
                    self.failWorker(.memory_events_read_failed);
                    return;
                };
            }
        }
    }

    fn pollSet(self: *Sentinel, pollfds: *[2]std.posix.pollfd) usize {
        pollfds[0] = .{
            .fd = self.command_fd,
            .events = poll_events,
            .revents = 0,
        };
        const fd = self.memory_events_fd orelse return 1;
        pollfds[1] = .{
            .fd = fd,
            .events = memory_events_poll,
            .revents = 0,
        };
        return 2;
    }

    fn validatePollBackend(self: *Sentinel) !void {
        var pollfds: [2]std.posix.pollfd = undefined;
        const poll_count = self.pollSet(&pollfds);
        const zero_timeout = std.posix.timespec{ .sec = 0, .nsec = 0 };
        while (true) {
            _ = std.posix.ppoll(pollfds[0..poll_count], &zero_timeout, null) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };
            break;
        }
        if ((pollfds[0].revents & @as(i16, @intCast(std.posix.POLL.NVAL))) != 0)
            return error.InvalidSentinelCommandFd;
        if (poll_count > 1 and (pollfds[1].revents & @as(i16, @intCast(std.posix.POLL.NVAL))) != 0)
            return error.InvalidMemoryEventsFd;
        _ = try self.readVmThreadCpu();
    }
};

/// The earliest CLOCK_MONOTONIC instant at which `publication` can pass one
/// of its deadlines, seen at `now_ns`; null when it has none. Its CPU
/// deadline cannot come sooner than its remaining CPU in wall time.
pub fn earliestExpiry(publication: Publication, now_ns: u64) ?u64 {
    if (publication.owner_id == 0)
        return null;
    var expiry_ns: ?u64 = null;
    if (publication.wall_deadline_ns != 0)
        expiry_ns = publication.wall_deadline_ns;
    if (publication.cpu_deadline_ns != 0) {
        const remaining_ns = publication.cpu_deadline_ns -| publication.window_cpu_start_ns;
        const cpu_expiry_ns = now_ns +| remaining_ns;
        expiry_ns = @min(expiry_ns orelse cpu_expiry_ns, cpu_expiry_ns);
    }
    return expiry_ns;
}

fn requestVmTermination(ctx: *anyopaque) !void {
    const vm: *bindings.Vm = @ptrCast(@alignCast(ctx));
    try vm.requestTermination();
}

fn timespecFromNs(ns: u64) std.posix.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

fn traceEvent(trace_fd: ?std.posix.fd_t, event: []const u8) void {
    if (trace_fd == null)
        return;

    var buffer: [process_limits.TRACE_EVENT_BUFFER_BYTES]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s}\n", .{event}) catch return;
    writeBestEffort(trace_fd.?, line, "trace event");
}

fn traceEventFmt(trace_fd: ?std.posix.fd_t, comptime fmt: []const u8, args: anytype) void {
    if (trace_fd == null)
        return;

    var buffer: [process_limits.TRACE_EVENT_BUFFER_BYTES]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, fmt ++ "\n", args) catch return;
    writeBestEffort(trace_fd.?, line, "trace event");
}

fn writeBestEffort(fd: std.posix.fd_t, bytes: []const u8, context: []const u8) void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = std.posix.write(fd, remaining) catch |err| switch (err) {
            error.WouldBlock, error.BrokenPipe, error.ConnectionResetByPeer => return,
            else => |unexpected| {
                std.log.warn("{s} write failed: {s}", .{ context, @errorName(unexpected) });
                return;
            },
        };
        if (written == 0)
            return;
        remaining = remaining[written..];
    }
}
