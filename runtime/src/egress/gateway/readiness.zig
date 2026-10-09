//! The wait of the egress gateway's main loop: one io_uring that polls the server's control
//! socket, every shard's wake eventfd and each attached worker's command eventfd and liveness
//! descriptor, plus a `wait_tick_ns` timeout so the loop still runs its periodic work when
//! nothing is ready. Only the main loop thread uses it. A liveness descriptor is polled for its
//! hang-up and errors only, since the worker holds the pipe's write end and nothing reads it.
//!
//! The ring must be built before the gateway's seccomp filter, which denies `io_uring_setup` and
//! `io_uring_register`, and its restriction set admits only POLL_ADD, POLL_REMOVE and TIMEOUT
//! submissions, so no code in the gateway can use it for anything but this wait. Polls are
//! one-shot: a completion consumes its poll, and the next `arm` adds it again. Each submission's
//! user_data carries `egress_gateway_readiness_high_byte` and an op id, and a completion that
//! does not decode is dropped.

const std = @import("std");
const linux = std.os.linux;
const restricted_uring = @import("collo_common_io").restricted_uring;
const tags = @import("collo_io_uring_tags");

pub const wait_tick_ns: u64 = 100 * std.time.ns_per_ms;
pub const wait_ready_max: usize = 64;

pub const WorkerFd = struct {
    session_id: u64,
    command_eventfd: std.posix.fd_t,
    liveness_fd: std.posix.fd_t,
};

pub const ShardFd = struct {
    index: usize,
    wake_fd: std.posix.fd_t,
};

/// One readiness completion with the poll's revents, which are `POLL.ERR` when the poll itself
/// failed.
pub const Ready = union(enum) {
    control: i16,
    shard: struct {
        index: usize,
        revents: i16,
    },
    worker: struct {
        session_id: u64,
        source: WorkerSource,
        revents: i16,
    },
};

pub const WorkerSource = enum {
    command,
    liveness,
};

const PollTarget = union(enum) {
    control,
    shard: usize,
    worker: struct {
        session_id: u64,
        source: WorkerSource,
    },
};

/// `closing` means a POLL_REMOVE is queued for the poll; its completion, if one still arrives,
/// is dropped.
const OpState = enum {
    armed,
    closing,
};

const Op = struct {
    target: PollTarget,
    state: OpState = .armed,
};

const WorkerArm = struct {
    command_fd: std.posix.fd_t,
    liveness_fd: std.posix.fd_t,
    command_op_id: ?u64 = null,
    liveness_op_id: ?u64 = null,
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

    pub fn pack(self: UserData) !u64 {
        if (self.op_id == 0)
            return error.InvalidEgressGatewayReadinessOpId;
        if (self.op_id > op_id_mask)
            return error.InvalidEgressGatewayReadinessOpId;
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

pub const gateway_readiness_restriction_count: usize = 4;

pub const Backend = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    control_arm: ControlArm = .{},
    shard_armed: []bool,
    worker_armed: std.AutoHashMapUnmanaged(u64, WorkerArm) = .empty,
    worker_membership: std.AutoHashMapUnmanaged(u64, void) = .empty,
    stale_workers: std.array_list.Aligned(u64, null) = .empty,
    ops: std.AutoHashMapUnmanaged(u64, Op) = .empty,
    next_op_id: u64 = 1,
    timeout_storage: linux.kernel_timespec = timespecFromNs(wait_tick_ns),
    timeout_queued: bool = false,

    pub fn init(allocator: std.mem.Allocator, shard_count: usize, max_workers: usize) !Backend {
        var ring = try initRestrictedGatewayReadinessRing(
            recommendedEntryCount(shard_count, max_workers),
        );
        errdefer ring.deinit();
        const shard_armed = try allocator.alloc(bool, shard_count);
        @memset(shard_armed, false);
        return .{
            .allocator = allocator,
            .ring = ring,
            .shard_armed = shard_armed,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.ring.deinit();
        self.worker_armed.deinit(self.allocator);
        self.worker_membership.deinit(self.allocator);
        self.stale_workers.deinit(self.allocator);
        self.ops.deinit(self.allocator);
        self.allocator.free(self.shard_armed);
        self.* = undefined;
    }

    pub fn arm(
        self: *Backend,
        control_fd: std.posix.fd_t,
        shards: []const ShardFd,
        workers: []const WorkerFd,
    ) !void {
        return self.armWithControlEvents(control_fd, std.posix.POLL.IN, shards, workers);
    }

    pub fn armWithControlEvents(
        self: *Backend,
        control_fd: std.posix.fd_t,
        control_events: i16,
        shards: []const ShardFd,
        workers: []const WorkerFd,
    ) !void {
        var queued = false;
        queued = (try self.armControl(control_fd, control_events)) or queued;

        for (shards) |shard| {
            if (shard.index >= self.shard_armed.len)
                return error.InvalidEgressGatewayShard;
            if (self.shard_armed[shard.index])
                continue;
            _ = try self.poll(shard.wake_fd, .{ .shard = shard.index }, std.posix.POLL.IN);
            self.shard_armed[shard.index] = true;
            queued = true;
        }

        for (workers) |worker| {
            const entry = try self.worker_armed.getOrPut(self.allocator, worker.session_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{
                    .command_fd = worker.command_eventfd,
                    .liveness_fd = worker.liveness_fd,
                };
            } else {
                const same_command_fd = entry.value_ptr.command_fd == worker.command_eventfd;
                const same_liveness_fd = entry.value_ptr.liveness_fd == worker.liveness_fd;
                if (!same_command_fd or !same_liveness_fd) {
                    queued = (try self.closeWorkerArm(entry.value_ptr)) or queued;
                    entry.value_ptr.* = .{
                        .command_fd = worker.command_eventfd,
                        .liveness_fd = worker.liveness_fd,
                    };
                }
            }
            if (entry.value_ptr.command_op_id == null) {
                entry.value_ptr.command_op_id = try self.poll(worker.command_eventfd, .{
                    .worker = .{
                        .session_id = worker.session_id,
                        .source = .command,
                    },
                }, std.posix.POLL.IN);
                queued = true;
            }
            if (entry.value_ptr.liveness_op_id == null) {
                // The hang-up alone, which `poll` always asks for: the worker
                // holds the write end, and a byte it wrote that nothing reads
                // would complete this one-shot poll on every pass.
                entry.value_ptr.liveness_op_id = try self.poll(worker.liveness_fd, .{
                    .worker = .{
                        .session_id = worker.session_id,
                        .source = .liveness,
                    },
                }, 0);
                queued = true;
            }
        }

        if (queued)
            _ = try self.ring.submit();
    }

    pub fn pruneWorkers(self: *Backend, workers: []const WorkerFd) !void {
        self.worker_membership.clearRetainingCapacity();
        self.stale_workers.clearRetainingCapacity();
        try self.worker_membership.ensureTotalCapacity(self.allocator, @intCast(workers.len));
        for (workers) |worker|
            self.worker_membership.putAssumeCapacity(worker.session_id, {});

        var iterator = self.worker_armed.keyIterator();
        while (iterator.next()) |session_id| {
            if (self.worker_membership.contains(session_id.*))
                continue;
            try self.stale_workers.append(self.allocator, session_id.*);
        }

        var queued = false;
        for (self.stale_workers.items) |session_id|
            queued = (try self.removeStaleWorker(session_id)) or queued;
        if (queued)
            _ = try self.ring.submit();
    }

    fn removeStaleWorker(self: *Backend, session_id: u64) !bool {
        var removed = self.worker_armed.fetchRemove(session_id) orelse return false;
        return self.closeWorkerArm(&removed.value);
    }

    fn armControl(self: *Backend, control_fd: std.posix.fd_t, events: i16) !bool {
        const requested_events = normalizeControlEvents(events);
        var queued = false;
        if (self.control_arm.op_id) |op_id| {
            if (self.control_arm.fd != control_fd or self.control_arm.events != requested_events) {
                queued = (try self.closePoll(op_id)) or queued;
                self.control_arm = .{};
            }
        }
        if (self.control_arm.op_id == null) {
            const op_id = try self.poll(control_fd, .control, requested_events);
            self.control_arm = .{
                .fd = control_fd,
                .events = requested_events,
                .op_id = op_id,
            };
            queued = true;
        }
        return queued;
    }

    fn closeWorkerArm(self: *Backend, worker_arm: *WorkerArm) !bool {
        var queued = false;
        if (worker_arm.command_op_id) |op_id| {
            queued = (try self.closePoll(op_id)) or queued;
            worker_arm.command_op_id = null;
        }
        if (worker_arm.liveness_op_id) |op_id| {
            queued = (try self.closePoll(op_id)) or queued;
            worker_arm.liveness_op_id = null;
        }
        return queued;
    }

    fn closePoll(self: *Backend, op_id: u64) !bool {
        const op = self.ops.getPtr(op_id) orelse return false;
        if (op.state == .closing)
            return false;
        try self.queuePollRemove(op_id);
        op.state = .closing;
        return true;
    }

    fn queuePollRemove(self: *Backend, op_id: u64) !void {
        const cancel_user_data = try (UserData{ .kind = .cancel, .op_id = op_id }).pack();
        const poll_user_data = try (UserData{ .kind = .poll, .op_id = op_id }).pack();
        while (true) {
            _ = self.ring.poll_remove(cancel_user_data, poll_user_data) catch |err| switch (err) {
                error.SubmissionQueueFull => {
                    _ = try self.ring.submit();
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    pub fn wait(self: *Backend, out: []Ready) !usize {
        if (out.len == 0)
            return 0;

        try self.queueTickTimeout();
        var cqes: [wait_ready_max]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(cqes[0..@min(cqes.len, out.len)], 1);
        var written: usize = 0;
        for (cqes[0..count]) |cqe| {
            if (try self.decodeReady(cqe)) |ready| {
                out[written] = ready;
                written += 1;
            }
        }
        return written;
    }

    fn poll(self: *Backend, fd: std.posix.fd_t, target: PollTarget, events: i16) !u64 {
        const id = try self.nextOpId();
        try self.ops.put(self.allocator, id, .{ .target = target });
        errdefer _ = self.ops.remove(id);
        const user_data = try (UserData{ .kind = .poll, .op_id = id }).pack();
        _ = try self.ring.poll_add(
            user_data,
            fd,
            pollMask(events | std.posix.POLL.HUP | std.posix.POLL.ERR),
        );
        return id;
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

        const user_data = try (UserData{
            .kind = .timeout,
            .op_id = timeout_user_data_op_id,
        }).pack();
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
        if (removed.value.state == .closing) {
            if (removed.value.target == .control)
                self.clearControlArm(op_id);
            return null;
        }
        const revents = pollRevents(res);
        switch (removed.value.target) {
            .control => {
                self.clearControlArm(op_id);
                return .{ .control = revents };
            },
            .shard => |index| {
                if (index < self.shard_armed.len)
                    self.shard_armed[index] = false;
                return .{ .shard = .{ .index = index, .revents = revents } };
            },
            .worker => |worker| {
                self.clearWorkerArm(worker.session_id, worker.source, op_id);
                return .{
                    .worker = .{
                        .session_id = worker.session_id,
                        .source = worker.source,
                        .revents = revents,
                    },
                };
            },
        }
    }

    fn clearControlArm(self: *Backend, op_id: u64) void {
        if (self.control_arm.op_id == op_id)
            self.control_arm = .{};
    }

    fn clearWorkerArm(self: *Backend, session_id: u64, source: WorkerSource, op_id: u64) void {
        const armed = self.worker_armed.getPtr(session_id) orelse return;
        switch (source) {
            .command => {
                if (armed.command_op_id == op_id)
                    armed.command_op_id = null;
            },
            .liveness => {
                if (armed.liveness_op_id == op_id)
                    armed.liveness_op_id = null;
            },
        }
    }

    fn nextOpId(self: *Backend) !u64 {
        const attempts_max = self.ops.count() + 1;
        var attempts: usize = 0;
        while (attempts < attempts_max) : (attempts += 1) {
            const id = self.next_op_id;
            self.next_op_id += 1;
            if (self.next_op_id > UserData.op_id_mask)
                self.next_op_id = 1;
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
    const errno = errnoFromResult(res) orelse unreachable;
    std.log.warn("egress gateway readiness poll cancel failed op_id={d}: {s}", .{
        op_id,
        @tagName(errno),
    });
    return error.EgressGatewayReadinessCancelFailed;
}

fn initRestrictedGatewayReadinessRing(entries: u13) !linux.IoUring {
    var ring = try linux.IoUring.init(entries, linux.IORING_SETUP_R_DISABLED);
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

/// Submission entries for a pass that arms everything at once: the control poll, one poll per
/// shard, two per worker and the tick timeout, plus headroom for removals; at least 256 and
/// rounded up to a power of two (`ceilPowerOfTwo`).
pub fn recommendedEntryCount(shard_count: usize, max_workers: usize) u13 {
    const minimum: usize = 256;
    const headroom: usize = 32;
    const required = 1 + shard_count + max_workers * 2 + 1 + headroom;
    const target = @max(minimum, required);
    const max_entries: usize = std.math.maxInt(u13);
    return @intCast(ceilPowerOfTwo(@min(target, max_entries)));
}

fn pollMask(events: i16) u32 {
    return @intCast(events);
}

fn normalizeControlEvents(events: i16) i16 {
    return events & (std.posix.POLL.IN | std.posix.POLL.OUT);
}

fn pollRevents(res: i32) i16 {
    return if (res >= 0) @intCast(res) else std.posix.POLL.ERR;
}

fn isBenignCancelResult(res: i32) bool {
    const errno = errnoFromResult(res) orelse return true;
    return switch (errno) {
        .NOENT, .ALREADY, .BUSY, .CANCELED => true,
        else => false,
    };
}

fn errnoFromResult(res: i32) ?linux.E {
    if (res >= 0)
        return null;
    if (res < -4095)
        return null;
    const errno_code: u16 = @intCast(-res);
    return @enumFromInt(errno_code);
}

/// FIXME: above 4096 this returns `maxInt(u13)`, which is not a power of two, so
/// `IoUring.init` would fail with `error.EntriesNotPowerOfTwo`. With `sizing.workers_max`
/// workers and `shard.default_max_shards` shards the count stays far below that.
fn ceilPowerOfTwo(value: usize) usize {
    if (value <= 1)
        return 1;
    var result: usize = 1;
    while (result < value) {
        if (result > std.math.maxInt(u13) / 2)
            return std.math.maxInt(u13);
        result *= 2;
    }
    return result;
}

fn timespecFromNs(ns: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

pub const testing = struct {
    pub const CompletionKindForTest = CompletionKind;
    pub const UserDataForTest = UserData;

    pub fn opCount(backend: *const Backend) usize {
        return backend.ops.count();
    }

    pub fn workerArmCount(backend: *const Backend) usize {
        return backend.worker_armed.count();
    }

    pub fn workerClosingOpCount(backend: *Backend, session_id: u64) usize {
        return workerOpCount(backend, session_id, .closing);
    }

    pub fn workerArmedOpCount(backend: *Backend, session_id: u64) usize {
        return workerOpCount(backend, session_id, .armed);
    }

    pub fn cancelResultIsBenign(res: i32) bool {
        return isBenignCancelResult(res);
    }

    fn workerOpCount(backend: *Backend, session_id: u64, state: OpState) usize {
        var count: usize = 0;
        var iterator = backend.ops.iterator();
        while (iterator.next()) |entry| switch (entry.value_ptr.target) {
            .worker => |worker| {
                if (worker.session_id == session_id and entry.value_ptr.state == state)
                    count += 1;
            },
            else => {},
        };
        return count;
    }
};
