//! Tests for the egress io_uring data driver (`client/io/bio_data.zig`): the
//! recv and send SQEs it owns for each wire, the one-shot writability poll it
//! arms for a connecting socket, and the wait that serves one result at a
//! time. They cover wake, readiness and deadline delivery, partial sends, one
//! receive at a time into a wire's buffer, a failed receive and a reset as
//! the wire sees them, the refresh of an idle wire before a lease, tokens
//! across the generation wrap, chunked submission past the SQ, expiry ahead
//! of a completion backlog, a connect poll that reports once and ends at
//! `cancelConnecting`, and wire cancels on full, failing and dead rings.
//!
//! Every test drives a real restricted ring. Wires sit on Unix socketpairs,
//! or on a TCP connection to 127.0.0.1 where a reset is needed; a TLS wire is
//! unhandshaken, so its only bytes are its ClientHello. Connecting sockets
//! dial listeners on 127.0.0.1, and a socketpair end with a full send buffer
//! stands in for a connect that has not ended. A receive fails on a pipe
//! dup2-ed over a wire's socket, a dead ring is simulated by dup2-ing an
//! eventfd over the ring fd, and transient flush failures are injected
//! through `test_flush_failures`. Every test skips when the kernel or its
//! policy offers no restricted ring (`initDriver`); any other setup failure
//! fails the test. How the engine's owner loop uses the driver is tested in
//! `engine/`.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const data_io = egress_client.data_io;
const transport = egress_client.transport;

const deadlineAfterMs = transport.config.deadlineAfterMs;
const monotonicNowNs = transport.config.monotonicNowNs;

/// The buffering budget of every test wire, above the largest payload a test
/// queues.
const max_buffered_bytes: usize = 256 * 1024;
/// Bounds the nonblocking loops that fill or drain a socket.
const max_socket_chunks: usize = 4096;

fn socketPair() ![2]std.posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => return .{ fds[0], fds[1] },
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// A driver, or a skip when this kernel or its policy offers no restricted
/// ring (`Driver.init`'s `UnsupportedKernel` and `PermissionDenied`); any
/// other failure fails the test.
fn initDriver() !data_io.Driver {
    return data_io.Driver.init(std.testing.allocator) catch |err| switch (err) {
        error.UnsupportedKernel, error.PermissionDenied => return error.SkipZigTest,
        else => |other| return other,
    };
}

/// Teardown for a wire the driver may have seen. A confirmed cancel leaves
/// the wire with the caller, which deinits it. An unconfirmed cancel
/// quarantines the registration and hands the wire to the driver, which
/// frees it once its terminal completions arrive; deiniting it here as well
/// would free it twice whenever a transient io_uring_enter EAGAIN hits
/// teardown.
fn releaseWire(driver: *data_io.Driver, wire: *transport.Wire) void {
    if (driver.cancelConnectionForClose(wire))
        wire.deinit();
}

/// A plain wire that takes `fd`, closing it on error.
fn createPlainWire(fd: std.posix.fd_t) !*transport.Wire {
    return transport.Wire.createPlain(std.testing.allocator, .{ .handle = fd }, max_buffered_bytes);
}

/// An unhandshaken TLS wire with its ClientHello queued for sending. Takes
/// `fd`, closing it on error.
fn createTlsWire(fd: std.posix.fd_t) !*transport.Wire {
    const wire = try transport.Wire.createTls(std.testing.allocator, .{ .handle = fd }, .{
        .server_name = "example.com",
        .insecure_tls = true,
        .session_key = null,
    }, max_buffered_bytes);
    errdefer wire.deinit();
    switch (try wire.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsHandshakeWait,
    }
    if (!wire.hasBytesToSend())
        return error.ExpectedQueuedClientHello;
    return wire;
}

/// Queues `bytes` on a plain wire, which must take all of them.
fn queueBytes(wire: *transport.Wire, bytes: []const u8) !void {
    switch (try wire.writeStep(bytes)) {
        .ready => |taken| try std.testing.expectEqual(bytes.len, taken),
        .wait, .eof => return error.ExpectedWireToTakeBytes,
    }
}

/// Reads plaintext the wire already holds, which must be `expected`.
fn expectRead(wire: *transport.Wire, expected: []const u8) !void {
    var buffer: [64]u8 = undefined;
    switch (try wire.readStep(&buffer)) {
        .ready => |len| try std.testing.expectEqualStrings(expected, buffer[0..len]),
        .wait, .eof => return error.ExpectedWireBytes,
    }
}

/// Reads exactly `buffer.len` bytes that the peer of `fd` already sent.
fn readExactly(fd: std.posix.fd_t, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const len = try std.posix.read(fd, buffer[filled..]);
        if (len == 0)
            return error.UnexpectedEndOfStream;
        filled += len;
    }
}

/// Reads and discards everything `fd` holds without blocking; returns the
/// byte count.
fn drainSocket(fd: std.posix.fd_t) !usize {
    var scratch: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    var reads: usize = 0;
    while (reads < max_socket_chunks) : (reads += 1) {
        const flags = std.os.linux.MSG.DONTWAIT;
        const len = std.posix.recv(fd, &scratch, flags) catch |err| switch (err) {
            error.WouldBlock => return total,
            else => |other| return other,
        };
        if (len == 0)
            return total;
        total += len;
    }
    return error.SocketNeverDrained;
}

/// Sends until a nonblocking send would block, so `fd` stays unwritable
/// until its peer reads.
fn fillSendBuffer(fd: std.posix.fd_t) !void {
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 0xa5);
    const flags = std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL;
    var sends: usize = 0;
    while (sends < max_socket_chunks) : (sends += 1) {
        _ = std.posix.send(fd, &chunk, flags) catch |err| switch (err) {
            error.WouldBlock => return,
            else => |other| return other,
        };
    }
    return error.SendBufferNeverFilled;
}

/// A listener on 127.0.0.1 with a port the kernel picks. The kernel
/// completes handshakes into its backlog, so a dial connects without an
/// accept.
fn loopbackListener() !std.net.Server {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    return address.listen(.{});
}

/// A 127.0.0.1 address nothing listens on: the port of a listener that was
/// just closed, so a dial to it is refused.
fn closedLoopbackAddress() !std.net.Address {
    var listener = try loopbackListener();
    const address = listener.listen_address;
    listener.deinit();
    return address;
}

/// A connected nonblocking TCP socket to `address`, its connect finished
/// under the driver's connect watch as a dial finishes it.
fn connectLoopback(driver: *data_io.Driver, address: std.net.Address) !std.posix.fd_t {
    const started = try transport.connect.startAttempt(address);
    errdefer std.posix.close(started.fd);
    if (!started.connected) {
        defer driver.cancelConnecting(started.fd);
        var context: u8 = 0;
        _ = try expectReady(&context, try driver.wait(&.{.{
            .context = &context,
            .io = .{ .connecting = started.fd },
            .deadline_mono_ns = try deadlineAfterMs(5_000),
        }}, null));
    }
    try transport.connect.finishAttempt(started.fd);
    return started.fd;
}

/// Waits until `fd` has bytes to read, at most `timeout_ms`.
fn awaitReadable(fd: std.posix.fd_t, timeout_ms: i32) !void {
    var polled = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&polled, timeout_ms) == 0)
        return error.SocketNeverReadable;
}

/// Waits until the kernel has posted at least one completion the driver has
/// not ingested. A completion of a receive armed against a silent peer is
/// posted on this thread's next entry into the kernel, which each sleep is.
fn awaitPostedCompletion(driver: *data_io.Driver) !void {
    for (0..2_000) |_| {
        if (driver.ring.cq_ready() != 0)
            return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.CompletionNeverPosted;
}

/// Waits until the completion queue holds `count` completions the driver has
/// not ingested, posted on this thread's entries into the kernel.
fn awaitPostedCount(driver: *data_io.Driver, count: usize) !void {
    for (0..2_000) |_| {
        if (driver.ring.cq_ready() >= count)
            return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.CompletionsNeverPosted;
}

/// Waits until the kernel holds a completion in its overflow list.
fn awaitOverflow(driver: *data_io.Driver) !void {
    for (0..2_000) |_| {
        if (driver.ring.cq_ring_needs_flush())
            return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.CompletionNeverOverflowed;
}

/// Fails unless `result` is readiness of `context`; returns its flags.
fn expectReady(context: *anyopaque, result: data_io.Result) !data_io.Ready {
    switch (result) {
        .ready => |ready| {
            try std.testing.expectEqual(context, ready.context);
            return ready;
        },
        .failed, .expired, .wake, .tick => return error.ExpectedEgressDataReady,
    }
}

/// Fails unless `result` is the expiry of `context`.
fn expectExpired(context: *anyopaque, result: data_io.Result) !void {
    switch (result) {
        .expired => |expired| try std.testing.expectEqual(context, expired),
        .ready, .failed, .wake, .tick => return error.ExpectedEgressDataExpiry,
    }
}

const WireKind = enum { plain, tls };

/// Wires on socketpairs, with the peer ends the test keeps and one context
/// per wire for its sources. `deinit` releases each wire through the driver
/// before closing its peer.
const WireSet = struct {
    wires: []*transport.Wire,
    peers: []std.posix.fd_t,
    contexts: []u8,
    reported: []bool,
    count: usize = 0,

    fn init(capacity: usize) !WireSet {
        const wires = try std.testing.allocator.alloc(*transport.Wire, capacity);
        errdefer std.testing.allocator.free(wires);
        const peers = try std.testing.allocator.alloc(std.posix.fd_t, capacity);
        errdefer std.testing.allocator.free(peers);
        const contexts = try std.testing.allocator.alloc(u8, capacity);
        errdefer std.testing.allocator.free(contexts);
        const reported = try std.testing.allocator.alloc(bool, capacity);
        @memset(reported, false);
        return .{
            .wires = wires,
            .peers = peers,
            .contexts = contexts,
            .reported = reported,
        };
    }

    fn deinit(self: *WireSet, driver: *data_io.Driver) void {
        for (self.wires[0..self.count], self.peers[0..self.count]) |wire, peer| {
            releaseWire(driver, wire);
            std.posix.close(peer);
        }
        std.testing.allocator.free(self.reported);
        std.testing.allocator.free(self.contexts);
        std.testing.allocator.free(self.peers);
        std.testing.allocator.free(self.wires);
        self.* = undefined;
    }

    fn add(self: *WireSet, kind: WireKind) !*transport.Wire {
        std.debug.assert(self.count < self.wires.len);
        const pair = try socketPair();
        errdefer std.posix.close(pair[1]);
        const wire = switch (kind) {
            .plain => try createPlainWire(pair[0]),
            .tls => try createTlsWire(pair[0]),
        };
        self.wires[self.count] = wire;
        self.peers[self.count] = pair[1];
        self.count += 1;
        return wire;
    }

    /// A source for wire `index` that wants its receive.
    fn source(self: *const WireSet, index: usize, deadline_mono_ns: u64) data_io.Source {
        return .{
            .context = &self.contexts[index],
            .io = .{ .wire = self.wires[index] },
            .deadline_mono_ns = deadline_mono_ns,
        };
    }

    /// Records a report for the wire whose context is `context`. Fails on a
    /// context outside the set or a second report.
    fn noteReport(self: *WireSet, context: *anyopaque) !void {
        for (self.contexts[0..self.count], 0..) |*slot, index| {
            if (@as(*anyopaque, slot) != context)
                continue;
            if (self.reported[index])
                return error.WireReportedTwice;
            self.reported[index] = true;
            return;
        }
        return error.UnknownWireContext;
    }
};

test "egress data io wakes from eventfd without sources" {
    var driver = try initDriver();
    defer driver.deinit();
    const wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(wake_fd);

    var one: u64 = 1;
    _ = try std.posix.write(wake_fd, std.mem.asBytes(&one));
    try std.testing.expectEqual(data_io.Result.wake, try driver.wait(&.{}, wake_fd));
}

test "egress data io sends a TLS wire's handshake ciphertext" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createTlsWire(fds[0]);
    defer releaseWire(&driver, wire);
    const hello = try std.testing.allocator.dupe(u8, wire.sendSlice());
    defer std.testing.allocator.free(hello);

    var context: u8 = 0;
    const ready = try expectReady(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
        .want_read = false,
        .want_write = true,
    }}, null));
    try std.testing.expect(ready.writable);
    try std.testing.expect(!wire.hasBytesToSend());

    const received = try std.testing.allocator.alloc(u8, hello.len);
    defer std.testing.allocator.free(received);
    try readExactly(fds[1], received);
    try std.testing.expectEqualSlices(u8, hello, received);
}

// The socket's send buffer is far smaller than the queued payload, so one
// send takes only part of it. The completion must drop exactly the bytes
// that went out and keep the rest queued for the next send.
test "egress data io preserves queued bytes after a partial socket send" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);
    const send_buffer_bytes: c_int = 4096;
    try std.posix.setsockopt(
        wire.fd(),
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        std.mem.asBytes(&send_buffer_bytes),
    );

    const payload = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0xa5);
    try queueBytes(wire, payload);

    var context: u8 = 0;
    const ready = try expectReady(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
        .want_read = false,
        .want_write = true,
    }}, null));
    try std.testing.expect(ready.writable);
    try std.testing.expect(!wire.send_in_flight);

    const queued = wire.sendSlice().len;
    try std.testing.expect(queued > 0);
    try std.testing.expect(queued < payload.len);
    try std.testing.expectEqual(payload.len - queued, try drainSocket(fds[1]));
}

// A send completes while the receive stays parked against the silent peer,
// and the next send leaves that receive in place instead of arming another.
test "egress data io keeps one recv and one send in flight per wire" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);

    var context: u8 = 0;
    const source: data_io.Source = .{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
        .want_read = true,
        .want_write = true,
    };
    try queueBytes(wire, "hello");
    const first = try expectReady(&context, try driver.wait(&.{source}, null));
    try std.testing.expect(first.writable);
    try std.testing.expect(!wire.send_in_flight);
    try std.testing.expect(wire.recv_in_flight);
    // The wire holds the driver's only registration.
    const parked_recv = driver.registrations.items[0].recv_user_data;

    try queueBytes(wire, "again");
    const second = try expectReady(&context, try driver.wait(&.{source}, null));
    try std.testing.expect(second.writable);
    try std.testing.expect(driver.registrations.items[0].recv_queued);
    try std.testing.expectEqual(parked_recv, driver.registrations.items[0].recv_user_data);

    var received: ["helloagain".len]u8 = undefined;
    try readExactly(fds[1], &received);
    try std.testing.expectEqualStrings("helloagain", &received);
}

// The kernel receives into the wire's own buffer, so a plain wire gets no
// further receive until the protocol has read the last one; bytes that
// arrive meanwhile wait in the socket.
test "egress data io lands one receive at a time in a plain wire's buffer" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);

    var context: u8 = 0;
    const reading: data_io.Source = .{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    };
    _ = try std.posix.write(fds[1], "ping");
    const first = try expectReady(&context, try driver.wait(&.{reading}, null));
    try std.testing.expect(first.readable);

    _ = try std.posix.write(fds[1], "pong");
    var gate_context: u8 = 0;
    const gated = [_]data_io.Source{ reading, .{
        .context = &gate_context,
        .deadline_mono_ns = try deadlineAfterMs(30),
    } };
    try expectExpired(&gate_context, try driver.wait(&gated, null));
    try std.testing.expect(!wire.recv_in_flight);
    try expectRead(wire, "ping");

    const second = try expectReady(&context, try driver.wait(&.{reading}, null));
    try std.testing.expect(second.readable);
    try expectRead(wire, "pong");
}

test "egress data io reports socket EOF to the wire" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);

    var context: u8 = 0;
    const ready = try expectReady(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    }}, null));
    try std.testing.expect(ready.readable);
    try std.testing.expect(wire.eof);
}

// A pipe dup2-ed over the wire's socket makes the next receive fail with
// ENOTSOCK, a failure that is no reset. The wire is unclean as soon as the
// driver learns of the failure, whoever hears of it and whenever, so a pool
// that looks at it before its owner does cannot lease it.
test "egress data io marks a wire whose receive failed unclean and arms it no further receive" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);
    try std.posix.dup2(pipe[0], wire.fd());
    try std.testing.expect(wire.cleanForReuse());

    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    }}, null)) {
        .failed => |failure| try std.testing.expectEqual(@as(*anyopaque, &context), failure.context),
        .ready, .expired, .wake, .tick => return error.ExpectedEgressDataFailure,
    }
    try std.testing.expect(!wire.cleanForReuse());
    try std.testing.expect(!wire.networkWantsRead());
}

// A TCP reset reads as the end of the stream (`applyReceiveResult` in
// bio_data.zig), and a TLS wire waiting for handshake records after that
// end fails its handshake at once instead of at the dial's stall deadline.
test "egress data io turns a reset during a TLS handshake into a failed handshake" {
    var driver = try initDriver();
    defer driver.deinit();
    var listener = try loopbackListener();
    defer listener.deinit();

    const wire = try createTlsWire(try connectLoopback(&driver, listener.listen_address));
    defer releaseWire(&driver, wire);
    const accepted = try listener.accept();
    var accepted_open = true;
    defer if (accepted_open) accepted.stream.close();

    var context: u8 = 0;
    const sent = try expectReady(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
        .want_read = false,
        .want_write = true,
    }}, null));
    try std.testing.expect(sent.writable);
    // The ClientHello reaches the server, which never reads it, and a socket
    // closed with unread bytes resets its connection instead of a FIN.
    try awaitReadable(accepted.stream.handle, 5_000);
    accepted.stream.close();
    accepted_open = false;

    const ready = try expectReady(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    }}, null));
    try std.testing.expect(ready.readable);
    try std.testing.expect(wire.eof);
    try std.testing.expectError(error.TlsHandshakeFailed, wire.handshakeStep());
}

// With no receive in flight, a refresh takes what the socket holds: bytes or
// the end of the stream make the wire unclean, and a quiet socket leaves it
// clean with nothing taken.
test "egress data io refreshes an idle wire with no receive in flight from its socket" {
    var driver = try initDriver();
    defer driver.deinit();
    var set = try WireSet.init(3);
    defer set.deinit(&driver);
    const stray = try set.add(.plain);
    const closed = try set.add(.plain);
    const quiet = try set.add(.plain);

    _ = try std.posix.write(set.peers[0], "stray");
    try std.posix.shutdown(set.peers[1], .send);

    try std.testing.expect(driver.refreshIdleWire(stray));
    try std.testing.expect(!stray.cleanForReuse());
    try expectRead(stray, "stray");
    try std.testing.expect(driver.refreshIdleWire(closed));
    try std.testing.expect(closed.eof);
    try std.testing.expect(!closed.cleanForReuse());
    try std.testing.expect(driver.refreshIdleWire(quiet));
    try std.testing.expect(quiet.cleanForReuse());
    try std.testing.expect(quiet.networkWantsRead());
}

// A wait that armed an idle wire's receive can return before its completion
// arrives, and the kernel then writes the receive's bytes into the wire's
// buffer without the wire knowing. A refresh ingests the posted completion,
// so the wire judges the bytes; while nothing was posted, the receive stays
// in flight and the wire stays clean.
test "egress data io refresh ingests an idle wire's receive that completed after its wait returned" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);

    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(30),
    }}, null));
    try std.testing.expect(wire.recv_in_flight);
    try std.testing.expect(driver.refreshIdleWire(wire));
    try std.testing.expect(wire.recv_in_flight);
    try std.testing.expect(wire.cleanForReuse());

    _ = try std.posix.write(fds[1], "stray");
    try awaitPostedCompletion(&driver);
    // The bytes sit in the wire's buffer, but nothing told the wire yet.
    try std.testing.expect(wire.recv_in_flight);
    try std.testing.expect(wire.cleanForReuse());

    try std.testing.expect(driver.refreshIdleWire(wire));
    try std.testing.expect(!wire.recv_in_flight);
    try std.testing.expect(!wire.cleanForReuse());
    try expectRead(wire, "stray");
}

// A completion the kernel finds no room for in the completion queue waits in
// its overflow list (IORING_FEAT_NODROP), which only an enter that asks for
// events moves into the queue. Here the queue is full of completions the
// driver does not own when the idle wire's receive completes, so the receive's
// completion overflows, and the queue then keeps fewer than one batch: a drain
// that ended on that short batch would call the queue empty and lease a wire
// whose buffer already holds bytes.
test "egress data io refresh ingests an idle wire's receive whose completion overflowed the completion queue" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);

    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(30),
    }}, null));
    try std.testing.expect(wire.recv_in_flight);

    // Timeouts that fire at once fill what room the queue has left. Their
    // user_data carries no egress tag, so ingestion drops each one.
    const queue_entries: usize = driver.ring.cq.cqes.len;
    const already_posted: usize = driver.ring.cq_ready();
    const immediate: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 0 };
    var filled: usize = already_posted;
    while (filled < queue_entries) {
        _ = driver.ring.timeout(0, &immediate, 0, 0) catch {
            _ = try driver.ring.submit();
            continue;
        };
        filled += 1;
    }
    _ = try driver.ring.submit();
    try awaitPostedCount(&driver, queue_entries);
    try std.testing.expect(!driver.ring.cq_ring_needs_flush());

    _ = try std.posix.write(fds[1], "stale");
    try awaitOverflow(&driver);
    // The queue keeps a short batch of the timeouts, and the receive waits in
    // the overflow list.
    const kept: u32 = 30;
    driver.ring.cq_advance(@intCast(queue_entries - kept));
    try std.testing.expectEqual(kept, driver.ring.cq_ready());
    try std.testing.expect(wire.recv_in_flight);
    try std.testing.expect(wire.cleanForReuse());

    try std.testing.expect(driver.refreshIdleWire(wire));
    try std.testing.expect(!wire.recv_in_flight);
    try std.testing.expect(!wire.cleanForReuse());
    try expectRead(wire, "stale");
    try std.testing.expect(!driver.ring.cq_ring_needs_flush());
}

// Every token carries the driver's u16 generation, which wraps past zero,
// since zero marks no token (`UserData.pack` in bio_data.zig). Here the
// receive takes the last generation before the wrap and the send the first
// after it, and both still complete and are matched to their wire.
test "egress data io matches completions armed on both sides of the generation wrap" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);

    driver.generation = std.math.maxInt(u16) - 1;
    try queueBytes(wire, "out");
    var context: u8 = 0;
    const source: data_io.Source = .{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
        .want_read = true,
        .want_write = true,
    };
    const sent = try expectReady(&context, try driver.wait(&.{source}, null));
    try std.testing.expect(sent.writable);
    try std.testing.expect(wire.recv_in_flight);
    try std.testing.expect(driver.generation != 0);
    try std.testing.expect(driver.generation < std.math.maxInt(u16) - 1);

    _ = try std.posix.write(fds[1], "in");
    const received = try expectReady(&context, try driver.wait(&.{source}, null));
    try std.testing.expect(received.readable);
    try expectRead(wire, "in");
    var echoed: ["out".len]u8 = undefined;
    try readExactly(fds[1], &echoed);
    try std.testing.expectEqualStrings("out", &echoed);
}

test "egress data io expires wire read deadlines" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer releaseWire(&driver, wire);

    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try monotonicNowNs(),
    }}, null));
}

test "egress data io expires deadline-only sources without arming io" {
    var driver = try initDriver();
    defer driver.deinit();

    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .deadline_mono_ns = try deadlineAfterMs(30),
    }}, null));
    try std.testing.expectEqual(@as(usize, 0), driver.registrations.items.len);
}

// Each wire wants a receive and a send, so one pass queues two SQEs per
// wire, more than the driver's SQ holds (`ring_entries` in bio_data.zig),
// and the submission must go out in chunks. The wires alternate TLS, with a
// ClientHello queued, and plain, with one byte queued.
test "egress data io submits more wire operations than the SQ holds in chunks" {
    var driver = try initDriver();
    defer driver.deinit();

    const wire_count = 150;
    var set = try WireSet.init(wire_count);
    defer set.deinit(&driver);
    const sources = try std.testing.allocator.alloc(data_io.Source, wire_count);
    defer std.testing.allocator.free(sources);
    const deadline_mono_ns = try deadlineAfterMs(10_000);
    for (sources, 0..) |*source, index| {
        if (index % 2 == 0) {
            _ = try set.add(.tls);
        } else {
            try queueBytes(try set.add(.plain), "x");
        }
        source.* = set.source(index, deadline_mono_ns);
        source.want_write = true;
    }

    // Every send reached the kernel: each wire is reported once, writable.
    for (0..wire_count) |_| {
        switch (try driver.wait(sources, null)) {
            .ready => |ready| {
                try set.noteReport(ready.context);
                try std.testing.expect(ready.writable);
            },
            .failed, .expired, .wake, .tick => return error.ExpectedMixedSourceReadiness,
        }
    }
}

// An expired deadline preempts ingestion. A completion backlog larger than
// one wait pass ingests (`max_ingest_batches_per_drain` batches of
// `max_cqes_per_copy` in bio_data.zig) must not delay the expiry the caller
// is owed, and the unread completions stay in the CQ for the passes that
// follow, where each wire's receive and send coalesce into one result.
test "egress data io serves an expired deadline before draining a completion backlog" {
    var driver = try initDriver();
    defer driver.deinit();

    const wire_count = 300;
    var set = try WireSet.init(wire_count);
    defer set.deinit(&driver);
    const sources = try std.testing.allocator.alloc(data_io.Source, wire_count + 1);
    defer std.testing.allocator.free(sources);
    const deadline_mono_ns = try deadlineAfterMs(10_000);
    for (sources[0..wire_count], 0..) |*source, index| {
        _ = try set.add(.plain);
        source.* = set.source(index, deadline_mono_ns);
    }

    // Park every wire's receive: the gate expires while they stay in the
    // kernel.
    var gate_context: u8 = 0;
    sources[wire_count] = .{
        .context = &gate_context,
        .deadline_mono_ns = try deadlineAfterMs(20),
    };
    try expectExpired(&gate_context, try driver.wait(sources, null));

    // Complete every receive and leave its completion unread, then queue one
    // byte on every wire for the next pass to send. The sleep loop gives the
    // kernel's completion task work time to post every receive.
    for (set.wires[0..wire_count], set.peers[0..wire_count]) |wire, peer| {
        _ = try std.posix.write(peer, "r");
        try queueBytes(wire, "s");
    }
    var tries: usize = 0;
    while (driver.ring.cq_ready() < wire_count and tries < 2_000) : (tries += 1)
        std.Thread.sleep(std.time.ns_per_ms);
    const backlog = driver.ring.cq_ready();
    try std.testing.expect(backlog >= wire_count);

    // An already expired deadline-only source outranks the whole backlog, so
    // the pass ingests nothing. It still arms the queued sends before
    // serving, and their completions join the backlog.
    var expired_context: u8 = 0;
    sources[wire_count] = .{
        .context = &expired_context,
        .deadline_mono_ns = try monotonicNowNs(),
    };
    try expectExpired(&expired_context, try driver.wait(sources, null));
    try std.testing.expect(driver.ring.cq_ready() >= backlog + wire_count);

    // The preemption lost nothing. The first serving pass ingests every
    // receive and the earliest sends, and the second ingests the rest before
    // any later wire is served, so every wire is reported once, readable and
    // writable, and then the gate expires.
    for (0..wire_count) |_| {
        switch (try driver.wait(sources[0..wire_count], null)) {
            .ready => |ready| {
                try set.noteReport(ready.context);
                try std.testing.expect(ready.readable);
                try std.testing.expect(ready.writable);
            },
            .failed, .expired, .wake, .tick => return error.ExpectedBacklogReadiness,
        }
    }
    sources[wire_count] = .{
        .context = &gate_context,
        .deadline_mono_ns = try deadlineAfterMs(20),
    };
    try expectExpired(&gate_context, try driver.wait(sources, null));
}

test "egress data io reports an in-progress connect ready once it ends" {
    var driver = try initDriver();
    defer driver.deinit();
    var listener = try loopbackListener();
    defer listener.deinit();

    const started = try transport.connect.startAttempt(listener.listen_address);
    defer std.posix.close(started.fd);
    defer driver.cancelConnecting(started.fd);
    // Linux answers a nonblocking TCP connect with EINPROGRESS even over
    // loopback.
    try std.testing.expect(!started.connected);

    var context: u8 = 0;
    const ready = try expectReady(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .connecting = started.fd },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    }}, null));
    try std.testing.expect(ready.writable);
    try transport.connect.finishAttempt(started.fd);
}

test "egress data io reports a refused connect ready and leaves its error to finishAttempt" {
    var driver = try initDriver();
    defer driver.deinit();

    const started = try transport.connect.startAttempt(try closedLoopbackAddress());
    defer std.posix.close(started.fd);
    defer driver.cancelConnecting(started.fd);
    try std.testing.expect(!started.connected);

    var context: u8 = 0;
    const ready = try expectReady(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .connecting = started.fd },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    }}, null));
    try std.testing.expect(ready.writable);
    try std.testing.expectError(
        error.ConnectionRefused,
        transport.connect.finishAttempt(started.fd),
    );
}

// The owner cancels a watch before it closes an abandoned attempt, and the
// next dial may reuse the fd number. The cancelled poll's readiness must
// never reach the watch on the reused number, and the driver must keep
// serving new watches.
test "egress data io cancelConnecting ends a connect watch whose poll has not fired" {
    var driver = try initDriver();
    defer driver.deinit();

    const watched = try socketPair();
    defer std.posix.close(watched[0]);
    defer std.posix.close(watched[1]);
    try fillSendBuffer(watched[0]);

    // Arm the poll on the unwritable socket; the wait expires while the poll
    // stays in the kernel.
    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .connecting = watched[0] },
        .deadline_mono_ns = try deadlineAfterMs(30),
    }}, null));
    driver.cancelConnecting(watched[0]);

    // The cancelled socket turns writable, then its fd number comes to name
    // another unwritable socket. A watch on that number starts fresh, so
    // only the deadline-only gate can end the wait.
    _ = try drainSocket(watched[1]);
    const reused = try socketPair();
    defer std.posix.close(reused[0]);
    defer std.posix.close(reused[1]);
    try fillSendBuffer(reused[0]);
    try std.posix.dup2(reused[0], watched[0]);
    defer driver.cancelConnecting(watched[0]);

    var reused_context: u8 = 0;
    var gate_context: u8 = 0;
    const gated = [_]data_io.Source{
        .{
            .context = &reused_context,
            .io = .{ .connecting = watched[0] },
            .deadline_mono_ns = try deadlineAfterMs(5_000),
        },
        .{
            .context = &gate_context,
            .deadline_mono_ns = try deadlineAfterMs(50),
        },
    };
    try expectExpired(&gate_context, try driver.wait(&gated, null));

    var listener = try loopbackListener();
    defer listener.deinit();
    const started = try transport.connect.startAttempt(listener.listen_address);
    defer std.posix.close(started.fd);
    defer driver.cancelConnecting(started.fd);
    var fresh_context: u8 = 0;
    const ready = try expectReady(&fresh_context, try driver.wait(&.{.{
        .context = &fresh_context,
        .io = .{ .connecting = started.fd },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    }}, null));
    try std.testing.expect(ready.writable);
    try transport.connect.finishAttempt(started.fd);
}

test "egress data io reports a connect poll once" {
    var driver = try initDriver();
    defer driver.deinit();
    var listener = try loopbackListener();
    defer listener.deinit();

    const started = try transport.connect.startAttempt(listener.listen_address);
    defer std.posix.close(started.fd);
    defer driver.cancelConnecting(started.fd);

    var context: u8 = 0;
    const connecting: data_io.Source = .{
        .context = &context,
        .io = .{ .connecting = started.fd },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    };
    const ready = try expectReady(&context, try driver.wait(&.{connecting}, null));
    try std.testing.expect(ready.writable);

    // The socket stays writable, so a second poll would complete at once;
    // the deadline-only gate expires instead.
    var gate_context: u8 = 0;
    const gated = [_]data_io.Source{ connecting, .{
        .context = &gate_context,
        .deadline_mono_ns = try deadlineAfterMs(50),
    } };
    try expectExpired(&gate_context, try driver.wait(&gated, null));
    try transport.connect.finishAttempt(started.fd);
}

// A cancel that meets a full SQ must flush the queued entries and retry, and
// the teardown may block on terminal CQEs only once the kernel confirmably
// owns the cancel; waiting on a cancel the kernel never received would park
// it forever against the silent peer.
test "egress data io cancels a parked connection through a full SQ without hanging" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    // Ownership follows the one cancel verdict below: an unconfirmed cancel
    // quarantines the wire to the driver. An unwind before the explicit
    // cancel still cancels exactly once through the defer, because a parked
    // recv references the wire's buffer and a wire the driver still
    // registers must never be deinited.
    var cancel_verdict: ?bool = null;
    defer {
        const wire_owned = cancel_verdict orelse driver.cancelConnectionForClose(wire);
        if (wire_owned) wire.deinit();
    }

    // Park a recv in flight against the silent peer.
    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(50),
    }}, null));

    // Fill the SQ with polls on an eventfd that never fires. Their user_data
    // carries no egress tag, so ingestion drops any stray completion. The
    // bound is the largest entry count an SQ can be created with.
    const dummy = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(dummy);
    var filled: usize = 0;
    while (filled < std.math.maxInt(u16)) : (filled += 1) {
        _ = driver.ring.poll_add(0, dummy, @intCast(std.posix.POLL.IN)) catch break;
    }
    try std.testing.expect(filled > 0);

    // The cancel must flush the full SQ, retry, drain its terminals and
    // return promptly; a confirmed cancel hands the wire back to the caller.
    // The verdict is recorded before the assertion so a failure neither
    // cancels twice nor deinits a quarantined wire.
    const cancel_confirmed = driver.cancelConnectionForClose(wire);
    cancel_verdict = cancel_confirmed;
    try std.testing.expect(cancel_confirmed);

    // The driver survives, and a fresh deadline-only wait still serves.
    var gate_context: u8 = 0;
    try expectExpired(&gate_context, try driver.wait(&.{.{
        .context = &gate_context,
        .deadline_mono_ns = try deadlineAfterMs(30),
    }}, null));
}

// A cancel left unconfirmed on a live ring, by transient EAGAIN through
// every flush retry, must not abandon the registration: the kernel still
// owns the original recv SQE, which references the wire's buffer. The
// driver quarantines the registration instead. The wire stays pinned and
// the driver takes ownership of it, the cancel is retried on later wait
// passes, and only after the terminal CQE is consumed, when the kernel no
// longer touches the buffer, are the registration released and the wire
// deinited.
test "egress data io quarantines an unconfirmed cancel on a live ring until terminals arrive" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    // Ownership follows the one cancel verdict below, as in the full-SQ test.
    var cancel_verdict: ?bool = null;
    defer {
        const wire_owned = cancel_verdict orelse driver.cancelConnectionForClose(wire);
        if (wire_owned) wire.deinit();
    }

    // Park a recv in flight against the silent peer, so the kernel owns a
    // recv SQE that reads into the wire's receive buffer.
    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(50),
    }}, null));
    try std.testing.expect(driver.registrations.items[0].recv_queued);

    // 32 injected EAGAIN-shaped failures outlast the cancel's flush and its
    // 16 bounded retries, so the cancel cannot be confirmed while the ring
    // stays live. Ownership passes to the driver; the caller must not
    // deinit.
    driver.test_flush_failures = 32;
    const cancel_confirmed = driver.cancelConnection(wire);
    cancel_verdict = cancel_confirmed;
    try std.testing.expect(!cancel_confirmed);

    // Nothing was abandoned: the quarantined registration still tracks the
    // kernel-owned recv and pins the wire.
    const registration = driver.registrations.items[0];
    try std.testing.expect(registration.quarantined);
    try std.testing.expect(registration.recv_queued);
    try std.testing.expect(registration.target == .wire);
    driver.test_flush_failures = 0;

    // Later wait passes retry the cancel, consume the terminal CQE, and
    // release the registration, deiniting the pinned wire.
    var released = false;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        var gate_context: u8 = 0;
        switch (try driver.wait(&.{.{
            .context = &gate_context,
            .deadline_mono_ns = try deadlineAfterMs(20),
        }}, null)) {
            .expired, .tick => {},
            .ready, .failed, .wake => return error.UnexpectedQuarantineGateResult,
        }
        const slot = driver.registrations.items[0];
        const queued = slot.recv_queued or slot.send_queued;
        if (!slot.quarantined and !queued and slot.target == .none) {
            released = true;
            break;
        }
    }
    try std.testing.expect(released);

    // The driver stays healthy after the release.
    var after_context: u8 = 0;
    try expectExpired(&after_context, try driver.wait(&.{.{
        .context = &after_context,
        .deadline_mono_ns = try deadlineAfterMs(30),
    }}, null));
}

// When the ring's descriptor dies, the owner's teardown after the failed wait
// cancels every wire. No cancel can reach the kernel then, yet the io_uring
// instance lives on through its mappings with every receive still armed, so
// each cancel returns at once without draining and keeps the wire, whose
// buffer a late receive may still write, until `Driver.deinit` has torn the
// ring down.
test "egress data io keeps a wire with an armed receive until the ring is torn down when the ring's descriptor dies" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    // Ownership follows the one cancel verdict below. An unconfirmed cancel
    // (false) quarantines the wire, and the driver frees it in its final
    // sweep. An unwind before the explicit cancel must still cancel exactly
    // once, because a recv parked in the kernel may reference the wire's
    // buffer and the driver requires a cancel before deinit; the defer
    // issues that cancel when no verdict was recorded.
    var cancel_verdict: ?bool = null;
    defer {
        const wire_owned = cancel_verdict orelse driver.cancelConnection(wire);
        if (wire_owned) wire.deinit();
    }

    // Park a recv in flight; the wait expires while the silent socket's
    // one-shot recv stays queued in the kernel.
    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(50),
    }}, null));

    // Kill the ring under the driver: dup2 swaps an eventfd over the ring
    // fd, so every later enter fails at the ring level while the ring memory
    // and the in-flight recv stay alive through its mmaps.
    const fake = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(fake);
    try std.posix.dup2(fake, driver.ring.fd);

    // The wait discovers the dead ring and fails, which in the owner starts
    // the teardown.
    try std.testing.expectError(error.OpcodeNotSupported, driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    }}, null));
    try std.testing.expect(driver.ringDead());
    // The cancel returns promptly and hands the wire to the driver, which
    // frees it once the ring is gone; the testing allocator's leak check at
    // the end shows it did. The verdict is recorded before the assertion so
    // a failure neither cancels twice nor deinits a quarantined wire.
    const cancel_confirmed = driver.cancelConnection(wire);
    cancel_verdict = cancel_confirmed;
    try std.testing.expect(!cancel_confirmed);
    const registration = driver.registrations.items[0];
    try std.testing.expect(registration.quarantined);
    try std.testing.expect(registration.recv_queued);
    try std.testing.expect(registration.target == .wire);
}

// The receive a dead ring's cancel leaves armed still completes when the
// origin sends, and writes into the wire's buffer, which must still belong to
// the wire and not to whatever the allocator handed it to next.
test "egress data io keeps the wire whose armed receive takes a peer's bytes after a dead ring's cancel" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    var cancel_verdict: ?bool = null;
    defer {
        const wire_owned = cancel_verdict orelse driver.cancelConnection(wire);
        if (wire_owned) wire.deinit();
    }

    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(50),
    }}, null));

    const fake = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(fake);
    try std.posix.dup2(fake, driver.ring.fd);
    try std.testing.expectError(error.OpcodeNotSupported, driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(5_000),
    }}, null));
    try std.testing.expect(driver.ringDead());

    const cancel_confirmed = driver.cancelConnection(wire);
    cancel_verdict = cancel_confirmed;
    try std.testing.expect(!cancel_confirmed);

    // The origin's late bytes complete the armed receive into the wire's
    // buffer on this thread's next entry into the kernel, which each sleep
    // is, and the completion lands in the mapped completion queue.
    const late = "late bytes";
    _ = try std.posix.write(fds[1], late);
    try awaitPostedCompletion(&driver);
    try std.testing.expectEqualStrings(late, wire.recvBuffer()[0..late.len]);
    const registration = driver.registrations.items[0];
    try std.testing.expect(registration.quarantined);
    try std.testing.expect(registration.target == .wire);
}

// A live ring can fail the copy a cancel's terminal drain waits on with an
// error that says nothing about the ring itself, such as EAGAIN under memory
// pressure. The registration is quarantined until its terminals arrive, and
// the ring, which still delivers, is not marked dead.
test "egress data io quarantines a cancel whose terminal drain fails on a live ring and keeps the ring alive" {
    var driver = try initDriver();
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    var cancel_verdict: ?bool = null;
    defer {
        const wire_owned = cancel_verdict orelse driver.cancelConnection(wire);
        if (wire_owned) wire.deinit();
    }

    var context: u8 = 0;
    try expectExpired(&context, try driver.wait(&.{.{
        .context = &context,
        .io = .{ .wire = wire },
        .deadline_mono_ns = try deadlineAfterMs(50),
    }}, null));
    try std.testing.expect(driver.registrations.items[0].recv_queued);

    driver.test_drain_failures = 1;
    const cancel_confirmed = driver.cancelConnection(wire);
    cancel_verdict = cancel_confirmed;
    try std.testing.expect(!cancel_confirmed);
    try std.testing.expect(!driver.ringDead());
    try std.testing.expect(driver.registrations.items[0].quarantined);

    // The cancel reached the kernel, so later waits consume the receive's
    // terminal completion and release the registration with its wire.
    var released = false;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        var gate_context: u8 = 0;
        switch (try driver.wait(&.{.{
            .context = &gate_context,
            .deadline_mono_ns = try deadlineAfterMs(20),
        }}, null)) {
            .expired, .tick => {},
            .ready, .failed, .wake => return error.UnexpectedQuarantineGateResult,
        }
        const slot = driver.registrations.items[0];
        if (!slot.quarantined and slot.target == .none) {
            released = true;
            break;
        }
    }
    try std.testing.expect(released);
    try std.testing.expect(!driver.ringDead());
}
