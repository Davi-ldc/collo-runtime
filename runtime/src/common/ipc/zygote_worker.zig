//! The zygote and worker handshakes as socket operations: ZygoteReady, the
//! fork request and reply, WorkerInit with its descriptor table, and the init
//! outcome. The host sends fork requests to the
//! zygote's fork loop and WorkerInit to the child on its init socket, which
//! becomes the worker's control socket once the child reports ready.
//!
//! The fixed-size payloads live in `messages.zig`; this file sends and
//! receives them. A `*WithFds` result type exists only where a receive hands
//! back owned descriptors from SCM_RIGHTS next to the payload. No send or
//! receive here allocates, which the zygote's fork loop requires
//! (`zygote/fork_loop.zig`).
//!
//! WorkerInit's descriptor table, in order: the base descriptors (metrics
//! page, completion eventfd, ingress payload memfd, payload credit eventfd,
//! tmp root, cgroup directory, bindings blob), the region descriptors of the
//! worker's egress session (`egress_shared.region_fd_count`), present exactly
//! when `WorkerInit.boot_egress_token` is not `egress_token.none`, the
//! worker's wake descriptors (`egress_shared.wake_fd_count`), which every
//! table has, the fs index memfd and the worker end of the fs fault pair, and
//! last the route's module pack, present exactly when
//! `WorkerInit.route_entry_specifier_len` is nonzero. With a session, the
//! regions and the wake descriptors together are the worker's half in
//! `egress_shared.RawFds.asArray` order. The message alone decides the table,
//! so the sender refuses a boot token without the regions and the regions
//! without a token, and the receiver rejects any count but the one the
//! message announces; when the table is short it names the first missing
//! descriptor, or the egress descriptors as a whole.

const std = @import("std");
const packet = @import("packet.zig");
const messages = @import("messages.zig");
const egress_shared = @import("egress_shared.zig");
const egress_token = @import("egress_token.zig");
const fs_index = @import("fs_index.zig");
const route_bindings = @import("route_bindings.zig");
const fd_mod = @import("collo_os").fd;

const worker_init_base_fd_count: usize = 7;
/// The sealed fs index memfd, always present (a tree with no files sends
/// `fs_index.placeholder_bytes`), and the worker end of the fs fault
/// SEQPACKET pair.
const worker_init_fs_fd_count: usize = 2;
/// The route's module pack, after the fs pair.
const worker_init_route_entry_fd_count: usize = 1;
const worker_init_fd_count_max: usize = worker_init_base_fd_count + egress_shared.shared_fd_count +
    worker_init_fs_fd_count + worker_init_route_entry_fd_count;

comptime {
    std.debug.assert(worker_init_fd_count_max <= messages.max_fds_per_message);
}

/// Where each part of WorkerInit's descriptor table sits for one message,
/// which announces the two optional parts: the session's regions by the boot
/// token, the route's pack by its specifier length.
const WorkerInitTable = struct {
    /// Index of the first region descriptor; null when the message carries
    /// no boot token.
    regions_first: ?usize,
    /// Index of the first wake descriptor, right after the regions.
    wake_first: usize,
    fs_index: usize,
    fs_fault: usize,
    /// Index of the route's pack; null when the message carries no route
    /// entry.
    route_entry: ?usize,
    /// Descriptors in the whole table.
    count: usize,

    fn of(message: *const messages.WorkerInit) WorkerInitTable {
        const has_regions = !egress_token.isNone(&message.boot_egress_token);
        const has_route_entry = message.route_entry_specifier_len != 0;
        const wake_first = worker_init_base_fd_count +
            @as(usize, if (has_regions) egress_shared.region_fd_count else 0);
        const fs_first = wake_first + egress_shared.wake_fd_count;
        const fs_end = fs_first + worker_init_fs_fd_count;
        return .{
            .regions_first = if (has_regions) worker_init_base_fd_count else null,
            .wake_first = wake_first,
            .fs_index = fs_first,
            .fs_fault = fs_first + 1,
            .route_entry = if (has_route_entry) fs_end else null,
            .count = fs_end + @as(usize, if (has_route_entry) worker_init_route_entry_fd_count else 0),
        };
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

/// A received WorkerInit and the descriptors it carried, each owned until a
/// `take*` call moves it out or `deinit` closes it.
pub const WorkerInitWithFds = struct {
    message: messages.WorkerInit,
    metrics_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    ingress_payload_fd: std.posix.fd_t,
    ingress_payload_credit_eventfd: std.posix.fd_t,
    tmp_root_fd: std.posix.fd_t,
    cgroup_dir_fd: std.posix.fd_t,
    /// Sealed read-only memfd holding the route's bindings blob
    /// (`route_bindings.zig`), `message.route_bindings_blob_len` bytes long.
    route_bindings_fd: std.posix.fd_t,
    /// Sealed read-only fs index memfd.
    fs_index_fd: std.posix.fd_t = -1,
    /// Worker end of the fs fault SEQPACKET pair.
    fs_fault_fd: std.posix.fd_t = -1,
    /// The route's sealed module pack; null when the packet carries no route
    /// entry (`message.route_entry_specifier_len` is zero).
    route_entry_fd: ?std.posix.fd_t = null,
    route_entry_specifier_buffer: [messages.WorkerInit.max_route_entry_specifier_bytes]u8 = undefined,
    /// The worker's egress descriptors: its wake descriptors always, and the
    /// regions of its session exactly when the message carries a boot token
    /// (`egress_shared.RawFds.regionCount`).
    egress_shared_fds: egress_shared.RawFds = .{},

    /// Empty when the packet carries no route entry.
    pub fn routeEntrySpecifier(self: *const WorkerInitWithFds) []const u8 {
        return self.route_entry_specifier_buffer[0..self.message.route_entry_specifier_len];
    }

    pub fn deinit(self: *WorkerInitWithFds) void {
        if (self.metrics_fd >= 0)
            std.posix.close(self.metrics_fd);
        if (self.completion_eventfd >= 0)
            std.posix.close(self.completion_eventfd);
        if (self.ingress_payload_fd >= 0)
            std.posix.close(self.ingress_payload_fd);
        if (self.ingress_payload_credit_eventfd >= 0)
            std.posix.close(self.ingress_payload_credit_eventfd);
        if (self.tmp_root_fd >= 0)
            std.posix.close(self.tmp_root_fd);
        if (self.cgroup_dir_fd >= 0)
            std.posix.close(self.cgroup_dir_fd);
        if (self.route_bindings_fd >= 0)
            std.posix.close(self.route_bindings_fd);
        if (self.fs_index_fd >= 0)
            std.posix.close(self.fs_index_fd);
        if (self.fs_fault_fd >= 0)
            std.posix.close(self.fs_fault_fd);
        if (self.route_entry_fd) |fd|
            std.posix.close(fd);
        self.egress_shared_fds.close();
        self.* = undefined;
    }

    pub fn takeRouteEntryFd(self: *WorkerInitWithFds) ?std.posix.fd_t {
        const fd = self.route_entry_fd;
        self.route_entry_fd = null;
        return fd;
    }

    pub fn takeFsIndexFd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.fs_index_fd;
        self.fs_index_fd = -1;
        return fd;
    }

    pub fn takeFsFaultFd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.fs_fault_fd;
        self.fs_fault_fd = -1;
        return fd;
    }

    pub fn takeMetricsFd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.metrics_fd;
        self.metrics_fd = -1;
        return fd;
    }

    pub fn takeCompletionEventfd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.completion_eventfd;
        self.completion_eventfd = -1;
        return fd;
    }

    pub fn takeIngressPayloadFd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.ingress_payload_fd;
        self.ingress_payload_fd = -1;
        return fd;
    }

    pub fn takeIngressPayloadCreditEventfd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.ingress_payload_credit_eventfd;
        self.ingress_payload_credit_eventfd = -1;
        return fd;
    }

    pub fn takeTmpRootFd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.tmp_root_fd;
        self.tmp_root_fd = -1;
        return fd;
    }

    pub fn takeCgroupDirFd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.cgroup_dir_fd;
        self.cgroup_dir_fd = -1;
        return fd;
    }

    pub fn takeRouteBindingsFd(self: *WorkerInitWithFds) std.posix.fd_t {
        const fd = self.route_bindings_fd;
        self.route_bindings_fd = -1;
        return fd;
    }

    pub fn takeEgressSharedFds(self: *WorkerInitWithFds) egress_shared.RawFds {
        const fds = self.egress_shared_fds;
        self.egress_shared_fds = .{};
        return fds;
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

pub fn sendForkRequest(fd: std.posix.fd_t, fork_job_id: u64, flags: u32) !void {
    const message = messages.ForkRequest.init(fork_job_id, flags);
    try packet.sendExact(fd, std.mem.asBytes(&message));
}

pub fn recvForkRequest(fd: std.posix.fd_t) !messages.ForkRequest {
    var message: messages.ForkRequest = undefined;
    try packet.recvPacketExact(fd, std.mem.asBytes(&message));
    if (try messages.decodeMessageKind(message.kind) != .fork_request)
        return error.InvalidMessageKind;
    if ((message.flags & ~messages.ForkRequest.Flags.valid_mask) != 0)
        return error.InvalidForkRequestFlags;
    return message;
}

pub const ForkRequestWithFd = struct {
    message: messages.ForkRequest,
    /// Owned pre-created worker cgroup directory fd; present exactly when
    /// `Flags.cgroup_fd` is set in `message.flags`.
    cgroup_dir_fd: ?std.posix.fd_t,

    pub fn deinit(self: *ForkRequestWithFd) void {
        if (self.cgroup_dir_fd) |fd|
            std.posix.close(fd);
        self.* = undefined;
    }

    pub fn takeCgroupDirFd(self: *ForkRequestWithFd) ?std.posix.fd_t {
        const fd = self.cgroup_dir_fd;
        self.cgroup_dir_fd = null;
        return fd;
    }
};

/// The codec owns `Flags.cgroup_fd`: it is set exactly when `cgroup_dir_fd`
/// travels as SCM_RIGHTS. The fd stays the caller's.
pub fn sendForkRequestWithCgroupFd(
    fd: std.posix.fd_t,
    fork_job_id: u64,
    cgroup_dir_fd: ?std.posix.fd_t,
) !void {
    if (cgroup_dir_fd) |dir_fd| {
        std.debug.assert(dir_fd >= 0);
        const message = messages.ForkRequest.init(fork_job_id, messages.ForkRequest.Flags.cgroup_fd);
        try packet.sendWithFds(fd, std.mem.asBytes(&message), &.{dir_fd});
        return;
    }
    try sendForkRequest(fd, fork_job_id, 0);
}

/// Receives a fork request with its cgroup directory fd, if any. Fails with
/// `error.InvalidFdCount` when the descriptors do not match
/// `Flags.cgroup_fd`, and with `error.InvalidForkRequestFlags` for an
/// unknown flag.
pub fn recvForkRequestWithFd(fd: std.posix.fd_t) !ForkRequestWithFd {
    var scratch: [@sizeOf(messages.ForkRequest)]u8 = undefined;
    var received = try packet.recvPacketWithFdsScratch(std.heap.smp_allocator, fd, &scratch);
    defer received.deinit();
    if (received.bytes.len != @sizeOf(messages.ForkRequest))
        return error.ShortRead;
    const message = packet.readStruct(messages.ForkRequest, received.bytes);
    if (try messages.decodeMessageKind(message.kind) != .fork_request)
        return error.InvalidMessageKind;
    if ((message.flags & ~messages.ForkRequest.Flags.valid_mask) != 0)
        return error.InvalidForkRequestFlags;
    const wants_cgroup_fd = (message.flags & messages.ForkRequest.Flags.cgroup_fd) != 0;
    const expected_fd_count: usize = if (wants_cgroup_fd) 1 else 0;
    if (received.fd_count != expected_fd_count)
        return error.InvalidFdCount;
    if (!wants_cgroup_fd) {
        return .{
            .message = message,
            .cgroup_dir_fd = null,
        };
    }
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
/// able to serve the next one: a cgroup directory fd that fails validation,
/// fd pressure before the clone, or a clone3 failure caused by this job's
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

/// Sends WorkerInit for a launch with no bindings, no files and no route
/// entry: it builds the empty bindings blob, the placeholder fs index and an
/// fs fault socketpair whose ends close once SCM_RIGHTS duplicated them. The
/// zygote integration tests launch this way; a host sends through
/// `sendWorkerInitWithRouteBindingsAndEgressShared`, whose rule for
/// `shared_fds` and failures this function shares.
pub fn sendWorkerInitWithEgressShared(
    fd: std.posix.fd_t,
    message: *const messages.WorkerInit,
    metrics_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    ingress_payload_fd: std.posix.fd_t,
    ingress_payload_credit_eventfd: std.posix.fd_t,
    tmp_root_fd: std.posix.fd_t,
    cgroup_dir_fd: std.posix.fd_t,
    shared_fds: egress_shared.RawFds,
) !void {
    const empty_bindings = try route_bindings.createEmptySealed();
    defer empty_bindings.close();
    const fs_index_fd = try createPlaceholderFsIndexMemfd();
    defer std.posix.close(fs_index_fd);
    const fs_fault_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(fs_fault_pair[0]);
    defer std.posix.close(fs_fault_pair[1]);
    var message_copy = message.*;
    message_copy.route_bindings_blob_len = empty_bindings.blob_len;
    try sendWorkerInitWithRouteBindingsAndEgressShared(
        fd,
        &message_copy,
        metrics_fd,
        completion_eventfd,
        ingress_payload_fd,
        ingress_payload_credit_eventfd,
        tmp_root_fd,
        cgroup_dir_fd,
        empty_bindings.fd,
        shared_fds,
        null,
        fs_index_fd,
        fs_fault_pair[1],
    );
}

/// The route's module pack, delivered at init: the child registers and
/// evaluates `specifier` before it reports ready. The fd is borrowed, since
/// SCM_RIGHTS duplicates it.
pub const RouteEntryInit = struct {
    fd: std.posix.fd_t,
    specifier: []const u8,
};

/// Sends WorkerInit with its descriptor table. Every fd is borrowed, since
/// SCM_RIGHTS duplicates them: `route_bindings_fd` is the sealed bindings
/// blob of `message.route_bindings_blob_len` bytes, `shared_fds` the worker's
/// egress descriptors, its wake descriptors always and the regions of its
/// session exactly when the message carries a boot token, `fs_index_fd` the
/// sealed fs index (a tree with no files still sends the placeholder index)
/// and `fs_fault_fd` the worker end of the fs fault socketpair. With
/// `route_entry`, the specifier follows the struct and the pack closes the
/// table; this function sets `route_entry_specifier_len` from it. Fails with
/// `error.InvalidEgressSharedEndpoint` for missing wake descriptors or some
/// regions without the rest, and `error.InvalidWorkerInit` for regions the
/// boot token does not announce, a boot token without them, a negative fs fd
/// or an empty, oversized or fd-less route entry.
pub fn sendWorkerInitWithRouteBindingsAndEgressShared(
    fd: std.posix.fd_t,
    message: *const messages.WorkerInit,
    metrics_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    ingress_payload_fd: std.posix.fd_t,
    ingress_payload_credit_eventfd: std.posix.fd_t,
    tmp_root_fd: std.posix.fd_t,
    cgroup_dir_fd: std.posix.fd_t,
    route_bindings_fd: std.posix.fd_t,
    shared_fds: egress_shared.RawFds,
    route_entry: ?RouteEntryInit,
    fs_index_fd: std.posix.fd_t,
    fs_fault_fd: std.posix.fd_t,
) !void {
    const has_boot_token = !egress_token.isNone(&message.boot_egress_token);
    if (!shared_fds.wakeFds().isValid())
        return error.InvalidEgressSharedEndpoint;
    switch (shared_fds.regionCount()) {
        0 => if (has_boot_token) return error.InvalidWorkerInit,
        egress_shared.region_fd_count => if (!has_boot_token) return error.InvalidWorkerInit,
        else => return error.InvalidEgressSharedEndpoint,
    }
    if (fs_index_fd < 0 or fs_fault_fd < 0)
        return error.InvalidWorkerInit;
    if (route_entry) |entry| {
        if (entry.specifier.len == 0 or
            entry.specifier.len > messages.WorkerInit.max_route_entry_specifier_bytes or
            entry.fd < 0)
            return error.InvalidWorkerInit;
    }

    var message_copy = message.*;
    message_copy.route_entry_specifier_len =
        if (route_entry) |entry| @intCast(entry.specifier.len) else 0;
    const table = WorkerInitTable.of(&message_copy);

    var fds: [worker_init_fd_count_max]std.posix.fd_t = undefined;
    fds[0] = metrics_fd;
    fds[1] = completion_eventfd;
    fds[2] = ingress_payload_fd;
    fds[3] = ingress_payload_credit_eventfd;
    fds[4] = tmp_root_fd;
    fds[5] = cgroup_dir_fd;
    fds[6] = route_bindings_fd;
    if (table.regions_first) |first| {
        // The checks above paired the regions with the boot token the table
        // reads, so the half is whole.
        const half_fds = shared_fds.asArray();
        @memcpy(fds[first..][0..egress_shared.region_fd_count], half_fds[0..egress_shared.region_fd_count]);
    }
    const wake_fds = shared_fds.wakeFds().asArray();
    @memcpy(fds[table.wake_first..][0..wake_fds.len], &wake_fds);
    fds[table.fs_index] = fs_index_fd;
    fds[table.fs_fault] = fs_fault_fd;
    if (route_entry) |entry|
        fds[table.route_entry.?] = entry.fd;

    var packet_buffer: [@sizeOf(messages.WorkerInit) + messages.WorkerInit.max_route_entry_specifier_bytes]u8 = undefined;
    @memcpy(packet_buffer[0..@sizeOf(messages.WorkerInit)], std.mem.asBytes(&message_copy));
    var packet_len: usize = @sizeOf(messages.WorkerInit);
    if (route_entry) |entry| {
        @memcpy(packet_buffer[packet_len..][0..entry.specifier.len], entry.specifier);
        packet_len += entry.specifier.len;
    }
    try packet.sendWithFds(
        fd,
        packet_buffer[0..packet_len],
        fds[0..table.count],
    );
}

/// `fs_index.placeholder_bytes`, the index of a tree with no files, sealed
/// into a fresh memfd the caller owns.
pub fn createPlaceholderFsIndexMemfd() !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        "collo-fs-index-empty",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);
    try fd_mod.writeAllRaw(fd, &fs_index.placeholder_bytes);
    try std.posix.lseek_SET(fd, 0);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    return fd;
}

/// Receives WorkerInit on the child's init socket; every descriptor and the
/// specifier move into the result. The table must be the one the message
/// announces (see the file header): a short one fails as
/// `checkWorkerInitFdCount` describes, so a boot token without the session's
/// regions, or a table without the wake descriptors, fails with
/// `error.MissingEgressSharedFd` and the regions without a token with
/// `error.InvalidFdCount`. A specifier length that disagrees with
/// the packet fails with `error.ShortRead` or `error.InvalidWorkerInit`. The
/// fields are not checked here: the caller runs `WorkerInit.validate`.
pub fn recvWorkerInit(fd: std.posix.fd_t) !WorkerInitWithFds {
    var scratch: [@sizeOf(messages.WorkerInit) + messages.WorkerInit.max_route_entry_specifier_bytes]u8 = undefined;
    var received = try packet.recvPacketWithFdsScratch(std.heap.smp_allocator, fd, &scratch);
    defer received.deinit();
    if (received.bytes.len < @sizeOf(messages.WorkerInit))
        return error.ShortRead;
    const message = packet.readStruct(messages.WorkerInit, received.bytes[0..@sizeOf(messages.WorkerInit)]);
    if (try messages.decodeMessageKind(message.kind) != .worker_init)
        return error.InvalidMessageKind;
    if (message.route_entry_specifier_len > messages.WorkerInit.max_route_entry_specifier_bytes)
        return error.InvalidWorkerInit;
    if (received.bytes.len != @sizeOf(messages.WorkerInit) + @as(usize, message.route_entry_specifier_len))
        return error.ShortRead;
    const table = WorkerInitTable.of(&message);
    try checkWorkerInitFdCount(received.fd_count, table);

    // Nothing below fails, so every descriptor moves into the result.
    var metrics_fd = received.takeFd(0);
    var completion_eventfd = received.takeFd(1);
    var ingress_payload_fd = received.takeFd(2);
    var ingress_payload_credit_eventfd = received.takeFd(3);
    var tmp_root_fd = received.takeFd(4);
    var cgroup_dir_fd = received.takeFd(5);
    var route_bindings_fd = received.takeFd(6);
    const egress_shared_fds = takeEgressFds(&received, table);
    var fs_index_fd = received.takeFd(table.fs_index);
    var fs_fault_fd = received.takeFd(table.fs_fault);
    var route_entry_fd: ?std.posix.fd_t = null;
    if (table.route_entry) |index| {
        var owned_route_entry_fd = received.takeFd(index);
        route_entry_fd = owned_route_entry_fd.release();
    }
    var result: WorkerInitWithFds = .{
        .message = message,
        .metrics_fd = metrics_fd.release(),
        .completion_eventfd = completion_eventfd.release(),
        .ingress_payload_fd = ingress_payload_fd.release(),
        .ingress_payload_credit_eventfd = ingress_payload_credit_eventfd.release(),
        .tmp_root_fd = tmp_root_fd.release(),
        .cgroup_dir_fd = cgroup_dir_fd.release(),
        .route_bindings_fd = route_bindings_fd.release(),
        .egress_shared_fds = egress_shared_fds,
        .fs_index_fd = fs_index_fd.release(),
        .fs_fault_fd = fs_fault_fd.release(),
        .route_entry_fd = route_entry_fd,
    };
    @memcpy(
        result.route_entry_specifier_buffer[0..message.route_entry_specifier_len],
        received.bytes[@sizeOf(messages.WorkerInit)..][0..message.route_entry_specifier_len],
    );
    return result;
}

/// Moves the worker's egress descriptors out of `received`: the regions when
/// `table` has them and the wake descriptors always, each group in
/// `egress_shared.RawFds.asArray` order. The caller owns the result.
fn takeEgressFds(received: *packet.ReceivedPacket, table: WorkerInitTable) egress_shared.RawFds {
    var taken: [egress_shared.shared_fd_count]std.posix.fd_t = @splat(-1);
    if (table.regions_first) |first| {
        for (taken[0..egress_shared.region_fd_count], first..) |*slot, index| {
            var owned = received.takeFd(index);
            slot.* = owned.release();
        }
    }
    for (taken[egress_shared.region_fd_count..], table.wake_first..) |*slot, index| {
        var owned = received.takeFd(index);
        slot.* = owned.release();
    }
    return egress_shared.RawFds.fromArray(taken);
}

/// A short table names its first missing descriptor, or the egress half as a
/// whole; a count that is neither short nor exact is `error.InvalidFdCount`.
fn checkWorkerInitFdCount(fd_count: usize, table: WorkerInitTable) !void {
    switch (fd_count) {
        0 => return error.MissingMetricsFd,
        1 => return error.MissingCompletionEventFd,
        2 => return error.MissingIngressPayloadFd,
        3 => return error.MissingIngressPayloadCreditFd,
        4 => return error.MissingTmpRootFd,
        5 => return error.MissingCgroupDirFd,
        6 => return error.MissingRouteBindingsFd,
        else => {},
    }
    if (fd_count < table.fs_index)
        return error.MissingEgressSharedFd;
    if (fd_count == table.fs_index)
        return error.MissingFsIndexFd;
    if (fd_count == table.fs_fault)
        return error.MissingFsFaultFd;
    if (table.route_entry) |route_entry| {
        if (fd_count == route_entry)
            return error.MissingRouteEntryFd;
    }
    if (fd_count != table.count)
        return error.InvalidFdCount;
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
