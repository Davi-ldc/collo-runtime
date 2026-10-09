//! The io_uring of an ingress lane, its user_data encoding, poll masks and
//! the deadline timerfd, used on the lane thread.
//!
//! A packed user_data holds the event kind in its top byte, a 32-bit
//! generation below it and a 24-bit slot or registration index at the
//! bottom; the lane's connection slots and worker registrations fit in that
//! index. Accept completions carry `server_ingress_high_byte` in the same top
//! byte (`common/io/uring_tags.zig`), which no `EventKind` may equal
//! (`ring_driver.zig` checks it at compile time and tests for that tag
//! first). Every user_data the ring hands back was packed by the lane, so a
//! top byte that names no kind is the lane's own fault
//! (`error.UnknownCqeTag`).
//!
//! The server's HTTP/2 module compiles this file without the lane
//! (`server/http2.zig`), so it imports no module that one lacks.
//!
//! Invariants:
//! - Preparing a poll, a cancel or a close only fills a submission queue
//!   entry (`LaneRing.prepare`). The lane hands everything a pass prepared to
//!   the kernel in one `io_uring_enter` at the end of the pass, the same call
//!   that waits when the pass found no work (`LaneRing.submit`,
//!   `LaneRing.submitAndWait`), and every `io_uring_enter` the lane makes is
//!   counted (`LaneRing.enters`). Only a pass that fills the submission queue
//!   submits early, and that call is counted too.
//! - A socket closes through the ring, behind the cancels of its polls in
//!   the same submission (`queueClose`), so no entry prepared for it can meet
//!   a descriptor that a later accept reused.
//! - A submission that fails transiently stays in the submission queue, and
//!   the next submit hands it to the kernel after the lane has reaped its
//!   completions, which is what clears a full completion queue.

const std = @import("std");
const linux = std.os.linux;

const limits = @import("collo_limits");
const fault = @import("../fault.zig");
const LaneFault = fault.LaneFault;

/// The lane lifecycle other threads read from `LaneWorker.lane_state`:
/// `warming` from `prepareStart` until the event loop runs, `active` while it
/// runs, then `exited` or `failed`.
pub const LaneRuntimeState = enum(u8) {
    warming,
    active,
    /// The shutdown drain is over: the lane takes no command any more and
    /// exits next (`ring_driver.handleStop`).
    closed,
    exited,
    failed,
};

pub const EventKind = enum(u8) {
    command,
    deadline_timer,
    connection_read,
    connection_write,
    connection_poll_cancel,
    /// The completion of the close of a connection's socket.
    connection_close,
    worker_completion,
    worker_control,
    worker_control_writable,
    worker_fs_fault,
    worker_pidfd,
    /// The completion of a cancel the lane submitted for one of a worker
    /// registration's polls.
    worker_poll_cancel,
};

pub const EventData = struct {
    kind: EventKind,
    index: u32 = 0,
    generation: u32 = 0,
};

const kind_shift: u6 = 56;
const generation_shift: u6 = 24;
const generation_mask: u64 = (1 << (kind_shift - generation_shift)) - 1;
const index_mask: u64 = (1 << generation_shift) - 1;

pub fn packEventData(data: EventData) u64 {
    return (@as(u64, @intFromEnum(data.kind)) << kind_shift) |
        ((@as(u64, data.generation) & generation_mask) << generation_shift) |
        (@as(u64, data.index) & index_mask);
}

/// Fails with `error.UnknownCqeTag` when the top byte names no kind.
pub fn unpackEventData(value: u64) error{UnknownCqeTag}!EventData {
    const kind_byte: u8 = @intCast(value >> kind_shift);
    const kind = std.meta.intToEnum(EventKind, kind_byte) catch return error.UnknownCqeTag;
    return .{
        .kind = kind,
        .generation = @intCast((value >> generation_shift) & generation_mask),
        .index = @intCast(value & index_mask),
    };
}

pub const read_events: i16 = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
pub const write_events: i16 = std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR;
pub const read_write_events: i16 = std.posix.POLL.IN | std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR;
pub const read_interest: i16 = std.posix.POLL.IN;
pub const write_interest: i16 = std.posix.POLL.OUT;
pub const readiness_interests: i16 = read_interest | write_interest;

pub fn pollMask(events: i16) u32 {
    return @intCast(events);
}

pub fn readinessInterest(events: i16) i16 {
    return events & readiness_interests;
}

pub fn pollEventsForInterest(interest: i16) i16 {
    std.debug.assert(interest == read_interest or interest == write_interest);
    return interest | std.posix.POLL.HUP | std.posix.POLL.ERR;
}

/// The lane's io_uring: `limits.ingress.ring_submission_entries` submission
/// entries and `limits.ingress.ring_completion_entries` completion entries,
/// submitted to only by the lane thread that creates it
/// (IORING_SETUP_SINGLE_ISSUER), and submitting a whole batch even when one
/// entry fails (IORING_SETUP_SUBMIT_ALL), whose failure then reaches that
/// entry's completion.
pub const LaneRing = struct {
    ring: linux.IoUring,
    /// Every `io_uring_enter` this ring made.
    enters: u64 = 0,

    pub fn init() !LaneRing {
        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_CQSIZE | linux.IORING_SETUP_SUBMIT_ALL | linux.IORING_SETUP_SINGLE_ISSUER,
            .cq_entries = limits.ingress.ring_completion_entries,
        });
        return .{ .ring = try linux.IoUring.init_params(limits.ingress.ring_submission_entries, &params) };
    }

    pub fn deinit(self: *LaneRing) void {
        self.ring.deinit();
    }

    /// A vacant submission entry. A queue full of entries the pass prepared
    /// is handed to the kernel first, in one counted call; still full after
    /// that, the lane faults.
    pub fn prepare(self: *LaneRing) LaneFault!*linux.io_uring_sqe {
        return self.ring.get_sqe() catch |err| switch (err) {
            error.SubmissionQueueFull => {
                try self.submit();
                return self.ring.get_sqe();
            },
        };
    }

    /// Hands every prepared entry to the kernel, without waiting, in one
    /// counted `io_uring_enter`; makes no call when nothing is prepared. A
    /// transient failure (`fault.ringErrorIsTransient`) leaves the entries
    /// for the next call; any other failure is the ring's and stops the lane.
    pub fn submit(self: *LaneRing) LaneFault!void {
        const pending = self.ring.flush_sq();
        if (pending == 0)
            return;
        self.enters += 1;
        _ = self.ring.enter(pending, 0, 0) catch |err| {
            if (fault.ringErrorIsTransient(err))
                return;
            return err;
        };
    }

    /// Hands every prepared entry to the kernel and waits until the ring
    /// holds a completion, in one counted `io_uring_enter`.
    pub fn submitAndWait(self: *LaneRing) fault.RingError!void {
        const pending = self.ring.flush_sq();
        self.enters += 1;
        _ = try self.ring.enter(pending, 1, linux.IORING_ENTER_GETEVENTS);
    }

    /// Copies the completions the ring holds, without waiting. Only a
    /// completion queue that overflowed into the kernel takes a call, which
    /// is counted.
    pub fn copyCompletions(self: *LaneRing, cqes: []linux.io_uring_cqe) fault.RingError!u32 {
        if (self.ring.cq_ready() == 0 and self.ring.cq_ring_needs_flush()) {
            self.enters += 1;
            _ = try self.ring.enter(0, 0, linux.IORING_ENTER_GETEVENTS);
        }
        return self.ring.copy_cqes(cqes, 0);
    }

    /// Whether entries are prepared and not yet handed to the kernel.
    pub fn hasPending(self: *LaneRing) bool {
        return self.ring.sq_ready() != 0;
    }

    /// Prepares a one-shot poll of `fd` for `events`, its completion tagged
    /// with `data`.
    pub fn queuePoll(self: *LaneRing, fd: std.posix.fd_t, events: u32, data: EventData) LaneFault!void {
        const sqe = try self.prepare();
        sqe.prep_poll_add(fd, events);
        sqe.user_data = packEventData(data);
    }

    /// Prepares the cancel of the poll tagged `target`, its own completion
    /// tagged with `data`. Cancelling by user_data keeps a reused descriptor
    /// out of reach.
    pub fn queuePollCancel(self: *LaneRing, data: EventData, target: EventData) LaneFault!void {
        const sqe = try self.prepare();
        sqe.prep_poll_remove(packEventData(target));
        sqe.user_data = packEventData(data);
    }

    /// Prepares the close of `fd`, its completion tagged with `data`. It runs
    /// after every entry prepared before it in the same submission, the
    /// cancels of the descriptor's polls among them.
    pub fn queueClose(self: *LaneRing, fd: std.posix.fd_t, data: EventData) LaneFault!void {
        const sqe = try self.prepare();
        sqe.prep_close(fd);
        sqe.user_data = packEventData(data);
    }
};

pub const EventSet = struct {
    timer_fd: std.posix.fd_t = -1,
    /// The deadline the timerfd is armed at, null while disarmed, so a call
    /// that would arm it at the same deadline makes no system call.
    timer_armed_ns: ?u64 = null,

    pub fn init() !EventSet {
        const timer_fd = try std.posix.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        return .{ .timer_fd = timer_fd };
    }

    pub fn deinit(self: *EventSet) void {
        if (self.timer_fd >= 0)
            std.posix.close(self.timer_fd);
        self.* = .{};
    }

    /// Arms the timerfd at the absolute CLOCK_MONOTONIC deadline, or disarms
    /// it for null.
    pub fn armDeadlineTimer(self: *EventSet, deadline_monotonic_ns: ?u64) !void {
        if (std.meta.eql(self.timer_armed_ns, deadline_monotonic_ns))
            return;
        const deadline = deadline_monotonic_ns orelse {
            var spec = linux.itimerspec{
                .it_interval = .{ .sec = 0, .nsec = 0 },
                .it_value = .{ .sec = 0, .nsec = 0 },
            };
            try std.posix.timerfd_settime(self.timer_fd, .{}, &spec, null);
            self.timer_armed_ns = null;
            return;
        };
        // A zero `it_value` disarms a timerfd (timerfd_settime(2)), so a
        // deadline of 0 becomes 1 ns, which has passed and fires at once.
        var spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = nsToTimespec(@max(deadline, 1)),
        };
        try std.posix.timerfd_settime(self.timer_fd, .{ .ABSTIME = true }, &spec, null);
        self.timer_armed_ns = deadline;
    }

    /// Reads every expiration the timerfd holds. Ends at `WouldBlock`; a read
    /// that returns fewer than eight bytes fails with
    /// `error.TimerfdShortRead`, and every other error is the read's
    /// (`fault.classifyTimerReadError` sorts them). An expiration leaves the
    /// timerfd disarmed.
    pub fn drainDeadlineTimer(self: *EventSet) fault.TimerReadError!u64 {
        var total: u64 = 0;
        while (true) {
            var value: u64 = 0;
            const read_len = std.posix.read(self.timer_fd, std.mem.asBytes(&value)) catch |err| switch (err) {
                error.WouldBlock => return total,
                else => |other| return other,
            };
            if (read_len != @sizeOf(u64))
                return error.TimerfdShortRead;
            total +|= value;
            self.timer_armed_ns = null;
        }
    }
};

/// Reads every count an eventfd holds. Ends at `WouldBlock`; a read that
/// returns fewer than eight bytes fails with `error.EventfdShortRead`, and
/// every other error is the read's (`fault.classifyWorkerError` sorts them
/// as `.wake`).
pub fn drainEventFd(fd: std.posix.fd_t) fault.WakeError!u64 {
    var total: u64 = 0;
    while (true) {
        var value: u64 = 0;
        const read_len = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
            error.WouldBlock => return total,
            else => |other| return other,
        };
        if (read_len != @sizeOf(u64))
            return error.EventfdShortRead;
        total +|= value;
    }
}

fn nsToTimespec(ns: u64) linux.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}
