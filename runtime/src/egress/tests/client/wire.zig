//! Unit tests of `transport.Wire`, the one connection type of both
//! protocols: on a plain wire, unread bytes ahead of EOF, half-close after a
//! failed send, a failed receive, the cleanliness rule the pool trusts, and
//! the rule that the receive buffer takes no new receive until the protocol
//! read the last one; on a TLS wire, the handshake ciphertext queued for the
//! owner's send, the send queue held in place while a send is in flight, the
//! buffered-bytes budget, and the socket's EOF during and after the
//! handshake.
//!
//! Each test stands in for the data driver by copying a receive into
//! `recvBuffer()` and feeding it, or by marking a send submitted and
//! complete, over one end of a socketpair. A handshaken TLS wire talks to the
//! production server shim's handshake over the other end, the test moving
//! the bytes in turn on one thread. The driver's own receives and sends are
//! tested in data_io.zig, and exchanges over a wire in http1/streaming.zig
//! and http1/tls.zig.

const std = @import("std");
const boring = @import("collo_boringssl");
const transport = @import("collo_egress_client").transport;

const Wire = transport.Wire;

/// The buffering budget of the plain-wire tests, above anything they queue.
const max_buffered_bytes: usize = 64 * 1024;
/// Bound on the rounds of a test handshake, each moving every queued byte
/// both ways; a TLS 1.3 handshake needs three.
const max_handshake_rounds: usize = 32;
/// Room for the server certificate and key PEM the test generates.
const pem_buffer_bytes: usize = 4096;
/// The name the client sends and the test certificate names.
const server_name = "example.com";
/// The end of the test certificate's validity, the start of the year 2100.
/// The client skips verification, so any window serves, and a fixed one
/// keeps the clock out.
const certificate_not_after_unix_seconds: i64 = 4_102_444_800;
/// Bounds the nonblocking loops that move bytes through a socket.
const max_socket_chunks: usize = 4096;

fn socketPair() ![2]std.posix.fd_t {
    return socketPairWithFlags(0);
}

/// A socketpair whose ends are nonblocking, as the data driver's sockets are.
fn nonblockingSocketPair() ![2]std.posix.fd_t {
    return socketPairWithFlags(std.posix.SOCK.NONBLOCK);
}

fn socketPairWithFlags(flags: u32) ![2]std.posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | flags,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => return .{ fds[0], fds[1] },
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// A plain wire that takes `fd`, closing it on error.
fn createPlainWire(fd: std.posix.fd_t) !*Wire {
    return Wire.createPlain(std.testing.allocator, .{ .handle = fd }, max_buffered_bytes);
}

/// An unhandshaken TLS wire that offers h2 and http/1.1 and takes `fd`,
/// closing it on error.
fn createTlsWire(fd: std.posix.fd_t, budget_bytes: usize) !*Wire {
    return Wire.createTls(std.testing.allocator, .{ .handle = fd }, .{
        .server_name = server_name,
        .insecure_tls = true,
        .session_key = null,
    }, budget_bytes);
}

/// The server end of a test handshake: the production server shim's context
/// over a certificate generated for `server_name`, and its connection on a
/// nonblocking socket the test owns. It offers TLS 1.3 alone and selects h2,
/// which every test wire offers.
const TlsServerPeer = struct {
    context: *boring.ContextHandle,
    connection: ?*boring.Handle,

    fn init(fd: std.posix.fd_t) !TlsServerPeer {
        var cert_pem: [pem_buffer_bytes]u8 = undefined;
        var key_pem: [pem_buffer_bytes]u8 = undefined;
        var cert_len: usize = 0;
        var key_len: usize = 0;
        const names = [_]boring.SubjectAltName{.{
            .value = server_name.ptr,
            .value_len = server_name.len,
            .kind = boring.subject_alt_name_dns,
            .reserved0 = @splat(0),
        }};
        if (boring.collo_boringssl_self_signed_generate(
            &names,
            names.len,
            0,
            certificate_not_after_unix_seconds,
            &cert_pem,
            cert_pem.len,
            &cert_len,
            &key_pem,
            key_pem.len,
            &key_len,
        ) != 0)
            return error.TestCertificateGenerationFailed;
        var context: ?*boring.ContextHandle = null;
        if (boring.collo_boringssl_ctx_new_pem_ex(
            &cert_pem,
            cert_len,
            &key_pem,
            key_len,
            null,
            boring.tls13_policy_all_supported,
            &context,
        ) != 0)
            return error.TestServerContextFailed;
        const owned_context = context orelse return error.TestServerContextFailed;
        errdefer boring.collo_boringssl_ctx_free(owned_context);
        var connection: ?*boring.Handle = null;
        if (boring.collo_boringssl_conn_new(owned_context, fd, &connection) != 0)
            return error.TestServerConnectionFailed;
        return .{
            .context = owned_context,
            .connection = connection orelse return error.TestServerConnectionFailed,
        };
    }

    fn deinit(self: *TlsServerPeer) void {
        self.dropConnection();
        boring.collo_boringssl_ctx_free(self.context);
        self.* = undefined;
    }

    /// One handshake step on the server's socket; true once the server
    /// finished its handshake.
    fn step(self: *TlsServerPeer) !bool {
        var raw = std.mem.zeroes(boring.RawResult);
        if (boring.collo_boringssl_handshake_step(self.connection.?, &raw) != 0)
            return error.TestServerHandshakeFailed;
        return switch (raw.status) {
            boring.status_ok => true,
            boring.status_want_read, boring.status_want_write => false,
            else => error.TestServerHandshakeFailed,
        };
    }

    /// Frees the server's connection without a close_notify: freeing writes
    /// nothing to the socket.
    fn dropConnection(self: *TlsServerPeer) void {
        if (self.connection) |connection|
            boring.collo_boringssl_conn_free(connection);
        self.connection = null;
    }
};

/// Runs a TLS handshake between `wire` and `server`, moving what each side
/// queued over the socketpair between them in turn.
fn handshakeWithServer(wire: *Wire, server: *TlsServerPeer) !void {
    var client_done = false;
    var server_done = false;
    for (0..max_handshake_rounds) |_| {
        if (!client_done) {
            switch (try wire.handshakeStep()) {
                .done => client_done = true,
                .wait => {},
            }
        }
        try sendQueued(wire);
        if (!server_done)
            server_done = try server.step();
        _ = try receiveAvailable(wire);
        if (client_done and server_done)
            return;
    }
    return error.TestHandshakeRunaway;
}

/// Stands in for the driver's sends on a nonblocking socket: writes what the
/// wire queued.
fn sendQueued(wire: *Wire) !void {
    for (0..max_socket_chunks) |_| {
        if (!wire.hasBytesToSend())
            return;
        const written = try std.posix.write(wire.fd(), wire.sendSlice());
        try wire.advanceSent(written);
    }
    return error.TestSocketNeverDrained;
}

/// Stands in for the driver's receives on a nonblocking socket: feeds the
/// wire what its socket holds, then the socket's EOF if the peer closed, a
/// reset reading as EOF as in the driver. Returns whether it fed EOF.
fn receiveAvailable(wire: *Wire) !bool {
    for (0..max_socket_chunks) |_| {
        const received = std.posix.read(wire.fd(), wire.recvBuffer()) catch |err| switch (err) {
            error.WouldBlock => return false,
            error.ConnectionResetByPeer => 0,
            else => |other| return other,
        };
        try wire.feedReceived(received);
        if (received == 0)
            return true;
    }
    return error.TestSocketNeverDrained;
}

/// Stands in for a completed receive: `bytes` land in the receive buffer
/// and the wire takes them.
fn feed(wire: *Wire, bytes: []const u8) !void {
    @memcpy(wire.recvBuffer()[0..bytes.len], bytes);
    try wire.feedReceived(bytes.len);
}

fn expectRead(wire: *Wire, expected: []const u8) !void {
    var dest: [64]u8 = undefined;
    switch (try wire.readStep(dest[0..expected.len])) {
        .ready => |len| try std.testing.expectEqualStrings(expected, dest[0..len]),
        .wait, .eof => return error.ExpectedWireBytes,
    }
}

fn expectReadStep(wire: *Wire, expected: std.meta.Tag(transport.IoStep)) !void {
    var dest: [64]u8 = undefined;
    try std.testing.expectEqual(expected, std.meta.activeTag(try wire.readStep(&dest)));
}

fn expectWriteTaken(wire: *Wire, bytes: []const u8) !void {
    switch (try wire.writeStep(bytes)) {
        .ready => |len| try std.testing.expectEqual(bytes.len, len),
        .wait, .eof => return error.ExpectedWireWrite,
    }
}

test "a plain wire hands out its unread bytes before it reports EOF" {
    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer wire.deinit();

    try feed(wire, "abc");
    try wire.feedReceived(0);
    try std.testing.expect(!wire.networkWantsRead());
    try std.testing.expect(!wire.cleanForReuse());

    try expectRead(wire, "abc");
    try expectReadStep(wire, .eof);
    // EOF is sticky: no receive is asked for again, and the wire never
    // becomes reusable.
    try expectReadStep(wire, .eof);
    try std.testing.expect(!wire.networkWantsRead());
    try std.testing.expect(!wire.cleanForReuse());
}

test "a half-closed wire discards what it sends and keeps reading what arrived" {
    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer wire.deinit();

    try expectWriteTaken(wire, "request");
    try std.testing.expect(wire.hasBytesToSend());
    // The peer's answer arrived before the send failed.
    try feed(wire, "response");

    wire.markSendBroken();
    try std.testing.expect(!wire.hasBytesToSend());
    try std.testing.expect(!wire.networkWantsWrite());
    // Later writes are taken and dropped, so the protocol above runs on to
    // the read that reports what the peer sent.
    try expectWriteTaken(wire, "more");
    try std.testing.expect(!wire.hasBytesToSend());

    try expectRead(wire, "response");
    // Nothing unread and no EOF: the broken send alone keeps the wire out
    // of the pool.
    try std.testing.expect(!wire.cleanForReuse());
}

test "a wire whose receive failed asks for no other receive and is never clean again" {
    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer wire.deinit();

    try feed(wire, "ab");
    wire.markReceiveFailed();
    // What arrived before the failure stays readable.
    try expectRead(wire, "ab");
    try std.testing.expect(!wire.networkWantsRead());
    try std.testing.expect(!wire.cleanForReuse());
}

test "a plain wire holding an unread byte is not clean for reuse" {
    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer wire.deinit();

    try std.testing.expect(wire.cleanForReuse());
    try feed(wire, "x");
    try std.testing.expect(!wire.cleanForReuse());
    try expectRead(wire, "x");
    try std.testing.expect(wire.cleanForReuse());
}

test "a plain wire asks for no receive until the protocol read the last one" {
    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createPlainWire(fds[0]);
    defer wire.deinit();

    try std.testing.expect(wire.networkWantsRead());
    try expectReadStep(wire, .wait);
    wire.markRecvSubmitted();
    try std.testing.expect(!wire.networkWantsRead());
    wire.markRecvComplete();

    // The kernel writes the next receive into the same buffer, so the wire
    // asks for it only once the protocol took every byte of this one.
    try feed(wire, "abcd");
    try std.testing.expect(!wire.networkWantsRead());
    try expectRead(wire, "ab");
    try std.testing.expect(!wire.networkWantsRead());
    try expectRead(wire, "cd");
    try std.testing.expect(wire.networkWantsRead());
    try expectReadStep(wire, .wait);
}

test "a TLS wire queues its handshake ciphertext for the owner's send" {
    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createTlsWire(fds[0], max_buffered_bytes);
    defer wire.deinit();

    switch (try wire.handshakeStep()) {
        .wait => |interest| try std.testing.expectEqual(transport.IoInterest.read, interest),
        .done => return error.ExpectedTlsHandshakeWait,
    }
    try std.testing.expect(wire.hasBytesToSend());
    try std.testing.expect(wire.networkWantsWrite());
    const hello = wire.sendSlice();
    try std.testing.expect(std.mem.indexOf(u8, hello, "h2") != null);

    // A partial send drops exactly what went out.
    const hello_len = hello.len;
    const sent = @min(hello_len, 7);
    try wire.advanceSent(sent);
    try std.testing.expectEqual(hello_len - sent, wire.sendSlice().len);
}

test "a TLS wire keeps its send queue in place while a send is in flight" {
    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createTlsWire(fds[0], max_buffered_bytes);
    defer wire.deinit();

    switch (try wire.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsHandshakeWait,
    }

    // After a partial send the driver arms a send over the rest: the kernel
    // reads exactly this memory until the completion.
    try wire.advanceSent(7);
    const armed = wire.sendSlice();
    const armed_copy = try std.testing.allocator.dupe(u8, armed);
    defer std.testing.allocator.free(armed_copy);
    wire.markSendSubmitted();
    try std.testing.expect(!wire.networkWantsWrite());

    // The owner keeps pumping TLS meanwhile; the queue neither moves nor
    // rewrites the armed bytes.
    try wire.flushOutgoing();
    const pumped = wire.sendSlice();
    try std.testing.expect(pumped.ptr == armed.ptr);
    try std.testing.expect(pumped.len >= armed_copy.len);
    try std.testing.expectEqualSlices(u8, armed_copy, pumped[0..armed_copy.len]);

    // The completion releases the pin before the advance.
    wire.markSendComplete();
    try wire.advanceSent(armed_copy.len);
    try std.testing.expect(!wire.hasBytesToSend());
}

test "a TLS wire refuses ciphertext past its buffered-bytes budget" {
    const fds = try socketPair();
    defer std.posix.close(fds[1]);
    const wire = try createTlsWire(fds[0], 1);
    defer wire.deinit();

    try std.testing.expectError(error.WireBufferExceeded, wire.handshakeStep());
    try std.testing.expect(wire.sendSlice().len <= 1);
}

// No handshake record can arrive after the socket's EOF, so the handshake
// fails at once instead of waiting out the dial's stall deadline.
test "a TLS wire whose peer closes during the handshake fails the handshake instead of waiting for a read" {
    const fds = try nonblockingSocketPair();
    const wire = try createTlsWire(fds[0], max_buffered_bytes);
    defer wire.deinit();

    switch (try wire.handshakeStep()) {
        .wait => |interest| try std.testing.expectEqual(transport.IoInterest.read, interest),
        .done => return error.ExpectedTlsHandshakeWait,
    }
    // The peer goes away before it answers the ClientHello.
    std.posix.close(fds[1]);
    try std.testing.expect(try receiveAvailable(wire));
    try std.testing.expectError(error.TlsHandshakeFailed, wire.handshakeStep());
}

// Many servers close without a close_notify. After the socket's EOF the
// stream ends where the received bytes end, as on a plain wire, so a
// pooled HTTPS wire that dies before a response reads as EOF and the
// request can replay.
test "a handshaken TLS wire reports EOF once its peer closes without a close_notify" {
    const fds = try nonblockingSocketPair();
    var server_fd_open = true;
    defer if (server_fd_open) std.posix.close(fds[1]);
    const wire = try createTlsWire(fds[0], max_buffered_bytes);
    defer wire.deinit();
    var server = try TlsServerPeer.init(fds[1]);
    defer server.deinit();

    try handshakeWithServer(wire, &server);
    // Session tickets sent after the handshake carry no plaintext.
    try std.testing.expect(!try receiveAvailable(wire));
    try expectReadStep(wire, .wait);
    try std.testing.expect(wire.cleanForReuse());

    server.dropConnection();
    std.posix.close(fds[1]);
    server_fd_open = false;
    try std.testing.expect(try receiveAvailable(wire));
    try expectReadStep(wire, .eof);
    try std.testing.expect(!wire.networkWantsRead());
    try std.testing.expect(!wire.cleanForReuse());
}
