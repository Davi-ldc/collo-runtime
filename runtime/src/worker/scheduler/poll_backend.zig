//! The worker loop's wait, on the VM thread: one `ppoll` over the
//! descriptors whose events the loop handles now, with the earliest of the
//! next timer, the next request deadline, the deferred-work recheck and the
//! idle cache release as its timeout, or a zero timeout while gateway packets
//! may wait past a drain's batch bound, turned into loop events. The set is
//! built anew for every wait from what the runtime holds:
//! - the control socket, for input always, and for room only while a
//!   response send, the retirement notice or a `request_done` waits for it
//!   (`Requests.control_send_blocked`, `Retirement.notice_pending`,
//!   `Requests.done_outbox`);
//! - the wakeup eventfd, which other threads and the engine's deferred work
//!   write;
//! - the payload credit eventfd, while the runtime holds one;
//! - an attached gateway session's completion eventfd and liveness pipe,
//!   whose hangup or error detaches the worker.
//!
//! `ppoll` is level-triggered, so every condition above that it reports is
//! consumed by the event's handler or leaves the next set: a packet read, an
//! eventfd drained, a send that found room. The kernel reports a hangup and
//! an error whatever a descriptor asks for, and one of the control socket
//! fails `wait` and `drain` with `error.ControlPeerClosed`. `ppoll` is in the
//! worker's seccomp allowlist (`zygote/worker_boot/sandbox.zig`), which the
//! sentinel's own wait shares.

const std = @import("std");

const state = @import("../runtime/root.zig");

/// Gateway packets one drain handles while the ready queue holds work
/// (`gatewayIpcDrainBatch` in `loop.zig`).
pub const gateway_ipc_drain_batch_interactive: usize = 64;
/// Gateway packets one drain handles while the ready queue is empty.
pub const gateway_ipc_drain_batch_body_heavy: usize = 256;
/// Recheck period while imminent deferred work, such as an async wasm
/// settlement, is outstanding. The wakeup eventfd is the normal signal; this
/// bounds the cases where none will come, such as a pass cut short by
/// termination that strands its queued tasks. Without outstanding work it
/// sets no timeout.
pub const deferred_work_backstop_ns: u64 = 10 * std.time.ns_per_ms;

/// Most events one wait or drain reports: two from the control socket, one
/// each from the wakeup and payload credit eventfds, two from a session (its
/// completion and its closing) and the deadline.
pub const events_max: usize = 7;

/// Most descriptors one wait watches: the control socket, the wakeup and
/// payload credit eventfds, and a session's completion eventfd and liveness
/// pipe.
const watched_max: usize = 5;

const poll_in: i16 = std.posix.POLL.IN;
const poll_out: i16 = std.posix.POLL.OUT;
const poll_closed: i16 = std.posix.POLL.HUP | std.posix.POLL.ERR;
const poll_invalid: i16 = std.posix.POLL.NVAL;

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
    /// The earliest deadline of the wait has passed.
    timer_deadline,
};

pub const PollBackend = struct {
    /// Absolute deadline of the deferred-work recheck; zero when no imminent
    /// deferred work is outstanding, the normal state. The loop refreshes it
    /// after every pump.
    deferred_backstop_deadline_ns: u64 = 0,
    /// Set while the last gateway drain stopped at its batch bound, so
    /// packets may wait in the session's completion ring
    /// (`collectEgressGatewayPacketsBounded`). Their eventfd was drained
    /// before them and nothing else signals them, so `wait` then polls with
    /// a zero timeout, and the loop drains again at its next tick
    /// (`scheduler/loop.zig`).
    egress_completion_debt: bool = false,
    /// When the VM thread will have been idle `thread_cache_idle_release_ns`
    /// and releases its allocator cache; zero when the cache is released or
    /// the loop is not about to block (`scheduler/loop.zig`).
    idle_cache_release_deadline_ns: u64 = 0,

    /// Blocks until a watched descriptor is ready or the earliest deadline
    /// passes, writes the events into `out` and returns their count, 0 when
    /// a signal cut the wait short. Blocks not at all while
    /// `egress_completion_debt` holds. Fails with `error.ControlPeerClosed`
    /// on a hangup of the control socket and with `error.PollFailed` when a
    /// descriptor the runtime owns is no longer open.
    pub fn wait(self: *const PollBackend, runtime: *state.Runtime, out: *[events_max]Event) !usize {
        if (self.egress_completion_debt)
            return self.drain(runtime, out);
        const deadline_ns = self.nextDeadlineNs(runtime);
        var timeout: std.posix.timespec = undefined;
        const timeout_ptr: ?*const std.posix.timespec = if (deadline_ns) |due_ns| blk: {
            timeout = timespecFromNs(due_ns -| runtime.nowMonoNs());
            break :blk &timeout;
        } else null;
        return poll(runtime, timeout_ptr, deadline_ns, out);
    }

    /// `wait` without blocking.
    pub fn drain(self: *const PollBackend, runtime: *state.Runtime, out: *[events_max]Event) !usize {
        const no_wait = std.posix.timespec{ .sec = 0, .nsec = 0 };
        return poll(runtime, &no_wait, self.nextDeadlineNs(runtime), out);
    }

    /// The earliest of the next timer, the next request deadline, the
    /// deferred-work recheck and the idle cache release, the last two of
    /// which must wake the loop even when no timer or deadline is armed.
    fn nextDeadlineNs(self: *const PollBackend, runtime: *state.Runtime) ?u64 {
        var deadline_ns: ?u64 = runtime.scheduler.timers.peekDueNs();
        const candidates = [_]?u64{
            runtime.nextRequestDeadlineNs(),
            nonZero(self.deferred_backstop_deadline_ns),
            nonZero(self.idle_cache_release_deadline_ns),
        };
        for (candidates) |candidate| {
            const due_ns = candidate orelse continue;
            deadline_ns = @min(deadline_ns orelse due_ns, due_ns);
        }
        return deadline_ns;
    }
};

/// What a watched descriptor is to the loop.
const Watch = enum { control, wakeup, ingress_payload_credit, egress_completion, egress_liveness };

const WatchSet = struct {
    pollfds: [watched_max]std.posix.pollfd = undefined,
    watches: [watched_max]Watch = undefined,
    len: usize = 0,

    fn add(self: *WatchSet, watch: Watch, fd: std.posix.fd_t, events: i16) void {
        std.debug.assert(self.len < watched_max);
        std.debug.assert(fd >= 0);
        self.pollfds[self.len] = .{ .fd = fd, .events = events, .revents = 0 };
        self.watches[self.len] = watch;
        self.len += 1;
    }
};

/// The descriptors the next wait watches, and for what (see the file
/// header). Fails with `error.ControlFdUnavailable` for a runtime without a
/// control socket, which has nothing to wait for that could end its loop.
fn watchSet(runtime: *state.Runtime) !WatchSet {
    var set: WatchSet = .{};
    const control_fd = runtime.core.control_fd orelse return error.ControlFdUnavailable;
    set.add(.control, control_fd, if (controlSendWaits(runtime)) poll_in | poll_out else poll_in);
    if (runtime.scheduler.wakeup_fd) |fd|
        set.add(.wakeup, fd, poll_in);
    if (runtime.requests.ingress_payload_credit_eventfd) |fd|
        set.add(.ingress_payload_credit, fd, poll_in);
    if (runtime.egress.state.shared) |*endpoint| {
        set.add(.egress_completion, endpoint.completion_eventfd, poll_in);
        // The pipe carries no bytes, only its hangup once the gateway's end
        // closes, which the kernel reports unasked.
        set.add(.egress_liveness, endpoint.liveness_fd, 0);
    }
    return set;
}

/// Whether the next wait asks the control socket for room: a writable socket
/// reports room at once, so the set asks for it only while a send waits for
/// it.
pub fn controlSendWaits(runtime: *const state.Runtime) bool {
    if (runtime.requests.control_send_blocked)
        return true;
    if (runtime.retirement.notice_pending)
        return true;
    return !runtime.requests.done_outbox.isEmpty();
}

fn poll(
    runtime: *state.Runtime,
    timeout: ?*const std.posix.timespec,
    deadline_ns: ?u64,
    out: *[events_max]Event,
) !usize {
    var set = try watchSet(runtime);
    _ = std.posix.ppoll(set.pollfds[0..set.len], timeout, null) catch |err| switch (err) {
        // The loop comes back with a timeout computed anew.
        error.SignalInterrupt => return 0,
        else => |other| return other,
    };

    var written: usize = 0;
    var egress_closed = false;
    for (set.pollfds[0..set.len], set.watches[0..set.len]) |pollfd, watch| {
        const revents = pollfd.revents;
        if (revents == 0)
            continue;
        switch (watch) {
            .control => {
                if ((revents & poll_invalid) != 0) {
                    std.log.err("worker control socket poll failed: descriptor not open", .{});
                    return error.PollFailed;
                }
                if ((revents & poll_closed) != 0)
                    return error.ControlPeerClosed;
                if ((revents & poll_in) != 0)
                    written = pushEvent(out, written, .control_ready);
                if ((revents & poll_out) != 0)
                    written = pushEvent(out, written, .control_writable);
            },
            .wakeup, .ingress_payload_credit => {
                if ((revents & poll_invalid) != 0) {
                    std.log.err("worker {s} eventfd poll failed: descriptor not open", .{@tagName(watch)});
                    return error.PollFailed;
                }
                if ((revents & poll_in) != 0) {
                    written = pushEvent(out, written, switch (watch) {
                        .wakeup => .wakeup_ready,
                        else => .ingress_payload_credit_ready,
                    });
                }
            },
            // One closing per wait: the detach it causes drops both
            // descriptors.
            .egress_completion => {
                if (egress_closed)
                    continue;
                if ((revents & poll_invalid) != 0) {
                    written = pushEvent(out, written, .{ .egress_closed = .completion_poll_error });
                    egress_closed = true;
                } else if ((revents & poll_closed) != 0) {
                    written = pushEvent(out, written, .{ .egress_closed = .completion_hup });
                    egress_closed = true;
                } else if ((revents & poll_in) != 0) {
                    written = pushEvent(out, written, .egress_completion_ready);
                }
            },
            .egress_liveness => {
                if (egress_closed)
                    continue;
                if ((revents & poll_invalid) != 0) {
                    written = pushEvent(out, written, .{ .egress_closed = .liveness_poll_error });
                    egress_closed = true;
                } else if ((revents & poll_closed) != 0) {
                    written = pushEvent(out, written, .{ .egress_closed = .liveness_hup });
                    egress_closed = true;
                }
            },
        }
    }
    if (deadline_ns) |due_ns| {
        if (runtime.nowMonoNs() >= due_ns)
            written = pushEvent(out, written, .timer_deadline);
    }
    return written;
}

fn pushEvent(out: *[events_max]Event, written: usize, event: Event) usize {
    std.debug.assert(written < out.len);
    out[written] = event;
    return written + 1;
}

fn nonZero(value_ns: u64) ?u64 {
    return if (value_ns == 0) null else value_ns;
}

fn timespecFromNs(ns: u64) std.posix.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}
