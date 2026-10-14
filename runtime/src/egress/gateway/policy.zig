//! The limits the egress gateway enforces on every fetch, the check of a fetch start against them,
//! and the identity of a fetch's pooled connections.
//!
//! Nothing configures the limits: every gateway runs `production`. A `Policy` with other values
//! exists only in tests, which inject lower caps the way they inject clocks. The defaults cite the
//! shared budgets in `common/limits` and `common/ipc/fetch_limits.zig`, the comptime block below
//! holds `production` inside what the fetch IPC can carry, and `runtime/tests/contracts/limits.zig`
//! asserts that the defaults keep citing the budgets.
//!
//! The network policies are the server's policy image (`collo_network`'s `table.zig`), which each
//! gateway's hello hands over (`control.zig`) and the gateway decodes once; a token names its
//! route's policy by id, and the table never changes for the life of a gateway. A fetch's pooled
//! connections, TLS sessions and shard are keyed by its security cell and that id
//! (`PoolIsolation`), so one definition's connections never serve another, and one policy's never
//! serve another policy's fetches.

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const egress = @import("collo_egress_client");

const network = egress.network;
const transport = egress.transport;

pub const PoolIsolationId = transport.PoolIsolationId;
pub const SecurityCellId = PoolIsolationId;

pub const default_max_request_body_bytes: usize = ipc.fetch_limits.request_body_pooled_bytes_max;
pub const default_max_response_header_bytes: usize = 64 * 1024;

/// The policy every gateway process enforces.
pub const production: Policy = .{};

pub const Policy = struct {
    max_response_body_bytes: usize = limits.http_body.MATERIALIZED_BODY_BYTES_MAX,
    max_encoded_response_bytes: usize = limits.http_body.MATERIALIZED_BODY_BYTES_MAX,
    max_request_body_bytes: usize = default_max_request_body_bytes,
    max_request_headers: usize = ipc.max_request_header_count,
    max_request_header_bytes: usize = 64 * 1024,
    max_response_headers: usize = ipc.max_request_header_count,
    max_response_header_bytes: usize = default_max_response_header_bytes,
    socket_timeout_ms: u32 = 5_000,
    enable_http2: bool = true,
    max_redirects: usize = 20,
    max_redirect_drain_bytes: usize = 64 * 1024,
    /// Fetches one worker session runs at once, from admission to the terminal packet the worker
    /// reads (`runtime/fetch_flow.zig`). The worker refuses a fetch past
    /// `limits.worker.fetches_per_worker_max` itself, counting the same lifetime, so an honest
    /// worker never meets this cap.
    max_active_fetches_per_worker_session: usize = limits.worker.fetches_per_worker_max,
    /// Fetches the sessions of one security cell run at once.
    max_active_fetches_per_security_cell: usize = 1024,
    max_body_chunk_bytes: usize = limits.http_body.EGRESS_BODY_CHUNK_BYTES,
};

comptime {
    // What the fetch IPC can carry bounds every limit a worker's packets meet, and a cap of zero
    // would refuse every fetch.
    std.debug.assert(production.max_response_body_bytes != 0);
    std.debug.assert(production.max_encoded_response_bytes != 0);
    std.debug.assert(production.max_request_body_bytes <= ipc.fetch_limits.request_body_pooled_bytes_max);
    std.debug.assert(production.max_request_headers <= ipc.max_request_header_count);
    std.debug.assert(production.max_request_header_bytes <= ipc.fetch_limits.request_headers_bytes_max);
    std.debug.assert(production.max_response_headers <= ipc.max_request_header_count);
    std.debug.assert(production.max_response_header_bytes <= maxResponseHeaderBytesForIpc());
    std.debug.assert(production.max_active_fetches_per_worker_session != 0);
    std.debug.assert(production.max_active_fetches_per_security_cell != 0);
    std.debug.assert(production.max_body_chunk_bytes != 0);
    std.debug.assert(production.max_body_chunk_bytes <= ipc.egress_shared.body_pool_capacity);
    // An honest worker counts its fetches over the lifetime the gateway counts them and refuses
    // one past its own cap, so it never meets the gateway's.
    std.debug.assert(limits.worker.fetches_per_worker_max <= production.max_active_fetches_per_worker_session);
    // A security cell is one worker definition, whose pool holds at most `pool_workers_max`
    // workers, so honest workers never meet the cell's cap either.
    std.debug.assert(@as(usize, limits.pool.pool_workers_max) * limits.worker.fetches_per_worker_max <=
        production.max_active_fetches_per_security_cell);
    // A session's and a cell's record counts are `u32` (`fetch_table.List.len`, `Table.cells`).
    std.debug.assert(production.max_active_fetches_per_worker_session <= std.math.maxInt(u32));
    std.debug.assert(production.max_active_fetches_per_security_cell <= std.math.maxInt(u32));
}

/// A fetch's pool key: its security cell and the pool id of the network policy its token named.
pub const PoolIsolation = struct {
    security_cell_id: SecurityCellId = transport.zero_pool_isolation_id,
    policy_id: PoolIsolationId = transport.zero_pool_isolation_id,
};

/// The pool id of network policy `id`: the id's little-endian bytes, zero-padded to the
/// transport's key width. Pools never outlive their gateway, which decodes one image whose ids
/// never change, so the id alone tells two policies' pools apart.
pub fn poolPolicyId(id: network.PolicyId) PoolIsolationId {
    var pool_id = transport.zero_pool_isolation_id;
    std.mem.writeInt(network.PolicyId, pool_id[0..@sizeOf(network.PolicyId)], id, .little);
    return pool_id;
}

pub fn maxResponseHeaderBytesForIpc() usize {
    return ipc.max_message_bytes - @sizeOf(ipc.EgressFetchHeadHeader);
}

/// Checks a decoded fetch start's shape against `policy` before anything is allocated for it, an
/// inline body and a pooled one alike: nonzero fetch and body ids, the header count and bytes, and
/// the request body's length (the inline bytes, or the announced length of a pooled body). Returns
/// the response cap the fetch runs under, the policy's, since a start names none. Every error is
/// the worker's own packet's.
pub fn checkStart(fetch: ipc.EgressFetchStartView, policy: Policy) !usize {
    if (fetch.fetch_id == 0 or fetch.body_id == 0)
        return error.InvalidEgressGatewayFetchIdentity;
    if (fetch.headers.len > @min(ipc.max_request_header_count, policy.max_request_headers))
        return error.TooManyFetchHeaders;
    if (requestHeaderBytes(fetch.headers) > policy.max_request_header_bytes)
        return error.EgressGatewayRequestHeadersTooLarge;
    const pooled = (fetch.flags & ipc.egress_fetch_start_flag_body_pooled) != 0;
    const body_len: u64 = if (pooled) fetch.pooled_body_len else fetch.body.len;
    if (pooled and body_len == 0)
        return error.EgressGatewayRequestBodyLimitExceeded;
    if (body_len > policy.max_request_body_bytes)
        return error.EgressGatewayRequestBodyLimitExceeded;
    return policy.max_response_body_bytes;
}

fn requestHeaderBytes(headers: []const ipc.RequestHeader) usize {
    var total: usize = 0;
    for (headers) |header|
        total +|= header.name.len + header.value.len;
    return total;
}
