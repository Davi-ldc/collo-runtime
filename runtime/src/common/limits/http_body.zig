//! HTTP body sizes shared by the ingress server, the worker and the egress
//! client. It must import nothing; `root.zig` says why.

/// Largest HTTP body held whole in memory: a request body the ingress server
/// admits, a body a worker buffers or returns, and by default a fetch
/// response body, decoded or encoded. The C++ Web API keeps its own copy,
/// `WebApiMaterializedBodyBytesMax` in `bindings/host_functions/webapi/limits.h`,
/// and no build step compares the two. The larger cap on pooled fetch uploads
/// is `request_body_pooled_bytes_max` in `common/ipc/fetch_limits.zig`.
pub const MATERIALIZED_BODY_BYTES_MAX: usize = 4 * 1024 * 1024;

/// Largest response body chunk a worker queues to the ingress server in one
/// IPC message, so a large response is paced in chunks instead of filling
/// the shared payload ring at once.
pub const INGRESS_RESPONSE_CHUNK_BYTES: usize = 64 * 1024;

/// Most bytes the gateway moves from a fetch's body queue into the worker's
/// body pool in one drain, the default of `Policy.max_body_chunk_bytes`
/// (`egress/gateway/policy.zig`). It is separate from
/// `INGRESS_RESPONSE_CHUNK_BYTES` because the two pace different rings in
/// different processes.
pub const EGRESS_BODY_CHUNK_BYTES: usize = 64 * 1024;
