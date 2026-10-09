//! The control protocol between the server and the egress gateway, over the one SEQPACKET
//! socket each gateway inherits (`launch.zig`): the gateway's ready report, the server's hello
//! with the token key and the network policy table, worker attaches with their session's ring
//! memfds, eventfds and liveness descriptors (`egress_shared.RawFds`) and their acks, the batched
//! `request_ended` notices, the gateway's report of each session it removed on its own, and
//! shutdown. On the server, the thread that spawns the gateway reads the ready report and sends
//! the hello (`server/gateway/process.zig`), the control client's reader thread reads the acks and
//! the removal reports, and the lanes and the launcher send `request_ended`; on the gateway, the
//! main loop thread owns the socket.
//!
//! Both processes compile this file, and the gateway is the server's own binary run under
//! another arg0, so a packet that does not decode is corruption rather than version skew:
//! every decoder accepts only exact lengths and known kinds and rejects the rest. The fixed
//! structs have their sizes and offsets pinned below. The worker-facing fetch protocol is
//! `common/ipc/egress.zig`, and the token is `common/ipc/egress_token.zig`.

const std = @import("std");
const ipc = @import("collo_ipc");
const policy = @import("policy.zig");

const egress_token = ipc.egress_token;

pub const magic: u32 = 0x43454231; // "CEB1" little-endian.

pub const Kind = enum(u32) {
    attach_worker = 1,
    shutdown = 2,
    attach_worker_ack = 5,
    gateway_ready = 7,
    /// From the server, once and first after `gateway_ready` (`HelloHeader`).
    hello = 9,
    /// From the server, one way and best effort (`RequestEndedHeader`).
    request_ended = 10,
    /// From the gateway, one way (`SessionRemoved`).
    session_removed = 11,
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

/// A worker session the gateway removed while it keeps running: the worker closed its end of the
/// liveness pipe the gateway watches, or the gateway dropped the session for what the worker sent
/// or left unread (`removeWorker` in `runtime/worker_flow.zig`). Nothing else tells the server that
/// the worker lost its session, and a worker without one refuses every fetch until the server
/// attaches it again, so the gateway reports each such removal once. A session whose attach ack
/// never left is not reported, since the server never learned its id.
pub const SessionRemoved = extern struct {
    session_id: u64,
};

/// The hello's fixed part: the key the gateway verifies egress tokens with and the number of
/// `PolicyEntry` records that follow it and end the packet. The server sends one hello per
/// gateway, right after it reads `gateway_ready`, with a key drawn for that gateway alone, so a
/// token minted for an earlier gateway fails here. The gateway accepts no other packet before it
/// and refuses a second one.
pub const HelloHeader = extern struct {
    key: egress_token.Key,
    policy_count: u32,
    _reserved0: u32 = 0,
};

/// One network policy as the hello carries it. Entries come in id order from 0, so `id` restates
/// the entry's index and the decoder refuses any other value. The flags are 0 or 1.
pub const PolicyEntry = extern struct {
    id: u16,
    kind: u8,
    allow_private_networks: u8,
    allow_http: u8,
    _reserved0: [3]u8 = @splat(0),
};

/// `PolicyEntry.kind` of `policy.PolicyKind.any_host`.
pub const policy_kind_any_host: u8 = 1;

/// The largest hello, a table of `policy.policies_max` entries.
pub const hello_bytes_max: usize =
    @sizeOf(Header) + @sizeOf(HelloHeader) + policy.policies_max * @sizeOf(PolicyEntry);

/// A decoded hello, which owns its copy of the key and the table.
pub const Hello = struct {
    key: egress_token.Key,
    table: policy.PolicyTable,
};

/// The fixed part of a `request_ended` packet: `count` entries follow it and end the packet.
pub const RequestEndedHeader = extern struct {
    count: u32,
    _reserved0: u32 = 0,
};

/// A request whose running fetches the gateway cancels and whose budget it drops, named as its
/// token names it. A boot token's entry has request id and generation 0.
pub const RequestEndedEntry = extern struct {
    session_id: u64,
    request_id: u64,
    request_generation: u64,
};

/// Entries one packet carries at most. A lane appends one for each request it finishes that
/// carried a token and sends them once per loop pass, sooner when the batch fills; a pass rarely
/// finishes this many. A full packet is 24 KiB and a few bytes, far below the default AF_UNIX
/// send buffer, so no batch fails for its size.
pub const request_ended_entries_max: usize = 1024;

pub const request_ended_bytes_max: usize = request_ended_entries_offset +
    request_ended_entries_max * @sizeOf(RequestEndedEntry);

const request_ended_entries_offset: usize = @sizeOf(Header) + @sizeOf(RequestEndedHeader);

/// A decoded `request_ended` packet. It borrows the packet's bytes, so the gateway handles every
/// entry before it releases the packet.
pub const RequestEnded = struct {
    entries: []const u8,
    count: usize,

    pub fn entry(self: RequestEnded, index: usize) RequestEndedEntry {
        std.debug.assert(index < self.count);
        return ipc.packet.readStruct(
            RequestEndedEntry,
            self.entries[index * @sizeOf(RequestEndedEntry) ..][0..@sizeOf(RequestEndedEntry)],
        );
    }
};

/// The entries one sending thread collects between sends, kept as the packet they go out as.
/// Each lane owns one; nothing else touches it.
pub const RequestEndedBatch = struct {
    packet: [request_ended_bytes_max]u8 align(8) = undefined,
    count: usize = 0,

    /// Appends `entry` and returns true, or returns false when the batch is full and must be
    /// sent first.
    pub fn append(self: *RequestEndedBatch, entry: RequestEndedEntry) bool {
        if (self.count < request_ended_entries_max) {
            const offset = request_ended_entries_offset + self.count * @sizeOf(RequestEndedEntry);
            _ = ipc.packet.writeStruct(self.packet[offset..], &entry);
            self.count += 1;
            return true;
        }
        return false;
    }

    pub fn isEmpty(self: *const RequestEndedBatch) bool {
        return self.count == 0;
    }

    /// Sends the batch as one packet on the control socket `fd`, which is nonblocking, and
    /// empties it whether the send worked or not. A batch the socket refuses is lost, which costs
    /// the fetches of its requests until their tokens' deadlines and nothing else, so the caller
    /// only counts the error.
    pub fn sendAndClear(self: *RequestEndedBatch, fd: std.posix.fd_t) !void {
        std.debug.assert(self.count > 0);
        defer self.count = 0;
        const header = Header{
            .magic = magic,
            .kind = @intFromEnum(Kind.request_ended),
        };
        const fixed = RequestEndedHeader{ .count = @intCast(self.count) };
        var cursor = ipc.packet.writeStruct(&self.packet, &header);
        cursor += ipc.packet.writeStruct(self.packet[cursor..], &fixed);
        std.debug.assert(cursor == request_ended_entries_offset);
        const len = request_ended_entries_offset + self.count * @sizeOf(RequestEndedEntry);
        try ipc.packet.sendWithFds(fd, self.packet[0..len], &.{});
    }

    /// Drops what the batch holds without sending it, for entries of a gateway that is gone.
    pub fn clear(self: *RequestEndedBatch) void {
        self.count = 0;
    }
};

comptime {
    // Every fixed struct crosses the socket as raw bytes, and the decoders compute exact lengths
    // from these sizes, so a layout change is an explicit edit here.
    std.debug.assert(@sizeOf(Header) == 8);
    std.debug.assert(@sizeOf(AttachAck) == 24);
    std.debug.assert(@sizeOf(HelloHeader) == 40);
    std.debug.assert(@offsetOf(HelloHeader, "key") == 0);
    std.debug.assert(@offsetOf(HelloHeader, "policy_count") == 32);
    std.debug.assert(@offsetOf(HelloHeader, "_reserved0") == 36);
    std.debug.assert(@sizeOf(PolicyEntry) == 8);
    std.debug.assert(@offsetOf(PolicyEntry, "id") == 0);
    std.debug.assert(@offsetOf(PolicyEntry, "kind") == 2);
    std.debug.assert(@offsetOf(PolicyEntry, "allow_private_networks") == 3);
    std.debug.assert(@offsetOf(PolicyEntry, "allow_http") == 4);
    std.debug.assert(@offsetOf(PolicyEntry, "_reserved0") == 5);
    std.debug.assert(@sizeOf(SessionRemoved) == 8);
    std.debug.assert(@sizeOf(RequestEndedHeader) == 8);
    std.debug.assert(@sizeOf(RequestEndedEntry) == 24);
    std.debug.assert(@offsetOf(RequestEndedEntry, "request_id") == 8);
    std.debug.assert(@offsetOf(RequestEndedEntry, "request_generation") == 16);
    std.debug.assert(hello_bytes_max <= ipc.max_message_bytes);
    std.debug.assert(request_ended_bytes_max <= ipc.max_message_bytes);
}

/// A packet the gateway decoded (`decode`).
pub const Message = union(enum) {
    hello: Hello,
    attach_worker: AttachWorker,
    request_ended: RequestEnded,
    shutdown,
};

/// A packet the server's control reader decoded (`decodeGatewayToServerPacket`).
pub const GatewayToServer = union(enum) {
    attach_ack: AttachAck,
    session_removed: SessionRemoved,
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

/// Sends the report that the gateway removed session `session_id`, which is never 0.
pub fn sendSessionRemoved(fd: std.posix.fd_t, session_id: u64) !void {
    if (session_id == 0)
        return error.InvalidEgressGatewayControl;
    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.session_removed),
    };
    const body = SessionRemoved{ .session_id = session_id };
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
        .request_ended,
        => error.InvalidEgressGatewayControl,
    };
}

fn decodeSessionRemoved(bytes: []const u8) !SessionRemoved {
    if (bytes.len != @sizeOf(Header) + @sizeOf(SessionRemoved))
        return error.InvalidEgressGatewayControl;
    const body = ipc.packet.readStruct(SessionRemoved, bytes[@sizeOf(Header)..][0..@sizeOf(SessionRemoved)]);
    if (body.session_id == 0)
        return error.InvalidEgressGatewayControl;
    return body;
}

/// Sends the hello for a gateway that has just reported ready: `key`, which must not be the
/// zero key, and every entry of `table`, which holds at least one.
pub fn sendHello(
    fd: std.posix.fd_t,
    key: *const egress_token.Key,
    table: *const policy.PolicyTable,
) !void {
    std.debug.assert(!key.isZero());
    std.debug.assert(table.count >= 1);
    const header = Header{
        .magic = magic,
        .kind = @intFromEnum(Kind.hello),
    };
    var fixed = HelloHeader{
        .key = key.*,
        .policy_count = table.count,
    };
    // Both copies of the key on this stack are scrubbed, so a later frame that sends what it
    // never wrote cannot carry them.
    defer std.crypto.secureZero(u8, &fixed.key.bytes);
    var buffer: [hello_bytes_max]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var cursor = ipc.packet.writeStruct(&buffer, &header);
    cursor += ipc.packet.writeStruct(buffer[cursor..], &fixed);
    for (table.slice(), 0..) |entry, index| {
        const wire = PolicyEntry{
            .id = @intCast(index),
            .kind = encodePolicyKind(entry.kind),
            .allow_private_networks = @intFromBool(entry.allow_private_networks),
            .allow_http = @intFromBool(entry.allow_http),
        };
        cursor += ipc.packet.writeStruct(buffer[cursor..], &wire);
    }
    try ipc.packet.sendWithFds(fd, buffer[0..cursor], &.{});
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
        .request_ended => return .{ .request_ended = try decodeRequestEnded(packet) },
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

/// Checks a hello completely: a nonzero key, between one and `policy.policies_max` entries in
/// id order, known kinds, flags of 0 or 1 and zero reserved bytes.
fn decodeHello(packet: *const ipc.ReceivedPacket) !Hello {
    const fixed_len = @sizeOf(Header) + @sizeOf(HelloHeader);
    if (packet.fd_count != 0 or packet.bytes.len < fixed_len)
        return error.InvalidEgressGatewayControl;
    const fixed_bytes = packet.bytes[@sizeOf(Header)..][0..@sizeOf(HelloHeader)];
    const fixed = ipc.packet.readStruct(HelloHeader, fixed_bytes);
    if (fixed._reserved0 != 0 or fixed.key.isZero())
        return error.InvalidEgressGatewayControl;
    const count: usize = fixed.policy_count;
    if (count == 0 or count > policy.policies_max)
        return error.InvalidEgressGatewayControl;
    if (packet.bytes.len != fixed_len + count * @sizeOf(PolicyEntry))
        return error.InvalidEgressGatewayControl;
    var hello = Hello{
        .key = fixed.key,
        .table = .{ .count = @intCast(count) },
    };
    for (hello.table.entries[0..count], 0..) |*out, index| {
        const offset = fixed_len + index * @sizeOf(PolicyEntry);
        const wire_bytes = packet.bytes[offset..][0..@sizeOf(PolicyEntry)];
        const wire = ipc.packet.readStruct(PolicyEntry, wire_bytes);
        out.* = try decodePolicyEntry(wire, index);
    }
    return hello;
}

fn decodePolicyEntry(wire: PolicyEntry, index: usize) !policy.NetworkPolicy {
    if (wire.id != index)
        return error.InvalidEgressGatewayControl;
    if (!std.mem.allEqual(u8, &wire._reserved0, 0))
        return error.InvalidEgressGatewayControl;
    return .{
        .kind = try decodePolicyKind(wire.kind),
        .allow_private_networks = try decodeFlag(wire.allow_private_networks),
        .allow_http = try decodeFlag(wire.allow_http),
    };
}

fn decodePolicyKind(raw: u8) !policy.PolicyKind {
    return switch (raw) {
        policy_kind_any_host => .any_host,
        else => error.InvalidEgressGatewayControl,
    };
}

fn encodePolicyKind(kind: policy.PolicyKind) u8 {
    return switch (kind) {
        .any_host => policy_kind_any_host,
    };
}

fn decodeFlag(raw: u8) !bool {
    return switch (raw) {
        0 => false,
        1 => true,
        else => error.InvalidEgressGatewayControl,
    };
}

/// Checks a `request_ended` packet completely: between one and `request_ended_entries_max`
/// entries, each with a nonzero session and request ids that are both zero, for a boot token, or
/// both nonzero.
fn decodeRequestEnded(packet: *const ipc.ReceivedPacket) !RequestEnded {
    if (packet.fd_count != 0 or packet.bytes.len < request_ended_entries_offset)
        return error.InvalidEgressGatewayControl;
    const fixed_bytes = packet.bytes[@sizeOf(Header)..][0..@sizeOf(RequestEndedHeader)];
    const fixed = ipc.packet.readStruct(RequestEndedHeader, fixed_bytes);
    if (fixed._reserved0 != 0)
        return error.InvalidEgressGatewayControl;
    const count: usize = fixed.count;
    if (count == 0 or count > request_ended_entries_max)
        return error.InvalidEgressGatewayControl;
    if (packet.bytes.len != request_ended_entries_offset + count * @sizeOf(RequestEndedEntry))
        return error.InvalidEgressGatewayControl;
    const ended = RequestEnded{
        .entries = packet.bytes[request_ended_entries_offset..],
        .count = count,
    };
    for (0..count) |index| {
        const entry = ended.entry(index);
        if (entry.session_id == 0)
            return error.InvalidEgressGatewayControl;
        if ((entry.request_id == 0) != (entry.request_generation == 0))
            return error.InvalidEgressGatewayControl;
    }
    return ended;
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
