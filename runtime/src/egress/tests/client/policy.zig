//! Tests of the gateway's outbound policy and transport rules: URL, protocol
//! and destination checks, DNS answer selection, the DNS cache's coalescing,
//! negative caching, invalidation and deadlines, connect racing, body and
//! window limits, and the stall, request and HTTP/1 park deadlines. The DNS
//! cache cases swap in test resolvers wherever they need a lookup to fail,
//! block or stall.

const std = @import("std");
const gateway_egress = @import("collo_egress_client");
const dns_cache = gateway_egress.dns_cache;
const egress_transport = gateway_egress.transport;
const readiness = gateway_egress.readiness;

test "egress stall deadline is an idle timeout: resets on progress, bounded by the total" {
    const ms = std.time.ns_per_ms;

    // The socket timeout is a stall clock: with no request deadline, the
    // deadline is exactly `socket_timeout_ms` from now.
    const idle_only = egress_transport.Config{ .socket_timeout_ms = 5_000 };
    try std.testing.expectEqual(@as(u64, 1_000_000 + 5_000 * ms), idle_only.stallDeadlineFromNow(1_000_000));

    // A later refresh, as when a chunk arrives, pushes the deadline forward
    // by exactly the elapsed time, so a long transfer that keeps progressing
    // never times out.
    const first = idle_only.stallDeadlineFromNow(1_000_000);
    const later = idle_only.stallDeadlineFromNow(1_000_000 + 4_000 * ms);
    try std.testing.expectEqual(first + 4_000 * ms, later);

    // The request deadline caps every refresh, so the stall clock never
    // pushes the fetch past its total bound.
    const capped = egress_transport.Config{
        .socket_timeout_ms = 5_000,
        .request_deadline_mono_ns = 1_000_000 + 2_000 * ms,
    };
    try std.testing.expectEqual(
        @as(u64, 1_000_000 + 2_000 * ms),
        capped.stallDeadlineFromNow(1_000_000),
    );
    // Even refreshing right up against the total never exceeds it.
    try std.testing.expectEqual(
        @as(u64, 1_000_000 + 2_000 * ms),
        capped.stallDeadlineFromNow(1_000_000 + 1_900 * ms),
    );
}

test "fetch protocol validation is explicit" {
    try egress_transport.validateProtocol("https://example.com/", false);
    try std.testing.expectError(error.PlainHttpFetchDisabled, egress_transport.validateProtocol("http://example.com/", false));
    try egress_transport.validateProtocol("http://example.com/", true);
    try std.testing.expectError(error.UnsupportedFetchProtocol, egress_transport.validateProtocol("file:///tmp/x", true));
}

test "egress policy rejects private and metadata destinations" {
    const policy = egress_transport.EgressPolicy{};
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("0.0.0.0", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("0.1.2.3", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("127.0.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("10.0.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("100.64.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("169.254.169.254", 80)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("172.16.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("172.31.255.255", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("192.168.1.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("198.18.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("224.0.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("240.0.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("255.255.255.255", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp6("::1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp6("::", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp6("fd00::1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp6("fe80::1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp6("ff02::fb", 5353)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp6("::ffff:127.0.0.1", 443)));
    try policy.validateResolvedAddress(try std.net.Address.parseIp4("93.184.216.34", 443));
    try policy.validateResolvedAddress(try std.net.Address.parseIp6("2606:2800:220:1:248:1893:25c8:1946", 443));
    try std.testing.expectError(error.EgressDenied, policy.validateUrl("https://localhost/"));
}

test "egress policy normalizes parser edge cases before DNS" {
    const policy = egress_transport.EgressPolicy{};
    try std.testing.expectError(error.EgressDenied, policy.validateUrl("https://localhost./"));
    try std.testing.expectError(error.EgressDenied, policy.validateUrl("https://demo.localhost./"));
    try std.testing.expectError(error.EgressDenied, policy.validateUrl("https://user:pass@localhost./"));
    try std.testing.expectError(error.InvalidFetchUrl, policy.validateUrl("https://exämple.com/"));
    try std.testing.expectError(error.InvalidFetchUrl, policy.validateUrl("https://%6cocalhost/"));
    try std.testing.expectError(error.InvalidFetchUrl, policy.validateUrl("https://0177.0.0.1/"));
    try std.testing.expectError(error.InvalidFetchUrl, policy.validateUrl("https://127.1/"));

    const dotted = try policy.parseTarget("https://example.com./data");
    try std.testing.expectEqualStrings("example.com", dotted.tls_server_name);
}

test "egress private opt-in still blocks local infrastructure addresses" {
    const policy = egress_transport.EgressPolicy{ .allow_private_networks = true };
    try policy.validateResolvedAddress(try std.net.Address.parseIp4("10.0.0.1", 443));
    try policy.validateResolvedAddress(try std.net.Address.parseIp4("172.16.0.1", 443));
    try policy.validateResolvedAddress(try std.net.Address.parseIp4("192.168.1.1", 443));
    try policy.validateResolvedAddress(try std.net.Address.parseIp6("fd00::1", 443));

    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("127.0.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp6("::1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp6("::ffff:127.0.0.1", 443)));
    try std.testing.expectError(error.EgressDenied, policy.validateResolvedAddress(try std.net.Address.parseIp4("169.254.169.254", 80)));
}

test "egress policy blocks well-known NAT64 translation prefixes" {
    const default_policy = egress_transport.EgressPolicy{};
    try std.testing.expectError(error.EgressDenied, default_policy.validateResolvedAddress(try std.net.Address.parseIp6("64:ff9b::7f00:1", 443)));
    try std.testing.expectError(error.EgressDenied, default_policy.validateResolvedAddress(try std.net.Address.parseIp6("64:ff9b::5db8:d822", 443)));
    try std.testing.expectError(error.EgressDenied, default_policy.validateResolvedAddress(try std.net.Address.parseIp6("64:ff9b:1::7f00:1", 443)));

    const private_policy = egress_transport.EgressPolicy{ .allow_private_networks = true };
    try std.testing.expectError(error.EgressDenied, private_policy.validateResolvedAddress(try std.net.Address.parseIp6("64:ff9b::0a00:1", 443)));
}

test "egress DNS policy rejects mixed safe and blocked answers" {
    const policy = egress_transport.EgressPolicy{};
    const answers = [_]std.net.Address{
        try std.net.Address.parseIp4("93.184.216.34", 443),
        try std.net.Address.parseIp4("127.0.0.1", 443),
    };
    try std.testing.expectError(error.EgressDenied, policy.selectResolvedAddress(&answers));
}

test "egress DNS policy returns first answer only after validating all answers" {
    const policy = egress_transport.EgressPolicy{};
    const answers = [_]std.net.Address{
        try std.net.Address.parseIp4("93.184.216.34", 443),
        try std.net.Address.parseIp6("2606:2800:220:1:248:1893:25c8:1946", 443),
    };
    const selected = try policy.selectResolvedAddress(&answers);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 93, 184, 216, 34 }, &egress_transport.ipv4Bytes(selected));
}

test "egress DNS cache coalesces completed lookups and invalidates entries" {
    var cache = egress_transport.DnsCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const first = try cache.resolve(std.testing.allocator, "127.0.0.1", 80);
    defer std.testing.allocator.free(first);
    try std.testing.expect(first.len > 0);

    const second = try cache.resolve(std.testing.allocator, "127.0.0.1", 80);
    defer std.testing.allocator.free(second);
    try std.testing.expect(second.len > 0);

    cache.invalidate("127.0.0.1", 80);
    const third = try cache.resolve(std.testing.allocator, "127.0.0.1", 80);
    defer std.testing.allocator.free(third);
    try std.testing.expect(third.len > 0);
}

var negative_lookup_count = std.atomic.Value(usize).init(0);

fn failingResolver(allocator: std.mem.Allocator, host: []const u8, port: u16) dns_cache.LookupResult {
    _ = allocator;
    _ = host;
    _ = port;
    _ = negative_lookup_count.fetchAdd(1, .acq_rel);
    return .{ .failure = error.UnknownHostName };
}

test "egress DNS cache keeps negative lookups for short TTL and invalidates explicitly" {
    negative_lookup_count.store(0, .release);
    var cache = egress_transport.DnsCache.init(std.testing.allocator, .{
        .ttl_ns = std.time.ns_per_hour,
        .negative_ttl_ns = std.time.ns_per_hour,
        .resolver = failingResolver,
    });
    defer cache.deinit();

    try std.testing.expectError(error.UnknownHostName, cache.resolve(std.testing.allocator, "missing.example.test", 443));
    try std.testing.expectError(error.UnknownHostName, cache.resolve(std.testing.allocator, "missing.example.test", 443));
    try std.testing.expectEqual(@as(usize, 1), negative_lookup_count.load(.acquire));

    cache.invalidate("missing.example.test", 443);
    try std.testing.expectError(error.UnknownHostName, cache.resolve(std.testing.allocator, "missing.example.test", 443));
    try std.testing.expectEqual(@as(usize, 2), negative_lookup_count.load(.acquire));
}

fn transientResolver(allocator: std.mem.Allocator, host: []const u8, port: u16) dns_cache.LookupResult {
    _ = allocator;
    _ = host;
    _ = port;
    _ = negative_lookup_count.fetchAdd(1, .acq_rel);
    return .{ .failure = error.DnsLookupFailed };
}

test "egress DNS cache does not negative-cache transient resolver failures" {
    negative_lookup_count.store(0, .release);
    var cache = egress_transport.DnsCache.init(std.testing.allocator, .{
        .ttl_ns = std.time.ns_per_hour,
        .negative_ttl_ns = std.time.ns_per_hour,
        .resolver = transientResolver,
        .resolver_worker_count = 0,
    });
    defer cache.deinit();

    try std.testing.expectError(error.DnsLookupFailed, cache.resolve(std.testing.allocator, "flaky.example.test", 443));
    try std.testing.expectError(error.DnsLookupFailed, cache.resolve(std.testing.allocator, "flaky.example.test", 443));
    try std.testing.expectEqual(@as(usize, 2), negative_lookup_count.load(.acquire));
}

var blocking_resolver_entered: std.Thread.ResetEvent = .{};
var blocking_resolver_release: std.Thread.ResetEvent = .{};

fn blockingResolver(allocator: std.mem.Allocator, host: []const u8, port: u16) dns_cache.LookupResult {
    blocking_resolver_entered.set();
    blocking_resolver_release.wait();
    const addresses = allocator.alloc(std.net.Address, 1) catch |err|
        return .{ .failure = err };
    addresses[0] = std.net.Address.parseIp4(host, port) catch |err| {
        allocator.free(addresses);
        return .{ .failure = err };
    };
    return .{ .success = addresses };
}

var blocking_resolve_ok = std.atomic.Value(bool).init(false);

fn resolveWhileInvalidated(cache: *egress_transport.DnsCache) void {
    const addresses = cache.resolve(std.testing.allocator, "93.184.216.34", 443) catch return;
    std.testing.allocator.free(addresses);
    blocking_resolve_ok.store(true, .release);
}

test "egress DNS cache invalidate defers removal while a lookup is in flight" {
    // Destroying a busy entry would be a use-after-free: the resolver thread
    // reads `host_lower` with the mutex released and clears `job_active`
    // when it finishes, and the caller thread waits on the entry.
    // `invalidate` must defer the removal like every other remover.
    blocking_resolver_entered.reset();
    blocking_resolver_release.reset();
    blocking_resolve_ok.store(false, .release);
    var cache = egress_transport.DnsCache.init(std.testing.allocator, .{
        .resolver = blockingResolver,
        .resolver_worker_count = 1,
    });
    defer cache.deinit();

    const resolver_thread = try std.Thread.spawn(.{}, resolveWhileInvalidated, .{&cache});
    // The resolver thread is inside the lookup: the entry is in flight with
    // `job_active` set, and the caller thread is parked as a waiter.
    blocking_resolver_entered.wait();
    cache.invalidate("93.184.216.34", 443);
    {
        cache.mutex.lock();
        defer cache.mutex.unlock();
        // Deferred, not destroyed.
        try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    }
    blocking_resolver_release.set();
    resolver_thread.join();
    try std.testing.expect(blocking_resolve_ok.load(.acquire));
}

fn slowResolver(allocator: std.mem.Allocator, host: []const u8, port: u16) dns_cache.LookupResult {
    std.Thread.sleep(20 * std.time.ns_per_ms);
    const addresses = allocator.alloc(std.net.Address, 1) catch |err|
        return .{ .failure = err };
    addresses[0] = std.net.Address.parseIp4(host, port) catch |err| {
        allocator.free(addresses);
        return .{ .failure = err };
    };
    return .{ .success = addresses };
}

test "egress DNS cache wait respects request deadline while resolver continues" {
    var cache = egress_transport.DnsCache.init(std.testing.allocator, .{
        .resolver = slowResolver,
        .resolver_worker_count = 1,
    });
    defer cache.deinit();

    try std.testing.expectError(
        error.FetchRequestDeadlineExceeded,
        cache.resolveUntil(
            std.testing.allocator,
            "93.184.216.34",
            443,
            try readiness.deadlineAfterMs(1),
        ),
    );
}

test "egress DNS cache applies stall ceiling when caller has no request deadline" {
    var cache = egress_transport.DnsCache.init(std.testing.allocator, .{
        .resolver = slowResolver,
        .resolver_worker_count = 1,
        .resolver_stall_timeout_ns = std.time.ns_per_ms,
    });
    defer cache.deinit();

    try std.testing.expectError(
        error.DnsLookupTimeout,
        cache.resolveUntil(std.testing.allocator, "93.184.216.34", 443, 0),
    );
}

test "ipv4 policy reads network-order address bytes" {
    const address = try std.net.Address.parseIp4("1.2.3.4", 443);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &egress_transport.ipv4Bytes(address));
}

test "egress target uses validated numeric connect host" {
    const policy = egress_transport.EgressPolicy{};
    var cache = egress_transport.DnsCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const request_target = try policy.parseTarget("https://93.184.216.34/");
    var target = try policy.resolveRequestTarget(std.testing.allocator, &cache, request_target);
    defer target.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("93.184.216.34", target.authority_host);
    try std.testing.expectEqualStrings("93.184.216.34", target.tls_server_name);
    try std.testing.expectEqualStrings("93.184.216.34", target.connect_host);
    try std.testing.expectEqual(@as(u16, 443), target.port);
}

test "egress target keeps ipv6 authority separate from tls server name" {
    const policy = egress_transport.EgressPolicy{};
    var cache = egress_transport.DnsCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const request_target = try policy.parseTarget("https://[2606:2800:220:1:248:1893:25c8:1946]:8443/");
    var target = try policy.resolveRequestTarget(std.testing.allocator, &cache, request_target);
    defer target.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[2606:2800:220:1:248:1893:25c8:1946]", target.authority_host);
    try std.testing.expectEqualStrings("2606:2800:220:1:248:1893:25c8:1946", target.tls_server_name);
    try std.testing.expectEqualStrings("2606:2800:220:1:248:1893:25c8:1946", target.connect_host);
    try std.testing.expectEqual(@as(u16, 8443), target.port);
}

test "egress target rejects bracketed non-ipv6 hosts" {
    const policy = egress_transport.EgressPolicy{};
    try std.testing.expectError(error.InvalidFetchUrl, policy.validateUrl("https://[example.com]/"));
}

test "binary fetch headers clone to http1 headers" {
    const input = [_]egress_transport.Header{
        .{ .name = "x-collo-test", .value = "yes" },
        .{ .name = "accept", .value = "application/json" },
    };
    var parsed = try egress_transport.parseFetchHeaders(std.testing.allocator, &input);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.headers.items.len);
    try std.testing.expectEqualStrings("x-collo-test", parsed.headers.items[0].name);
    try std.testing.expectEqualStrings("yes", parsed.headers.items[0].value);
}

test "response body buffering enforces maximum" {
    var body = try std.array_list.Aligned(u8, null).initCapacity(std.testing.allocator, 16);
    defer body.deinit(std.testing.allocator);
    try egress_transport.appendResponseChunk(std.testing.allocator, &body, "12345678", 16);
    try egress_transport.appendResponseChunk(std.testing.allocator, &body, "abcdefgh", 16);
    try std.testing.expectEqualStrings("12345678abcdefgh", body.items);
    try std.testing.expectError(error.FetchResponseTooLarge, egress_transport.appendResponseChunk(std.testing.allocator, &body, "!", 16));
}

test "compressed stream pump keeps decoded queue watermark separate from body cap" {
    const config = egress_transport.Config{
        .max_response_body_bytes = 4 * 1024 * 1024,
        .max_encoded_response_bytes = 512 * 1024,
        .max_pending_decoded_body_bytes = 256 * 1024,
    };

    const identity_limits = config.streamPumpLimitsForEncoding(.identity);
    try std.testing.expectEqual(@as(usize, 256 * 1024), identity_limits.max_pending_decoded_bytes);
    try std.testing.expectEqual(@as(usize, 512 * 1024), identity_limits.max_encoded_bytes);

    const compressed_limits = config.streamPumpLimitsForEncoding(.gzip);
    try std.testing.expectEqual(@as(usize, 256 * 1024), compressed_limits.max_pending_decoded_bytes);
    try std.testing.expectEqual(@as(usize, 512 * 1024), compressed_limits.max_encoded_bytes);
}

test "http2 advertised receive window respects encoded budget" {
    const config = egress_transport.Config{
        .max_response_body_bytes = 4 * 1024 * 1024,
        .max_encoded_response_bytes = 32 * 1024,
        .max_pending_decoded_body_bytes = 256 * 1024,
        .http2_stream_receive_window = 1024 * 1024,
    };
    const limits = try config.http2Limits().normalized();
    try std.testing.expectEqual(@as(u32, 32 * 1024), limits.stream_receive_window);
}

test "connect racing continues past first parallel candidate window" {
    var server_address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try server_address.listen(.{ .reuse_address = true });
    defer server.deinit();

    const accept_thread = try std.Thread.spawn(.{}, acceptOneForConnectRace, .{&server});
    defer accept_thread.join();

    const port = server.listen_address.getPort();
    var refused_ports: [4]u16 = undefined;
    for (&refused_ports) |*refused_port|
        refused_port.* = try closedLoopbackPort();
    const addresses = [_]std.net.Address{
        try std.net.Address.parseIp4("127.0.0.1", refused_ports[0]),
        try std.net.Address.parseIp4("127.0.0.1", refused_ports[1]),
        try std.net.Address.parseIp4("127.0.0.1", refused_ports[2]),
        try std.net.Address.parseIp4("127.0.0.1", refused_ports[3]),
        try std.net.Address.parseIp4("127.0.0.1", port),
    };
    var driver = try readiness.Driver.initWithBackend(std.testing.allocator, .poll);
    defer driver.deinit();

    const deadline = try readiness.deadlineAfterMs(2000);
    errdefer {
        if (std.net.Address.parseIp4("127.0.0.1", port)) |wake_address| {
            if (std.net.tcpConnectToAddress(wake_address)) |wake| {
                wake.close();
            } else |_| {}
        } else |_| {}
    }
    var stream = try egress_transport.connectStreamWithReadiness(&addresses, deadline, &driver, null, .{});
    defer stream.close();
}

fn acceptOneForConnectRace(server: *std.net.Server) void {
    var connection = server.accept() catch return;
    connection.stream.close();
}

fn closedLoopbackPort() !u16 {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    const port = server.listen_address.getPort();
    server.deinit();
    return port;
}

test "h1 owner-loop pending deadlines follow the two-clock model" {
    const engine = gateway_egress.engine;
    const ms = std.time.ns_per_ms;

    var pending = engine.H1Pending{
        .command = .{
            .task = undefined,
            .config = .{ .socket_timeout_ms = 5_000 },
        },
        .body_pipe = undefined,
        .source_id = 1,
        .phase = .{ .exchange = undefined },
        .park = .runnable,
    };

    // Connector waits and runnable pendings arm no deadline: the connector's
    // own connect and handshake budgets bound the dial, as they do for an
    // HTTP/2 connect group, and runnables are stepped before the next wait.
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), pending.effectiveDeadlineMonoNs());
    pending.park = .awaiting_connect;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), pending.effectiveDeadlineMonoNs());

    // An io park carries the stall deadline recorded when it parked, a fresh
    // `socket_timeout_ms` window per park.
    pending.park = .{ .io = .{
        .fd = -1,
        .interest = .read,
        .timeout_err = error.FetchReadTimeout,
        .deadline_mono_ns = 42_000 * ms,
    } };
    try std.testing.expectEqual(@as(u64, 42_000 * ms), pending.effectiveDeadlineMonoNs());
    // Before the total deadline, expiry surfaces the park's stage error...
    try std.testing.expectEqual(error.FetchReadTimeout, pending.expiredErrorAt(42_000 * ms));
    pending.park.io.timeout_err = error.FetchWriteTimeout;
    try std.testing.expectEqual(error.FetchWriteTimeout, pending.expiredErrorAt(42_000 * ms));

    // A credit park (consumer backpressure) suspends the stall clock
    // entirely: without a total request deadline it never expires...
    pending.park = .credit;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), pending.effectiveDeadlineMonoNs());

    // ...and with one, the total clock still caps the fetch, and expiry is
    // attributed to the request deadline, not a read timeout.
    pending.command.config.request_deadline_mono_ns = 90_000 * ms;
    try std.testing.expectEqual(@as(u64, 90_000 * ms), pending.effectiveDeadlineMonoNs());
    try std.testing.expectEqual(error.FetchRequestDeadlineExceeded, pending.expiredErrorAt(90_000 * ms));

    // The total clock also reattributes an io-park expiry once it has passed.
    pending.park = .{ .io = .{
        .fd = -1,
        .interest = .read,
        .timeout_err = error.FetchReadTimeout,
        .deadline_mono_ns = 89_000 * ms,
    } };
    try std.testing.expectEqual(error.FetchReadTimeout, pending.expiredErrorAt(89_000 * ms));
    try std.testing.expectEqual(error.FetchRequestDeadlineExceeded, pending.expiredErrorAt(90_000 * ms));

    // A dial-retry park, made when the connector queue is full at dispatch,
    // waits on its recorded retry-tick deadline with no fd, like a credit
    // park, and expiry past the total clock is attributed to the request
    // deadline.
    pending.park = .{ .dial_retry = .{ .deadline_mono_ns = 88_000 * ms } };
    try std.testing.expectEqual(@as(u64, 88_000 * ms), pending.effectiveDeadlineMonoNs());
    try std.testing.expectEqual(error.FetchRequestDeadlineExceeded, pending.expiredErrorAt(90_000 * ms));

    // The park deadline is one retry tick from now, capped by the total
    // request deadline: the tick only decides when the dispatch retries;
    // the total clock alone decides when the fetch fails.
    const tick = engine.H1Pending.dial_retry_tick_ns;
    try std.testing.expectEqual(@as(u64, 50_000 * ms + tick), pending.dialRetryParkDeadline(50_000 * ms));
    try std.testing.expectEqual(@as(u64, 90_000 * ms), pending.dialRetryParkDeadline(90_000 * ms - 1));

    // Without a request deadline, which is zero in production for a boot
    // permit, the tick still bounds the park, so a queue-full dial parks on
    // the tick instead of spinning runnable at full CPU.
    pending.command.config.request_deadline_mono_ns = 0;
    try std.testing.expectEqual(@as(u64, 50_000 * ms + tick), pending.dialRetryParkDeadline(50_000 * ms));
    pending.park = .{ .dial_retry = .{ .deadline_mono_ns = 50_000 * ms + tick } };
    try std.testing.expectEqual(@as(u64, 50_000 * ms + tick), pending.effectiveDeadlineMonoNs());
}
