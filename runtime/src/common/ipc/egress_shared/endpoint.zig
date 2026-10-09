//! Each side's mapping of its half of a session (`Endpoint`). The worker maps
//! its half on its event loop thread, and the gateway maps its half on its
//! loop thread when the server attaches the worker. Mapping a region checks
//! each of its descriptors for the access the side may have
//! (`EndpointSide.access`), for its size seals and for its size, and checks
//! the meta's magic, version, role and capacity, so a descriptor with the
//! wrong access or from another region fails the map. Taking a half
//! closes the region descriptors once they are mapped and moves the eventfds
//! and liveness ends into the endpoint; the gateway's body pool also keeps
//! its data memfd for `punchFreeRange`.

const std = @import("std");
const fd_mod = @import("collo_os").fd;

const RingMeta = @import("region.zig").RingMeta;
const Role = @import("region.zig").Role;
const magic = @import("region.zig").magic;
const version = @import("region.zig").version;
const RingAccess = @import("packet_ring.zig").RingAccess;
const RingConsumerState = @import("packet_ring.zig").RingConsumerState;
const RingProducerState = @import("packet_ring.zig").RingProducerState;
const RingView = @import("packet_ring.zig").RingView;
const command_ring_capacity = @import("packet_ring.zig").command_ring_capacity;
const completion_ring_capacity = @import("packet_ring.zig").completion_ring_capacity;
const BodyPoolAccess = @import("body_pool.zig").BodyPoolAccess;
const BodyPoolConsumerState = @import("body_pool.zig").BodyPoolConsumerState;
const BodyPoolProducerState = @import("body_pool.zig").BodyPoolProducerState;
const BodyPoolView = @import("body_pool.zig").BodyPoolView;
const body_pool_capacity = @import("body_pool.zig").body_pool_capacity;
const RawFds = @import("session_fds.zig").RawFds;

/// One side's mapped session. It owns the mappings and the eventfd and
/// liveness descriptors, and `deinit` releases all of them.
pub const Endpoint = struct {
    command: RingView,
    completion: RingView,
    body_pool: BodyPoolView,
    upload_pool: BodyPoolView,
    command_eventfd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    liveness_fd: std.posix.fd_t,
    peer_liveness_fd: std.posix.fd_t,

    pub fn deinit(self: *Endpoint) void {
        self.command.deinit();
        self.completion.deinit();
        self.body_pool.deinit();
        self.upload_pool.deinit();
        if (self.command_eventfd >= 0)
            std.posix.close(self.command_eventfd);
        if (self.completion_eventfd >= 0)
            std.posix.close(self.completion_eventfd);
        if (self.liveness_fd >= 0)
            std.posix.close(self.liveness_fd);
        if (self.peer_liveness_fd >= 0)
            std.posix.close(self.peer_liveness_fd);
        self.* = undefined;
    }

    /// Checks that the four metas name one session: none stamped yet, or all
    /// with the same nonzero session id and the same generation. Fails with
    /// `error.InvalidEgressSharedEndpoint` otherwise.
    pub fn validateConsistentSession(self: *const Endpoint) !void {
        const command_session = self.command.workerSessionId();
        const completion_session = self.completion.workerSessionId();
        const body_session = self.body_pool.workerSessionId();
        const upload_session = self.upload_pool.workerSessionId();
        if (command_session == 0 and completion_session == 0 and
            body_session == 0 and upload_session == 0)
            return;
        if (command_session == 0 or completion_session == 0 or
            body_session == 0 or upload_session == 0)
            return error.InvalidEgressSharedEndpoint;
        if (command_session != completion_session or
            command_session != body_session or
            command_session != upload_session)
            return error.InvalidEgressSharedEndpoint;

        const command_generation = self.command.generation();
        const completion_generation = self.completion.generation();
        const body_generation = self.body_pool.generation();
        const upload_generation = self.upload_pool.generation();
        if (command_generation != completion_generation or
            command_generation != body_generation or
            command_generation != upload_generation)
            return error.InvalidEgressSharedEndpoint;
    }
};

/// Maps the worker's half and takes `fds`: the region descriptors are closed
/// once mapped, the eventfds and liveness ends move into the endpoint, and
/// `fds` is left empty. A missing descriptor fails with
/// `error.InvalidEgressSharedEndpoint`; a wrong access mode, missing seals,
/// a wrong size or a meta that disagrees fail the map too. On failure `fds`
/// keeps every descriptor.
pub fn mapEndpointTakeForWorker(fds: *RawFds) !Endpoint {
    return mapEndpointTakeWithAccess(fds, .worker);
}

/// As `mapEndpointTakeForWorker` for the gateway's half, whose body pool
/// view also keeps the data memfd for `punchFreeRange`.
pub fn mapEndpointTakeForGateway(fds: *RawFds) !Endpoint {
    return mapEndpointTakeWithAccess(fds, .gateway);
}

fn mapEndpointWithAccess(fds: RawFds, side: EndpointSide) !Endpoint {
    if (!fds.isValid())
        return error.InvalidEgressSharedEndpoint;
    const access = side.access();
    var command = try mapRingReadWrite(fds.command_control_fd, fds.command_producer_fd, fds.command_consumer_fd, fds.command_data_fd, .command, command_ring_capacity, access.command);
    errdefer command.deinit();
    var completion = try mapRingReadWrite(fds.completion_control_fd, fds.completion_producer_fd, fds.completion_consumer_fd, fds.completion_data_fd, .completion, completion_ring_capacity, access.completion);
    errdefer completion.deinit();
    var body_pool = try mapBodyPoolReadWrite(fds.body_pool_control_fd, fds.body_pool_producer_fd, fds.body_pool_consumer_fd, fds.body_pool_data_fd, .body_pool, access.body_pool);
    errdefer body_pool.deinit();
    var upload_pool = try mapBodyPoolReadWrite(fds.upload_pool_control_fd, fds.upload_pool_producer_fd, fds.upload_pool_consumer_fd, fds.upload_pool_data_fd, .upload_pool, access.upload_pool);
    errdefer upload_pool.deinit();
    return .{
        .command = command,
        .completion = completion,
        .body_pool = body_pool,
        .upload_pool = upload_pool,
        .command_eventfd = fds.command_eventfd,
        .completion_eventfd = fds.completion_eventfd,
        .liveness_fd = fds.liveness_fd,
        .peer_liveness_fd = fds.peer_liveness_fd,
    };
}

fn mapEndpointTakeWithAccess(fds: *RawFds, side: EndpointSide) !Endpoint {
    var endpoint = try mapEndpointWithAccess(fds.*, side);
    // The gateway's body pool keeps the received data descriptor itself for
    // `punchFreeRange`, because the gateway's seccomp filter denies
    // fcntl(F_DUPFD) and fcntl(F_DUPFD_CLOEXEC). The upload pool keeps none:
    // its draining side is the worker, whose seccomp filter does not allow
    // fallocate.
    if (side == .gateway) {
        endpoint.body_pool.data_fd = fds.body_pool_data_fd;
        fds.body_pool_data_fd = -1;
    }
    std.posix.close(fds.command_control_fd);
    std.posix.close(fds.command_producer_fd);
    std.posix.close(fds.command_consumer_fd);
    std.posix.close(fds.command_data_fd);
    std.posix.close(fds.completion_control_fd);
    std.posix.close(fds.completion_producer_fd);
    std.posix.close(fds.completion_consumer_fd);
    std.posix.close(fds.completion_data_fd);
    std.posix.close(fds.body_pool_control_fd);
    std.posix.close(fds.body_pool_producer_fd);
    std.posix.close(fds.body_pool_consumer_fd);
    if (fds.body_pool_data_fd >= 0)
        std.posix.close(fds.body_pool_data_fd);
    std.posix.close(fds.upload_pool_control_fd);
    std.posix.close(fds.upload_pool_producer_fd);
    std.posix.close(fds.upload_pool_consumer_fd);
    std.posix.close(fds.upload_pool_data_fd);
    fds.command_control_fd = -1;
    fds.command_producer_fd = -1;
    fds.command_consumer_fd = -1;
    fds.command_data_fd = -1;
    fds.completion_control_fd = -1;
    fds.completion_producer_fd = -1;
    fds.completion_consumer_fd = -1;
    fds.completion_data_fd = -1;
    fds.body_pool_control_fd = -1;
    fds.body_pool_producer_fd = -1;
    fds.body_pool_consumer_fd = -1;
    fds.body_pool_data_fd = -1;
    fds.upload_pool_control_fd = -1;
    fds.upload_pool_producer_fd = -1;
    fds.upload_pool_consumer_fd = -1;
    fds.upload_pool_data_fd = -1;
    fds.command_eventfd = -1;
    fds.completion_eventfd = -1;
    fds.liveness_fd = -1;
    fds.peer_liveness_fd = -1;
    return endpoint;
}

fn mapRingReadWrite(
    control_fd: std.posix.fd_t,
    producer_fd: std.posix.fd_t,
    consumer_fd: std.posix.fd_t,
    data_fd: std.posix.fd_t,
    role: Role,
    expected_capacity: usize,
    access: RingAccess,
) !RingView {
    const meta_bytes = try mapRingMeta(control_fd, role, expected_capacity, access.write_session);
    errdefer std.posix.munmap(meta_bytes);
    const producer_bytes = try mapRingProducer(producer_fd, access.write_packets);
    errdefer std.posix.munmap(producer_bytes);
    const consumer_bytes = try mapRingConsumer(consumer_fd, access.read_packets);
    errdefer std.posix.munmap(consumer_bytes);
    const data_bytes = try mapData(data_fd, expected_capacity, dataProtForRing(access));
    errdefer std.posix.munmap(data_bytes);
    return .{
        .meta_bytes = meta_bytes,
        .producer_bytes = producer_bytes,
        .consumer_bytes = consumer_bytes,
        .data_bytes = data_bytes,
        .meta = @ptrCast(@alignCast(meta_bytes.ptr)),
        .producer = @ptrCast(@alignCast(producer_bytes.ptr)),
        .consumer = @ptrCast(@alignCast(consumer_bytes.ptr)),
        .capacity_bytes = expected_capacity,
        .access = access,
    };
}

fn mapBodyPoolReadWrite(
    control_fd: std.posix.fd_t,
    producer_fd: std.posix.fd_t,
    consumer_fd: std.posix.fd_t,
    data_fd: std.posix.fd_t,
    role: Role,
    access: BodyPoolAccess,
) !BodyPoolView {
    const meta_bytes = try mapRingMeta(control_fd, role, body_pool_capacity, access.write_session);
    errdefer std.posix.munmap(meta_bytes);
    const producer_bytes = try mapBodyPoolProducer(producer_fd, access.write_chunks);
    errdefer std.posix.munmap(producer_bytes);
    const consumer_bytes = try mapBodyPoolConsumer(
        consumer_fd,
        access.release_chunks or access.drain_releases,
    );
    errdefer std.posix.munmap(consumer_bytes);
    const data_bytes = try mapData(data_fd, body_pool_capacity, dataProtForBodyPool(access));
    errdefer std.posix.munmap(data_bytes);
    // `data_fd` stays -1 here; `mapEndpointTakeWithAccess` gives the gateway's
    // body pool its descriptor.
    return .{
        .meta_bytes = meta_bytes,
        .producer_bytes = producer_bytes,
        .consumer_bytes = consumer_bytes,
        .data_bytes = data_bytes,
        .meta = @ptrCast(@alignCast(meta_bytes.ptr)),
        .producer = @ptrCast(@alignCast(producer_bytes.ptr)),
        .consumer = @ptrCast(@alignCast(consumer_bytes.ptr)),
        .capacity_bytes = body_pool_capacity,
        .access = access,
        .data_fd = -1,
    };
}

fn mapRingMeta(fd: std.posix.fd_t, role: Role, expected_capacity: usize, writable: bool) ![]align(std.heap.page_size_min) u8 {
    try requireFdAccess(fd, writable);
    try fd_mod.requireSeals(fd, fd_mod.memfd_size_seals);
    const stat = try std.posix.fstat(fd);
    if (@as(usize, @intCast(stat.size)) != @sizeOf(RingMeta))
        return error.InvalidEgressSharedRing;
    const bytes = try std.posix.mmap(
        null,
        @sizeOf(RingMeta),
        if (writable) std.posix.PROT.READ | std.posix.PROT.WRITE else std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(bytes);
    const meta: *RingMeta = @ptrCast(@alignCast(bytes.ptr));
    try validateRingMeta(meta, role, expected_capacity);
    return bytes;
}

fn mapRingProducer(fd: std.posix.fd_t, writable: bool) ![]align(std.heap.page_size_min) u8 {
    return mapStateMemfd(RingProducerState, fd, writable);
}

fn mapRingConsumer(fd: std.posix.fd_t, writable: bool) ![]align(std.heap.page_size_min) u8 {
    return mapStateMemfd(RingConsumerState, fd, writable);
}

fn mapBodyPoolProducer(fd: std.posix.fd_t, writable: bool) ![]align(std.heap.page_size_min) u8 {
    return mapStateMemfd(BodyPoolProducerState, fd, writable);
}

fn mapBodyPoolConsumer(fd: std.posix.fd_t, writable: bool) ![]align(std.heap.page_size_min) u8 {
    return mapStateMemfd(BodyPoolConsumerState, fd, writable);
}

fn mapStateMemfd(comptime T: type, fd: std.posix.fd_t, writable: bool) ![]align(std.heap.page_size_min) u8 {
    try requireFdAccess(fd, writable);
    try fd_mod.requireSeals(fd, fd_mod.memfd_size_seals);
    const stat = try std.posix.fstat(fd);
    if (@as(usize, @intCast(stat.size)) != @sizeOf(T))
        return error.InvalidEgressSharedRing;
    return try std.posix.mmap(
        null,
        @sizeOf(T),
        if (writable) std.posix.PROT.READ | std.posix.PROT.WRITE else std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
}

fn mapData(fd: std.posix.fd_t, expected_capacity: usize, prot: u32) ![]align(std.heap.page_size_min) u8 {
    try requireFdAccess(fd, (prot & std.posix.PROT.WRITE) != 0);
    try fd_mod.requireSeals(fd, fd_mod.memfd_size_seals);
    const stat = try std.posix.fstat(fd);
    if (@as(usize, @intCast(stat.size)) != expected_capacity)
        return error.InvalidEgressSharedRing;
    return try std.posix.mmap(
        null,
        expected_capacity,
        prot,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
}

fn validateRingMeta(meta: *const RingMeta, role: Role, expected_capacity: usize) !void {
    if (meta.magic != magic or
        meta.version != version or
        meta.role != @intFromEnum(role) or
        meta.capacity != expected_capacity)
    {
        return error.InvalidEgressSharedRing;
    }
}

/// A writable mapping needs a descriptor open for writing, and a read-only
/// mapping must come from a read-only descriptor, so a side handed write
/// access to state it should only read fails the map with
/// `error.InvalidEgressSharedFdAccess`.
fn requireFdAccess(fd: std.posix.fd_t, writable: bool) !void {
    const flags: usize = @intCast(try std.posix.fcntl(fd, std.posix.F.GETFL, 0));
    const accmode = flags & 0x3;
    const rdonly: usize = 0;
    if (writable) {
        if (accmode == rdonly)
            return error.InvalidEgressSharedFdAccess;
    } else if (accmode != rdonly) {
        return error.InvalidEgressSharedFdAccess;
    }
}

fn dataProtForRing(access: RingAccess) u32 {
    var prot: u32 = 0;
    if (access.read_packets)
        prot |= std.posix.PROT.READ;
    if (access.write_packets)
        prot |= std.posix.PROT.WRITE;
    return if (prot == 0) std.posix.PROT.READ else prot;
}

fn dataProtForBodyPool(access: BodyPoolAccess) u32 {
    var prot: u32 = 0;
    if (access.read_chunks)
        prot |= std.posix.PROT.READ;
    if (access.write_chunks)
        prot |= std.posix.PROT.WRITE;
    return if (prot == 0) std.posix.PROT.READ else prot;
}

const EndpointAccess = struct {
    command: RingAccess,
    completion: RingAccess,
    body_pool: BodyPoolAccess,
    upload_pool: BodyPoolAccess,
};

const EndpointSide = enum {
    worker,
    gateway,

    /// What each side may do per region. It must agree with the access modes
    /// `SessionFds.rawForWorker` and `SessionFds.rawForGateway` hand out, since
    /// `requireFdAccess` checks every descriptor against it.
    fn access(self: EndpointSide) EndpointAccess {
        return switch (self) {
            .worker => .{
                .command = .{ .write_packets = true },
                .completion = .{ .read_packets = true },
                .body_pool = .{ .read_chunks = true, .release_chunks = true },
                .upload_pool = .{ .write_chunks = true, .drain_releases = true },
            },
            .gateway => .{
                .command = .{ .read_packets = true, .write_session = true },
                .completion = .{ .write_packets = true, .write_session = true },
                .body_pool = .{ .write_chunks = true, .drain_releases = true, .write_session = true },
                .upload_pool = .{ .read_chunks = true, .release_chunks = true, .write_session = true },
            },
        };
    }
};
