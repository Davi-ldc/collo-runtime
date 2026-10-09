//! `collo_ktls`, the record layer of kernel TLS. Most tests here need no
//! kernel TLS socket: the layouts of the kernel's `tls12_crypto_info_*`
//! structs, TLS 1.3 key and IV derivation, KeyUpdate parsing, `RekeyState`
//! validation, and the failure paths of a rekey and of a control record. One
//! test runs a TLS 1.3 KeyUpdate in each direction over a loopback TCP pair
//! with kernel TLS on both ends: `collo_ktls` drives the server end, and the
//! client end is a reference peer written here from RFC 8446. That test skips
//! only on a host without kernel TLS for TLS 1.3 AES-128-GCM or without
//! TLS 1.3 key update (Linux before 6.14). Lane `common-test`; the key
//! install after a real handshake runs in `local-e2e` when the kernel offers
//! a usable kTLS cipher.

const std = @import("std");
const ktls = @import("collo_ktls");
const os = @import("collo_os");

const cmsg = os.cmsg;

test "kernel crypto structs match linux uapi sizes" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ktls.KernelTls12CryptoInfoAesGcm128));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm128, "info"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm128, "iv"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm128, "key"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm128, "salt"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm128, "rec_seq"));

    try std.testing.expectEqual(@as(usize, 56), @sizeOf(ktls.KernelTls12CryptoInfoAesGcm256));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm256, "info"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm256, "iv"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm256, "key"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm256, "salt"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(ktls.KernelTls12CryptoInfoAesGcm256, "rec_seq"));

    try std.testing.expectEqual(@as(usize, 56), @sizeOf(ktls.KernelTls12CryptoInfoChacha20Poly1305));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ktls.KernelTls12CryptoInfoChacha20Poly1305, "info"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(ktls.KernelTls12CryptoInfoChacha20Poly1305, "iv"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ktls.KernelTls12CryptoInfoChacha20Poly1305, "key"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(ktls.KernelTls12CryptoInfoChacha20Poly1305, "salt"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(ktls.KernelTls12CryptoInfoChacha20Poly1305, "rec_seq"));
}

test "ktls TLS 1.3 HKDF labels derive stable key and iv lengths" {
    const secret = [_]u8{0x42} ** 32;
    const info = try ktls.deriveDirectionCrypto(ktls.tls13_aes_128_gcm_sha256, ktls.tls_1_3_version, &secret, .{ 0, 0, 0, 0, 0, 0, 0, 1 });
    const aes = switch (info) {
        .aes_gcm_128 => |value| value,
        else => return error.UnexpectedCipherClass,
    };
    try std.testing.expectEqual(ktls.tls_1_3_version, aes.version);
    try std.testing.expectEqual(@as(usize, 16), aes.key.len);
    // `deriveDirectionCrypto` splits the 12-byte TLS 1.3 IV into the 4-byte
    // salt and 8-byte iv of the kernel's AES-GCM layout.
    try std.testing.expectEqual(@as(usize, 8), aes.iv.len);
    try std.testing.expectEqual(@as(usize, 4), aes.salt.len);
}

test "ktls TLS 1.3 KeyUpdate parser accepts only exact key_update messages" {
    try std.testing.expectEqual(
        ktls.KeyUpdateRequest.update_not_requested,
        try ktls.parseKeyUpdate(&.{ 24, 0, 0, 1, 0 }),
    );
    try std.testing.expectEqual(
        ktls.KeyUpdateRequest.update_requested,
        try ktls.parseKeyUpdate(&.{ 24, 0, 0, 1, 1 }),
    );
    try std.testing.expectError(error.InvalidKeyUpdate, ktls.parseKeyUpdate(&.{ 24, 0, 0, 2, 0, 0 }));
    try std.testing.expectError(error.InvalidKeyUpdate, ktls.parseKeyUpdate(&.{ 23, 0, 0, 1, 0 }));
}

test "ktls rekey state validates TLS 1.3 secrets" {
    const secret = [_]u8{0x11} ** 32;
    var state = try ktls.RekeyState.initTls13(ktls.tls13_aes_128_gcm_sha256, &secret, &secret);
    defer state.zero();
    try state.validate();
    try std.testing.expect(state.enabled());
    try std.testing.expectEqual(@as(u16, 32), state.secret_len);
}

test "ktls rekey state rejects noncanonical disabled and enabled forms" {
    var disabled = ktls.RekeyState.disabled();
    disabled.read_generation = 1;
    try std.testing.expectError(error.InvalidKtlsRekeyState, disabled.validate());

    const secret = [_]u8{0x11} ** 32;
    var state = try ktls.RekeyState.initTls13(ktls.tls13_aes_128_gcm_sha256, &secret, &secret);
    defer state.zero();

    state.enabled_flag = 2;
    try std.testing.expectError(error.InvalidKtlsRekeyState, state.validate());
    state.enabled_flag = 1;

    state._reserved0 = 1;
    try std.testing.expectError(error.InvalidKtlsRekeyState, state.validate());
    state._reserved0 = 0;

    state._reserved1[0] = 1;
    try std.testing.expectError(error.InvalidKtlsRekeyState, state.validate());
    state._reserved1[0] = 0;

    // Bytes past `secret_len` must stay zero.
    state.read_secret[32] = 1;
    try std.testing.expectError(error.InvalidKtlsRekeyState, state.validate());
}

test "ktls TLS 1.3 KeyUpdate failure does not commit staged traffic secret" {
    const secret = [_]u8{0x11} ** 32;
    var state = try ktls.RekeyState.initTls13(ktls.tls13_aes_128_gcm_sha256, &secret, &secret);
    defer state.zero();
    const original_read_secret = state.read_secret;

    // Passing fd -1 fails the kernel install of the new key, which comes
    // after the next secret is derived and before it is committed.
    try std.testing.expectError(error.InvalidHandle, ktls.installUpdatedTrafficKey(-1, .rx, &state));

    try std.testing.expectEqualSlices(u8, &original_read_secret, &state.read_secret);
}

test "ktls control records without TLS 1.3 rekey state are rejected intentionally" {
    var disabled = ktls.RekeyState.disabled();
    try std.testing.expectError(
        error.UnexpectedTlsControlRecord,
        ktls.handleControlRecord(-1, .alert, &.{}, &disabled),
    );
}

test "a TLS 1.3 KeyUpdate in each direction keeps a kernel TLS connection decrypting" {
    // The client sends data, a KeyUpdate that asks for the server's, and data
    // under its new key; the server must read both and answer with its own
    // KeyUpdate, after which the client must read the server's data under
    // the server's new key. The first record under a new key has record
    // sequence number zero (RFC 8446 section 5.3), so a key installed at any
    // other number fails the read that follows it.
    const listener_address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try listener_address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    const server = (try listener.accept()).stream;
    defer server.close();
    try os.socket.setReadWriteTimeouts(client.handle, socket_timeout_ms);
    try os.socket.setReadWriteTimeouts(server.handle, socket_timeout_ms);

    ktls.enableKernelRxTx(server.handle, .{
        .rx = try keyOf(&client_to_server_secret),
        .tx = try keyOf(&server_to_client_secret),
    }) catch |err| switch (err) {
        // The host has no kernel TLS for TLS 1.3 AES-128-GCM.
        error.OperationNotSupported, error.InvalidProtocolOption => return error.SkipZigTest,
        else => return err,
    };
    try ktls.enableKernelRxTx(client.handle, .{
        .rx = try keyOf(&server_to_client_secret),
        .tx = try keyOf(&client_to_server_secret),
    });
    var state = try ktls.RekeyState.initTls13(
        ktls.tls13_aes_128_gcm_sha256,
        &client_to_server_secret,
        &server_to_client_secret,
    );
    defer state.zero();

    var buffer: [256]u8 = undefined;
    try client.writeAll("before");
    const before_len = try ktls.readApplicationData(server.handle, &buffer, &state);
    try std.testing.expectEqualStrings("before", buffer[0..before_len]);

    try sendHandshakeRecord(client.handle, &key_update_requested);
    installPeerKey(client.handle, tls_tx, nextSecret(client_to_server_secret)) catch |err| switch (err) {
        // The kernel takes one key per direction and cannot follow a TLS 1.3
        // KeyUpdate (Linux before 6.14).
        error.KeyUpdateUnsupported => return error.SkipZigTest,
        else => return err,
    };
    try client.writeAll("after the client's update");
    const after_len = try ktls.readApplicationData(server.handle, &buffer, &state);
    try std.testing.expectEqualStrings("after the client's update", buffer[0..after_len]);
    try std.testing.expectEqual(@as(u64, 1), state.read_generation);
    try std.testing.expectEqual(@as(u64, 1), state.write_generation);

    try server.writeAll("after the server's update");
    const update = try readPeerRecord(client.handle, &buffer);
    try std.testing.expectEqual(@as(?ktls.RecordType, .handshake), update.record_type);
    try std.testing.expectEqualSlices(u8, &key_update_not_requested, buffer[0..update.len]);
    try installPeerKey(client.handle, tls_rx, nextSecret(server_to_client_secret));
    const data = try readPeerRecord(client.handle, &buffer);
    try std.testing.expect(data.record_type == null or data.record_type.? == .application_data);
    try std.testing.expectEqualStrings("after the server's update", buffer[0..data.len]);
}

/// Bounds each blocking read and write of the KeyUpdate test, so a kernel
/// that never delivers a record fails the test instead of hanging its lane.
const socket_timeout_ms: u32 = 10_000;

// The reference peer, the client end of the KeyUpdate test. It derives each
// next traffic secret (RFC 8446 section 7.2), sends its KeyUpdate and
// installs each new key at record sequence zero with its own code and these
// `<linux/tls.h>` values, so the test does not check `collo_ktls` against
// itself.
const sol_tls: i32 = 282;
const tls_tx: u32 = 1;
const tls_rx: u32 = 2;
const tls_set_record_type: c_int = 1;
const handshake_record_type: u8 = 22;

/// KeyUpdate handshake messages (RFC 8446 section 4.6.3): type 24, a body
/// length of 1, and whether the receiver must update its own sending key.
const key_update_requested = [_]u8{ 24, 0, 0, 1, 1 };
const key_update_not_requested = [_]u8{ 24, 0, 0, 1, 0 };

/// The application traffic secrets both ends start from.
const client_to_server_secret = [_]u8{0x31} ** 32;
const server_to_client_secret = [_]u8{0x47} ** 32;

/// The record sequence number of the first record under every key
/// (RFC 8446 section 5.3).
const first_record_sequence: [8]u8 = @splat(0);

/// The AES-128-GCM key and IV of a TLS 1.3 traffic secret, for the first
/// record under it.
fn keyOf(secret: []const u8) !ktls.DirectionCryptoInfo {
    return ktls.deriveDirectionCrypto(ktls.tls13_aes_128_gcm_sha256, ktls.tls_1_3_version, secret, first_record_sequence);
}

/// HKDF-Expand-Label(secret, "traffic upd", "", 32), the next application
/// traffic secret for SHA-256. `info` is the HkdfLabel of RFC 8446 section
/// 7.1: the output length as a big-endian u16, then the prefixed label and
/// the empty context, each after a one-byte length.
fn nextSecret(secret: [32]u8) [32]u8 {
    const label = "tls13 traffic upd";
    var info: [2 + 1 + label.len + 1]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], 32, .big);
    info[2] = label.len;
    @memcpy(info[3..][0..label.len], label);
    info[3 + label.len] = 0;
    var next: [32]u8 = undefined;
    std.crypto.kdf.hkdf.HkdfSha256.expand(&next, &info, secret);
    return next;
}

/// Installs the key of `secret` on `fd` for `optname`, at record sequence
/// zero.
fn installPeerKey(fd: std.posix.fd_t, optname: u32, secret: [32]u8) !void {
    const aes = (try keyOf(&secret)).aes_gcm_128;
    const kernel = ktls.KernelTls12CryptoInfoAesGcm128{
        .info = .{ .version = aes.version, .cipher_type = ktls.tls_cipher_aes_gcm_128 },
        .iv = aes.iv,
        .key = aes.key,
        .salt = aes.salt,
        .rec_seq = first_record_sequence,
    };
    const bytes = std.mem.asBytes(&kernel);
    const rc = std.os.linux.setsockopt(fd, sol_tls, optname, bytes.ptr, @intCast(bytes.len));
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {},
        // A kernel that takes one key per direction refuses a second one.
        .BUSY => return error.KeyUpdateUnsupported,
        else => |errno| return std.posix.unexpectedErrno(errno),
    }
}

/// Sends `payload` as one handshake record; the kernel takes the record type
/// from a `TLS_SET_RECORD_TYPE` control message.
fn sendHandshakeRecord(fd: std.posix.fd_t, payload: []const u8) !void {
    var control: [cmsg.space(1)]u8 align(cmsg.header_align) = @splat(0);
    const header: *cmsg.Cmsghdr = @ptrCast(@alignCast(&control));
    header.* = .{ .len = cmsg.len(1), .level = sol_tls, .type = tls_set_record_type };
    control[cmsg.dataOffset()] = handshake_record_type;
    const iov = [1]std.posix.iovec_const{.{ .base = payload.ptr, .len = payload.len }};
    const msg = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const sent = try std.posix.sendmsg(fd, &msg, std.posix.MSG.NOSIGNAL);
    if (sent != payload.len)
        return error.ShortWrite;
}

/// What one recvmsg on the reference peer's socket returned. The kernel
/// returns records of one type per read and attaches that type, and
/// `record_type` is null when it attached none.
const PeerRecord = struct {
    len: usize,
    record_type: ?ktls.RecordType,
};

fn readPeerRecord(fd: std.posix.fd_t, buffer: []u8) !PeerRecord {
    var recv_msg: ktls.RecvMsg = .{};
    const rc = std.c.recvmsg(fd, recv_msg.prepare(buffer), 0);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |errno| return std.posix.unexpectedErrno(errno),
    }
    return .{ .len = @intCast(rc), .record_type = try recv_msg.recordType() };
}
