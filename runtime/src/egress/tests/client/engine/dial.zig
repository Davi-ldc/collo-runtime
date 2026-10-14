//! Engine tests of dials (`egress/client/engine/dial.zig`, lane
//! `egress-test`), each driven through `Engine.submit`: fetches to one
//! origin share a dial and its connection; ALPN decides between HTTP/2 and
//! HTTP/1; every resolved address and every HTTP/1 redirect hop passes the
//! fetch's policy before a socket opens; each dial phase fails at its own
//! stall deadline and each waiting fetch at its own request deadline; a hop
//! that joined a timed-out dial late gets a fresh one; a cancel or a stop
//! settles a fetch exactly once in every dial phase and closes what its dial
//! held; a canceled dial leaves its origin usable; and the owner serves
//! other origins between the steps of a handshake. HTTP/2-capable fetches
//! (https) wait on their origin's shared dial, and HTTP/1 fetches (plain
//! http, or `enable_http2 = false`) dial alone, so each phase is tested for
//! both kinds.
//!
//! A test pins a dial in a phase by what the phase shows from outside: a
//! call held inside the test resolver, an attempt's socket in the process's
//! descriptor table, a ClientHello at a silent origin. The connecting phase
//! needs a listener whose full accept queue keeps a TCP connect in
//! progress (`support.FullListener`), so the tests that use it skip on a
//! host whose TCP stack completes such a connect anyway. Happy Eyeballs
//! itself is tested on `Schedule` in `../connect.zig`, and the DNS cache in
//! `../dns_cache.zig`.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const local_address = @import("collo_test_net");
const tls_shim = @import("collo_test_tls_shim");
const http1_support = @import("../http1/support.zig");
const network_policy = @import("../network_policy.zig");
const support = @import("support.zig");

const egress_engine = egress_client.engine;
const task_model = egress_client.task;
const monotonicNowNs = egress_client.transport.config.monotonicNowNs;
const gpa = std.testing.allocator;

// The test origin serves one connection, so the second fetch completes only
// if it waited on the first fetch's dial and opened its stream on the same
// connection.
test "egress engine fetches to one origin share its dial and connection" {
    var origin: ?*tls_shim.TestH2Origin = null;
    var port: u16 = 0;
    if (tls_shim.collo_test_h2_origin_start(tls_shim.test_h2_origin_alpn_h2, &origin, &port) != 0)
        return error.StartLocalH2OriginFailed;
    defer tls_shim.collo_test_h2_origin_stop(origin.?);

    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const url_one = try std.fmt.allocPrint(gpa, "https://{s}:{d}/one", .{ host, port });
    defer gpa.free(url_one);
    const url_two = try std.fmt.allocPrint(gpa, "https://{s}:{d}/two", .{ host, port });
    defer gpa.free(url_two);
    var first = try support.initEngineFetchTask(gpa, 21, url_one, 21);
    defer first.deinit();
    var second = try support.initEngineFetchTask(gpa, 22, url_two, 22);
    defer second.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &second);
    defer _ = support.releaseTaskBodyCredits(&engine, &first);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{port});
    const config = egress_client.Config{
        .network = origins.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &first, .config = config });
    try engine.submit(.{ .task = &second, .config = config });
    try support.waitTaskDone(&first, 5_000);
    try support.waitTaskDone(&second, 5_000);
    try support.expectTaskStatus(&first, 200);
    try support.expectTaskStatus(&second, 200);
    var body_buffer: [64]u8 = undefined;
    _ = try support.readBody(&engine, first.response_body, &body_buffer, 5_000);
    _ = try support.readBody(&engine, second.response_body, &body_buffer, 5_000);
    try std.testing.expectEqual(@as(u32, 2), tls_shim.collo_test_h2_origin_stream_count(origin.?));
}

// An origin whose handshake chooses http/1.1 hands the dialed connection to
// the fetch, which runs on HTTP/1 without a second dial (the test origin
// serves one connection).
test "egress engine serves a fetch over HTTP/1 when the handshake chooses http/1.1" {
    var origin: ?*tls_shim.TestH2Origin = null;
    var port: u16 = 0;
    if (tls_shim.collo_test_h2_origin_start(tls_shim.test_h2_origin_alpn_http11, &origin, &port) != 0)
        return error.StartLocalH2OriginFailed;
    defer tls_shim.collo_test_h2_origin_stop(origin.?);

    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const url = try std.fmt.allocPrint(gpa, "https://{s}:{d}/fallback", .{ host, port });
    defer gpa.free(url);
    var task = try support.initEngineFetchTask(gpa, 23, url, 23);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &task);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{port});
    const config = egress_client.Config{
        .network = origins.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 5_000);
    try support.expectTaskStatus(&task, 200);
    var body_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("fallback", try support.readBody(&engine, task.response_body, &body_buffer, 5_000));
}

// The answer holds this host's address, public or private as the host is,
// then a private address, which the policy refuses. A resolution with any
// refused address is refused whole, so the dial opens no socket, not even to
// the first address, where the idle listener would have queued the
// connection; the private address comes second and is never dialed.
test "egress engine refuses a DNS answer holding a private address under public HTTPS and opens no socket" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    var listener = try support.IdleListener.start(host);
    defer listener.stop();
    const answer = [_]std.net.Address{
        try std.net.Address.parseIp4(host, listener.port),
        std.net.Address.initIp4(.{ 10, 0, 0, 1 }, listener.port),
    };
    support.TestResolver.reset(.{ .answer = &answer });
    var task = try support.initEngineFetchTask(gpa, 100, "https://private-answer.test/", 100);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    engine.dns_cache.config.resolver = support.TestResolver.resolve;
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = network_policy.public_https,
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 5_000);
    // Stop returns once every socket the engine opened is closed, so a
    // connection the dial made would wait in the listener's queue by now.
    engine.stop();
    try support.expectTaskDenied(&task, .{ .scheme = .https, .host = "private-answer.test", .port = 443 }, .private_address);
    // The refusal came after the lookup, from the dial.
    try std.testing.expectEqual(@as(usize, 1), support.TestResolver.callCount());
    try std.testing.expect(!(try listener.hasPendingConnection()));
    try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(&task));
}

// The origin listens on every address, so a hop to 127.0.0.1 that got past
// the policy would have been its second connection.
test "egress engine refuses an HTTP/1 redirect to a loopback address before it connects" {
    const origin = try http1_support.LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    const url = try origin.url(gpa, "/redirect-loopback");
    defer gpa.free(url);
    var task = try support.initEngineFetchTask(gpa, 110, url, 110);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = origin.policy(),
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 5_000);
    engine.stop();
    try support.expectTaskDenied(&task, .{ .scheme = .http, .host = "127.0.0.1", .port = origin.port }, .reserved_address);
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(&task));
}

test "egress engine refuses an HTTP/1 redirect to a port the policy does not name and connects nowhere" {
    const origin = try http1_support.LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    // Serves on the same address as `origin`, on a port its policy omits.
    const unnamed = try http1_support.LocalHttp1Origin.start(gpa);
    defer unnamed.stop(gpa);
    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/redirect-port/{d}", .{ origin.host(), origin.port, unnamed.port });
    defer gpa.free(url);
    var task = try support.initEngineFetchTask(gpa, 111, url, 111);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = origin.policy(),
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 5_000);
    engine.stop();
    try support.expectTaskDenied(&task, .{ .scheme = .http, .host = origin.host(), .port = unnamed.port }, .port_not_allowed);
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), unnamed.accepted.load(.acquire));
}

// The redirect of the previous test under a policy that names both ports:
// the second hop gets a plan of its own, decided under the fetch's policy,
// and connects to the other origin.
test "egress engine prepares each HTTP/1 redirect hop under the fetch's policy" {
    const origin = try http1_support.LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    const target = try http1_support.LocalHttp1Origin.start(gpa);
    defer target.stop(gpa);
    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/redirect-port/{d}", .{ origin.host(), origin.port, target.port });
    defer gpa.free(url);
    const target_url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/one", .{ target.host(), target.port });
    defer gpa.free(target_url);
    var task = try support.initEngineFetchTask(gpa, 112, url, 112);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &task);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(origin.host(), &.{ origin.port, target.port });
    const config = egress_client.Config{
        .network = origins.policy(),
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 5_000);
    try support.expectTaskStatus(&task, 200);
    try support.expectTaskRedirectedTo(&task, target_url);
    var body_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("one ok", try support.readBody(&engine, task.response_body, &body_buffer, 5_000));
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), target.accepted.load(.acquire));
}

// The resolver holds the lookup past the stall budget of the dial's DNS
// phase.
test "egress engine fails a dial whose DNS lookup outlasts the socket timeout with DnsLookupTimeout" {
    support.TestResolver.reset(.{ .hold = true });
    var task = try support.initEngineFetchTask(gpa, 120, "https://slow-dns.example/", 120);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    // Joining the resolver threads waits for the held lookup, so it is let
    // go before the engine's deinit.
    defer support.TestResolver.releaseHeld();
    engine.dns_cache.config.resolver = support.TestResolver.resolve;
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = network_policy.public_https,
        .socket_timeout_ms = 200,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.TestResolver.waitCalls(1, 2_000);
    try support.waitTaskDone(&task, 5_000);
    try support.expectTaskFailureMessage(&task, "DnsLookupTimeout");
    engine.stop();
    try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(&task));
}

// The resolver answers the full listener's address, so the dial connects
// through DNS and its connect stalls. The answer stays in the DNS cache for
// its TTL, so only the timeout's invalidation sends the next dial to the
// resolver again.
test "egress engine fails a stalled TCP connect with FetchConnectTimeout and asks DNS again on the next dial" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    var listener = try support.FullListener.start(host);
    defer listener.stop();
    const answer = [_]std.net.Address{try std.net.Address.parseIp4(host, listener.port)};
    support.TestResolver.reset(.{ .answer = &answer });
    var first = try support.initEngineFetchTask(gpa, 130, "https://connect.dial.test/", 130);
    defer first.deinit();
    var second = try support.initEngineFetchTask(gpa, 131, "https://connect.dial.test/", 131);
    defer second.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    engine.dns_cache.config.resolver = support.TestResolver.resolve;
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = support.dial_test_names,
        .socket_timeout_ms = 200,
    };
    const descriptors_before = try support.openDescriptorCount();

    try engine.submit(.{ .task = &first, .config = config });
    try support.waitTaskDone(&first, 5_000);
    try support.expectTaskFailureMessage(&first, "FetchConnectTimeout");
    try std.testing.expectEqual(@as(usize, 1), support.TestResolver.callCount());
    // The stalled attempt's socket closed with its dial.
    try support.waitDescriptorCount(descriptors_before, 1_000);

    try engine.submit(.{ .task = &second, .config = config });
    try support.waitTaskDone(&second, 5_000);
    try support.expectTaskFailureMessage(&second, "FetchConnectTimeout");
    try std.testing.expectEqual(@as(usize, 2), support.TestResolver.callCount());
    engine.stop();
    try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(&first));
    try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(&second));
}

// Happy Eyeballs on real sockets: the answer's first address is the full
// listener, whose connect stalls, and its second a live origin. The second
// attempt can start only once the attempt delay passed with the first still
// pending, and its connect closes the stalled one. The origin's thread opens
// and closes the accepted connection meanwhile, so the descriptor count is
// compared once that connection is done.
test "egress engine starts the next address after the attempt delay when a connect stalls, and closes the stalled attempt" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    var listener = try support.FullListener.start(host);
    defer listener.stop();
    const origin = try http1_support.LocalHttp1Origin.start(gpa);
    defer origin.stop(gpa);
    const answer = [_]std.net.Address{
        try std.net.Address.parseIp4(host, listener.port),
        try std.net.Address.parseIp4(host, origin.port),
    };
    support.TestResolver.reset(.{ .answer = &answer });
    var task = try support.initEngineFetchTask(gpa, 135, "http://eyeballs.dial.test/fast", 135);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &task);
    defer engine.stop();
    engine.dns_cache.config.resolver = support.TestResolver.resolve;
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = support.dial_test_names,
        .socket_timeout_ms = 5_000,
    };
    const descriptors_before = try support.openDescriptorCount();

    const submitted_ns = try monotonicNowNs();
    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 5_000);
    const done_ns = try monotonicNowNs();
    try support.expectTaskStatus(&task, 200);
    try std.testing.expect(done_ns - submitted_ns >= egress_client.transport.connect.attempt_delay_ns);
    var body_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("fast ok", try support.readBody(&engine, task.response_body, &body_buffer, 5_000));
    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
    // The origin closes the connection after its answer, so nothing of the
    // fetch stays open: neither the winner nor the stalled attempt.
    try support.waitDescriptorCount(descriptors_before, 2_000);
}

// Two fetches share one dial, which waits on a held DNS lookup. The first
// has a request deadline and fails at it; the dial goes on, and once the
// lookup is let go it serves the second fetch, which never asked DNS again.
test "egress engine fails a waiter at its request deadline while the dial goes on for the others" {
    var origin: ?*tls_shim.TestH2Origin = null;
    var port: u16 = 0;
    if (tls_shim.collo_test_h2_origin_start(tls_shim.test_h2_origin_alpn_h2, &origin, &port) != 0)
        return error.StartLocalH2OriginFailed;
    defer tls_shim.collo_test_h2_origin_stop(origin.?);
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const answer = [_]std.net.Address{try std.net.Address.parseIp4(host, port)};
    support.TestResolver.reset(.{ .answer = &answer, .hold = true });
    var early = try support.initEngineFetchTask(gpa, 140, "https://deadline.dial.test/one", 140);
    defer early.deinit();
    var patient = try support.initEngineFetchTask(gpa, 141, "https://deadline.dial.test/one", 141);
    defer patient.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    defer support.TestResolver.releaseHeld();
    defer _ = support.releaseTaskBodyCredits(&engine, &patient);
    defer engine.stop();
    engine.dns_cache.config.resolver = support.TestResolver.resolve;
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const patient_config = egress_client.Config{
        .network = support.dial_test_names,
        .insecure_tls = true,
        .socket_timeout_ms = 10_000,
    };
    var early_config = patient_config;
    early_config.request_deadline_mono_ns = (try monotonicNowNs()) + 300 * std.time.ns_per_ms;

    try engine.submit(.{ .task = &early, .config = early_config });
    try engine.submit(.{ .task = &patient, .config = patient_config });
    try support.TestResolver.waitCalls(1, 2_000);
    try support.waitTaskDone(&early, 5_000);
    try support.expectTaskFailureMessage(&early, "FetchRequestDeadlineExceeded");
    try std.testing.expect(!support.taskDone(&patient));

    support.TestResolver.releaseHeld();
    try support.waitTaskDone(&patient, 5_000);
    try support.expectTaskStatus(&patient, 200);
    var body_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("one", try support.readBody(&engine, patient.response_body, &body_buffer, 5_000));
    try std.testing.expectEqual(@as(usize, 1), support.TestResolver.callCount());
    try std.testing.expectEqual(@as(u32, 1), tls_shim.collo_test_h2_origin_stream_count(origin.?));
    engine.stop();
    try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(&early));
}

// A leader and an early joiner share a dial whose handshake the held origin
// never answers, and a third hop joins halfway through the handshake's stall
// budget. When the phase times out, the leader and the early joiner fail,
// since their own budgets ran out with it, while the late joiner, with
// budget left, gets a fresh dial instead of the leader's timeout. Only the
// clock can place the late join, so the test waits for that instant.
test "egress engine gives a hop that joined a timed-out dial late a fresh dial" {
    const origin = try support.HeldOrigin.start(gpa, 2);
    defer origin.stop(gpa);
    const url = try origin.httpsUrl(gpa);
    defer gpa.free(url);
    var leader = try support.initEngineFetchTask(gpa, 150, url, 150);
    defer leader.deinit();
    var early = try support.initEngineFetchTask(gpa, 151, url, 151);
    defer early.deinit();
    var late = try support.initEngineFetchTask(gpa, 152, url, 152);
    defer late.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const stall_ms: u32 = 400;
    const config = egress_client.Config{
        .network = origin.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = stall_ms,
    };

    try engine.submit(.{ .task = &leader, .config = config });
    try engine.submit(.{ .task = &early, .config = config });
    try origin.waitClientHello(0, 2_000);
    // The handshake phase began before its ClientHello reached the origin,
    // so the late hop joins at least half the budget after it.
    std.Thread.sleep(@as(u64, stall_ms / 2) * std.time.ns_per_ms);
    try engine.submit(.{ .task = &late, .config = config });

    try support.waitTaskDone(&leader, 5_000);
    try support.expectTaskFailureMessage(&leader, "TlsHandshakeTimeout");
    // The dial settles the early joiner right after the leader; a fresh dial
    // would have kept it for a whole stall budget.
    try support.waitTaskDone(&early, 100);
    try support.expectTaskFailureMessage(&early, "TlsHandshakeTimeout");
    try std.testing.expect(!support.taskDone(&late));
    try origin.waitClientHello(1, 2_000);
    try support.waitTaskDone(&late, 5_000);
    try support.expectTaskFailureMessage(&late, "TlsHandshakeTimeout");
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
    engine.stop();
    for ([_]*task_model.Task{ &leader, &early, &late }) |task|
        try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(task));
}

// The resolver threads are held inside both lookups, so each fetch's dial
// waits on its DNS ticket when its cancel arrives: an HTTP/2-capable fetch
// on its origin's shared dial, an HTTP/1 fetch on a dial of its own.
test "egress engine cancel during DNS resolution settles each fetch once" {
    support.TestResolver.reset(.{ .hold = true });
    var shared = try support.initEngineFetchTask(gpa, 30, "https://resolving.example/", 30);
    defer shared.deinit();
    var private = try support.initEngineFetchTask(gpa, 31, "http://resolving.example/", 31);
    defer private.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    defer support.TestResolver.releaseHeld();
    engine.dns_cache.config.resolver = support.TestResolver.resolve;
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const shared_config = egress_client.Config{
        .network = network_policy.public_https,
        .socket_timeout_ms = 10_000,
    };
    const private_config = egress_client.Config{
        .network = network_policy.public_http_and_https,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &shared, .config = shared_config });
    try engine.submit(.{ .task = &private, .config = private_config });
    // Two ports, two lookups: one on each resolver thread.
    try support.TestResolver.waitCalls(2, 2_000);
    engine.cancel(&shared);
    try support.waitTaskDone(&shared, 2_000);
    engine.cancel(&private);
    try support.waitTaskDone(&private, 2_000);
    engine.stop();
    try support.expectSettledOnceCanceled(&wake, &shared);
    try support.expectSettledOnceCanceled(&wake, &private);
}

// A dial is connecting once its attempt's socket exists, which the process's
// descriptor table shows, and the full accept queue keeps the connect in
// progress. Only the engine's owner thread opens or closes descriptors
// meanwhile, so each change of the count is a dial's.
test "egress engine cancel during a TCP connect closes the attempt's socket and settles each fetch once" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    var listener = try support.FullListener.start(host);
    defer listener.stop();
    const shared_url = try std.fmt.allocPrint(gpa, "https://{s}:{d}/", .{ host, listener.port });
    defer gpa.free(shared_url);
    const private_url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/", .{ host, listener.port });
    defer gpa.free(private_url);
    var shared = try support.initEngineFetchTask(gpa, 32, shared_url, 32);
    defer shared.deinit();
    var private = try support.initEngineFetchTask(gpa, 33, private_url, 33);
    defer private.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{listener.port});
    const config = egress_client.Config{
        .network = origins.policy(),
        .socket_timeout_ms = 10_000,
    };
    const descriptors_before = try support.openDescriptorCount();

    try engine.submit(.{ .task = &shared, .config = config });
    try support.waitDescriptorCount(descriptors_before + 1, 2_000);
    try engine.submit(.{ .task = &private, .config = config });
    try support.waitDescriptorCount(descriptors_before + 2, 2_000);

    engine.cancel(&shared);
    try support.waitTaskDone(&shared, 2_000);
    try support.waitDescriptorCount(descriptors_before + 1, 2_000);
    engine.cancel(&private);
    try support.waitTaskDone(&private, 2_000);
    try support.waitDescriptorCount(descriptors_before, 2_000);
    engine.stop();
    try support.expectSettledOnceCanceled(&wake, &shared);
    try support.expectSettledOnceCanceled(&wake, &private);
}

// Each fetch's dial is pinned in its handshake by its ClientHello at the
// held origin, which sees its end of the connection close once the cancel
// released the dial's wire.
test "egress engine cancel during a TLS handshake closes the socket and settles each fetch once" {
    const origin = try support.HeldOrigin.start(gpa, 2);
    defer origin.stop(gpa);
    const url = try origin.httpsUrl(gpa);
    defer gpa.free(url);
    var shared = try support.initEngineFetchTask(gpa, 34, url, 34);
    defer shared.deinit();
    var private = try support.initEngineFetchTask(gpa, 35, url, 35);
    defer private.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const shared_config = egress_client.Config{
        .network = origin.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 10_000,
    };
    var private_config = shared_config;
    private_config.enable_http2 = false;

    try engine.submit(.{ .task = &shared, .config = shared_config });
    try origin.waitClientHello(0, 2_000);
    try engine.submit(.{ .task = &private, .config = private_config });
    try origin.waitClientHello(1, 2_000);

    engine.cancel(&shared);
    try support.waitTaskDone(&shared, 2_000);
    try origin.waitPeerClosed(0, 2_000);
    engine.cancel(&private);
    try support.waitTaskDone(&private, 2_000);
    try origin.waitPeerClosed(1, 2_000);
    engine.stop();
    try std.testing.expectEqual(@as(usize, 2), origin.accepted.load(.acquire));
    try support.expectSettledOnceCanceled(&wake, &shared);
    try support.expectSettledOnceCanceled(&wake, &private);
}

// Stop must settle a fetch whatever its dial is doing and close what the
// dial held. Two fetches wait on DNS, an HTTP/2-capable one on its origin's
// shared dial and an HTTP/1 one on its own; three wait on TLS handshakes,
// two on one shared dial and one on an HTTP/1 dial of its own. An HTTP/1
// fetch leaves its dial before it ends, or settling the dial would reach the
// freed fetch.
test "egress engine stop settles every fetch whose dial is resolving or handshaking exactly once" {
    support.TestResolver.reset(.{ .hold = true });
    const held = try support.HeldOrigin.start(gpa, 2);
    defer held.stop(gpa);
    const handshaking_url = try held.httpsUrl(gpa);
    defer gpa.free(handshaking_url);

    var shared_resolving = try support.initEngineFetchTask(gpa, 40, "https://resolving.example/", 40);
    defer shared_resolving.deinit();
    var private_resolving = try support.initEngineFetchTask(gpa, 41, "http://resolving.example/", 41);
    defer private_resolving.deinit();
    var shared_handshaking = try support.initEngineFetchTask(gpa, 42, handshaking_url, 42);
    defer shared_handshaking.deinit();
    var joined = try support.initEngineFetchTask(gpa, 43, handshaking_url, 43);
    defer joined.deinit();
    var private_handshaking = try support.initEngineFetchTask(gpa, 44, handshaking_url, 44);
    defer private_handshaking.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    defer support.TestResolver.releaseHeld();
    engine.dns_cache.config.resolver = support.TestResolver.resolve;
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const public_https_config = egress_client.Config{
        .network = network_policy.public_https,
        .socket_timeout_ms = 10_000,
    };
    const public_http_config = egress_client.Config{
        .network = network_policy.public_http_and_https,
        .socket_timeout_ms = 10_000,
    };
    const held_config = egress_client.Config{
        .network = held.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 10_000,
    };
    var held_http1_config = held_config;
    held_http1_config.enable_http2 = false;

    try engine.submit(.{ .task = &shared_resolving, .config = public_https_config });
    try engine.submit(.{ .task = &private_resolving, .config = public_http_config });
    try support.TestResolver.waitCalls(2, 2_000);
    try engine.submit(.{ .task = &shared_handshaking, .config = held_config });
    try engine.submit(.{ .task = &joined, .config = held_config });
    try held.waitClientHello(0, 2_000);
    try engine.submit(.{ .task = &private_handshaking, .config = held_http1_config });
    try held.waitClientHello(1, 2_000);

    // A stop returns only once every fetch is settled.
    engine.stop();
    for ([_]*task_model.Task{ &shared_resolving, &private_resolving, &shared_handshaking, &joined, &private_handshaking }) |task| {
        try std.testing.expect(support.taskDone(task));
        try support.expectTaskFailureMessage(task, "EgressEngineStopped");
        try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(task));
    }
    // Two connections reached the held origin: the joined fetch waited on
    // the shared dial. Both closed with the stop.
    try std.testing.expectEqual(@as(usize, 2), held.accepted.load(.acquire));
    try held.waitPeerClosed(0, 2_000);
    try held.waitPeerClosed(1, 2_000);
}

// The connecting phase of the stop above, apart because it needs the full
// accept queue. Each dial's attempt socket shows in the descriptor table.
test "egress engine stop closes connecting dials' sockets and settles every fetch exactly once" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    var listener = try support.FullListener.start(host);
    defer listener.stop();
    const shared_url = try std.fmt.allocPrint(gpa, "https://{s}:{d}/", .{ host, listener.port });
    defer gpa.free(shared_url);
    const private_url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/", .{ host, listener.port });
    defer gpa.free(private_url);
    var shared = try support.initEngineFetchTask(gpa, 45, shared_url, 45);
    defer shared.deinit();
    var private = try support.initEngineFetchTask(gpa, 46, private_url, 46);
    defer private.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{listener.port});
    const config = egress_client.Config{
        .network = origins.policy(),
        .socket_timeout_ms = 10_000,
    };
    const descriptors_before = try support.openDescriptorCount();

    try engine.submit(.{ .task = &shared, .config = config });
    try engine.submit(.{ .task = &private, .config = config });
    try support.waitDescriptorCount(descriptors_before + 2, 2_000);

    engine.stop();
    for ([_]*task_model.Task{ &shared, &private }) |task| {
        try support.expectTaskFailureMessage(task, "EgressEngineStopped");
        try std.testing.expectEqual(@as(usize, 1), wake.taskReadyCount(task));
    }
    // The owner closed both attempts' sockets before the stop returned.
    try std.testing.expectEqual(descriptors_before, try support.openDescriptorCount());
}

// A canceled dial must leave nothing behind for its origin: the next fetch
// to the same origin starts a dial of its own.
test "egress engine canceled dial leaves the origin usable" {
    const origin = try support.HeldOrigin.start(gpa, 2);
    defer origin.stop(gpa);
    const url = try origin.httpsUrl(gpa);
    defer gpa.free(url);
    var first = try support.initEngineFetchTask(gpa, 50, url, 50);
    defer first.deinit();
    var second = try support.initEngineFetchTask(gpa, 51, url, 51);
    defer second.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = origin.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 300,
    };

    try engine.submit(.{ .task = &first, .config = config });
    try origin.waitClientHello(0, 2_000);
    engine.cancel(&first);
    try support.waitTaskDone(&first, 2_000);

    try engine.submit(.{ .task = &second, .config = config });
    try origin.waitClientHello(1, 2_000);
    try support.waitTaskDone(&second, 3_000);
    try support.expectTaskFailureMessage(&second, "TlsHandshakeTimeout");
    engine.stop();
    try support.expectSettledOnceCanceled(&wake, &first);
}

// The relay hands the slow origin's flight to the engine a byte per write
// and keeps its last byte back, so the owner steps that handshake on every
// byte it receives and cannot finish it. A fetch to another origin,
// handshake and stream, completes meanwhile; then the gate opens, and the
// held handshake finishes and serves its own stream. An owner that ran a
// handshake through to its end once bytes arrived would hold the second
// fetch until the gate opened.
test "egress engine serves another origin's stream between the steps of a handshake in progress" {
    var slow_origin: ?*tls_shim.TestH2Origin = null;
    var slow_port: u16 = 0;
    if (tls_shim.collo_test_h2_origin_start(tls_shim.test_h2_origin_alpn_h2, &slow_origin, &slow_port) != 0)
        return error.StartLocalH2OriginFailed;
    defer tls_shim.collo_test_h2_origin_stop(slow_origin.?);
    var fast_origin: ?*tls_shim.TestH2Origin = null;
    var fast_port: u16 = 0;
    if (tls_shim.collo_test_h2_origin_start(tls_shim.test_h2_origin_alpn_h2, &fast_origin, &fast_port) != 0)
        return error.StartLocalH2OriginFailed;
    defer tls_shim.collo_test_h2_origin_stop(fast_origin.?);
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const proxy = try support.TrickleProxy.start(gpa, host, slow_port);
    defer proxy.stop(gpa);

    const slow_url = try std.fmt.allocPrint(gpa, "https://{s}:{d}/one", .{ host, proxy.port });
    defer gpa.free(slow_url);
    const fast_url = try std.fmt.allocPrint(gpa, "https://{s}:{d}/one", .{ host, fast_port });
    defer gpa.free(fast_url);
    var slow = try support.initEngineFetchTask(gpa, 60, slow_url, 60);
    defer slow.deinit();
    var fast = try support.initEngineFetchTask(gpa, 61, fast_url, 61);
    defer fast.deinit();

    var engine = try egress_engine.Engine.init(gpa, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &fast);
    defer _ = support.releaseTaskBodyCredits(&engine, &slow);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{ proxy.port, fast_port });
    const config = egress_client.Config{
        .network = origins.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &slow, .config = config });
    // Part of the server's flight has reached the engine, a byte at a time.
    try proxy.waitRelayed(64, 5_000);
    try engine.submit(.{ .task = &fast, .config = config });
    try support.waitTaskDone(&fast, 5_000);
    try support.expectTaskStatus(&fast, 200);
    var body_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("one", try support.readBody(&engine, fast.response_body, &body_buffer, 5_000));
    try std.testing.expect(!support.taskDone(&slow));

    proxy.openGate();
    try support.waitTaskDone(&slow, 5_000);
    try support.expectTaskStatus(&slow, 200);
    try std.testing.expectEqualStrings("one", try support.readBody(&engine, slow.response_body, &body_buffer, 5_000));
}
