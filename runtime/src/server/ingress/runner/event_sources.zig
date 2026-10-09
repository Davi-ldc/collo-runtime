//! The io_uring user_data encoding, poll masks, submissions and deadline
//! timerfd of an ingress lane, used on the lane thread.
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
//! A submission that fails transiently stays in the submission queue
//! (`submitPending`), and the next submit or the loop's wait
//! (`ring_driver.zig`) hands it to the kernel after the lane has reaped its
//! completions, which is what clears a full completion queue. Only a
//! submission queue that fills up with such entries fails the lane.

const std = @import("std");
const linux = std.os.linux;

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
    connection,
    connection_read,
    connection_write,
    connection_poll_cancel,
    worker_completion,
    worker_control,
    worker_control_writable,
    worker_payload_credit,
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

/// Hands every queued submission to the kernel. A transient failure
/// (`fault.ringErrorIsTransient`) leaves them queued for the next submit or
/// wait, which `ring_driver.zig` makes after reaping; any other failure is
/// the ring's and stops the lane.
pub fn submitPending(ring: *linux.IoUring) LaneFault!void {
    _ = ring.submit() catch |err| {
        if (fault.ringErrorIsTransient(err))
            return;
        return err;
    };
}

pub const EventSet = struct {
    timer_fd: std.posix.fd_t = -1,

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
        const deadline = deadline_monotonic_ns orelse {
            var spec = linux.itimerspec{
                .it_interval = .{ .sec = 0, .nsec = 0 },
                .it_value = .{ .sec = 0, .nsec = 0 },
            };
            try std.posix.timerfd_settime(self.timer_fd, .{}, &spec, null);
            return;
        };
        // A zero `it_value` disarms a timerfd (timerfd_settime(2)), so a
        // deadline of 0 becomes 1 ns, which has passed and fires at once.
        var spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = nsToTimespec(@max(deadline, 1)),
        };
        try std.posix.timerfd_settime(self.timer_fd, .{ .ABSTIME = true }, &spec, null);
    }

    /// Reads every expiration the timerfd holds. Ends at `WouldBlock`; a read
    /// that returns fewer than eight bytes fails with
    /// `error.TimerfdShortRead`, and every other error is the read's
    /// (`fault.classifyTimerReadError` sorts them).
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
        }
    }

    /// Queues and submits a one-shot poll of `fd` for `events`, its
    /// completion tagged with `data`. A queue that transient submit failures
    /// left full (`submitPending`) gets one more submit first; still full
    /// after it, the lane faults.
    pub fn queuePoll(
        _: *EventSet,
        ring: *linux.IoUring,
        fd: std.posix.fd_t,
        events: u32,
        data: EventData,
    ) LaneFault!void {
        _ = ring.poll_add(packEventData(data), fd, events) catch |err| switch (err) {
            error.SubmissionQueueFull => retried: {
                try submitPending(ring);
                break :retried try ring.poll_add(packEventData(data), fd, events);
            },
        };
        try submitPending(ring);
    }

    /// Queues and submits the cancel of the poll tagged `target`, its own
    /// completion tagged with `data`, retrying a full queue as `queuePoll`
    /// does.
    pub fn queuePollCancel(
        _: *EventSet,
        ring: *linux.IoUring,
        data: EventData,
        target: EventData,
    ) LaneFault!void {
        _ = ring.poll_remove(packEventData(data), packEventData(target)) catch |err| switch (err) {
            error.SubmissionQueueFull => retried: {
                try submitPending(ring);
                break :retried try ring.poll_remove(packEventData(data), packEventData(target));
            },
        };
        try submitPending(ring);
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
