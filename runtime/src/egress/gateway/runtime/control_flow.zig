//! The gateway's end of the control socket, as a comptime mixin over the gateway run on its loop
//! thread: the server's hello, worker attaches, the batched `request_ended` notices and shutdown,
//! and what the gateway owes the server in return, the attach acks and a report of each session
//! it removed on its own. The wire format is `control.zig`.
//!
//! The hello comes first and once. Until it arrives the gateway holds the zero key, which
//! verifies no egress token, and takes nothing but the hello and shutdown; any other packet, or a
//! second hello, is a protocol violation that ends the gateway, so the server sees its control
//! channel fail and replaces it. The key, the policy table and each entry's isolation id never
//! change after the hello.
//!
//! The socket is nonblocking. A packet that finds it full waits in a FIFO, and while any waits,
//! new ones queue behind it, so the server receives them in order. When sending or queueing an
//! ack fails, the gateway removes the worker it attached, so no session is left that the server
//! was never told about. A removal report the gateway can neither send nor queue while the server
//! holds its end ends the gateway: the server would otherwise keep a worker it believes attached,
//! and the channel's failure has the server replace the gateway and attach every worker again. A
//! server that closed its end needs no report, and its hang-up ends the loop. `request_ended` is
//! one way. Repeating an entry changes nothing, an entry for a session the gateway no longer has
//! is skipped, and a lost entry costs only fetches under the request's token until its deadline
//! (`budgets.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");

const budgets = @import("../budgets.zig");
const control = @import("../control.zig");
const control_queue = @import("../control_queue.zig");
const policy_mod = @import("../policy.zig");
const sizing = @import("../sizing.zig");

const egress_token = ipc.egress_token;

const control_drain_batch: usize = 64;
/// Packets the full socket can hold back at once. The server waits for each attach's ack before
/// it sends the next attach, and a held-back ack makes that wait time out and retire the gateway,
/// so at most one ack waits, beside one report for each session the gateway holds. Only a server
/// that stopped reading fills the queue.
const pending_control_packet_capacity: usize = sizing.workers_max + 1;

pub const ControlAction = enum {
    idle,
    processed,
    shutdown,
};

/// What the server's hello gave this gateway: the key egress tokens verify under, the network
/// policy table their `policy_id` indexes, and the isolation id of each entry. Fetch admission
/// reads it (`runtime/worker_flow.zig`), and only the hello writes it.
pub const HelloState = struct {
    /// Set by the hello. Until then the gateway takes nothing but the hello and shutdown.
    received: bool = false,
    /// The zero key until the hello, which verifies no token (`egress_token.verify`).
    key: egress_token.Key = .{ .bytes = @splat(0) },
    policies: policy_mod.PolicyTable = .{},
    /// `policy_mod.networkPolicyIsolationId` of each entry of `policies`: the identity of the
    /// entry's fetches in pool keys and shard placement.
    isolation_ids: [policy_mod.policies_max]policy_mod.PoolIsolationId = undefined,
};

/// An attach ack the gateway owes the server.
pub const AttachAck = struct {
    status: control.AttachAckStatus,
    request_id: u64,
    worker_session_id: u64,
};

/// A packet the gateway owes the server, held while the socket has no room.
pub const PendingControlPacket = union(enum) {
    attach_ack: AttachAck,
    /// The id of a session the gateway removed (`control.SessionRemoved`).
    session_removed: u64,
};

pub const PendingControlPackets = control_queue.Queue(
    PendingControlPacket,
    pending_control_packet_capacity,
);

pub fn Methods(comptime Gateway: type) type {
    return struct {
        /// Handles up to `control_drain_batch` control messages and returns true when the server
        /// asked for shutdown or closed the socket. Fails, which ends the gateway, on a packet that
        /// does not decode or breaks the hello's order.
        pub fn drainControl(self: *Gateway) !bool {
            var drained: usize = 0;
            while (drained < control_drain_batch) : (drained += 1) {
                switch (try self.handleControl()) {
                    .idle => return false,
                    .processed => continue,
                    .shutdown => return true,
                }
            }
            return false;
        }

        pub fn controlEvents(self: *const Gateway) i16 {
            var events: i16 = std.posix.POLL.IN;
            if (!self.pending_control_packets.isEmpty())
                events |= std.posix.POLL.OUT;
            return events;
        }

        pub fn sendAttachAck(
            self: *Gateway,
            status: control.AttachAckStatus,
            request_id: u64,
            worker_session_id: u64,
        ) !void {
            try self.sendOrQueueControlPacket(.{ .attach_ack = .{
                .status = status,
                .request_id = request_id,
                .worker_session_id = worker_session_id,
            } });
        }

        /// Tells the server that the gateway removed session `session_id` on its own. A server
        /// that closed its end needs no report, and its hang-up ends the loop on the next pass.
        /// Fails, which ends the gateway, when the report can be neither sent nor queued.
        pub fn reportSessionRemoved(self: *Gateway, session_id: u64) !void {
            self.sendOrQueueControlPacket(.{ .session_removed = session_id }) catch |err| switch (err) {
                error.PeerClosed => return,
                else => return err,
            };
        }

        pub fn sendOrQueueControlPacket(self: *Gateway, packet: PendingControlPacket) !void {
            if (!self.pending_control_packets.isEmpty())
                return self.pending_control_packets.push(packet);

            sendControlPacket(self.control_fd, packet) catch |err| switch (err) {
                error.WouldBlock => return self.pending_control_packets.push(packet),
                else => return err,
            };
        }

        pub fn flushPendingControlPackets(self: *Gateway) !void {
            while (self.pending_control_packets.peek()) |packet| {
                sendControlPacket(self.control_fd, packet) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return err,
                };
                self.pending_control_packets.pop();
            }
        }

        pub fn handleControl(self: *Gateway) !ControlAction {
            var received = ipc.recvPacketWithFdsScratch(self.allocator, self.control_fd, self.scratch) catch |err| switch (err) {
                error.WouldBlock => return .idle,
                error.PeerClosed => return .shutdown,
                else => return err,
            };
            defer received.deinit();

            var message = try control.decode(&received);
            switch (message) {
                .shutdown => return .shutdown,
                .hello => |*hello| {
                    // The packet lies in the scratch the gateway also reads worker commands into
                    // and encodes worker-bound packets from, so it keeps no copy of the key once
                    // `self.hello` holds one, whatever the hello's outcome.
                    defer std.crypto.secureZero(u8, received.bytes);
                    defer std.crypto.secureZero(u8, &hello.key.bytes);
                    if (self.hello.received)
                        return error.EgressGatewayControlOutOfOrder;
                    takeHello(self, hello);
                    return .processed;
                },
                .attach_worker => |attach| {
                    if (!self.hello.received) {
                        var fds = attach.fds;
                        fds.close();
                        return error.EgressGatewayControlOutOfOrder;
                    }
                    if (self.workers.len() >= self.max_workers) {
                        var fds = attach.fds;
                        fds.close();
                        std.log.warn("egress gateway worker attach rejected at limit={d}", .{self.max_workers});
                        self.sendAttachAck(.rejected, attach.request_id, 0) catch |err|
                            std.log.warn("egress gateway attach nack failed: {s}", .{@errorName(err)});
                        return .processed;
                    }
                    var fds = attach.fds;
                    errdefer fds.close();
                    var endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&fds);
                    errdefer endpoint.deinit();
                    const attached = try self.workers.attachEndpoint(
                        self.allocator,
                        &endpoint,
                        attach.security_cell_id,
                    );
                    self.sendAttachAck(.ok, attach.request_id, attached.session_id) catch |err| {
                        try self.removeWorker(attached.index, .attach_ack_failed);
                        std.log.warn("egress gateway attach ack failed session={d}: {s}", .{
                            attached.session_id,
                            @errorName(err),
                        });
                        return .processed;
                    };
                    return .processed;
                },
                .request_ended => |ended| {
                    if (!self.hello.received)
                        return error.EgressGatewayControlOutOfOrder;
                    endRequests(self, ended);
                    return .processed;
                },
            }
        }

        /// Keeps the hello's key and table and computes each entry's isolation id under the
        /// limits this gateway enforces.
        fn takeHello(self: *Gateway, hello: *const control.Hello) void {
            std.debug.assert(!self.hello.received);
            std.debug.assert(!hello.key.isZero());
            const limits_id = policy_mod.policyIsolationId(self.policy);
            for (hello.table.slice(), 0..) |entry, index| {
                self.hello.isolation_ids[index] = policy_mod.networkPolicyIsolationId(
                    limits_id,
                    @intCast(index),
                    entry,
                );
            }
            self.hello.key = hello.key;
            self.hello.policies = hello.table;
            self.hello.received = true;
        }

        /// For each entry, ends the request's budget in its session, cancels the request's
        /// running fetches on every shard and drops its uploads still assembling. The worker gets
        /// no packet for any of them, since its request is over.
        fn endRequests(self: *Gateway, ended: control.RequestEnded) void {
            for (0..ended.count) |index| {
                const key = budgets.BudgetKey.ofEnded(ended.entry(index));
                const worker = self.workers.bySession(key.session_id) orelse continue;
                worker.budgets.end(key);
                self.shards.cancelRequest(key);
                self.dropRequestUploads(key);
            }
        }
    };
}

fn sendControlPacket(fd: std.posix.fd_t, packet: PendingControlPacket) !void {
    switch (packet) {
        .attach_ack => |ack| try control.sendAttachAck(fd, ack.status, ack.request_id, ack.worker_session_id),
        .session_removed => |session_id| try control.sendSessionRemoved(fd, session_id),
    }
}
