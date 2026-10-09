//! Tests for the HTTP/1 exchange and body continuation against the local
//! origin in support.zig, covering pooling, replay, framing, redirects,
//! drive budgets, would-block parks and billing. The support drivers stand in
//! for the owner loop, parking on poll(2) between drives, and for a connector
//! thread, dialing on `.connect`. Paced tests hold the origin on parks the
//! client recorded instead of on sleeps. Behavior that needs the real owner
//! and connector threads, such as fairness between fetches, is tested in
//! client/all.zig.

const std = @import("std");
const test_support = @import("support.zig");
const transport = test_support.transport;
const decompress = test_support.decompress;
const fetch_body = test_support.fetch_body;
const Http1HeaderContext = test_support.Http1HeaderContext;
const LocalHttp1Origin = test_support.LocalHttp1Origin;
const fetchViaExchange = test_support.fetchViaExchange;
const runExchange = test_support.runExchange;

const default_body_pipe_capacity: usize = 64 * 1024;

fn expectBodyBytes(body_pipe: *fetch_body.Body, expected: []const u8) !void {
    const bytes = try test_support.collectBodyBytes(body_pipe, std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "egress request plan does not resolve network addresses" {
    var plan = try transport.prepareRequest(
        std.testing.allocator,
        "https://does-not-exist.invalid/hello",
        "GET",
        &.{},
        .{},
    );
    defer plan.deinit();

    try std.testing.expectEqualStrings("does-not-exist.invalid", plan.target.authority_host);
    try std.testing.expectEqualStrings("/hello", plan.request_target);
}

test "egress http1 streaming path publishes headers before body" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/data", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    const headers = [_]transport.Header{.{ .name = "x-collo-test", .value = "yes" }};
    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "POST",
        "payload",
        &headers,
        .{
            .allow_plain_http = true,
            .allow_private_networks = true,
            .max_response_body_bytes = 64,
        },
        .{},
        body_pipe,
        &context,
    );

    try std.testing.expect(context.published);
    try std.testing.expectEqual(fetch_body.State.complete, body_pipe.state);
    try expectBodyBytes(body_pipe, "post ok");
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
    try std.testing.expectEqual(
        origin.request_wire.load(.acquire) + origin.response_wire.load(.acquire),
        test_support.bodyBilledTotal(body_pipe),
    );
}

test "egress http1 compressed response decodes through streaming body path" {
    if (!decompress.supportsZlib())
        return error.SkipZigTest;

    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/gzip", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "POST",
        "payload",
        &.{},
        .{
            .allow_plain_http = true,
            .allow_private_networks = true,
            .max_response_body_bytes = 64,
        },
        .{},
        body_pipe,
        &context,
    );

    try std.testing.expect(context.published);
    try std.testing.expectEqual(fetch_body.State.complete, body_pipe.state);
    try expectBodyBytes(body_pipe, "hello world");
}

test "egress http1 pool caps requests per connection" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/one", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();

    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
        .http1_pool_max_requests_per_connection = 2,
    };

    for (0..3) |_| {
        const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
        defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
        var context = Http1HeaderContext{ .expected_url = url };
        try fetchViaExchange(
            std.testing.allocator,
            &pool,
            &dns_cache,
            url,
            "POST",
            "payload",
            &.{},
            config,
            .{},
            body_pipe,
            &context,
        );
        try expectBodyBytes(body_pipe, "one ok");
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 retries idempotent request when pooled connection was half closed" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stale", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();

    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
    };

    for (0..2) |_| {
        const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
        defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
        var context = Http1HeaderContext{ .expected_url = url };
        try fetchViaExchange(
            std.testing.allocator,
            &pool,
            &dns_cache,
            url,
            "GET",
            "",
            &.{},
            config,
            .{},
            body_pipe,
            &context,
        );
        try expectBodyBytes(body_pipe, "stale ok");
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 pool evicts connections past max age" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/one", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();

    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
        .http1_pool_max_connection_age_ns = 1,
    };

    for (0..2) |round| {
        const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
        defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
        var context = Http1HeaderContext{ .expected_url = url };
        try fetchViaExchange(
            std.testing.allocator,
            &pool,
            &dns_cache,
            url,
            "POST",
            "payload",
            &.{},
            config,
            .{},
            body_pipe,
            &context,
        );
        try expectBodyBytes(body_pipe, "one ok");
        if (round == 0)
            std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 empty-body POST sends explicit content-length zero" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/empty", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "POST",
        "",
        &.{},
        .{
            .allow_plain_http = true,
            .allow_private_networks = true,
            .max_response_body_bytes = 64,
        },
        .{},
        body_pipe,
        &context,
    );

    try expectBodyBytes(body_pipe, "empty ok");
}

test "egress http1 does not replay pooled request after read timeout" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/hang-second", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();

    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
        .socket_timeout_ms = 100,
    };

    const first_body = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(first_body, std.testing.allocator);
    var first_context = Http1HeaderContext{ .expected_url = url };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "GET",
        "",
        &.{},
        config,
        .{},
        first_body,
        &first_context,
    );
    try expectBodyBytes(first_body, "hang ok");

    const second_body = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(second_body, std.testing.allocator);
    var second_context = Http1HeaderContext{ .expected_url = url };
    try std.testing.expectError(error.FetchReadTimeout, fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "GET",
        "",
        &.{},
        config,
        .{},
        second_body,
        &second_context,
    ));
    try std.testing.expect(!second_context.published);
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

test "egress http1 liveness probe discards dead pooled connections before non-retryable requests" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stale-post", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();

    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
    };

    for (0..2) |round| {
        const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
        defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
        var context = Http1HeaderContext{ .expected_url = url };
        try fetchViaExchange(
            std.testing.allocator,
            &pool,
            &dns_cache,
            url,
            "POST",
            "payload",
            &.{},
            config,
            .{},
            body_pipe,
            &context,
        );
        try expectBodyBytes(body_pipe, "stale ok");
        if (round == 0)
            std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 honors server keep-alive timeout hint" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/ka-zero", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();

    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
    };

    for (0..2) |round| {
        const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
        defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
        var context = Http1HeaderContext{ .expected_url = url };
        try fetchViaExchange(
            std.testing.allocator,
            &pool,
            &dns_cache,
            url,
            "GET",
            "",
            &.{},
            config,
            .{},
            body_pipe,
            &context,
        );
        try expectBodyBytes(body_pipe, "ka ok");
        if (round == 0)
            std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 caps consecutive interim responses" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const flood_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/interim-flood", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(flood_url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();

    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
    };

    const flood_body = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(flood_body, std.testing.allocator);
    var flood_context = Http1HeaderContext{ .expected_url = flood_url };
    try std.testing.expectError(error.TooManyInterimResponses, fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        flood_url,
        "GET",
        "",
        &.{},
        config,
        .{},
        flood_body,
        &flood_context,
    ));
    try std.testing.expect(!flood_context.published);

    const ok_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/interim-ok", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(ok_url);
    const ok_body = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(ok_body, std.testing.allocator);
    var ok_context = Http1HeaderContext{ .expected_url = ok_url };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        ok_url,
        "GET",
        "",
        &.{},
        config,
        .{},
        ok_body,
        &ok_context,
    );
    try expectBodyBytes(ok_body, "interim ok");
}

test "egress http1 accepts bare-LF response heads from the wire" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/bare-lf", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "GET",
        "",
        &.{},
        .{
            .allow_plain_http = true,
            .allow_private_networks = true,
            .max_response_body_bytes = 64,
        },
        .{},
        body_pipe,
        &context,
    );
    try expectBodyBytes(body_pipe, "lf ok");
}

test "egress http1 does not pool lenient bare-LF keep-alive responses" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const first_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://{s}:{d}/bare-lf-keepalive",
        .{ origin.host(), origin.port },
    );
    defer std.testing.allocator.free(first_url);
    const second_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://{s}:{d}/one",
        .{ origin.host(), origin.port },
    );
    defer std.testing.allocator.free(second_url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
    };

    const first_body = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(first_body, std.testing.allocator);
    var first_context = Http1HeaderContext{ .expected_url = first_url };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        first_url,
        "GET",
        "",
        &.{},
        config,
        .{},
        first_body,
        &first_context,
    );
    try expectBodyBytes(first_body, "lf ok");

    const second_body = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(second_body, std.testing.allocator);
    var second_context = Http1HeaderContext{ .expected_url = second_url };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        second_url,
        "POST",
        "payload",
        &.{},
        config,
        .{},
        second_body,
        &second_context,
    );
    try expectBodyBytes(second_body, "one ok");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 retry predicate only fires on connection death before response bytes" {
    const http1 = transport.http1;
    try std.testing.expect(http1.isHttp1ConnectionDeathBeforeResponse(error.FetchResponseTruncated, .{}));
    try std.testing.expect(http1.isHttp1ConnectionDeathBeforeResponse(error.BrokenPipe, .{}));
    try std.testing.expect(http1.isHttp1ConnectionDeathBeforeResponse(error.ConnectionResetByPeer, .{}));
    try std.testing.expect(http1.isHttp1ConnectionDeathBeforeResponse(error.FetchWriteFailed, .{}));
    try std.testing.expect(!http1.isHttp1ConnectionDeathBeforeResponse(error.FetchReadTimeout, .{}));
    try std.testing.expect(!http1.isHttp1ConnectionDeathBeforeResponse(error.FetchWriteTimeout, .{}));
    try std.testing.expect(!http1.isHttp1ConnectionDeathBeforeResponse(error.InvalidResponseLine, .{}));
    try std.testing.expect(!http1.isHttp1ConnectionDeathBeforeResponse(
        error.FetchResponseTruncated,
        .{ .response_bytes_received = true },
    ));
}

test "egress http1 parses keep-alive timeout hints" {
    const http1 = transport.http1;
    try std.testing.expectEqual(
        @as(?u64, 5 * std.time.ns_per_s),
        http1.keepAliveTimeoutNs(&.{.{ .name = "keep-alive", .value = "timeout=5, max=1000" }}),
    );
    try std.testing.expectEqual(
        @as(?u64, 0),
        http1.keepAliveTimeoutNs(&.{.{ .name = "Keep-Alive", .value = "max=7, timeout=0" }}),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        http1.keepAliveTimeoutNs(&.{.{ .name = "keep-alive", .value = "max=7" }}),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        http1.keepAliveTimeoutNs(&.{.{ .name = "keep-alive", .value = "timeout=abc" }}),
    );
}

test "egress http1 resolves transfer-coded response encodings" {
    const http1_protocol = transport.http1_protocol;
    var scan_start: usize = 0;
    var gzip_chunked = (try http1_protocol.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        &scan_start,
        http1_protocol.default_max_header_bytes,
    )).?;
    defer gzip_chunked.deinit();
    try std.testing.expectEqual(decompress.Encoding.gzip, try transport.http1.responseEncodingForHead(gzip_chunked));

    var conflict_scan: usize = 0;
    var conflicting = (try http1_protocol.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\nContent-Encoding: br\r\n\r\n",
        &conflict_scan,
        http1_protocol.default_max_header_bytes,
    )).?;
    defer conflicting.deinit();
    try std.testing.expectError(
        error.UnsupportedTransferEncoding,
        transport.http1.responseEncodingForHead(conflicting),
    );
}

test "egress http1 rejects ambiguous response framing before publishing body" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/ambiguous", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };

    try std.testing.expectError(error.InvalidResponseBodyFraming, fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "GET",
        "",
        &.{},
        .{
            .allow_plain_http = true,
            .allow_private_networks = true,
            .max_response_body_bytes = 64,
        },
        .{},
        body_pipe,
        &context,
    ));
    try std.testing.expect(!context.published);
}

test "egress http1 redirect revalidates SSRF policy on every hop" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/redirect-loopback", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };

    try std.testing.expectError(error.EgressDenied, fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "GET",
        "",
        &.{},
        .{
            .allow_plain_http = true,
            .allow_private_networks = true,
            .max_response_body_bytes = 64,
        },
        .{},
        body_pipe,
        &context,
    ));
    try std.testing.expect(!context.published);
}

test "egress http1 detached body completion returns connection to the pool" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/one", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
    };

    for (0..2) |_| {
        const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, 4096);
        defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
        var context = Http1HeaderContext{ .expected_url = url };
        const continuation = (try runExchange(
            std.testing.allocator,
            &pool,
            &dns_cache,
            url,
            "POST",
            "payload",
            &.{},
            config,
            .{},
            body_pipe,
            &context,
        )) orelse return error.ExpectedBodyContinuation;
        var budget = transport.Http1DriveBudget{};
        switch (try continuation.step(.{}, &budget)) {
            .done => {},
            .paused, .yielded => {
                continuation.failAndDeinit("unexpected pause");
                return error.UnexpectedBodyPause;
            },
        }
        try std.testing.expect(context.published);
        // The clean framed completion hands the connection back; the next
        // round must lease it instead of dialing the origin again.
        continuation.returnConnectionIfReusable();
        continuation.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

// One step() spends at most one drive budget: a large fast body must yield
// every ~drive_budget_max_bytes instead of running to EOF in a single
// drive, and the yielded continuation must resume exactly where it stopped
// and deliver every byte once. 1 MiB against the 256 KiB byte quantum needs
// at least three yields.
test "egress http1 body continuation yields on the drive budget" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/big", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const big_len = test_support.big_body_bytes;
    // Ample credit everywhere: the pump never pauses, so only the drive
    // budget can stop the transfer mid-body.
    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = big_len * 2,
        .max_encoded_response_bytes = big_len * 2,
        .max_pending_decoded_body_bytes = big_len * 2,
    };

    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, big_len * 2);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };
    const continuation = (try runExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "GET",
        "",
        &.{},
        config,
        .{},
        body_pipe,
        &context,
    )) orelse return error.ExpectedBodyContinuation;

    var yields: usize = 0;
    var steps: usize = 0;
    while (true) {
        steps += 1;
        if (steps > 1_000) {
            continuation.failAndDeinit("drive budget loop runaway");
            return error.DriveBudgetLoopRunaway;
        }
        // A fresh budget per step, as the owner gives each driveOneH1 call.
        var budget = transport.Http1DriveBudget{};
        const outcome = continuation.step(.{}, &budget) catch |err| {
            continuation.failAndDeinit(@errorName(err));
            return err;
        };
        switch (outcome) {
            .done => break,
            .paused => {
                continuation.failAndDeinit("unexpected pause");
                return error.UnexpectedBodyPause;
            },
            .yielded => yields += 1,
        }
    }
    try std.testing.expect(context.published);
    try std.testing.expect(yields >= 3);
    // Nothing consumed the pipe, so the queued decoded bytes are the whole
    // body: yields dropped and duplicated nothing.
    try std.testing.expectEqual(big_len, body_pipe.queuedDecodedBytes());
    continuation.returnConnectionIfReusable();
    continuation.deinit();
}

// The owner never blocks inside step(): a dry socket unwinds with
// error.EgressWouldBlock, and the request parks on the recorded interest and
// re-enters with a fresh budget (driveOneH1 and parkH1Io in
// engine/h2_engine.zig). A paced origin forces several such parks; the
// owner-shaped driver must deliver the whole body across them, and every park
// on this plain TCP stream records read interest.
test "egress http1 body continuation re-parks through the would_block probe" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/paced", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const body_len = test_support.paced_body_bytes;
    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = body_len * 2,
        .max_encoded_response_bytes = body_len * 2,
        .max_pending_decoded_body_bytes = body_len * 2,
        .socket_timeout_ms = 2_000,
    };

    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, body_len * 2);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };
    const continuation = (try runExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "GET",
        "",
        &.{},
        config,
        .{},
        body_pipe,
        &context,
    )) orelse return error.ExpectedBodyContinuation;

    // The origin releases chunk N only after the client recorded its Nth park
    // (park_signal feeds the origin's gate), so every gap between chunks is a
    // would-block unwind under any scheduler load.
    var park_log = test_support.OwnerShapedParkLog{ .park_signal = &origin.paced_gate };
    try test_support.driveContinuationOwnerShaped(continuation, config.socket_timeout_ms, &park_log);

    try std.testing.expect(context.published);
    try std.testing.expectEqual(fetch_body.State.complete, body_pipe.state);
    try std.testing.expectEqual(body_len, body_pipe.queuedDecodedBytes());
    // Chunk N waited for park N, so a complete body proves at least
    // chunk_count - 1 real would-block unwinds, a path the blocking driver
    // never takes.
    try std.testing.expect(park_log.parks >= test_support.paced_chunk_count - 1);
    for (park_log.recorded()) |interest|
        try std.testing.expectEqual(transport.IoInterest.read, interest);
}

// An origin that goes silent mid-body must fail the fetch through the
// would-block path, with the park's recorded stage error after one stall
// window (parkH1Io's per-park deadline), and the bytes that arrived before
// the silence must stay delivered.
test "egress http1 owner-shaped stall window expires a silent mid-body origin" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stall-mid", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 1024,
        .socket_timeout_ms = 150,
    };

    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);
    var context = Http1HeaderContext{ .expected_url = url };
    const continuation = (try runExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url,
        "GET",
        "",
        &.{},
        config,
        .{},
        body_pipe,
        &context,
    )) orelse return error.ExpectedBodyContinuation;

    var park_log = test_support.OwnerShapedParkLog{};
    try std.testing.expectError(
        error.FetchReadTimeout,
        test_support.driveContinuationOwnerShaped(continuation, config.socket_timeout_ms, &park_log),
    );
    try std.testing.expect(body_pipe.isFailed());
    // The partial prefix (32 of 128 content-length bytes) was delivered
    // before the stall; the expiry must not drop it.
    try std.testing.expectEqual(@as(usize, 32), body_pipe.queuedDecodedBytes());
    try std.testing.expect(park_log.parks >= 1);
    const parked = park_log.recorded();
    try std.testing.expectEqual(transport.IoInterest.read, parked[parked.len - 1]);
}

// On TLS a body read can need write readiness first (tlsBioDirectReadStep
// returns `.wait = .write` while ciphertext is queued behind a full socket
// send buffer), so each re-park may ask for either direction and must record
// its own interest; an owner that re-armed a stale interest would poll the
// wrong direction until the stall deadline. The setup is a hand-built
// close-delimited continuation over an unhandshaken tls_bio_direct
// socketpair whose send buffer the test fills first. The first park asks for
// write (handshake ciphertext queued, buffer full); the peer drains, the
// re-entry sends, and the next park asks for read, whose stall window the
// silent peer then lets expire.
test "egress http1 would_block park records TLS mask changes per re-park" {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer std.posix.close(fds[1]);

    const bio = transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .http_1_1,
        transport.default_tls_ciphertext_buffer_bytes,
        null,
    ) catch |err| {
        std.posix.close(fds[0]);
        return err;
    };
    var bio_owned = true;
    errdefer if (bio_owned) bio.deinit();

    // Shrink and then fill the send buffer, so the handshake ciphertext the
    // first read queues cannot leave the process and the read must park on
    // write readiness.
    try std.posix.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 4096)));
    const junk = [_]u8{'j'} ** 4096;
    var filled: usize = 0;
    while (filled < 64 * 1024 * 1024) {
        const written = std.posix.write(fds[0], &junk) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        filled += written;
    } else return error.SendBufferNeverFilled;

    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .insecure_tls = true,
        .max_response_body_bytes = 4096,
        .socket_timeout_ms = 300,
    };
    const body_pipe = try test_support.makeBodyPipe(std.testing.allocator, 4096);
    defer test_support.releaseBodyPipe(body_pipe, std.testing.allocator);

    const reason = try std.testing.allocator.dupe(u8, "OK");
    var reason_owned = true;
    errdefer if (reason_owned) std.testing.allocator.free(reason);
    const head_headers = try std.testing.allocator.alloc(transport.Header, 0);
    var headers_owned = true;
    errdefer if (headers_owned) std.testing.allocator.free(head_headers);
    const response = transport.Http1OwnedResponseHead{
        .allocator = std.testing.allocator,
        .wire = .empty,
        .head = .{
            .allocator = std.testing.allocator,
            .minor_version = 1,
            .status_code = 200,
            .reason = reason,
            .consumed_len = 0,
            .headers = head_headers,
            .body_framing = .close_delimited,
            .transfer_coding = .none,
            .content_length = 0,
            .post_head_bytes = &.{},
            .initial_body_bytes = &.{},
            .close_after_response = true,
        },
    };

    const continuation = try transport.Http1BodyContinuation.init(
        std.testing.allocator,
        &pool,
        .{ .tls_bio_direct = bio },
        response,
        .{},
        0,
        1,
        false,
        .identity,
        config.http1StreamPumpLimits(),
        config,
        body_pipe,
        null,
        test_support.noopBodyReady,
        .generic,
        null,
    );
    bio_owned = false;
    reason_owned = false;
    headers_owned = false;

    // Releases the write park. The drain thread touches the socket only after
    // the client's first park is recorded (the filled send buffer makes that
    // park ask for write), then keeps the peer drained without ever writing,
    // so every later read park expires on its stall window.
    var park_signal = std.atomic.Value(usize).init(0);
    var drain_state = DrainPeerState{ .fd = fds[1], .parked = &park_signal };
    const drain_thread = try std.Thread.spawn(.{}, drainPeerAfterPark, .{&drain_state});
    defer {
        drain_state.stop.store(true, .release);
        drain_thread.join();
    }

    var park_log = test_support.OwnerShapedParkLog{ .park_signal = &park_signal };
    try std.testing.expectError(
        error.FetchReadTimeout,
        test_support.driveContinuationOwnerShaped(continuation, config.socket_timeout_ms, &park_log),
    );

    const parked = park_log.recorded();
    try std.testing.expect(parked.len >= 2);
    // The interest changed across re-parks of the same read: write first,
    // with ciphertext stuck behind the full buffer and nothing drained before
    // that park was recorded, then read once the peer drained it.
    try std.testing.expectEqual(transport.IoInterest.write, parked[0]);
    try std.testing.expectEqual(transport.IoInterest.read, parked[parked.len - 1]);
    try std.testing.expect(body_pipe.isFailed());
}

const DrainPeerState = struct {
    fd: std.posix.fd_t,
    parked: *std.atomic.Value(usize),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Waits for the client's first recorded park (the write park the filled
/// buffer forces), then drains the peer side without ever writing until the
/// test stops it. Both ends wait on conditions, so no sleep decides whether
/// the drain raced the park.
fn drainPeerAfterPark(state: *DrainPeerState) void {
    while (state.parked.load(.acquire) == 0) {
        if (state.stop.load(.acquire))
            return;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    var sink: [4096]u8 = undefined;
    while (!state.stop.load(.acquire)) {
        const got = std.posix.read(state.fd, &sink) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return,
        };
        if (got == 0)
            return;
    }
}

test "egress http1 redirect chain sums billed bytes across hops" {
    var origin = try LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url_hop = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/hop", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url_hop);
    const url_final = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/hop-final", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url_final);

    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(std.testing.allocator);
    defer pool.deinit();
    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64,
    };

    // Baseline: the final hop alone.
    const direct_body = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(direct_body, std.testing.allocator);
    var direct_context = Http1HeaderContext{ .expected_url = url_final };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url_final,
        "GET",
        "",
        &.{},
        config,
        .{},
        direct_body,
        &direct_context,
    );
    try expectBodyBytes(direct_body, "final ok");
    const direct_billed = test_support.bodyBilledTotal(direct_body);
    try std.testing.expect(direct_billed > 0);

    // The chain is a 302 with a drained 5-byte body, then the final
    // response. Billing sums every hop, so the chain total must exceed the
    // direct fetch by at least the 302 hop's request head and response.
    const chain_body = try test_support.makeBodyPipe(std.testing.allocator, default_body_pipe_capacity);
    defer test_support.releaseBodyPipe(chain_body, std.testing.allocator);
    // The published head carries the final hop's URL.
    var chain_context = Http1HeaderContext{ .expected_url = url_final };
    try fetchViaExchange(
        std.testing.allocator,
        &pool,
        &dns_cache,
        url_hop,
        "GET",
        "",
        &.{},
        config,
        .{},
        chain_body,
        &chain_context,
    );
    try expectBodyBytes(chain_body, "final ok");
    try std.testing.expect(test_support.bodyBilledTotal(chain_body) > direct_billed);
    // Plain TCP observes no ciphertext, so cost stays 0.
    try std.testing.expectEqual(@as(u64, 0), test_support.bodyCost(chain_body));
    // The drained 302 connection must serve the final hop too: one accept
    // for the direct baseline and one for the whole chain. Abandoning the
    // drained connection and redialing would pass the body and billing
    // checks above but show a third accept here.
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}
