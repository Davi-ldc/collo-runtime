//! Covers the evaluations that own route modules' top-level code
//! (`worker/runtime/evaluations.zig`): each the boot opens copies
//! WorkerInit's boot token, which every fetch of its top-level code presents,
//! and together they start no more fetches than that one token admits; a
//! later evaluation gets no token, a gateway disconnect clears every copy,
//! and the lifecycle page's startup-end flag goes up once the last startup
//! evaluation closes, whether it settled, rejected or expired; each gets its
//! route's evaluation budget once its synchronous part ends, and closes with its
//! route's evaluation, after which nothing runs or is scheduled under its
//! id; with the `none` boot token fetch alone is refused, with a TypeError
//! and before anything leaves the worker, and in a worker without a network
//! grant it gets the network setting's denial, logged under request id 0. Each route's top-level timers end
//! with its own evaluation, and one route's top-level code cannot clear
//! another's timers. A top-level `import()` loads from the registered pack
//! and sends nothing to the server. A worker whose only route failed on an
//! await sends one `worker_retiring` notice and keeps answering, a begin
//! after the notice with 503 and no JavaScript. Most tests boot one route; a table of
//! several, with routes that share a module instance and so an evaluation,
//! is covered in `routes.zig`. Runs in `worker-test`.
//!
//! These tests drive the worker side end to end (evaluate, settle, serve).
//! The `LocalEgressGateway` harness submits straight to the engine and runs
//! no admission. The gateway's admission of a boot token, refused past its
//! deadline and after its `request_ended`, is covered in
//! `egress/tests/gateway/worker_flow.zig`; the recorded FetchStart tokens
//! join the two, since what the worker puts on the wire is what that test
//! admits.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const local_address = @import("collo_test_net");
const request_context = @import("collo_worker_request").context;
const worker_shared_page = @import("collo_worker_state").page;
const retirement_notice = @import("retirement_notice.zig");

const fakeNow = rt.fakeNow;
const socketPairType = rt.socketPairType;
const createModulePackFd = rt.createModulePackFd;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;
const LocalOrigin = rt.LocalOrigin;

const module_eval_budget_ns = worker.testing.module_routes.module_eval_budget_ns;

/// The evaluation of the route at index 0, the only route most tests boot.
const first_evaluation_id = request_context.evaluationId(0);

/// The deadline the boot tokens below carry. The worker copies a token
/// without reading it, so any instant on the fake clock serves.
const boot_window_end_ns: u64 = 30 * std.time.ns_per_s;

/// One scheduler pass: collects every completion source
/// `executeUntilRequestDone` collects, then drains the whole ready queue.
/// The boot window has no single request whose end could stop the loop.
fn pumpOnce(runtime: *worker.Runtime) !void {
    _ = try runtime.collectEgressGatewayPacketsBounded(64);
    runtime.collectModuleSettlements();
    try runtime.collectCompletedCryptoJobs();
    try runtime.collectCompletedFetches();
    try runtime.collectReadyFetchBodies();
    try runtime.collectDueTimers();
    try runtime.collectReadyImmediates();
    try runtime.collectDueRequestDeadlines();
    while (!runtime.scheduler.ready_queue.isEmpty())
        try executeNextReady(runtime);
}

fn pumpUntilRouteReady(runtime: *worker.Runtime, specifier: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        if (rt.routeModule(runtime, specifier)) |record| {
            if (record.* == .ready)
                return;
            if (record.* == .failed)
                return error.BootEvaluationFailed;
        }
        try pumpOnce(runtime);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.BootEvaluationDidNotSettle;
}

fn expectControlSilent(fd: std.posix.fd_t, timeout_ms: i32) !void {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pollfds, timeout_ms));
}

/// Adds `specifier` as the runtime's route, as the route table WorkerInit
/// carries would, and evaluates it as the worker's boot does, from the pack
/// in `route_fd`.
fn bootEvaluate(runtime: *worker.Runtime, route_fd: std.posix.fd_t, specifier: []const u8) !void {
    _ = try rt.addRoute(runtime, specifier);
    try runtime.evaluateBootRoutes(route_fd, 0, null);
    runtime.sealStartupEvaluations();
}

/// The module state of the route at `specifier`, which the runtime holds.
fn routeRecord(runtime: *worker.Runtime, specifier: []const u8) !worker.testing.module_routes.RouteModuleState {
    const record = rt.routeModule(runtime, specifier) orelse return error.MissingRouteRecord;
    return record.*;
}

fn enqueueRoute(
    runtime: *worker.Runtime,
    request_id: u64,
    route_entry_specifier: []const u8,
    path: []const u8,
) !void {
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = rt.routeIndex(runtime, route_entry_specifier) orelse return error.TestRouteMissing,
        .request = .{ .path = path },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, 1, .{ .path = path });
}

/// Runs one request for the route at `specifier` to its end and returns its
/// body, which the caller frees. Its deadline lies an hour out on the fake
/// clock, so a test may move the clock before it.
fn serveLate(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
    specifier: []const u8,
) ![]u8 {
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = rt.routeIndex(runtime, specifier) orelse return error.TestRouteMissing,
        .deadline_monotonic_ns = std.time.ns_per_hour,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, 1, .{});
    try executeNextReady(runtime);
    try executeUntilRequestDone(runtime, request_id);
    return rt.readIngressResponseBody(runtime, server_control_fd, request_id);
}

fn expectStartupEnded(runtime: *const worker.Runtime, expected: bool) !void {
    const snapshot = worker_shared_page.LifecycleSnapshot.load(runtime.observability.metrics_view.header);
    try std.testing.expectEqual(expected, snapshot.startupEnded());
}

test "a startup evaluation that closes before the next route opens sets no startup-end flag" {
    var vm = try support.createVm();
    defer vm.deinit();
    var now_ns: u64 = 0;
    var completion = try rt.CompletionFixture.init();
    defer completion.deinit();
    const token = rt.bootEgressToken(boot_window_end_ns);
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{ .ctx = &now_ns, .now_fn = fakeNow },
        .boot_egress_token = token,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    const synchronous = "/__collo_route/demo/startup-sync.js";
    const pending = "/__collo_route/demo/startup-pending.js";
    const pack_fd = try rt.createModulePackGraphFd(&.{
        .{ .specifier = synchronous, .source = "export default function() {}" },
        .{ .specifier = pending, .source = "await new Promise(() => {}); export default function() {}" },
    }, 0);
    defer std.posix.close(pack_fd);
    _ = try rt.addRoute(&runtime, synchronous);
    _ = try rt.addRoute(&runtime, pending);
    try runtime.evaluateBootRoutes(pack_fd, 0, null);
    runtime.sealStartupEvaluations();
    try expectStartupEnded(&runtime, false);
    const owner = runtime.requests.active.get(request_context.evaluationId(1)).?;
    try std.testing.expectEqualSlices(u8, &token, &owner.dispatch_work.egress_token);
    now_ns = module_eval_budget_ns;
    runtime.expireRouteEvaluations();
    try expectStartupEnded(&runtime, true);
}

test "a module instance two routes share sets the startup-end flag once it rejects or expires" {
    for ([_]bool{ true, false }) |reject| {
        var vm = try support.createVm();
        defer vm.deinit();
        var now_ns: u64 = 0;
        var completion = try rt.CompletionFixture.init();
        defer completion.deinit();
        const token = rt.bootEgressToken(boot_window_end_ns);
        var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
            .clock = .{ .ctx = &now_ns, .now_fn = fakeNow },
            .boot_egress_token = token,
        });
        defer runtime.deinit();
        try runtime.attachHostRuntime();
        const shared = "/__collo_route/demo/startup-shared.js";
        const pack_fd = try createModulePackFd(
            shared,
            "await new Promise((_, reject) => { globalThis.rejectStartup = reject; }); export default function() {}",
        );
        defer std.posix.close(pack_fd);
        _ = try rt.addRoute(&runtime, shared);
        _ = try rt.addRoute(&runtime, shared);
        try runtime.evaluateBootRoutes(pack_fd, 0, null);
        runtime.sealStartupEvaluations();
        try expectStartupEnded(&runtime, false);
        const owner = runtime.requests.active.get(first_evaluation_id).?;
        try std.testing.expectEqualSlices(u8, &token, &owner.dispatch_work.egress_token);
        if (reject) {
            try support.registerModule(&vm, "/reject-startup.js", "globalThis.rejectStartup(new Error('rejected')); export default 1;");
            try support.evaluateOk(&vm, "/reject-startup.js");
            runtime.collectModuleSettlements();
        } else {
            now_ns = module_eval_budget_ns;
            runtime.expireRouteEvaluations();
        }
        try expectStartupEnded(&runtime, true);
    }
}

test "a request-triggered evaluation gets no boot token" {
    var vm = try support.createVm();
    defer vm.deinit();
    var now_ns: u64 = 0;
    var completion = try rt.CompletionFixture.init();
    defer completion.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{ .ctx = &now_ns, .now_fn = fakeNow },
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    runtime.sealStartupEvaluations();
    try expectStartupEnded(&runtime, true);
    try std.testing.expect(ipc.egress_token.isNone(&runtime.evaluations.boot_egress_token));
    const late = "/__collo_route/demo/startup-late.js";
    const late_index = try rt.registerRoute(&runtime, late, "await new Promise(() => {}); export default function() {}");
    try enqueueRoute(&runtime, 71, late, "/late");
    try executeNextReady(&runtime);
    const owner = runtime.requests.active.get(request_context.evaluationId(late_index)).?;
    try std.testing.expect(ipc.egress_token.isNone(&owner.dispatch_work.egress_token));
    try expectStartupEnded(&runtime, true);
}

test "a gateway disconnect clears every boot token copy and leaves the pending startup evaluation open" {
    var vm = try support.createVm();
    defer vm.deinit();
    var completion = try rt.CompletionFixture.init();
    defer completion.deinit();
    var now_ns: u64 = 0;
    const token = rt.bootEgressToken(boot_window_end_ns);
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{ .ctx = &now_ns, .now_fn = fakeNow },
        .boot_egress_token = token,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    const entry = "/__collo_route/demo/startup-disconnect.js";
    const pack = try createModulePackFd(entry, "await new Promise(() => {}); export default function() {}");
    defer std.posix.close(pack);
    try bootEvaluate(&runtime, pack, entry);
    const before = runtime.requests.active.get(first_evaluation_id).?;
    try std.testing.expectEqualSlices(u8, &token, &before.dispatch_work.egress_token);
    runtime.disconnectEgressGatewayWithReason("replaced");
    const after = runtime.requests.active.get(first_evaluation_id) orelse return error.EvaluationEnded;
    try std.testing.expect(ipc.egress_token.isNone(&after.dispatch_work.egress_token));
    try std.testing.expect(ipc.egress_token.isNone(&runtime.evaluations.boot_egress_token));
    try expectStartupEnded(&runtime, false);
}

test "a top-level await fetch at boot presents WorkerInit's boot token" {
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
    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
        .boot_egress_token = boot_token,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/boot-fetch.js";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\const res = await fetch("http://{s}:{d}/data", {{
        \\    method: "POST",
        \\    headers: {{ "x-collo-test": "yes", cookie: "secret=1" }},
        \\    body: new Uint8Array([112, 97, 121, 108, 111, 97, 100])
        \\}});
        \\globalThis.__boot_body = await res.text();
        \\export default function handle() {{
        \\    return globalThis.__boot_body;
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const route_fd = try createModulePackFd(specifier, source);
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    const evaluation = runtime.requests.active.get(first_evaluation_id) orelse
        return error.MissingEvaluation;

    // These fields differ from a dispatched request's, each for the reason
    // `RequestContext.initEvaluation` gives. The evaluation keeps its own
    // copy of the boot token.
    try std.testing.expectEqual(first_evaluation_id, evaluation.exec.request_id);
    try std.testing.expectEqual(@as(u64, 0), evaluation.request_generation);
    try std.testing.expect(evaluation.dispatch_started);
    try std.testing.expect(evaluation.live_slot_released);
    try std.testing.expectEqualSlices(u8, &boot_token, &evaluation.dispatch_work.egress_token);
    try std.testing.expect(ipc.egress_token.isNone(&runtime.evaluations.boot_egress_token));
    try expectStartupEnded(&runtime, false);
    // A top-level await is in flight, so the route's budget is armed.
    try std.testing.expect(evaluation.deadline_armed);
    try std.testing.expectEqual(now_mono_ns + module_eval_budget_ns, evaluation.exec.deadline_monotonic_ns);

    try pumpUntilRouteReady(&runtime, specifier);

    // The settlement closed the evaluation, so no deadline, identity or
    // byte count of it outlives the close.
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));
    try expectStartupEnded(&runtime, true);

    // Exactly one FetchStart crossed the wire, carrying the boot token byte
    // for byte: kind boot, request id and generation 0.
    var starts: [4]rt.FetchStartIdentity = undefined;
    const start_count = gateway.recordedFetchStarts(&starts);
    try std.testing.expectEqual(@as(usize, 1), start_count);
    try std.testing.expectEqualSlices(u8, &boot_token, &starts[0].egress_token);
    const presented = try rt.verifyEgressToken(&starts[0].egress_token);
    try std.testing.expectEqual(ipc.egress_token.Kind.boot, presented.kind);
    try std.testing.expectEqual(@as(u64, 0), presented.request_id);
    try std.testing.expectEqual(@as(u64, 0), presented.request_generation);

    // The warmed handler serves what the boot fetch loaded.
    const body = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 41, specifier, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "post ok"));
}

test "the evaluations of two routes start no more fetches together than the one boot token admits" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // Each route tries a whole token's worth of fetches, one after another,
    // so the two together try twice what the boot token admits and the
    // worker must refuse half of them, whichever route's turn they fall in.
    // The gateway refuses plain HTTP, so a started fetch fails without an
    // origin.
    const limit: usize = comptime @intCast(ipc.WorkerRuntimeBootOptions.default().max_fetches_per_request);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\let refused = 0;
        \\for (let i = 0; i < {d}; i += 1) {{
        \\    try {{
        \\        await fetch("http://127.0.0.1:1/nope");
        \\    }} catch (err) {{
        \\        if (String(err).includes("Failed to schedule fetch")) refused += 1;
        \\    }}
        \\}}
        \\export default function handle() {{
        \\    return String(refused);
        \\}}
    , .{limit});
    defer std.testing.allocator.free(source);
    const first_entry = "/__collo_route/demo/boot-fetches-first.js";
    const second_entry = "/__collo_route/demo/boot-fetches-second.js";
    const pack_fd = try rt.createModulePackGraphFd(&.{
        .{ .specifier = first_entry, .source = source },
        .{ .specifier = second_entry, .source = source },
    }, 0);
    defer std.posix.close(pack_fd);
    _ = try rt.addRoute(&runtime, first_entry);
    _ = try rt.addRoute(&runtime, second_entry);
    try runtime.evaluateBootRoutes(pack_fd, 0, null);
    runtime.sealStartupEvaluations();
    try pumpUntilRouteReady(&runtime, first_entry);
    try pumpUntilRouteReady(&runtime, second_entry);

    var starts: [2 * limit]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(limit, gateway.recordedFetchStarts(&starts));

    const first_body = try serveLate(&runtime, control_pair[1], 91, first_entry);
    defer std.testing.allocator.free(first_body);
    const second_body = try serveLate(&runtime, control_pair[1], 92, second_entry);
    defer std.testing.allocator.free(second_body);
    const refused = try std.fmt.parseInt(usize, first_body, 10) + try std.fmt.parseInt(usize, second_body, 10);
    try std.testing.expectEqual(limit, refused);
}

// The worker writes all sixteen starts before the gateway reads any, and
// signals the command eventfd only for the first: a consumer must read the
// ring to empty after each wake (`notifyAfterPacketWrite` in
// `common/ipc/egress_shared/wake.zig`). A consumer that read one packet per
// wake would strand the other fifteen, and the evaluation would never
// settle.
test "sixteen concurrent top-level fetches all reach the gateway and settle" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The gateway refuses plain HTTP, so each fetch settles without an
    // origin.
    const specifier = "/__collo_route/demo/boot-concurrent-fetches.js";
    const route_fd = try createModulePackFd(specifier,
        \\const settled = await Promise.allSettled(
        \\    Array.from({ length: 16 }, () => fetch("http://127.0.0.1:1/nope")));
        \\export default function handle() {
        \\    return String(settled.filter((outcome) => outcome.status === "rejected").length);
        \\}
    );
    defer std.posix.close(route_fd);
    try bootEvaluate(&runtime, route_fd, specifier);
    try pumpUntilRouteReady(&runtime, specifier);

    var starts: [16]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 16), gateway.recordedFetchStarts(&starts));
    const body = try serveLate(&runtime, control_pair[1], 93, specifier);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("16", body);
}

test "a top-level timer is canceled when its evaluation settles" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/boot-timer.js";
    const route_fd = try createModulePackFd(specifier,
        \\globalThis.__boot_timer = "pending";
        \\setTimeout(() => { globalThis.__boot_timer = "fired"; }, 0);
        \\export default function handle() {
        \\    return globalThis.__boot_timer;
        \\}
    );
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    try pumpUntilRouteReady(&runtime, specifier);

    // The entry settled within its synchronous part, so its evaluation
    // closed then, and the close canceled the timer the evaluation set: no
    // later pass fires it.
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));
    var pass: usize = 0;
    while (pass < 5) : (pass += 1)
        try pumpOnce(&runtime);

    const body = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 51, specifier, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "pending"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "fired"));
}

test "a route's top-level interval ends with its own evaluation while another route's await is pending" {
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

    const ticking_entry = "/__collo_route/demo/boot-ticking.js";
    const pending_entry = "/__collo_route/demo/boot-pending.js";
    const pack_fd = try rt.createModulePackGraphFd(&.{
        .{
            .specifier = ticking_entry,
            .source =
            \\globalThis.__ticks = 0;
            \\setInterval(() => { globalThis.__ticks += 1; }, 1);
            \\export default function handle() {
            \\    return String(globalThis.__ticks);
            \\}
            ,
        },
        .{
            .specifier = pending_entry,
            .source =
            \\await new Promise(() => {});
            \\export default function handle() {
            \\    return "never";
            \\}
            ,
        },
    }, 0);
    defer std.posix.close(pack_fd);
    _ = try rt.addRoute(&runtime, ticking_entry);
    _ = try rt.addRoute(&runtime, pending_entry);
    try runtime.evaluateBootRoutes(pack_fd, 0, null);
    runtime.sealStartupEvaluations();

    // Route 0 settled within its synchronous part, so its evaluation closed
    // and took the interval with it; route 1's evaluation stays open.
    try std.testing.expect(try routeRecord(&runtime, ticking_entry) == .ready);
    try std.testing.expect(try routeRecord(&runtime, pending_entry) == .evaluating);
    try std.testing.expect(!runtime.requests.active.contains(request_context.evaluationId(0)));
    try std.testing.expect(runtime.requests.active.contains(request_context.evaluationId(1)));

    // Time passes well within route 1's budget. A live interval would be due
    // on every pass.
    var pass: usize = 0;
    while (pass < 5) : (pass += 1) {
        now_mono_ns += 2 * std.time.ns_per_ms;
        try pumpOnce(&runtime);
    }
    try std.testing.expect(try routeRecord(&runtime, pending_entry) == .evaluating);

    const body = try serveLate(&runtime, control_pair[1], 91, ticking_entry);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("0", body);
}

test "one route's top-level code cannot clear another route's top-level timer" {
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

    // Both routes run in the main realm, so route 1 sees the id route 0
    // stored on the shared global.
    const owner_entry = "/__collo_route/demo/boot-timer-owner.js";
    const clearer_entry = "/__collo_route/demo/boot-timer-clearer.js";
    const pack_fd = try rt.createModulePackGraphFd(&.{
        .{
            .specifier = owner_entry,
            .source =
            \\globalThis.__fired = "no";
            \\globalThis.__route0Timer = setTimeout(() => { globalThis.__fired = "yes"; }, 5);
            \\await new Promise((resolve) => setTimeout(resolve, 10));
            \\export default function handle() {
            \\    return globalThis.__fired;
            \\}
            ,
        },
        .{
            .specifier = clearer_entry,
            .source =
            \\clearTimeout(globalThis.__route0Timer);
            \\export default function handle() {
            \\    return "cleared";
            \\}
            ,
        },
    }, 0);
    defer std.posix.close(pack_fd);
    _ = try rt.addRoute(&runtime, owner_entry);
    _ = try rt.addRoute(&runtime, clearer_entry);
    try runtime.evaluateBootRoutes(pack_fd, 0, null);
    runtime.sealStartupEvaluations();
    try std.testing.expect(try routeRecord(&runtime, owner_entry) == .evaluating);
    try std.testing.expect(try routeRecord(&runtime, clearer_entry) == .ready);

    // Both of route 0's timers come due; its await settles after the first
    // timer ran.
    now_mono_ns = 20 * std.time.ns_per_ms;
    try pumpUntilRouteReady(&runtime, owner_entry);

    const body = try serveLate(&runtime, control_pair[1], 92, owner_entry);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("yes", body);
}

test "a fire-and-forget top-level fetch is canceled when its evaluation settles" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/boot-fire-and-forget.js";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\globalThis.__boot_ff = "pending";
        \\fetch("http://{s}:{d}/data", {{
        \\    method: "POST",
        \\    headers: {{ "x-collo-test": "yes" }},
        \\    body: new Uint8Array([112, 97, 121, 108, 111, 97, 100])
        \\}}).then((res) => res.text()).then((text) => {{
        \\    globalThis.__boot_ff = text;
        \\}}).catch((err) => {{
        \\    globalThis.__boot_ff = "error:" + String(err);
        \\}});
        \\export default function handle() {{
        \\    return globalThis.__boot_ff;
        \\}}
    , .{ origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const route_fd = try createModulePackFd(specifier, source);
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);

    // Without a top-level await the module settles synchronously, and the
    // evaluation's close reaps the fetch started during it while it is in
    // flight, telling the gateway to drop it.
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .ready);
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));

    // With the task reaped, a gateway packet that still arrives for the fetch
    // finds no task and is dropped natively; not even an abort rejection
    // runs, so the promise never settles and its `.then` and `.catch` never
    // run. The close reaps synchronously, so the loop never iterates: it is a
    // guard that fails only when a task outlives the close for 2000 passes.
    // The passes after it collect any late packet, and the probe catches a
    // task that survived the close and then delivered its body.
    var attempt: usize = 0;
    while (runtime.egress.state.tasks.count() != 0) : (attempt += 1) {
        if (attempt > 2000)
            return error.CanceledBootFetchNeverReaped;
        try pumpOnce(&runtime);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    var pass: usize = 0;
    while (pass < 20) : (pass += 1)
        try pumpOnce(&runtime);
    const body = try rt.runRegisteredRouteAndReadBody(
        &runtime,
        control_pair[1],
        900,
        specifier,
        .{},
    );
    defer std.testing.allocator.free(body);
    if (std.mem.containsAtLeast(u8, body, 1, "post ok"))
        return error.CanceledBootFetchDelivered;
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "pending"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "error:"));
}

test "an evaluation under the none boot token gives top-level code timers and refuses fetch with a TypeError in the worker" {
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
    // A granted launch whose worker got no session sends its wake
    // descriptors with the none boot token (`LaunchEgress.detached` in
    // `host/launch.zig`), which `RuntimeOptions` defaults to.
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // Awaiting the fetch catches its refusal whether it throws or returns a
    // rejected promise.
    const specifier = "/__collo_route/demo/boot-no-token.js";
    const route_fd = try createModulePackFd(specifier,
        \\globalThis.__boot_fetch = "unset";
        \\try {
        \\    await fetch("https://example.test/");
        \\    globalThis.__boot_fetch = "fetched";
        \\} catch (err) {
        \\    globalThis.__boot_fetch = err instanceof TypeError ? "TypeError: " + err.message : "other " + String(err);
        \\}
        \\await new Promise((resolve) => setTimeout(resolve, 0));
        \\globalThis.__boot_timer = "fired";
        \\export default function handle() {
        \\    return globalThis.__boot_timer + " " + globalThis.__boot_fetch;
        \\}
    );
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    // The evaluation still exists, for timers.
    const evaluation = runtime.requests.active.get(first_evaluation_id) orelse
        return error.MissingEvaluation;
    try std.testing.expect(ipc.egress_token.isNone(&evaluation.dispatch_work.egress_token));
    try pumpUntilRouteReady(&runtime, specifier);

    const body = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 62, specifier, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        body,
        1,
        "fired TypeError: fetch failed: the request has no egress token",
    ));

    // The worker refused the fetch before it left, so the gateway, which
    // would count a token that fails verification against the worker's
    // session, saw nothing.
    var starts: [1]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 0), gateway.recordedFetchStarts(&starts));
}

// A worker whose definition grants no network access gets no egress
// descriptor, and top-level code is no exception: its fetch gets the same
// denial a handler's does, and the line names no request, since an
// evaluation's reserved id names nothing the server knows.
test "top-level code of a worker without a network grant gets the network setting's denial, logged once under request id 0" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
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

    const specifier = "/__collo_route/demo/boot-no-grant.js";
    const route_fd = try createModulePackFd(specifier,
        \\let outcome = "unset";
        \\try {
        \\    await fetch("https://example.test/");
        \\    outcome = "fetched";
        \\} catch (err) {
        \\    outcome = (err instanceof TypeError ? "TypeError: " : "other: ") + err.message;
        \\}
        \\export default function handle() {
        \\    return outcome;
        \\}
    );
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    try pumpUntilRouteReady(&runtime, specifier);
    try expectStartupEnded(&runtime, true);

    const denial = "fetch to https://example.test denied by the network setting: no network setting grants access to this route";
    const body = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 63, specifier, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "TypeError: " ++ denial));

    var scratch: [4 * worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var lines: [4]worker_shared_page.DrainedLogLine = undefined;
    const count = try completion_fixture.view.drainLogLinesChecked(&scratch, &lines);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@intFromEnum(worker_shared_page.LogLevel.warn), lines[0].header.level);
    try std.testing.expectEqual(@as(u64, 0), lines[0].header.request_id);
    try std.testing.expectEqualStrings(denial, lines[0].payload);
}

test "a worker whose only route failed on an await sends worker_retiring once and goes on serving until its control socket closes" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/boot-hung.js";
    const route_fd = try createModulePackFd(specifier,
        \\await new Promise(() => {});
        \\export default function handle() {
        \\    return "unreachable";
        \\}
    );
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    const evaluation = runtime.requests.active.get(first_evaluation_id) orelse
        return error.MissingEvaluation;
    try std.testing.expect(evaluation.deadline_armed);

    // With no request waiting, the evaluation's armed budget is the one wake
    // guaranteed to notice the await that never settles.
    now_mono_ns = module_eval_budget_ns + std.time.ns_per_ms;
    try pumpOnce(&runtime);

    // The route is pinned failed, and its evaluation closed instead of
    // reaching the response path.
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .failed);
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));
    // No frame was sent for the evaluation.
    try expectControlSilent(control_pair[1], 25);

    // The worker's only route can no longer serve, and a fresh worker might
    // get past the await, so the loop's check asks the server to retire it,
    // once. Before, the loop stopped itself and the worker exited.
    try std.testing.expect(runtime.modules.state.fresh_worker_may_serve);
    try runtime.checkRetirement();
    try std.testing.expectEqual(ipc.WorkerRetiringReason.routes_failed, try retirement_notice.read(control_pair[1]));
    try runtime.checkRetirement();
    try retirement_notice.expectNone(control_pair[1]);
    try std.testing.expect(runtime.core.running);

    // The worker keeps reading begins and answers one that arrives after
    // the notice with 503, without running the route.
    try enqueueRoute(&runtime, 72, specifier, "/after-notice");
    try executeUntilRequestDone(&runtime, 72);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 72);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 503), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.worker_retiring, response.doneStatus());
    try std.testing.expect(runtime.core.running);
}

test "an evaluation's budget deadline after its settlement is a no-op" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/boot-gated.js";
    const route_fd = try createModulePackFd(specifier,
        \\const gate = new Promise((resolve) => { globalThis.__resolveBootGate = resolve; });
        \\await gate;
        \\export default function handle() {
        \\    return "settled";
        \\}
    );
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    const evaluation = runtime.requests.active.get(first_evaluation_id) orelse
        return error.MissingEvaluation;
    try std.testing.expect(evaluation.deadline_armed);

    try support.registerModule(&vm, "/boot-gate-resolve.js",
        \\globalThis.__resolveBootGate();
        \\export default 1;
    );
    try support.evaluateOk(&vm, "/boot-gate-resolve.js");
    runtime.collectModuleSettlements();

    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .ready);
    // The settlement's close disarmed the budget and destroyed the context,
    // so the deadline entry already queued finds no owner and does nothing.
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));

    // The instant the budget was armed for passes, and nothing happens.
    now_mono_ns = module_eval_budget_ns + std.time.ns_per_ms;
    try pumpOnce(&runtime);
    try std.testing.expect(runtime.core.running);
    try expectControlSilent(control_pair[1], 25);
}

test "a failed boot evaluation answers its waiters with the worker's 500, then the worker asks to retire" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/boot-reject.js";
    const route_fd = try createModulePackFd(specifier,
        \\const gate = new Promise((resolve, reject) => { globalThis.__rejectBootGate = reject; });
        \\await gate;
        \\export default function handle() {
        \\    return "unreachable";
        \\}
    );
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    try std.testing.expect(runtime.requests.active.contains(first_evaluation_id));

    // A request that arrives during evaluation waits on it.
    try enqueueRoute(&runtime, 71, specifier, "/boot-fail");
    try executeNextReady(&runtime);
    try std.testing.expect(runtime.requests.active.contains(71));

    try support.registerModule(&vm, "/boot-gate-reject.js",
        \\globalThis.__rejectBootGate(new Error("boot boom"));
        \\export default 1;
    );
    try support.evaluateOk(&vm, "/boot-gate-reject.js");
    runtime.collectModuleSettlements();

    // The failure stays with the module, and a fresh worker may serve; the
    // failed settlement also closed and destroyed the evaluation.
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .failed);
    try std.testing.expect(runtime.modules.state.fresh_worker_may_serve);
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));

    // The waiter, whose begin came before any notice, gets its own 500 from
    // the worker: the failed record refuses it with
    // `error.RouteModuleEvaluationFailed`, which ends it as an internal
    // error.
    try executeUntilRequestDone(&runtime, 71);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 71);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 500), response.status);

    // The worker asks to retire and stays in its loop; the server retires it.
    try runtime.checkRetirement();
    try std.testing.expectEqual(ipc.WorkerRetiringReason.routes_failed, try retirement_notice.read(control_pair[1]));
    try std.testing.expect(runtime.core.running);
}

test "a top-level import() at boot loads a packed module and refuses a missing one without a packet" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/boot-lazy-import.js";
    const route_fd = try rt.createModulePackGraphFd(&.{
        .{
            .specifier = specifier,
            .source =
            \\const packed = await import("./boot-packed.js");
            \\let missing = "loaded";
            \\try {
            \\    await import("./boot-missing.js");
            \\} catch (err) {
            \\    missing = "denied";
            \\}
            \\globalThis.__boot_import = packed.answer + "|" + missing;
            \\export default function handle() {
            \\    return globalThis.__boot_import;
            \\}
            ,
        },
        .{ .specifier = "/__collo_route/demo/boot-packed.js", .source = "export const answer = 'packed';" },
    }, 0);
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    try pumpUntilRouteReady(&runtime, specifier);

    // Both imports settled from the registered pack: nothing crossed the
    // control socket.
    try expectControlSilent(control_pair[1], 25);

    const body = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 81, specifier, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "packed|denied"));
    // The settlement closed the evaluation.
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));
}

test "chokepoint guards drop response-path work for an evaluation" {
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
        .boot_egress_token = rt.bootEgressToken(boot_window_end_ns),
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // An await that never settles keeps the route's evaluation open.
    const specifier = "/__collo_route/demo/boot-chokepoint.js";
    const route_fd = try createModulePackFd(specifier,
        \\await new Promise(() => {});
        \\export default function handle() {
        \\    return "unreachable";
        \\}
    );
    defer std.posix.close(route_fd);
    try bootEvaluate(&runtime, route_fd, specifier);
    const evaluation = runtime.requests.active.get(first_evaluation_id) orelse
        return error.MissingEvaluation;

    // A failure of the evaluation's work, which `requestFailureCallback` can
    // report (for example when building a fetch response runs out of
    // memory), is dropped: no frame is sent, no record published and the
    // evaluation survives.
    worker.testing.request_dispatch.handleLocalFailure(&runtime, first_evaluation_id, error.TestChokepointFailure);
    try std.testing.expect(runtime.requests.active.contains(first_evaluation_id));
    try std.testing.expect(!evaluation.finish_started);
    try std.testing.expect(runtime.core.running);

    // `finishRequest` refuses an evaluation outright.
    try std.testing.expectError(
        error.InvalidArgument,
        worker.testing.response_finish.finishRequest(&runtime, evaluation, .internal_error, 500),
    );
    try std.testing.expect(!evaluation.finish_started);
    try std.testing.expect(runtime.requests.active.contains(first_evaluation_id));

    // A deadline call before the evaluation's budget expires nothing and
    // leaves it open and armed.
    try worker.testing.request_dispatch.deadlineTimeout(&runtime, first_evaluation_id);
    try std.testing.expect(runtime.core.running);
    try std.testing.expect(runtime.requests.active.contains(first_evaluation_id));
    try std.testing.expect(evaluation.deadline_armed);

    // Nothing is left on the control socket.
    try expectControlSilent(control_pair[1], 25);
}

test "teardown with an in-flight boot fetch reaps cleanly" {
    // A listener that completes handshakes from its backlog but never
    // accepts: the boot fetch connects, sends, and stalls in flight.
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
    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
        .boot_egress_token = boot_token,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/boot-teardown.js";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\fetch("http://{s}:{d}/hang").catch(() => {{}});
        \\export default function handle() {{
        \\    return "up";
        \\}}
    , .{ host, silent_server.listen_address.getPort() });
    defer std.testing.allocator.free(source);
    const route_fd = try createModulePackFd(specifier, source);
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .ready);

    // Wait until the FetchStart crossed the wire: the gateway then holds a
    // fetch against a peer that never answers.
    var attempts: usize = 0;
    var starts: [1]rt.FetchStartIdentity = undefined;
    while (gateway.recordedFetchStarts(&starts) == 0) : (attempts += 1) {
        if (attempts > 2000)
            return error.BootFetchNeverStarted;
        try pumpOnce(&runtime);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqualSlices(u8, &boot_token, &starts[0].egress_token);

    // The synchronous close destroyed the evaluation and reaped its fetch
    // task, so the worker holds nothing of the fetch while the gateway may
    // still be serving it. Teardown runs in that state, and the gateway
    // reaps the session on detach or deinit. The allocator's leak check and
    // the gateway thread's panic on error are the assertions.
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));
}

test "a closed evaluation runs none of its JavaScript again and presents the boot token no more" {
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
    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
        .boot_egress_token = boot_token,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // A rejection of the boot fetch is the only JavaScript of the evaluation
    // that could still run after its close. The `.catch` below tries a
    // timer, a fetch and an import, so the probes show whether it ever got a
    // turn.
    const specifier = "/__collo_route/demo/boot-close-deny.js";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\globalThis.__done = "unset";
        \\globalThis.__timer = "unset";
        \\globalThis.__fetch = "unset";
        \\globalThis.__import = "unset";
        \\fetch("http://{s}:{d}/data", {{
        \\    method: "POST",
        \\    headers: {{ "x-collo-test": "yes" }},
        \\    body: new Uint8Array([1])
        \\}}).then(() => {{
        \\    globalThis.__done = "delivered";
        \\}}).catch(() => {{
        \\    try {{
        \\        setTimeout(() => {{ globalThis.__timer = "fired"; }}, 0);
        \\        globalThis.__timer = "scheduled";
        \\    }} catch (err) {{
        \\        globalThis.__timer = "denied";
        \\    }}
        \\    try {{
        \\        fetch("http://{s}:{d}/again").then(() => {{
        \\            globalThis.__fetch = "ok";
        \\        }}, () => {{
        \\            globalThis.__fetch = "denied";
        \\        }});
        \\        if (globalThis.__fetch === "unset") globalThis.__fetch = "scheduled";
        \\    }} catch (err) {{
        \\        globalThis.__fetch = "denied";
        \\    }}
        \\    import("./boot-close-lazy.js").then(() => {{
        \\        globalThis.__import = "ok";
        \\    }}, () => {{
        \\        globalThis.__import = "denied";
        \\    }});
        \\    globalThis.__done = "swept";
        \\}});
        \\export default function handle() {{
        \\    return [globalThis.__done, globalThis.__timer, globalThis.__fetch, globalThis.__import].join("|");
        \\}}
    , .{ origin.host(), origin.port, origin.host(), origin.port });
    defer std.testing.allocator.free(source);
    const route_fd = try createModulePackFd(specifier, source);
    defer std.posix.close(route_fd);

    try bootEvaluate(&runtime, route_fd, specifier);
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .ready);
    // The settlement was synchronous: the evaluation is closed and its
    // context destroyed, so its copy of the boot token is gone and nothing
    // under its id remains in the active map.
    try std.testing.expect(!runtime.requests.active.contains(first_evaluation_id));

    // The close reaped the fetch task, so a gateway packet for it is dropped
    // natively: the `.then` never runs and neither does the `.catch` with
    // every probe inside it.
    var attempt: usize = 0;
    while (runtime.egress.state.tasks.count() != 0) : (attempt += 1) {
        if (attempt > 2000)
            return error.CanceledBootFetchNeverReaped;
        try pumpOnce(&runtime);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    var pass: usize = 0;
    while (pass < 20) : (pass += 1)
        try pumpOnce(&runtime);
    const body = try rt.runRegisteredRouteAndReadBody(
        &runtime,
        control_pair[1],
        700,
        specifier,
        .{},
    );
    defer std.testing.allocator.free(body);
    if (std.mem.containsAtLeast(u8, body, 1, "delivered"))
        return error.CanceledBootFetchDelivered;
    // All four probes are unset: none of the evaluation's JavaScript ran
    // after the close, refused or otherwise.
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 4, "unset"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "swept"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "scheduled"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "denied"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "ok"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "fired"));

    // Only the FetchStart from before the close crossed the wire, under the
    // boot token; the evaluation's copy is gone, so nothing new followed.
    var starts: [4]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 1), gateway.recordedFetchStarts(&starts));
    try std.testing.expectEqualSlices(u8, &boot_token, &starts[0].egress_token);
}
