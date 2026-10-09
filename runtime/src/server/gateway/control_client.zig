//! The server's client for one gateway process's control socket: the attach round trip, and a
//! reader thread of the client's own that receives what the gateway sends after its ready report,
//! its attach acknowledgements and a report of each worker session it removed on its own. The
//! reader hands each report to `InitOptions.session_removed`. Only the launcher attaches
//! (`Manager.attachWorker` in `manager.zig`), and `attach_mutex` holds any other caller back, so
//! one attach waits at a time.
//!
//! Failures come in two tiers. A refused attach fails that call alone, and the client keeps
//! serving. Any other failure fails the channel: a send error, a deadline that passes before the
//! send or the acknowledgement (`control_timeout_ms`), and every reader error, which covers a poll
//! or receive error, the hang-up the gateway's exit causes, a packet that does not decode and an
//! acknowledgement that names no waiting attach. The first one stops the client for good: every
//! waiting and later attach fails with it, and the client calls `InitOptions.failed` once, on the
//! reader thread or on the thread whose call failed. That call holds no lock of the client except,
//! on the attaching thread, `attach_mutex`, and neither does `session_removed`, which runs on the
//! reader thread only. The stop `deinit` asks for calls nothing.
//!
//! A waiter lives on the stack of the attaching thread, and the reader writes into it only under
//! `mutex`. An acknowledgement that arrives after its deadline would name a waiter that is gone,
//! so a missed deadline fails the channel, not just the call.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const os_process = @import("collo_os").process;
const ipc = @import("collo_ipc");

const control = @import("collo_egress_gateway").control;

pub const protocol = control;

/// Bounds one attach: waiting for room to send it and waiting for its acknowledgement share this
/// deadline (`controlDeadlineNs`).
const control_timeout_ms: i32 = 1_000;
/// Packets the reader receives per wakeup before it checks for a stop request again.
const control_packet_drain_batch: usize = 64;
/// The reader's receive buffer holds the longest packet the gateway sends it, an acknowledgement;
/// a longer packet arrives truncated and fails the channel with `error.TruncatedMessage`.
const control_recv_scratch_bytes: usize = @max(
    @sizeOf(control.Header) + @sizeOf(control.AttachAck),
    @sizeOf(control.Header) + @sizeOf(control.SessionRemoved),
);

pub const Client = struct {
    allocator: std.mem.Allocator = undefined,
    control_fd: std.posix.fd_t = -1,
    wake_fd: fd_mod.OwnedFd = .{},
    thread: ?std.Thread = null,
    ctx: *anyopaque = undefined,
    failed: *const fn (ctx: *anyopaque, err: anyerror) void = undefined,
    session_removed: *const fn (ctx: *anyopaque, session_id: u64) void = undefined,
    /// Held for each attach's whole round trip, before `mutex`.
    attach_mutex: std.Thread.Mutex = .{},
    /// Guards the fields below it and the waiter `waiter` points to.
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    /// The first failure, of the channel or the stop `deinit` asks for. Set once; the reader
    /// returns and every attach fails once it is set.
    failure: ?anyerror = null,
    next_attach_request_id: u64 = 1,
    /// The attach waiting for its acknowledgement, null between attaches.
    waiter: ?*AttachWaiter = null,

    pub const InitOptions = struct {
        /// Passed back to both callbacks.
        ctx: *anyopaque,
        /// Told the channel's first failure, once (see the file header). It runs on the reader
        /// thread or inside a failing `attachWorker`, so it must neither deinit the client nor
        /// attach through it.
        failed: *const fn (ctx: *anyopaque, err: anyerror) void,
        /// Told each session the gateway removed on its own (`control.SessionRemoved`), on the
        /// reader thread, which receives nothing more until it returns. It must neither deinit
        /// the client nor attach through it.
        session_removed: *const fn (ctx: *anyopaque, session_id: u64) void,
    };

    /// Starts the reader on `control_fd`, which stays the caller's: the client never closes it,
    /// and it must stay open until `deinit` returns. The reader keeps a pointer to `self`, so
    /// `self` must not move until then.
    pub fn init(
        self: *Client,
        allocator: std.mem.Allocator,
        control_fd: std.posix.fd_t,
        options: InitOptions,
    ) !void {
        std.debug.assert(control_fd >= 0);
        self.* = .{
            .allocator = allocator,
            .control_fd = control_fd,
            .wake_fd = fd_mod.OwnedFd.fromRaw(try std.posix.eventfd(
                0,
                std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
            )),
            .ctx = options.ctx,
            .failed = options.failed,
            .session_removed = options.session_removed,
        };
        errdefer {
            self.wake_fd.deinit();
            self.* = undefined;
        }
        self.thread = try std.Thread.spawn(.{}, readerMain, .{self});
    }

    /// Stops the client without calling `failed`, joins the reader and closes the wake
    /// descriptor. No attach may be waiting, and the caller is not the reader thread, which may
    /// still be inside `failed` until the join returns.
    pub fn deinit(self: *Client) void {
        self.mutex.lock();
        if (self.failure == null)
            self.failure = error.EgressGatewayUnavailable;
        std.debug.assert(self.waiter == null);
        self.mutex.unlock();
        self.signalWake();
        if (self.thread) |thread|
            thread.join();
        self.wake_fd.deinit();
        self.* = undefined;
    }

    /// Attaches a worker session under `security_cell_id` and returns the session id the gateway
    /// assigned. The gateway receives its own copies of `shared_fds` through SCM_RIGHTS, so the
    /// caller keeps and closes its descriptors. A call made while another attach waits blocks
    /// until that one ends. Fails with `error.EgressGatewayAttachRejected` when the gateway
    /// refuses the session, which leaves the client serving, and otherwise with the error that
    /// failed the channel.
    pub fn attachWorker(
        self: *Client,
        security_cell_id: control.SecurityCellId,
        shared_fds: ipc.egress_shared.RawFds,
    ) !u64 {
        self.attach_mutex.lock();
        defer self.attach_mutex.unlock();

        var waiter: AttachWaiter = .{};
        const request_id = try self.putWaiter(&waiter);
        defer self.removeWaiter(&waiter);

        const deadline_ns = controlDeadlineNs();
        sendAttachWorkerRequest(
            self.control_fd,
            request_id,
            security_cell_id,
            shared_fds,
            deadline_ns,
        ) catch |err| {
            self.failChannel(err);
            return err;
        };
        return self.waitAttachAck(&waiter, deadline_ns);
    }

    fn stopped(self: *Client) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure != null;
    }

    /// Publishes `waiter` under the next request id, which it returns, or returns the error that
    /// stopped the client.
    fn putWaiter(self: *Client, waiter: *AttachWaiter) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |err|
            return err;
        // `attach_mutex` admits one attach, and it removes its waiter before it lets go.
        std.debug.assert(self.waiter == null);
        const request_id = self.next_attach_request_id;
        self.next_attach_request_id +%= 1;
        if (self.next_attach_request_id == 0)
            self.next_attach_request_id = 1;
        waiter.request_id = request_id;
        self.waiter = waiter;
        return request_id;
    }

    fn removeWaiter(self: *Client, waiter: *AttachWaiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.waiter == waiter);
        self.waiter = null;
    }

    fn waitAttachAck(self: *Client, waiter: *const AttachWaiter, deadline_ns: u64) !u64 {
        self.mutex.lock();
        while (true) {
            if (self.failure) |err| {
                self.mutex.unlock();
                return err;
            }
            if (waiter.completed)
                break;
            const now_ns = os_process.monotonicNowNsOrZero();
            if (now_ns >= deadline_ns) {
                self.mutex.unlock();
                self.failChannel(error.EgressGatewayControlTimeout);
                return error.EgressGatewayControlTimeout;
            }
            self.condition.timedWait(&self.mutex, deadline_ns - now_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
        }
        const status = waiter.status;
        const worker_session_id = waiter.worker_session_id;
        self.mutex.unlock();
        return switch (status) {
            .ok => worker_session_id,
            .rejected => error.EgressGatewayAttachRejected,
        };
    }

    /// Stops the client with `err` and, when this is its first failure, tells the owner.
    fn failChannel(self: *Client, err: anyerror) void {
        self.mutex.lock();
        const first = self.failure == null;
        if (first) {
            self.failure = err;
            self.condition.broadcast();
        }
        self.mutex.unlock();
        if (first) {
            self.signalWake();
            self.failed(self.ctx, err);
        }
    }

    fn completeAttachAck(self: *Client, ack: control.AttachAck) !void {
        const status = std.meta.intToEnum(control.AttachAckStatus, ack.status) catch
            return error.InvalidEgressGatewayControl;
        self.mutex.lock();
        defer self.mutex.unlock();
        const waiter = self.waiter orelse return error.InvalidEgressGatewayControl;
        if (waiter.request_id != ack.request_id)
            return error.InvalidEgressGatewayControl;
        if (waiter.completed)
            return error.InvalidEgressGatewayControl;
        waiter.completed = true;
        waiter.status = status;
        waiter.worker_session_id = ack.worker_session_id;
        self.condition.broadcast();
    }

    /// Returns when the client stops, and with an error when the channel fails.
    fn readLoop(self: *Client) !void {
        var scratch: [control_recv_scratch_bytes]u8 = undefined;
        while (!self.stopped()) {
            var pollfds = [_]std.posix.pollfd{
                .{
                    .fd = self.control_fd,
                    .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                    .revents = 0,
                },
                .{
                    .fd = self.wake_fd.fd(),
                    .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                    .revents = 0,
                },
            };
            _ = try std.posix.poll(&pollfds, -1);
            if ((pollfds[1].revents & std.posix.POLL.IN) != 0)
                drainEventFd(self.wake_fd.fd());
            if (self.stopped())
                return;
            if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
                return error.PeerClosed;
            if ((pollfds[0].revents & std.posix.POLL.IN) == 0)
                continue;

            var drained: usize = 0;
            while (drained < control_packet_drain_batch) : (drained += 1) {
                var packet = ipc.recvPacketWithFdsScratch(
                    self.allocator,
                    self.control_fd,
                    &scratch,
                ) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                };
                defer packet.deinit();
                switch (try control.decodeGatewayToServerPacket(&packet)) {
                    .attach_ack => |ack| try self.completeAttachAck(ack),
                    .session_removed => |removed| self.session_removed(self.ctx, removed.session_id),
                }
            }
        }
    }

    fn signalWake(self: *Client) void {
        var one: u64 = 1;
        _ = std.posix.write(self.wake_fd.fd(), std.mem.asBytes(&one)) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => {
                std.log.warn("egress gateway control wake failed: {s}", .{@errorName(err)});
                return;
            },
        };
    }
};

const AttachWaiter = struct {
    request_id: u64 = 0,
    completed: bool = false,
    status: control.AttachAckStatus = .rejected,
    worker_session_id: u64 = 0,
};

fn readerMain(client: *Client) void {
    client.readLoop() catch |err| client.failChannel(err);
}

fn sendAttachWorkerRequest(
    fd: std.posix.fd_t,
    request_id: u64,
    security_cell_id: control.SecurityCellId,
    shared_fds: ipc.egress_shared.RawFds,
    deadline_ns: u64,
) !void {
    while (true) {
        control.sendAttachWorker(fd, request_id, security_cell_id, shared_fds) catch |err| switch (err) {
            error.WouldBlock => {
                try waitWritable(fd, deadline_ns);
                continue;
            },
            else => return err,
        };
        return;
    }
}

/// The monotonic deadline of an attach sent now.
fn controlDeadlineNs() u64 {
    return os_process.monotonicNowNsOrZero() +|
        (@as(u64, @intCast(control_timeout_ms)) * std.time.ns_per_ms);
}

fn waitWritable(fd: std.posix.fd_t, deadline_ns: u64) !void {
    const now_ns = os_process.monotonicNowNsOrZero();
    if (now_ns >= deadline_ns)
        return error.EgressGatewayControlTimeout;
    const remaining_ns = deadline_ns - now_ns;
    const remaining_ms = @max(@as(u64, 1), (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
    var pollfds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    const timeout_ms = @min(remaining_ms, @as(u64, @intCast(std.math.maxInt(i32))));
    const ready = try std.posix.poll(&pollfds, @intCast(timeout_ms));
    if (ready == 0)
        return error.EgressGatewayControlTimeout;
    if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
        return error.PeerClosed;
}

fn drainEventFd(fd: std.posix.fd_t) void {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => {
            std.log.warn("egress gateway control wake drain failed: {s}", .{@errorName(err)});
            return;
        },
    };
}
