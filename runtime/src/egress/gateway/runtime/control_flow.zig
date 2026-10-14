//! The gateway's end of the control socket, on its loop thread: the server's hello, worker
//! attaches, the end of a session's boot token and shutdown, and what the gateway owes the server
//! in return, the attach acks and a report of each session it removed on its own. The wire format
//! is `control.zig`.
//!
//! The hello comes first and once. Until it arrives the gateway holds the zero key, which
//! verifies no egress token, and takes nothing but the hello and shutdown; any other packet, or a
//! second hello, is a protocol violation that ends the gateway, so the server sees its control
//! channel fail and replaces it. The hello's policy image must be a memfd sealed against writes
//! and resizes that holds exactly the length the hello names and decodes whole
//! (`readPolicyImage`); anything else is a server bug and ends the gateway too. The key and the
//! decoded table never change after the hello, and the gateway keeps them for its life.
//!
//! An attach the gateway cannot take, because it holds `Gateway.sessions_max` sessions or because
//! the session's memory does not map or register, is refused with a `rejected` ack and costs
//! nothing else; only a packet that does not decode ends the gateway.
//!
//! The socket is nonblocking. A packet that finds it full waits in a FIFO, and while any waits,
//! new ones queue behind it, so the server receives them in order. When sending or queueing an
//! ack fails, the gateway removes the session it attached, so no session is left that the server
//! was never told about. A removal report the gateway can neither send nor queue while the server
//! holds its end ends the gateway: the server would otherwise keep a worker it believes attached,
//! and the channel's failure has the server replace the gateway. A server that closed its end
//! needs no report, and its hang-up ends the loop. `boot_ended` is one way: it ends the session's
//! boot token, after which the token admits nothing, and fails every fetch the token admitted that
//! is still running or assembling its upload (`fetch_flow.endBootFetches`); an entry for a session
//! the gateway no longer has is skipped, and a repeated one changes nothing.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const network = @import("collo_egress_client").network;

const control = @import("../control.zig");
const control_queue = @import("../control_queue.zig");
const sizing = @import("../sizing.zig");
const fetch_flow = @import("fetch_flow.zig");
const Gateway = @import("root.zig").Gateway;
const session_flow = @import("session_flow.zig");

const egress_token = ipc.egress_token;

const control_drain_batch: usize = 64;
/// Packets the full socket can hold back at once. The server waits for each attach's ack before
/// it sends the next attach, and a held-back ack makes that wait time out and retire the gateway,
/// so at most one ack waits, beside one report for each session the gateway holds. Only a server
/// that stopped reading fills the queue.
const pending_control_packet_capacity: usize = sizing.sessions_max + 1;

pub const ControlAction = enum {
    idle,
    processed,
    shutdown,
};

/// What the server's hello gave this gateway: the key egress tokens verify under and the network
/// policies their `policy_id` names. Fetch admission reads it (`command_flow.zig`), the hello
/// writes it once, and the gateway frees it at its end. The shard threads read the decoded table
/// through the `network.Policy` values a fetch's configuration carries, which reach them through
/// an engine's submit queue after the hello.
pub const HelloState = struct {
    /// Set by the hello. Until then the gateway takes nothing but the hello and shutdown.
    received: bool = false,
    /// The zero key until the hello, which verifies no token (`egress_token.verify`).
    key: egress_token.Key = .{ .bytes = @splat(0) },
    /// The decoded policy image; null until the hello.
    table: ?network.Table = null,

    /// The policy a verified token's `policy_id` names, or null before the hello and for an id
    /// past the table, which only a server bug produces.
    pub fn lookup(self: *const HelloState, id: network.PolicyId) ?network.Policy {
        const table = self.table orelse return null;
        return table.policy(id);
    }

    pub fn policyCount(self: *const HelloState) usize {
        const table = self.table orelse return 0;
        return table.policies.len;
    }

    pub fn deinit(self: *HelloState, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, &self.key.bytes);
        if (self.table) |*table|
            table.deinit(gpa);
        self.* = undefined;
    }
};

/// An attach ack the gateway owes the server.
pub const AttachAck = struct {
    status: control.AttachAckStatus,
    request_id: u64,
    session_id: u64,
};

/// A packet the gateway owes the server, held while the socket has no room.
pub const PendingControlPacket = union(enum) {
    attach_ack: AttachAck,
    /// A session the gateway removed (`control.SessionRemoved`).
    session_removed: control.RemovedSession,
};

pub const PendingControlPackets = control_queue.Queue(
    PendingControlPacket,
    pending_control_packet_capacity,
);

/// Handles up to `control_drain_batch` control messages and returns true when the server asked
/// for shutdown or closed the socket. Fails, which ends the gateway, on a packet that does not
/// decode or breaks the hello's order.
pub fn drainControl(gateway: *Gateway) !bool {
    var drained: usize = 0;
    while (drained < control_drain_batch) : (drained += 1) {
        switch (try handleControl(gateway)) {
            .idle => return false,
            .processed => continue,
            .shutdown => return true,
        }
    }
    return false;
}

/// The events the loop polls the control socket for: always input, and output while control
/// packets wait to be sent.
pub fn controlEvents(gateway: *const Gateway) i16 {
    var events: i16 = std.posix.POLL.IN;
    if (!gateway.pending_control_packets.isEmpty())
        events |= std.posix.POLL.OUT;
    return events;
}

/// Tells the server that the gateway removed session `session_id` on its own, for `cause`. A
/// server that closed its end needs no report, and its hang-up ends the loop on the next pass.
/// Fails, which ends the gateway, when the report can be neither sent nor queued.
pub fn reportSessionRemoved(gateway: *Gateway, session_id: u64, cause: control.SessionRemovedCause) !void {
    const removed: control.RemovedSession = .{ .session_id = session_id, .cause = cause };
    sendOrQueueControlPacket(gateway, .{ .session_removed = removed }) catch |err| switch (err) {
        error.PeerClosed => return,
        else => return err,
    };
}

pub fn flushPendingControlPackets(gateway: *Gateway) !void {
    while (gateway.pending_control_packets.peek()) |packet| {
        sendControlPacket(gateway.control_fd, packet) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        gateway.pending_control_packets.pop();
    }
}

/// Receives and handles one control packet.
pub fn handleControl(gateway: *Gateway) !ControlAction {
    var received = ipc.recvPacketWithFdsScratch(gateway.allocator, gateway.control_fd, gateway.read_scratch) catch |err| switch (err) {
        error.WouldBlock => return .idle,
        error.PeerClosed => return .shutdown,
        else => return err,
    };
    defer received.deinit();

    var message = try control.decode(&received);
    switch (message) {
        .shutdown => return .shutdown,
        .hello => |*hello| {
            // The packet lies in the scratch the gateway also copies worker commands into, so it
            // keeps no copy of the key once `gateway.hello` holds one, whatever the hello's
            // outcome.
            defer std.crypto.secureZero(u8, received.bytes);
            defer std.crypto.secureZero(u8, &hello.key.bytes);
            defer hello.table_fd.deinit();
            if (gateway.hello.received)
                return error.EgressGatewayControlOutOfOrder;
            try takeHello(gateway, hello);
            return .processed;
        },
        .attach_worker => |attach| {
            var fds = attach.fds;
            if (!gateway.hello.received) {
                fds.close();
                return error.EgressGatewayControlOutOfOrder;
            }
            if (gateway.sessions.len() >= gateway.sessions_max) {
                fds.close();
                rejectAttach(gateway, attach.request_id, "at the session limit");
                return .processed;
            }
            var endpoint = ipc.egress_shared.mapEndpointTakeForGateway(&fds) catch |err| {
                // A session the gateway cannot map, for its memory or descriptors that are not
                // what they claim, fails its attach alone.
                fds.close();
                rejectAttach(gateway, attach.request_id, @errorName(err));
                return .processed;
            };
            const attached = session_flow.attachSession(gateway, &endpoint, attach.security_cell_id) catch |err| {
                endpoint.deinit();
                rejectAttach(gateway, attach.request_id, @errorName(err));
                return .processed;
            };
            sendOrQueueControlPacket(gateway, .{ .attach_ack = .{
                .status = .ok,
                .request_id = attach.request_id,
                .session_id = attached.session_id,
            } }) catch |err| {
                std.log.warn("egress gateway attach ack failed session={d}: {s}", .{
                    attached.session_id,
                    @errorName(err),
                });
                try session_flow.removeSession(gateway, attached.index, .attach_ack_failed);
            };
            return .processed;
        },
        .boot_ended => |ended| {
            if (!gateway.hello.received)
                return error.EgressGatewayControlOutOfOrder;
            if (gateway.sessions.byId(ended.session_id)) |session| {
                session.boot_ended = true;
                fetch_flow.endBootFetches(gateway, session);
            }
            return .processed;
        },
    }
}

fn sendOrQueueControlPacket(gateway: *Gateway, packet: PendingControlPacket) !void {
    if (!gateway.pending_control_packets.isEmpty())
        return gateway.pending_control_packets.push(packet);
    sendControlPacket(gateway.control_fd, packet) catch |err| switch (err) {
        error.WouldBlock => return gateway.pending_control_packets.push(packet),
        else => return err,
    };
}

/// Refuses an attach the gateway cannot take. The server learns of it from the ack; a nack that
/// cannot leave makes the server's wait for it time out and retire the gateway.
fn rejectAttach(gateway: *Gateway, request_id: u64, reason: []const u8) void {
    std.log.warn("egress gateway worker attach rejected: {s}", .{reason});
    sendOrQueueControlPacket(gateway, .{ .attach_ack = .{
        .status = .rejected,
        .request_id = request_id,
        .session_id = 0,
    } }) catch |err|
        std.log.warn("egress gateway attach nack failed: {s}", .{@errorName(err)});
}

/// Keeps the hello's key and decodes its policy image. Fails, which ends the gateway, on an image
/// `readPolicyImage` refuses or on a failed allocation.
fn takeHello(gateway: *Gateway, hello: *const control.Hello) !void {
    std.debug.assert(!gateway.hello.received);
    std.debug.assert(!hello.key.isZero());
    const table = try readPolicyImage(gateway.allocator, hello.table_fd.fd(), hello.table_bytes);
    gateway.hello = .{
        .received = true,
        .key = hello.key,
        .table = table,
    };
}

/// Reads the policy image `fd` holds and decodes it into a table from `gpa`, which the caller
/// owns. The descriptor must carry `fd_mod.memfd_readonly_seals`, so no process can change the
/// bytes once they pass, and hold exactly `table_bytes` bytes. Fails with
/// `error.InvalidEgressGatewayPolicyImage` for anything else and for an image
/// `network.Table.decode` refuses; only a server bug sends one.
pub fn readPolicyImage(gpa: std.mem.Allocator, fd: std.posix.fd_t, table_bytes: u32) !network.Table {
    fd_mod.requireSeals(fd, fd_mod.memfd_readonly_seals) catch |err| switch (err) {
        error.MissingFdSeals => return error.InvalidEgressGatewayPolicyImage,
        else => |other| return other,
    };
    const stat = try std.posix.fstat(fd);
    const size = std.math.cast(u64, stat.size) orelse return error.InvalidEgressGatewayPolicyImage;
    if (size != table_bytes)
        return error.InvalidEgressGatewayPolicyImage;
    const image = try gpa.alloc(u8, table_bytes);
    defer gpa.free(image);
    var filled: usize = 0;
    // Each pass reads at least one byte or fails, so at most `table_bytes` passes run.
    while (filled < image.len) {
        const read = try std.posix.pread(fd, image[filled..], filled);
        if (read == 0)
            return error.InvalidEgressGatewayPolicyImage;
        filled += read;
    }
    return network.Table.decode(gpa, image) catch |err| switch (err) {
        error.InvalidPolicyImage => error.InvalidEgressGatewayPolicyImage,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn sendControlPacket(fd: std.posix.fd_t, packet: PendingControlPacket) !void {
    switch (packet) {
        .attach_ack => |ack| try control.sendAttachAck(fd, ack.status, ack.request_id, ack.session_id),
        .session_removed => |removed| try control.sendSessionRemoved(fd, removed.session_id, removed.cause),
    }
}
