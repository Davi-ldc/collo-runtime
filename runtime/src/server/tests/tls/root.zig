//! The server's TLS layer (`server/tls/root.zig` and `server/tls/ktls.zig`): a
//! BoringSSL context that refuses missing certificate files, ALPN that must
//! settle on h2, the handshakes the restricted TLS 1.3 policies still
//! complete, the negotiation policy the kernel's kTLS ciphers select, the
//! classes of negotiated cipher suites, when a worker may write to a client
//! connection directly, and exported key material turned into kTLS state and
//! zeroed. The handshakes run in process through the TLS test shim
//! (`runtime/tests/support/tls/tls_shim.cc`), whose h2 client drives the
//! server in `local-e2e`; one test checks that client's request encoding
//! against the server's HPACK decoder. Lane `server-core-test`.

const std = @import("std");
const server_main = @import("collo_server_main");
const tls = server_main.tls;
const ktls = server_main.ktls_mod;
const boring = tls.boringssl;

const BoringSslContextHandle = boring.ContextHandle;
const KtlsNegotiationPolicy = tls.KtlsNegotiationPolicy;
const Tls13Policy = tls.Tls13Policy;
const ktlsKeyMaterialToInitialState = tls.ktlsKeyMaterialToInitialState;
const requireIngressH2Alpn = tls.requireIngressH2Alpn;
const tls12_cipher_list_aes_128 = tls.tls12_cipher_list_aes_128;
const tls12_cipher_list_all = tls.tls12_cipher_list_all;

const hpack = @import("collo_hpack");
const routes = @import("collo_server_routes");
const h2_request = server_main.http2.request_head;

const tls_shim = @import("collo_test_tls_shim");
const TlsAlpnResult = tls_shim.TlsAlpnResult;
const TlsPolicyResult = tls_shim.TlsPolicyResult;
const collo_test_tls_alpn_end_to_end = tls_shim.collo_test_tls_alpn_end_to_end;
const collo_test_tls_policy_end_to_end = tls_shim.collo_test_tls_policy_end_to_end;
const collo_test_tls_last_error = tls_shim.collo_test_tls_last_error;
const collo_test_h2_request_header_block = tls_shim.collo_test_h2_request_header_block;

test "BoringSSL C context rejects missing certificate files when linked" {
    var handle: ?*BoringSslContextHandle = null;
    try std.testing.expect(boring.collo_boringssl_ctx_new(
        "/definitely/missing/origin.pem",
        "/definitely/missing/origin.key",
        &handle,
    ) != 0);
    try std.testing.expect(handle == null);
    try std.testing.expect(std.mem.indexOf(u8, boring.lastErrorSlice(), "load certificate chain") != null);
}

/// Encodes a GET of `path` with the test client and checks that the server's
/// HPACK decoder and request-head parser read the same path back.
fn expectClientRequestPathDecodes(path: [:0]const u8) !void {
    var block: [512]u8 = undefined;
    var block_len: u64 = 0;
    if (collo_test_h2_request_header_block("GET", path.ptr, &block, block.len, &block_len) != 0) {
        std.debug.print("encoding a {d}-byte path failed: {s}\n", .{ path.len, std.mem.span(collo_test_tls_last_error()) });
        return error.H2RequestHeaderBlockFailed;
    }
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(std.testing.allocator, block[0..@intCast(block_len)], h2_request.max_header_count, 16 * 1024);
    defer decoded.deinit(std.testing.allocator);
    const parsed = try h2_request.parse(decoded.headers, true);
    try std.testing.expectEqualStrings(path, parsed.path);
}

test "the test h2 client encodes request paths past one HPACK length byte" {
    // A string length below 127 fits the 7-bit prefix of its first byte;
    // from 127 on it continues in further bytes.
    for ([_]usize{ 126, 127, 128, 400 }) |len| {
        const path = try std.testing.allocator.allocSentinel(u8, len, 0);
        defer std.testing.allocator.free(path);
        @memset(path, 'a');
        path[0] = '/';
        try expectClientRequestPathDecodes(path);
    }
    // The path local-e2e sends to reach `error.PathTooDeep`.
    try expectClientRequestPathDecodes("/a" ** (routes.table.path_segments_max + 1));
}

test "TLS ALPN negotiates h2 for the HTTP/2 server path" {
    var result: TlsAlpnResult = undefined;
    if (collo_test_tls_alpn_end_to_end(&result) != 0) {
        std.debug.print("TLS/ALPN test helper failed: {s}\n", .{std.mem.span(collo_test_tls_last_error())});
        return error.TlsAlpnEndToEndFailed;
    }

    try std.testing.expectEqual(@as(c_int, @intCast(boring.alpn_h2)), result.h2_protocol);
    try std.testing.expectEqual(@as(c_int, @intCast(boring.alpn_unspecified)), result.http11_protocol);
    try std.testing.expectEqual(@as(c_int, @intCast(boring.alpn_unspecified)), result.unsupported_protocol);
}

test "BoringSSL server completes handshakes under the restricted kTLS TLS 1.3 policies" {
    var result: TlsPolicyResult = undefined;
    if (collo_test_tls_policy_end_to_end(&result) != 0) {
        std.debug.print("TLS policy test helper failed: {s}\n", .{std.mem.span(collo_test_tls_last_error())});
        return error.TlsPolicyEndToEndFailed;
    }

    try std.testing.expectEqual(@as(c_int, ktls.tls_1_3_version), result.aes_gcm_only_tls_version);
    try std.testing.expectEqual(@as(c_int, ktls.tls_1_2_version), result.tls13_disabled_tls_version);
    try std.testing.expectEqual(@as(c_int, 1), result.tls13_policy_cipher_flags_ok);
}

test "ingress TLS requires negotiated h2 ALPN" {
    try requireIngressH2Alpn(boring.alpn_h2);
    try std.testing.expectError(
        error.UnsupportedApplicationProtocol,
        requireIngressH2Alpn(boring.alpn_http_1_1),
    );
    try std.testing.expectError(
        error.UnsupportedApplicationProtocol,
        requireIngressH2Alpn(boring.alpn_unspecified),
    );
}

test "kTLS negotiation policy keeps broad TLS 1.3 when kernel supports every general cipher" {
    const policy = try KtlsNegotiationPolicy.fromCapabilities(ktls.KernelCapabilities.allKnown());
    try std.testing.expectEqual(Tls13Policy.all_supported, policy.tls13_policy);
    try std.testing.expectEqualStrings(tls12_cipher_list_all, policy.tls12_cipher_list);
}

test "kTLS transport requires both RX and TX for direct worker writes" {
    try std.testing.expect(ktls.directWorkerWriteAllowed(false, false, false));
    try std.testing.expect(!ktls.directWorkerWriteAllowed(true, true, false));
    try std.testing.expect(!ktls.directWorkerWriteAllowed(true, false, true));
    try std.testing.expect(ktls.directWorkerWriteAllowed(true, true, true));
}

test "kTLS kernel adapter without exported secrets is unsupported" {
    try std.testing.expect(!try ktls.Adapter.kernelWithoutSecrets().enableRxTx(-1));
}

test "kTLS TLS 1.2 AES-GCM cipher suites map to classes" {
    try std.testing.expectEqual(
        ktls.Tls12CipherClass.aes_gcm_128,
        try ktls.classifyTls12Handshake(ktls.tls_1_2_version, ktls.tls12_ecdhe_rsa_aes_128_gcm_sha256),
    );
    try std.testing.expectEqual(
        ktls.Tls12CipherClass.aes_gcm_128,
        try ktls.classifyTls12Handshake(ktls.tls_1_2_version, ktls.tls12_ecdhe_ecdsa_aes_128_gcm_sha256),
    );
    try std.testing.expectEqual(
        ktls.Tls12CipherClass.aes_gcm_256,
        try ktls.classifyTls12Handshake(ktls.tls_1_2_version, ktls.tls12_ecdhe_rsa_aes_256_gcm_sha384),
    );
    try std.testing.expectEqual(
        ktls.Tls12CipherClass.aes_gcm_256,
        try ktls.classifyTls12Handshake(ktls.tls_1_2_version, ktls.tls12_ecdhe_ecdsa_aes_256_gcm_sha384),
    );
}

test "kTLS TLS 1.3 cipher suites map to classes" {
    try std.testing.expectEqual(
        ktls.TlsCipherClass.tls13_aes_gcm_128,
        try ktls.classifyTls13Handshake(ktls.tls_1_3_version, ktls.tls13_aes_128_gcm_sha256),
    );
    try std.testing.expectEqual(
        ktls.TlsCipherClass.tls13_aes_gcm_256,
        try ktls.classifyTls13Handshake(ktls.tls_1_3_version, ktls.tls13_aes_256_gcm_sha384),
    );
    try std.testing.expectEqual(
        ktls.TlsCipherClass.tls13_chacha20_poly1305,
        try ktls.classifyTls13Handshake(ktls.tls_1_3_version, ktls.tls13_chacha20_poly1305_sha256),
    );
}

test "kTLS capability set classifies negotiated handshakes" {
    const full = ktls.KernelCapabilities.allKnown();
    try std.testing.expect(full.supportsHandshake(ktls.tls_1_3_version, ktls.tls13_chacha20_poly1305_sha256));

    const aes_only = ktls.KernelCapabilities{
        .tls12_aes_gcm_128 = true,
        .tls12_aes_gcm_256 = true,
        .tls13_aes_gcm_128 = true,
        .tls13_aes_gcm_256 = true,
    };
    try std.testing.expect(aes_only.supportsTls13AesGcm());
    try std.testing.expect(!aes_only.supportsFullTls13());
    try std.testing.expect(!aes_only.supportsHandshake(ktls.tls_1_3_version, ktls.tls13_chacha20_poly1305_sha256));
}

test "kTLS negotiation policy falls back to AES-GCM-only TLS 1.3 when ChaCha is missing" {
    const policy = try KtlsNegotiationPolicy.fromCapabilities(.{
        .tls12_aes_gcm_128 = true,
        .tls12_aes_gcm_256 = true,
        .tls13_aes_gcm_128 = true,
        .tls13_aes_gcm_256 = true,
        .tls13_chacha20_poly1305 = false,
    });
    try std.testing.expectEqual(Tls13Policy.aes_gcm_only, policy.tls13_policy);
    try std.testing.expectEqualStrings(tls12_cipher_list_all, policy.tls12_cipher_list);
}

test "kTLS negotiation policy disables TLS 1.3 when it cannot be made safe" {
    const policy = try KtlsNegotiationPolicy.fromCapabilities(.{
        .tls12_aes_gcm_128 = true,
        .tls12_aes_gcm_256 = false,
        .tls13_aes_gcm_128 = true,
        .tls13_aes_gcm_256 = false,
        .tls13_chacha20_poly1305 = true,
    });
    try std.testing.expectEqual(Tls13Policy.disabled, policy.tls13_policy);
    try std.testing.expectEqualStrings(tls12_cipher_list_aes_128, policy.tls12_cipher_list);
}

test "BoringSSL TLS 1.2 key material converts to kTLS RX/TX structs" {
    var raw: boring.RawKtlsKeyMaterial = std.mem.zeroes(boring.RawKtlsKeyMaterial);
    raw.tls_version = ktls.tls_1_2_version;
    raw.cipher_id = ktls.tls12_ecdhe_rsa_aes_128_gcm_sha256;
    raw.key_len = 16;
    raw.rx_key[0] = 0x11;
    raw.tx_key[0] = 0x22;
    raw.rx_salt = .{ 1, 2, 3, 4 };
    raw.tx_salt = .{ 5, 6, 7, 8 };
    @memcpy(raw.rx_iv[0..8], &[_]u8{ 9, 10, 11, 12, 13, 14, 15, 16 });
    @memcpy(raw.tx_iv[0..8], &[_]u8{ 17, 18, 19, 20, 21, 22, 23, 24 });
    @memcpy(raw.rx_iv[8..12], &[_]u8{ 0xa1, 0xa2, 0xa3, 0xa4 });
    @memcpy(raw.tx_iv[8..12], &[_]u8{ 0xb1, 0xb2, 0xb3, 0xb4 });
    raw.read_seq = .{ 0, 0, 0, 0, 0, 0, 0, 3 };
    raw.write_seq = .{ 0, 0, 0, 0, 0, 0, 0, 4 };

    const initial = try ktlsKeyMaterialToInitialState(&raw);
    const info = initial.crypto_info;
    try std.testing.expect(!initial.rekey_state.enabled());
    const rx = switch (info.rx) {
        .aes_gcm_128 => |aes| aes,
        .aes_gcm_256 => return error.UnexpectedCipherClass,
        .chacha20_poly1305 => return error.UnexpectedCipherClass,
    };
    const tx = switch (info.tx) {
        .aes_gcm_128 => |aes| aes,
        .aes_gcm_256 => return error.UnexpectedCipherClass,
        .chacha20_poly1305 => return error.UnexpectedCipherClass,
    };
    try std.testing.expectEqual(@as(u8, 0x11), rx.key[0]);
    try std.testing.expectEqual(@as(u8, 0x22), tx.key[0]);
    try std.testing.expectEqualSlices(u8, &raw.rx_salt, &rx.salt);
    try std.testing.expectEqualSlices(u8, &raw.tx_salt, &tx.salt);
    try std.testing.expectEqualSlices(u8, raw.rx_iv[0..8], &rx.iv);
    try std.testing.expectEqualSlices(u8, raw.tx_iv[0..8], &tx.iv);
    try std.testing.expectEqualSlices(u8, &raw.read_seq, &rx.rec_seq);
    try std.testing.expectEqualSlices(u8, &raw.write_seq, &tx.rec_seq);
}

test "BoringSSL TLS 1.2 key material rejects mismatched key length" {
    var raw: boring.RawKtlsKeyMaterial = std.mem.zeroes(boring.RawKtlsKeyMaterial);
    raw.tls_version = ktls.tls_1_2_version;
    raw.cipher_id = ktls.tls12_ecdhe_rsa_aes_128_gcm_sha256;
    raw.key_len = 32;
    try std.testing.expectError(error.KtlsKeyExportFailed, ktlsKeyMaterialToInitialState(&raw));
}

test "BoringSSL TLS 1.3 key material derives initial kTLS crypto from traffic secrets" {
    var raw: boring.RawKtlsKeyMaterial = std.mem.zeroes(boring.RawKtlsKeyMaterial);
    raw.tls_version = ktls.tls_1_3_version;
    raw.cipher_id = ktls.tls13_aes_128_gcm_sha256;
    raw.key_len = 0;
    raw.secret_len = 32;
    @memset(&raw.rx_key, 0xa5);
    @memset(&raw.tx_key, 0xa5);
    @memset(&raw.rx_salt, 0xa5);
    @memset(&raw.tx_salt, 0xa5);
    @memset(&raw.rx_iv, 0xa5);
    @memset(&raw.tx_iv, 0xa5);
    @memset(raw.read_secret[0..raw.secret_len], 0x11);
    @memset(raw.write_secret[0..raw.secret_len], 0x22);
    raw.read_seq = .{ 0, 0, 0, 0, 0, 0, 0, 7 };
    raw.write_seq = .{ 0, 0, 0, 0, 0, 0, 0, 8 };

    var initial = try ktlsKeyMaterialToInitialState(&raw);
    defer initial.rekey_state.zero();
    try std.testing.expect(initial.rekey_state.enabled());
    try std.testing.expectEqual(@as(u16, 32), initial.rekey_state.secret_len);
    try std.testing.expectEqualSlices(u8, raw.read_secret[0..32], initial.rekey_state.read_secret[0..32]);
    try std.testing.expectEqualSlices(u8, raw.write_secret[0..32], initial.rekey_state.write_secret[0..32]);

    const expected_rx = try ktls.deriveDirectionCrypto(
        raw.cipher_id,
        raw.tls_version,
        raw.read_secret[0..raw.secret_len],
        raw.read_seq,
    );
    const expected_tx = try ktls.deriveDirectionCrypto(
        raw.cipher_id,
        raw.tls_version,
        raw.write_secret[0..raw.secret_len],
        raw.write_seq,
    );
    const rx = switch (initial.crypto_info.rx) {
        .aes_gcm_128 => |aes| aes,
        else => return error.UnexpectedCipherClass,
    };
    const tx = switch (initial.crypto_info.tx) {
        .aes_gcm_128 => |aes| aes,
        else => return error.UnexpectedCipherClass,
    };
    const expected_rx_aes = switch (expected_rx) {
        .aes_gcm_128 => |aes| aes,
        else => return error.UnexpectedCipherClass,
    };
    const expected_tx_aes = switch (expected_tx) {
        .aes_gcm_128 => |aes| aes,
        else => return error.UnexpectedCipherClass,
    };
    try std.testing.expectEqualSlices(u8, &expected_rx_aes.key, &rx.key);
    try std.testing.expectEqualSlices(u8, &expected_tx_aes.key, &tx.key);
    try std.testing.expectEqualSlices(u8, &expected_rx_aes.iv, &rx.iv);
    try std.testing.expectEqualSlices(u8, &expected_tx_aes.iv, &tx.iv);
    try std.testing.expectEqualSlices(u8, &expected_rx_aes.salt, &rx.salt);
    try std.testing.expectEqualSlices(u8, &expected_tx_aes.salt, &tx.salt);
    try std.testing.expectEqualSlices(u8, &raw.read_seq, &rx.rec_seq);
    try std.testing.expectEqualSlices(u8, &raw.write_seq, &tx.rec_seq);
}

test "BoringSSL TLS 1.3 key material rejects oversized secret length" {
    var raw: boring.RawKtlsKeyMaterial = std.mem.zeroes(boring.RawKtlsKeyMaterial);
    raw.tls_version = ktls.tls_1_3_version;
    raw.cipher_id = ktls.tls13_aes_128_gcm_sha256;
    raw.secret_len = raw.read_secret.len + 1;

    try std.testing.expectError(error.KtlsKeyExportFailed, ktlsKeyMaterialToInitialState(&raw));
}

test "BoringSSL key material zeroizer clears raw export struct" {
    var raw: boring.RawKtlsKeyMaterial = undefined;
    @memset(std.mem.asBytes(&raw), 0xa5);

    boring.collo_boringssl_zeroize_key_material(&raw);

    for (std.mem.asBytes(&raw)) |byte|
        try std.testing.expectEqual(@as(u8, 0), byte);
}
