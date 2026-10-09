//! The limits and the network policies the egress gateway enforces on every fetch, the identity
//! of each in pool and session keys, and the worker pressure the body drain consults.
//!
//! Nothing configures the limits: every gateway runs `production`, and the server stamps the
//! fetch budgets of `production` into the tokens it mints. A `Policy` with other values exists
//! only in tests that drive an engine directly. The defaults cite the shared budgets in
//! `common/limits` and `common/ipc/fetch_limits.zig`, and `runtime/tests/contracts/limits.zig`
//! asserts that they keep doing so.
//!
//! The network policies form a `PolicyTable` that the server builds at boot and sends in each
//! gateway's hello (`control.zig`); a token names its route's entry by id, and the table never
//! changes for the life of a gateway. Until the configuration accepts `network`, the table holds
//! one entry, `public_https`, and every route maps to it; a test harness may loosen that entry
//! (`Manager.Config.network_policy` in `server/gateway/manager.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const egress = @import("collo_egress_client");

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
    max_active_fetches_per_worker_session: usize = 64,
    max_active_fetches_per_security_cell: usize = 1024,
    /// The budget the server stamps into each request token.
    max_fetches_per_request: usize = 16,
    /// The budget the server stamps into each boot token, for the fetches a worker session makes
    /// while its routes' modules evaluate. No byte budget exists apart from it: this count times
    /// the response caps bounds the bytes.
    max_fetches_per_boot: usize = 16,
    max_body_chunk_bytes: usize = limits.http_body.EGRESS_BODY_CHUNK_BYTES,
};

comptime {
    // A token carries its budget as a u32 (`common/ipc/egress_token.zig`).
    std.debug.assert(production.max_fetches_per_request <= std.math.maxInt(u32));
    std.debug.assert(production.max_fetches_per_boot <= std.math.maxInt(u32));
}

/// Network policies one table holds at most. A route's effective `network` setting is one entry,
/// so the table never needs more entries than the configuration has routes, and a token's u16
/// policy id reaches every one.
pub const policies_max: usize = limits.server.routes_max;

/// The id of the one entry every table holds until the configuration accepts `network`.
pub const public_https_id: u16 = 0;

pub const PolicyKind = enum {
    /// Any host whose resolved address the entry's flags admit, on every hop, redirects included.
    any_host,
};

/// One network policy as the gateway enforces it on each hop of a fetch whose token names it:
/// the host before DNS by `kind`, then the scheme and the address class. Loopback, link-local
/// and metadata addresses are denied whatever the flags say.
pub const NetworkPolicy = struct {
    kind: PolicyKind,
    /// Private network addresses pass the address check.
    allow_private_networks: bool,
    /// Plain `http:` URLs pass the scheme check.
    allow_http: bool,
};

/// The grant every route has until the configuration accepts `network`: any public host over
/// HTTPS.
pub const public_https: NetworkPolicy = .{
    .kind = .any_host,
    .allow_private_networks = false,
    .allow_http = false,
};

/// The network policies of one gateway, indexed by id from 0.
pub const PolicyTable = struct {
    entries: [policies_max]NetworkPolicy = undefined,
    count: u16 = 0,

    /// The table of one entry, `public_https_id`, that the server sends while every route maps to
    /// the same policy.
    pub fn single(entry: NetworkPolicy) PolicyTable {
        var table: PolicyTable = .{ .count = 1 };
        table.entries[public_https_id] = entry;
        return table;
    }

    /// The entry a verified token's `policy_id` names, or null for an id past the table, which
    /// only a server bug produces.
    pub fn lookup(self: *const PolicyTable, id: u16) ?*const NetworkPolicy {
        if (id < self.count)
            return &self.entries[id];
        return null;
    }

    pub fn slice(self: *const PolicyTable) []const NetworkPolicy {
        return self.entries[0..self.count];
    }

    comptime {
        std.debug.assert(policies_max <= std.math.maxInt(u16));
    }
};

/// The identity of table entry `id` in the keys of pooled connections, TLS sessions and shard
/// placement: fetches under two entries, or under one entry with other limits, never share a
/// pooled connection. `limits_id` is `policyIsolationId` of the gateway's limits. The gateway
/// computes one per entry when it takes its hello.
pub fn networkPolicyIsolationId(
    limits_id: PoolIsolationId,
    id: u16,
    entry: NetworkPolicy,
) PoolIsolationId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("collo-egress-network-policy-v1");
    hasher.update(&limits_id);
    hasher.update(std.mem.asBytes(&id));
    hasher.update(&[_]u8{
        @intFromEnum(entry.kind),
        @intFromBool(entry.allow_private_networks),
        @intFromBool(entry.allow_http),
    });
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    var isolation_id: PoolIsolationId = undefined;
    @memcpy(isolation_id[0..], digest[0..isolation_id.len]);
    return isolation_id;
}

/// What the gateway's probe reports about one worker session, which the body drain obeys
/// (`body_pump.drainBody`).
pub const WorkerPressure = struct {
    /// While set, no body pull is armed and no chunk is drained for this worker.
    pause_pulls: bool = false,
    /// Largest body chunk to publish to this worker, or 0 for no limit below the policy's
    /// `max_body_chunk_bytes`.
    max_body_chunk_bytes: usize = 0,
    /// Free bytes in the worker's body pool. A chunk the body drain takes leaves the engine's
    /// body queue for good, so the drain checks this before it takes one. The default reads as
    /// unconstrained: the gateway's probe always sets the field, and an engine without a probe,
    /// which only tests build, must not stall on a pool it cannot see.
    pool_free_bytes: usize = std.math.maxInt(usize),
    /// Free bytes in the worker's completion ring. A fragmented pool can split one body chunk
    /// into one ring descriptor per pool block, so the drain checks the ring against that worst
    /// case before it takes a chunk; a publish that found the ring full after the drain would
    /// lose the drained bytes. Defaults like `pool_free_bytes`.
    completion_ring_free_bytes: usize = std.math.maxInt(usize),
};

pub const PoolIsolation = struct {
    security_cell_id: SecurityCellId = transport.zero_pool_isolation_id,
    policy_id: PoolIsolationId = transport.zero_pool_isolation_id,
};

pub fn validate(policy: Policy) !void {
    if (policy.max_response_body_bytes == 0 or
        policy.max_encoded_response_bytes == 0 or
        policy.max_request_body_bytes > ipc.fetch_limits.request_body_pooled_bytes_max or
        policy.max_request_headers > ipc.max_request_header_count or
        policy.max_request_header_bytes > ipc.fetch_limits.request_headers_bytes_max or
        policy.max_response_headers > ipc.max_request_header_count or
        policy.max_response_header_bytes > maxResponseHeaderBytesForIpc() or
        policy.max_active_fetches_per_worker_session == 0 or
        policy.max_active_fetches_per_security_cell == 0 or
        policy.max_fetches_per_request == 0 or
        policy.max_fetches_per_boot == 0 or
        policy.max_body_chunk_bytes == 0 or
        policy.max_body_chunk_bytes > ipc.egress_shared.body_pool_capacity)
    {
        return error.InvalidEgressGatewayResponseBodyLimit;
    }
}

/// The identity of the limits in `policy`, which `networkPolicyIsolationId` folds into the key of
/// every table entry: fetches under limits that differ in any field never share a pooled
/// connection.
pub fn policyIsolationId(policy: Policy) PoolIsolationId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("collo-egress-policy-v1");
    hasher.update(std.mem.asBytes(&policy.max_response_body_bytes));
    hasher.update(std.mem.asBytes(&policy.max_encoded_response_bytes));
    hasher.update(std.mem.asBytes(&policy.max_request_body_bytes));
    hasher.update(std.mem.asBytes(&policy.max_request_headers));
    hasher.update(std.mem.asBytes(&policy.max_request_header_bytes));
    hasher.update(std.mem.asBytes(&policy.max_response_headers));
    hasher.update(std.mem.asBytes(&policy.max_response_header_bytes));
    hasher.update(std.mem.asBytes(&policy.socket_timeout_ms));
    hasher.update(std.mem.asBytes(&policy.enable_http2));
    hasher.update(std.mem.asBytes(&policy.max_redirects));
    hasher.update(std.mem.asBytes(&policy.max_redirect_drain_bytes));
    hasher.update(std.mem.asBytes(&policy.max_active_fetches_per_worker_session));
    hasher.update(std.mem.asBytes(&policy.max_active_fetches_per_security_cell));
    hasher.update(std.mem.asBytes(&policy.max_fetches_per_request));
    hasher.update(std.mem.asBytes(&policy.max_fetches_per_boot));
    hasher.update(std.mem.asBytes(&policy.max_body_chunk_bytes));
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    var id: PoolIsolationId = undefined;
    @memcpy(id[0..], digest[0..id.len]);
    return id;
}

pub fn maxResponseHeaderBytesForIpc() usize {
    return ipc.max_message_bytes - @sizeOf(ipc.EgressFetchHeadHeader);
}

/// The response body cap of one fetch: the cap the worker requested, or `gateway_limit` when it
/// requested none (0). A request above `gateway_limit` fails with
/// `error.EgressGatewayResponseBodyLimitExceeded` instead of being lowered.
pub fn resolveMaxResponseBodyBytes(requested: u64, gateway_limit: usize) !usize {
    if (gateway_limit == 0)
        return error.InvalidEgressGatewayResponseBodyLimit;
    if (requested == 0)
        return gateway_limit;
    if (requested > @as(u64, @intCast(gateway_limit)))
        return error.EgressGatewayResponseBodyLimitExceeded;
    return @intCast(requested);
}
