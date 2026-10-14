//! Covers fetch from a handler in the worker runtime, through the in-process
//! gateway of the harness (`LocalEgressGateway`) to a local origin, or
//! through a session whose gateway end the test plays (`RawSession`): URLs
//! refused before or by the gateway; the request's egress token a FetchStart
//! carries byte for byte; the TypeError, before anything leaves the worker,
//! of a fetch whose request carries no token, whose worker has no network
//! grant or no egress session, even on a signal already at its listener
//! limit, and of a request's fetch past `fetches_per_request_max` started,
//! finished ones included; a fetch counted from its start to its terminal
//! packet, so a worker at `fetches_per_worker_max` with open bodies refuses
//! one more itself; one stop per fetch, after its last view let go; the
//! body bytes a request's fetches sent and received in its record, a pooled
//! upload's as its batches leave and an encoded or redirected body's as it
//! arrived; the network setting's denial, by the gateway or for want of a
//! grant, written once to the tenant's log; a pooled start that waits for
//! room in the session's upload bytes in flight, the copies of its start
//! included; a reader cancelled while its body's ready item waits, which
//! gives the request's ready count back; the active fetch failed with a
//! TypeError when the gateway is lost while the worker keeps serving; a
//! body-pool release the pool refuses, or a gateway completion whose ids
//! disagree, either of which detaches the worker, which keeps serving and
//! asks to be retired; a
//! worker booted without a session that an `egress_attach` on its control
//! socket attaches, and an attach on another wake set it refuses, before it
//! lets go of a session it holds; the response's status, bytes, headers and
//! streaming body, `clone` and body tees under their one clone budget, a
//! fetch response returned as the handler's
//! response, a saved one refused in a later request, and live clones
//! released at teardown. Runs in `worker-test`; the gateway's admission and
//! policy are covered by its own tests, a forked worker attached again after
//! it lost its gateway by the zygote integration lane, and fetch's Web API
//! surface by the `webapi` lane.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const worker_shared_page = @import("collo_worker_state").page;
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const local_address = @import("collo_test_net");
const retirement_notice = @import("retirement_notice.zig");

const fakeNow = rt.fakeNow;
const RequestParts = rt.RequestParts;
const DispatchParts = rt.DispatchParts;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
const runRouteAndExpectBody = rt.runRouteAndExpectBody;
const runRouteAndReadBody = rt.runRouteAndReadBody;
const runRouteAndReadBodyWithRequest = rt.runRouteAndReadBodyWithRequest;
const runRouteAndReadBodyWithRequestCaptures = rt.runRouteAndReadBodyWithRequestCaptures;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;
const LocalOrigin = rt.LocalOrigin;

test "fetch rejects unsupported and blocked protocols" {
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{});
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const invalid_protocol =
        \\export default async function handle() {
        \\    try {
        \\        await fetch("file:///tmp/nope");
        \\    } catch (err) {
        \\        return Response.json({ rejected: String(err).includes("Failed to schedule fetch") });
        \\    }
        \\    return "unexpected";
        \\}
    ;
    const http_blocked =
        \\export default async function handle() {
        \\    try {
        \\        await fetch("http://127.0.0.1:1/nope");
        \\    } catch (err) {
        \\        return Response.json({ rejected: true });
        \\    }
        \\    return "unexpected";
        \\}
    ;
    const invalid_utf8 =
        \\export default async function handle() {
        \\    try {
        \\        await fetch("\uD800");
        \\    } catch (err) {
        \\        return Response.json({ rejected: true });
        \\    }
        \\    return "unexpected";
        \\}
    ;
    const invalid_url_before_body =
        \\export default async function handle() {
        \\    try {
        \\        await fetch("invalid url", { body: new Uint8Array([1]) });
        \\    } catch (err) {
        \\        return Response.json({ invalidUrlFirst: String(err).includes("invalid URL") });
        \\    }
        \\    return "unexpected";
        \\}
    ;
    try rt.bootRoutes(&runtime, &.{
        .{ .specifier = "/fetch-invalid-protocol.js", .source = invalid_protocol },
        .{ .specifier = "/fetch-http-blocked.js", .source = http_blocked },
        .{ .specifier = "/fetch-invalid-utf8.js", .source = invalid_utf8 },
        .{ .specifier = "/fetch-invalid-url-before-body.js", .source = invalid_url_before_body },
    });

    try runRouteAndExpectBody(&runtime, control_pair[1], invalid_protocol, 14, "/fetch-invalid-protocol.js", "\"rejected\":true");
    try runRouteAndExpectBody(&runtime, control_pair[1], http_blocked, 15, "/fetch-http-blocked.js", "\"rejected\":true");
    try runRouteAndExpectBody(&runtime, control_pair[1], invalid_utf8, 16, "/fetch-invalid-utf8.js", "\"rejected\":true");
    try runRouteAndExpectBody(&runtime, control_pair[1], invalid_url_before_body, 25, "/fetch-invalid-url-before-body.js", "\"invalidUrlFirst\":true");
}

test "handler can await fetch from local origin" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/data", {{
        \\        method: "POST",
        \\        headers: {{ "x-collo-test": "yes", cookie: "secret=1" }},
        \\        body: new Uint8Array([112, 97, 121, 108, 111, 97, 100])
        \\    }});
        \\    const text = await res.text();
        \\    return Response.json({{ status: res.status, ok: res.ok, text }});
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const response = try runRouteAndReadBody(&runtime, control_pair[1], source, 12, "/fetch-route.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"status\":200"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"ok\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"text\":\"post ok\""));

    try std.testing.expectEqual(@as(usize, 1), origin.accepted.load(.acquire));
}

test "a request's egress token reaches the gateway byte for byte in its fetch's start" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = try rt.routeSpecifier(std.testing.allocator, "/fetch-identity.js");
    defer std.testing.allocator.free(specifier);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/binary");
        \\    return Response.json({{ status: res.status }});
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const route_index = try rt.registerRoute(&runtime, specifier, source);

    // The server's lane mints the token under the request id and the
    // generation of the request slot the request took. A reused slot is past
    // generation 1 even on a worker's first request.
    const request_id: u64 = 31;
    const request_generation: u64 = 7;
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .request_generation = request_generation,
        .route_index = route_index,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, request_id);
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], request_id);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\"status\":200"));

    // The start names the request only through the token, which the worker
    // copied without reading it.
    var starts: [2]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 1), gateway.recordedFetchStarts(&starts));
    try std.testing.expectEqualSlices(u8, &dispatch.egress_token, &starts[0].egress_token);
    const presented = try rt.verifyEgressToken(&starts[0].egress_token);
    try std.testing.expectEqual(ipc.egress_token.Kind.request, presented.kind);
    try std.testing.expectEqual(rt.local_egress_session_id, presented.session_id);
    try std.testing.expectEqual(request_id, presented.request_id);
    try std.testing.expectEqual(request_generation, presented.request_generation);
}

test "a fetch of a request dispatched without an egress token rejects with a TypeError before it leaves the worker" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = try rt.routeSpecifier(std.testing.allocator, "/fetch-without-token.js");
    defer std.testing.allocator.free(specifier);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    try {{
        \\        await fetch("http://{s}:{d}/binary");
        \\        return Response.json({{ fetched: true }});
        \\    }} catch (err) {{
        \\        return Response.json({{ typeError: err instanceof TypeError, message: err.message }});
        \\    }}
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const route_index = try rt.registerRoute(&runtime, specifier, source);

    // The worker is attached, but the server dispatched the request with no
    // token, so the worker refuses the fetch itself rather than present bytes
    // the gateway would count against its session.
    const request_id: u64 = 32;
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .egress_token = ipc.egress_token.none,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, request_id);
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], request_id);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        body,
        1,
        "\"typeError\":true,\"message\":\"fetch failed: the request has no egress token\"",
    ));

    var starts: [1]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 0), gateway.recordedFetchStarts(&starts));
    try std.testing.expectEqual(@as(usize, 0), origin.accepted.load(.acquire));
}

/// The text a worker without a network grant rejects a fetch of
/// `https://example.test/` with, as the gateway writes a denial
/// (`collo_network.writeDenial` with `no_grant`).
const no_grant_denial = "fetch to https://example.test denied by the network setting: no network setting grants access to this route";

// A worker without a grant used to refuse as a worker whose gateway is
// gone, "fetch failed: no egress gateway", which named no setting to change
// and left nothing in the tenant's log.
test "a fetch in a worker without a network grant rejects at once with the network setting's denial, written once to the tenant's log" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    // No egress descriptors, as for a worker whose definition has no network
    // grant (WorkerInit without `flag_egress`).
    var no_egress: ipc.egress_shared.RawFds = .{};
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &no_egress,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    try {
        \\        await fetch("https://example.test/");
        \\        return Response.json({ fetched: true });
        \\    } catch (err) {
        \\        return Response.json({ typeError: err instanceof TypeError, message: err.message });
        \\    }
        \\}
    , 33, "/fetch-no-grant.js", "\"typeError\":true,\"message\":\"" ++ no_grant_denial ++ "\"");
    try expectOneDenialLine(&completion_fixture.reader, 33, no_grant_denial);
}

/// Fails unless the tenant's log holds exactly one line since the last
/// drain: a `warn` under `request_id` whose text is `text`.
fn expectOneDenialLine(reader: *worker_shared_page.HostReaderView, request_id: u64, text: []const u8) !void {
    var scratch: [4 * worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var lines: [4]worker_shared_page.DrainedLogLine = undefined;
    const count = try reader.drainLogLinesChecked(&scratch, &lines);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@intFromEnum(worker_shared_page.LogLevel.warn), lines[0].header.level);
    try std.testing.expectEqual(@as(u8, 0), lines[0].header.flags);
    try std.testing.expectEqual(request_id, lines[0].header.request_id);
    try std.testing.expectEqualStrings(text, lines[0].payload);
}

test "a request's fetch past fetches_per_request_max is refused in the worker, finished fetches included, and never reaches the gateway" {
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{});
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // Each fetch fails at the gateway, which refuses plain HTTP, before the
    // next one starts, so no two are ever in flight together; the gateway
    // spends the token's budget on each all the same.
    const limit: usize = limits.worker.fetches_per_request_max;
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const outcomes = [];
        \\    for (let i = 0; i <= {d}; i += 1) {{
        \\        try {{
        \\            await fetch("http://127.0.0.1:1/nope");
        \\            outcomes.push("fetched");
        \\        }} catch (err) {{
        \\            outcomes.push(String(err).includes("Failed to schedule fetch") ? "refused" : "failed");
        \\        }}
        \\    }}
        \\    return Response.json({{ outcomes: outcomes.join(",") }});
        \\}}
    , .{limit});
    defer std.testing.allocator.free(source);
    const body = try runRouteAndReadBody(&runtime, control_pair[1], source, 34, "/fetch-request-limit.js");
    defer std.testing.allocator.free(body);

    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    try expected.appendSlice(std.testing.allocator, "\"outcomes\":\"");
    for (0..limit) |_|
        try expected.appendSlice(std.testing.allocator, "failed,");
    try expected.appendSlice(std.testing.allocator, "refused\"");
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, expected.items));

    var starts: [limit + 1]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(limit, gateway.recordedFetchStarts(&starts));
}

test "a refused fetch on a signal at its listener limit rejects with the refusal's TypeError" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The signal holds as many listeners as an event target takes. The
    // refused fetch is already rejected and gets no abort listener, so the
    // limit never comes into play.
    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    const signal = new AbortController().signal;
        \\    for (let index = 0; index < (1 << 14); index += 1)
        \\        signal.addEventListener("abort", () => {});
        \\    try {
        \\        await fetch("https://example.test/", { signal });
        \\        return Response.json({ fetched: true });
        \\    } catch (err) {
        \\        return Response.json({ typeError: err instanceof TypeError, message: err.message });
        \\    }
        \\}
    , 41, "/fetch-refused-signal-limit.js", "\"typeError\":true,\"message\":\"" ++ no_grant_denial ++ "\"");
}

test "losing the gateway fails the active fetch with a TypeError and the worker serves the next request, whose fetch rejects at once (#47)" {
    // A listener that completes handshakes from its backlog but never
    // accepts: the first fetch connects, sends and stays in flight.
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    var bind_address = try std.net.Address.parseIp4("0.0.0.0", 0);
    var silent_server = try bind_address.listen(.{ .reuse_address = true });
    defer silent_server.deinit();

    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .policy = .{ .socket_timeout_ms = 2_000 },
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = try rt.routeSpecifier(std.testing.allocator, "/fetch-gateway-lost.js");
    defer std.testing.allocator.free(specifier);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    try {{
        \\        await fetch("http://{s}:{d}/hang");
        \\        return Response.json({{ fetched: true }});
        \\    }} catch (err) {{
        \\        return Response.json({{ typeError: err instanceof TypeError, message: err.message }});
        \\    }}
        \\}}
    , .{ host, silent_server.listen_address.getPort() });
    defer std.testing.allocator.free(source);
    const route_index = try rt.registerRoute(&runtime, specifier, source);

    const first_id: u64 = 34;
    var first = try initDispatchWork(std.testing.allocator, .{
        .request_id = first_id,
        .route_index = route_index,
    });
    defer first.deinit();
    try rt.enqueueIngressRoute(&runtime, &first, 1, .{});
    try executeNextReady(&runtime);
    var starts: [2]rt.FetchStartIdentity = undefined;
    try pumpUntilFetchStarts(&runtime, gateway, 1);

    // The worker learns its gateway is gone as the loop's `egress_closed`
    // arm does. It fails the fetch in flight, releases the session's regions
    // and keeps running.
    runtime.disconnectEgressGatewayWithReason("liveness_hup");
    try std.testing.expect(runtime.core.running);
    try executeUntilRequestDone(&runtime, first_id);
    const first_body = try rt.readIngressResponseBody(&runtime, control_pair[1], first_id);
    defer std.testing.allocator.free(first_body);
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        first_body,
        1,
        "\"typeError\":true,\"message\":\"fetch failed: egress gateway closed\"",
    ));

    // The next request is served, and its fetch, made while detached, rejects
    // at once without reaching any gateway.
    const second_id: u64 = 35;
    var second = try initDispatchWork(std.testing.allocator, .{
        .request_id = second_id,
        .route_index = route_index,
    });
    defer second.deinit();
    try rt.enqueueIngressRoute(&runtime, &second, 1, .{});
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, second_id);
    const second_body = try rt.readIngressResponseBody(&runtime, control_pair[1], second_id);
    defer std.testing.allocator.free(second_body);
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        second_body,
        1,
        "\"typeError\":true,\"message\":\"fetch failed: no egress gateway\"",
    ));
    try std.testing.expect(runtime.core.running);
    try std.testing.expectEqual(@as(usize, 1), gateway.recordedFetchStarts(&starts));
    try std.testing.expectEqualSlices(u8, &first.egress_token, &starts[0].egress_token);
}

test "a worker booted without a session holds its wake descriptors until egress_attach maps a session on them, then fetches through that gateway" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    // The worker's wake set, which the server keeps for the worker's life and
    // builds every session of the worker on, and a gateway with a session on
    // it that the worker does not get at boot.
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
        .network = rt.local_origin_network,
    }, &wake_set);
    defer gateway.deinit();
    var boot_fds = ipc.egress_shared.RawFds.wakeOnly(try wake_set.openWorkerWake());
    defer boot_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &boot_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const egress_state = &runtime.egress.state;
    try std.testing.expect(egress_state.shared == null);
    const boot_wake = egress_state.detached_wake orelse return error.TestExpectedWakeDescriptors;

    // The server attaches the worker to that session on its control socket.
    var worker_half = gateway.takeWorkerSharedFds();
    defer worker_half.close();
    try ipc.egress_attach.send(control_pair[1], worker_half);
    try worker.testing.scheduler.loop.collectControlPacket(&runtime);
    try std.testing.expect(egress_state.shared != null);
    try std.testing.expect(egress_state.detached_wake == null);
    // The boot's descriptors closed, and the endpoint's, which the loop
    // polls from now on, are ends of the same pipes.
    const boot_descriptors = [_]std.posix.fd_t{
        boot_wake.command_eventfd,
        boot_wake.completion_eventfd,
        boot_wake.liveness_fd,
        boot_wake.peer_liveness_fd,
    };
    for (boot_descriptors) |fd|
        try expectClosedDescriptor(fd);
    try expectSamePipe(wake_set.liveness_read.fd(), egress_state.shared.?.liveness_fd);

    const route_source = try fetchRouteSource(origin.host(), origin.port, "/binary");
    defer std.testing.allocator.free(route_source);
    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-after-attach.js", route_source);
    const request_id: u64 = 38;
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, request_id);
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], request_id);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\"status\":200"));
    var starts: [2]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 1), gateway.recordedFetchStarts(&starts));
    try std.testing.expectEqualSlices(u8, &dispatch.egress_token, &starts[0].egress_token);
}

test "an egress_attach to an attached worker fails its fetch in flight with a TypeError and moves the worker to the new gateway" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    // A listener that completes handshakes from its backlog but never
    // accepts: the first fetch connects, sends and stays in flight.
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    var bind_address = try std.net.Address.parseIp4("0.0.0.0", 0);
    var silent_server = try bind_address.listen(.{ .reuse_address = true });
    defer silent_server.deinit();

    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var first_gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
        .policy = .{ .socket_timeout_ms = 2_000 },
        .network = rt.local_origin_network,
    }, &wake_set);
    var first_gateway_running = true;
    defer if (first_gateway_running) first_gateway.deinit();
    var boot_fds = first_gateway.takeWorkerSharedFds();
    defer boot_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &boot_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const hang_source = try fetchRouteSource(host, silent_server.listen_address.getPort(), "/hang");
    defer std.testing.allocator.free(hang_source);
    const origin_source = try fetchRouteSource(origin.host(), origin.port, "/binary");
    defer std.testing.allocator.free(origin_source);
    try rt.bootRoutes(&runtime, &.{
        .{ .specifier = "/fetch-hang-across-attach.js", .source = hang_source },
        .{ .specifier = "/fetch-after-attach.js", .source = origin_source },
    });
    const hang_route: u16 = 0;
    const origin_route: u16 = 1;

    const first_id: u64 = 39;
    var first = try initDispatchWork(std.testing.allocator, .{
        .request_id = first_id,
        .route_index = hang_route,
    });
    defer first.deinit();
    try rt.enqueueIngressRoute(&runtime, &first, 1, .{});
    try executeNextReady(&runtime);
    try pumpUntilFetchStarts(&runtime, first_gateway, 1);
    var starts: [2]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 1), first_gateway.recordedFetchStarts(&starts));
    try std.testing.expectEqualSlices(u8, &first.egress_token, &starts[0].egress_token);

    // The first gateway is gone, as a lost one is by the time the server
    // reattaches its workers, and the worker has not noticed yet. Two live
    // gateways of one worker would both wake on its one command eventfd, so
    // the second starts only now.
    first_gateway.deinit();
    first_gateway_running = false;
    var second_gateway = try rt.LocalEgressGateway.startOnWakeSet(std.testing.allocator, .{
        .network = rt.local_origin_network,
    }, &wake_set);
    defer second_gateway.deinit();

    // The server attaches the worker to the second gateway while its fetch
    // through the first is in flight: the worker detaches first, which
    // fails that fetch, then maps the new session.
    var second_half = second_gateway.takeWorkerSharedFds();
    defer second_half.close();
    try ipc.egress_attach.send(control_pair[1], second_half);
    try worker.testing.scheduler.loop.collectControlPacket(&runtime);
    try std.testing.expect(runtime.egress.state.shared != null);
    try std.testing.expect(runtime.core.running);
    try executeUntilRequestDone(&runtime, first_id);
    const first_body = try rt.readIngressResponseBody(&runtime, control_pair[1], first_id);
    defer std.testing.allocator.free(first_body);
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        first_body,
        1,
        "\"typeError\":true,\"message\":\"fetch failed: egress gateway closed\"",
    ));

    const second_id: u64 = 40;
    var second = try initDispatchWork(std.testing.allocator, .{
        .request_id = second_id,
        .route_index = origin_route,
    });
    defer second.deinit();
    try rt.enqueueIngressRoute(&runtime, &second, 1, .{});
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, second_id);
    const second_body = try rt.readIngressResponseBody(&runtime, control_pair[1], second_id);
    defer std.testing.allocator.free(second_body);
    try std.testing.expect(std.mem.containsAtLeast(u8, second_body, 1, "\"status\":200"));
    try std.testing.expectEqual(@as(usize, 1), second_gateway.recordedFetchStarts(&starts));
    try std.testing.expectEqualSlices(u8, &second.egress_token, &starts[0].egress_token);
}

// The server builds every session of a worker on the worker's one wake set.
// A session on another set, such as one sent to the wrong worker's socket,
// would let this worker read another worker's responses; it used to be
// mapped all the same.
test "an egress_attach whose session is on another wake set is refused and the worker keeps its boot descriptors" {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var boot_fds = ipc.egress_shared.RawFds.wakeOnly(try wake_set.openWorkerWake());
    defer boot_fds.close();
    // A session built on another wake set than the one WorkerInit's wake
    // descriptors came from.
    var other_wake_set = try ipc.egress_shared.WakeSet.create();
    defer other_wake_set.deinit();
    var other_session = try ipc.egress_shared.createSessionForWorker(&other_wake_set);
    defer other_session.deinit();
    var other_half = other_session.takeWorkerHalf();
    defer other_half.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &boot_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const boot_wake = runtime.egress.state.detached_wake orelse return error.TestExpectedWakeDescriptors;
    try ipc.egress_attach.send(control_pair[1], other_half);
    try std.testing.expectError(
        error.EgressAttachLivenessPipeMismatch,
        worker.testing.scheduler.loop.collectControlPacket(&runtime),
    );
    try std.testing.expect(runtime.egress.state.shared == null);
    const still_held = runtime.egress.state.detached_wake orelse return error.TestExpectedWakeDescriptors;
    try std.testing.expectEqual(boot_wake.liveness_fd, still_held.liveness_fd);
    try expectSamePipe(wake_set.liveness_read.fd(), still_held.liveness_fd);
}

/// The source of a route whose handler fetches `target_path` from
/// `host:port` and answers the fetch's status, or the TypeError it rejected
/// with and its message. The caller frees it.
fn fetchRouteSource(host: []const u8, port: u16, target_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    try {{
        \\        const res = await fetch("http://{s}:{d}{s}");
        \\        return Response.json({{ status: res.status }});
        \\    }} catch (err) {{
        \\        return Response.json({{ typeError: err instanceof TypeError, message: err.message }});
        \\    }}
        \\}}
    , .{ host, port, target_path });
}

/// Checks that `fd` names no open descriptor of this process.
fn expectClosedDescriptor(fd: std.posix.fd_t) !void {
    const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    try std.testing.expectEqual(std.os.linux.E.BADF, std.os.linux.E.init(rc));
}

/// Checks that `first` and `second` are descriptors of one pipe, by device
/// and inode.
fn expectSamePipe(first: std.posix.fd_t, second: std.posix.fd_t) !void {
    const first_stat = try std.posix.fstat(first);
    const second_stat = try std.posix.fstat(second);
    try std.testing.expectEqual(first_stat.dev, second_stat.dev);
    try std.testing.expectEqual(first_stat.ino, second_stat.ino);
}

test "a malformed completion packet detaches the worker, which keeps serving, refuses the next fetch and asks to be retired" {
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // A packet whose kind names no message, as a gateway breaking the
    // protocol would write. The worker drops the session instead of ending,
    // and the collector reports no further packet.
    var bogus: [8]u8 = @splat(0);
    std.mem.writeInt(u32, bogus[0..4], 0xdead_beef, .little);
    try gateway.queueCompletionPacket(&bogus);
    try std.testing.expect(!try runtime.collectEgressGatewayPacketsBounded(64));
    try std.testing.expect(runtime.core.running);

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    try {
        \\        await fetch("https://example.test/");
        \\        return Response.json({ fetched: true });
        \\    } catch (err) {
        \\        return Response.json({ typeError: err instanceof TypeError, message: err.message });
        \\    }
        \\}
    , 36, "/fetch-after-malformed-packet.js", "\"typeError\":true,\"message\":\"fetch failed: no egress gateway\"");
    var starts: [1]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 0), gateway.recordedFetchStarts(&starts));

    // No gateway gives the worker a session again, so the loop's next tick
    // asks the server to retire it.
    try runtime.checkRetirement();
    try std.testing.expectEqual(ipc.WorkerRetiringReason.egress_detached, try retirement_notice.read(control_pair[1]));
}

test "a body-pool release the shared pool refuses detaches the worker between handlers, and its loop keeps running" {
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{});
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // A release longer than the whole pool is one the pool refuses, as it
    // refuses every release once the gateway has corrupted its shared queue.
    // The release path only marks the session, so the body or detach that
    // released the extent is never torn down under its own feet.
    worker.testing.egress_gateway_control.bodyPoolRelease(&runtime, 1, std.math.maxInt(u32)).release();
    try std.testing.expect(runtime.egress.state.body_pool_release_failed);
    try std.testing.expect(runtime.egress.state.shared != null);
    try std.testing.expect(runtime.core.running);

    // The loop's check between handlers detaches the worker, which keeps
    // running and refuses the next fetch at once.
    runtime.detachEgressAfterFailedRelease();
    try std.testing.expect(runtime.egress.state.shared == null);
    try std.testing.expect(!runtime.egress.state.body_pool_release_failed);
    try std.testing.expect(runtime.core.running);
    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    try {
        \\        await fetch("https://example.test/");
        \\        return Response.json({ fetched: true });
        \\    } catch (err) {
        \\        return Response.json({ typeError: err instanceof TypeError, message: err.message });
        \\    }
        \\}
    , 37, "/fetch-after-failed-release.js", "\"typeError\":true,\"message\":\"fetch failed: no egress gateway\"");
    try runtime.checkRetirement();
    try std.testing.expectEqual(ipc.WorkerRetiringReason.egress_detached, try retirement_notice.read(control_pair[1]));
}

test "a whole body the handler has not read yet rejects once the worker detaches instead of resolving short" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The handler holds the response across a timer on the fake clock, which
    // stands still until the test moves it, so the whole body reaches the
    // worker before the handler reads any of it.
    const specifier = try rt.routeSpecifier(std.testing.allocator, "/fetch-body-detached.js");
    defer std.testing.allocator.free(specifier);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/binary");
        \\    await new Promise((resolve) => setTimeout(resolve, 1));
        \\    try {{
        \\        const text = await res.text();
        \\        return Response.json({{ resolvedLength: text.length }});
        \\    }} catch (err) {{
        \\        return Response.json({{ rejected: true }});
        \\    }}
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const route_index = try rt.registerRoute(&runtime, specifier, source);

    const request_id: u64 = 37;
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        // Past the instant the clock moves to below, so only the timer fires.
        .deadline_monotonic_ns = 60 * std.time.ns_per_s,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);

    // The worker counts the fetch until it reads the body's end, so once the
    // count is back to zero the whole body arrived, and the handler waits on
    // its timer with all of it unread.
    var attempts: usize = 0;
    while (runtime.egress.state.fetches.count() != 0) : (attempts += 1) {
        if (attempts > 2000)
            return error.BodyNeverEnded;
        try pumpOnce(&runtime);
        std.Thread.sleep(std.time.ns_per_ms);
    }

    runtime.disconnectEgressGatewayWithReason("liveness_hup");
    now_mono_ns = 2 * std.time.ns_per_ms;
    try executeUntilRequestDone(&runtime, request_id);
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], request_id);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\"rejected\":true"));
}

/// Runs the runtime's collectors and ready queue until `gateway` has recorded
/// `count` fetch starts. Fails after a fixed number of passes, each of which
/// sleeps a millisecond.
fn pumpUntilFetchStarts(runtime: *worker.Runtime, gateway: *rt.LocalEgressGateway, count: usize) !void {
    var starts: [8]rt.FetchStartIdentity = undefined;
    std.debug.assert(count <= starts.len);
    var attempts: usize = 0;
    while (gateway.recordedFetchStarts(&starts) < count) : (attempts += 1) {
        if (attempts > 2000)
            return error.FetchNeverStarted;
        try pumpOnce(runtime);
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

/// One scheduler pass for a request that waits on its fetch: collects gateway
/// packets, which queue fetch completions and bodies themselves, timers and
/// immediates, then drains the ready queue.
fn pumpOnce(runtime: *worker.Runtime) !void {
    _ = try runtime.collectEgressGatewayPacketsBounded(64);
    try runtime.collectDueTimers();
    try runtime.collectReadyImmediates();
    while (!runtime.scheduler.ready_queue.isEmpty())
        try executeNextReady(runtime);
}

test "fetch response preserves binary body and origin metadata" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/binary");
        \\    return Response.json({{
        \\        bytes: Array.from(await res.bytes()),
        \\        origin: res.headers.get("x-collo-origin"),
        \\        statusText: res.statusText,
        \\        type: res.type
        \\    }});
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const response = try runRouteAndReadBody(&runtime, control_pair[1], source, 13, "/fetch-binary-route.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"bytes\":[0,255,65]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"origin\":\"local\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"statusText\":\"OK\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"type\":\"basic\""));
}

test "fetch response headers are immutable and expose server cookies" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/binary");
        \\    let setThrew = false;
        \\    let appendThrew = false;
        \\    let deleteThrew = false;
        \\    try {{ res.headers.set("x-collo-origin", "mutated"); }} catch (err) {{ setThrew = err instanceof TypeError; }}
        \\    try {{ res.headers.append("x-extra", "1"); }} catch (err) {{ appendThrew = err instanceof TypeError; }}
        \\    try {{ res.headers.delete("x-collo-origin"); }} catch (err) {{ deleteThrew = err instanceof TypeError; }}
        \\    return Response.json({{
        \\        origin: res.headers.get("x-collo-origin"),
        \\        cookieGet: res.headers.get("set-cookie"),
        \\        cookieHas: res.headers.has("set-cookie"),
        \\        exposedNames: Array.from(res.headers.keys()).join("|"),
        \\        cookies: res.headers.getSetCookie().join("|"),
        \\        setThrew,
        \\        appendThrew,
        \\        deleteThrew
        \\    }});
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);

    const response = try runRouteAndReadBody(&runtime, control_pair[1], source, 18, "/fetch-headers-guard.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"origin\":\"local\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"cookieGet\":null"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"cookieHas\":false"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, response, 1, "set-cookie"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"cookies\":\"session=abc|theme=dark\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"setThrew\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"appendThrew\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"deleteThrew\":true"));
}

test "fetch response body reader streams bytes" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/binary");
        \\    const reader = res.body.getReader();
        \\    const first = await reader.read();
        \\    const second = await reader.read();
        \\    return Response.json({{
        \\        firstDone: first.done,
        \\        firstBytes: Array.from(first.value),
        \\        secondDone: second.done,
        \\        secondValue: String(second.value),
        \\        bodyUsed: res.bodyUsed
        \\    }});
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const response = try runRouteAndReadBody(&runtime, control_pair[1], source, 17, "/fetch-stream-route.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"firstDone\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"firstBytes\":[0,255,65]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"secondDone\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"secondValue\":\"undefined\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"bodyUsed\":true"));
}

test "returned fetch response streams through server response and strips upstream framing" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    return await fetch("http://{s}:{d}/binary");
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);

    var response = try rt.runRouteAndReadIngressResponseWithRequest(&runtime, control_pair[1], source, 20, "/fetch-return-stream.js", .{});
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.headers_wire, 1, "x-collo-origin: local"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, response.headers_wire, 1, "transfer-encoding:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, response.headers_wire, 1, "content-length:"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, response.headers_wire, 1, "connection:"));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 65 }, response.body);
}

test "returned fetch response from previous request is rejected" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const save_source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    globalThis.__saved_fetch_response = await fetch("http://{s}:{d}/binary");
        \\    return new Response("saved");
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(save_source);
    const reuse_source =
        \\export default function handle() {
        \\    return globalThis.__saved_fetch_response;
        \\}
    ;
    try rt.bootRoutes(&runtime, &.{
        .{ .specifier = "/save-fetch-response.js", .source = save_source },
        .{ .specifier = "/reuse-fetch-response.js", .source = reuse_source },
    });

    const saved = try runRouteAndReadBody(&runtime, control_pair[1], save_source, 21, "/save-fetch-response.js");
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.containsAtLeast(u8, saved, 1, "saved"));

    var rejected = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1], reuse_source, 22, "/reuse-fetch-response.js");
    defer rejected.deinit();
    try std.testing.expectEqual(@as(u16, 500), rejected.status);
}

test "fetch response clone tees streaming body" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/binary");
        \\    const cloned = res.clone();
        \\    const both = await Promise.all([res.bytes(), cloned.bytes()]);
        \\    return Response.json({{
        \\        original: Array.from(both[0]),
        \\        cloned: Array.from(both[1]),
        \\        originalUsed: res.bodyUsed,
        \\        clonedUsed: cloned.bodyUsed
        \\    }});
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const response = try runRouteAndReadBody(&runtime, control_pair[1], source, 18, "/fetch-clone-route.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"original\":[0,255,65]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"cloned\":[0,255,65]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"originalUsed\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"clonedUsed\":true"));
}

test "clones and body tees of one fetch response count against one clone budget, so the 17th of either throws" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // WebApiBodyCloneFanoutMax (limits.h) is 16: one spare clone, seven clones each teed once,
    // and one more clone fill the tree, so the next clone of the response and the first tee of
    // the spare's body both throw, and the response's body still reads whole.
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/binary");
        \\    const outcome = (make) => {{
        \\        try {{
        \\            make();
        \\            return "made";
        \\        }} catch (error) {{
        \\            return error.name;
        \\        }}
        \\    }};
        \\    const spare = res.clone();
        \\    for (let index = 0; index < 7; index++) res.clone().body.tee();
        \\    res.clone();
        \\    const clone = outcome(() => res.clone());
        \\    const tee = outcome(() => spare.body.tee());
        \\    const bytes = Array.from(await res.bytes());
        \\    return Response.json({{ clone, tee, bytes }});
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const response = try runRouteAndReadBody(&runtime, control_pair[1], source, 19, "/fetch-clone-budget-route.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"clone\":\"QuotaExceededError\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"tee\":\"QuotaExceededError\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"bytes\":[0,255,65]"));
}

test "runtime deinit releases live cloned fetch bodies" {
    var origin = try LocalOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("http://{s}:{d}/binary");
        \\    globalThis.__collo_live_fetch_bodies = [res, res.clone()];
        \\    return "kept";
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const response = try runRouteAndReadBody(&runtime, control_pair[1], source, 19, "/fetch-clone-live-route.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "kept"));
    // Both bodies are still reachable from a global when the runtime tears
    // down; the testing allocator's leak check is the assertion.
}

const RawSession = rt.RawSession;

/// A runtime on a fake clock attached to `session`.
fn initSessionRuntime(
    vm: *support.bindings.Vm,
    control_fd: std.posix.fd_t,
    completion_fixture: *rt.CompletionFixture,
    now_mono_ns: *u64,
    session: *RawSession,
) !worker.Runtime {
    // The caller attaches the host runtime once the value has its final
    // address: the VM keeps a pointer to it.
    return worker.Runtime.init(std.testing.allocator, vm, control_fd, &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{ .ctx = now_mono_ns, .now_fn = fakeNow },
        .egress_shared_fds = &session.worker_raw,
    });
}

/// Runs the route `source` as request `request_id` until it ends and
/// returns its body, which the caller frees. Fetch heads come from the test.
fn serveOnSession(
    runtime: *worker.Runtime,
    session: *RawSession,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
    specifier: []const u8,
    source: []const u8,
) ![]u8 {
    const route_index = try rt.registerRoute(runtime, specifier, source);
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, 1, .{});
    try executeNextReady(runtime);
    try session.sendOpenHead(runtime);
    try executeUntilRequestDone(runtime, request_id);
    return rt.readIngressResponseBody(runtime, server_control_fd, request_id);
}

// A stored reader takes no reference of its own; the table's covers it, and
// every removal drops the reader. A reader that took one and was discarded
// with the request left its body allocated forever, which the testing
// allocator's leak check at the runtime's teardown reports.
test "a request that ends while its text() waits on an open body frees the body" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const body = try serveOnSession(&runtime, &session, control_pair[1], 701, "/var/task/fetch-open-text.js",
        \\export default async function handle() {
        \\    const res = await fetch("https://origin.test/open");
        \\    res.text();
        \\    return new Response("ended");
        \\}
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("ended", body);
    try std.testing.expectEqual(@as(usize, 0), runtime.egress.state.bodies.count());
}

test "a reader cancelled while its read waits on an open body frees the body" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const body = try serveOnSession(&runtime, &session, control_pair[1], 702, "/var/task/fetch-open-cancel.js",
        \\export default async function handle() {
        \\    const res = await fetch("https://origin.test/open");
        \\    const reader = res.body.getReader();
        \\    reader.read().catch(() => {});
        \\    await reader.cancel();
        \\    return new Response("cancelled");
        \\}
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("cancelled", body);
}

/// A route that starts `fetches_per_request_max` fetches whose starts are
/// near the gateway's packet limits, more than the command ring holds, so
/// the last starts park; `abort` aborts the last fetch at once and answers
/// with the name of its rejection.
fn parkedStartsSource(comptime abort: bool) []const u8 {
    return 
    \\export default async function handle() {
    \\    const value = "x".repeat(4000);
    \\    const headers = {};
    \\    for (let i = 0; i < 15; i++) headers["x-large-" + i] = value;
    \\    const url = "https://origin.test/" + "u".repeat(15000) + "?";
    \\    const controller = new AbortController();
    \\    let last;
    \\    for (let i = 0; i < 16; i++)
    \\        last = fetch(url + i, i === 15 ? { headers, signal: controller.signal } : { headers });
    \\
++ (if (abort)
    \\    controller.abort();
    \\    return new Response(await last.then(() => "resolved", (err) => err.name));
    \\}
else
    \\    last.catch(() => {});
    \\    await new Promise((resolve) => setTimeout(resolve, 1));
    \\    return new Response("returned");
    \\}
);
}

/// The tasks of the runtime whose start never reached the command ring.
fn unsentStarts(runtime: *worker.Runtime) usize {
    var count: usize = 0;
    var tasks = runtime.egress.state.tasks.valueIterator();
    while (tasks.next()) |task| {
        if (!task.*.start_sent)
            count += 1;
    }
    return count;
}

// A canceled task used to wait for the gateway's answer to its cancel, which
// the gateway sends only for a start it received; a start parked on a full
// ring never got one, so its task stayed until the gateway went away.
test "a fetch whose start never left the worker is ended without the gateway when its request ends" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-parked.js", comptime parkedStartsSource(false));
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 703,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    try std.testing.expect(unsentStarts(&runtime) > 0);

    now_mono_ns += std.time.ns_per_ms;
    try executeUntilRequestDone(&runtime, 703);
    while (runtime.scheduler.ready_queue.pop()) |item|
        try worker.testing.executeWorkItem(&runtime, item);
    try std.testing.expectEqual(@as(usize, 0), unsentStarts(&runtime));
}

test "an abort of a fetch whose start never left the worker rejects with its AbortError at once" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-parked-abort.js", comptime parkedStartsSource(true));
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 704,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 704);
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], 704);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("AbortError", body);
}

// The finish's cleanup rejects a body read still pending, and that rejection
// runs the request's JavaScript after its response was decided. A fetch it
// starts used to reach the gateway after the response; a request whose
// finish started now refuses new work.
test "a fetch started by a reaction to a finishing request's body read never leaves the worker" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-after-finish.js",
        \\export default function handle(request) {
        \\    request.text().catch(() => fetch("https://origin.test/after-finish").catch(() => {}));
        \\    return new Response("returned");
        \\}
    );
    // The body never completes: the stream stays open after the head.
    const parts: RequestParts = .{
        .method = "POST",
        .body_framing = .ingress_channel,
        .body_end_stream = false,
    };
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 705,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
        .request = parts,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, parts);
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 705);
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], 705);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("returned", body);
    try std.testing.expectEqual(@as(usize, 0), runtime.egress.state.tasks.count());
}

// The gateway's error packet carries why a fetch failed. A denial used to
// reject with its text like any failure and leave nothing in the tenant's
// log, so a handler that swallowed the error hid which setting to change.
test "a fetch the network setting denied at the gateway rejects with the gateway's text, written once to the tenant's log, and a failed fetch writes no line" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-denied.js",
        \\export default async function handle() {
        \\    const outcomes = [];
        \\    for (const path of ["denied", "failed"]) {
        \\        try {
        \\            await fetch("https://origin.test/" + path);
        \\            outcomes.push("fetched");
        \\        } catch (err) {
        \\            outcomes.push((err instanceof TypeError ? "TypeError: " : "other: ") + err.message);
        \\        }
        \\    }
        \\    return new Response(outcomes.join("|"));
        \\}
    );
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 706,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);

    const denial = "fetch to https://origin.test denied by the network setting: the host is not in the allow list";
    try session.sendError(&runtime, .network_denied, denial);
    // The first fetch's settlement runs the handler on to its second fetch.
    try executeNextReady(&runtime);
    try session.sendError(&runtime, .failed, "fetch failed: ConnectionRefused");
    try executeUntilRequestDone(&runtime, 706);

    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], 706);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("TypeError: " ++ denial ++ "|TypeError: fetch failed: ConnectionRefused", body);
    try expectOneDenialLine(&completion_fixture.reader, 706, denial);
}

// The gateway admits a session's pooled starts only while their announced
// lengths fit its bytes in flight, and refuses the next one otherwise. The
// worker used to send every start at once, so a third large upload failed
// although the first two would end.
test "a pooled start that would pass the session's upload bytes in flight waits until an earlier pooled fetch ends, then leaves" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();

    // The bridge materializes every fetch body, so the largest one is the
    // materialized cap. Each start also reserves the copies of its start the
    // gateway keeps (`ipc.fetch_limits.pooledStartHeldBytes`: the record
    // allowance, "POST" and a URL of about 30 bytes, without headers), which
    // `start_held_slack` covers, so `fit` bodies short of the cap by it fill
    // the bytes in flight but for less than one more start, which is one
    // request's whole share of fetches, and one more, from a second request,
    // must wait.
    const start_held_slack: u64 = 4096;
    const body_bytes: u64 = limits.http_body.MATERIALIZED_BODY_BYTES_MAX - start_held_slack;
    const in_flight_max: u64 = ipc.fetch_limits.request_body_pooled_in_flight_bytes_max;
    const fit = in_flight_max / limits.http_body.MATERIALIZED_BODY_BYTES_MAX;
    comptime std.debug.assert(body_bytes > ipc.fetch_limits.request_body_inline_bytes_max);
    comptime std.debug.assert(fit * limits.http_body.MATERIALIZED_BODY_BYTES_MAX == in_flight_max);
    comptime std.debug.assert(fit <= limits.worker.fetches_per_request_max);
    comptime std.debug.assert(ipc.fetch_limits.pooled_start_record_bytes + 64 < start_held_slack);
    const starts = fit + 1;
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const filling = try uploadRouteSource(body_bytes, fit);
    defer std.testing.allocator.free(filling);
    const waiting = try uploadRouteSource(body_bytes, 1);
    defer std.testing.allocator.free(waiting);
    try rt.bootRoutes(&runtime, &.{
        .{ .specifier = "/fetch-upload-room-fill.js", .source = filling },
        .{ .specifier = "/fetch-upload-room-wait.js", .source = waiting },
    });
    var first = try initDispatchWork(std.testing.allocator, .{
        .request_id = 707,
        .route_index = 0,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer first.deinit();
    try rt.enqueueIngressRoute(&runtime, &first, 1, .{});
    try executeNextReady(&runtime);
    var second = try initDispatchWork(std.testing.allocator, .{
        .request_id = 708,
        .route_index = 1,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer second.deinit();
    try rt.enqueueIngressRoute(&runtime, &second, 3, .{});
    try executeNextReady(&runtime);

    // Fetch ids count from 1 in a fresh runtime.
    try std.testing.expectEqual(@as(usize, starts), runtime.egress.state.tasks.count());
    try std.testing.expectEqual(@as(usize, 1), unsentStarts(&runtime));
    try std.testing.expect(!runtime.egress.state.tasks.get(starts).?.start_sent);
    // Each sent start reserved its body and the copies of its start.
    const first_task = runtime.egress.state.tasks.get(1).?;
    const first_reserved = body_bytes + ipc.fetch_limits.pooledStartHeldBytes(first_task.method.len, first_task.url.len, first_task.headers);
    const reserved = runtime.egress.state.upload_reserved_bytes;
    try std.testing.expect(reserved > fit * body_bytes);
    try std.testing.expect(reserved <= in_flight_max);
    try std.testing.expect(reserved + first_reserved > in_flight_max);

    // The first fetch ends at the gateway: its bytes return, and the pump
    // that follows the packet sends the last start, whose URL and so whose
    // reservation are the first one's.
    try session.sendErrorFor(&runtime, 1, .failed, "fetch failed: test");
    try std.testing.expectEqual(@as(usize, 0), unsentStarts(&runtime));
    try std.testing.expectEqual(reserved, runtime.egress.state.upload_reserved_bytes);

    var fetch_id: u64 = 2;
    while (fetch_id <= starts) : (fetch_id += 1)
        try session.sendErrorFor(&runtime, fetch_id, .failed, "fetch failed: test");
    try std.testing.expectEqual(@as(u64, 0), runtime.egress.state.upload_reserved_bytes);
    try std.testing.expectEqual(@as(usize, 0), runtime.egress.state.fetches.count());
    const outcome = "fetch failed: test";
    inline for (.{ .{ 707, fit }, .{ 708, 1 } }) |expected| {
        try executeUntilRequestDone(&runtime, expected[0]);
        const body = try rt.readIngressResponseBody(&runtime, control_pair[1], expected[0]);
        defer std.testing.allocator.free(body);
        try std.testing.expectEqual(expected[1] * outcome.len + expected[1] - 1, body.len);
        var outcomes = std.mem.splitScalar(u8, body, '|');
        while (outcomes.next()) |each|
            try std.testing.expectEqualStrings(outcome, each);
    }
}

/// Answers every task of the runtime that has no answer yet with a 200 head
/// and an open body, lets the runtime read the heads, and runs what they
/// made ready.
fn answerOpenHeads(runtime: *worker.Runtime, session: *RawSession) !void {
    var tasks = runtime.egress.state.tasks.valueIterator();
    while (tasks.next()) |task| {
        if (task.*.done)
            continue;
        var buffer: [4096]u8 = undefined;
        const head = try ipc.encodeEgressFetchHeadInto(&buffer, .{
            .fetch_id = task.*.id,
            .body_id = task.*.response_body_identity.body_id,
            .status = 200,
            .status_text = "OK",
            .url = "https://origin.test/open",
            .headers = &.{},
        });
        _ = try session.gateway.completion.writePacket(head);
    }
    while (try runtime.collectEgressGatewayPacketsBounded(64)) {}
    while (runtime.scheduler.ready_queue.pop()) |item|
        try worker.testing.executeWorkItem(runtime, item);
}

/// The commands a test's gateway end found in the command ring since its
/// last look: fetch starts and everything else.
const CommandCounts = struct {
    starts: usize = 0,
    others: usize = 0,
};

/// Reads every command the worker wrote since the last call.
fn takeCommands(session: *RawSession) !CommandCounts {
    const buffer = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(buffer);
    var counts: CommandCounts = .{};
    while (try session.gateway.command.readPacket(buffer)) |packet| {
        const kind = try ipc.decodeMessageKind(std.mem.readInt(u32, packet[0..4], .little));
        switch (kind) {
            .egress_fetch_start => counts.starts += 1,
            else => counts.others += 1,
        }
    }
    return counts;
}

// The worker used to count a fetch until its head arrived, and the gateway
// until the fetch ended there, after its body. A worker whose fetches all
// had heads but open bodies saw room the gateway did not have, sent one more
// start, and the gateway refused it against the session.
test "a worker whose counted fetches all have heads but open bodies refuses one more fetch itself, and no start leaves" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // Each holding request starts its whole share of fetches, keeps every
    // response with its body unread and never ends.
    const per_request = limits.worker.fetches_per_request_max;
    const holding_requests = limits.worker.fetches_per_worker_max / per_request;
    comptime std.debug.assert(holding_requests * per_request == limits.worker.fetches_per_worker_max);
    const holding = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const pending = [];
        \\    for (let i = 0; i < {d}; i++)
        \\        pending.push(fetch("https://origin.test/held/" + i));
        \\    globalThis.__collo_held = (globalThis.__collo_held || []).concat(await Promise.all(pending));
        \\    return new Promise(() => {{}});
        \\}}
    , .{per_request});
    defer std.testing.allocator.free(holding);
    try rt.bootRoutes(&runtime, &.{
        .{ .specifier = "/fetch-hold.js", .source = holding },
        .{ .specifier = "/fetch-one-more.js", .source = 
        \\export default async function handle() {
        \\    try {
        \\        await fetch("https://origin.test/one-more");
        \\        return new Response("left");
        \\    } catch (err) {
        \\        return new Response(String(err));
        \\    }
        \\}
        },
    });

    var dispatches: [holding_requests]ipc.DispatchWork = undefined;
    var dispatched: usize = 0;
    defer for (dispatches[0..dispatched]) |*dispatch| dispatch.deinit();
    while (dispatched < holding_requests) : (dispatched += 1) {
        dispatches[dispatched] = try initDispatchWork(std.testing.allocator, .{
            .request_id = 900 + @as(u64, @intCast(dispatched)),
            .route_index = 0,
            .deadline_monotonic_ns = std.time.ns_per_hour,
        });
        errdefer dispatches[dispatched].deinit();
        // A client opens only odd-numbered streams.
        try rt.enqueueIngressRoute(&runtime, &dispatches[dispatched], @intCast(2 * dispatched + 1), .{});
        try executeNextReady(&runtime);
        try answerOpenHeads(&runtime, &session);
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.egress.state.tasks.count());
    try std.testing.expectEqual(
        CommandCounts{ .starts = limits.worker.fetches_per_worker_max },
        try takeCommands(&session),
    );

    // The next id after the holding requests', so the harness's slot for it
    // (the id modulo the live slots) is one no holding request occupies.
    const one_more_id: u64 = 900 + holding_requests;
    var one_more = try initDispatchWork(std.testing.allocator, .{
        .request_id = one_more_id,
        .route_index = 1,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer one_more.deinit();
    try rt.enqueueIngressRoute(&runtime, &one_more, 2 * holding_requests + 1, .{});
    try executeNextReady(&runtime);
    try std.testing.expectEqual(CommandCounts{}, try takeCommands(&session));
    try executeUntilRequestDone(&runtime, one_more_id);
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], one_more_id);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "Failed to schedule fetch"));
}

test "a fetch stays counted until its terminal packet: its body end, its error or its stop's acknowledgment" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-terminal-packets.js",
        \\export default async function handle() {
        \\    const controller = new AbortController();
        \\    const ended = fetch("https://origin.test/ended");
        \\    const failed = fetch("https://origin.test/failed").catch((err) => err.message);
        \\    const aborted = fetch("https://origin.test/aborted", { signal: controller.signal })
        \\        .catch((err) => err.name);
        \\    const res = await ended;
        \\    const bytes = await res.arrayBuffer();
        \\    controller.abort();
        \\    return new Response([bytes.byteLength, await failed, await aborted].join("|"));
        \\}
    );
    const request_id: u64 = 910;
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    const state = &runtime.egress.state;
    try std.testing.expectEqual(@as(usize, 3), state.fetches.count());
    try std.testing.expectEqual(CommandCounts{ .starts = 3 }, try takeCommands(&session));
    const ended_body = state.tasks.get(1).?.response_body_identity;
    const aborted_body = state.tasks.get(3).?.response_body_identity;

    // A head ends nothing at the gateway, so the fetch stays counted while
    // its body streams.
    var head_buffer: [4096]u8 = undefined;
    const head = try ipc.encodeEgressFetchHeadInto(&head_buffer, .{
        .fetch_id = 1,
        .body_id = ended_body.body_id,
        .status = 200,
        .status_text = "OK",
        .url = "https://origin.test/ended",
        .headers = &.{},
    });
    _ = try session.gateway.completion.writePacket(head);
    _ = try runtime.collectEgressGatewayPacketsBounded(8);
    try executeNextReady(&runtime);
    try std.testing.expectEqual(@as(usize, 3), state.fetches.count());

    try session.sendBodyEnd(&runtime, ended_body);
    try std.testing.expectEqual(@as(usize, 2), state.fetches.count());
    // The body's end resolves the read, and the handler aborts the third
    // fetch: one stop names it, and it stays counted until the gateway
    // acknowledges that stop.
    try executeNextReady(&runtime);
    const stop_buffer = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(stop_buffer);
    const stop = (try session.gateway.command.readPacket(stop_buffer)) orelse return error.TestExpectedStop;
    try std.testing.expectEqual(@as(u64, 3), try ipc.egress.decodeStop(stop));
    try std.testing.expectEqual(CommandCounts{}, try takeCommands(&session));
    try std.testing.expect(state.fetches.contains(3));

    try session.sendErrorFor(&runtime, 2, .failed, "fetch failed: test");
    try std.testing.expectEqual(@as(usize, 1), state.fetches.count());

    const ack = ipc.EgressAbortAck.init(3, aborted_body.body_id);
    _ = try session.gateway.completion.writePacket(std.mem.asBytes(&ack));
    _ = try runtime.collectEgressGatewayPacketsBounded(8);
    try std.testing.expectEqual(@as(usize, 0), state.fetches.count());

    try executeUntilRequestDone(&runtime, request_id);
    const body = try rt.readIngressResponseBody(&runtime, control_pair[1], request_id);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("0|fetch failed: test|AbortError", body);
}

// A fetch body's cancel used to stop the fetch with two commands, a cancel
// and a release, and the second named a fetch the first had already retired
// at the gateway, which counted against the session.
test "cancelling the only view of an open fetch body sends one stop for the fetch" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const body = try serveOnSession(&runtime, &session, control_pair[1], 913, "/var/task/fetch-cancel-one.js",
        \\export default async function handle() {
        \\    const res = await fetch("https://origin.test/open");
        \\    await res.body.cancel();
        \\    return new Response("cancelled");
        \\}
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("cancelled", body);
    try std.testing.expectEqual(CommandCounts{ .starts = 1, .others = 1 }, try takeCommands(&session));
}

// Cancelling the source view of a cloned body used to fail the source, which
// stopped feeding the clone and kept the last view from stopping the fetch.
test "letting go of every view of an open fetch body sends one stop for the fetch" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const body = try serveOnSession(&runtime, &session, control_pair[1], 911, "/var/task/fetch-one-stop.js",
        \\export default async function handle() {
        \\    const res = await fetch("https://origin.test/open");
        \\    const copy = res.clone();
        \\    await res.body.cancel();
        \\    await copy.body.cancel();
        \\    return new Response("cancelled");
        \\}
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("cancelled", body);
    try std.testing.expectEqual(CommandCounts{ .starts = 1, .others = 1 }, try takeCommands(&session));
}

// The worker used to fold byte meters the gateway's packets carried, and
// took no count of a chunk that reached a body no view read any more.
test "a request records the body bytes its fetch sent and every chunk that arrived, after its reader let go too" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = std.time.ns_per_s;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-bytes.js",
        \\export default async function handle() {
        \\    const res = await fetch("https://origin.test/bytes", { method: "POST", body: "x".repeat(100) });
        \\    const reader = res.body.getReader();
        \\    const first = await reader.read();
        \\    await reader.cancel();
        \\    await new Promise((resolve) => setTimeout(resolve, 10));
        \\    return new Response(String(first.value.byteLength));
        \\}
    );
    const request_id: u64 = 912;
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    try session.sendOpenHead(&runtime);
    try executeNextReady(&runtime);

    // The first chunk answers the read, whose reader then lets go; the
    // second arrives after that, before the request ends.
    var bodies = runtime.egress.state.bodies.valueIterator();
    const body_identity = (bodies.next() orelse return error.TestExpectedBody).*.identity;
    for ([_][]const u8{ "hello", "goodbye" }, 0..) |bytes, index| {
        const handle = try session.gateway.body_pool.writeChunk(bytes);
        var buffer: [256]u8 = undefined;
        const batch = try ipc.encodeEgressBodyChunkBatchInto(&buffer, .{ .chunks = &.{.{
            .fetch_id = body_identity.fetch_id,
            .body_id = body_identity.body_id,
            .body_pool_offset = handle,
            .len = bytes.len,
        }} });
        _ = try session.gateway.completion.writePacket(batch);
        _ = try runtime.collectEgressGatewayPacketsBounded(8);
        if (index == 0)
            try executeNextReady(&runtime);
    }

    now_mono_ns += 20 * std.time.ns_per_ms;
    try executeUntilRequestDone(&runtime, request_id);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqualStrings("5", response.body);
    try std.testing.expectEqual(@as(u64, 100), response.done.fetch_sent_bytes);
    try std.testing.expectEqual(@as(u64, "hello".len + "goodbye".len), response.done.fetch_received_bytes);
}

/// "hello world" as one gzip member.
const gzip_hello_world = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
    0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
};

test "a request records a pooled upload's bytes as its batches leave, and a redirected fetch's encoded body as it arrived" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = std.time.ns_per_s;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // Four times the inline limit, so the body streams through the upload pool.
    const upload_bytes: usize = 4 * ipc.fetch_limits.request_body_inline_preferred_bytes_max;
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const res = await fetch("https://origin.test/upload", {{ method: "POST", body: new Uint8Array({d}) }});
        \\    const bytes = await res.arrayBuffer();
        \\    return new Response(bytes.byteLength + ":" + res.redirected);
        \\}}
    , .{upload_bytes});
    defer std.testing.allocator.free(source);
    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-upload-bytes.js", source);
    const request_id: u64 = 913;
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);

    // The start announced a pooled body, and the upload batches carried all of it.
    const scratch = try std.testing.allocator.create(ipc.GatewayEgressDecodeScratch);
    defer std.testing.allocator.destroy(scratch);
    scratch.* = .{};
    const packet_buffer = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(packet_buffer);
    const start_packet = (try session.gateway.command.readPacket(packet_buffer)) orelse return error.TestExpectedFetchStart;
    const start = try ipc.decodeEgressFetchStart(scratch, start_packet);
    try std.testing.expect((start.flags & ipc.egress_fetch_start_flag_body_pooled) != 0);
    try std.testing.expectEqual(@as(u64, upload_bytes), start.pooled_body_len);
    const fetch_id = start.fetch_id;
    const body_id = start.body_id;
    var uploaded: usize = 0;
    while (try session.gateway.command.readPacket(packet_buffer)) |batch_packet| {
        for (try ipc.decodeEgressUploadChunkBatch(scratch, batch_packet)) |chunk|
            uploaded += chunk.len;
    }
    try std.testing.expectEqual(upload_bytes, uploaded);

    // The gateway followed a redirect and the origin answered with a gzip body, which reaches
    // the worker still encoded.
    var head_buffer: [4096]u8 = undefined;
    const head = try ipc.encodeEgressFetchHeadInto(&head_buffer, .{
        .fetch_id = fetch_id,
        .body_id = body_id,
        .flags = ipc.egress_fetch_head_flag_redirected,
        .status = 200,
        .body_encoding = .gzip,
        .max_decoded_body_bytes = 1024 * 1024,
        .status_text = "OK",
        .url = "https://origin.test/moved",
        .headers = &.{},
    });
    _ = try session.gateway.completion.writePacket(head);
    _ = try runtime.collectEgressGatewayPacketsBounded(8);
    const handle = try session.gateway.body_pool.writeChunk(&gzip_hello_world);
    var batch_buffer: [256]u8 = undefined;
    const batch = try ipc.encodeEgressBodyChunkBatchInto(&batch_buffer, .{ .chunks = &.{.{
        .fetch_id = fetch_id,
        .body_id = body_id,
        .body_pool_offset = handle,
        .len = gzip_hello_world.len,
    }} });
    _ = try session.gateway.completion.writePacket(batch);
    try session.sendBodyEnd(&runtime, .{
        .request_id = request_id,
        .request_generation = 1,
        .fetch_id = fetch_id,
        .body_id = body_id,
    });

    try executeUntilRequestDone(&runtime, request_id);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqualStrings("11:true", response.body);
    // The upload counts once, as its batches left; the body counts as it arrived, encoded, and
    // the hops the gateway made are not the worker's to count.
    try std.testing.expectEqual(@as(u64, upload_bytes), response.done.fetch_sent_bytes);
    try std.testing.expectEqual(@as(u64, gzip_hello_world.len), response.done.fetch_received_bytes);
}

// The liveness pipe's check was tested only on a worker without a session, so a version that let
// go of the session it held before comparing the pipes would pass it, and a misrouted attach
// would cost a healthy worker its session.
test "an egress_attach on another wake set is refused before the worker lets go of the session it holds" {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var held_session = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer held_session.deinit();
    var held_half = held_session.takeWorkerHalf();
    defer held_half.close();
    var other_wake_set = try ipc.egress_shared.WakeSet.create();
    defer other_wake_set.deinit();
    var other_session = try ipc.egress_shared.createSessionForWorker(&other_wake_set);
    defer other_session.deinit();
    var other_half = other_session.takeWorkerHalf();
    defer other_half.close();

    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &held_half,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const held = runtime.egress.state.shared orelse return error.TestExpectedSession;
    const held_command_eventfd = held.command_eventfd;
    try ipc.egress_attach.send(control_pair[1], other_half);
    try std.testing.expectError(
        error.EgressAttachLivenessPipeMismatch,
        worker.testing.scheduler.loop.collectControlPacket(&runtime),
    );
    const still_held = runtime.egress.state.shared orelse return error.TestExpectedSession;
    try std.testing.expectEqual(held_command_eventfd, still_held.command_eventfd);
}

/// The source of a route that uploads `count` bodies of `body_bytes` at once
/// and answers each outcome, joined by `|`. The caller frees it.
fn uploadRouteSource(body_bytes: u64, count: u64) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const body = new Uint8Array({d});
        \\    const outcomes = [];
        \\    for (let i = 0; i < {d}; i++)
        \\        outcomes.push(fetch("https://origin.test/upload/" + i, {{ method: "POST", body }})
        \\            .then(() => "fetched", (err) => err.message));
        \\    return new Response((await Promise.all(outcomes)).join("|"));
        \\}}
    , .{ body_bytes, count });
}

// A body's ready item counts for its request from its enqueue to its pop. A
// reader cancelled after the item was queued left nothing for it to do, but
// the count stayed until the pop, so the request read as runnable, and its
// I/O as waiting, until then.
test "a reader cancelled while its body's ready item is queued gives the count back, so the time until the item pops is I/O" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    // Away from 0, which a readiness stamp reads as now.
    var now_mono_ns: u64 = std.time.ns_per_s;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_index = try rt.registerRoute(&runtime, "/var/task/fetch-cancel-queued.js",
        \\export default async function handle() {
        \\    const res = await fetch("https://origin.test/open");
        \\    const reader = res.body.getReader();
        \\    reader.read().catch(() => {});
        \\    return new Promise((resolve) => {
        \\        setTimeout(() => {
        \\            reader.cancel().catch(() => {});
        \\            setTimeout(() => resolve(new Response("cancelled")), 100);
        \\        }, 0);
        \\    });
        \\}
    );
    const request_id: u64 = 708;
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    try session.sendOpenHead(&runtime);
    // The head's settlement starts the read, which waits on the open body,
    // and sets the timer.
    try executeNextReady(&runtime);
    try runtime.collectDueTimers();

    // The body ends while the read waits, which queues its item behind the
    // timer's.
    try std.testing.expectEqual(@as(usize, 1), runtime.egress.state.bodies.count());
    var bodies = runtime.egress.state.bodies.valueIterator();
    try session.sendBodyEnd(&runtime, bodies.next().?.*.identity);

    // The timer cancels the reader, and the body's item stays queued.
    try executeNextReady(&runtime);
    try std.testing.expect(!runtime.scheduler.ready_queue.isEmpty());

    // 50 ms pass before the stale item pops, with nothing of the request
    // ready: I/O. A count left behind made them waiting.
    now_mono_ns += 50 * std.time.ns_per_ms;
    try executeNextReady(&runtime);
    now_mono_ns += 50 * std.time.ns_per_ms;
    try executeUntilRequestDone(&runtime, request_id);

    var response = try rt.readIngressResponse(&runtime, control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqualStrings("cancelled", response.body);
    try std.testing.expect(response.done.waiting_ns < std.time.ns_per_ms);
    try std.testing.expect(response.done.io_ns >= 100 * std.time.ns_per_ms);
}

test "a gateway completion whose fetch id does not match its body detaches the session and keeps the loop serving" {
    var session: RawSession = undefined;
    try session.init();
    defer session.deinit();
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initSessionRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns, &session);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // A request whose fetch waits on the gateway, with its body open.
    const route_index = try rt.registerRoute(&runtime, "/var/task/egress-id-mismatch.js",
        \\export default async function handle() {
        \\    await fetch("https://origin.test/mismatch").catch(() => {});
        \\    return new Promise(() => {});
        \\}
    );
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 801,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try executeNextReady(&runtime);
    var tasks = runtime.egress.state.tasks.valueIterator();
    const identity = (tasks.next() orelse return error.TestExpectedFetchTask).*.response_body_identity;

    // The gateway ends that body under a fetch id one past its own.
    var end_message = ipc.EgressBodyEnd.init(identity.fetch_id + 1, identity.body_id);
    _ = try session.gateway.completion.writePacket(std.mem.asBytes(&end_message));

    // The malformed packet detaches the worker: its fetches settle and its
    // endpoint is released, while the loop keeps serving requests until the
    // server attaches a new session.
    _ = try runtime.collectEgressGatewayPacketsBounded(8);
    try std.testing.expect(runtime.egress.state.shared == null);
    try std.testing.expect(runtime.core.running);
    try std.testing.expect(runtime.requests.active.contains(801));
}
