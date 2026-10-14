//! Tests of HTTP/2 pool policy that need no origin: the lifecycle deadline
//! combines idle timeout and connection age, and the origin key that names
//! pooled connections, dials and TLS sessions separates authorities, schemes,
//! ports, security cells, policies and private-network verdicts while
//! leaving per-fetch limits out.

const std = @import("std");
const network_policy = @import("../network_policy.zig");
const test_support = @import("support.zig");
const pool = test_support.pool;
const transport = test_support.transport;

/// Every request here names a public host over HTTPS on port 443.
const public_https = network_policy.public_https;

test "http2 pool lifecycle deadline uses idle timeout and connection age" {
    const config = pool.Config{
        .idle_timeout_ns = 100,
        .max_connection_age_ns = 1_000,
    };
    try std.testing.expectEqual(@as(u64, 150), pool.lifecycleDeadlineNs(0, 50, config));
    try std.testing.expectEqual(@as(u64, 1_000), pool.lifecycleDeadlineNs(0, 950, config));

    const age_only = pool.Config{
        .idle_timeout_ns = 0,
        .max_connection_age_ns = 500,
    };
    try std.testing.expectEqual(@as(u64, 600), pool.lifecycleDeadlineNs(100, 200, age_only));

    const disabled = pool.Config{
        .idle_timeout_ns = 0,
        .max_connection_age_ns = 0,
    };
    try std.testing.expectEqual(std.math.maxInt(u64), pool.lifecycleDeadlineNs(100, 200, disabled));
}

fn keyFor(url: []const u8, config: transport.Config) !transport.OriginKey {
    var plan = try transport.prepareRequest(std.testing.allocator, url, "GET", &.{}, config);
    defer plan.deinit();
    return plan.origin_key;
}

test "origin key leaves per-fetch limits out" {
    const base = try keyFor("https://example.com/one", .{ .network = public_https });
    // Another path and other connection limits name the same origin: a
    // fetch's own response cap applies per stream.
    const limited = try keyFor("https://Example.com/two", .{
        .network = public_https,
        .http2_max_active_streams = 4,
        .http2_max_outgoing_buffer_bytes = 512 * 1024,
        .wire_buffer_bytes = 256 * 1024,
        .max_response_body_bytes = 1024,
        .socket_timeout_ms = 1_000,
    });
    try std.testing.expect(base.eql(&limited));
}

test "origin key separates authorities, schemes, ports, cells and policies" {
    const config: transport.Config = .{ .network = network_policy.public_http_and_https };
    const base = try keyFor("https://a.example/resource", config);

    const other_host = try keyFor("https://b.example/resource", config);
    try std.testing.expect(!base.eql(&other_host));

    const plain = try keyFor("http://a.example/resource", config);
    try std.testing.expect(!base.eql(&plain));

    var security_cell_id: transport.PoolIsolationId = [_]u8{0} ** 16;
    security_cell_id[0] = 1;
    var cell_config = config;
    cell_config.pool_security_cell_id = security_cell_id;
    const other_cell = try keyFor("https://a.example/resource", cell_config);
    try std.testing.expect(!base.eql(&other_cell));

    var policy_id: transport.PoolIsolationId = [_]u8{0} ** 16;
    policy_id[0] = 1;
    var policy_config = config;
    policy_config.pool_policy_id = policy_id;
    const other_policy = try keyFor("https://a.example/resource", policy_config);
    try std.testing.expect(!base.eql(&other_policy));

    var insecure_config = config;
    insecure_config.insecure_tls = true;
    const insecure = try keyFor("https://a.example/resource", insecure_config);
    try std.testing.expect(!base.eql(&insecure));
}

test "origin key separates hops whose admission allows private addresses" {
    // One host under a setting that names it with allowPrivateNetworks, and
    // under `*` alone, which never allows them. A connection dialed under
    // the first may have reached a private address the second's dial would
    // have refused, so it must never serve the second.
    const network = transport.network;
    const private_grant: network.Grant = .{
        .allow_http = false,
        .allow_private_networks = true,
        .any = false,
        .names = &.{.{ .host = .{ .name = "a.example" }, .port = 0 }},
        .suffixes = &.{},
        .ipv4 = &.{},
        .ipv6 = &.{},
    };
    const private_policy: network.Policy = .{ .grants = &.{&private_grant} };

    const private_key = try keyFor("https://a.example/resource", .{ .network = private_policy });
    const public_key = try keyFor("https://a.example/resource", .{ .network = public_https });
    try std.testing.expect(private_key.allow_private_networks);
    try std.testing.expect(!public_key.allow_private_networks);
    try std.testing.expect(!private_key.eql(&public_key));
}
