//! Tests for request plans, redirect rewriting, content-encoding parsing, and
//! the limits a transport config derives for HTTP/2 and for the body pump
//! both protocols share. They call the builders directly and never touch the
//! network.

const std = @import("std");
const network_policy = @import("../network_policy.zig");
const test_support = @import("support.zig");
const transport = test_support.transport;
const decompress = test_support.decompress;
const containsHeader = test_support.containsHeader;

const network = transport.network;
const https_only: transport.Config = .{ .network = network_policy.public_https };
const http_and_https: transport.Config = .{ .network = network_policy.public_http_and_https };

const example_com_443_grant: network.Grant = .{
    .allow_http = true,
    .allow_private_networks = false,
    .any = false,
    .names = &.{.{ .host = .{ .name = "example.com" }, .port = 443 }},
    .suffixes = &.{},
    .ipv4 = &.{},
    .ipv6 = &.{},
};
/// `example.com:443` for plain HTTP and HTTPS.
const example_com_443: network.Policy = .{ .grants = &.{&example_com_443_grant} };

test "egress client core rejects unsupported protocols without a task runtime" {
    try std.testing.expectError(error.UnsupportedFetchProtocol, transport.prepareRequest(
        std.testing.allocator,
        "file:///tmp/no-network",
        "GET",
        &.{},
        https_only,
    ));
}

test "egress request plan does not resolve network addresses" {
    var plan = try transport.prepareRequest(
        std.testing.allocator,
        "https://does-not-exist.invalid/hello",
        "GET",
        &.{},
        https_only,
    );
    defer plan.deinit();

    try std.testing.expectEqualStrings("does-not-exist.invalid", plan.target.authority_host);
    try std.testing.expectEqualStrings("/hello", plan.request_target);
}

test "egress request plan prepares shared http1 and http2 request state" {
    var origins: network_policy.Origins = .{};
    try origins.init("93.184.216.34", &.{8443});
    const headers = [_]transport.Header{.{ .name = "accept", .value = "text/plain" }};
    var plan = try transport.prepareRequest(
        std.testing.allocator,
        "https://93.184.216.34:8443/hello?x=1",
        "get",
        &headers,
        .{ .network = origins.policy() },
    );
    defer plan.deinit();

    try std.testing.expectEqualStrings("GET", plan.method);
    try std.testing.expectEqualStrings("/hello?x=1", plan.request_target);
    try std.testing.expectEqualStrings("93.184.216.34:8443", plan.request_authority);
    try std.testing.expectEqual(@as(usize, 2), plan.parsed_headers.headers.items.len);
    // The HTTP/2 head carries the same validated fields the HTTP/1 head
    // serializes, the default accept-encoding included.
    const h2_head = plan.h2RequestHead("");
    try std.testing.expectEqualStrings("https", h2_head.scheme);
    try std.testing.expectEqualStrings("93.184.216.34:8443", h2_head.authority);
    try std.testing.expectEqualStrings("/hello?x=1", h2_head.path);
    try std.testing.expectEqual(@as(usize, 2), h2_head.headers.len);
    try std.testing.expectEqualStrings("accept", h2_head.headers[0].name);
    try std.testing.expectEqualStrings("text/plain", h2_head.headers[0].value);
}

test "egress request plan accepts uppercase schemes and HTTP method tokens" {
    _ = try transport.parseTarget(network_policy.public_https, "HTTPS://example.com/data");
    _ = try transport.parseTarget(network_policy.public_http_and_https, "HTTP://example.com/data");

    var custom = try transport.prepareRequest(
        std.testing.allocator,
        "HTTPS://example.com/data",
        "REPORT",
        &.{},
        https_only,
    );
    defer custom.deinit();
    try std.testing.expectEqualStrings("REPORT", custom.method);
    try std.testing.expect(std.mem.startsWith(u8, custom.parsed_headers.headers.items[0].value, "gzip, deflate"));

    try std.testing.expectError(error.UnsupportedFetchMethod, transport.prepareRequest(
        std.testing.allocator,
        "https://example.com/data",
        "CONNECT",
        &.{},
        https_only,
    ));
    try std.testing.expectError(error.UnsupportedFetchMethod, transport.prepareRequest(
        std.testing.allocator,
        "https://example.com/data",
        "bad method",
        &.{},
        https_only,
    ));
}

test "egress request plan omits scheme-default ports from the authority" {
    var tls_default = try transport.prepareRequest(
        std.testing.allocator,
        "https://example.com:443/x",
        "GET",
        &.{},
        https_only,
    );
    defer tls_default.deinit();
    try std.testing.expectEqualStrings("example.com", tls_default.request_authority);

    var plain_default = try transport.prepareRequest(
        std.testing.allocator,
        "http://example.com:80/x",
        "GET",
        &.{},
        http_and_https,
    );
    defer plain_default.deinit();
    try std.testing.expectEqualStrings("example.com", plain_default.request_authority);

    var cross_scheme = try transport.prepareRequest(
        std.testing.allocator,
        "http://example.com:443/x",
        "GET",
        &.{},
        .{ .network = example_com_443 },
    );
    defer cross_scheme.deinit();
    try std.testing.expectEqualStrings("example.com:443", cross_scheme.request_authority);
}

test "egress content-encoding parsing aliases x-gzip and passes unknown codings through" {
    const Encoding = decompress.Encoding;
    try std.testing.expectEqual(
        Encoding.gzip,
        try decompress.encodingFromHeaders(&[_]transport.Header{
            .{ .name = "content-encoding", .value = "x-gzip" },
        }),
    );
    try std.testing.expectEqual(
        Encoding.identity,
        try decompress.encodingFromHeaders(&[_]transport.Header{
            .{ .name = "content-encoding", .value = "zstd" },
        }),
    );
    try std.testing.expectEqual(
        Encoding.identity,
        try decompress.encodingFromHeaders(&[_]transport.Header{
            .{ .name = "content-encoding", .value = "gzip, zstd" },
        }),
    );
    try std.testing.expectEqual(
        Encoding.br,
        try decompress.encodingFromHeaders(&[_]transport.Header{
            .{ .name = "content-encoding", .value = "identity, br, identity" },
        }),
    );
    try std.testing.expectError(
        error.UnsupportedCompressionMethod,
        decompress.encodingFromHeaders(&[_]transport.Header{
            .{ .name = "content-encoding", .value = "gzip, br" },
        }),
    );
}

test "egress request plan preserves explicit accept-encoding" {
    const headers = [_]transport.Header{.{ .name = "accept-encoding", .value = "identity" }};
    var plan = try transport.prepareRequest(
        std.testing.allocator,
        "https://example.com/data",
        "GET",
        &headers,
        https_only,
    );
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.parsed_headers.headers.items.len);
    try std.testing.expectEqualStrings("identity", plan.parsed_headers.headers.items[0].value);
}

test "egress request plan rejects protocol-managed request headers before connect" {
    const headers = [_]transport.Header{
        .{ .name = "content-length", .value = "10" },
    };
    try std.testing.expectError(error.ForbiddenRequestHeader, transport.prepareRequest(
        std.testing.allocator,
        "https://example.com/data",
        "POST",
        &headers,
        https_only,
    ));
}

test "egress redirect target rewrites method and strips unsafe headers" {
    const Header = struct { name: []const u8, value: []const u8 };
    const original_headers = [_]transport.Header{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "content-length", .value = "7" },
        .{ .name = "authorization", .value = "Bearer x" },
        .{ .name = "x-keep", .value = "yes" },
    };
    const rewritten = try transport.redirectTarget(
        std.testing.allocator,
        "https://example.com/a/b",
        "POST",
        &original_headers,
        302,
        &[_]Header{.{ .name = "location", .value = "../next" }},
        .{},
        0,
    ) orelse return error.ExpectedRedirectTarget;
    defer {
        std.testing.allocator.free(rewritten.url);
        std.testing.allocator.free(rewritten.method);
        transport.freeHeaders(std.testing.allocator, rewritten.headers);
    }
    try std.testing.expectEqualStrings("https://example.com/next", rewritten.url);
    try std.testing.expectEqualStrings("GET", rewritten.method);
    try std.testing.expectEqual(transport.RedirectBody.drop, rewritten.body);
    try std.testing.expect(!containsHeader(rewritten.headers, "content-type"));
    try std.testing.expect(!containsHeader(rewritten.headers, "content-length"));
    try std.testing.expect(containsHeader(rewritten.headers, "authorization"));
    try std.testing.expect(containsHeader(rewritten.headers, "x-keep"));

    const cross_origin_headers = [_]transport.Header{
        .{ .name = "authorization", .value = "Bearer x" },
        .{ .name = "cookie", .value = "a=b" },
        .{ .name = "x-keep", .value = "yes" },
    };
    const cross_origin = try transport.redirectTarget(
        std.testing.allocator,
        "https://example.com/a",
        "GET",
        &cross_origin_headers,
        307,
        &[_]Header{.{ .name = "location", .value = "https://other.example/path" }},
        .{},
        0,
    ) orelse return error.ExpectedRedirectTarget;
    defer {
        std.testing.allocator.free(cross_origin.url);
        std.testing.allocator.free(cross_origin.method);
        transport.freeHeaders(std.testing.allocator, cross_origin.headers);
    }
    try std.testing.expectEqualStrings("https://other.example/path", cross_origin.url);
    try std.testing.expectEqualStrings("GET", cross_origin.method);
    try std.testing.expectEqual(transport.RedirectBody.keep, cross_origin.body);
    try std.testing.expect(!containsHeader(cross_origin.headers, "authorization"));
    try std.testing.expect(!containsHeader(cross_origin.headers, "cookie"));
    try std.testing.expect(containsHeader(cross_origin.headers, "x-keep"));

    const userinfo_target = try transport.redirectTarget(
        std.testing.allocator,
        "https://example.com/a",
        "GET",
        &.{},
        302,
        &[_]Header{.{ .name = "location", .value = "https://user:pass@other.example/secret" }},
        .{},
        0,
    ) orelse return error.ExpectedRedirectTarget;
    defer {
        std.testing.allocator.free(userinfo_target.url);
        std.testing.allocator.free(userinfo_target.method);
        transport.freeHeaders(std.testing.allocator, userinfo_target.headers);
    }
    try std.testing.expectEqualStrings("https://other.example/secret", userinfo_target.url);
}

test "egress config exposes HTTP2 limits for pooled sessions" {
    const limits = (transport.Config{
        .network = network_policy.public_https,
        .max_pending_decoded_body_bytes = 2 * 1024 * 1024,
        .http2_max_active_streams = 7,
        .http2_stream_receive_window = 2 * 1024 * 1024,
        .http2_conn_receive_window = 8 * 1024 * 1024,
        .http2_receive_window_update_threshold = 256 * 1024,
        .http2_max_pending_body_credit_per_stream = 512 * 1024,
        .http2_max_pending_body_credit_per_connection = 2 * 1024 * 1024,
        .http2_max_outgoing_buffer_bytes = 512 * 1024,
    }).http2Limits();

    try std.testing.expectEqual(@as(usize, 7), limits.max_active_streams);
    try std.testing.expectEqual(@as(u32, 2 * 1024 * 1024), limits.stream_receive_window);
    try std.testing.expectEqual(@as(u32, 8 * 1024 * 1024), limits.connection_receive_window);
    try std.testing.expectEqual(@as(u32, 256 * 1024), limits.receive_window_update_threshold);
    try std.testing.expectEqual(@as(usize, 512 * 1024), limits.max_pending_body_credit_per_stream);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), limits.max_pending_body_credit_per_connection);
    try std.testing.expectEqual(
        transport.default_http2_max_outgoing_buffer_bytes,
        https_only.http2_max_outgoing_buffer_bytes,
    );
    try std.testing.expectEqual(
        transport.default_wire_buffer_bytes,
        https_only.wire_buffer_bytes,
    );
}

test "egress config does not advertise h2 stream credit above decoded queue budget" {
    const config = https_only;
    const pump_limits = try config.streamPumpLimits().normalized();
    const h2_limits = try config.http2Limits().normalized();

    try std.testing.expect(h2_limits.stream_receive_window <= pump_limits.max_pending_decoded_bytes);
    try std.testing.expect(h2_limits.max_pending_body_credit_per_stream <= pump_limits.max_pending_decoded_bytes);

    const clamped = (transport.Config{
        .network = network_policy.public_https,
        .max_pending_decoded_body_bytes = 128 * 1024,
        .http2_stream_receive_window = 1024 * 1024,
        .http2_max_pending_body_credit_per_stream = 1024 * 1024,
    }).http2Limits();
    try std.testing.expectEqual(@as(u32, 128 * 1024), clamped.stream_receive_window);
    try std.testing.expectEqual(@as(usize, 128 * 1024), clamped.max_pending_body_credit_per_stream);
}

test "egress body pump limits use the decoded queue watermark for backpressure" {
    const config = transport.Config{
        .network = network_policy.public_https,
        .max_response_body_bytes = 1024 * 1024,
        .max_pending_decoded_body_bytes = 64 * 1024,
    };
    const pump_limits = try config.streamPumpLimits().normalized();

    try std.testing.expectEqual(@as(usize, 64 * 1024), pump_limits.max_pending_decoded_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), pump_limits.max_decoded_bytes);
}
