//! The server's TLS side: the BoringSSL context built from the configured or generated
//! certificate, the handshake of each client connection, and the export of its keys to kTLS.
//! `ktls.zig` holds the kernel side and `self_signed.zig` the certificate the server generates
//! when its configuration names none.
//!
//! `Server.init` builds the context once. The ingress lanes then start connections from it
//! concurrently, and each connection belongs to the lane that accepted it until its keys move to
//! the kernel. The context copies the certificate and key it loads, and zeroes its copy of the
//! key, so a caller's PEM buffers need to live only until `BoringSslContext.init` returns.

const std = @import("std");
const ktls = @import("ktls.zig");
const boring = @import("collo_boringssl");

pub const boringssl = boring;
pub const self_signed = @import("self_signed.zig");

/// The largest PEM text accepted for each part. A larger file fails with `error.FileTooBig`, and
/// larger inline text with `error.PemMaterialTooLarge`.
pub const max_cert_chain_pem_bytes: usize = 128 * 1024;
pub const max_private_key_pem_bytes: usize = 16 * 1024;

/// Logs `context` with the shim's last error. Call it on the thread that received the failing
/// status, since the shim keeps that message per thread.
pub fn logBoringSslLastError(context: []const u8) void {
    const message = boring.lastErrorSlice();
    if (message.len == 0) {
        std.log.err("{s}", .{context});
    } else {
        std.log.err("{s}: {s}", .{ context, message });
    }
}

pub const PemSource = union(enum) {
    /// An absolute path to a PEM file.
    path: []const u8,
    inline_pem: []const u8,
};

pub const CertificateConfig = struct {
    cert_chain: PemSource,
    private_key: PemSource,
};

pub const BoringSslContext = struct {
    handle: *BoringSslContextHandle,
    ktls_capabilities: ktls.KernelCapabilities = ktls.KernelCapabilities.allKnown(),

    /// Assumes the kernel takes every cipher class instead of probing it.
    pub fn init(allocator: std.mem.Allocator, certificate: CertificateConfig) !BoringSslContext {
        return initWithKtlsCapabilities(allocator, certificate, ktls.KernelCapabilities.allKnown());
    }

    /// Probes the kernel and offers only the ciphers it can take over.
    pub fn initForKernelKtls(
        allocator: std.mem.Allocator,
        certificate: CertificateConfig,
    ) !BoringSslContext {
        return initWithKtlsCapabilities(allocator, certificate, ktls.KernelCapabilities.probe());
    }

    /// Fails with `error.NoUsableKtlsCipher` when `ktls_capabilities` leaves no cipher to offer,
    /// with `error.EmptyPemMaterial`, a size error or a file error for an unusable PEM source,
    /// and with `error.BoringSslInitFailed` after logging BoringSSL's reason.
    pub fn initWithKtlsCapabilities(
        allocator: std.mem.Allocator,
        certificate: CertificateConfig,
        ktls_capabilities: ktls.KernelCapabilities,
    ) !BoringSslContext {
        const policy = try KtlsNegotiationPolicy.fromCapabilities(ktls_capabilities);
        const cert_chain_pem = try loadPemSource(
            allocator,
            certificate.cert_chain,
            max_cert_chain_pem_bytes,
        );
        defer allocator.free(cert_chain_pem);
        const private_key_pem = try loadPemSource(
            allocator,
            certificate.private_key,
            max_private_key_pem_bytes,
        );
        defer secureFree(allocator, private_key_pem);
        const tls12_cipher_list = try allocator.dupeZ(u8, policy.tls12_cipher_list);
        defer allocator.free(tls12_cipher_list);

        var handle: ?*BoringSslContextHandle = null;
        if (boring.collo_boringssl_ctx_new_pem_ex(
            cert_chain_pem.ptr,
            cert_chain_pem.len,
            private_key_pem.ptr,
            private_key_pem.len,
            tls12_cipher_list.ptr,
            @intFromEnum(policy.tls13_policy),
            &handle,
        ) != 0) {
            logBoringSslLastError("BoringSSL TLS context init failed");
            return error.BoringSslInitFailed;
        }

        return .{
            .handle = handle orelse return error.BoringSslInitFailed,
            .ktls_capabilities = ktls_capabilities,
        };
    }

    pub fn deinit(self: *BoringSslContext) void {
        boring.collo_boringssl_ctx_free(self.handle);
        self.* = undefined;
    }

    /// Starts the server side of a handshake on `fd`. The connection does not own `fd`: freeing
    /// it leaves the socket open.
    pub fn start(
        self: *BoringSslContext,
        fd: std.posix.fd_t,
    ) !BoringSslConnection {
        var handle: ?*BoringSslHandle = null;
        if (boring.collo_boringssl_conn_new(self.handle, @intCast(fd), &handle) != 0)
            return error.BoringSslInitFailed;

        return .{
            .handle = handle orelse return error.BoringSslInitFailed,
            .ktls_capabilities = self.ktls_capabilities,
        };
    }
};

fn loadPemSource(
    allocator: std.mem.Allocator,
    source: PemSource,
    max_bytes: usize,
) ![]u8 {
    const pem = switch (source) {
        .path => |path| try readFileAbsolute(allocator, path, max_bytes),
        .inline_pem => |inline_pem| try allocator.dupe(u8, inline_pem),
    };
    errdefer allocator.free(pem);
    if (pem.len == 0)
        return error.EmptyPemMaterial;
    if (pem.len > max_bytes)
        return error.PemMaterialTooLarge;
    return pem;
}

fn readFileAbsolute(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn secureFree(allocator: std.mem.Allocator, secret: []u8) void {
    std.crypto.secureZero(u8, secret);
    allocator.free(secret);
}

/// The ciphers the context offers, narrowed to the ones the kernel can take over, so a handshake
/// completes only with a cipher `exportKtlsInitialState` can hand to the kernel.
pub const KtlsNegotiationPolicy = struct {
    tls12_cipher_list: []const u8,
    tls13_policy: Tls13Policy,

    /// Fails with `error.NoUsableKtlsCipher` when neither TLS 1.2 nor TLS 1.3 keeps a cipher.
    pub fn fromCapabilities(capabilities: ktls.KernelCapabilities) !KtlsNegotiationPolicy {
        const tls12_cipher_list = tls12CipherList(capabilities);
        const tls13_policy = tls13Policy(capabilities);
        if (tls12_cipher_list.len == 0 and tls13_policy == .disabled)
            return error.NoUsableKtlsCipher;
        return .{
            .tls12_cipher_list = tls12_cipher_list,
            .tls13_policy = tls13_policy,
        };
    }

    fn tls12CipherList(capabilities: ktls.KernelCapabilities) []const u8 {
        if (capabilities.tls12_aes_gcm_128 and capabilities.tls12_aes_gcm_256)
            return tls12_cipher_list_all;
        if (capabilities.tls12_aes_gcm_128)
            return tls12_cipher_list_aes_128;
        if (capabilities.tls12_aes_gcm_256)
            return tls12_cipher_list_aes_256;
        return "";
    }

    fn tls13Policy(capabilities: ktls.KernelCapabilities) Tls13Policy {
        if (capabilities.supportsFullTls13())
            return .all_supported;
        if (capabilities.supportsTls13AesGcm())
            return .aes_gcm_only;
        return .disabled;
    }
};

pub const Tls13Policy = enum(c_int) {
    all_supported = boring.tls13_policy_all_supported,
    aes_gcm_only = boring.tls13_policy_aes_gcm_only,
    disabled = boring.tls13_policy_disabled,
};

pub const tls12_cipher_list_all =
    tls12_cipher_list_aes_128 ++ ":" ++ tls12_cipher_list_aes_256;
pub const tls12_cipher_list_aes_128 =
    "ECDHE-RSA-AES128-GCM-SHA256:" ++
    "ECDHE-ECDSA-AES128-GCM-SHA256";
pub const tls12_cipher_list_aes_256 =
    "ECDHE-RSA-AES256-GCM-SHA384:" ++
    "ECDHE-ECDSA-AES256-GCM-SHA384";

pub const HandshakeStep = enum {
    done,
    want_read,
    want_write,
};

/// One client connection's handshake, used only by the lane that accepted the connection.
pub const BoringSslConnection = struct {
    handle: *BoringSslHandle,
    ktls_capabilities: ktls.KernelCapabilities = ktls.KernelCapabilities.allKnown(),

    pub fn deinit(self: *BoringSslConnection) void {
        boring.collo_boringssl_conn_free(self.handle);
        self.* = undefined;
    }

    /// Advances the handshake as far as the socket allows. `.done` means it completed with ALPN
    /// `h2`. Fails with `error.TlsHandshakeFailed`, or with
    /// `error.UnsupportedApplicationProtocol` when the client negotiated no `h2`.
    pub fn step(self: *BoringSslConnection) !HandshakeStep {
        var raw: BoringSslRawResult = .{
            .status = boring.status_failed,
            .tls_version = 0,
            .application_protocol = boring.alpn_unspecified,
            .reserved0 = 0,
            .cipher_id = 0,
        };
        if (boring.collo_boringssl_handshake_step(self.handle, &raw) != 0)
            return error.TlsHandshakeFailed;

        switch (raw.status) {
            boring.status_ok => {
                try requireIngressH2Alpn(raw.application_protocol);
                return .done;
            },
            boring.status_want_read => return .want_read,
            boring.status_want_write => return .want_write,
            else => return error.TlsHandshakeFailed,
        }
    }

    /// The kernel keys for both directions of a finished handshake and, for TLS 1.3, the rekey
    /// state, which the caller zeroes when done. Fails with `error.KtlsCipherUnsupportedByKernel`
    /// when the kernel cannot take the negotiated cipher, and with `error.KtlsKeyExportFailed`
    /// when the export or a key derivation fails.
    pub fn exportKtlsInitialState(self: *BoringSslConnection) !ktls.InitialState {
        var raw: boring.RawKtlsKeyMaterial = std.mem.zeroes(boring.RawKtlsKeyMaterial);
        defer boring.collo_boringssl_zeroize_key_material(&raw);
        if (boring.collo_boringssl_export_ktls_key_material(self.handle, &raw) != 0)
            return error.KtlsKeyExportFailed;
        if (!self.ktls_capabilities.supportsHandshake(raw.tls_version, raw.cipher_id))
            return error.KtlsCipherUnsupportedByKernel;
        return try ktlsKeyMaterialToInitialState(&raw);
    }

    /// The kernel keys alone; the rekey state is zeroed before it returns.
    pub fn exportKtlsCryptoInfo(self: *BoringSslConnection) !ktls.CryptoInfo {
        var initial = try self.exportKtlsInitialState();
        defer initial.rekey_state.zero();
        return initial.crypto_info;
    }
};

/// `raw` is the shim's ALPN code for a finished handshake.
pub fn requireIngressH2Alpn(raw: u8) !void {
    // The ingress serves HTTP/2 only: a reverse proxy in front of the server terminates HTTP/1
    // and speaks h2 to it, so the server keeps no HTTP/1.1 path. The handshake already refuses a
    // client whose ALPN list lacks h2 (`collo_boringssl_select_alpn` in
    // `bindings/boringssl/shim.cc`), but a client that sends no ALPN completes it with none
    // selected, so this check refuses that client too.
    if (raw == boring.alpn_h2)
        return;
    return error.UnsupportedApplicationProtocol;
}

/// Converts the shim's exported key material into kernel keys and, for TLS 1.3, the rekey state.
/// Fails with `error.KtlsKeyExportFailed` when a key or secret length does not fit the cipher.
pub fn ktlsKeyMaterialToInitialState(raw: *const boring.RawKtlsKeyMaterial) !ktls.InitialState {
    // For TLS 1.2 AES-GCM the kernel takes the 4-byte implicit salt and the 8-byte explicit nonce
    // separately; the shim leaves that nonce, the record sequence, in the first 8 bytes of each
    // `*_iv`.
    const crypto_info: ktls.CryptoInfo = switch (try ktls.classifyHandshake(raw.tls_version, raw.cipher_id)) {
        .tls12_aes_gcm_128 => blk: {
            if (raw.key_len != 16)
                return error.KtlsKeyExportFailed;
            break :blk .{ .rx = .{ .aes_gcm_128 = .{
                .version = raw.tls_version,
                .iv = raw.rx_iv[0..8].*,
                .key = first16(raw.rx_key),
                .salt = raw.rx_salt,
                .rec_seq = raw.read_seq,
            } }, .tx = .{ .aes_gcm_128 = .{
                .version = raw.tls_version,
                .iv = raw.tx_iv[0..8].*,
                .key = first16(raw.tx_key),
                .salt = raw.tx_salt,
                .rec_seq = raw.write_seq,
            } } };
        },
        .tls12_aes_gcm_256 => blk: {
            if (raw.key_len != 32)
                return error.KtlsKeyExportFailed;
            break :blk .{ .rx = .{ .aes_gcm_256 = .{
                .version = raw.tls_version,
                .iv = raw.rx_iv[0..8].*,
                .key = raw.rx_key,
                .salt = raw.rx_salt,
                .rec_seq = raw.read_seq,
            } }, .tx = .{ .aes_gcm_256 = .{
                .version = raw.tls_version,
                .iv = raw.tx_iv[0..8].*,
                .key = raw.tx_key,
                .salt = raw.tx_salt,
                .rec_seq = raw.write_seq,
            } } };
        },
        .tls13_aes_gcm_128,
        .tls13_aes_gcm_256,
        .tls13_chacha20_poly1305,
        => try tls13KtlsInitialCrypto(raw),
    };

    const rekey_state = if (raw.tls_version == ktls.tls_1_3_version)
        try ktls.RekeyState.initTls13(
            raw.cipher_id,
            raw.read_secret[0..raw.secret_len],
            raw.write_secret[0..raw.secret_len],
        )
    else
        ktls.RekeyState.disabled();
    return .{ .crypto_info = crypto_info, .rekey_state = rekey_state };
}

fn tls13KtlsInitialCrypto(raw: *const boring.RawKtlsKeyMaterial) !ktls.CryptoInfo {
    if (raw.tls_version != ktls.tls_1_3_version)
        return error.KtlsKeyExportFailed;
    if (raw.secret_len > raw.read_secret.len)
        return error.KtlsKeyExportFailed;

    const read_secret = raw.read_secret[0..raw.secret_len];
    const write_secret = raw.write_secret[0..raw.secret_len];
    return .{
        .rx = ktls.deriveDirectionCrypto(
            raw.cipher_id,
            raw.tls_version,
            read_secret,
            raw.read_seq,
        ) catch return error.KtlsKeyExportFailed,
        .tx = ktls.deriveDirectionCrypto(
            raw.cipher_id,
            raw.tls_version,
            write_secret,
            raw.write_seq,
        ) catch return error.KtlsKeyExportFailed,
    };
}

fn first16(input: [32]u8) [16]u8 {
    var out: [16]u8 = undefined;
    @memcpy(&out, input[0..16]);
    return out;
}

const BoringSslHandle = boring.Handle;
const BoringSslContextHandle = boring.ContextHandle;
const BoringSslRawResult = boring.RawResult;
