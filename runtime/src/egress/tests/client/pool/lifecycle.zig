//! Tests of HTTP/2 pool policy that need no origin: a disabled pool refuses
//! before DNS, the lifecycle deadline combines idle timeout and connection
//! age, and the pool key separates connections by authority, HTTP/2 limits
//! and isolation identities.

const std = @import("std");
const network_policy = @import("../network_policy.zig");
const test_support = @import("support.zig");
const pool = test_support.pool;
const data_io = test_support.data_io;
const readiness = test_support.readiness;
const transport = test_support.transport;
const TestH2Origin = test_support.TestH2Origin;
const collo_test_h2_origin_start = test_support.collo_test_h2_origin_start;
const collo_test_h2_origin_stop = test_support.collo_test_h2_origin_stop;
const collo_test_h2_origin_last_error = test_support.collo_test_h2_origin_last_error;
const collo_test_h2_origin_stream_count = test_support.collo_test_h2_origin_stream_count;
const collo_test_h2_origin_selected_alpn = test_support.collo_test_h2_origin_selected_alpn;
const test_h2_origin_alpn_h2 = test_support.test_h2_origin_alpn_h2;
const test_h2_origin_alpn_http11 = test_support.test_h2_origin_alpn_http11;
const test_alpn_h2 = test_support.test_alpn_h2;
const routableLocalIpv4 = test_support.routableLocalIpv4;
const FakeWriteTransport = test_support.FakeWriteTransport;

/// Every request here names a public host over HTTPS on port 443.
const public_https = network_policy.public_https;

test "http2 egress pool rejects unknown origins before DNS when disabled" {
    var client_pool = pool.Pool.init(std.testing.allocator, .{ .max_entries = 0 });
    defer client_pool.deinit();

    const result = try client_pool.startRequest(.{
        .allocator = std.testing.allocator,
        .url = "https://does-not-exist.invalid/",
        .method = "GET",
        .body = "",
        .headers = &.{},
        .config = .{ .network = public_https },
    });
    switch (result) {
        .failed => |err| try std.testing.expectEqual(error.Http2PoolDisabled, err),
        else => return error.UnexpectedHttp2Pending,
    }
}

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

test "http2 pool key includes normalized HTTP2 limits" {
    var plan = try transport.prepareRequest(
        std.testing.allocator,
        "https://example.com/resource",
        "GET",
        &.{},
        .{ .network = public_https },
    );
    defer plan.deinit();

    var key = try pool.Key.init(std.testing.allocator, &plan, .{
        .network = public_https,
        .http2_max_active_streams = 4,
        .http2_stream_receive_window = 2 * 1024 * 1024,
        .http2_max_outgoing_buffer_bytes = 512 * 1024,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
    });
    defer key.deinit(std.testing.allocator);

    try std.testing.expect(key.matches(&plan, .{
        .network = public_https,
        .http2_max_active_streams = 4,
        .http2_stream_receive_window = 2 * 1024 * 1024,
        .http2_max_outgoing_buffer_bytes = 512 * 1024,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
    }));
    try std.testing.expect(!key.matches(&plan, .{
        .network = public_https,
        .http2_max_active_streams = 8,
        .http2_stream_receive_window = 2 * 1024 * 1024,
        .http2_max_outgoing_buffer_bytes = 512 * 1024,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
    }));
    try std.testing.expect(!key.matches(&plan, .{
        .network = public_https,
        .http2_max_active_streams = 4,
        .http2_stream_receive_window = 2 * 1024 * 1024,
        .http2_max_outgoing_buffer_bytes = 1024 * 1024,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
    }));
    try std.testing.expect(!key.matches(&plan, .{
        .network = public_https,
        .http2_max_active_streams = 4,
        .http2_stream_receive_window = 2 * 1024 * 1024,
        .http2_max_outgoing_buffer_bytes = 512 * 1024,
        .tls_ciphertext_buffer_bytes = 1024 * 1024,
    }));
    var security_cell_id: transport.PoolIsolationId = [_]u8{0} ** 16;
    security_cell_id[0] = 1;
    try std.testing.expect(!key.matches(&plan, .{
        .network = public_https,
        .http2_max_active_streams = 4,
        .http2_stream_receive_window = 2 * 1024 * 1024,
        .http2_max_outgoing_buffer_bytes = 512 * 1024,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
        .pool_security_cell_id = security_cell_id,
    }));
    var policy_id: transport.PoolIsolationId = [_]u8{0} ** 16;
    policy_id[0] = 1;
    try std.testing.expect(!key.matches(&plan, .{
        .network = public_https,
        .http2_max_active_streams = 4,
        .http2_stream_receive_window = 2 * 1024 * 1024,
        .http2_max_outgoing_buffer_bytes = 512 * 1024,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
        .pool_policy_id = policy_id,
    }));
}

test "http2 pool key does not coalesce different authorities" {
    var plan = try transport.prepareRequest(
        std.testing.allocator,
        "https://a.example/resource",
        "GET",
        &.{},
        .{ .network = public_https },
    );
    defer plan.deinit();
    var other = try transport.prepareRequest(
        std.testing.allocator,
        "https://b.example/resource",
        "GET",
        &.{},
        .{ .network = public_https },
    );
    defer other.deinit();

    const config: transport.Config = .{ .network = public_https };
    var key = try pool.Key.init(std.testing.allocator, &plan, config);
    defer key.deinit(std.testing.allocator);

    try std.testing.expect(key.matches(&plan, config));
    try std.testing.expect(!key.matches(&other, config));
}
