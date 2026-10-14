//! The control protocol between the server and the egress gateway, over the one SEQPACKET
//! socket each gateway inherits (`launch.zig`): the gateway's ready report, the server's hello
//! with the token key and the network policy image, worker attaches with their session's ring
//! memfds, eventfds and liveness descriptors (`egress_shared.RawFds`) and their acks, the end of a
//! session's boot token, the gateway's report of each session it removed on its own and why, and
//! shutdown. On the server, the thread that spawns the gateway reads the ready report and sends
//! the hello (`server/gateway/process.zig`), the control client's reader thread reads the acks and
//! the removal reports, and the supervisor's metrics pass sends `boot_ended`; on the gateway, the
//! main loop thread owns the socket.
//!
//! Both processes compile this file, and the gateway is the server's own binary run under
//! another arg0, so a packet that does not decode is corruption rather than version skew:
//! every decoder accepts only exact lengths and known kinds and rejects the rest. The fixed
//! structs have their sizes and offsets pinned below. The worker-facing fetch protocol is
//! `common/ipc/egress.zig`, and the token is `common/ipc/egress_token.zig`.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const network = @import("collo_egress_client").network;

const egress_token = ipc.egress_token;

pub const magic: u32 = 0x43454231; // "CEB1" little-endian.

pub const Kind = enum(u32) {
    /// From the gateway, once, as its last boot step.
    gateway_ready = 1,
    /// From the server, once and first after `gateway_ready` (`HelloHeader`).
    hello = 2,
    attach_worker = 3,
    attach_worker_ack = 4,
    /// From the server, one way (`BootEnded`).
    boot_ended = 5,
    /// From the gateway, one way (`SessionRemoved`).
    session_removed = 6,
    shutdown = 7,
};

pub const Header = extern struct {
    magic: u32,
    kind: u32,
};

/// The isolation owner of a worker session's egress: pools, TLS sessions
/// and the per-cell fetch cap never cross it. The server derives it from the
/// worker definition (`securityCellIdForDefinition` in
/// `server/gateway/manager.zig`).
pub const SecurityCellId = [16]u8;

/// A worker session to attach. `request_id` pairs the attach with its `AttachAck`, and the
/// receiver owns `fds` once `decode` returns.
pub const AttachWorker = struct {
    request_id: u64,
    security_cell_id: SecurityCellId,
    fds: ipc.egress_shared.RawFds,
};

/// An attach packet: the header, the request id and the security cell; the
/// session's shared fds ride SCM_RIGHTS.
pub const attach_worker_message_bytes: usize = @sizeOf(Header) + @sizeOf(u64) + @sizeOf(SecurityCellId);

pub const AttachAckStatus = enum(u32) {
    ok = 0,
    rejected = 1,
};

pub const AttachAck = extern struct {
    status: u32,
    _reserved0: u32 = 0,
    request_id: u64 = 0,
    worker_session_id: u64 = 0,
};

/// A worker session the gateway removed while it keeps running, and why (`SessionRemovedCause`,
/// validated on decode). Nothing else tells the server that the worker lost its session. The
/// gateway reports each such removal once (`removeSession` in `runtime/session_flow.zig`). A
/// session whose attach ack never left is not reported, since the server never learned its id.
pub const SessionRemoved = extern struct {
    session_id: u64,
    cause: u32,
    _reserved0: u32 = 0,
};

/// Why the gateway removed a session. The liveness pipe cannot tell an exit from a detach, so the
/// server leaves `liveness_closed` to the worker's own channels; only `protocol_violation` blames
/// the worker for the removal (`Launcher.egressSessionLost` in `server/supervisor/launcher.zig`).
pub const SessionRemovedCause = enum(u32) {
    /// The worker closed its end of the liveness pipe the gateway watches: it exited, or it
    /// detached on its own after a packet only a gateway defect produces.
    liveness_closed = 1,
    /// The gateway removed the session for what the worker sent or left unread: a command ring
    /// that failed its checks, a command that does not decode, an extent the pools reject, or a
    /// completion ring left at the hard mark (`runtime/session_flow.zig`).
    protocol_violation = 2,
};

/// The end of a session's boot token: from this packet on, the gateway admits no fetch under the
/// session's boot token although its deadline has not passed. The server sends it once the
/// worker's startup evaluations closed (`Manager.endBoot` in `server/gateway/manager.zig`). It only
/// shortens what the token admits, so a lost or repeated packet costs nothing but fetches the
/// token's deadline already bounds.
pub const BootEnded = extern struct {
    session_id: u64,
};

/// The hello's fixed part: the key the gateway verifies egress tokens with and the length of the
/// policy image whose sealed memfd is the packet's one descriptor. The server sends one hello
/// per gateway, right after it reads `gateway_ready`, with a key drawn for that gateway alone, so
/// a token minted for an earlier gateway fails here. The gateway accepts no other packet before
/// it and refuses a second one. The image travels as a memfd sealed against writes and resizes,
/// so its size never depends on the socket's send buffer and the gateway reads the bytes the
/// server wrote.
pub const HelloHeader = extern struct {
    key: egress_token.Key,
    table_bytes: u32,
    _reserved0: u32 = 0,
};

/// The length of every hello.
pub const hello_bytes: usize = @sizeOf(Header) + @sizeOf(HelloHeader);

/// A decoded hello. It owns its copy of the key and the image's descriptor, which the gateway
/// checks, reads and closes (`runtime/control_flow.zig`).
pub const Hello = struct {
    key: egress_token.Key,
    table_fd: fd_mod.OwnedFd,
    table_bytes: u32,
};

comptime {
    // Every fixed struct crosses the socket as raw bytes, and the decoders compute exact lengths
    // from these sizes, so a layout change is an explicit edit here.
    std.debug.assert(@sizeOf(Header) == 8);
    std.debug.assert(@sizeOf(AttachAck) == 24);
    std.debug.assert(@sizeOf(HelloHeader) == 40);
    std.debug.assert(@offsetOf(HelloHeader, "key") == 0);
    std.debug.assert(@offsetOf(HelloHeader, "table_bytes") == 32);
    std.debug.assert(@offsetOf(HelloHeader, "_reserved0") == 36);
    // The hello holds the image's length in a u32.
    std.debug.assert(network.table.image_bytes_max <= std.math.maxInt(u32));
    std.debug.assert(@sizeOf(SessionRemoved) == 16);
    std.debug.assert(@offsetOf(SessionRemoved, "session_id") == 0);
    std.debug.assert(@offsetOf(SessionRemoved, "cause") == 8);
    std.debug.assert(@offsetOf(SessionRemoved, "_reserved0") == 12);
    std.debug.assert(@sizeOf(BootEnded) == 8);
    std.debug.assert(hello_bytes <= ipc.max_message_bytes);
}

/// A packet the gateway decoded (`decode`).
pub const Message = union(enum) {
    hello: Hello,
    attach_worker: AttachWorker,
    boot_ended: BootEnded,
    shutdown,
};

/// A packet the server's control reader decoded (`decodeGatewayToServerPacket`).
pub const GatewayToServer = union(enum) {
    attach_ack: AttachAck,
    session_removed: RemovedSession,
};

/// A decoded `SessionRemoved`: a nonzero session id and a cause the enum names.
pub const RemovedSession = struct {
    session_id: u64,
    cause: SessionRemovedCause,
};

pub fn sendAttachWorker(
    fd: std.posix.fd_t,
    request_id: u64,
    security_cell_id: SecurityCellId,
    shared_fds: ipc.egress_shared.RawFds,
) !void {
    if (request_id == 0)
        return error.InvalidEgressGatewayControl;
    if (!shared_fds.isValid())
        return error.InvalidEgressSharedEndpoint;

    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.attach_worker),
    };
    var buffer: [attach_worker_message_bytes]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(Header)], std.mem.asBytes(&header));
    std.mem.writeInt(u64, buffer[@sizeOf(Header)..][0..@sizeOf(u64)], request_id, .little);
    @memcpy(buffer[@sizeOf(Header) + @sizeOf(u64) ..][0..@sizeOf(SecurityCellId)], &security_cell_id);
    const fds = shared_fds.asArray();
    try ipc.packet.sendWithFds(fd, &buffer, &fds);
}

pub fn sendAttachAck(
    fd: std.posix.fd_t,
    status: AttachAckStatus,
    request_id: u64,
    worker_session_id: u64,
) !void {
    if (request_id == 0)
        return error.InvalidEgressGatewayControl;
    try validateAttachAckFields(status, request_id, worker_session_id);
    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.attach_worker_ack),
    };
    const body = AttachAck{
        .status = @intFromEnum(status),
        .request_id = request_id,
        .worker_session_id = worker_session_id,
    };
    var buffer: [@sizeOf(Header) + @sizeOf(AttachAck)]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(Header)], std.mem.asBytes(&header));
    @memcpy(buffer[@sizeOf(Header)..], std.mem.asBytes(&body));
    try ipc.packet.sendWithFds(fd, &buffer, &.{});
}

pub fn decodeAttachAck(bytes: []const u8) !AttachAck {
    if (bytes.len != @sizeOf(Header) + @sizeOf(AttachAck))
        return error.InvalidEgressGatewayControl;
    const header = ipc.packet.readStruct(Header, bytes[0..@sizeOf(Header)]);
    if (header.magic != magic or header.kind != @intFromEnum(Kind.attach_worker_ack))
        return error.InvalidEgressGatewayControl;
    const body = ipc.packet.readStruct(AttachAck, bytes[@sizeOf(Header)..][0..@sizeOf(AttachAck)]);
    const status = std.meta.intToEnum(AttachAckStatus, body.status) catch
        return error.InvalidEgressGatewayControl;
    if (body._reserved0 != 0 or body.request_id == 0)
        return error.InvalidEgressGatewayControl;
    try validateAttachAckFields(status, body.request_id, body.worker_session_id);
    return body;
}

/// Sends the report that the gateway removed session `session_id`, which is never 0, for `cause`.
pub fn sendSessionRemoved(fd: std.posix.fd_t, session_id: u64, cause: SessionRemovedCause) !void {
    if (session_id == 0)
        return error.InvalidEgressGatewayControl;
    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.session_removed),
    };
    const body = SessionRemoved{ .session_id = session_id, .cause = @intFromEnum(cause) };
    var buffer: [@sizeOf(Header) + @sizeOf(SessionRemoved)]u8 = undefined;
    var cursor = ipc.packet.writeStruct(&buffer, &header);
    cursor += ipc.packet.writeStruct(buffer[cursor..], &body);
    try ipc.packet.sendWithFds(fd, buffer[0..cursor], &.{});
}

/// Decodes a packet the server's control reader received after the ready report. The gateway
/// sends nothing then but attach acks and removal reports, so anything else, a packet with
/// descriptors among them, fails with `error.InvalidEgressGatewayControl`, and one shorter than a
/// header with `error.ShortRead`.
pub fn decodeGatewayToServerPacket(packet: *ipc.ReceivedPacket) !GatewayToServer {
    if (packet.fd_count != 0)
        return error.InvalidEgressGatewayControl;
    if (packet.bytes.len < @sizeOf(Header))
        return error.ShortRead;
    const header = ipc.packet.readStruct(Header, packet.bytes[0..@sizeOf(Header)]);
    if (header.magic != magic)
        return error.InvalidEgressGatewayControl;
    const kind = std.meta.intToEnum(Kind, header.kind) catch return error.InvalidEgressGatewayControl;
    return switch (kind) {
        .attach_worker_ack => .{ .attach_ack = try decodeAttachAck(packet.bytes) },
        .session_removed => .{ .session_removed = try decodeSessionRemoved(packet.bytes) },
        .attach_worker,
        .shutdown,
        .gateway_ready,
        .hello,
        .boot_ended,
        => error.InvalidEgressGatewayControl,
    };
}

fn decodeSessionRemoved(bytes: []const u8) !RemovedSession {
    if (bytes.len != @sizeOf(Header) + @sizeOf(SessionRemoved))
        return error.InvalidEgressGatewayControl;
    const body = ipc.packet.readStruct(SessionRemoved, bytes[@sizeOf(Header)..][0..@sizeOf(SessionRemoved)]);
    if (body.session_id == 0 or body._reserved0 != 0)
        return error.InvalidEgressGatewayControl;
    const cause = std.enums.fromInt(SessionRemovedCause, body.cause) orelse
        return error.InvalidEgressGatewayControl;
    return .{ .session_id = body.session_id, .cause = cause };
}

/// Sends the end of session `session_id`'s boot token, which is never 0, on the nonblocking control
/// socket `fd`. Fails with `error.WouldBlock` when the socket is full; the caller tries again later.
pub fn sendBootEnded(fd: std.posix.fd_t, session_id: u64) !void {
    if (session_id == 0)
        return error.InvalidEgressGatewayControl;
    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.boot_ended),
    };
    const body = BootEnded{ .session_id = session_id };
    var buffer: [@sizeOf(Header) + @sizeOf(BootEnded)]u8 = undefined;
    var cursor = ipc.packet.writeStruct(&buffer, &header);
    cursor += ipc.packet.writeStruct(buffer[cursor..], &body);
    try ipc.packet.sendWithFds(fd, buffer[0..cursor], &.{});
}

fn decodeBootEnded(packet: *const ipc.ReceivedPacket) !BootEnded {
    if (packet.fd_count != 0 or packet.bytes.len != @sizeOf(Header) + @sizeOf(BootEnded))
        return error.InvalidEgressGatewayControl;
    const body = ipc.packet.readStruct(BootEnded, packet.bytes[@sizeOf(Header)..][0..@sizeOf(BootEnded)]);
    if (body.session_id == 0)
        return error.InvalidEgressGatewayControl;
    return body;
}

/// Sends the hello for a gateway that has just reported ready: `key`, which must not be the
/// zero key, and the policy image in `table_fd`, borrowed for the call: a memfd that carries
/// `memfd_readonly_seals` and holds exactly `table_bytes` bytes, 1 to
/// `network.table.image_bytes_max`. The server builds the image once at boot and lends it to
/// each hello; the packet carries the descriptor.
pub fn sendHello(
    fd: std.posix.fd_t,
    key: *const egress_token.Key,
    table_fd: std.posix.fd_t,
    table_bytes: u32,
) !void {
    std.debug.assert(!key.isZero());
    std.debug.assert(table_fd >= 0);
    std.debug.assert(table_bytes >= 1);
    std.debug.assert(table_bytes <= network.table.image_bytes_max);
    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.hello),
    };
    var fixed = HelloHeader{
        .key = key.*,
        .table_bytes = table_bytes,
    };
    // Both copies of the key on this stack are scrubbed, so a later frame that sends what it
    // never wrote cannot carry them.
    defer std.crypto.secureZero(u8, &fixed.key.bytes);
    var buffer: [hello_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var cursor = ipc.packet.writeStruct(&buffer, &header);
    cursor += ipc.packet.writeStruct(buffer[cursor..], &fixed);
    std.debug.assert(cursor == hello_bytes);
    try ipc.packet.sendWithFds(fd, &buffer, &.{table_fd});
}

pub fn sendShutdown(fd: std.posix.fd_t) !void {
    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.shutdown),
    };
    try ipc.packet.sendWithFds(fd, std.mem.asBytes(&header), &.{});
}

/// The gateway sends this once, after its sandbox, shard threads, readiness
/// ring and seccomp filter are all in place (`runtime/root.zig`). The socket
/// keeps packets in order and the server reads this one in
/// `server/gateway/process.zig` before its control reader thread exists, so
/// `decodeGatewayToServerPacket` never sees it.
pub fn sendGatewayReady(fd: std.posix.fd_t) !void {
    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.gateway_ready),
    };
    try ipc.packet.sendWithFds(fd, std.mem.asBytes(&header), &.{});
}

pub fn decodeGatewayReady(bytes: []const u8) !void {
    if (bytes.len != @sizeOf(Header))
        return error.InvalidEgressGatewayControl;
    const header = ipc.packet.readStruct(Header, bytes[0..@sizeOf(Header)]);
    if (header.magic != magic or header.kind != @intFromEnum(Kind.gateway_ready))
        return error.InvalidEgressGatewayControl;
}

/// Decodes a packet the gateway received from the server. An attach takes the packet's
/// descriptors, which the caller owns afterwards; every other kind must carry none. Fails with
/// `error.ShortRead` for a packet shorter than a header and `error.InvalidEgressGatewayControl`
/// for anything malformed or a kind only the gateway sends. The order the gateway takes the kinds
/// in, the hello first and once, is enforced by `handleControl` in `runtime/control_flow.zig`.
pub fn decode(packet: *ipc.ReceivedPacket) !Message {
    if (packet.bytes.len < @sizeOf(Header))
        return error.ShortRead;
    const header = ipc.packet.readStruct(Header, packet.bytes[0..@sizeOf(Header)]);
    if (header.magic != magic)
        return error.InvalidEgressGatewayControl;
    const kind = std.meta.intToEnum(Kind, header.kind) catch return error.InvalidEgressGatewayControl;

    switch (kind) {
        .hello => return .{ .hello = try decodeHello(packet) },
        .boot_ended => return .{ .boot_ended = try decodeBootEnded(packet) },
        .attach_worker => {
            if (packet.bytes.len != attach_worker_message_bytes)
                return error.InvalidEgressGatewayControl;
            if (packet.fd_count != ipc.egress_shared.shared_fd_count)
                return error.InvalidEgressGatewayControl;
            const request_id = std.mem.readInt(u64, packet.bytes[@sizeOf(Header)..][0..@sizeOf(u64)], .little);
            if (request_id == 0)
                return error.InvalidEgressGatewayControl;
            const security_cell_id = packet.bytes[@sizeOf(Header) + @sizeOf(u64) ..][0..@sizeOf(SecurityCellId)].*;
            var command_control_fd = packet.takeFd(0);
            var command_producer_fd = packet.takeFd(1);
            var command_consumer_fd = packet.takeFd(2);
            var command_data_fd = packet.takeFd(3);
            var completion_control_fd = packet.takeFd(4);
            var completion_producer_fd = packet.takeFd(5);
            var completion_consumer_fd = packet.takeFd(6);
            var completion_data_fd = packet.takeFd(7);
            var body_pool_control_fd = packet.takeFd(8);
            var body_pool_producer_fd = packet.takeFd(9);
            var body_pool_consumer_fd = packet.takeFd(10);
            var body_pool_data_fd = packet.takeFd(11);
            var upload_pool_control_fd = packet.takeFd(12);
            var upload_pool_producer_fd = packet.takeFd(13);
            var upload_pool_consumer_fd = packet.takeFd(14);
            var upload_pool_data_fd = packet.takeFd(15);
            var command_eventfd = packet.takeFd(16);
            var completion_eventfd = packet.takeFd(17);
            var liveness_fd = packet.takeFd(18);
            var peer_liveness_fd = packet.takeFd(19);
            return .{ .attach_worker = .{
                .request_id = request_id,
                .security_cell_id = security_cell_id,
                .fds = .{
                    .command_control_fd = command_control_fd.release(),
                    .command_producer_fd = command_producer_fd.release(),
                    .command_consumer_fd = command_consumer_fd.release(),
                    .command_data_fd = command_data_fd.release(),
                    .completion_control_fd = completion_control_fd.release(),
                    .completion_producer_fd = completion_producer_fd.release(),
                    .completion_consumer_fd = completion_consumer_fd.release(),
                    .completion_data_fd = completion_data_fd.release(),
                    .body_pool_control_fd = body_pool_control_fd.release(),
                    .body_pool_producer_fd = body_pool_producer_fd.release(),
                    .body_pool_consumer_fd = body_pool_consumer_fd.release(),
                    .body_pool_data_fd = body_pool_data_fd.release(),
                    .upload_pool_control_fd = upload_pool_control_fd.release(),
                    .upload_pool_producer_fd = upload_pool_producer_fd.release(),
                    .upload_pool_consumer_fd = upload_pool_consumer_fd.release(),
                    .upload_pool_data_fd = upload_pool_data_fd.release(),
                    .command_eventfd = command_eventfd.release(),
                    .completion_eventfd = completion_eventfd.release(),
                    .liveness_fd = liveness_fd.release(),
                    .peer_liveness_fd = peer_liveness_fd.release(),
                },
            } };
        },
        .shutdown => {
            if (packet.fd_count != 0 or packet.bytes.len != @sizeOf(Header))
                return error.InvalidEgressGatewayControl;
            return .shutdown;
        },
        .attach_worker_ack, .gateway_ready, .session_removed => return error.InvalidEgressGatewayControl,
    }
}

/// Checks a hello's packet completely: the exact length, one descriptor, a nonzero key, zero
/// reserved bytes and an image length of 1 to `network.table.image_bytes_max`, then takes the
/// descriptor. Whether the descriptor is the sealed image it claims to be is the gateway's check
/// when it reads it (`runtime/control_flow.zig`).
fn decodeHello(packet: *ipc.ReceivedPacket) !Hello {
    if (packet.fd_count != 1 or packet.bytes.len != hello_bytes)
        return error.InvalidEgressGatewayControl;
    const fixed_bytes = packet.bytes[@sizeOf(Header)..][0..@sizeOf(HelloHeader)];
    const fixed = ipc.packet.readStruct(HelloHeader, fixed_bytes);
    if (fixed._reserved0 != 0 or fixed.key.isZero())
        return error.InvalidEgressGatewayControl;
    if (fixed.table_bytes == 0 or fixed.table_bytes > network.table.image_bytes_max)
        return error.InvalidEgressGatewayControl;
    return .{
        .key = fixed.key,
        .table_fd = packet.takeFd(0),
        .table_bytes = fixed.table_bytes,
    };
}

fn validateAttachAckFields(
    status: AttachAckStatus,
    request_id: u64,
    worker_session_id: u64,
) !void {
    if (request_id == 0)
        return error.InvalidEgressGatewayControl;
    switch (status) {
        .ok => {
            if (worker_session_id == 0)
                return error.InvalidEgressGatewayControl;
        },
        .rejected => {
            if (worker_session_id != 0)
                return error.InvalidEgressGatewayControl;
        },
    }
}
