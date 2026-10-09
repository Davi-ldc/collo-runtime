//! The gateway's limits and network policies (`egress/gateway/policy.zig`): the table the hello
//! carries and its lookup by a token's policy id, the `public_https` entry every route has until
//! the configuration accepts `network`, the isolation id of each entry, which changes with the
//! entry's id, its flags and the gateway's limits, the limits' own identity over every field, and
//! limits a worker sends that cannot raise the gateway's. Admission, which looks a verified
//! token's policy up and refuses an id past the table, is covered in `worker_flow.zig`. Lane:
//! egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const limits = @import("collo_limits");
const ipc = @import("collo_ipc");

const policy = gateway.policy;

test "the single table holds public_https as entry 0 and nothing past it" {
    const table = policy.PolicyTable.single(policy.public_https);
    try std.testing.expectEqual(@as(u16, 0), policy.public_https_id);
    try std.testing.expectEqual(@as(u16, 1), table.count);
    try std.testing.expectEqual(@as(usize, 1), table.slice().len);

    const entry = table.lookup(policy.public_https_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(&table.slice()[0], entry);
    // Any public host over HTTPS: private addresses and plain `http:` stay denied.
    try std.testing.expectEqual(policy.PolicyKind.any_host, entry.kind);
    try std.testing.expect(!entry.allow_private_networks);
    try std.testing.expect(!entry.allow_http);

    try std.testing.expect(table.lookup(1) == null);
    try std.testing.expect(table.lookup(std.math.maxInt(u16)) == null);

    // A gateway holds the empty table until its hello, and that table names no entry at all.
    const empty: policy.PolicyTable = .{};
    try std.testing.expect(empty.lookup(policy.public_https_id) == null);
    try std.testing.expectEqual(@as(usize, 0), empty.slice().len);
}

test "a table looks up every id below its count and none past it" {
    var table: policy.PolicyTable = .{ .count = 3 };
    table.entries[0] = policy.public_https;
    table.entries[1] = .{ .kind = .any_host, .allow_private_networks = true, .allow_http = false };
    table.entries[2] = .{ .kind = .any_host, .allow_private_networks = false, .allow_http = true };
    // A slot past the count holds an entry, which no lookup may return.
    table.entries[3] = .{ .kind = .any_host, .allow_private_networks = true, .allow_http = true };

    for (0..table.count) |index| {
        const id: u16 = @intCast(index);
        const entry = table.lookup(id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(&table.entries[index], entry);
    }
    try std.testing.expect(table.lookup(3) == null);
    try std.testing.expectEqual(@as(usize, 3), table.slice().len);
    try std.testing.expectEqual(&table.entries[0], &table.slice()[0]);
}

test "a table holds an entry for every route the configuration can have" {
    try std.testing.expectEqual(limits.server.routes_max, policy.policies_max);
    try std.testing.expect(policy.policies_max <= std.math.maxInt(u16));

    var table: policy.PolicyTable = .{ .count = policy.policies_max };
    for (table.entries[0..policy.policies_max]) |*entry|
        entry.* = policy.public_https;
    const last: u16 = policy.policies_max - 1;
    try std.testing.expectEqual(&table.entries[last], table.lookup(last).?);
    try std.testing.expect(table.lookup(last + 1) == null);
}

test "each table entry has its own isolation id, which changes with its id, flags and limits" {
    const limits_id = policy.policyIsolationId(policy.production);
    const base = policy.networkPolicyIsolationId(limits_id, policy.public_https_id, policy.public_https);

    // Equal inputs give equal ids, so a fetch's pooled connections are found again.
    try expectSameId(base, policy.networkPolicyIsolationId(limits_id, 0, policy.public_https));

    // Two entries of one table never share pools, even with equal flags.
    try expectOtherId(base, policy.networkPolicyIsolationId(limits_id, 1, policy.public_https));
    try expectOtherId(
        policy.networkPolicyIsolationId(limits_id, 1, policy.public_https),
        policy.networkPolicyIsolationId(limits_id, 2, policy.public_https),
    );

    const flag_variants = [_]policy.NetworkPolicy{
        .{ .kind = .any_host, .allow_private_networks = true, .allow_http = false },
        .{ .kind = .any_host, .allow_private_networks = false, .allow_http = true },
        .{ .kind = .any_host, .allow_private_networks = true, .allow_http = true },
    };
    for (flag_variants, 0..) |variant, index| {
        const variant_id = policy.networkPolicyIsolationId(limits_id, 0, variant);
        try expectOtherId(base, variant_id);
        for (flag_variants[index + 1 ..]) |other|
            try expectOtherId(variant_id, policy.networkPolicyIsolationId(limits_id, 0, other));
    }

    var other_limits = policy.production;
    other_limits.max_redirects -= 1;
    const other_limits_id = policy.policyIsolationId(other_limits);
    try expectOtherId(
        base,
        policy.networkPolicyIsolationId(other_limits_id, policy.public_https_id, policy.public_https),
    );
}

test "the limits' identity changes with every field of the limits" {
    const base = policy.Policy{};
    const base_id = policy.policyIsolationId(base);
    inline for (std.meta.fields(policy.Policy)) |field| {
        var changed = base;
        const value = &@field(changed, field.name);
        switch (@typeInfo(field.type)) {
            .bool => value.* = !value.*,
            .int => value.* = if (value.* == std.math.maxInt(field.type)) value.* - 1 else value.* + 1,
            else => @compileError("no variation for Policy." ++ field.name),
        }
        const changed_id = policy.policyIsolationId(changed);
        if (std.mem.eql(u8, &base_id, &changed_id)) {
            std.debug.print("policyIsolationId ignores Policy.{s}\n", .{field.name});
            return error.TestUnexpectedResult;
        }
    }
    // The network flags are no limit of the gateway's: each table entry carries its own.
    try std.testing.expect(!@hasField(policy.Policy, "allow_plain_http"));
    try std.testing.expect(!@hasField(policy.Policy, "allow_private_networks"));
}

test "egress gateway response body limit cannot be enlarged by worker IPC" {
    const gateway_limit = limits.http_body.MATERIALIZED_BODY_BYTES_MAX;

    try std.testing.expectEqual(
        gateway_limit,
        try policy.resolveMaxResponseBodyBytes(0, gateway_limit),
    );
    try std.testing.expectEqual(
        @as(usize, 1024),
        try policy.resolveMaxResponseBodyBytes(1024, gateway_limit),
    );
    try std.testing.expectError(
        error.EgressGatewayResponseBodyLimitExceeded,
        policy.resolveMaxResponseBodyBytes(gateway_limit + 1, gateway_limit),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayResponseBodyLimit,
        policy.resolveMaxResponseBodyBytes(0, 0),
    );
}

test "egress gateway request body policy is capped by the pooled upload limit" {
    try std.testing.expectEqual(
        ipc.fetch_limits.request_body_pooled_bytes_max,
        policy.default_max_request_body_bytes,
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayResponseBodyLimit,
        policy.validate(.{
            .max_request_body_bytes = ipc.fetch_limits.request_body_pooled_bytes_max + 1,
        }),
    );
}

test "egress gateway rejects impossible encoded response policy" {
    try std.testing.expectError(
        error.InvalidEgressGatewayResponseBodyLimit,
        gateway.engine.Engine.init(std.testing.allocator, .{
            .policy = .{
                .max_encoded_response_bytes = 0,
            },
        }),
    );
}

test "egress gateway rejects impossible body chunk policy" {
    try std.testing.expectError(
        error.InvalidEgressGatewayResponseBodyLimit,
        gateway.engine.Engine.init(std.testing.allocator, .{
            .policy = .{
                .max_body_chunk_bytes = 0,
            },
        }),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayResponseBodyLimit,
        gateway.engine.Engine.init(std.testing.allocator, .{
            .policy = .{
                .max_body_chunk_bytes = ipc.egress_shared.body_pool_capacity + 1,
            },
        }),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayResponseBodyLimit,
        gateway.engine.Engine.init(std.testing.allocator, .{
            .policy = .{
                .max_request_header_bytes = ipc.fetch_limits.request_headers_bytes_max + 1,
            },
        }),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayResponseBodyLimit,
        gateway.engine.Engine.init(std.testing.allocator, .{
            .policy = .{
                .max_fetches_per_request = 0,
            },
        }),
    );
    try std.testing.expectError(
        error.InvalidEgressGatewayResponseBodyLimit,
        gateway.engine.Engine.init(std.testing.allocator, .{
            .policy = .{
                .max_active_fetches_per_security_cell = 0,
            },
        }),
    );
}

fn expectSameId(expected: policy.PoolIsolationId, actual: policy.PoolIsolationId) !void {
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

fn expectOtherId(first: policy.PoolIsolationId, second: policy.PoolIsolationId) !void {
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
