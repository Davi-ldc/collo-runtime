//! Tests of the egress TLS client on BoringSSL: the verified context loads,
//! the ALPN offer values match the shim's ABI, an end-to-end handshake
//! negotiates h2 and http/1.1, a memory-BIO connection hands out its
//! handshake ciphertext without owning an fd and offers only what its offer
//! names, and the session key carries cell, policy, host and port. The wire
//! that holds a connection is covered by `wire.zig`.

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
            try std.testing.expectEqualStrings("\x02h2\x08http/1.1", try clientHelloAlpn(ciphertext[0..drained]));
        },
        .wait, .eof => return error.ExpectedTlsBioCiphertext,
    }
    try std.testing.expectEqual(@as(usize, 0), try connection.pendingCiphertext());

    switch (try connection.drainCiphertext(&ciphertext)) {
        .wait => {},
        .ready, .eof => return error.ExpectedTlsBioEmptyDrainWait,
    }
}

test "an http/1.1-only offer leaves h2 out of the client hello" {
    var connection = try tls.BioConnection.createUnhandshaken(
        std.testing.allocator,
        "example.com",
        true,
        .http_1_1,
        null,
    );
    defer connection.deinit();
    _ = try connection.handshakeStep();

    var ciphertext: [16 * 1024]u8 = undefined;
    switch (try connection.drainCiphertext(&ciphertext)) {
        .ready => |drained| try std.testing.expectEqualStrings("\x08http/1.1", try clientHelloAlpn(ciphertext[0..drained])),
        .wait, .eof => return error.ExpectedTlsBioCiphertext,
    }
}

const record_type_handshake: u8 = 22;
const handshake_type_client_hello: u8 = 1;
const extension_type_alpn: u16 = 16;

/// The protocol name list of the ALPN extension (RFC 7301 §3.1), each name
/// after its one-byte length, from `record`, a TLS record that holds a
/// whole ClientHello (RFC 8446 §4.1.2). The hello's random, session id and
/// key shares are random bytes, so only the extension's own bytes can say
/// what the client offered.
fn clientHelloAlpn(record: []const u8) ![]const u8 {
    var record_reader: std.Io.Reader = .fixed(record);
    if (try record_reader.takeByte() != record_type_handshake)
        return error.ExpectedHandshakeRecord;
    try record_reader.discardAll(2); // legacy_record_version
    var handshake: std.Io.Reader = .fixed(try record_reader.take(try record_reader.takeInt(u16, .big)));
    if (try handshake.takeByte() != handshake_type_client_hello)
        return error.ExpectedClientHello;
    var hello: std.Io.Reader = .fixed(try handshake.take(try handshake.takeInt(u24, .big)));
    try hello.discardAll(2 + 32); // legacy_version, random
    try hello.discardAll(try hello.takeByte()); // legacy_session_id
    try hello.discardAll(try hello.takeInt(u16, .big)); // cipher_suites
    try hello.discardAll(try hello.takeByte()); // legacy_compression_methods
    var extensions: std.Io.Reader = .fixed(try hello.take(try hello.takeInt(u16, .big)));
    while (extensions.bufferedLen() != 0) {
        const extension_type = try extensions.takeInt(u16, .big);
        const data = try extensions.take(try extensions.takeInt(u16, .big));
        if (extension_type != extension_type_alpn)
            continue;
        var alpn: std.Io.Reader = .fixed(data);
        const names = try alpn.take(try alpn.takeInt(u16, .big));
        if (alpn.bufferedLen() != 0)
            return error.MalformedAlpnExtension;
        return names;
    }
    return error.ExpectedAlpnExtension;
}

test "a TLS session key names the cell, the policy, the lowercased host and the port" {
    var buffer: [tls.max_session_key_bytes]u8 = undefined;
    const cell = [_]u8{0x11} ** 16;
    const policy = [_]u8{0x22} ** 16;
    const key = tls.buildSessionKey(&buffer, cell, policy, "Example.COM", 8443).?;

    try std.testing.expectEqual(@as(usize, 16 + 16 + "example.com".len + 2), key.len);
    try std.testing.expectEqualSlices(u8, &cell, key[0..16]);
    try std.testing.expectEqualSlices(u8, &policy, key[16..32]);
    try std.testing.expectEqualStrings("example.com", key[32 .. key.len - 2]);
    try std.testing.expectEqual(@as(u16, 8443), std.mem.readInt(u16, key[key.len - 2 ..][0..2], .big));

    // Another policy cell keys another ticket.
    var other_buffer: [tls.max_session_key_bytes]u8 = undefined;
    const other = tls.buildSessionKey(&other_buffer, cell, [_]u8{0x33} ** 16, "example.com", 8443).?;
    try std.testing.expect(!std.mem.eql(u8, key, other));

    try std.testing.expect(tls.buildSessionKey(&buffer, cell, policy, "", 443) == null);
    try std.testing.expect(tls.buildSessionKey(&buffer, cell, policy, "a" ** 254, 443) == null);
}
