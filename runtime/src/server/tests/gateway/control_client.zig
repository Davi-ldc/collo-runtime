//! The server's gateway control client (`server/gateway/control_client.zig`) against a socket
//! pair that plays the gateway. A `rejected` attach acknowledgement fails that one attach, and the
//! client keeps serving; so does a report of a session the gateway removed, which reaches
//! `session_removed` on the reader thread. Any other fault stops the client for good: here the
//! gateway hanging up, an acknowledgement that carries descriptors or names no waiting attach, a
//! packet that is neither an acknowledgement nor a report, and an acknowledgement that misses its
//! deadline. The `failed` callback then runs exactly once, on the reader thread or, for the missed
//! deadline, on the attaching thread. The waiting attach and every later one fail with the first
//! error, the later ones at once and without reaching the socket, and `deinit` reports nothing.
//! What the manager does on those callbacks, and attaches to a real gateway, are covered in
//! `manager.zig`. Lane: server-gateway-control.

const std = @import("std");
const os = @import("collo_os");
const ipc = @import("collo_ipc");

const control_client = @import("collo_server_gateway_control_client");
const control = control_client.protocol;

const security_cell_id: control.SecurityCellId = @splat(0x3c);
/// Waits for another thread's event in slices of `wait_slice_ns`, at most `wait_slices_max` of
/// them, so a client that never reports fails the test instead of hanging it.
const wait_slice_ns: u64 = 100 * std.time.ns_per_ms;
const wait_slices_max: usize = 50;
const poll_timeout_ms: i32 = 5_000;

test "an acknowledged attach returns the session the gateway assigned and deinit reports nothing" {
    var gateway = try FakeGateway.init();
    defer gateway.deinit();
    var session = try createSession();
    defer session.deinit();
    var recorder: FailureRecorder = .{};
    var client: control_client.Client = .{};
    try client.init(std.testing.allocator, gateway.client_end, recorder.options());
    var client_live = true;
    defer if (client_live) client.deinit();

    var call = AttachCall{ .client = &client, .fds = session.rawForGateway() };
    try call.start();
    defer call.join();
    const request_id = try gateway.receiveAttach();
    try control.sendAttachAck(gateway.gateway_end, .ok, request_id, 77);
    call.join();
    try std.testing.expectEqual(@as(?anyerror, null), call.err);
    try std.testing.expectEqual(@as(?u64, 77), call.session_id);

    // The stop `deinit` asks for is no failure of the channel.
    client.deinit();
    client_live = false;
    try std.testing.expectEqual(@as(usize, 0), recorder.calls());
}

test "a rejected attach fails that call alone and the client keeps serving" {
    var gateway = try FakeGateway.init();
    defer gateway.deinit();
    var session = try createSession();
    defer session.deinit();
    var recorder: FailureRecorder = .{};
    var client: control_client.Client = .{};
    try client.init(std.testing.allocator, gateway.client_end, recorder.options());
    defer client.deinit();

    var rejected = AttachCall{ .client = &client, .fds = session.rawForGateway() };
    try rejected.start();
    defer rejected.join();
    const rejected_id = try gateway.receiveAttach();
    try control.sendAttachAck(gateway.gateway_end, .rejected, rejected_id, 0);
    rejected.join();
    try std.testing.expectEqual(@as(?anyerror, error.EgressGatewayAttachRejected), rejected.err);

    var accepted = AttachCall{ .client = &client, .fds = session.rawForGateway() };
    try accepted.start();
    defer accepted.join();
    const accepted_id = try gateway.receiveAttach();
    try std.testing.expect(accepted_id != rejected_id);
    try control.sendAttachAck(gateway.gateway_end, .ok, accepted_id, 78);
    accepted.join();
    try std.testing.expectEqual(@as(?u64, 78), accepted.session_id);
    try std.testing.expectEqual(@as(usize, 0), recorder.calls());
}

test "a session the gateway removed reaches session_removed on the reader, and the client keeps serving" {
    var gateway = try FakeGateway.init();
    defer gateway.deinit();
    var session = try createSession();
    defer session.deinit();
    var recorder: FailureRecorder = .{};
    var client: control_client.Client = .{};
    try client.init(std.testing.allocator, gateway.client_end, recorder.options());
    defer client.deinit();

    // Reports arrive while no attach waits and between an attach and its acknowledgement.
    try control.sendSessionRemoved(gateway.gateway_end, 9);
    try recorder.waitRemoved(1);
    var call = AttachCall{ .client = &client, .fds = session.rawForGateway() };
    try call.start();
    defer call.join();
    const request_id = try gateway.receiveAttach();
    try control.sendSessionRemoved(gateway.gateway_end, 10);
    try control.sendAttachAck(gateway.gateway_end, .ok, request_id, 11);
    call.join();
    try std.testing.expectEqual(@as(?u64, 11), call.session_id);
    try recorder.waitRemoved(2);

    try std.testing.expectEqual(@as(u64, 9), recorder.removedAt(0));
    try std.testing.expectEqual(@as(u64, 10), recorder.removedAt(1));
    try std.testing.expect(recorder.removedThread() != std.Thread.getCurrentId());
    try std.testing.expect(recorder.removedThread() != call.thread_id);
    try std.testing.expectEqual(@as(usize, 0), recorder.calls());
}

test "a gateway that hangs up stops an idle client, which reports it once and nothing at deinit" {
    var gateway = try FakeGateway.init();
    defer gateway.deinit();
    var session = try createSession();
    defer session.deinit();
    var recorder: FailureRecorder = .{};
    var client: control_client.Client = .{};
    try client.init(std.testing.allocator, gateway.client_end, recorder.options());
    var client_live = true;
    defer if (client_live) client.deinit();

    // No attach waits: the reader alone notices that the gateway is gone.
    gateway.closeGatewayEnd();
    try std.testing.expectEqual(@as(?anyerror, error.PeerClosed), recorder.waitFirst());
    try std.testing.expect(recorder.firstThread() != std.Thread.getCurrentId());
    try expectLaterAttachFailsAtOnce(&client, &session, error.PeerClosed);

    client.deinit();
    client_live = false;
    try std.testing.expectEqual(@as(usize, 1), recorder.calls());
}

test "an acknowledgement carrying descriptors stops the client and fails the waiting attach" {
    var gateway = try FakeGateway.init();
    defer gateway.deinit();
    var session = try createSession();
    defer session.deinit();
    var recorder: FailureRecorder = .{};
    var client: control_client.Client = .{};
    try client.init(std.testing.allocator, gateway.client_end, recorder.options());
    defer client.deinit();

    var call = AttachCall{ .client = &client, .fds = session.rawForGateway() };
    try call.start();
    defer call.join();
    const request_id = try gateway.receiveAttach();

    // `sendAttachAck` attaches no descriptors, so this acknowledgement is built by hand and
    // sent with an eventfd attached.
    const extra_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(extra_fd);
    const header = control.Header{
        .magic = control.magic,
        .kind = @intFromEnum(control.Kind.attach_worker_ack),
    };
    const ack = control.AttachAck{
        .status = @intFromEnum(control.AttachAckStatus.ok),
        .request_id = request_id,
        .worker_session_id = 77,
    };
    var buffer: [@sizeOf(control.Header) + @sizeOf(control.AttachAck)]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(control.Header)], std.mem.asBytes(&header));
    @memcpy(buffer[@sizeOf(control.Header)..], std.mem.asBytes(&ack));
    try ipc.packet.sendWithFds(gateway.gateway_end, &buffer, &.{extra_fd});

    try expectChannelFailedOnReader(&recorder, &call, error.InvalidEgressGatewayControl);
    try expectLaterAttachFailsAtOnce(&client, &session, error.InvalidEgressGatewayControl);
    try gateway.expectNothing();
    try std.testing.expectEqual(@as(usize, 1), recorder.calls());
}

test "an acknowledgement for no waiting attach stops the client and fails the waiting attach" {
    var gateway = try FakeGateway.init();
    defer gateway.deinit();
    var session = try createSession();
    defer session.deinit();
    var recorder: FailureRecorder = .{};
    var client: control_client.Client = .{};
    try client.init(std.testing.allocator, gateway.client_end, recorder.options());
    defer client.deinit();

    var call = AttachCall{ .client = &client, .fds = session.rawForGateway() };
    try call.start();
    defer call.join();
    const request_id = try gateway.receiveAttach();
    try control.sendAttachAck(gateway.gateway_end, .ok, request_id + 1_000, 77);

    try expectChannelFailedOnReader(&recorder, &call, error.InvalidEgressGatewayControl);
    try expectLaterAttachFailsAtOnce(&client, &session, error.InvalidEgressGatewayControl);
    try gateway.expectNothing();
    try std.testing.expectEqual(@as(usize, 1), recorder.calls());
}

test "a packet that is neither an attach acknowledgement nor a removal report stops the client" {
    // A second ready report has a valid header and the wrong kind; three bytes are not even a
    // header. Each stops the client with the decoder's error.
    const header = control.Header{
        .magic = control.magic,
        .kind = @intFromEnum(control.Kind.gateway_ready),
    };
    const Case = struct { bytes: []const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .bytes = std.mem.asBytes(&header), .expected = error.InvalidEgressGatewayControl },
        .{ .bytes = &[_]u8{ 1, 2, 3 }, .expected = error.ShortRead },
    };
    for (cases) |case| {
        var gateway = try FakeGateway.init();
        defer gateway.deinit();
        var session = try createSession();
        defer session.deinit();
        var recorder: FailureRecorder = .{};
        var client: control_client.Client = .{};
        try client.init(std.testing.allocator, gateway.client_end, recorder.options());
        defer client.deinit();

        var call = AttachCall{ .client = &client, .fds = session.rawForGateway() };
        try call.start();
        defer call.join();
        _ = try gateway.receiveAttach();
        try ipc.packet.sendExact(gateway.gateway_end, case.bytes);

        try expectChannelFailedOnReader(&recorder, &call, case.expected);
        try expectLaterAttachFailsAtOnce(&client, &session, case.expected);
        try gateway.expectNothing();
        try std.testing.expectEqual(@as(usize, 1), recorder.calls());
    }
}

test "an acknowledgement that misses its deadline fails the channel on the attaching thread" {
    var gateway = try FakeGateway.init();
    defer gateway.deinit();
    var session = try createSession();
    defer session.deinit();
    var recorder: FailureRecorder = .{};
    var client: control_client.Client = .{};
    try client.init(std.testing.allocator, gateway.client_end, recorder.options());
    defer client.deinit();

    // Nothing answers, so the attach waits out its whole deadline on this thread.
    try std.testing.expectError(
        error.EgressGatewayControlTimeout,
        client.attachWorker(security_cell_id, session.rawForGateway()),
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.calls());
    try std.testing.expectEqual(@as(?anyerror, error.EgressGatewayControlTimeout), recorder.waitFirst());
    try std.testing.expectEqual(std.Thread.getCurrentId(), recorder.firstThread());

    // The unanswered attach is the only packet the gateway got.
    _ = try gateway.receiveAttach();
    try expectLaterAttachFailsAtOnce(&client, &session, error.EgressGatewayControlTimeout);
    try gateway.expectNothing();
    try std.testing.expectEqual(@as(usize, 1), recorder.calls());
}

/// Counts the client's `failed` calls and keeps the first one's error and thread, and keeps the
/// sessions `session_removed` reported with the thread that reported them.
const FailureRecorder = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    count: usize = 0,
    first: ?anyerror = null,
    first_thread: std.Thread.Id = 0,
    removed: [removed_sessions_max]u64 = undefined,
    removed_len: usize = 0,
    removed_thread: std.Thread.Id = 0,

    const removed_sessions_max: usize = 4;

    fn options(self: *FailureRecorder) control_client.Client.InitOptions {
        return .{ .ctx = self, .failed = failed, .session_removed = sessionRemoved };
    }

    fn sessionRemoved(ctx: *anyopaque, session_id: u64) void {
        const self: *FailureRecorder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.removed_len < self.removed.len) {
            self.removed[self.removed_len] = session_id;
            self.removed_len += 1;
        }
        self.removed_thread = std.Thread.getCurrentId();
        self.condition.broadcast();
    }

    /// Waits until `count` sessions were reported, or fails when fewer came.
    fn waitRemoved(self: *FailureRecorder, count: usize) !void {
        std.debug.assert(count <= removed_sessions_max);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..wait_slices_max) |_| {
            if (self.removed_len >= count)
                return;
            self.condition.timedWait(&self.mutex, wait_slice_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
        }
        return error.TestRemovalReportMissing;
    }

    /// The `index`-th session reported, in report order.
    fn removedAt(self: *FailureRecorder, index: usize) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(index < self.removed_len);
        return self.removed[index];
    }

    fn removedThread(self: *FailureRecorder) std.Thread.Id {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.removed_thread;
    }

    fn failed(ctx: *anyopaque, err: anyerror) void {
        const self: *FailureRecorder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.first == null) {
            self.first = err;
            self.first_thread = std.Thread.getCurrentId();
        }
        self.count += 1;
        self.condition.broadcast();
    }

    /// Waits for the first failure and returns its error, or null when none came.
    fn waitFirst(self: *FailureRecorder) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..wait_slices_max) |_| {
            if (self.first) |err|
                return err;
            self.condition.timedWait(&self.mutex, wait_slice_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
        }
        return self.first;
    }

    fn firstThread(self: *FailureRecorder) std.Thread.Id {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.first_thread;
    }

    fn calls(self: *FailureRecorder) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
};

/// One `attachWorker` call on a thread of its own, since the test thread plays the gateway.
const AttachCall = struct {
    client: *control_client.Client,
    fds: ipc.egress_shared.RawFds,
    thread: ?std.Thread = null,
    thread_id: std.Thread.Id = 0,
    session_id: ?u64 = null,
    err: ?anyerror = null,

    fn start(self: *AttachCall) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *AttachCall) void {
        self.thread_id = std.Thread.getCurrentId();
        self.session_id = self.client.attachWorker(security_cell_id, self.fds) catch |err| {
            self.err = err;
            return;
        };
    }

    fn join(self: *AttachCall) void {
        if (self.thread) |thread|
            thread.join();
        self.thread = null;
    }
};

/// Waits for the channel's failure, joins the waiting attach and checks that both carry
/// `expected` and that `failed` ran on neither the test thread nor the attaching one, so on the
/// client's reader.
fn expectChannelFailedOnReader(
    recorder: *FailureRecorder,
    call: *AttachCall,
    expected: anyerror,
) !void {
    try std.testing.expectEqual(@as(?anyerror, expected), recorder.waitFirst());
    call.join();
    try std.testing.expectEqual(@as(?u64, null), call.session_id);
    try std.testing.expectEqual(@as(?anyerror, expected), call.err);
    const reporter = recorder.firstThread();
    try std.testing.expect(reporter != std.Thread.getCurrentId());
    try std.testing.expect(reporter != call.thread_id);
}

/// An attach on a stopped client fails on the calling thread with the error that stopped it,
/// without waiting for anything.
fn expectLaterAttachFailsAtOnce(
    client: *control_client.Client,
    session: *ipc.egress_shared.SessionFds,
    expected: anyerror,
) !void {
    try std.testing.expectError(
        expected,
        client.attachWorker(security_cell_id, session.rawForGateway()),
    );
}

/// A session on a wake set of its own. The session holds its own copy of
/// every wake descriptor, so the set closes once the session is built.
fn createSession() !ipc.egress_shared.SessionFds {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    return ipc.egress_shared.createSessionForWorker(&wake_set);
}

/// The two ends of a control socket: the client reads and writes `client_end`, which stays the
/// test's to close, and the test plays the gateway on `gateway_end`.
const FakeGateway = struct {
    client_end: std.posix.fd_t,
    gateway_end: std.posix.fd_t,

    fn init() !FakeGateway {
        const pair = try os.fd.socketPairType(
            std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        );
        return .{ .client_end = pair[0], .gateway_end = pair[1] };
    }

    fn deinit(self: *FakeGateway) void {
        std.posix.close(self.client_end);
        self.closeGatewayEnd();
        self.* = undefined;
    }

    fn closeGatewayEnd(self: *FakeGateway) void {
        if (self.gateway_end >= 0)
            std.posix.close(self.gateway_end);
        self.gateway_end = -1;
    }

    /// Receives the next attach request, closes the descriptors it carried and returns its
    /// request id.
    fn receiveAttach(self: *FakeGateway) !u64 {
        var scratch: [control.attach_worker_message_bytes]u8 = undefined;
        try waitReadable(self.gateway_end);
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.gateway_end, &scratch);
        defer packet.deinit();
        switch (try control.decode(&packet)) {
            .attach_worker => |attach| {
                var fds = attach.fds;
                fds.close();
                try std.testing.expectEqualSlices(u8, &security_cell_id, &attach.security_cell_id);
                return attach.request_id;
            },
            else => return error.TestUnexpectedControlMessage,
        }
    }

    fn expectNothing(self: *FakeGateway) !void {
        var scratch: [control.attach_worker_message_bytes]u8 = undefined;
        try std.testing.expectError(
            error.WouldBlock,
            ipc.recvPacketWithFdsScratch(std.testing.allocator, self.gateway_end, &scratch),
        );
    }
};

fn waitReadable(fd: std.posix.fd_t) !void {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, poll_timeout_ms);
    if (ready == 0)
        return error.TestTimeout;
}
