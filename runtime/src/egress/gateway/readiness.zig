//! The wait of the egress gateway's main loop: one io_uring that polls the server's control
//! socket, every shard's wake eventfd and each attached session's command eventfd and liveness
//! descriptor, plus a `wait_tick_ns` timeout so the loop still runs its periodic work when
//! nothing is ready. Only the main loop thread uses it. A liveness descriptor is polled for its
//! hang-up and errors only, since the worker holds the pipe's write end and nothing reads it.
//!
//! Polls are one-shot and follow their targets: a shard's poll is added when the shard starts, a
//! session's two polls when it attaches, and both are removed when it goes. A completion consumes
//! its poll and records its target, and `rearm`, which the loop calls once it has handled the
//! pass's events, adds the poll again for each such target still present. Each pass therefore
//! costs work for what woke it, never for every session.
//!
//! The ring must be built before the gateway's seccomp filter, which denies `io_uring_setup` and
//! `io_uring_register`, and its restriction set admits only POLL_ADD, POLL_REMOVE and TIMEOUT
//! submissions, so no code in the gateway can use it for anything but this wait. Each
//! submission's user_data carries `egress_gateway_readiness_high_byte` and an op id, and a
//! completion that does not decode is dropped.

const std = @import("std");
const linux = std.os.linux;
const restricted_uring = @import("collo_common_io").restricted_uring;
const tags = @import("collo_io_uring_tags");

const sizing = @import("sizing.zig");

pub const wait_tick_ns: u64 = 100 * std.time.ns_per_ms;
pub const wait_ready_max: usize = 64;

/// One readiness completion with the poll's revents, which are `POLL.ERR` when the poll itself
/// failed.
pub const Ready = union(enum) {
    control: i16,
    shard: struct {
        index: usize,
        revents: i16,
    },
    session: struct {
        session_id: u64,
        source: SessionSource,
        revents: i16,
    },
};

pub const SessionSource = enum {
    command,
    liveness,
};

const Target = union(enum) {
    control,
    shard: usize,
    session: struct {
        session_id: u64,
        source: SessionSource,
    },
};

/// `closing` means a POLL_REMOVE is queued for the poll; its completion, if one still arrives,
/// is dropped.
const OpState = enum {
    armed,
    closing,
};

const Op = struct {
    target: Target,
    state: OpState = .armed,
};

const SessionArm = struct {
    command_fd: std.posix.fd_t,
    liveness_fd: std.posix.fd_t,
    command_op_id: ?u64 = null,
    liveness_op_id: ?u64 = null,
};

const ShardArm = struct {
    fd: std.posix.fd_t = -1,
    op_id: ?u64 = null,
};

const ControlArm = struct {
    fd: std.posix.fd_t = -1,
    events: i16 = 0,
    op_id: ?u64 = null,
};

const CompletionKind = enum(u8) {
    poll = 1,
    cancel = 2,
    timeout = 3,
};

const UserData = struct {
    kind: CompletionKind,
    op_id: u64,

    const kind_shift: u6 = 48;
    const kind_mask: u64 = 0xff;
    const op_id_mask: u64 = (1 << kind_shift) - 1;

    pub fn pack(self: UserData) u64 {
        std.debug.assert(self.op_id != 0);
        std.debug.assert(self.op_id <= op_id_mask);
        return (tags.egress_gateway_readiness_high_byte << tags.high_byte_shift) |
            (@as(u64, @intFromEnum(self.kind)) << kind_shift) |
            self.op_id;
    }

    pub fn unpack(value: u64) !UserData {
        if ((value >> tags.high_byte_shift) != tags.egress_gateway_readiness_high_byte)
            return error.InvalidEgressGatewayReadinessTag;
        const kind_raw: u8 = @intCast((value >> kind_shift) & kind_mask);
        const kind = std.meta.intToEnum(CompletionKind, kind_raw) catch {
            return error.InvalidEgressGatewayReadinessKind;
        };
        const op_id = value & op_id_mask;
        if (op_id == 0)
            return error.InvalidEgressGatewayReadinessOpId;
        return .{
            .kind = kind,
            .op_id = op_id,
        };
    }
};

const timeout_user_data_op_id: u64 = 1;
/// Poll op ids start above the timeout's and stay below `UserData.op_id_mask`.
const first_poll_op_id: u64 = timeout_user_data_op_id + 1;

pub const gateway_readiness_restriction_count: usize = 4;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    control: ControlArm = .{},
    shards: []ShardArm,
    sessions: std.AutoHashMapUnmanaged(u64, SessionArm) = .empty,
    ops: std.AutoHashMapUnmanaged(u64, Op) = .empty,
    next_op_id: u64 = first_poll_op_id,
    /// Targets whose poll completed in the last `wait`, to arm again in `rearm`. One wait decodes
    /// at most `wait_ready_max` completions.
    disarmed: [wait_ready_max]Target = undefined,
    disarmed_len: usize = 0,
    timeout_storage: linux.kernel_timespec = timespecFromNs(wait_tick_ns),
    timeout_queued: bool = false,

    pub fn init(allocator: std.mem.Allocator, shard_count: usize, max_sessions: usize) !Backend {
        var ring = try initRestrictedGatewayReadinessRing(
            recommendedEntryCount(shard_count, max_sessions),
        );
        errdefer ring.deinit();
        const shards = try allocator.alloc(ShardArm, shard_count);
        @memset(shards, .{});
        return .{
            .allocator = allocator,
            .ring = ring,
            .shards = shards,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.ring.deinit();
        self.sessions.deinit(self.allocator);
        self.ops.deinit(self.allocator);
        self.allocator.free(self.shards);
        self.* = undefined;
    }

    /// Starts polling shard `index`'s wake eventfd `fd` for the rest of the gateway's life.
    pub fn addShard(self: *Backend, index: usize, fd: std.posix.fd_t) !void {
        std.debug.assert(index < self.shards.len);
        std.debug.assert(self.shards[index].op_id == null);
        self.shards[index] = .{ .fd = fd };
        self.shards[index].op_id = try self.poll(fd, .{ .shard = index }, std.posix.POLL.IN);
        _ = try self.ring.submit();
    }

    /// Makes room for one more session, so the `addSession` after a successful attach cannot
    /// fail for memory. Fails with `error.OutOfMemory`.
    pub fn reserveSession(self: *Backend) !void {
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        try self.ops.ensureUnusedCapacity(self.allocator, 2);
    }

    /// Starts polling a newly attached session's command eventfd and liveness descriptor. Fails
    /// when the ring refuses a submission; the caller then removes the session.
    pub fn addSession(
        self: *Backend,
        session_id: u64,
        command_fd: std.posix.fd_t,
        liveness_fd: std.posix.fd_t,
    ) !void {
        const entry = try self.sessions.getOrPut(self.allocator, session_id);
        std.debug.assert(!entry.found_existing);
        entry.value_ptr.* = .{ .command_fd = command_fd, .liveness_fd = liveness_fd };
        errdefer _ = self.sessions.remove(session_id);
        // A new entry has neither poll, so arming it always queues both.
        const queued = try self.armSession(session_id, entry.value_ptr);
        std.debug.assert(queued);
        _ = try self.ring.submit();
    }

    /// Stops polling a session that is going: its polls are removed, and a completion of either
    /// that still arrives is dropped.
    pub fn removeSession(self: *Backend, session_id: u64) !void {
        const removed = self.sessions.fetchRemove(session_id) orelse return;
        var queued = false;
        if (removed.value.command_op_id) |op_id|
            queued = (try self.closePoll(op_id)) or queued;
        if (removed.value.liveness_op_id) |op_id|
            queued = (try self.closePoll(op_id)) or queued;
        if (queued)
            _ = try self.ring.submit();
    }

    /// Polls the control socket for `events`, `POLL.IN` alone or with `POLL.OUT` while control
    /// packets wait to be sent. A poll for other events is replaced.
    pub fn armControl(self: *Backend, control_fd: std.posix.fd_t, events: i16) !void {
        const requested = events & (std.posix.POLL.IN | std.posix.POLL.OUT);
        if (self.control.op_id) |op_id| {
            if (self.control.fd == control_fd and self.control.events == requested)
                return;
            _ = try self.closePoll(op_id);
            self.control = .{};
        }
        const op_id = try self.poll(control_fd, .control, requested);
        self.control = .{ .fd = control_fd, .events = requested, .op_id = op_id };
        _ = try self.ring.submit();
    }

    /// Adds the poll again for each shard and session whose poll completed in the last `wait` and
    /// that is still present. The loop calls it once it has handled the pass's events, so an
    /// eventfd it drained does not complete the new poll at once.
    pub fn rearm(self: *Backend) !void {
        var queued = false;
        for (self.disarmed[0..self.disarmed_len]) |target| {
            switch (target) {
                .control => {},
                .shard => |index| {
                    const arm = &self.shards[index];
                    if (arm.op_id == null and arm.fd >= 0) {
                        arm.op_id = try self.poll(arm.fd, target, std.posix.POLL.IN);
                        queued = true;
                    }
                },
                .session => |session| {
                    const arm = self.sessions.getPtr(session.session_id) orelse continue;
                    queued = (try self.armSession(session.session_id, arm)) or queued;
                },
            }
        }
        self.disarmed_len = 0;
        if (queued)
            _ = try self.ring.submit();
    }

    /// Waits for at least one completion or the tick, then writes up to `out.len` ready events
    /// into `out` and returns how many. A signal that interrupts the wait, as one a debugger or
    /// a profiler attaching to the gateway delivers, ends it with nothing ready: the loop's
    /// next pass waits again, and the tick queued before it stays queued.
    pub fn wait(self: *Backend, out: []Ready) !usize {
        std.debug.assert(out.len <= wait_ready_max);
        std.debug.assert(self.disarmed_len == 0);
        if (out.len == 0)
            return 0;
        try self.queueTickTimeout();
        var cqes: [wait_ready_max]linux.io_uring_cqe = undefined;
        const count = self.ring.copy_cqes(cqes[0..out.len], 1) catch |err| switch (err) {
            error.SignalInterrupt => return 0,
            else => return err,
        };
        var written: usize = 0;
        for (cqes[0..count]) |cqe| {
            if (try self.decodeReady(cqe)) |ready| {
                out[written] = ready;
                written += 1;
            }
        }
        return written;
    }

    /// Adds whichever of a session's two polls is not armed and returns whether it queued one.
    fn armSession(self: *Backend, session_id: u64, arm: *SessionArm) !bool {
        var queued = false;
        if (arm.command_op_id == null) {
            arm.command_op_id = try self.poll(arm.command_fd, .{ .session = .{
                .session_id = session_id,
                .source = .command,
            } }, std.posix.POLL.IN);
            queued = true;
        }
        if (arm.liveness_op_id == null) {
            // The hang-up alone, which `poll` always asks for: the worker holds the write end,
            // and a byte it wrote that nothing reads would complete this one-shot poll on every
            // pass.
            arm.liveness_op_id = try self.poll(arm.liveness_fd, .{ .session = .{
                .session_id = session_id,
                .source = .liveness,
            } }, 0);
            queued = true;
        }
        return queued;
    }

    fn closePoll(self: *Backend, op_id: u64) !bool {
        const op = self.ops.getPtr(op_id) orelse return false;
        if (op.state == .closing)
            return false;
        const cancel_user_data = (UserData{ .kind = .cancel, .op_id = op_id }).pack();
        const poll_user_data = (UserData{ .kind = .poll, .op_id = op_id }).pack();
        while (true) {
            _ = self.ring.poll_remove(cancel_user_data, poll_user_data) catch |err| switch (err) {
                // The kernel takes what the queue holds, which frees every entry.
                error.SubmissionQueueFull => {
                    _ = try self.ring.submit();
                    continue;
                },
                else => return err,
            };
            break;
        }
        op.state = .closing;
        return true;
    }

    fn poll(self: *Backend, fd: std.posix.fd_t, target: Target, events: i16) !u64 {
        const id = try self.nextOpId();
        try self.ops.put(self.allocator, id, .{ .target = target });
        errdefer _ = self.ops.remove(id);
        const user_data = (UserData{ .kind = .poll, .op_id = id }).pack();
        const mask: u32 = @intCast(events | std.posix.POLL.HUP | std.posix.POLL.ERR);
        while (true) {
            _ = self.ring.poll_add(user_data, fd, mask) catch |err| switch (err) {
                // The kernel takes what the queue holds, which frees every entry.
                error.SubmissionQueueFull => {
                    _ = try self.ring.submit();
                    continue;
                },
                else => return err,
            };
            return id;
        }
    }

    fn decodeReady(self: *Backend, cqe: linux.io_uring_cqe) !?Ready {
        const user_data = UserData.unpack(cqe.user_data) catch return null;
        switch (user_data.kind) {
            .poll => return self.decodePollReady(user_data.op_id, cqe.res),
            .cancel => {
                try decodeCancel(user_data.op_id, cqe.res);
                return null;
            },
            .timeout => {
                self.timeout_queued = false;
                return null;
            },
        }
    }

    fn queueTickTimeout(self: *Backend) !void {
        if (self.timeout_queued)
            return;
        const user_data = (UserData{ .kind = .timeout, .op_id = timeout_user_data_op_id }).pack();
        self.timeout_storage = timespecFromNs(wait_tick_ns);
        while (true) {
            _ = self.ring.timeout(user_data, &self.timeout_storage, 0, 0) catch |err| switch (err) {
                error.SubmissionQueueFull => {
                    _ = try self.ring.submit();
                    continue;
                },
                else => return err,
            };
            self.timeout_queued = true;
            _ = try self.ring.submit();
            return;
        }
    }

    fn decodePollReady(self: *Backend, op_id: u64, res: i32) ?Ready {
        const removed = self.ops.fetchRemove(op_id) orelse return null;
        const target = removed.value.target;
        if (removed.value.state == .closing) {
            if (target == .control and self.control.op_id == op_id)
                self.control = .{};
            return null;
        }
        const revents: i16 = if (res >= 0) @intCast(res) else std.posix.POLL.ERR;
        switch (target) {
            .control => {
                if (self.control.op_id == op_id)
                    self.control = .{};
                return .{ .control = revents };
            },
            .shard => |index| {
                self.shards[index].op_id = null;
                self.disarm(target);
                return .{ .shard = .{ .index = index, .revents = revents } };
            },
            .session => |session| {
                if (self.sessions.getPtr(session.session_id)) |arm| {
                    switch (session.source) {
                        .command => arm.command_op_id = null,
                        .liveness => arm.liveness_op_id = null,
                    }
                    self.disarm(target);
                }
                return .{ .session = .{
                    .session_id = session.session_id,
                    .source = session.source,
                    .revents = revents,
                } };
            },
        }
    }

    fn disarm(self: *Backend, target: Target) void {
        std.debug.assert(self.disarmed_len < self.disarmed.len);
        self.disarmed[self.disarmed_len] = target;
        self.disarmed_len += 1;
    }

    fn nextOpId(self: *Backend) !u64 {
        const attempts_max = self.ops.count() + 1;
        var attempts: usize = 0;
        while (attempts < attempts_max) : (attempts += 1) {
            const id = self.next_op_id;
            self.next_op_id += 1;
            if (self.next_op_id > UserData.op_id_mask)
                self.next_op_id = first_poll_op_id;
            if (!self.ops.contains(id))
                return id;
        }
        return error.EgressGatewayReadinessOpIdsExhausted;
    }
};

/// A removal that found its poll already completed or canceled is benign. Any other failure
/// ends the loop with `error.EgressGatewayReadinessCancelFailed`.
fn decodeCancel(op_id: u64, res: i32) !void {
    if (isBenignCancelResult(res))
        return;
    std.log.warn("egress gateway readiness poll cancel failed op_id={d}: {s}", .{
        op_id,
        @tagName(linux.E.init(@bitCast(@as(isize, res)))),
    });
    return error.EgressGatewayReadinessCancelFailed;
}

fn initRestrictedGatewayReadinessRing(entries: u16) !linux.IoUring {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_R_DISABLED,
        .sq_thread_idle = 1000,
    });
    var ring = try restricted_uring.initRingParams(entries, &params);
    errdefer ring.deinit();
    var restrictions = gatewayReadinessRestrictions();
    // The set needs no SQE_FLAGS_ALLOWED entry: once restrictions are registered, the kernel
    // admits only the SQE flags such an entry lists, so this ring admits none, and the gateway
    // never sets any. The opcode restriction limits it to readiness polls, their removals and
    // the loop's tick timeout.
    try restricted_uring.registerRestrictions(ring.fd, &restrictions);
    try restricted_uring.enableRing(ring.fd);
    return ring;
}

pub fn gatewayReadinessRestrictions() [gateway_readiness_restriction_count]restricted_uring.Restriction {
    return .{
        restricted_uring.registerRestriction(.REGISTER_ENABLE_RINGS),
        restricted_uring.sqeRestriction(.POLL_ADD),
        restricted_uring.sqeRestriction(.POLL_REMOVE),
        restricted_uring.sqeRestriction(.TIMEOUT),
    };
}

/// Most submission entries a ring may have (`IORING_MAX_ENTRIES` in the kernel's io_uring
/// setup), a power of two.
pub const ring_entries_max: u16 = 32768;

/// Submission entries for the most polls the ring holds at once: the control poll, one poll per
/// shard, two per session and the tick timeout, plus headroom for removals; at least 256, a power
/// of two, and at most `ring_entries_max`. A submission that still finds the queue full submits
/// what it holds and goes on (`Backend.poll`), and the completion queue, twice as large, holds a
/// completion from every armed poll at once.
pub fn recommendedEntryCount(shard_count: usize, max_sessions: usize) u16 {
    const minimum: usize = 256;
    const target = @max(minimum, requiredEntryCount(shard_count, max_sessions));
    return @intCast(std.math.ceilPowerOfTwoAssert(usize, @min(target, ring_entries_max)));
}

fn requiredEntryCount(shard_count: usize, max_sessions: usize) usize {
    const headroom: usize = 32;
    return 1 + shard_count + max_sessions * 2 + 1 + headroom;
}

comptime {
    // The plan's largest gateway holds every poll at once without waiting on the kernel.
    std.debug.assert(requiredEntryCount(sizing.shards_max, sizing.sessions_max) <= ring_entries_max);
    std.debug.assert(std.math.isPowerOfTwo(ring_entries_max));
}

fn isBenignCancelResult(res: i32) bool {
    if (res >= 0)
        return true;
    return switch (linux.E.init(@bitCast(@as(isize, res)))) {
        .NOENT, .ALREADY, .BUSY, .CANCELED => true,
        else => false,
    };
}

fn timespecFromNs(ns: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}
