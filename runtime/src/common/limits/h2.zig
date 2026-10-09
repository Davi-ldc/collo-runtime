//! HTTP/2 window and frame sizes of the ingress server and the egress fetch
//! client. The two sides use different values on purpose: ingress paces
//! request bodies from untrusted clients against the buffers that hold them
//! until a worker reads them, while egress favors download throughput from
//! origins within the response-body budget. It must import nothing;
//! `root.zig` says why. The relations to the protocol bounds and between the
//! two sides are checked in `runtime/tests/contracts/limits.zig`.

/// Per-stream receive window the ingress server advertises as
/// SETTINGS_INITIAL_WINDOW_SIZE. It must not exceed the per-stream
/// pending-body buffer, which `server/ingress/runner/flow_control.zig`
/// asserts.
pub const INGRESS_STREAM_RECV_WINDOW_BYTES: u32 = 512 * 1024;

/// Connection receive window of the ingress server. SETTINGS cannot change
/// the connection window, which starts at `default_initial_window_size`
/// (`collo_http.http2`), so the server raises it with a WINDOW_UPDATE of the
/// difference right after its SETTINGS. It must therefore stay above that
/// default, and within the per-connection pending-body buffer that
/// `server/ingress/runner/flow_control.zig` asserts.
pub const INGRESS_CONNECTION_RECV_WINDOW_BYTES: u32 = 2 * 1024 * 1024;

/// SETTINGS_MAX_FRAME_SIZE the ingress server advertises and enforces on
/// every inbound frame. It also sizes the read buffer each ingress lane shares
/// across its connections (`read_buffer_bytes` in
/// `server/ingress/http2/lane_resources.zig`). Outbound frames follow the client's own SETTINGS_MAX_FRAME_SIZE instead.
pub const INGRESS_MAX_FRAME_SIZE_BYTES: u32 = 64 * 1024;

/// Per-stream receive window of the egress fetch client, and the default cap
/// on body bytes one stream may hold until the fetch acknowledges them
/// (`Limits` in `egress/client/transport/h2/codec/client.zig`), so every byte
/// of credit the client grants can be buffered. Smaller than the ingress
/// stream window on purpose.
pub const EGRESS_STREAM_RECV_WINDOW_BYTES: u32 = 256 * 1024;

/// Connection receive window of the egress fetch client, and the default cap
/// on unacknowledged body bytes across a connection's streams. Larger than
/// the ingress connection window on purpose, because many downloads can
/// share one origin connection.
pub const EGRESS_CONNECTION_RECV_WINDOW_BYTES: u32 = 4 * 1024 * 1024;

/// Consumed receive credit at which the egress client sends one
/// WINDOW_UPDATE, so it batches updates instead of sending one per chunk.
/// The client uses half of a window instead when that is smaller
/// (`receiveWindowThreshold` in `egress/client/transport/h2/codec/client.zig`).
pub const EGRESS_RECV_WINDOW_UPDATE_THRESHOLD_BYTES: u32 = 512 * 1024;
