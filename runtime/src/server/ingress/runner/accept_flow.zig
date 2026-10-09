//! The multishot accept of an ingress lane and the setup of each accepted
//! connection, on the lane thread. The lane keeps one multishot accept armed
//! on its listener and re-arms it whenever the kernel ends it, except while
//! the server is stopping; arming only prepares the submission, which the
//! pass's one `io_uring_enter` hands over (`event_sources.LaneRing`). An
//! accepted socket belongs to the accept path until `startConnection` gives
//! it a connection slot, and from then on to that slot, whose close also
//! closes the socket. A connection costs no buffer until it reads: every
//! read goes into the lane's one read buffer, so the connection slab's
//! capacity is the only bound on connections.
//!
//! A socket that cannot be set up concerns only itself: its error is a
//! connection outcome (`fault.classifyConnectionError`, `.accept`), the
//! socket is closed and counted, and the lane goes on. So does an accept
//! error that concerns one pending connection or a passing shortage
//! (`retriedAcceptResult`). An accept errno nothing outside the lane
//! explains, a failed re-arm and the lane's own timerfd and ring fail the
//! lane.

const std = @import("std");
const linux = std.os.linux;
const process = @import("collo_os").process;
const socket_mod = @import("collo_os").socket;

const accept = @import("../accept.zig");
const fault = @import("../fault.zig");
const PeerAddress = @import("../peer_address.zig").PeerAddress;
const connection_flow = @import("connection_flow.zig");
const connection_slot = @import("connection_slot.zig");
const deadline_driver = @import("deadline_driver.zig");
const event_sources = @import("event_sources.zig");
const work_queues = @import("work_queues.zig");

const LaneFault = fault.LaneFault;

/// How long the lane waits before re-arming an accept that the kernel ended
/// on EMFILE or ENFILE.
const accept_backoff_ns: u64 = 25 * std.time.ns_per_ms;

pub fn Methods(comptime Self: type) type {
    return struct {
        const Connection = connection_flow.Methods(Self);
        const Deadlines = deadline_driver.Methods(Self);
        const Queues = work_queues.Methods(Self);

        /// Prepares the lane's multishot accept unless it is already active.
        /// Accepted sockets arrive nonblocking and close-on-exec.
        pub fn ensureAcceptArmed(self: *Self, ring: *event_sources.LaneRing) LaneFault!void {
            if (self.lane.accept_registration.state == .active)
                return;
            const generation = self.lane.accept_registration.arm();
            const user_data = try accept.packAcceptUserData(self.lane.lane_id, generation);
            const sqe = try ring.prepare();
            sqe.prep_multishot_accept(
                self.listener.stream.handle,
                null,
                null,
                std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            );
            sqe.user_data = user_data;
        }

        /// Loop handler for one accept completion. A completion of an earlier
        /// arming is counted as stale and its socket closed, and one tagged
        /// for another lane is only counted. The loop routes only accept
        /// completions here, so a tag that is not one is the lane's fault.
        pub fn handleAcceptCqe(self: *Self, cqe: linux.io_uring_cqe) LaneFault!void {
            self.lane.counters.readiness_cqes_processed += 1;
            const ring = self.runtime_ring orelse return error.IngressRingUnavailable;
            const decoded = accept.unpackAcceptUserData(cqe.user_data) catch |err| switch (err) {
                error.InvalidUserDataTag => return error.UnknownCqeTag,
                error.InvalidLaneId => return error.InvalidLaneId,
            };
            if (decoded.lane_id != self.lane.lane_id) {
                self.accept_counters.multishot_stale_cqes += 1;
                return;
            }
            if (decoded.generation != self.lane.accept_registration.generation or
                self.lane.accept_registration.state != .active)
            {
                self.accept_counters.multishot_stale_cqes += 1;
                if (cqe.res >= 0) {
                    accept.closeRejectedAcceptedFd(
                        @intCast(cqe.res),
                        &self.lane.counters,
                        .connection_slab_exhaustion,
                    );
                }
                return;
            }

            const action = accept.handleAcceptCompletion(
                &self.lane.accept_registration,
                .{ .generation = decoded.generation, .res = retriedAcceptResult(cqe.res), .flags = cqe.flags },
                monotonicNowNs(),
                accept_backoff_ns,
                &self.accept_counters,
            );
            switch (action) {
                .accepted => |fd| {
                    try acceptConnection(self, fd);
                    if (self.lane.accept_registration.state == .inactive and
                        !self.service.shouldStop())
                    {
                        try ensureAcceptArmed(self, ring);
                    }
                },
                // A transient error ended the multishot accept. Like the
                // re-arm after `.accepted`, it is not resubmitted once the
                // server is stopping.
                .rearm => if (!self.service.shouldStop()) try ensureAcceptArmed(self, ring),
                // The deadline timerfd wakes the lane when the backoff ends,
                // and the loop re-arms the accept then.
                .backoff => try deadline_driver.armTimer(Self, self),
                .transient, .ignored_stale => {},
                .fatal => return error.FatalAcceptCqe,
            }
        }

        /// Takes the accepted socket `fd` into a connection, or closes it.
        fn acceptConnection(self: *Self, fd: std.posix.fd_t) LaneFault!void {
            // The multishot accept keeps delivering sockets during the
            // shutdown drain (`ring_driver.zig`), since nearly every
            // completion carries IORING_CQE_F_MORE and the accept rarely ends
            // by itself. Without this check new clients would keep opening
            // connections into a lane that is draining. A socket accepted
            // after the stop has done no handshake, so closing it loses no
            // work.
            if (self.service.shouldStop()) {
                accept.closeRejectedAcceptedFd(fd, &self.lane.counters, .shutting_down);
                return;
            }
            startConnection(self, fd) catch |err| return refuseConnection(self, err);
        }

        /// Counts a socket `startConnection` refused, which is closed
        /// already, and returns a lane fault unchanged.
        fn refuseConnection(self: *Self, err: (LaneFault || fault.AcceptError)) LaneFault!void {
            switch (try fault.classifyConnectionError(.{ .accept = err })) {
                .keep => {},
                .close => |close| switch (close.reason) {
                    .connection_limit => self.lane.counters.accepted_connection_slab_exhaustion += 1,
                    else => {
                        self.lane.counters.accepted_setup_failures += 1;
                        std.log.warn(
                            "ingress lane {d} could not set up an accepted connection: {s}",
                            .{ self.listener_index, @errorName(err) },
                        );
                    },
                },
            }
        }

        /// Gives the accepted socket `fd`, which it owns from the call, a
        /// connection slot and starts its TLS handshake under the
        /// pre-request deadline. On every error the socket is closed: before
        /// the slot takes it here, after that by the slot's close.
        pub fn startConnection(self: *Self, fd: std.posix.fd_t) (LaneFault || fault.AcceptError)!void {
            const acquired = self.connections.acquire() orelse {
                std.posix.close(fd);
                return error.ConnectionSlabFull;
            };
            const runtime = acquired.entry;
            runtime.key = .{ .lane_id = self.lane.lane_id, .slot = acquired.index, .generation = acquired.generation };
            runtime.fd = fd;
            runtime.streams = &self.h2_lane.streams;
            runtime.wait_events = event_sources.read_write_events;
            self.lane.counters.accepted_connections += 1;
            const now = monotonicNowNs();
            runtime.accepted_ns = now;
            runtime.last_progress_ns = now;
            // What fails below is the socket's setup or its TLS session
            // (`fault.AcceptError`), whose rows are this close, or the lane
            // itself. The close runs on the slot's next turn.
            var runtime_owned = true;
            errdefer if (runtime_owned) {
                Connection.closeRuntimeConnection(self, runtime, .{ .reason = .setup_failed, .goaway = null });
            };
            try socket_mod.setTcpNoDelay(fd);
            configureAcceptedTcpNotSentLowAt(self, fd);
            // `ensureAcceptArmed` passes no address buffer, so the peer
            // address is read here, once per connection.
            runtime.peer_address = try PeerAddress.fromSocket(fd);
            runtime.tls_connection = try self.service.tls_context.start(fd);
            try Deadlines.syncConnectionDeadline(self, runtime);
            try Connection.updateConnectionInterest(self, runtime);
            Queues.enqueueConnection(self, acquired.index);
            runtime_owned = false;
        }

        /// A zero `ingress_tcp_notsent_lowat_bytes` leaves the kernel default.
        /// A failure is counted and warned about once per lane, and the
        /// connection proceeds without the option.
        fn configureAcceptedTcpNotSentLowAt(self: *Self, fd: std.posix.fd_t) void {
            const byte_count = self.service.ingress_tcp_notsent_lowat_bytes;
            if (byte_count == 0)
                return;
            socket_mod.setTcpNotSentLowAt(fd, byte_count) catch |err| {
                self.lane.counters.accepted_tcp_notsent_lowat_failures += 1;
                if (!self.tcp_notsent_lowat_warning_logged) {
                    self.tcp_notsent_lowat_warning_logged = true;
                    std.log.warn(
                        "ingress lane {d} failed to set TCP_NOTSENT_LOWAT={d}: {s}",
                        .{ self.listener_index, byte_count, @errorName(err) },
                    );
                }
            };
        }
    };
}

/// The result of an accept completion as the accept's state machine
/// (`accept.handleAcceptCompletion`) should see it. accept(2) passes a
/// network error already pending on the new connection, or a firewall's
/// refusal of it, back as the accept's own error, and asks the caller to
/// retry as for EAGAIN: such an error concerns one connection, so it reads
/// as ECONNABORTED, the abort of one pending connection. A shortage of
/// socket buffers passes like the descriptor limits, as ENFILE, which backs
/// the accept off. Every other result is unchanged.
fn retriedAcceptResult(res: i32) i32 {
    if (res >= 0)
        return res;
    const code = std.math.cast(u16, -@as(i64, res)) orelse return res;
    const errno: linux.E = @enumFromInt(code);
    const retried: linux.E = switch (errno) {
        .NETDOWN, .PROTO, .NOPROTOOPT, .HOSTDOWN, .NONET, .HOSTUNREACH, .OPNOTSUPP, .NETUNREACH, .PERM => .CONNABORTED,
        .NOBUFS, .NOMEM => .NFILE,
        else => return res,
    };
    return -@as(i32, @intFromEnum(retried));
}

fn monotonicNowNs() u64 {
    return process.monotonicNowNsOrZero();
}
