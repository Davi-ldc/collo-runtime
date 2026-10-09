//! Covers asynchronous WebAssembly settlement in the worker runtime. JSC
//! settles the promises of `WebAssembly.instantiate` and `compile` through
//! its DeferredWorkTimer, which needs a RunLoop a worker never runs, so the
//! settle runs only when the loop calls `pumpDeferredWork`
//! (`scheduler/loop.zig`). These tests call that same pump between the
//! harness's collect passes, so the path is the loop's without the ring
//! wait. The wake side, the wakeup eventfd and the backstop deadline, needs
//! the real loop of a forked worker, which `zygote-integration` covers. Runs
//! in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const socketPairType = rt.socketPairType;

/// The 41-byte module
/// `(module (func (export "add") (param i32 i32) (result i32)
///   local.get 0 local.get 1 i32.add))`,
/// as a JavaScript expression the route sources embed.
const wasm_add_module_js_bytes =
    \\Uint8Array.from([
    \\    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    \\    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    \\    0x03, 0x02, 0x01, 0x00,
    \\    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
    \\    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
    \\])
;

/// The harness's default deadline (`DispatchParts.deadline_monotonic_ns`),
/// an absolute instant on the fake clock. It cannot fire while a drive keeps
/// the clock at 0.
const default_request_deadline_ns: u64 = 10_000;

fn enqueueWasmRoute(
    runtime: *worker.Runtime,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
    deadline_monotonic_ns: u64,
) !void {
    const route_specifier = try rt.routeSpecifier(std.testing.allocator, specifier);
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(runtime, route_specifier, source);

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = deadline_monotonic_ns,
        .request = .{},
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, 1, .{});
}

/// `collectFast` in `scheduler/loop.zig` without the backlog drain and the
/// ingress, request completion and fs fault rescans, which only recover work
/// a full ready queue turned away; these tests never fill it.
fn collectPass(runtime: *worker.Runtime) !void {
    runtime.collectModuleSettlements();
    try runtime.collectCompletedCryptoJobs();
    try runtime.collectCompletedFetches();
    try runtime.collectReadyFetchBodies();
    try runtime.collectDueTimers();
    try runtime.collectReadyImmediates();
    try runtime.collectDueRequestDeadlines();
}

/// Runs a route to completion as the harness's `executeUntilRequestDone`
/// does, with the loop's pump added: the compile finishes on the wasm
/// worklist thread, and only a pump pass runs the settle it queues. Each
/// pass keeps the loop's order of collect, pump, then one ready work item.
/// The caller owns the returned response body.
fn runWasmRouteAndReadBody(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
) ![]u8 {
    try enqueueWasmRoute(runtime, source, request_id, specifier, default_request_deadline_ns);

    var host_pump_exec_ctx = support.makeExecCtx(0);
    var pending_imminent = false;
    var attempts: usize = 0;
    while (runtime.requests.active.contains(request_id)) : (attempts += 1) {
        if (attempts > 1000)
            return error.RequestDidNotComplete;
        try collectPass(runtime);
        pending_imminent = worker.testing.scheduler.loop.pumpDeferredWork(
            runtime,
            &host_pump_exec_ctx,
            pending_imminent,
        );
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker.testing.executeWorkItem(runtime, item);
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }

    return rt.readIngressResponseBody(runtime, server_control_fd, request_id);
}

fn expectBodyContains(body: []const u8, expected: []const u8) !void {
    if (!std.mem.containsAtLeast(u8, body, 1, expected)) {
        std.debug.print("expected response body to contain: {s}\nactual body:\n{s}\n", .{ expected, body });
        return error.TestUnexpectedResult;
    }
}

test "await WebAssembly.instantiate settles through the pump and serves 200" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const bytes = {s};
        \\    const {{ instance }} = await WebAssembly.instantiate(bytes);
        \\    return Response.json({{
        \\        sum: instance.exports.add(19, 23),
        \\        streaming: typeof WebAssembly.instantiateStreaming,
        \\    }});
        \\}}
    , .{wasm_add_module_js_bytes});
    defer std.testing.allocator.free(source);

    const body = try runWasmRouteAndReadBody(&runtime, control_pair[1], source, 20, "/wasm-200.js");
    defer std.testing.allocator.free(body);
    try expectBodyContains(body, "\"sum\":42");
    // The global object's method table (`bindings/jsc/runtime/global_object.cpp`)
    // leaves the `compileStreaming` and `instantiateStreaming` hooks null, so
    // the engine defines neither function and user code sees `undefined`.
    try expectBodyContains(body, "\"streaming\":\"undefined\"");
}

test "WebAssembly.compile then instantiate settles both promises through the pump" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\export default async function handle() {{
        \\    const bytes = {s};
        \\    const module = await WebAssembly.compile(bytes);
        \\    const instance = await WebAssembly.instantiate(module);
        \\    return Response.json({{ sum: instance.exports.add(40, 2) }});
        \\}}
    , .{wasm_add_module_js_bytes});
    defer std.testing.allocator.free(source);

    const body = try runWasmRouteAndReadBody(&runtime, control_pair[1], source, 21, "/wasm-compile-instantiate.js");
    defer std.testing.allocator.free(body);
    try expectBodyContains(body, "\"sum\":42");
}

test "boot fire-and-forget instantiate settles posthumously in a host window, not on a live request" {
    // A WebAssembly ticket has no request owner. `closeBootContext` sweeps
    // only what is registered under the boot id, so the boot context's close
    // does not cancel it, and JSC never does either, because the global
    // object reports its script execution status as always running. An
    // instantiate that module top-level code starts therefore settles later
    // through the pump. With no boot context, that settle must run as
    // a request-less turn with owner 0 even when an unrelated request is the
    // only live one, instead of spending that request's turn, deadline and
    // CPU. The case where the boot context still exists and owns the settle
    // is not covered here.
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // The wakeup gate is installed reporting work once
    // (`collo_vm_deferred_work_scheduled` in `bindings/jsc/runtime/vm.cpp`).
    // Consuming that report here makes the wait below see a real schedule.
    _ = runtime.core.vm.deferredWorkScheduled();

    // Top-level code starts the instantiate without awaiting it, so the
    // module settles at once and the wasm promise is still in flight while
    // requests run.
    const boot_source = try std.fmt.allocPrint(std.testing.allocator,
        \\const bytes = {s};
        \\globalThis.bootWasm = "pending";
        \\WebAssembly.instantiate(bytes).then(
        \\    () => {{ globalThis.bootWasm = "settled"; }},
        \\    () => {{ globalThis.bootWasm = "rejected"; }},
        \\);
        \\export default async function handle() {{
        \\    return Response.json({{ ok: true, bootWasm: globalThis.bootWasm }});
        \\}}
    , .{wasm_add_module_js_bytes});
    defer std.testing.allocator.free(boot_source);

    // The first request runs without the pump. Only a pump pass can run the
    // settle, so its response reads "pending" every time, and the ticket in
    // flight does not hold up serving.
    try enqueueWasmRoute(&runtime, boot_source, 22, "/wasm-boot-posthumous.js", default_request_deadline_ns);
    var attempts: usize = 0;
    while (runtime.requests.active.contains(22)) : (attempts += 1) {
        if (attempts > 1000)
            return error.RequestDidNotComplete;
        try collectPass(&runtime);
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker.testing.executeWorkItem(&runtime, item);
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const boot_body = try rt.readIngressResponseBody(&runtime, control_pair[1], 22);
    defer std.testing.allocator.free(boot_body);
    try expectBodyContains(boot_body, "\"ok\":true");
    try expectBodyContains(boot_body, "\"bootWasm\":\"pending\"");

    // A second, unrelated request parks at a one-second timer. The fake
    // clock stays at 0 until after the settle, so this request is the only
    // live one for the whole settle window, and its deadline sits an hour
    // out so the later clock advance cannot fire it.
    const reader_source =
        \\export default async function handle() {
        \\    await new Promise((resolve) => setTimeout(resolve, 1000));
        \\    return Response.json({ ok: true, bootWasm: globalThis.bootWasm });
        \\}
    ;
    try enqueueWasmRoute(&runtime, reader_source, 23, "/wasm-boot-reader.js", std.time.ns_per_hour);
    attempts = 0;
    while (true) : (attempts += 1) {
        if (attempts > 1000)
            return error.ReaderDidNotPark;
        try collectPass(&runtime);
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker.testing.executeWorkItem(&runtime, item);
            continue;
        }
        // No ready work is left and every collect ran. With the clock frozen,
        // only the request's timer can still move it.
        break;
    }
    const reader_ctx = runtime.requests.active.get(23) orelse return error.ReaderNotParked;

    // Wait for the worklist thread's schedule notification. The settle is
    // ready once `scheduleWorkSoon` has run, and with the install report
    // consumed above, a true here means a real schedule.
    attempts = 0;
    while (!runtime.core.vm.deferredWorkScheduled()) : (attempts += 1) {
        if (attempts > 5000)
            return error.BootWasmSettleNeverScheduled;
        std.Thread.sleep(std.time.ns_per_ms);
    }

    // The settle runs through the loop's pump while request 23 is the only
    // live request. The wait above consumed the gate, so the first pass is
    // told work is imminent; otherwise the pump would find the gate clear
    // and skip.
    const reader_cpu_before = reader_ctx.exec.cpu_used_ns_total;
    var host_pump_exec_ctx = support.makeExecCtx(0);
    var pending_imminent = true;
    attempts = 0;
    while (pending_imminent) : (attempts += 1) {
        if (attempts > 1000)
            return error.BootWasmSettleDidNotDrain;
        pending_imminent = worker.testing.scheduler.loop.pumpDeferredWork(
            &runtime,
            &host_pump_exec_ctx,
            pending_imminent,
        );
        if (pending_imminent)
            std.Thread.sleep(std.time.ns_per_ms);
    }

    // The settle's CPU went to the request-less host context, and the
    // parked request gained none.
    try std.testing.expect(host_pump_exec_ctx.cpu_used_ns_total > 0);
    try std.testing.expectEqual(reader_cpu_before, reader_ctx.exec.cpu_used_ns_total);

    // The clock moves past the parked request's timer, so the request
    // finishes and reads the global the settle's continuation set:
    // "settled", because the module bytes are valid.
    now_mono_ns = 2 * std.time.ns_per_s;
    attempts = 0;
    while (runtime.requests.active.contains(23)) : (attempts += 1) {
        if (attempts > 1000)
            return error.RequestDidNotComplete;
        try collectPass(&runtime);
        pending_imminent = worker.testing.scheduler.loop.pumpDeferredWork(
            &runtime,
            &host_pump_exec_ctx,
            pending_imminent,
        );
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker.testing.executeWorkItem(&runtime, item);
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const reader_body = try rt.readIngressResponseBody(&runtime, control_pair[1], 23);
    defer std.testing.allocator.free(reader_body);
    try expectBodyContains(reader_body, "\"ok\":true");
    try expectBodyContains(reader_body, "\"bootWasm\":\"settled\"");
}
