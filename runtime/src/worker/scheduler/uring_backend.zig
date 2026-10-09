//! The worker loop's wait, on the VM thread: one-shot polls on the worker
//! ring's fixed files and a timerfd armed for the earliest timer, request
//! deadline or deferred-work recheck, turned into loop events. At most one
//! poll per fixed file and direction is in flight, and `arm` re-queues each
//! after its completion is handled. Every poll waits for input or a hangup,
//! except the control socket's write poll, which `arm` queues only while a
//! response send waits for room in the socket
//! (`Requests.control_send_blocked`). A hangup or error seen by either
//! control poll fails `wait` and `drain` with `error.ControlPeerClosed`. The
//! ring and its restrictions belong to `common/io/restricted_uring.zig`; the
//! seccomp rules that confine io_uring_enter to it and deny setup and
//! register are in `zygote/worker_boot/sandbox.zig`.

const std = @import("std");
const restricted_uring = @import("collo_common_io").restricted_uring;

const state = @import("../runtime/root.zig");
const linux = std.os.linux;

const OperationKind = restricted_uring.OperationKind;
const UserData = restricted_uring.UserData;

/// Gateway packets one drain handles while the ready queue holds work
/// (`gatewayIpcDrainBatch` in `loop.zig`).
pub const gateway_ipc_drain_batch_interactive: usize = 64;
/// Gateway packets one drain handles while the ready queue is empty.
pub const gateway_ipc_drain_batch_body_heavy: usize = 256;
/// Recheck period while imminent deferred work, such as an async wasm
/// settlement, is outstanding. The wakeup eventfd is the normal signal; this
/// bounds the cases where none will come, such as a pass cut short by
/// termination that strands its queued tasks. Without outstanding work it
/// arms nothing.
pub const deferred_work_backstop_ns: u64 = 10 * std.time.ns_per_ms;
/// The user_data generation of every operation; a worker has one ring for
/// its lifetime.
const worker_ring_generation: u64 = 1;

pub const EgressClosedReason = enum {
    completion_poll_error,
    completion_hup,
    liveness_poll_error,
    liveness_hup,
};

pub const Event = union(enum) {
    control_ready,
    /// The control socket has room for a send that found it full.
    control_writable,
    wakeup_ready,
    egress_completion_ready,
    ingress_payload_credit_ready,
    egress_closed: EgressClosedReason,
    fs_fault_ready,
    timer_deadline,
};

pub const UringBackend = struct {
    control_poll_armed: bool = false,
    control_writable_poll_armed: bool = false,
    wakeup_poll_armed: bool = false,
    egress_completion_poll_armed: bool = false,
    egress_liveness_poll_armed: bool = false,
    ingress_payload_credit_poll_armed: bool = false,
    fs_fault_poll_armed: bool = false,
    /// Set on a hangup or error of the fault channel with nothing left to
    /// read, since a re-armed poll would complete at once forever and spin
    /// the loop. Faults stop working; the control channel's hangup is what
    /// stops the worker.
    fs_fault_poll_disabled: bool = false,
    timer_poll_armed: bool = false,
    timer_armed: bool = false,
    timer_deadline_ns: u64 = 0,
    /// Absolute deadline of the deferred-work recheck, folded into the
    /// timerfd; zero when no imminent deferred work is outstanding, the
    /// normal state. The loop refreshes it after every pump.
    deferred_backstop_deadline_ns: u64 = 0,

    /// Arms every poll. Fails with `error.WorkerRingUnavailable` before
    /// `initRestrictedWorkerRing` has run.
    pub fn init(runtime: *state.Runtime) !UringBackend {
        if (runtime.scheduler.worker_ring == null)
            return error.WorkerRingUnavailable;
        var self = UringBackend{};
        errdefer self.deinit();
        try self.arm(runtime);
        return self;
    }

    pub fn deinit(self: *UringBackend) void {
        self.* = undefined;
    }

    /// Queues a poll on every fixed file whose last poll completed, sets or
    /// clears the timerfd for the earliest deadline, and submits only when a
    /// poll was queued, so calling it with every poll in flight costs no
    /// io_uring syscall.
    pub fn arm(self: *UringBackend, runtime: *state.Runtime) !void {
        const ring = if (runtime.scheduler.worker_ring) |*worker_ring| worker_ring else return error.WorkerRingUnavailable;
        runtime.scheduler.metrics.worker_ring_arm_calls += 1;
        var queued_sqes: u64 = 0;

        if (!self.control_poll_armed) {
            try ring.pollFixed(userData(.control_poll, 0), .control, pollMask(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR));
            self.control_poll_armed = true;
            queued_sqes += 1;
        }

        // A writable socket completes this poll at once, so it is armed only
        // while a send waits for room.
        if (runtime.requests.control_send_blocked and !self.control_writable_poll_armed) {
            try ring.pollFixed(userData(.control_writable_poll, 0), .control, pollMask(std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR));
            self.control_writable_poll_armed = true;
            queued_sqes += 1;
        }

        if (!self.wakeup_poll_armed) {
            try ring.pollFixed(userData(.wakeup_poll, 0), .wakeup, pollMask(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR));
            self.wakeup_poll_armed = true;
            queued_sqes += 1;
        }

        if (runtime.egress.state.shared != null and !self.egress_completion_poll_armed) {
            try ring.pollFixed(userData(.egress_completion_poll, 0), .egress_completion, pollMask(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR));
            self.egress_completion_poll_armed = true;
            queued_sqes += 1;
        }

        if (runtime.egress.state.shared != null and !self.egress_liveness_poll_armed) {
            try ring.pollFixed(userData(.egress_liveness_poll, 0), .egress_liveness, pollMask(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR));
            self.egress_liveness_poll_armed = true;
            queued_sqes += 1;
        }

        if (runtime.requests.ingress_payload_credit_eventfd != null and !self.ingress_payload_credit_poll_armed) {
            try ring.pollFixed(userData(.ingress_payload_credit_poll, 0), .ingress_payload_credit, pollMask(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR));
            self.ingress_payload_credit_poll_armed = true;
            queued_sqes += 1;
        }

        if (!self.fs_fault_poll_armed and !self.fs_fault_poll_disabled) {
            try ring.pollFixed(userData(.fs_fault_poll, 0), .fs_fault, pollMask(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR));
            self.fs_fault_poll_armed = true;
            queued_sqes += 1;
        }

        if (!self.timer_poll_armed) {
            try ring.pollFixed(userData(.timer_poll, 0), .timer, pollMask(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR));
            self.timer_poll_armed = true;
            queued_sqes += 1;
        }

        if (self.nextDeadlineWithBackstopNs(runtime)) |deadline_ns| {
            if (!self.timer_armed or self.timer_deadline_ns != deadline_ns) {
                try self.armTimerFd(runtime, deadline_ns);
            }
        } else if (self.timer_armed) {
            try self.disarmTimerFd(runtime);
        }

        if (queued_sqes != 0) {
            runtime.scheduler.metrics.worker_ring_sqe_submits += queued_sqes;
            runtime.scheduler.metrics.worker_ring_submit_syscalls += 1;
            _ = try ring.submit();
        }
    }

    /// Blocks for at least one completion, writes the events the
    /// completions produce into `out` and returns their count. Fails with
    /// `error.ControlPeerClosed` on a hangup of the control channel.
    pub fn wait(self: *UringBackend, runtime: *state.Runtime, out: []Event) !usize {
        if (out.len == 0)
            return 0;
        const ring = if (runtime.scheduler.worker_ring) |*worker_ring| worker_ring else return error.WorkerRingUnavailable;
        var completions: [16]restricted_uring.Completion = undefined;
        const ready = try ring.wait(completions[0..@min(completions.len, out.len)], 1);
        runtime.scheduler.metrics.worker_ring_cqes += ready;
        var written: usize = 0;
        for (completions[0..ready]) |completion| {
            written = try self.handleCompletion(runtime, completion, out, written);
            std.debug.assert(written <= out.len);
        }
        return written;
    }

    /// `wait` without blocking.
    pub fn drain(self: *UringBackend, runtime: *state.Runtime, out: []Event) !usize {
        if (out.len == 0)
            return 0;
        const ring = if (runtime.scheduler.worker_ring) |*worker_ring| worker_ring else return error.WorkerRingUnavailable;
        var completions: [16]restricted_uring.Completion = undefined;
        const ready = try ring.drain(completions[0..@min(completions.len, out.len)]);
        runtime.scheduler.metrics.worker_ring_cqes += ready;
        var written: usize = 0;
        for (completions[0..ready]) |completion| {
            written = try self.handleCompletion(runtime, completion, out, written);
            std.debug.assert(written <= out.len);
        }
        return written;
    }

    fn handleCompletion(
        self: *UringBackend,
        runtime: *state.Runtime,
        completion: restricted_uring.Completion,
        out: []Event,
        written_start: usize,
    ) !usize {
        var written = written_start;
        switch (completion.user_data.kind) {
            .control_poll => {
                self.control_poll_armed = false;
                const revents = pollResult(completion) catch |err| {
                    std.log.err("worker control poll failed res={d}: {s}", .{
                        completion.res,
                        @errorName(err),
                    });
                    return err;
                };
                if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
                    return error.ControlPeerClosed;
                if ((revents & std.posix.POLL.IN) != 0)
                    written = pushEvent(out, written, .control_ready);
            },
            .control_writable_poll => {
                self.control_writable_poll_armed = false;
                const revents = pollResult(completion) catch |err| {
                    std.log.err("worker control writability poll failed res={d}: {s}", .{
                        completion.res,
                        @errorName(err),
                    });
                    return err;
                };
                if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
                    return error.ControlPeerClosed;
                if ((revents & std.posix.POLL.OUT) != 0)
                    written = pushEvent(out, written, .control_writable);
            },
            .wakeup_poll => {
                self.wakeup_poll_armed = false;
                const revents = pollResult(completion) catch 0;
                if ((revents & std.posix.POLL.IN) != 0)
                    written = pushEvent(out, written, .wakeup_ready);
            },
            .egress_completion_poll => {
                self.egress_completion_poll_armed = false;
                if (completion.errno()) |err| {
                    if (err == .AGAIN or err == .INTR)
                        return written;
                    written = pushEvent(out, written, .{ .egress_closed = .completion_poll_error });
                    return written;
                }
                const revents: i16 = @intCast(completion.res);
                if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                    written = pushEvent(out, written, .{ .egress_closed = .completion_hup });
                    return written;
                }
                if ((revents & std.posix.POLL.IN) != 0)
                    written = pushEvent(out, written, .egress_completion_ready);
            },
            .egress_liveness_poll => {
                self.egress_liveness_poll_armed = false;
                if (completion.errno()) |err| {
                    if (err == .AGAIN or err == .INTR)
                        return written;
                    written = pushEvent(out, written, .{ .egress_closed = .liveness_poll_error });
                    return written;
                }
                const revents: i16 = @intCast(completion.res);
                if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
                    written = pushEvent(out, written, .{ .egress_closed = .liveness_hup });
            },
            .ingress_payload_credit_poll => {
                self.ingress_payload_credit_poll_armed = false;
                const revents = pollResult(completion) catch 0;
                if ((revents & std.posix.POLL.IN) != 0)
                    written = pushEvent(out, written, .ingress_payload_credit_ready);
            },
            .fs_fault_poll => {
                self.fs_fault_poll_armed = false;
                const revents = pollResult(completion) catch 0;
                // Readable packets are drained before a hangup disables the
                // poll, so responses sent just before the host end closed
                // still settle their waiters.
                if ((revents & std.posix.POLL.IN) != 0)
                    written = pushEvent(out, written, .fs_fault_ready);
                if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0 and
                    (revents & std.posix.POLL.IN) == 0)
                {
                    std.log.warn("worker fs fault channel closed; fault plane disabled", .{});
                    self.fs_fault_poll_disabled = true;
                }
            },
            .timer_poll => {
                self.timer_poll_armed = false;
                if (completion.errno()) |err| {
                    if (err == .CANCELED or err == .ALREADY or err == .NOENT)
                        return written;
                    std.log.warn("worker timerfd poll failed res={d}: {s}", .{
                        completion.res,
                        @tagName(err),
                    });
                    written = pushEvent(out, written, .timer_deadline);
                    return written;
                }
                try self.drainTimerFd(runtime);
                self.timer_armed = false;
                self.timer_deadline_ns = 0;
                written = pushEvent(out, written, .timer_deadline);
            },
        }
        return written;
    }

    /// The earliest of the next timer, the next request deadline and the
    /// deferred-work recheck, which must wake the loop even when no timer or
    /// deadline is armed.
    fn nextDeadlineWithBackstopNs(self: *const UringBackend, runtime: *state.Runtime) ?u64 {
        const base = nextDeadlineNs(runtime);
        if (self.deferred_backstop_deadline_ns == 0)
            return base;
        if (base) |deadline_ns|
            return @min(deadline_ns, self.deferred_backstop_deadline_ns);
        return self.deferred_backstop_deadline_ns;
    }

    fn armTimerFd(self: *UringBackend, runtime: *state.Runtime, deadline_ns: u64) !void {
        const fd = runtime.scheduler.worker_timer_fd orelse return error.WorkerTimerFdUnavailable;
        const now_ns = runtime.nowMonoNs();
        // A zero it_value disarms a timerfd, so a deadline already past
        // fires after one nanosecond.
        const delay_ns = if (deadline_ns <= now_ns) 1 else deadline_ns - now_ns;
        var spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = timespecFromNs(delay_ns),
        };
        try std.posix.timerfd_settime(fd, .{}, &spec, null);
        self.timer_armed = true;
        self.timer_deadline_ns = deadline_ns;
        runtime.scheduler.metrics.timeout_rearms += 1;
    }

    fn disarmTimerFd(self: *UringBackend, runtime: *state.Runtime) !void {
        const fd = runtime.scheduler.worker_timer_fd orelse return error.WorkerTimerFdUnavailable;
        var spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = 0 },
        };
        try std.posix.timerfd_settime(fd, .{}, &spec, null);
        self.timer_armed = false;
        self.timer_deadline_ns = 0;
        runtime.scheduler.metrics.timeout_cancels += 1;
    }

    fn drainTimerFd(self: *UringBackend, runtime: *state.Runtime) !void {
        _ = self;
        const fd = runtime.scheduler.worker_timer_fd orelse return error.WorkerTimerFdUnavailable;
        while (true) {
            var expirations: u64 = 0;
            const read_len = std.posix.read(fd, std.mem.asBytes(&expirations)) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (read_len != @sizeOf(u64))
                return error.ShortTimerFdRead;
        }
    }
};

fn pushEvent(out: []Event, written: usize, event: Event) usize {
    if (written >= out.len)
        return written;
    out[written] = event;
    return written + 1;
}

fn userData(kind: OperationKind, value: u64) UserData {
    return .{ .kind = kind, .generation = worker_ring_generation, .value = value };
}

fn timespecFromNs(ns: u64) linux.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

fn nextDeadlineNs(runtime: *state.Runtime) ?u64 {
    const timer_due = runtime.scheduler.timers.peekDueNs();
    const request_due = runtime.nextRequestDeadlineNs();
    if (timer_due == null)
        return request_due;
    if (request_due == null)
        return timer_due;
    return @min(timer_due.?, request_due.?);
}

fn pollMask(events: i16) u32 {
    return @intCast(events);
}

fn pollResult(completion: restricted_uring.Completion) !i16 {
    if (completion.errno()) |err| {
        return switch (err) {
            .CANCELED, .NOENT => error.PollCanceled,
            else => error.PollFailed,
        };
    }
    return @intCast(completion.res);
}
