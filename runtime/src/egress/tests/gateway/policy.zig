//! The gateway's limits (`egress/gateway/policy.zig`): the shape check every fetch start passes
//! before anything is allocated for it, which refuses zero ids, too many or too large headers and
//! a request body past the limit, an empty announced pooled body included, and returns the
//! policy's response cap; and the pool id of a network policy, which tells every two policies
//! apart. Admission's order around the shape check is covered in `command_flow.zig`, and the
//! comptime block of `policy.zig` holds `production` inside the IPC's bounds. Lane:
//! egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const network = @import("collo_egress_client").network;

const policy = gateway.policy;

test "a start within every limit passes and runs under the policy's response cap" {
    const headers = [_]ipc.RequestHeader{
        .{ .name = "accept", .value = "*/*" },
        .{ .name = "x-trace", .value = "1" },
    };
    try std.testing.expectEqual(
        limits.http_body.MATERIALIZED_BODY_BYTES_MAX,
        try policy.checkStart(inlineStart(&headers, "hello"), policy.production),
    );
    // A start names no response cap, so a policy's own cap is the one a fetch gets.
    var lower = policy.production;
    lower.max_response_body_bytes = 4096;
    try std.testing.expectEqual(@as(usize, 4096), try policy.checkStart(inlineStart(&headers, ""), lower));
}

test "a start with a zero fetch id or a zero body id is refused" {
    var start = inlineStart(&.{}, "");
    start.fetch_id = 0;
    try std.testing.expectError(error.InvalidEgressGatewayFetchIdentity, policy.checkStart(start, policy.production));
    start = inlineStart(&.{}, "");
    start.body_id = 0;
    try std.testing.expectError(error.InvalidEgressGatewayFetchIdentity, policy.checkStart(start, policy.production));
}

test "a start with more headers than the policy allows is refused, and one at the count passes" {
    var limited = policy.production;
    limited.max_request_headers = 2;
    const two = [_]ipc.RequestHeader{
        .{ .name = "a", .value = "1" },
        .{ .name = "b", .value = "2" },
    };
    const three = two ++ [_]ipc.RequestHeader{.{ .name = "c", .value = "3" }};
    _ = try policy.checkStart(inlineStart(&two, ""), limited);
    try std.testing.expectError(error.TooManyFetchHeaders, policy.checkStart(inlineStart(&three, ""), limited));
}

test "a start whose header names and values pass the byte limit is refused, and one at it passes" {
    var limited = policy.production;
    limited.max_request_header_bytes = 10;
    // Names and values both count: 4 + 6 bytes.
    const at_limit = [_]ipc.RequestHeader{.{ .name = "name", .value = "valueX" }};
    const past_limit = [_]ipc.RequestHeader{.{ .name = "name", .value = "valueXY" }};
    _ = try policy.checkStart(inlineStart(&at_limit, ""), limited);
    try std.testing.expectError(
        error.EgressGatewayRequestHeadersTooLarge,
        policy.checkStart(inlineStart(&past_limit, ""), limited),
    );
}

test "an inline body past the request body limit is refused, and one at it passes" {
    var limited = policy.production;
    limited.max_request_body_bytes = 4;
    _ = try policy.checkStart(inlineStart(&.{}, "four"), limited);
    try std.testing.expectError(
        error.EgressGatewayRequestBodyLimitExceeded,
        policy.checkStart(inlineStart(&.{}, "five!"), limited),
    );
}

test "a pooled body announcing nothing or more than the request body limit is refused before any buffer exists" {
    var limited = policy.production;
    limited.max_request_body_bytes = 1024;
    _ = try policy.checkStart(pooledStart(1024), limited);
    try std.testing.expectError(error.EgressGatewayRequestBodyLimitExceeded, policy.checkStart(pooledStart(1025), limited));
    try std.testing.expectError(error.EgressGatewayRequestBodyLimitExceeded, policy.checkStart(pooledStart(0), limited));
    // The production limit is the pooled-upload ceiling the IPC carries.
    _ = try policy.checkStart(pooledStart(ipc.fetch_limits.request_body_pooled_bytes_max), policy.production);
    try std.testing.expectError(
        error.EgressGatewayRequestBodyLimitExceeded,
        policy.checkStart(pooledStart(ipc.fetch_limits.request_body_pooled_bytes_max + 1), policy.production),
    );
}

test "the pool id of a policy is its id in little-endian bytes, zero-padded, so two policies never share pools" {
    const zero: policy.PoolIsolationId = @splat(0);
    try std.testing.expectEqualSlices(u8, &zero, &policy.poolPolicyId(0));

    var expected: policy.PoolIsolationId = @splat(0);
    expected[0] = 0x02;
    expected[1] = 0x01;
    try std.testing.expectEqualSlices(u8, &expected, &policy.poolPolicyId(0x0102));

    // Every id a hello's table can hold has a pool id of its own.
    const ids = [_]network.PolicyId{ 0, 1, 2, 255, 256, std.math.maxInt(network.PolicyId) };
    for (ids, 0..) |id, index| {
        try std.testing.expectEqualSlices(u8, &policy.poolPolicyId(id), &policy.poolPolicyId(id));
        for (ids[index + 1 ..]) |other| {
            const first = policy.poolPolicyId(id);
            const second = policy.poolPolicyId(other);
            try std.testing.expect(!std.mem.eql(u8, &first, &second));
        }
    }
}

/// An inline start with `headers` and `body` and nonzero ids.
fn inlineStart(headers: []const ipc.RequestHeader, body: []const u8) ipc.EgressFetchStartView {
    return .{
        .fetch_id = 1,
        .egress_token = ipc.egress_token.none,
        .body_id = 2,
        .method = "POST",
        .url = "https://origin.test/",
        .headers = headers,
        .body = body,
    };
}

/// A start whose body comes through the upload pool, announcing `pooled_body_len` bytes.
fn pooledStart(pooled_body_len: u64) ipc.EgressFetchStartView {
    return .{
        .fetch_id = 1,
        .egress_token = ipc.egress_token.none,
        .body_id = 2,
        .flags = ipc.egress_fetch_start_flag_body_pooled,
        .method = "POST",
        .url = "https://origin.test/",
        .headers = &.{},
        .body = "",
        .pooled_body_len = pooled_body_len,
    };
}
