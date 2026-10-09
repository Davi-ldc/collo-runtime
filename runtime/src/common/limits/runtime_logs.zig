//! Bounds on worker console output and on the analytics records the server
//! writes (`server/analytics/`). Leaf module: imports nothing, so the worker
//! and the server can both cite it.
//!
//! The record field caps, from the worker name to the client address, size
//! inline byte arrays that every ingress request slot and every access-ring
//! slot carries (`server/analytics/access.zig` `AccessFacts`), so each byte
//! added to one costs a byte per slot on every lane. A value longer than its
//! cap is cut at a UTF-8 boundary when it is captured, and the record holds
//! the cut value.

/// Byte cap per console line message, cut worker-side at a UTF-8 boundary
/// with the `truncated` flag. Equal to the log ring's frame cap
/// (`common/worker_state/page/console_ring.zig` `LOG_LINE_BYTES_MAX`), which
/// `server/analytics/logs.zig` asserts at compile time: the server never cuts a
/// line again, so every line the ring accepts reaches the sink whole.
pub const LINE_BYTES_MAX: usize = 4096;

/// Byte cap on the worker name a record carries. The server names a worker by
/// the DNS name it routes to, and DNS caps a name at 253 bytes.
pub const WORKER_NAME_BYTES_MAX: usize = 256;

/// Byte cap on a record's route pattern (`/blog/:slug`). A pattern is a path
/// shape with dynamic segments collapsed, so it is never longer than the
/// paths it serves need to be.
pub const ROUTE_BYTES_MAX: usize = 256;

/// Byte cap on an access record's request method. Every registered HTTP
/// method fits, with room for extension methods.
pub const METHOD_BYTES_MAX: usize = 32;

/// Byte cap on an access record's request path. A longer path is recorded
/// cut, because real routes stay far below it and every byte of the cap is
/// paid in every request and ring slot of every lane.
pub const PATH_BYTES_MAX: usize = 512;

/// Byte cap on an access record's `user-agent` value. Browser user agents
/// run about 100 to 150 bytes.
pub const USER_AGENT_BYTES_MAX: usize = 256;

/// Byte cap on an access record's client address: the connection's TCP peer
/// as `PeerAddress.text` writes it (`server/ingress/peer_address.zig`), whose
/// longest form is an IPv6 address with no zero run to compress. The ingress
/// lane asserts that bound against this cap.
pub const CLIENT_IP_BYTES_MAX: usize = 39;

/// Byte cap on the worker fault label an access or usage record carries
/// (`WorkerFaultReason.label` in `server/ingress/fault.zig`, which asserts
/// that every label fits). The record points at the static label, so the cap
/// sizes only the encoded record.
pub const WORKER_FAULT_BYTES_MAX: usize = 48;

/// Per-request console output caps, in lines and in bytes; past either,
/// further lines from that request are dropped. Enforced in the worker's
/// console client before the formatter materializes anything, with each
/// suppressed line counted into the log ring's drop counter so the server's
/// drop marker reports it.
pub const CONSOLE_REQUEST_LINES_MAX: usize = 256;
pub const CONSOLE_REQUEST_BYTES_MAX: usize = 1024 * 1024;
