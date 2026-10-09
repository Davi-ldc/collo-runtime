//! Covers the boot context, under which module top-level code may fetch and
//! set timers: its install with WorkerInit's boot token, which every fetch of
//! module top-level code presents, the evaluation budget, the close when the
//! route's evaluation settles, the refusal of anything under its id afterwards
//! or when it was never installed, and the refusal of fetch alone, with a
//! TypeError and before anything leaves the worker, when the boot token is
//! `none`. A top-level `import()` loads from the registered pack and sends
//! nothing to the server. Each test boots one route; a table of several, and
//! the context held open until the last of them settles, are covered in
//! `routes.zig`. Runs in `worker-test`.
//!
//! These tests drive the worker side end to end (install, evaluate, settle,
//! serve). The `LocalEgressGateway` harness submits straight to the engine
//! and runs no admission. The gateway's admission of a boot token, refused
//! past the child window and after its `request_ended`, is covered in
//! `egress/tests/gateway/worker_flow.zig`; the recorded FetchStart tokens join
//! the two, since what the worker puts on the wire is what that test admits.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const local_address = @import("collo_test_net");

const fakeNow = rt.fakeNow;
const socketPairType = rt.socketPairType;
const createModulePackFd = rt.createModulePackFd;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;
const LocalOrigin = rt.LocalOrigin;

const boot_request_id = @import("collo_worker_request").context.boot_request_id;
const module_eval_budget_ns = worker.testing.module_routes.module_eval_budget_ns;

/// The end of the child window the boot tokens below carry. The worker
/// copies a token without reading it, so any instant on the fake clock
/// serves.
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
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
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

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    const boot_ctx = runtime.bootContext() orelse return error.MissingBootContext;

    // These fields differ from a dispatched request's, each for the reason
    // `RequestContext.initBoot` gives. The context keeps its own copy of the
    // boot token.
    try std.testing.expectEqual(boot_request_id, boot_ctx.exec.request_id);
    try std.testing.expectEqual(@as(u64, 0), boot_ctx.request_generation);
    try std.testing.expect(boot_ctx.dispatch_started);
    try std.testing.expect(boot_ctx.live_slot_released);
    try std.testing.expectEqual(@as(u64, 0), boot_ctx.exec.deadline_monotonic_ns);
    try std.testing.expectEqualSlices(u8, &boot_token, &boot_ctx.dispatch_work.egress_token);

    try bootEvaluate(&runtime, route_fd, specifier);
    // A top-level await is in flight, so the evaluation budget is armed.
    try std.testing.expect(boot_ctx.deadline_armed);
    try std.testing.expectEqual(now_mono_ns + module_eval_budget_ns, boot_ctx.exec.deadline_monotonic_ns);

    try pumpUntilRouteReady(&runtime, specifier);

    // The settlement destroyed the boot context, so no deadline, identity or
    // byte count of it outlives the close.
    try std.testing.expect(runtime.boot_ctx == .closed);
    try std.testing.expect(runtime.bootContext() == null);

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

    // Nothing under the boot id remains in the active map after the close.
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
}

test "boot top-level timer is canceled when the root entry settles" {
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

    const specifier = "/__collo_route/demo/boot-timer.js";
    const route_fd = try createModulePackFd(specifier,
        \\globalThis.__boot_timer = "pending";
        \\setTimeout(() => { globalThis.__boot_timer = "fired"; }, 0);
        \\export default function handle() {
        \\    return globalThis.__boot_timer;
        \\}
    );
    defer std.posix.close(route_fd);

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    try bootEvaluate(&runtime, route_fd, specifier);
    try pumpUntilRouteReady(&runtime, specifier);
    try std.testing.expect(runtime.boot_ctx == .closed);

    // The synchronous settlement closed the boot context, and its sweep
    // canceled the timer set during evaluation, so no later pass fires it.
    var pass: usize = 0;
    while (pass < 5) : (pass += 1)
        try pumpOnce(&runtime);

    const body = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 51, specifier, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "pending"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "fired"));
    // The close destroyed the context itself.
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
}

test "boot fire-and-forget fetch is canceled when the root entry settles" {
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

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    try bootEvaluate(&runtime, route_fd, specifier);

    // Without a top-level await the module settles synchronously, and the
    // close reaps the fetch started during evaluation while it is in flight,
    // telling the gateway to drop it.
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .ready);
    try std.testing.expect(runtime.boot_ctx == .closed);

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
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
}

test "top-level fetch without an installed boot context stays denied" {
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

    const specifier = "/__collo_route/demo/boot-denied.js";
    const route_fd = try createModulePackFd(specifier,
        \\globalThis.__boot_fetch_err = "none";
        \\try {
        \\    fetch("https://example.test/");
        \\} catch (err) {
        \\    globalThis.__boot_fetch_err = String(err);
        \\}
        \\export default function handle() {
        \\    return globalThis.__boot_fetch_err;
        \\}
    );
    defer std.posix.close(route_fd);

    // No boot context was installed, as for a launch that does not serve
    // routes, so the VM refuses top-level host calls.
    try std.testing.expect(runtime.bootContext() == null);
    try bootEvaluate(&runtime, route_fd, specifier);

    const body = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 61, specifier, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "active request turn"));

    // Nothing crossed the egress wire.
    var starts: [1]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 0), gateway.recordedFetchStarts(&starts));
}

test "a boot context with the none boot token gives top-level code timers and refuses fetch with a TypeError in the worker" {
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

    // A launch without an egress grant sends WorkerInit with the none boot
    // token (`host/launch.zig`). The context still exists, for timers.
    try runtime.installBootContext(&ipc.egress_token.none);
    const boot_ctx = runtime.bootContext() orelse return error.MissingBootContext;
    try std.testing.expect(ipc.egress_token.isNone(&boot_ctx.dispatch_work.egress_token));
    try bootEvaluate(&runtime, route_fd, specifier);
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

test "a hung top-level await in a worker's only route fails it at the eval budget and recycles the worker after the drain" {
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

    const specifier = "/__collo_route/demo/boot-hung.js";
    const route_fd = try createModulePackFd(specifier,
        \\await new Promise(() => {});
        \\export default function handle() {
        \\    return "unreachable";
        \\}
    );
    defer std.posix.close(route_fd);

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    const boot_ctx = runtime.bootContext() orelse return error.MissingBootContext;
    try bootEvaluate(&runtime, route_fd, specifier);
    try std.testing.expect(boot_ctx.deadline_armed);

    // With no request waiting, the boot context's armed budget is the one
    // wake guaranteed to notice the evaluation that never settles.
    now_mono_ns = module_eval_budget_ns + std.time.ns_per_ms;
    try pumpOnce(&runtime);

    // The route is pinned failed, and with no evaluation left the boot
    // context closed instead of reaching the response path.
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .failed);
    try std.testing.expect(runtime.boot_ctx == .closed);
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
    // No frame was sent for the boot id.
    try expectControlSilent(control_pair[1], 25);

    // The worker's only route can no longer serve, and a fresh worker might
    // get past the await, so the loop stops it once nothing is left to drain.
    try std.testing.expect(runtime.modules.state.recycle_after_drain);
    try std.testing.expect(runtime.core.running);
    runtime.maybeRecycleAfterFailedEvaluation();
    try std.testing.expect(!runtime.core.running);
}

test "eval-budget deadline after settlement is a no-op" {
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

    const specifier = "/__collo_route/demo/boot-gated.js";
    const route_fd = try createModulePackFd(specifier,
        \\const gate = new Promise((resolve) => { globalThis.__resolveBootGate = resolve; });
        \\await gate;
        \\export default function handle() {
        \\    return "settled";
        \\}
    );
    defer std.posix.close(route_fd);

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    const boot_ctx = runtime.bootContext() orelse return error.MissingBootContext;
    try bootEvaluate(&runtime, route_fd, specifier);
    try std.testing.expect(boot_ctx.deadline_armed);

    try support.registerModule(&vm, "/boot-gate-resolve.js",
        \\globalThis.__resolveBootGate();
        \\export default 1;
    );
    try support.evaluateOk(&vm, "/boot-gate-resolve.js");
    runtime.collectModuleSettlements();

    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .ready);
    // The settlement's close disarmed the budget and destroyed the context,
    // so the deadline entry already queued finds no request and does nothing.
    try std.testing.expect(runtime.boot_ctx == .closed);
    try std.testing.expect(runtime.bootContext() == null);

    // The instant the budget was armed for passes, and nothing happens.
    now_mono_ns = module_eval_budget_ns + std.time.ns_per_ms;
    try pumpOnce(&runtime);
    try std.testing.expect(runtime.core.running);
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
    try expectControlSilent(control_pair[1], 25);
}

test "failed boot evaluation drains waiters with worker-side 500 then recycles" {
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

    const specifier = "/__collo_route/demo/boot-reject.js";
    const route_fd = try createModulePackFd(specifier,
        \\const gate = new Promise((resolve, reject) => { globalThis.__rejectBootGate = reject; });
        \\await gate;
        \\export default function handle() {
        \\    return "unreachable";
        \\}
    );
    defer std.posix.close(route_fd);

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    try std.testing.expect(runtime.bootContext() != null);
    try bootEvaluate(&runtime, route_fd, specifier);

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

    // The failure stays with the module and the recycle after the drain is
    // armed; the failed settlement also closed and destroyed the boot
    // context.
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .failed);
    try std.testing.expect(runtime.modules.state.recycle_after_drain);
    try std.testing.expect(runtime.boot_ctx == .closed);
    try std.testing.expect(runtime.bootContext() == null);

    // The waiter gets its own 500 from the worker: the failed record refuses
    // it with `error.RouteModuleEvaluationFailed`, which ends it as an
    // internal error. Recycling before the drain would have left the request
    // to a record the server synthesizes
    // (`server/supervisor/usage_drain.zig`).
    try executeUntilRequestDone(&runtime, 71);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], 71);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 500), response.status);

    // The loop recycles the worker only after the drain; the boot id already
    // left the active map with the close.
    runtime.maybeRecycleAfterFailedEvaluation();
    try std.testing.expect(!runtime.core.running);
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
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

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    try bootEvaluate(&runtime, route_fd, specifier);
    try pumpUntilRouteReady(&runtime, specifier);

    // Both imports settled from the registered pack: nothing crossed the
    // control socket.
    try expectControlSilent(control_pair[1], 25);

    const body = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 81, specifier, .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "packed|denied"));
    // The settlement's close destroyed the boot context.
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
}

test "chokepoint guards drop response-path work for the boot context" {
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

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    const boot_ctx = runtime.bootContext() orelse return error.MissingBootContext;

    // A failure of boot work, which `requestFailureCallback` can report (for
    // example when building a fetch response runs out of memory), is dropped:
    // no frame is sent, no record published and the boot context survives.
    worker.testing.request_dispatch.handleLocalFailure(&runtime, boot_request_id, error.TestChokepointFailure);
    try std.testing.expect(runtime.requests.active.contains(boot_request_id));
    try std.testing.expect(!boot_ctx.finish_started);
    try std.testing.expect(runtime.core.running);

    // `finishRequest` refuses the boot context outright.
    try std.testing.expectError(
        error.InvalidArgument,
        worker.testing.response_finish.finishRequest(&runtime, boot_ctx, .internal_error, 500),
    );
    try std.testing.expect(!boot_ctx.finish_started);
    try std.testing.expect(runtime.requests.active.contains(boot_request_id));

    // An unarmed deadline call for the boot id is a no-op.
    try worker.testing.request_dispatch.deadlineTimeout(&runtime, boot_request_id);
    try std.testing.expect(runtime.core.running);
    try std.testing.expect(runtime.requests.active.contains(boot_request_id));

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
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
        .egress_shared_fds = &egress_shared_fds,
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

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
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

    // The synchronous close destroyed the boot context and reaped its fetch
    // task, so the worker holds nothing of the fetch while the gateway may
    // still be serving it. Teardown runs in that state, and the gateway
    // reaps the session on detach or deinit. The allocator's leak check and
    // the gateway thread's panic on error are the assertions.
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
}

test "closed boot context denies surviving-reference scheduling and the boot token" {
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

    // A rejection of the boot fetch is the only JavaScript that could still
    // run under the boot id after the close. The `.catch` below tries a
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

    const boot_token = rt.bootEgressToken(boot_window_end_ns);
    try runtime.installBootContext(&boot_token);
    try bootEvaluate(&runtime, route_fd, specifier);
    const record = try routeRecord(&runtime, specifier);
    try std.testing.expect(record == .ready);
    // The settlement was synchronous: the state is closed and the context
    // destroyed, so the worker's copy of the boot token is gone and nothing
    // under the boot id remains in the active map.
    try std.testing.expect(runtime.boot_ctx == .closed);
    try std.testing.expect(!runtime.requests.active.contains(boot_request_id));
    try std.testing.expect(runtime.bootContext() == null);

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
    // All four probes are unset: no boot JavaScript ran after the close,
    // refused or otherwise.
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 4, "unset"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "swept"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "scheduled"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "denied"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "ok"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, body, 1, "fired"));

    // Only the FetchStart from before the close crossed the wire, under the
    // boot token; the worker holds no boot token any more, so nothing new
    // followed.
    var starts: [4]rt.FetchStartIdentity = undefined;
    try std.testing.expectEqual(@as(usize, 1), gateway.recordedFetchStarts(&starts));
    try std.testing.expectEqualSlices(u8, &boot_token, &starts[0].egress_token);
}
