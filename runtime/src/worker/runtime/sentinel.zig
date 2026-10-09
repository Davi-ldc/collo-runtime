//! The worker's sentinel: a thread that stops a JavaScript turn past its
//! request's deadline and ends the worker when its cgroup reports memory
//! pressure. The VM thread arms and disarms deadlines and publishes the turn
//! owner. The sentinel thread polls its command eventfd and the cgroup's
//! `memory.events.local`, and outside its own state it only requests the
//! VM's termination and writes trace lines and the lifecycle state on the
//! shared page. `start` runs before seccomp (`zygote/child_boot.zig`), which
//! denies the clone a later start would need.
//!
//! A deadline fires only while its own request is the published turn owner,
//! because the engine's termination trap stops whatever JavaScript the VM
//! thread is running. The VM is created with `forbidExecutionOnTermination`,
//! so a fire cannot be undone: the entry stays spent until the VM thread
//! disarms it, and the worker then stops after its drain
//! (`Runtime.stop_after_deadline_fire`). An expired entry whose request is
//! not running is left to the event loop, which answers that request's 504
//! itself (`collectDueRequestDeadlines`).
//!
//! Memory pressure means the `high` count of `memory.events.local` rose above
//! the count read at init, so the worker went past `memory.high`, its
//! configured memory limit. The sentinel then publishes the dead state with
//! reason `.memory` on the shared page and exits the process at once,
//! without unwinding the VM thread.

const std = @import("std");
const bindings = @import("collo_bindings");
const cgroup = @import("collo_cgroup");
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const worker_shared_page = @import("collo_worker_state").page;

const poll_events: u32 = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
const memory_events_poll: u32 = std.posix.POLL.PRI | std.posix.POLL.HUP | std.posix.POLL.ERR;
const memory_pressure_exit_status: u8 = 125;

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
    /// Replaces the VM termination request, so a test can observe fires.
    termination_hook: ?TerminationHook = null,
};

pub const TerminationHook = struct {
    ctx: *anyopaque,
    request: *const fn (*anyopaque) anyerror!void,
};

/// Every deadline that can be armed at once: one per live request slot on
/// the shared page, plus the boot context's. A comptime assert keeps the
/// largest `concurrency` a definition may set equal to `LIVE_SLOT_COUNT`
/// (`worker_concurrency_max` in `common/limits/server.zig`, pinned in
/// `tests/contracts/limits.zig`).
pub const max_armed_deadlines: usize = worker_shared_page.LIVE_SLOT_COUNT + 1;

/// How long the poll waits while an expired entry belongs to a request that
/// is not the turn owner. Publishing an owner does not wake the sentinel, so
/// sleeping until the next future deadline would leave that request
/// unguarded if its own turn starts right after and hangs, and a zero
/// timeout would spin, since the entry cannot fire until its request runs.
/// The common case never waits this long: the loop answers the expired
/// request's 504 and disarms the entry first.
const foreign_expiry_recheck_ns: u64 = 50 * std.time.ns_per_ms;

const DeadlineEntry = struct {
    request_id: u64,
    generation: u64,
    deadline_ns: u64,
    termination_requested: bool,
};

pub const Sentinel = struct {
    termination_ctx: *anyopaque,
    termination_fn: *const fn (*anyopaque) anyerror!void,
    command_fd: std.posix.fd_t,
    memory_events_fd: ?std.posix.fd_t,
    metrics: ?*worker_shared_page.WorkerWriterView,
    trace_fd: ?std.posix.fd_t,
    memory_events_baseline: cgroup.memory.Events,
    thread: ?std.Thread = null,
    /// Guards `entries`, `entries_len` and `next_generation`, the armed
    /// deadlines of the live requests and the boot context. A holder only
    /// scans or edits at most `max_armed_deadlines` entries, and the
    /// termination request always runs after the release.
    mutex: std.Thread.Mutex,
    entries: [max_armed_deadlines]DeadlineEntry,
    entries_len: usize,
    next_generation: u64,
    /// The request whose JavaScript the VM thread runs now, or 0 for no
    /// single owner. The termination trap stops whatever JavaScript is
    /// running, so an expired entry fires only while its own request is the
    /// owner; otherwise another request would be killed in its place.
    turn_owner: std.atomic.Value(u64),
    /// Serializes an owner change against a fire. The atomic alone cannot:
    /// the fire path loads the owner and scans before it requests
    /// termination, and the owner can change in between. The VM thread holds
    /// the lease only around its store; the sentinel holds it from the
    /// owner's recheck through the termination request. Lock order is
    /// `owner_lease` before `mutex`: the fire path takes `mutex` inside the
    /// lease (`handleTimeout`), and no path takes the lease while holding
    /// `mutex`.
    owner_lease: std.Thread.Mutex,
    stop_requested: std.atomic.Value(bool),

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

        return .{
            .termination_ctx = hook.ctx,
            .termination_fn = hook.request,
            .command_fd = command_fd,
            .memory_events_fd = config.memory_events_fd,
            .metrics = config.metrics,
            .trace_fd = config.trace_fd,
            .memory_events_baseline = baseline,
            .mutex = .{},
            .entries = undefined,
            .entries_len = 0,
            .next_generation = 1,
            .turn_owner = std.atomic.Value(u64).init(0),
            .owner_lease = .{},
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

    /// Arms a CLOCK_MONOTONIC deadline for `request_id` and returns the
    /// generation that `disarm` and `terminationWasRequested` take. Fails
    /// with `error.InvalidRequestId` for 0, which means no owner, and with
    /// `error.DeadlineSetFull` when other requests hold every entry.
    pub fn arm(self: *Sentinel, request_id: u64, deadline_monotonic_ns: u64) !u64 {
        if (request_id == 0)
            return error.InvalidRequestId;

        self.mutex.lock();
        const generation = self.nextGenerationLocked();
        const slot = slot: {
            // A request holds at most one entry: arming it again replaces
            // that entry instead of taking a second one.
            for (self.entries[0..self.entries_len]) |*entry| {
                if (entry.request_id == request_id)
                    break :slot entry;
            }
            if (self.entries_len == max_armed_deadlines) {
                self.mutex.unlock();
                return error.DeadlineSetFull;
            }
            const entry = &self.entries[self.entries_len];
            self.entries_len += 1;
            break :slot entry;
        };
        slot.* = .{
            .request_id = request_id,
            .generation = generation,
            .deadline_ns = deadline_monotonic_ns,
            .termination_requested = false,
        };
        self.mutex.unlock();
        self.wake();
        return generation;
    }

    /// Removes the entry only while `generation` still matches, so a stale
    /// disarm cannot drop a newer deadline.
    pub fn disarm(self: *Sentinel, request_id: u64, generation: u64) void {
        self.mutex.lock();
        for (self.entries[0..self.entries_len], 0..) |*entry, index| {
            if (entry.request_id != request_id or entry.generation != generation)
                continue;
            self.entries_len -= 1;
            self.entries[index] = self.entries[self.entries_len];
            break;
        }
        self.mutex.unlock();
        self.wake();
    }

    /// Whether this armed entry has fired; false once it is disarmed.
    pub fn terminationWasRequested(self: *Sentinel, request_id: u64, generation: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.findEntryLocked(request_id, generation) orelse return false;
        return entry.termination_requested;
    }

    /// Publishes the owner of the JavaScript the VM thread is about to run,
    /// 0 for no single owner. The VM thread calls it around every turn, and
    /// the lease is contended only while the sentinel fires, so the call
    /// makes no syscall in the common case.
    pub fn publishTurnOwner(self: *Sentinel, request_id: u64) void {
        self.owner_lease.lock();
        defer self.owner_lease.unlock();
        self.turn_owner.store(request_id, .release);
    }

    pub fn clearTurnOwner(self: *Sentinel) void {
        self.owner_lease.lock();
        defer self.owner_lease.unlock();
        self.turn_owner.store(0, .release);
    }

    fn nextGenerationLocked(self: *Sentinel) u64 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0)
            self.next_generation = 1;
        return generation;
    }

    /// Caller holds `mutex`.
    fn findEntryLocked(self: *Sentinel, request_id: u64, generation: u64) ?*DeadlineEntry {
        for (self.entries[0..self.entries_len]) |*entry| {
            if (entry.request_id == request_id and entry.generation == generation)
                return entry;
        }
        return null;
    }

    fn wake(self: *Sentinel) void {
        var one: u64 = 1;
        const bytes = std.mem.asBytes(&one);
        while (true) {
            const written = std.posix.write(self.command_fd, bytes) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    std.log.warn("worker sentinel wake write failed: {s}", .{@errorName(err)});
                    return;
                },
            };
            if (written != @sizeOf(u64)) {
                std.log.warn("worker sentinel wake write was short: {d}", .{written});
                return;
            }
            return;
        }
    }

    fn drainCommandFd(self: *Sentinel) void {
        var value: u64 = 0;
        const bytes = std.mem.asBytes(&value);
        while (true) {
            const read = std.posix.read(self.command_fd, bytes) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    std.log.err("worker sentinel command read failed: {s}", .{@errorName(err)});
                    return;
                },
            };
            if (read != @sizeOf(u64)) {
                std.log.err("worker sentinel command read was short: {d}", .{read});
                return;
            }
        }
    }

    /// Fires the entry: marks it and requests termination, once per entry.
    /// An id and generation that match no entry do nothing. It skips the
    /// owner check, which `handleExpiredDeadline` makes before calling it.
    pub fn handleTimeout(self: *Sentinel, expected_request_id: u64, expected_generation: u64) void {
        self.mutex.lock();
        const entry = self.findEntryLocked(expected_request_id, expected_generation) orelse {
            self.mutex.unlock();
            return;
        };
        if (entry.termination_requested) {
            self.mutex.unlock();
            return;
        }
        entry.termination_requested = true;
        self.mutex.unlock();

        self.termination_fn(self.termination_ctx) catch |err|
            std.log.warn("deadline VM termination request failed request_id={d}: {s}", .{ expected_request_id, @errorName(err) });
    }

    fn handleMemoryEvents(self: *Sentinel) void {
        const fd = self.memory_events_fd orelse return;
        const events = cgroup.memory.readEvents(fd) catch |err| {
            std.log.warn("worker sentinel memory.events read failed: {s}", .{@errorName(err)});
            return;
        };
        const fatal_field = events.highPressureFieldSince(self.memory_events_baseline) orelse return;

        traceEventFmt(self.trace_fd, "child.memory_pressure.detected={s}", .{fatal_field});
        if (self.metrics) |metrics|
            metrics.setState(.dead, .memory);
        traceEvent(self.trace_fd, "child.memory_state_published");
        traceEvent(self.trace_fd, "child.memory_exit");
        std.c._exit(memory_pressure_exit_status);
    }

    fn sentinelPollLoop(self: *Sentinel, start_signal: *StartSignal) void {
        self.validatePollBackend() catch |err| {
            std.log.err("worker sentinel poll backend validation failed: {s}", .{@errorName(err)});
            start_signal.fail(err);
            return;
        };
        start_signal.succeed();
        traceEvent(self.trace_fd, "child.sentinel.poll_backend");

        while (true) {
            var pollfds: [2]std.posix.pollfd = undefined;
            pollfds[0] = .{
                .fd = self.command_fd,
                .events = poll_events,
                .revents = 0,
            };
            var poll_count: usize = 1;
            if (self.memory_events_fd) |fd| {
                pollfds[poll_count] = .{
                    .fd = fd,
                    .events = memory_events_poll,
                    .revents = 0,
                };
                poll_count += 1;
            }

            var timeout: std.posix.timespec = undefined;
            const ready = std.posix.ppoll(pollfds[0..poll_count], self.pollTimeout(&timeout), null) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => {
                    std.log.err("worker sentinel poll failed: {s}", .{@errorName(err)});
                    return;
                },
            };
            if (ready == 0) {
                self.handleExpiredDeadline();
                continue;
            }

            if ((pollfds[0].revents & @as(i16, @intCast(std.posix.POLL.NVAL))) != 0) {
                std.log.err("worker sentinel command fd became invalid", .{});
                return;
            }
            if ((pollfds[0].revents & @as(i16, @intCast(poll_events))) != 0) {
                self.drainCommandFd();
                if (self.stop_requested.load(.acquire))
                    return;
                self.handleExpiredDeadline();
            }
            if (poll_count > 1 and (pollfds[1].revents & @as(i16, @intCast(std.posix.POLL.NVAL))) != 0) {
                std.log.err("worker sentinel memory.events fd became invalid", .{});
                return;
            }
            if (poll_count > 1 and (pollfds[1].revents & @as(i16, @intCast(memory_events_poll))) != 0)
                self.handleMemoryEvents();
        }
    }

    fn validatePollBackend(self: *Sentinel) !void {
        var pollfds: [2]std.posix.pollfd = undefined;
        pollfds[0] = .{
            .fd = self.command_fd,
            .events = poll_events,
            .revents = 0,
        };
        var poll_count: usize = 1;
        if (self.memory_events_fd) |fd| {
            pollfds[poll_count] = .{
                .fd = fd,
                .events = memory_events_poll,
                .revents = 0,
            };
            poll_count += 1;
        }

        while (true) {
            const zero_timeout = std.posix.timespec{ .sec = 0, .nsec = 0 };
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
    }

    fn pollTimeout(self: *Sentinel, storage: *std.posix.timespec) ?*const std.posix.timespec {
        const owner = self.turn_owner.load(.acquire);
        const now = process.monotonicNowNsOrZero();
        self.mutex.lock();
        var wait_ns: ?u64 = null;
        for (self.entries[0..self.entries_len]) |*entry| {
            // A fired entry is spent: it waits for the cooperative disarm
            // and must not keep the poll hot.
            if (entry.termination_requested)
                continue;
            const entry_wait_ns = if (entry.deadline_ns > now)
                entry.deadline_ns - now
            else if (entry.request_id == owner)
                0
            else
                foreign_expiry_recheck_ns;
            wait_ns = @min(wait_ns orelse std.math.maxInt(u64), entry_wait_ns);
        }
        self.mutex.unlock();
        const delta_ns = wait_ns orelse return null;
        storage.* = .{
            .sec = @intCast(delta_ns / std.time.ns_per_s),
            .nsec = @intCast(delta_ns % std.time.ns_per_s),
        };
        return storage;
    }

    fn handleExpiredDeadline(self: *Sentinel) void {
        // Owner 0 means no single request owns what the VM thread runs, if it
        // runs anything, so nothing may be terminated; the loop answers an
        // expired request that is not running (`collectDueRequestDeadlines`).
        const owner = self.turn_owner.load(.acquire);
        if (owner == 0)
            return;
        const now = process.monotonicNowNsOrZero();
        var expired_request_id: u64 = 0;
        var expired_generation: u64 = 0;
        self.mutex.lock();
        for (self.entries[0..self.entries_len]) |*entry| {
            if (entry.termination_requested or entry.deadline_ns > now)
                continue;
            if (entry.request_id != owner)
                continue;
            expired_request_id = entry.request_id;
            expired_generation = entry.generation;
            break;
        }
        self.mutex.unlock();
        if (expired_request_id == 0)
            return;
        // Rechecked under the lease: between the scan above and the request
        // below, the VM thread can hand the turn to another request, which
        // the trap would then kill instead.
        self.owner_lease.lock();
        defer self.owner_lease.unlock();
        if (self.turn_owner.load(.acquire) != expired_request_id)
            return;
        self.handleTimeout(expired_request_id, expired_generation);
    }
};

fn requestVmTermination(ctx: *anyopaque) !void {
    const vm: *bindings.Vm = @ptrCast(@alignCast(ctx));
    try vm.requestTermination();
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
