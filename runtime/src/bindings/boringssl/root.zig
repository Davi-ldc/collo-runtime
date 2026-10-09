//! The Zig declarations of the BoringSSL shim (`shim.cc`): the server's TLS handshake with its
//! clients and the kTLS key export, the gateway's client contexts and connections, and the
//! self-signed certificate generator. Each extern struct mirrors the shim's struct of the same
//! fields, and both sides pin its size and offsets.
//!
//! Each `*_new` hands the caller a handle it releases with the matching `*_free`. A client
//! connection points into its context's session cache, so a client context outlives every
//! connection made from it. Contexts may be shared between threads, but a connection is used by
//! one thread at a time, as BoringSSL requires of an `SSL`. A failing call leaves its message in a
//! buffer of the calling thread, read with `lastErrorSlice` on that same thread.

const std = @import("std");

pub const Handle = opaque {};
pub const ContextHandle = opaque {};
pub const ClientHandle = opaque {};
pub const ClientContextHandle = opaque {};

/// What a handshake step reports: `status` is a `status_*` code, and once it is `status_ok` the
/// negotiated TLS version, `alpn_*` code and cipher id follow.
pub const RawResult = extern struct {
    status: c_int,
    tls_version: u16,
    application_protocol: u8,
    reserved0: u8,
    cipher_id: u32,
};

/// The negotiated keys `collo_boringssl_export_ktls_key_material` writes. TLS 1.2 fills the keys,
/// salts and IVs, TLS 1.3 only the traffic secrets, and both fill the record sequences. The caller
/// zeroes it with `collo_boringssl_zeroize_key_material`.
pub const RawKtlsKeyMaterial = extern struct {
    tls_version: u16,
    reserved0: u16,
    cipher_id: u32,
    rx_key: [32]u8,
    tx_key: [32]u8,
    rx_salt: [4]u8,
    tx_salt: [4]u8,
    rx_iv: [12]u8,
    tx_iv: [12]u8,
    read_seq: [8]u8,
    write_seq: [8]u8,
    read_secret: [64]u8,
    write_secret: [64]u8,
    key_len: usize,
    secret_len: usize,
};

/// Result codes. A handshake step returns 0 and puts one in `RawResult.status`; the client read,
/// write and ciphertext calls return one directly. Both groups return -1 for invalid arguments.
/// The other calls return 0 on success and -1 on failure, except
/// `collo_boringssl_client_session_reused`, which returns 1 when the handshake resumed a session
/// and 0 otherwise.
pub const status_ok: c_int = 0;
pub const status_want_read: c_int = 1;
pub const status_want_write: c_int = 2;
pub const status_failed: c_int = 3;
pub const status_eof: c_int = 4;

pub const alpn_unspecified: u8 = 0;
pub const alpn_http_1_1: u8 = 1;
pub const alpn_h2: u8 = 2;

pub const alpn_offer_http_1_1: c_int = 0;
pub const alpn_offer_h2_http_1_1: c_int = 1;
pub const alpn_offer_h2_only: c_int = 2;

/// TLS 1.3 policies for a server context. `KtlsNegotiationPolicy` in `server/tls/root.zig` picks
/// one from the ciphers the running kernel can take over.
pub const tls13_policy_all_supported: c_int = 0;
pub const tls13_policy_aes_gcm_only: c_int = 1;
pub const tls13_policy_disabled: c_int = 2;

/// `SubjectAltName.kind` values.
pub const subject_alt_name_dns: u8 = 0;
pub const subject_alt_name_ip: u8 = 1;
/// Most names one call to `collo_boringssl_self_signed_generate` accepts.
pub const self_signed_names_max: usize = 16;

/// `collo_boringssl_subject_alt_name`: a DNS name of letters, digits, hyphens and dots, or the 4
/// or 16 bytes of an IP address in network order. `value` is borrowed for the call and
/// `reserved0` is zero.
pub const SubjectAltName = extern struct {
    value: [*]const u8,
    value_len: usize,
    kind: u8,
    reserved0: [7]u8,
};

pub extern fn collo_boringssl_ctx_new(
    cert_chain_path: [*:0]const u8,
    private_key_path: [*:0]const u8,
    out: *?*ContextHandle,
) c_int;

pub extern fn collo_boringssl_ctx_new_ex(
    cert_chain_path: [*:0]const u8,
    private_key_path: [*:0]const u8,
    tls12_cipher_list: ?[*:0]const u8,
    tls13_policy: c_int,
    out: *?*ContextHandle,
) c_int;

pub extern fn collo_boringssl_ctx_new_pem_ex(
    cert_chain_pem: [*]const u8,
    cert_chain_len: usize,
    private_key_pem: [*]const u8,
    private_key_len: usize,
    tls12_cipher_list: ?[*:0]const u8,
    tls13_policy: c_int,
    out: *?*ContextHandle,
) c_int;

pub extern fn collo_boringssl_ctx_free(handle: *ContextHandle) void;

pub extern fn collo_boringssl_conn_new(
    context: *ContextHandle,
    fd: c_int,
    out: *?*Handle,
) c_int;

pub extern fn collo_boringssl_conn_free(handle: *Handle) void;

pub extern fn collo_boringssl_handshake_step(handle: *Handle, result: *RawResult) c_int;

pub extern fn collo_boringssl_client_ctx_new(
    insecure_skip_verify: c_int,
    out: *?*ClientContextHandle,
) c_int;

pub extern fn collo_boringssl_client_ctx_free(handle: *ClientContextHandle) void;

pub extern fn collo_boringssl_client_conn_new(
    context: *ClientContextHandle,
    fd: c_int,
    server_name: [*:0]const u8,
    alpn_offer: c_int,
    session_key: ?[*]const u8,
    session_key_len: usize,
    out: *?*ClientHandle,
) c_int;

pub extern fn collo_boringssl_client_conn_new_bio(
    context: *ClientContextHandle,
    server_name: [*:0]const u8,
    alpn_offer: c_int,
    session_key: ?[*]const u8,
    session_key_len: usize,
    out: *?*ClientHandle,
) c_int;

pub extern fn collo_boringssl_client_conn_free(handle: *ClientHandle) void;

pub extern fn collo_boringssl_client_session_reused(handle: *ClientHandle) c_int;

pub extern fn collo_boringssl_client_handshake_step(handle: *ClientHandle, result: *RawResult) c_int;

pub extern fn collo_boringssl_client_read(
    handle: *ClientHandle,
    out: [*]u8,
    out_cap: usize,
    out_len: *usize,
) c_int;

pub extern fn collo_boringssl_client_has_buffered_input(
    handle: *ClientHandle,
    out_has_buffered: *c_int,
) c_int;

pub extern fn collo_boringssl_client_write(
    handle: *ClientHandle,
    bytes: [*]const u8,
    bytes_len: usize,
    out_len: *usize,
) c_int;

pub extern fn collo_boringssl_client_feed_ciphertext(
    handle: *ClientHandle,
    bytes: [*]const u8,
    bytes_len: usize,
    out_len: *usize,
) c_int;

pub extern fn collo_boringssl_client_drain_ciphertext(
    handle: *ClientHandle,
    out: [*]u8,
    out_cap: usize,
    out_len: *usize,
) c_int;

pub extern fn collo_boringssl_client_pending_ciphertext(
    handle: *ClientHandle,
    out_len: *usize,
) c_int;

pub extern fn collo_boringssl_client_shutdown_best_effort(handle: *ClientHandle) void;

pub extern fn collo_boringssl_export_ktls_key_material(
    handle: *Handle,
    out: *RawKtlsKeyMaterial,
) c_int;

pub extern fn collo_boringssl_zeroize_key_material(out: *RawKtlsKeyMaterial) void;

/// Generates an EC P-256 key and a certificate it signs itself for `names`, valid from
/// `not_before_unix_seconds` to `not_after_unix_seconds`, with a random serial, and writes both as
/// PEM into the caller's buffers. Returns 0 with both lengths set, or -1 with both lengths zero and
/// the whole key buffer cleansed: for no names or more than `self_signed_names_max`, an invalid
/// name, a validity that does not end after it starts, a buffer too small, or a BoringSSL failure.
/// The caller owns both buffers and zeroes the key when it is done with it.
pub extern fn collo_boringssl_self_signed_generate(
    names: [*]const SubjectAltName,
    name_count: usize,
    not_before_unix_seconds: i64,
    not_after_unix_seconds: i64,
    cert_pem: [*]u8,
    cert_pem_cap: usize,
    out_cert_pem_len: *usize,
    key_pem: [*]u8,
    key_pem_cap: usize,
    out_key_pem_len: *usize,
) c_int;

/// The calling thread's last shim error as a NUL-terminated string; `lastErrorSlice` wraps it.
pub extern fn collo_boringssl_last_error() [*:0]const u8;

/// The calling thread's last shim error, which holds until that thread's next shim call. Read it
/// on the thread that received the failing status.
pub fn lastErrorSlice() []const u8 {
    return std.mem.span(collo_boringssl_last_error());
}

comptime {
    if (@sizeOf(RawResult) != 12)
        @compileError("boringssl.RawResult size mismatch");
    if (@offsetOf(RawResult, "status") != 0)
        @compileError("boringssl.RawResult.status offset mismatch");
    if (@offsetOf(RawResult, "tls_version") != 4)
        @compileError("boringssl.RawResult.tls_version offset mismatch");
    if (@offsetOf(RawResult, "application_protocol") != 6)
        @compileError("boringssl.RawResult.application_protocol offset mismatch");
    if (@offsetOf(RawResult, "reserved0") != 7)
        @compileError("boringssl.RawResult.reserved0 offset mismatch");
    if (@offsetOf(RawResult, "cipher_id") != 8)
        @compileError("boringssl.RawResult.cipher_id offset mismatch");
    if (@sizeOf(RawKtlsKeyMaterial) != 264)
        @compileError("boringssl.RawKtlsKeyMaterial size mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "tls_version") != 0)
        @compileError("boringssl.RawKtlsKeyMaterial.tls_version offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "reserved0") != 2)
        @compileError("boringssl.RawKtlsKeyMaterial.reserved0 offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "cipher_id") != 4)
        @compileError("boringssl.RawKtlsKeyMaterial.cipher_id offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "rx_key") != 8)
        @compileError("boringssl.RawKtlsKeyMaterial.rx_key offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "tx_key") != 40)
        @compileError("boringssl.RawKtlsKeyMaterial.tx_key offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "rx_salt") != 72)
        @compileError("boringssl.RawKtlsKeyMaterial.rx_salt offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "tx_salt") != 76)
        @compileError("boringssl.RawKtlsKeyMaterial.tx_salt offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "rx_iv") != 80)
        @compileError("boringssl.RawKtlsKeyMaterial.rx_iv offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "tx_iv") != 92)
        @compileError("boringssl.RawKtlsKeyMaterial.tx_iv offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "read_seq") != 104)
        @compileError("boringssl.RawKtlsKeyMaterial.read_seq offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "write_seq") != 112)
        @compileError("boringssl.RawKtlsKeyMaterial.write_seq offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "read_secret") != 120)
        @compileError("boringssl.RawKtlsKeyMaterial.read_secret offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "write_secret") != 184)
        @compileError("boringssl.RawKtlsKeyMaterial.write_secret offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "key_len") != 248)
        @compileError("boringssl.RawKtlsKeyMaterial.key_len offset mismatch");
    if (@offsetOf(RawKtlsKeyMaterial, "secret_len") != 256)
        @compileError("boringssl.RawKtlsKeyMaterial.secret_len offset mismatch");
    if (@sizeOf(SubjectAltName) != 24)
        @compileError("boringssl.SubjectAltName size mismatch");
    if (@offsetOf(SubjectAltName, "value") != 0)
        @compileError("boringssl.SubjectAltName.value offset mismatch");
    if (@offsetOf(SubjectAltName, "value_len") != 8)
        @compileError("boringssl.SubjectAltName.value_len offset mismatch");
    if (@offsetOf(SubjectAltName, "kind") != 16)
        @compileError("boringssl.SubjectAltName.kind offset mismatch");
    if (@offsetOf(SubjectAltName, "reserved0") != 17)
        @compileError("boringssl.SubjectAltName.reserved0 offset mismatch");
}
