//! The Zig side of the test TLS shim (`tls_shim.cc` in this directory): the one
//! declaration of each export a Zig caller uses, with the structs and enum
//! values those calls share. Each extern struct mirrors, field for field, the
//! shim struct its comment names. A compilation that calls any of these links
//! the shim through `configureBoringSslTestShim` in `runtime/build/shims.zig`.

/// `collo_test_tls_alpn_result`: the protocol the production server shim
/// selects for an h2 offer, an http/1.1 offer and an unsupported offer, or 0
/// when it refuses the offer and the handshake fails.
pub const TlsAlpnResult = extern struct {
    h2_protocol: c_int,
    http11_protocol: c_int,
    unsupported_protocol: c_int,
};

/// `collo_test_tls_policy_result`: negotiated versions are wire values,
/// 0x0303 for TLS 1.2 and 0x0304 for TLS 1.3.
pub const TlsPolicyResult = extern struct {
    aes_gcm_only_tls_version: c_int,
    tls13_disabled_tls_version: c_int,
    tls13_policy_cipher_flags_ok: c_int,
};

/// `collo_test_egress_tls_alpn_result`.
pub const EgressAlpnResult = extern struct {
    h2_protocol: c_int,
    http11_protocol: c_int,
};

/// `TempFiles`: NUL-terminated paths of throwaway TLS material in a directory
/// under /tmp: the test CA, a server certificate the CA signed, and that
/// certificate's private key.
pub const TlsMaterial = extern struct {
    dir: [128]u8,
    ca: [160]u8,
    server_cert: [160]u8,
    server_key: [160]u8,
};

/// `collo_test_h2_server_result`.
pub const H2ServerResult = extern struct {
    get_body_len: u64,
    post_body_len: u64,
    large_body_len: u64,
    data_frame_count: u64,
    header_frame_count: u64,
    get_body: [1024]u8,
    post_body: [1024]u8,
};

/// `collo_test_h2_get_timings`: the split of one GET's wall clock.
pub const H2GetTimings = extern struct {
    /// Connecting and the TLS handshake, before the server can see the
    /// request.
    handshake_ns: u64,
    total_ns: u64,
};

/// `collo_test_h2_peer`: the server an h2 client call talks to.
pub const H2Peer = extern struct {
    /// The CA the server's chain must verify against under `.test_ca`;
    /// unused under `.any_certificate`.
    material: ?*const TlsMaterial,
    /// Sent as `:authority`, and as SNI unless its host is an IP literal.
    authority: [*:0]const u8,
    /// The server's port on 127.0.0.1.
    port: u16,
    trust: H2Trust,
    reserved0: [5]u8 = @splat(0),
};

/// How an h2 client call checks the server's certificate.
pub const H2Trust = enum(u8) {
    /// Against the test CA in `H2Peer.material`, the material local-e2e's
    /// servers present. Only the chain is checked, never the host name, so an
    /// authority the certificate does not name still verifies.
    test_ca = 0,
    /// Not at all, as `curl -k` does, for a server that generated its own
    /// certificate.
    any_certificate = 1,
};

comptime {
    if (@sizeOf(H2Peer) != 24) @compileError("H2Peer must mirror collo_test_h2_peer");
}

/// `collo_test_h2_client`: one client connection a caller holds across calls,
/// from `collo_test_h2_client_open` to `collo_test_h2_client_close`. One
/// thread at a time calls into it.
pub const TestH2Client = opaque {};

/// `collo_test_h2_response`: how one stream of a held connection ended.
pub const H2Response = extern struct {
    /// The body's full length, which exceeds `body.len` when the body did not
    /// fit.
    body_len: u64,
    header_block_len: u64,
    /// The RST_STREAM or GOAWAY error code when `reset` is 1.
    reset_code: u32,
    /// 1 when the stream ended without END_STREAM: the server reset it, or a
    /// GOAWAY refused it.
    reset: u8,
    reserved0: [3]u8,
    /// The HPACK payload of the response's first HEADERS frame.
    header_block: [1024]u8,
    body: [2048]u8,
};

comptime {
    if (@sizeOf(H2Response) != 3096) @compileError("H2Response must mirror collo_test_h2_response");
}

pub const TestH2Origin = opaque {};
pub const TestTlsResumptionOrigin = opaque {};

/// The ALPN answer `collo_test_h2_origin_start` gives its client.
pub const test_h2_origin_alpn_h2: c_int = 0;
pub const test_h2_origin_alpn_http11: c_int = 1;
/// What `collo_test_h2_origin_selected_alpn` reports once h2 is negotiated.
pub const test_alpn_h2: c_int = 2;

/// The reason for the calling thread's last failed call into the shim. An
/// origin's own thread reports through that origin's `*_last_error` instead.
pub extern fn collo_test_tls_last_error() [*:0]const u8;

pub extern fn collo_test_tls_alpn_end_to_end(out: *TlsAlpnResult) c_int;
pub extern fn collo_test_tls_policy_end_to_end(out: *TlsPolicyResult) c_int;
pub extern fn collo_test_egress_tls_alpn_end_to_end(out: *EgressAlpnResult) c_int;

/// Writes fresh TLS material into `out`: 0, or nonzero with the reason in
/// `collo_test_tls_last_error`. The files stay until
/// `collo_test_tls_material_cleanup`, which also clears `material`.
pub extern fn collo_test_tls_material_create(out: *TlsMaterial) c_int;
pub extern fn collo_test_tls_material_cleanup(material: *TlsMaterial) void;

/// One GET of `path` on a fresh connection to `peer`, on stream 1: 0 once the
/// response ended, or nonzero with the reason in `collo_test_tls_last_error`.
/// The body goes to `out_body`, and `out_body_len` gets its full length,
/// which exceeds `out_body_cap` when the body did not fit. With
/// `out_header_block`, the HPACK payload of the response's first HEADERS
/// frame goes there; with `out_timings`, the split of the call's wall clock.
/// The connection closes before the call returns.
pub extern fn collo_test_h2_get(
    peer: *const H2Peer,
    path: [*:0]const u8,
    out_body: [*]u8,
    out_body_cap: u64,
    out_body_len: *u64,
    out_header_block: ?[*]u8,
    out_header_block_cap: u64,
    out_header_block_len: ?*u64,
    out_timings: ?*H2GetTimings,
) c_int;

// The calls below that take a port and TLS material talk to the server on
// 127.0.0.1 under the authority `demo.example.test` and verify it against
// the test CA in `material`, as `collo_test_h2_get` does with a `.test_ca`
// peer.

/// Three streams on one TLS 1.2 connection: a GET of `/hello/h2?x=7`, a POST
/// of `/echo` whose body arrives in two DATA frames, and a GET of
/// `/large-response`, whose body is only counted.
pub extern fn collo_test_h2_server_roundtrip(port: u16, material: *const TlsMaterial, out: *H2ServerResult) c_int;
pub extern fn collo_test_h2_server_get(
    port: u16,
    material: *const TlsMaterial,
    path: [*:0]const u8,
    out_body: [*]u8,
    out_body_cap: u64,
    out_body_len: *u64,
    out_header_block: ?[*]u8,
    out_header_block_cap: u64,
    out_header_block_len: ?*u64,
) c_int;
pub extern fn collo_test_h2_server_get_timed(
    port: u16,
    material: *const TlsMaterial,
    path: [*:0]const u8,
    out_body: [*]u8,
    out_body_cap: u64,
    out_body_len: *u64,
    out_header_block: ?[*]u8,
    out_header_block_cap: u64,
    out_header_block_len: ?*u64,
    out_timings: ?*H2GetTimings,
) c_int;
/// The HEADERS block the client sends for a bodiless `method` request of
/// `path` under the authority `demo.example.test`: 0 with `out_len` set, or
/// nonzero with the reason in `collo_test_tls_last_error`.
pub extern fn collo_test_h2_request_header_block(
    method: [*:0]const u8,
    path: [*:0]const u8,
    out: [*]u8,
    out_cap: u64,
    out_len: *u64,
) c_int;
/// Two GETs on one connection: `path_first` on stream 1, then `path_second`
/// on stream 3, whose body goes to `out_body`. The second request skips the
/// handshake, so aimed at a route whose worker definition has no worker yet
/// it times a cold start on an open connection.
pub extern fn collo_test_h2_server_get_pair(
    port: u16,
    material: *const TlsMaterial,
    path_first: [*:0]const u8,
    path_second: [*:0]const u8,
    out_body: [*]u8,
    out_body_cap: u64,
    out_body_len: *u64,
    out_first: *H2GetTimings,
    out_second: *H2GetTimings,
) c_int;

/// Opens a connection to `peer` with h2 negotiated and the server's SETTINGS
/// applied: 0 with `out` set, which the caller owns until
/// `collo_test_h2_client_close`, or nonzero with the reason in
/// `collo_test_tls_last_error`.
pub extern fn collo_test_h2_client_open(peer: *const H2Peer, out: *?*TestH2Client) c_int;
/// Ends the connection without a close_notify alert and frees the client. Null
/// does nothing.
pub extern fn collo_test_h2_client_close(client: ?*TestH2Client) void;
/// Opens stream `stream_id`, an odd id above every earlier stream of the
/// connection, with the HEADERS of a `method` request of `path` (GET or
/// POST): content-length when `content_length` is not negative, END_STREAM
/// when `end_stream` is nonzero. The stream's response is kept until
/// `collo_test_h2_client_read_response`.
pub extern fn collo_test_h2_client_send_request(
    client: *TestH2Client,
    stream_id: u32,
    method: [*:0]const u8,
    path: [*:0]const u8,
    content_length: i64,
    end_stream: c_int,
) c_int;
/// Sends `body_bytes` filler bytes on open stream `stream_id` in DATA frames
/// of at most `frame_bytes`, within the server's frame size and send windows,
/// reading the server's frames while a window is closed. The last frame
/// carries END_STREAM when `end_stream` is nonzero. `out_sent` gets the bytes
/// sent, short of `body_bytes` only when the stream's response ended or the
/// stream was reset first.
pub extern fn collo_test_h2_client_send_body(
    client: *TestH2Client,
    stream_id: u32,
    body_bytes: u64,
    frame_bytes: u32,
    end_stream: c_int,
    out_sent: *u64,
) c_int;
/// Reads the server's frames until open stream `stream_id` ends, then copies
/// its response to `out` and forgets the stream. Frames of the client's other
/// open streams are kept for their own read.
pub extern fn collo_test_h2_client_read_response(
    client: *TestH2Client,
    stream_id: u32,
    out: *H2Response,
) c_int;

/// Starts a TLS origin on an ephemeral port of every IPv4 address, presenting
/// material of its own that the test CA signed, and a thread of its own that
/// serves one connection. Whatever the client offers, it selects the protocol
/// `alpn_mode` names: under h2 it answers two streams, stream 1 with `one`
/// and any other with `two`; under http/1.1 it answers one request with
/// `fallback`. 0 with `out` and `out_port` set, or nonzero with the reason in
/// `collo_test_tls_last_error`. The caller owns the origin until
/// `collo_test_h2_origin_stop`.
pub extern fn collo_test_h2_origin_start(alpn_mode: c_int, out: *?*TestH2Origin, out_port: *u16) c_int;
/// Benchmark origin: the first stream answers with an empty body and every
/// later stream with `response_body_bytes` of DATA, so a caller knows the
/// plaintext size of every response.
pub extern fn collo_bench_h2_origin_start(
    expected_stream_count: u32,
    response_body_bytes: usize,
    out: *?*TestH2Origin,
    out_port: *u16,
) c_int;
/// Closes the listener and the connection, joins the origin's thread and
/// frees the origin with its material.
pub extern fn collo_test_h2_origin_stop(origin: *TestH2Origin) void;
/// The origin thread's failure, or an empty string.
pub extern fn collo_test_h2_origin_last_error(origin: *TestH2Origin) [*:0]const u8;
/// The responses sent so far; the origin counts each one after writing it.
pub extern fn collo_test_h2_origin_stream_count(origin: *TestH2Origin) u32;
pub extern fn collo_test_h2_origin_selected_alpn(origin: *TestH2Origin) c_int;

/// Starts a TLS origin that accepts `accept_count` connections one after
/// another on one server context, so a session ticket issued on one can
/// resume the next, and counts handshakes and resumptions. After each
/// handshake it writes one byte; a client that reads it has processed the
/// session tickets sent before it. 0 with `out` and `out_port` set, or
/// nonzero with the reason in `collo_test_tls_last_error`.
pub extern fn collo_test_tls_resumption_origin_start(
    accept_count: u32,
    out: *?*TestTlsResumptionOrigin,
    out_port: *u16,
) c_int;
/// Waits for the origin's thread, which ends once its last connection closes
/// or at its first failure. The counters are final when this returns.
pub extern fn collo_test_tls_resumption_origin_join(origin: *TestTlsResumptionOrigin) void;
/// Closes the listener, joins the origin's thread and frees the origin with
/// its material.
pub extern fn collo_test_tls_resumption_origin_stop(origin: *TestTlsResumptionOrigin) void;
pub extern fn collo_test_tls_resumption_origin_resumed_count(origin: *TestTlsResumptionOrigin) u32;
pub extern fn collo_test_tls_resumption_origin_handshakes(origin: *TestTlsResumptionOrigin) u32;
pub extern fn collo_test_tls_resumption_origin_last_error(origin: *TestTlsResumptionOrigin) [*:0]const u8;
