//! The gateway's limits (`egress/gateway/policy.zig`): the isolation id of each policy of the
//! hello's image, which changes with the policy's id, with the image and with the gateway's
//! limits, the limits' own identity over every field, and limits a worker sends that cannot raise
//! the gateway's. The image's layout and its policies are covered in `common/tests/network/`,
//! their lookup by a verified token's policy id in `control_flow.zig` and admission, which refuses
//! an id past the table, in `worker_flow.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const limits = @import("collo_limits");
const ipc = @import("collo_ipc");
const network = @import("collo_egress_client").network;

const policy_image = @import("support/policy_image.zig");

const policy = gateway.policy;

test "each policy of an image has its own isolation id, which changes with its id, its image and the limits" {
    const standard = try policy_image.standard(std.testing.allocator);
    defer std.testing.allocator.free(standard);
    // Another image whose policy 1 grants exactly what the standard image's policy 1 grants, so
    // only the digest tells the two apart.
    const any_host = [_]network.Pattern{.{ .host = .any, .port = 0 }};
    const name = [_]network.Pattern{.{ .host = .{ .name = "api.example.test" }, .port = 0 }};
    const settings = [_]network.Setting{ .{ .allow = &any_host }, .{ .allow = &name } };
    const first_members = [_]usize{0};
    const second_members = [_]usize{1};
    const policies = [_][]const usize{ &first_members, &second_members };
    const other = try policy_image.encode(std.testing.allocator, &settings, &policies);
    defer std.testing.allocator.free(other);
    const standard_digest = policy_image.digest(standard);
    const other_digest = policy_image.digest(other);
    try std.testing.expect(!std.mem.eql(u8, &standard_digest, &other_digest));

    const limits_id = policy.policyIsolationId(policy.production);
    const base = policy.networkPolicyIsolationId(limits_id, standard_digest, policy_image.public_https_id);

    // Equal inputs give equal ids, so a fetch's pooled connections are found again.
    try expectSameId(base, policy.networkPolicyIsolationId(limits_id, standard_digest, policy_image.public_https_id));

    // Two policies of one image never share pools.
    for (0..policy_image.standard_policy_count) |index| {
        const id: network.PolicyId = @intCast(index);
        const isolation_id = policy.networkPolicyIsolationId(limits_id, standard_digest, id);
        for (index + 1..policy_image.standard_policy_count) |other_index| {
            const other_id: network.PolicyId = @intCast(other_index);
            try expectOtherId(isolation_id, policy.networkPolicyIsolationId(limits_id, standard_digest, other_id));
        }
    }

    // One policy id of two images never shares pools.
    try expectOtherId(base, policy.networkPolicyIsolationId(limits_id, other_digest, policy_image.public_https_id));

    // Nor does one policy under other limits.
    var other_limits = policy.production;
    other_limits.max_redirects -= 1;
    const other_limits_id = policy.policyIsolationId(other_limits);
    try expectOtherId(
        base,
        policy.networkPolicyIsolationId(other_limits_id, standard_digest, policy_image.public_https_id),
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
    // The network flags are no limit of the gateway's: each grant of a policy carries its own.
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
