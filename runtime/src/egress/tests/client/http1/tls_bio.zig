//! Tests for the BIO TLS transport: its config surface and, over a
//! nonblocking socketpair whose peer never answers, handshake ciphertext
//! queueing, the pinned send buffer while the kernel owns a send, and the
//! ciphertext budget.

const std = @import("std");
const test_support = @import("support.zig");
const transport = test_support.transport;

test "egress TLS BIO transport exposes its local config surface" {
    const mode: transport.tls_bio.TlsRxMode = .memory_bio;
    try std.testing.expectEqual(transport.tls_bio.config.TlsRxMode.memory_bio, mode);
    const lease_queue = transport.tls_bio.lease_queue;
    _ = lease_queue;
}

test "egress BIO TLS transport queues handshake ciphertext for owner-driven send" {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer std.posix.close(fds[1]);

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer bio.deinit();

    switch (try bio.handshakeStep()) {
        .wait => |interest| try std.testing.expectEqual(transport.IoInterest.read, interest),
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }
    try std.testing.expect(bio.hasCiphertextToSend());
    const first = bio.sendCiphertextSlice();
    try std.testing.expect(first.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, first, "h2") != null);

    const partial = @min(first.len, 7);
    try bio.advanceSentCiphertext(partial);
    try std.testing.expectEqual(first.len - partial, bio.queuedCiphertextLen());
}

test "egress BIO TLS transport pins the send buffer while a send is in flight" {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer std.posix.close(fds[1]);

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer bio.deinit();

    switch (try bio.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }
    try std.testing.expect(bio.hasCiphertextToSend());

    // A partial send already completed (cursor != 0), and the driver armed a
    // new send over the remaining tail: the SQE captured this exact ptr/len.
    try bio.advanceSentCiphertext(7);
    const armed = bio.sendCiphertextSlice();
    const armed_copy = try std.testing.allocator.dupe(u8, armed);
    defer std.testing.allocator.free(armed_copy);
    bio.markSendSubmitted();

    // The owner keeps pumping TLS while the kernel owns those bytes; the
    // drain must neither move nor rewrite the armed region.
    try bio.flushOutgoing();
    const pumped = bio.sendCiphertextSlice();
    try std.testing.expect(pumped.ptr == armed.ptr);
    try std.testing.expect(pumped.len >= armed_copy.len);
    try std.testing.expectEqualSlices(u8, armed_copy, pumped[0..armed_copy.len]);

    // Terminal CQE: the completion releases the pin before the advance, which
    // may then compact or grow the buffer again.
    bio.markSendComplete();
    try bio.advanceSentCiphertext(armed_copy.len);
    try std.testing.expect(!bio.hasCiphertextToSend());
}

test "egress BIO TLS transport enforces ciphertext queue budget" {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer std.posix.close(fds[1]);

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        1,
        null,
    );
    defer bio.deinit();

    try std.testing.expectError(error.TlsCiphertextBufferExceeded, bio.handshakeStep());
    try std.testing.expect(bio.ciphertext_limit_hit);
    try std.testing.expect(bio.queuedCiphertextLen() <= 1);
}
