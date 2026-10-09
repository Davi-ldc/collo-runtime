//! The server's kernel TLS policy: the cipher classes the kernel can take
//! over from BoringSSL, probed at boot, and the classification of a
//! negotiated version and cipher into those classes. The record layer itself,
//! which installs keys, reads control records and rekeys, is `collo_ktls`
//! (`common/tls/ktls.zig`). This file re-exports it for `tls/root.zig`, the
//! boot and the tests; the ingress lanes import `collo_ktls` directly.
//!
//! The probe runs on the thread that builds the TLS context and keys one
//! loopback TCP connection per cipher class with throwaway keys, so it needs
//! loopback networking.

const std = @import("std");
const common = @import("collo_ktls");

pub const CryptoInfo = common.CryptoInfo;
pub const Direction = common.Direction;
pub const DirectionCryptoInfo = common.DirectionCryptoInfo;
pub const InitialState = common.InitialState;
pub const KeyUpdateRequest = common.KeyUpdateRequest;
pub const RecordType = common.RecordType;
pub const RekeyState = common.RekeyState;
pub const TlsAesGcm128 = common.TlsAesGcm128;
pub const TlsAesGcm256 = common.TlsAesGcm256;
pub const TlsChacha20Poly1305 = common.TlsChacha20Poly1305;

pub const deriveDirectionCrypto = common.deriveDirectionCrypto;
pub const enableKernelRxTx = common.enableKernelRxTx;
pub const handleControlRecord = common.handleControlRecord;
pub const installUpdatedTrafficKey = common.installUpdatedTrafficKey;
pub const queueRecvMsg = common.queueRecvMsg;
pub const readApplicationData = common.readApplicationData;

pub const header_align = common.header_align;
pub const max_tls13_secret_len = common.max_tls13_secret_len;
pub const recv_control_len = common.recv_control_len;
pub const tls12_ecdhe_ecdsa_aes_128_gcm_sha256 = common.tls12_ecdhe_ecdsa_aes_128_gcm_sha256;
pub const tls12_ecdhe_ecdsa_aes_256_gcm_sha384 = common.tls12_ecdhe_ecdsa_aes_256_gcm_sha384;
pub const tls12_ecdhe_rsa_aes_128_gcm_sha256 = common.tls12_ecdhe_rsa_aes_128_gcm_sha256;
pub const tls12_ecdhe_rsa_aes_256_gcm_sha384 = common.tls12_ecdhe_rsa_aes_256_gcm_sha384;
pub const tls13_aes_128_gcm_sha256 = common.tls13_aes_128_gcm_sha256;
pub const tls13_aes_256_gcm_sha384 = common.tls13_aes_256_gcm_sha384;
pub const tls13_chacha20_poly1305_sha256 = common.tls13_chacha20_poly1305_sha256;
pub const tls_1_2_version = common.tls_1_2_version;
pub const tls_1_3_version = common.tls_1_3_version;
pub const tls_cipher_aes_gcm_128 = common.tls_cipher_aes_gcm_128;
pub const tls_cipher_aes_gcm_256 = common.tls_cipher_aes_gcm_256;
pub const tls_cipher_chacha20_poly1305 = common.tls_cipher_chacha20_poly1305;

pub const Tls12CipherClass = enum {
    aes_gcm_128,
    aes_gcm_256,
};

pub const TlsCipherClass = enum {
    tls12_aes_gcm_128,
    tls12_aes_gcm_256,
    tls13_aes_gcm_128,
    tls13_aes_gcm_256,
    tls13_chacha20_poly1305,
};

/// Key material for kTLS on one socket. `enableRxTx` reports whether the
/// kernel took over: false without keys or when the kernel lacks the cipher.
pub const Adapter = struct {
    mode: AdapterMode = .kernel,
    crypto_info: ?CryptoInfo = null,

    pub fn kernelWithoutSecrets() Adapter {
        return .{ .mode = .kernel, .crypto_info = null };
    }

    pub fn kernelWithSecrets(info: CryptoInfo) Adapter {
        return .{ .mode = .kernel, .crypto_info = info };
    }

    pub fn enableRxTx(self: Adapter, fd: std.posix.fd_t) !bool {
        return switch (self.mode) {
            .kernel => {
                const info = self.crypto_info orelse return false;
                // A failure after the receive key is installed leaves `fd`
                // half configured, so the caller closes it on any error.
                common.enableKernelRxTx(fd, info) catch |err| switch (err) {
                    error.InvalidProtocolOption,
                    error.OperationNotSupported,
                    => return false,
                    else => return err,
                };
                return true;
            },
        };
    }
};

const AdapterMode = enum {
    kernel,
};

/// The cipher classes the kernel accepts for kTLS. `probe` asks the kernel;
/// `allKnown` assumes every class, for callers that skip the probe.
pub const KernelCapabilities = struct {
    tls12_aes_gcm_128: bool = false,
    tls12_aes_gcm_256: bool = false,
    tls13_aes_gcm_128: bool = false,
    tls13_aes_gcm_256: bool = false,
    tls13_chacha20_poly1305: bool = false,

    pub fn allKnown() KernelCapabilities {
        return .{
            .tls12_aes_gcm_128 = true,
            .tls12_aes_gcm_256 = true,
            .tls13_aes_gcm_128 = true,
            .tls13_aes_gcm_256 = true,
            .tls13_chacha20_poly1305 = true,
        };
    }

    pub fn probe() KernelCapabilities {
        return .{
            .tls12_aes_gcm_128 = probeKernelCipher(.tls12_aes_gcm_128),
            .tls12_aes_gcm_256 = probeKernelCipher(.tls12_aes_gcm_256),
            .tls13_aes_gcm_128 = probeKernelCipher(.tls13_aes_gcm_128),
            .tls13_aes_gcm_256 = probeKernelCipher(.tls13_aes_gcm_256),
            .tls13_chacha20_poly1305 = probeKernelCipher(.tls13_chacha20_poly1305),
        };
    }

    /// Whether the kernel can take over a connection that negotiated
    /// `tls_version` and `cipher_id`; false for a pair outside every class.
    pub fn supportsHandshake(self: KernelCapabilities, tls_version: u16, cipher_id: u32) bool {
        const class = classifyHandshake(tls_version, cipher_id) catch return false;
        return switch (class) {
            .tls12_aes_gcm_128 => self.tls12_aes_gcm_128,
            .tls12_aes_gcm_256 => self.tls12_aes_gcm_256,
            .tls13_aes_gcm_128 => self.tls13_aes_gcm_128,
            .tls13_aes_gcm_256 => self.tls13_aes_gcm_256,
            .tls13_chacha20_poly1305 => self.tls13_chacha20_poly1305,
        };
    }

    pub fn supportsAnyTls12(self: KernelCapabilities) bool {
        return self.tls12_aes_gcm_128 or self.tls12_aes_gcm_256;
    }

    /// Requires both AES-GCM sizes, because BoringSSL has no TLS 1.3 cipher
    /// list: the server can prefer AES-GCM but cannot keep a handshake off
    /// either size (the `aes_gcm_only` case in `collo_boringssl_ctx_new_internal`,
    /// `bindings/boringssl/shim.cc`).
    pub fn supportsTls13AesGcm(self: KernelCapabilities) bool {
        return self.tls13_aes_gcm_128 and self.tls13_aes_gcm_256;
    }

    pub fn supportsFullTls13(self: KernelCapabilities) bool {
        return self.supportsTls13AesGcm() and self.tls13_chacha20_poly1305;
    }
};

pub fn classifyTls12Handshake(tls_version: u16, cipher_id: u32) !Tls12CipherClass {
    if (tls_version != tls_1_2_version)
        return error.UnsupportedTlsVersion;

    return switch (cipher_id) {
        tls12_ecdhe_rsa_aes_128_gcm_sha256,
        tls12_ecdhe_ecdsa_aes_128_gcm_sha256,
        => .aes_gcm_128,
        tls12_ecdhe_rsa_aes_256_gcm_sha384,
        tls12_ecdhe_ecdsa_aes_256_gcm_sha384,
        => .aes_gcm_256,
        else => error.UnsupportedTlsCipher,
    };
}

pub fn classifyTls13Handshake(tls_version: u16, cipher_id: u32) !TlsCipherClass {
    if (tls_version != tls_1_3_version)
        return error.UnsupportedTlsVersion;
    return switch (cipher_id) {
        tls13_aes_128_gcm_sha256 => .tls13_aes_gcm_128,
        tls13_aes_256_gcm_sha384 => .tls13_aes_gcm_256,
        tls13_chacha20_poly1305_sha256 => .tls13_chacha20_poly1305,
        else => error.UnsupportedTlsCipher,
    };
}

pub fn classifyHandshake(tls_version: u16, cipher_id: u32) !TlsCipherClass {
    if (tls_version == tls_1_2_version) {
        return switch (try classifyTls12Handshake(tls_version, cipher_id)) {
            .aes_gcm_128 => .tls12_aes_gcm_128,
            .aes_gcm_256 => .tls12_aes_gcm_256,
        };
    }
    return classifyTls13Handshake(tls_version, cipher_id);
}

/// A worker may write to a client socket itself only when the socket carries
/// no TLS or the kernel handles TLS in both directions.
pub fn directWorkerWriteAllowed(tls_enabled: bool, ktls_rx_enabled: bool, ktls_tx_enabled: bool) bool {
    return !tls_enabled or (ktls_rx_enabled and ktls_tx_enabled);
}

const TcpPair = struct {
    server: std.net.Stream,
    client: std.net.Stream,

    fn close(self: *TcpPair) void {
        self.server.close();
        self.client.close();
    }
};

/// Attempts per cipher class when a probe fails for a reason other than
/// missing support, such as memory or descriptor exhaustion. One such failure
/// says nothing about the kernel, yet without a retry it would drop the
/// cipher for the server's life, and failing on every cipher would fail the
/// boot with `error.NoUsableKtlsCipher` on a capable kernel.
const ktls_probe_max_attempts: u8 = 3;

const ProbeOutcome = enum { supported, unsupported, transient_failure };

fn probeKernelCipherOnce(class: TlsCipherClass) ProbeOutcome {
    var pair = createLoopbackTcpPair() catch return .transient_failure;
    defer pair.close();
    common.enableKernelRxTx(pair.server.handle, sampleCryptoInfo(class)) catch |err| switch (err) {
        // The kernel lacks this cipher or the TLS module itself, so the
        // negotiation policy must not offer the cipher.
        error.OperationNotSupported,
        error.InvalidProtocolOption,
        => return .unsupported,
        // Any other error, such as ENOMEM or a broken loopback socket, says
        // nothing about cipher support, so the probe is retried.
        else => return .transient_failure,
    };
    return .supported;
}

fn probeKernelCipher(class: TlsCipherClass) bool {
    var attempt: u8 = 0;
    while (attempt < ktls_probe_max_attempts) : (attempt += 1) {
        switch (probeKernelCipherOnce(class)) {
            .supported => return true,
            .unsupported => return false,
            .transient_failure => {},
        }
    }
    // Support could not be proven, so the cipher counts as unsupported: the
    // cipher list narrows, and the boot still fails with
    // `error.NoUsableKtlsCipher` when nothing is left. The warning keeps the
    // loss of a cipher visible.
    std.log.warn(
        "ktls: probe for {s} failed transiently after {d} attempts; treating as unsupported",
        .{ @tagName(class), ktls_probe_max_attempts },
    );
    return false;
}

fn createLoopbackTcpPair() !TcpPair {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    errdefer client.close();
    const accepted = try listener.accept();
    errdefer accepted.stream.close();

    return .{
        .server = accepted.stream,
        .client = client,
    };
}

fn sampleCryptoInfo(class: TlsCipherClass) CryptoInfo {
    return .{
        .rx = sampleDirectionCryptoInfo(class, .{ 0, 0, 0, 0, 0, 0, 0, 1 }),
        .tx = sampleDirectionCryptoInfo(class, .{ 0, 0, 0, 0, 0, 0, 0, 1 }),
    };
}

fn sampleDirectionCryptoInfo(class: TlsCipherClass, rec_seq: [8]u8) DirectionCryptoInfo {
    return switch (class) {
        .tls12_aes_gcm_128 => .{ .aes_gcm_128 = .{
            .version = tls_1_2_version,
            .iv = .{ 0, 0, 0, 0, 0, 0, 0, 1 },
            .key = .{0x11} ** 16,
            .salt = .{ 0x21, 0x22, 0x23, 0x24 },
            .rec_seq = rec_seq,
        } },
        .tls12_aes_gcm_256 => .{ .aes_gcm_256 = .{
            .version = tls_1_2_version,
            .iv = .{ 0, 0, 0, 0, 0, 0, 0, 1 },
            .key = .{0x12} ** 32,
            .salt = .{ 0x25, 0x26, 0x27, 0x28 },
            .rec_seq = rec_seq,
        } },
        .tls13_aes_gcm_128 => .{ .aes_gcm_128 = .{
            .version = tls_1_3_version,
            .iv = .{ 0, 0, 0, 0, 0, 0, 0, 1 },
            .key = .{0x13} ** 16,
            .salt = .{ 0x29, 0x2a, 0x2b, 0x2c },
            .rec_seq = rec_seq,
        } },
        .tls13_aes_gcm_256 => .{ .aes_gcm_256 = .{
            .version = tls_1_3_version,
            .iv = .{ 0, 0, 0, 0, 0, 0, 0, 1 },
            .key = .{0x14} ** 32,
            .salt = .{ 0x2d, 0x2e, 0x2f, 0x30 },
            .rec_seq = rec_seq,
        } },
        .tls13_chacha20_poly1305 => .{ .chacha20_poly1305 = .{
            .version = tls_1_3_version,
            .iv = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
            .key = .{0x15} ** 32,
            .rec_seq = rec_seq,
        } },
    };
}
