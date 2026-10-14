//! The zygote and worker handshakes as socket operations: ZygoteReady, the
//! fork request and reply, WorkerInit with its descriptor table, and the init
//! outcome. The host sends fork requests to the zygote's fork loop and
//! WorkerInit to the child on its init socket, which becomes the worker's
//! control socket once the child reports ready.
//!
//! The fixed-size payloads live in `messages.zig`; this file sends and
//! receives them. A `*WithFds` result type exists only where a receive hands
//! back owned descriptors from SCM_RIGHTS next to the payload. No send or
//! receive here allocates, which the zygote's fork loop requires
//! (`zygote/fork_loop.zig`).
//!
//! A fork request carries exactly one descriptor, the worker's cgroup leaf.
//!
//! WorkerInit's descriptor table is the parts of `WorkerInitPart`, in its
//! order: the state page, the completion eventfd, the ingress payload memfd,
//! the payload credit eventfd and the cgroup leaf, always; the region
//! descriptors of the worker's egress session (`egress_shared.region_fd_count`),
//! present exactly when `WorkerInit.boot_egress_token` is not
//! `egress_token.none`; the worker's wake descriptors
//! (`egress_shared.wake_fd_count`), present exactly when the message sets
//! `WorkerInit.flag_egress`; and last the definition artifact
//! (`module_pack.zig`), always. With a session, the regions and the wake
//! descriptors together are the worker's half in `egress_shared.RawFds.asArray`
//! order; a launch whose worker has no session yet carries the wake
//! descriptors alone. The message alone decides the table. The sender owns
//! `flag_egress`, setting it exactly when it sends wake descriptors, and
//! refuses a boot token without the regions and the regions without a token;
//! the receiver rejects any count but the one the message announces, and when
//! the table is short it names the first missing part.

const std = @import("std");
const packet = @import("packet.zig");
const messages = @import("messages.zig");
const egress_shared = @import("egress_shared.zig");
const egress_token = @import("egress_token.zig");

/// The parts of WorkerInit's descriptor table, in table order.
pub const WorkerInitPart = enum {
    /// The worker's state page (`common/worker_state/page.zig`).
    state_page,
    /// The eventfd the worker signals when it frees room in the
    /// server-to-worker payload ring.
    completion_eventfd,
    /// The ingress payload memfd that holds both payload rings
    /// (`ingress_channel/payload_ring.zig`).
    payload_memfd,
    /// The eventfd the server signals when it frees room in the
    /// worker-to-server payload ring.
    payload_credit_eventfd,
    /// The worker's cgroup leaf directory.
    leaf,
    /// The region descriptors of the worker's egress session.
    egress_regions,
    /// The worker's egress wake descriptors.
    egress_wake,
    /// The definition artifact, a sealed memfd.
    artifact,

    fn fdCount(part: WorkerInitPart) usize {
        return switch (part) {
            .egress_regions => egress_shared.region_fd_count,
            .egress_wake => egress_shared.wake_fd_count,
            else => 1,
        };
    }

    fn present(part: WorkerInitPart, message: *const messages.WorkerInit) bool {
        return switch (part) {
            .egress_regions => !egress_token.isNone(&message.boot_egress_token),
            .egress_wake => message.hasEgress(),
            else => true,
        };
    }

    /// How a receive names this part when the table ends before it.
    fn missingError(part: WorkerInitPart) RecvWorkerInitError {
        return switch (part) {
            .state_page => error.MissingMetricsFd,
            .completion_eventfd => error.MissingCompletionEventFd,
            .payload_memfd => error.MissingIngressPayloadFd,
            .payload_credit_eventfd => error.MissingIngressPayloadCreditFd,
            .leaf => error.MissingCgroupDirFd,
            .egress_regions, .egress_wake => error.MissingEgressSharedFd,
            .artifact => error.MissingModulePackFd,
        };
    }
};

const RecvWorkerInitError = error{
    MissingMetricsFd,
    MissingCompletionEventFd,
    MissingIngressPayloadFd,
    MissingIngressPayloadCreditFd,
    MissingCgroupDirFd,
    MissingEgressSharedFd,
    MissingModulePackFd,
    InvalidFdCount,
};

/// Descriptors in the largest table, every part present.
const worker_init_fd_count_max: usize = count: {
    var total: usize = 0;
    for (std.enums.values(WorkerInitPart)) |part|
        total += part.fdCount();
    break :count total;
};

comptime {
    std.debug.assert(worker_init_fd_count_max == messages.max_fds_per_message);
}

/// Where each part of WorkerInit's descriptor table starts for one message.
const WorkerInitTable = struct {
    /// Index of each part's first descriptor; null for a part the message
    /// does not announce.
    first: std.EnumArray(WorkerInitPart, ?usize),
    /// Descriptors in the whole table.
    count: usize,

    fn of(message: *const messages.WorkerInit) WorkerInitTable {
        var table: WorkerInitTable = .{ .first = .initFill(null), .count = 0 };
        for (std.enums.values(WorkerInitPart)) |part| {
            if (!part.present(message))
                continue;
            table.first.set(part, table.count);
            table.count += part.fdCount();
        }
        std.debug.assert(table.count <= worker_init_fd_count_max);
        return table;
    }

    /// The index of a part every table has.
    fn at(self: *const WorkerInitTable, part: WorkerInitPart) usize {
        return self.first.get(part).?;
    }

    /// A short table names its first missing part; a count that is neither
    /// short nor exact is `error.InvalidFdCount`.
    fn checkFdCount(self: *const WorkerInitTable, fd_count: usize) RecvWorkerInitError!void {
        for (std.enums.values(WorkerInitPart)) |part| {
            const first = self.first.get(part) orelse continue;
            if (fd_count < first + part.fdCount())
                return part.missingError();
        }
        if (fd_count != self.count)
            return error.InvalidFdCount;
    }
};

/// A fork reply with the two descriptors it carried, both owned by the
/// receiver; `deinit` closes them.
pub const ForkReplyWithFds = struct {
    message: messages.ForkReply,
    worker_init_fd: std.posix.fd_t,
    worker_pidfd: std.posix.fd_t,

    pub fn deinit(self: *ForkReplyWithFds) void {
        std.posix.close(self.worker_init_fd);
        std.posix.close(self.worker_pidfd);
        self.* = undefined;
    }
};

/// The descriptors a host sends with WorkerInit, every one borrowed, since
/// SCM_RIGHTS duplicates them; field names as in `WorkerInitWithFds`.
pub const WorkerInitFds = struct {
    metrics_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    ingress_payload_fd: std.posix.fd_t,
    ingress_payload_credit_eventfd: std.posix.fd_t,
    cgroup_dir_fd: std.posix.fd_t,
    /// None for a launch without egress; the wake descriptors alone for a
    /// worker with no session yet; the whole half with a session, which the
    /// message's boot token announces.
    egress_shared_fds: egress_shared.RawFds = .{},
    module_pack_fd: std.posix.fd_t,

    /// The descriptor of a part that is one descriptor long.
    fn single(self: *const WorkerInitFds, part: WorkerInitPart) std.posix.fd_t {
        return switch (part) {
            .state_page => self.metrics_fd,
            .completion_eventfd => self.completion_eventfd,
            .payload_memfd => self.ingress_payload_fd,
            .payload_credit_eventfd => self.ingress_payload_credit_eventfd,
            .leaf => self.cgroup_dir_fd,
            .artifact => self.module_pack_fd,
            .egress_regions, .egress_wake => unreachable,
        };
    }
};

/// A received WorkerInit and the descriptors it carried, each owned until a
/// `take*` call moves it out or `deinit` closes it.
pub const WorkerInitWithFds = struct {
    message: messages.WorkerInit,
    metrics_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    ingress_payload_fd: std.posix.fd_t,
    ingress_payload_credit_eventfd: std.posix.fd_t,
    cgroup_dir_fd: std.posix.fd_t,
    /// The definition artifact, a sealed memfd.
    module_pack_fd: std.posix.fd_t,
    /// The worker's egress descriptors: its wake descriptors exactly when the
    /// message sets `WorkerInit.flag_egress`, and the regions of its session
    /// exactly when the message carries a boot token
    /// (`egress_shared.RawFds.regionCount`); empty without either.
    egress_shared_fds: egress_shared.RawFds = .{},

    pub fn deinit(self: *WorkerInitWithFds) void {
        for ([_]std.posix.fd_t{
            self.metrics_fd,
            self.completion_eventfd,
            self.ingress_payload_fd,
            self.ingress_payload_credit_eventfd,
            self.cgroup_dir_fd,
            self.module_pack_fd,
        }) |fd| {
            if (fd >= 0)
                std.posix.close(fd);
        }
        self.egress_shared_fds.close();
        self.* = undefined;
    }

    pub fn takeModulePackFd(self: *WorkerInitWithFds) std.posix.fd_t {
        return takeFd(&self.module_pack_fd);
    }

    pub fn takeMetricsFd(self: *WorkerInitWithFds) std.posix.fd_t {
        return takeFd(&self.metrics_fd);
    }

    pub fn takeCompletionEventfd(self: *WorkerInitWithFds) std.posix.fd_t {
        return takeFd(&self.completion_eventfd);
    }

    pub fn takeIngressPayloadFd(self: *WorkerInitWithFds) std.posix.fd_t {
        return takeFd(&self.ingress_payload_fd);
    }

    pub fn takeIngressPayloadCreditEventfd(self: *WorkerInitWithFds) std.posix.fd_t {
        return takeFd(&self.ingress_payload_credit_eventfd);
    }

    pub fn takeCgroupDirFd(self: *WorkerInitWithFds) std.posix.fd_t {
        return takeFd(&self.cgroup_dir_fd);
    }

    pub fn takeEgressSharedFds(self: *WorkerInitWithFds) egress_shared.RawFds {
        const fds = self.egress_shared_fds;
        self.egress_shared_fds = .{};
        return fds;
    }

    fn takeFd(slot: *std.posix.fd_t) std.posix.fd_t {
        const fd = slot.*;
        slot.* = -1;
        return fd;
    }
};

pub fn sendZygoteReady(fd: std.posix.fd_t) !void {
    const message = messages.ZygoteReady.init();
    try packet.sendExact(fd, std.mem.asBytes(&message));
}

pub fn recvZygoteReady(fd: std.posix.fd_t) !messages.ZygoteReady {
    var message: messages.ZygoteReady = undefined;
    try packet.recvPacketExact(fd, std.mem.asBytes(&message));
    if (try messages.decodeMessageKind(message.kind) != .zygote_ready)
        return error.InvalidMessageKind;
    return message;
}

/// A fork request with the cgroup leaf it carried, owned until
/// `takeCgroupDirFd` moves it out or `deinit` closes it.
pub const ForkRequestWithFd = struct {
    message: messages.ForkRequest,
    cgroup_dir_fd: std.posix.fd_t,

    pub fn deinit(self: *ForkRequestWithFd) void {
        if (self.cgroup_dir_fd >= 0)
            std.posix.close(self.cgroup_dir_fd);
        self.* = undefined;
    }

    pub fn takeCgroupDirFd(self: *ForkRequestWithFd) std.posix.fd_t {
        const fd = self.cgroup_dir_fd;
        self.cgroup_dir_fd = -1;
        return fd;
    }
};

/// Sends a fork request with the worker's cgroup leaf, which stays the
/// caller's, since SCM_RIGHTS duplicates it.
pub fn sendForkRequest(fd: std.posix.fd_t, fork_job_id: u64, cgroup_dir_fd: std.posix.fd_t) !void {
    std.debug.assert(cgroup_dir_fd >= 0);
    const message = messages.ForkRequest.init(fork_job_id);
    try packet.sendWithFds(fd, std.mem.asBytes(&message), &.{cgroup_dir_fd});
}

/// Receives a fork request with its cgroup leaf. Fails with
/// `error.ShortRead` for a packet shorter than the struct and
/// `error.TruncatedMessage` for a longer one, `error.InvalidForkRequest` for
/// a nonzero reserved field and `error.InvalidFdCount` for any count of
/// descriptors but one; every descriptor received closes on failure.
pub fn recvForkRequest(fd: std.posix.fd_t) !ForkRequestWithFd {
    var scratch: [@sizeOf(messages.ForkRequest)]u8 = undefined;
    var received = try packet.recvPacketWithFdsScratch(std.heap.smp_allocator, fd, &scratch);
    defer received.deinit();
    if (received.bytes.len != @sizeOf(messages.ForkRequest))
        return error.ShortRead;
    const message = packet.readStruct(messages.ForkRequest, received.bytes);
    if (try messages.decodeMessageKind(message.kind) != .fork_request)
        return error.InvalidMessageKind;
    if (message._reserved0 != 0)
        return error.InvalidForkRequest;
    if (received.fd_count != 1)
        return error.InvalidFdCount;
    var cgroup_dir_fd = received.takeFd(0);
    return .{
        .message = message,
        .cgroup_dir_fd = cgroup_dir_fd.release(),
    };
}

/// Answers a fork with the child's pid, the host's end of the child's init
/// socket and the child's pidfd, which clone3 created along with the child
/// (CLONE_PIDFD). The host kills and waits through that pidfd instead of
/// the pid, which the kernel may reuse once the auto-reaped child exits.
/// Both fds are borrowed, since SCM_RIGHTS duplicates them, and `pid` is
/// never 0, the mark of `sendForkFailed`.
pub fn sendForkReply(
    fd: std.posix.fd_t,
    fork_job_id: u64,
    pid: u32,
    worker_init_fd: std.posix.fd_t,
    worker_pidfd: std.posix.fd_t,
) !void {
    std.debug.assert(pid != 0);
    const message = messages.ForkReply.init(fork_job_id, pid);
    try packet.sendWithFds(fd, std.mem.asBytes(&message), &.{ worker_init_fd, worker_pidfd });
}

/// Reply for a fork the zygote refused or could not complete while it stays
/// able to serve the next one: a cgroup leaf that fails validation, fd
/// pressure before the clone, or a clone3 failure caused by this job's
/// resources (`isTransientForkError` in `zygote/fork_loop.zig`). pid 0 marks
/// it and no descriptor rides along; `recvForkReply` reports it as
/// `error.ForkTransientFailure`, which the host retries instead of treating
/// the zygote as dead.
pub fn sendForkFailed(fd: std.posix.fd_t, fork_job_id: u64) !void {
    const message = messages.ForkReply.init(fork_job_id, 0);
    try packet.sendExact(fd, std.mem.asBytes(&message));
}

/// Receives the reply to a fork request. A `sendForkFailed` reply fails with
/// `error.ForkTransientFailure`. A success reply without exactly its two
/// descriptors, or a failure reply with any, fails with
/// `error.InvalidFdCount`.
pub fn recvForkReply(fd: std.posix.fd_t) !ForkReplyWithFds {
    var scratch: [@sizeOf(messages.ForkReply)]u8 = undefined;
    var received = try packet.recvPacketWithFdsScratch(std.heap.smp_allocator, fd, &scratch);
    defer received.deinit();
    if (received.bytes.len != @sizeOf(messages.ForkReply))
        return error.ShortRead;
    const message = packet.readStruct(messages.ForkReply, received.bytes);
    if (try messages.decodeMessageKind(message.kind) != .fork_reply)
        return error.InvalidMessageKind;
    if (message.pid == 0) {
        if (received.fd_count != 0)
            return error.InvalidFdCount;
        return error.ForkTransientFailure;
    }
    if (received.fd_count != 2)
        return error.InvalidFdCount;
    var worker_init_fd = received.takeFd(0);
    var worker_pidfd = received.takeFd(1);
    return .{
        .message = message,
        .worker_init_fd = worker_init_fd.release(),
        .worker_pidfd = worker_pidfd.release(),
    };
}

/// Sends WorkerInit with its descriptor table. The packet sent is `message`
/// with `flag_egress` set exactly when wake descriptors travel. Fails with
/// `error.InvalidEgressSharedEndpoint` for some wake descriptors without the
/// rest or some regions without the rest, and `error.InvalidWorkerInit` for
/// regions the boot token does not announce, a boot token without them or
/// without any egress descriptor, or a negative descriptor among the parts
/// that are one descriptor long.
pub fn sendWorkerInit(fd: std.posix.fd_t, message: *const messages.WorkerInit, fds: WorkerInitFds) !void {
    const has_boot_token = !egress_token.isNone(&message.boot_egress_token);
    const shared_fds = fds.egress_shared_fds;
    var outgoing = message.*;
    if (shared_fds.isEmpty()) {
        if (has_boot_token)
            return error.InvalidWorkerInit;
        outgoing.flags &= ~messages.WorkerInit.flag_egress;
    } else {
        if (!shared_fds.wakeFds().isValid())
            return error.InvalidEgressSharedEndpoint;
        switch (shared_fds.regionCount()) {
            0 => if (has_boot_token) return error.InvalidWorkerInit,
            egress_shared.region_fd_count => if (!has_boot_token) return error.InvalidWorkerInit,
            else => return error.InvalidEgressSharedEndpoint,
        }
        outgoing.flags |= messages.WorkerInit.flag_egress;
    }
    const table = WorkerInitTable.of(&outgoing);

    var table_fds: [worker_init_fd_count_max]std.posix.fd_t = undefined;
    for (std.enums.values(WorkerInitPart)) |part| {
        const first = table.first.get(part) orelse continue;
        switch (part) {
            // The checks above paired the regions with the boot token the
            // table reads, so the half is whole.
            .egress_regions => {
                const half_fds = shared_fds.asArray();
                @memcpy(
                    table_fds[first..][0..egress_shared.region_fd_count],
                    half_fds[0..egress_shared.region_fd_count],
                );
            },
            // `flag_egress` was set above exactly because the wake
            // descriptors are whole.
            .egress_wake => {
                const wake_fds = shared_fds.wakeFds().asArray();
                @memcpy(table_fds[first..][0..wake_fds.len], &wake_fds);
            },
            else => {
                const part_fd = fds.single(part);
                if (part_fd < 0)
                    return error.InvalidWorkerInit;
                table_fds[first] = part_fd;
            },
        }
    }

    try packet.sendWithFds(fd, std.mem.asBytes(&outgoing), table_fds[0..table.count]);
}

/// Receives WorkerInit on the child's init socket; every descriptor moves
/// into the result. The table must be the one the message announces (see
/// the file header): a short one names its first missing part, so a boot
/// token without the session's regions, or `flag_egress` without the wake
/// descriptors, fails with `error.MissingEgressSharedFd` and a table that
/// ends before the artifact with `error.MissingModulePackFd`; a longer one,
/// the regions without a token or the wake descriptors without `flag_egress`,
/// fails with `error.InvalidFdCount`. A packet shorter than the struct fails
/// with `error.ShortRead` and a longer one with `error.TruncatedMessage`. The
/// fields are not checked here: the caller runs `WorkerInit.validate`, which
/// refuses a boot token without `flag_egress`.
pub fn recvWorkerInit(fd: std.posix.fd_t) !WorkerInitWithFds {
    var scratch: [@sizeOf(messages.WorkerInit)]u8 = undefined;
    var received = try packet.recvPacketWithFdsScratch(std.heap.smp_allocator, fd, &scratch);
    defer received.deinit();
    if (received.bytes.len != @sizeOf(messages.WorkerInit))
        return error.ShortRead;
    const message = packet.readStruct(messages.WorkerInit, received.bytes);
    if (try messages.decodeMessageKind(message.kind) != .worker_init)
        return error.InvalidMessageKind;
    const table = WorkerInitTable.of(&message);
    try table.checkFdCount(received.fd_count);

    // Nothing below fails, so every descriptor moves into the result.
    return .{
        .message = message,
        .metrics_fd = takeReceived(&received, table.at(.state_page)),
        .completion_eventfd = takeReceived(&received, table.at(.completion_eventfd)),
        .ingress_payload_fd = takeReceived(&received, table.at(.payload_memfd)),
        .ingress_payload_credit_eventfd = takeReceived(&received, table.at(.payload_credit_eventfd)),
        .cgroup_dir_fd = takeReceived(&received, table.at(.leaf)),
        .module_pack_fd = takeReceived(&received, table.at(.artifact)),
        .egress_shared_fds = takeEgressFds(&received, &table),
    };
}

fn takeReceived(received: *packet.ReceivedPacket, index: usize) std.posix.fd_t {
    var owned = received.takeFd(index);
    return owned.release();
}

/// Moves the worker's egress descriptors out of `received`: the regions and
/// the wake descriptors, each when `table` has them and in
/// `egress_shared.RawFds.asArray` order. The caller owns the result.
fn takeEgressFds(received: *packet.ReceivedPacket, table: *const WorkerInitTable) egress_shared.RawFds {
    var taken: [egress_shared.shared_fd_count]std.posix.fd_t = @splat(-1);
    if (table.first.get(.egress_regions)) |first| {
        for (taken[0..egress_shared.region_fd_count], first..) |*slot, index|
            slot.* = takeReceived(received, index);
    }
    if (table.first.get(.egress_wake)) |first| {
        for (taken[egress_shared.region_fd_count..], first..) |*slot, index|
            slot.* = takeReceived(received, index);
    }
    return egress_shared.RawFds.fromArray(taken);
}

pub fn sendWorkerReady(fd: std.posix.fd_t) !void {
    const message = messages.WorkerReady.init();
    try packet.sendExact(fd, std.mem.asBytes(&message));
}

pub fn recvWorkerReady(fd: std.posix.fd_t) !messages.WorkerReady {
    var message: messages.WorkerReady = undefined;
    try packet.recvPacketExact(fd, std.mem.asBytes(&message));
    if (try messages.decodeMessageKind(message.kind) != .worker_ready)
        return error.InvalidMessageKind;
    return message;
}

pub fn sendWorkerInitFailed(fd: std.posix.fd_t, reason: messages.WorkerInitFailedReason) !void {
    const message = messages.WorkerInitFailed.init(reason);
    try packet.sendExact(fd, std.mem.asBytes(&message));
}

pub fn recvWorkerInitFailed(fd: std.posix.fd_t) !messages.WorkerInitFailed {
    var message: messages.WorkerInitFailed = undefined;
    try packet.recvPacketExact(fd, std.mem.asBytes(&message));
    if (try messages.decodeMessageKind(message.kind) != .worker_init_failed)
        return error.InvalidMessageKind;
    _ = try messages.decodeWorkerInitFailedReason(message.reason);
    return message;
}

/// Receives the child's answer to WorkerInit: WorkerReady, or
/// WorkerInitFailed with a known reason. Fails with `error.PeerClosed` once
/// the child closed its end, whether the receive finds the end of stream or
/// a reset, with the other errors of `packet.recvPacket`, `error.ShortRead`
/// for a packet shorter than a kind, `error.InvalidMessageKind` for any other
/// kind or length, and `error.InvalidWorkerInitFailedReason` for an unknown
/// reason.
pub fn recvInitOutcome(fd: std.posix.fd_t) !messages.InitOutcome {
    var bytes: [@max(@sizeOf(messages.WorkerReady), @sizeOf(messages.WorkerInitFailed))]u8 = undefined;
    const received = try packet.recvPacket(fd, &bytes);
    if (received == 0)
        return error.PeerClosed;
    if (received < @sizeOf(u32))
        return error.ShortRead;
    const kind_raw = packet.readStruct(u32, bytes[0..@sizeOf(u32)]);
    const kind = try messages.decodeMessageKind(kind_raw);
    if (received == @sizeOf(messages.WorkerReady) and kind == .worker_ready)
        return .ready;
    if (received == @sizeOf(messages.WorkerInitFailed) and kind == .worker_init_failed) {
        const message = packet.readStruct(messages.WorkerInitFailed, bytes[0..@sizeOf(messages.WorkerInitFailed)]);
        return .{ .failed = try messages.decodeWorkerInitFailedReason(message.reason) };
    }
    return error.InvalidMessageKind;
}
