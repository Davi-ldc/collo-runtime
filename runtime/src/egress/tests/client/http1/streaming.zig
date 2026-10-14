//! Tests for the HTTP/1 exchange and body continuation against the local
//! origin in support.zig: pooling and the rules that keep a pooled wire
//! clean, the lease that brings a pooled wire up to date with its socket,
//! replay after a dead pooled wire, framing and leniency, interim heads,
//! redirects and the network policy on each hop, a body step's wait on its
//! wire, and the stall deadline. The support harness stands in for the
//! engine's owner loop on the production data driver, and paced routes hold
//! their writes on what the client did instead of on sleeps. Fairness
//! between fetches and everything else that needs the real owner thread is
//! tested in client/engine/, HTTP/1 over TLS wires in http1/tls.zig, and the
//! wire alone in client/wire.zig.

const std = @import("std");
const test_support = @import("support.zig");
const transport = test_support.transport;
const decompress = test_support.decompress;
const Client = test_support.Client;
const LocalHttp1Origin = test_support.LocalHttp1Origin;
const Response = test_support.Response;
const WaitLog = test_support.WaitLog;
const driveContinuationToEnd = test_support.driveContinuationToEnd;
const fetchViaExchange = test_support.fetchViaExchange;
const runExchange = test_support.runExchange;

const gpa = std.testing.allocator;

/// The head-size bound the parser calls below pass; any bound above their
/// heads serves.
const head_bytes_max: usize = 16 * 1024;

test "egress http1 streaming path publishes headers before body" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/data");
    defer gpa.free(url);
    const headers = [_]transport.Header{.{ .name = "x-collo-test", .value = "yes" }};
    var response = Response.init(url);
    defer response.deinit(gpa);
    try fetchViaExchange(&client, .{
        .url = url,
        .method = "POST",
        .body = "payload",
        .headers = &headers,
    }, .{ .network = origin.policy(), .max_response_body_bytes = 64 }, &response);

    try std.testing.expect(response.published);
    try response.expectBody(gpa, "post ok");
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

test "egress http1 compressed response decodes through streaming body path" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/gzip");
    defer gpa.free(url);
    var response = Response.init(url);
    defer response.deinit(gpa);
    try fetchViaExchange(
        &client,
        .{ .url = url, .method = "POST", .body = "payload" },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &response,
    );

    try std.testing.expect(response.published);
    try response.expectBody(gpa, "hello world");
}

test "egress http1 pool caps requests per connection" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/one");
    defer gpa.free(url);
    const config: transport.Config = .{
        .network = origin.policy(),
        .max_response_body_bytes = 64,
        .http1_pool_max_requests_per_connection = 2,
    };

    for (0..3) |_| {
        var response = Response.init(url);
        defer response.deinit(gpa);
        try fetchViaExchange(&client, .{ .url = url, .method = "POST", .body = "payload" }, config, &response);
        try response.expectBody(gpa, "one ok");
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

// `/close-second` answers the first request on a connection and closes on
// the second without answering. The pooled wire is clean when the second
// GET leases it, the origin closes under the request, and the GET, bodiless
// and idempotent, is sent again on a fresh dial.
test "egress http1 replays a GET whose pooled wire's peer closes under it" {
    try expectGetReplayedAfterPeerEnd("/close-second");
}

// The same death as a reset, which reads as the end of the stream.
test "egress http1 replays a GET whose pooled wire's peer resets under it" {
    try expectGetReplayedAfterPeerEnd("/reset-second");
}

fn expectGetReplayedAfterPeerEnd(path: []const u8) !void {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, path);
    defer gpa.free(url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    for (0..2) |_| {
        var response = Response.init(url);
        defer response.deinit(gpa);
        try fetchViaExchange(&client, .{ .url = url }, config, &response);
        try response.expectBody(gpa, test_support.kept_body);
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

// A POST may have taken effect before its connection died, so the same
// death fails it instead of sending it again.
test "egress http1 does not replay a POST whose pooled wire's peer closes under it" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/close-second");
    defer gpa.free(url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    var first = Response.init(url);
    defer first.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = url }, config, &first);
    try first.expectBody(gpa, test_support.kept_body);

    var second = Response.init(url);
    defer second.deinit(gpa);
    try std.testing.expectError(
        error.FetchResponseTruncated,
        fetchViaExchange(&client, .{ .url = url, .method = "POST", .body = "payload" }, config, &second),
    );
    try std.testing.expect(!second.published);
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

test "egress http1 pool evicts connections past max age" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/one");
    defer gpa.free(url);
    // A connection is older than 1 ns by the time the next fetch looks.
    const config: transport.Config = .{
        .network = origin.policy(),
        .max_response_body_bytes = 64,
        .http1_pool_max_connection_age_ns = 1,
    };

    for (0..2) |_| {
        var response = Response.init(url);
        defer response.deinit(gpa);
        try fetchViaExchange(&client, .{ .url = url, .method = "POST", .body = "payload" }, config, &response);
        try response.expectBody(gpa, "one ok");
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 empty-body POST sends explicit content-length zero" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/empty");
    defer gpa.free(url);
    var response = Response.init(url);
    defer response.deinit(gpa);
    try fetchViaExchange(
        &client,
        .{ .url = url, .method = "POST" },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &response,
    );

    try response.expectBody(gpa, "empty ok");
}

// The origin answers the first request and stays silent on the second, so
// the second fails at its read deadline; a timeout says nothing about
// whether the origin acted on the request, so it is not sent again.
test "egress http1 does not replay pooled request after read timeout" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/hang-second");
    defer gpa.free(url);
    const config: transport.Config = .{
        .network = origin.policy(),
        .max_response_body_bytes = 64,
        .socket_timeout_ms = 100,
    };

    var first = Response.init(url);
    defer first.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = url }, config, &first);
    try first.expectBody(gpa, "hang ok");

    var second = Response.init(url);
    defer second.deinit(gpa);
    try std.testing.expectError(
        error.FetchReadTimeout,
        fetchViaExchange(&client, .{ .url = url }, config, &second),
    );
    try std.testing.expect(!second.published);
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

test "egress http1 pool drops an idle wire its peer closed before a non-retryable request leases it" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/stale");
    defer gpa.free(url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    var first = Response.init(url);
    defer first.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = url, .method = "POST", .body = "payload" }, config, &first);
    try first.expectBody(gpa, "stale ok");
    try std.testing.expectEqual(@as(usize, 1), client.pool.idleEntries().len);

    // The origin closed after its answer. The receive armed on the idle wire
    // hears the EOF, and the eviction that follows drops the wire.
    try std.testing.expect(try client.serviceIdleEntries(2_000));
    try std.testing.expectEqual(@as(usize, 0), client.pool.idleEntries().len);

    // A POST is never sent twice, so on the dead wire it would fail; it
    // succeeds only because it dials a fresh one.
    var second = Response.init(url);
    defer second.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = url, .method = "POST", .body = "payload" }, config, &second);
    try second.expectBody(gpa, "stale ok");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

// `/stale` promises keep-alive and closes after its answer, and the test
// waits until the close reached the pooled wire's socket. The next fetch
// leases in the same iteration that pooled the wire, before any wait could
// arm the idle receive. A POST is never sent twice, so on the dead wire it
// would fail; the lease takes the close from the socket first and the POST
// dials a fresh wire.
test "egress http1 lease drops a pooled wire whose peer closed after its response, so a POST dials fresh" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/stale");
    defer gpa.free(url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    var first = Response.init(url);
    defer first.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = url, .method = "POST", .body = "payload" }, config, &first);
    try first.expectBody(gpa, "stale ok");
    try client.awaitIdleSocketReadable(2_000);

    var second = Response.init(url);
    defer second.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = url, .method = "POST", .body = "payload" }, config, &second);
    try second.expectBody(gpa, "stale ok");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

// `/stray-later` sends a stray head in its own segment once the client
// finished the response, and the test waits until it reached the pooled
// wire's socket. Leased as it is, the wire would answer the next request
// with that head; the lease takes it from the socket first, so it costs the
// wire and the next fetch dials.
test "egress http1 lease drops a pooled wire whose peer sent a stray head after its response" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const stray_url = try origin.url(gpa, "/stray-later");
    defer gpa.free(stray_url);
    const one_url = try origin.url(gpa, "/one");
    defer gpa.free(one_url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    var first = Response.init(stray_url);
    defer first.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = stray_url }, config, &first);
    try first.expectBody(gpa, test_support.stray_later_body);
    try std.testing.expectEqual(@as(usize, 1), client.pool.idleEntries().len);
    origin.gate.store(1, .release);
    try client.awaitIdleSocketReadable(2_000);

    var second = Response.init(one_url);
    defer second.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = one_url }, config, &second);
    try second.expectBody(gpa, "one ok");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

// Here a wait arms the pooled wire's receive and ends before the stray head
// arrives; the receive then takes the head, and its completion waits in the
// driver's ring with no wait to serve it. Having been through a wait does
// not make the wire safe to lease: the lease ingests the ring's completions
// first, so the head costs the wire.
test "egress http1 lease drops a pooled wire whose armed receive took a stray head no wait served" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const stray_url = try origin.url(gpa, "/stray-later");
    defer gpa.free(stray_url);
    const one_url = try origin.url(gpa, "/one");
    defer gpa.free(one_url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    var first = Response.init(stray_url);
    defer first.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = stray_url }, config, &first);
    try first.expectBody(gpa, test_support.stray_later_body);
    // The idle receive is armed, and nothing arrives within the window.
    try std.testing.expect(!try client.serviceIdleEntries(20));
    try std.testing.expectEqual(@as(usize, 1), client.pool.idleEntries().len);
    origin.gate.store(1, .release);
    try client.awaitIdleReceivePosted();

    var second = Response.init(one_url);
    defer second.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = one_url }, config, &second);
    try second.expectBody(gpa, "one ok");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

// `Keep-Alive: timeout=0` expires the pooled wire at once, so the second
// fetch dials anew.
test "egress http1 honors server keep-alive timeout hint" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/ka-zero");
    defer gpa.free(url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    for (0..2) |_| {
        var response = Response.init(url);
        defer response.deinit(gpa);
        try fetchViaExchange(&client, .{ .url = url }, config, &response);
        try response.expectBody(gpa, "ka ok");
    }
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 caps consecutive interim responses" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    const flood_url = try origin.url(gpa, "/interim-flood");
    defer gpa.free(flood_url);
    var flood = Response.init(flood_url);
    defer flood.deinit(gpa);
    try std.testing.expectError(
        error.TooManyInterimResponses,
        fetchViaExchange(&client, .{ .url = flood_url }, config, &flood),
    );
    try std.testing.expect(!flood.published);

    const ok_url = try origin.url(gpa, "/interim-ok");
    defer gpa.free(ok_url);
    var ok = Response.init(ok_url);
    defer ok.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = ok_url }, config, &ok);
    try ok.expectBody(gpa, "interim ok");
}

test "egress http1 accepts bare-LF response heads from the wire" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/bare-lf");
    defer gpa.free(url);
    var response = Response.init(url);
    defer response.deinit(gpa);
    try fetchViaExchange(
        &client,
        .{ .url = url },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &response,
    );
    try response.expectBody(gpa, "lf ok");
}

test "egress http1 does not pool lenient bare-LF keep-alive responses" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const first_url = try origin.url(gpa, "/bare-lf-keepalive");
    defer gpa.free(first_url);
    const second_url = try origin.url(gpa, "/one");
    defer gpa.free(second_url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    var first = Response.init(first_url);
    defer first.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = first_url }, config, &first);
    try first.expectBody(gpa, "lf ok");
    try std.testing.expectEqual(@as(usize, 0), client.pool.idleEntries().len);

    var second = Response.init(second_url);
    defer second.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = second_url, .method = "POST", .body = "payload" }, config, &second);
    try second.expectBody(gpa, "one ok");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

// A replay needs both: a request whose second send cannot repeat its
// effects (idempotent, no body), and a failure showing the origin never
// started a response.
test "egress http1 replays only a bodiless idempotent request whose connection died before any response byte" {
    try std.testing.expect(transport.isReplayableBeforeResponse("GET", ""));
    try std.testing.expect(transport.isReplayableBeforeResponse("head", ""));
    try std.testing.expect(transport.isReplayableBeforeResponse("OPTIONS", ""));
    try std.testing.expect(transport.isReplayableBeforeResponse("DELETE", ""));
    try std.testing.expect(!transport.isReplayableBeforeResponse("POST", ""));
    try std.testing.expect(!transport.isReplayableBeforeResponse("PUT", ""));
    try std.testing.expect(!transport.isReplayableBeforeResponse("GET", "body"));

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
        gpa,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        &scan_start,
        head_bytes_max,
    )).?;
    defer gzip_chunked.deinit();
    try std.testing.expectEqual(decompress.Encoding.gzip, try transport.http1.responseEncodingForHead(gzip_chunked));

    var conflict_scan: usize = 0;
    var conflicting = (try http1_protocol.completeResponseHead(
        gpa,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\nContent-Encoding: br\r\n\r\n",
        &conflict_scan,
        head_bytes_max,
    )).?;
    defer conflicting.deinit();
    try std.testing.expectError(
        error.UnsupportedTransferEncoding,
        transport.http1.responseEncodingForHead(conflicting),
    );
}

test "egress http1 rejects ambiguous response framing before publishing body" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/ambiguous");
    defer gpa.free(url);
    var response = Response.init(url);
    defer response.deinit(gpa);
    try std.testing.expectError(error.InvalidResponseBodyFraming, fetchViaExchange(
        &client,
        .{ .url = url },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &response,
    ));
    try std.testing.expect(!response.published);
}

test "egress http1 redirect to a loopback address fails with EgressReservedAddressDenied" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    // The origin redirects to 127.0.0.1 on its own port.
    const url = try origin.url(gpa, "/redirect-loopback");
    defer gpa.free(url);
    var response = Response.init(url);
    defer response.deinit(gpa);
    try std.testing.expectError(error.EgressReservedAddressDenied, fetchViaExchange(
        &client,
        .{ .url = url },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &response,
    ));
    try std.testing.expect(!response.published);
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

test "egress http1 redirect to a port the policy does not name fails with EgressPortDenied and connects nowhere" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    // Serves on the same address as `origin`, on a port its policy omits.
    const unnamed = try LocalHttp1Origin.start(gpa);
    defer unnamed.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/redirect-port/{d}", .{ origin.host(), origin.port, unnamed.port });
    defer gpa.free(url);
    var response = Response.init(url);
    defer response.deinit(gpa);
    try std.testing.expectError(error.EgressPortDenied, fetchViaExchange(
        &client,
        .{ .url = url },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &response,
    ));
    try std.testing.expect(!response.published);
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), unnamed.accepted.load(.acquire));
}

// The 302's small body is drained only so its wire stays reusable, and the
// next hop, to the same origin, leases that wire instead of dialing.
test "egress http1 drained redirect hop hands its wire to the next hop" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const hop_url = try origin.url(gpa, "/hop");
    defer gpa.free(hop_url);
    const final_url = try origin.url(gpa, "/hop-final");
    defer gpa.free(final_url);
    // The published head names the last hop.
    var response = Response.init(final_url);
    defer response.deinit(gpa);
    try fetchViaExchange(
        &client,
        .{ .url = hop_url },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &response,
    );
    try response.expectBody(gpa, "final ok");
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

// `/hop` sends its body whatever the method, and the answer to HEAD ends at
// its head, so that body is surplus: the redirect hop gives up its wire and
// the next hop dials.
test "egress http1 redirect answering HEAD with a body does not hand its wire to the next hop" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const hop_url = try origin.url(gpa, "/hop");
    defer gpa.free(hop_url);
    const final_url = try origin.url(gpa, "/hop-final");
    defer gpa.free(final_url);
    var response = Response.init(final_url);
    defer response.deinit(gpa);
    try fetchViaExchange(
        &client,
        .{ .url = hop_url, .method = "HEAD" },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &response,
    );
    try response.expectBody(gpa, "");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

test "egress http1 body finish returns a clean wire to the pool for the next fetch" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/one");
    defer gpa.free(url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    for (0..2) |_| {
        var response = Response.init(url);
        defer response.deinit(gpa);
        const continuation = (try runExchange(
            &client,
            .{ .url = url, .method = "POST", .body = "payload" },
            config,
            &response,
        )) orelse return error.ExpectedBodyContinuation;
        try driveContinuationToEnd(&client, continuation, &response, config.socket_timeout_ms, null);
        try std.testing.expect(response.published);
        try response.expectBody(gpa, "one ok");
        try std.testing.expectEqual(@as(usize, 1), client.pool.idleEntries().len);
    }
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

// A step consumes only what the wire holds. The paced origin writes chunk N
// only after the client recorded its Nth wait, so every gap between chunks
// is a step that found the wire empty, returned `.wait = .read`, and went
// on after the receive the harness serviced.
test "egress http1 body step waits for a read on an empty wire and resumes after the receive" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/paced");
    defer gpa.free(url);
    const body_len = test_support.paced_body_bytes;
    // Ample credit: nothing pauses the body, so only an empty wire stops a step.
    const config: transport.Config = .{
        .network = origin.policy(),
        .max_response_body_bytes = body_len * 2,
        .max_encoded_response_bytes = body_len * 2,
        .max_pending_decoded_body_bytes = body_len * 2,
        .socket_timeout_ms = 2_000,
    };

    var response = Response.init(url);
    defer response.deinit(gpa);
    const continuation = (try runExchange(&client, .{ .url = url }, config, &response)) orelse
        return error.ExpectedBodyContinuation;
    var wait_log: WaitLog = .{ .signal = &origin.gate };
    try driveContinuationToEnd(&client, continuation, &response, config.socket_timeout_ms, &wait_log);

    try std.testing.expect(response.published);
    try response.expectBody(gpa, &([_]u8{'p'} ** test_support.paced_body_bytes));
    // Chunk N waited for wait N, so a complete body proves at least
    // `paced_chunk_count - 1` waits.
    try std.testing.expect(wait_log.waits >= test_support.paced_chunk_count - 1);
    for (wait_log.recorded()) |interest|
        try std.testing.expectEqual(transport.IoInterest.read, interest);
}

// The origin sends part of its body and goes silent without closing. The
// body fails after one stall window with the stage error the engine
// reports, and the bytes that arrived before the silence reached the queue
// first.
test "egress http1 silent mid-body origin fails the body with FetchReadTimeout" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/stall-mid");
    defer gpa.free(url);
    const config: transport.Config = .{
        .network = origin.policy(),
        .max_response_body_bytes = 1024,
        .socket_timeout_ms = 150,
    };

    var response = Response.init(url);
    defer response.deinit(gpa);
    const continuation = (try runExchange(&client, .{ .url = url }, config, &response)) orelse
        return error.ExpectedBodyContinuation;
    var wait_log: WaitLog = .{};
    try std.testing.expectError(
        error.FetchReadTimeout,
        driveContinuationToEnd(&client, continuation, &response, config.socket_timeout_ms, &wait_log),
    );

    try std.testing.expectEqualStrings("FetchReadTimeout", response.queue.failureMessage().?);
    try std.testing.expectEqual(test_support.stall_mid_prefix_bytes, response.queue.queuedBytes());
    const waited = wait_log.recorded();
    try std.testing.expect(waited.len >= 1);
    try std.testing.expectEqual(transport.IoInterest.read, waited[waited.len - 1]);
}

// Bytes after a response's framing would be read as the next response's
// head, so the wire that carried them never returns to the pool, and the
// response itself completes whichever receive carried them. `/surplus` sends
// its head, then, once the gate opens after the head was parsed, its
// Content-Length body and a stray head in one write, so the stray head stays
// unread in the wire.
test "egress http1 response with bytes past its framing in a later receive does not pool its wire" {
    try expectSurplusDropsWire("/surplus", true, 200, test_support.surplus_body);
}

// `/surplus-inline` writes head, body and stray head at once, so the stray
// head arrives in the receive that carried the head.
test "egress http1 response with bytes past its framing in the head's receive completes and does not pool its wire" {
    try expectSurplusDropsWire("/surplus-inline", false, 200, test_support.surplus_body);
}

// A response without a body ends at its head, so any byte after the head is
// surplus.
test "egress http1 bodiless response followed by bytes does not pool its wire" {
    try expectSurplusDropsWire("/no-content-surplus", false, 204, "");
}

fn expectSurplusDropsWire(path: []const u8, open_gate: bool, status: u16, expected_body: []const u8) !void {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const surplus_url = try origin.url(gpa, path);
    defer gpa.free(surplus_url);
    const one_url = try origin.url(gpa, "/one");
    defer gpa.free(one_url);
    const config: transport.Config = .{ .network = origin.policy(), .max_response_body_bytes = 64 };

    var first = Response.init(surplus_url);
    first.expected_status = status;
    defer first.deinit(gpa);
    const continuation = (try runExchange(&client, .{ .url = surplus_url }, config, &first)) orelse
        return error.ExpectedBodyContinuation;
    if (open_gate)
        origin.gate.store(1, .release);
    try driveContinuationToEnd(&client, continuation, &first, config.socket_timeout_ms, null);
    try first.expectBody(gpa, expected_body);
    try std.testing.expectEqual(@as(usize, 0), client.pool.idleEntries().len);

    // A reused wire would answer this request with the stray head.
    var second = Response.init(one_url);
    defer second.deinit(gpa);
    try fetchViaExchange(&client, .{ .url = one_url, .method = "POST", .body = "payload" }, config, &second);
    try second.expectBody(gpa, "one ok");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
}

// The two policies name the same address and port and differ only in
// allowHttp. The refused fetch runs first, so the accept count shows it
// opened no connection.
test "egress http1 plain HTTP fetch runs under allowHttp and is refused before any connection without it" {
    const origin = try LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    var client: Client = undefined;
    try client.init(gpa);
    defer client.deinit();

    const url = try origin.url(gpa, "/one");
    defer gpa.free(url);
    const network = transport.network;
    const address = try std.net.Address.parseIp4(origin.host(), 0);
    const rules = [_]network.Pattern{.{ .host = .{ .ipv4 = network.address.ipv4Bytes(address) }, .port = origin.port }};
    const https_only_grant: network.Grant = .{
        .allow_http = false,
        .allow_private_networks = true,
        .any = false,
        .names = &.{},
        .suffixes = &.{},
        .ipv4 = &rules,
        .ipv6 = &.{},
    };
    const https_only_grants = [_]*const network.Grant{&https_only_grant};
    const https_only: network.Policy = .{ .grants = &https_only_grants };

    var refused = Response.init(url);
    defer refused.deinit(gpa);
    try std.testing.expectError(error.EgressSchemeDenied, fetchViaExchange(
        &client,
        .{ .url = url, .method = "POST", .body = "payload" },
        .{ .network = https_only, .max_response_body_bytes = 64 },
        &refused,
    ));
    try std.testing.expect(!refused.published);
    try std.testing.expectEqual(@as(usize, 0), origin.accepted.load(.acquire));

    var allowed = Response.init(url);
    defer allowed.deinit(gpa);
    try fetchViaExchange(
        &client,
        .{ .url = url, .method = "POST", .body = "payload" },
        .{ .network = origin.policy(), .max_response_body_bytes = 64 },
        &allowed,
    );
    try allowed.expectBody(gpa, "one ok");
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}
