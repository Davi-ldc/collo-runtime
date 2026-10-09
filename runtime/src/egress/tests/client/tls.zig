//! Tests of the egress TLS client on BoringSSL: the verified context loads,
//! the ALPN offer values match the shim's ABI, an end-to-end handshake
//! negotiates h2 and http/1.1, a socket connection reports a pending
//! handshake step instead of blocking, and a memory-BIO connection hands out
//! its handshake ciphertext without owning an fd.

const std = @import("std");
const tls = @import("collo_egress_client").tls;
const boring = @import("collo_boringssl");

const tls_shim = @import("collo_test_tls_shim");
const EgressAlpnResult = tls_shim.EgressAlpnResult;
const collo_test_egress_tls_alpn_end_to_end = tls_shim.collo_test_egress_tls_alpn_end_to_end;
const collo_test_tls_last_error = tls_shim.collo_test_tls_last_error;

test "egress TLS verified client context preloads through BoringSSL" {
    try tls.preloadVerifiedContext();
}

test "egress TLS ALPN offers preserve shim ABI" {
    try std.testing.expectEqual(boring.alpn_offer_http_1_1, @intFromEnum(tls.AlpnOffer.http_1_1));
    try std.testing.expectEqual(boring.alpn_offer_h2_http_1_1, @intFromEnum(tls.AlpnOffer.h2_http_1_1));
    try std.testing.expectEqual(boring.alpn_offer_h2_only, @intFromEnum(tls.AlpnOffer.h2_only));
}

test "egress TLS client negotiates h2 and http1 through ALPN" {
    var result: EgressAlpnResult = undefined;
    if (collo_test_egress_tls_alpn_end_to_end(&result) != 0) {
        std.debug.print("egress TLS/ALPN helper failed: {s}\n", .{std.mem.span(collo_test_tls_last_error())});
        return error.EgressTlsAlpnEndToEndFailed;
    }
    try std.testing.expectEqual(@as(c_int, boring.alpn_h2), result.h2_protocol);
    try std.testing.expectEqual(@as(c_int, boring.alpn_http_1_1), result.http11_protocol);
}

test "egress TLS exposes incremental handshake readiness" {
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

    const stream = std.net.Stream{ .handle = fds[0] };
    var connection = try tls.Connection.createUnhandshaken(
        std.testing.allocator,
        stream,
        "example.com",
        true,
        .h2_http_1_1,
        null,
    );
    defer connection.deinit();

    switch (try connection.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsHandshakeReadinessWait,
    }
}

test "egress TLS memory BIO emits handshake ciphertext without owning an fd" {
    var connection = try tls.BioConnection.createUnhandshaken(
        std.testing.allocator,
        "example.com",
        true,
        .h2_http_1_1,
        null,
    );
    defer connection.deinit();

    switch (try connection.handshakeStep()) {
        .wait => |interest| try std.testing.expectEqual(tls.IoInterest.read, interest),
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }

    const pending = try connection.pendingCiphertext();
    try std.testing.expect(pending > 0);

    var ciphertext: [16 * 1024]u8 = undefined;
    switch (try connection.drainCiphertext(&ciphertext)) {
        .ready => |drained| {
            try std.testing.expectEqual(pending, drained);
            try std.testing.expect(std.mem.indexOf(u8, ciphertext[0..drained], "h2") != null);
        },
        .wait, .eof => return error.ExpectedTlsBioCiphertext,
    }
    try std.testing.expectEqual(@as(usize, 0), try connection.pendingCiphertext());

    switch (try connection.drainCiphertext(&ciphertext)) {
        .wait => {},
        .ready, .eof => return error.ExpectedTlsBioEmptyDrainWait,
    }
}
