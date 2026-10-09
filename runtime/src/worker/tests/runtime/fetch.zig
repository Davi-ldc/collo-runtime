//! Covers fetch from a handler in the worker runtime, through the in-process
//! gateway of the harness (`LocalEgressGateway`) to a local origin: URLs
//! refused before or by the gateway, the request's egress token a FetchStart
//! carries byte for byte, the refusal with a TypeError, before anything
//! leaves the worker, of a fetch whose request carries no token or whose
//! worker has no egress session, even on a signal already at its listener
//! limit, and of a request's fetch past `max_fetches_per_request` started,
//! finished ones included, the active fetch failed with a TypeError when
//! the gateway is lost while the worker keeps serving, a body-pool release
//! the pool refuses, which detaches the worker between handlers and leaves it
//! serving, a worker booted without
//! a session that an `egress_attach` on its control socket attaches, the
//! response's status, bytes, headers and streaming body, `clone`, a fetch
//! response returned as the handler's response, a saved one refused in a later
//! request, and live clones released at teardown. Runs in `worker-test`; the
//! gateway's admission and policy are covered by its own tests, a forked
//! worker attached again after it lost its gateway by the zygote integration
//! lane, and fetch's Web API surface by the `webapi` lane.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker_metrics_state = @import("collo_worker_state").metrics;
const worker_shared_page = @import("collo_worker_state").page;
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const local_address = @import("collo_test_net");

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

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    try {
        \\        await fetch("file:///tmp/nope");
        \\    } catch (err) {
        \\        return Response.json({ rejected: String(err).includes("Failed to schedule fetch") });
        \\    }
        \\    return "unexpected";
        \\}
    , 14, "/fetch-invalid-protocol.js", "\"rejected\":true");

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    try {
        \\        await fetch("http://127.0.0.1:1/nope");
        \\    } catch (err) {
        \\        return Response.json({ rejected: true });
        \\    }
        \\    return "unexpected";
        \\}
    , 15, "/fetch-http-blocked.js", "\"rejected\":true");

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    try {
        \\        await fetch("\uD800");
        \\    } catch (err) {
        \\        return Response.json({ rejected: true });
        \\    }
        \\    return "unexpected";
        \\}
    , 16, "/fetch-invalid-utf8.js", "\"rejected\":true");

    try runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    try {
        \\        await fetch("invalid url", { body: new Uint8Array([1]) });
        \\    } catch (err) {
        \\        return Response.json({ invalidUrlFirst: String(err).includes("invalid URL") });
        \\    }
        \\    return "unexpected";
        \\}
    , 25, "/fetch-invalid-url-before-body.js", "\"invalidUrlFirst\":true");
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

test "a fetch in a worker without an egress session rejects at once with a TypeError" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    // No egress descriptors, as for a worker whose definition has no egress
    // grant: the worker runs detached from any gateway.
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
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
    , 33, "/fetch-detached.js", "\"typeError\":true,\"message\":\"fetch failed: no egress gateway\"");
}

test "a request's fetch past max_fetches_per_request is refused in the worker, finished fetches included, and never reaches the gateway" {
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
    const limit: usize = comptime @intCast(ipc.WorkerRuntimeBootOptions.default().max_fetches_per_request);
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
    , 41, "/fetch-refused-signal-limit.js", "\"typeError\":true,\"message\":\"fetch failed: no egress gateway\"");
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
    try std.testing.expectEqual(boot_wake, egress_state.wakeFds().?);

    // The server attaches the worker to that session on its control socket.
    var worker_half = gateway.takeWorkerSharedFds();
    defer worker_half.close();
    try ipc.egress_attach.send(control_pair[1], worker_half);
    try worker.testing.scheduler.loop.collectControlPacket(&runtime);
    try std.testing.expect(egress_state.shared != null);
    try std.testing.expect(egress_state.detached_wake == null);
    // The boot's descriptors closed, and the endpoint's watch the same pipes.
    const boot_descriptors = [_]std.posix.fd_t{
        boot_wake.command_eventfd,
        boot_wake.completion_eventfd,
        boot_wake.liveness_fd,
        boot_wake.peer_liveness_fd,
    };
    for (boot_descriptors) |fd|
        try expectClosedDescriptor(fd);
    const attached_wake = egress_state.wakeFds() orelse return error.TestExpectedWakeDescriptors;
    try expectSamePipe(wake_set.liveness_read.fd(), attached_wake.liveness_fd);

    const route_index = try registerFetchRoute(&runtime, "/fetch-after-attach.js", origin.host(), origin.port, "/binary");
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

    const hang_route = try registerFetchRoute(&runtime, "/fetch-hang-across-attach.js", host, silent_server.listen_address.getPort(), "/hang");
    const origin_route = try registerFetchRoute(&runtime, "/fetch-after-attach.js", origin.host(), origin.port, "/binary");

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

test "an egress_attach whose session is on another wake set is refused with every descriptor it brought closed" {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var boot_fds = ipc.egress_shared.RawFds.wakeOnly(try wake_set.openWorkerWake());
    defer boot_fds.close();
    // A session built on another worker's wake set, whose liveness pipe the
    // worker's ring does not watch.
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

    const open_before = try openFdCount();
    try ipc.egress_attach.send(control_pair[1], other_half);
    try std.testing.expectError(
        error.EgressAttachLivenessPipeMismatch,
        worker.testing.scheduler.loop.collectControlPacket(&runtime),
    );
    try std.testing.expectEqual(open_before, try openFdCount());
    try std.testing.expect(runtime.egress.state.shared == null);
    try std.testing.expect(runtime.egress.state.detached_wake != null);
}

/// Registers route `path`, whose handler fetches `target_path` from
/// `host:port` and answers the fetch's status, or the TypeError it rejected
/// with and its message. Returns the route's index.
fn registerFetchRoute(
    runtime: *worker.Runtime,
    path: []const u8,
    host: []const u8,
    port: u16,
    target_path: []const u8,
) !u16 {
    const specifier = try rt.routeSpecifier(std.testing.allocator, path);
    defer std.testing.allocator.free(specifier);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    try {{
        \\        const res = await fetch("http://{s}:{d}{s}");
        \\        return Response.json({{ status: res.status }});
        \\    }} catch (err) {{
        \\        return Response.json({{ typeError: err instanceof TypeError, message: err.message }});
        \\    }}
        \\}}
    , .{ host, port, target_path });
    defer std.testing.allocator.free(source);
    return rt.registerRoute(runtime, specifier, source);
}

/// Open descriptors of this process, counted from `/proc/self/fd` without
/// the one the count itself opens.
fn openFdCount() !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();
    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |_|
        count += 1;
    return count - 1;
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

test "a malformed completion packet detaches the worker, which keeps serving and refuses the next fetch" {
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
    const release = &runtime.egress.state.body_pool_release_context;
    release.release_fn(release.context, 1, std.math.maxInt(u32));
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

    // Once the gateway has written the body's end, one more pass applies it,
    // and the handler waits on its timer with the whole body unread.
    var attempts: usize = 0;
    while (gateway.publishedBodyEnds() < 1) : (attempts += 1) {
        if (attempts > 2000)
            return error.BodyNeverEnded;
        try pumpOnce(&runtime);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try pumpOnce(&runtime);

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
/// packets, fetch completions, fetch bodies, timers and immediates, then
/// drains the ready queue.
fn pumpOnce(runtime: *worker.Runtime) !void {
    _ = try runtime.collectEgressGatewayPacketsBounded(64);
    try runtime.collectCompletedFetches();
    try runtime.collectReadyFetchBodies();
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

    const saved = try runRouteAndReadBody(&runtime, control_pair[1], save_source, 21, "/save-fetch-response.js");
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.containsAtLeast(u8, saved, 1, "saved"));

    var rejected = try rt.runRouteAndReadIngressResponse(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return globalThis.__saved_fetch_response;
        \\}
    , 22, "/reuse-fetch-response.js");
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
