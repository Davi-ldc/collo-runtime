//! Covers how the worker runtime loads route modules and a handler's dynamic
//! imports. A route pack stays permanent, any module of a pack can be the
//! entry, bytecode in a pack serves and falls back to source when JSC
//! refuses it, a pack in an unsealed memfd is refused before it is mapped, a
//! request for a route no registered pack holds fails without stopping the
//! worker, and a top-level await parks requests until the evaluation
//! settles, after which a rejection fails them for good. A handler's
//! `import()` resolves a module of its route's pack, also after a timer
//! continuation, and rejects a module the pack lacks, or a bare specifier,
//! at once inside the worker: nothing but the response reaches the control
//! socket. Runs in `worker-test`; the boot evaluation of a route entry is
//! covered by `boot_eval.zig`, and the engine's module loader by the
//! `bindings` lane.

const std = @import("std");
const support = @import("bindings_support");
const bindings = @import("collo_bindings");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
const createModulePackFd = rt.createModulePackFd;
const createModulePackGraphFd = rt.createModulePackGraphFd;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;
const runRouteAndReadBody = rt.runRouteAndReadBody;

/// The server's end of the control socket holds no packet: the worker sent
/// nothing beyond what the caller already read.
fn expectControlSilent(fd: std.posix.fd_t) !void {
    var pending = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pending, 25));
}

/// Registers the pack in `route_fd` as the runtime's route at
/// `route_entry_specifier`, as WorkerInit's route entry does, and enqueues
/// one request for it.
fn registerAndEnqueueRoute(
    runtime: *worker.Runtime,
    request_id: u64,
    route_entry_specifier: []const u8,
    route_fd: std.posix.fd_t,
    path: []const u8,
) !void {
    try rt.registerRoutePack(runtime, route_fd, route_entry_specifier);
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_entry_specifier = route_entry_specifier,
        .request = .{ .path = path },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, 1, .{ .path = path });
}

fn completeRequestResponse(runtime: *worker.Runtime, control_fd: std.posix.fd_t, request_id: u64) ![]u8 {
    try executeUntilRequestDone(runtime, request_id);
    return rt.readIngressResponseBody(runtime, control_fd, request_id);
}

test "route module pack is permanent worker state" {
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

    const response = try runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return "ok";
        \\}
    , 302, "/__collo_route/demo/permanent-route.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "ok"));

    const stats = try vm.evictModulesByLifetime(.evictable);
    try std.testing.expectEqual(@as(usize, 0), stats.sources_removed);
    try std.testing.expectEqual(@as(usize, 0), stats.namespaces_removed);
}

test "worker executes route module that is not primary module pack entry" {
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

    const route_fd = try createModulePackGraphFd(&.{
        .{ .specifier = "/__collo_route/demo/primary.js", .source = "export default function primary() { return 'primary'; }" },
        .{ .specifier = "/__collo_route/demo/route.js", .source = "export default function handle() { return 'non-primary'; }" },
    }, 0);
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 101, "/__collo_route/demo/route.js", route_fd, "/route");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 101);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "non-primary"));
}

test "generated bytecode rides the pack and the route serves" {
    // A module pack can carry a blob from the bytecode generator
    // (`bindings/jsc/runtime/tooling_bytecode.cpp`), which the loader hands
    // to JSC as `CachedBytecode`. JSC parses the source instead whenever it
    // refuses the blob, so a response cannot tell whether the blob was used.
    // This test shows that a real generated blob never breaks serving; the
    // two tests below cover blobs that must be refused.
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

    const specifier = "/__collo_route/demo/bytecode-route.js";
    const source = "export default function handle() { return 'bytecode-ok'; }";
    const bytecode = try bindings.generateModuleBytecodeAlloc(std.testing.allocator, specifier, source);
    defer std.testing.allocator.free(bytecode);
    try std.testing.expect(bytecode.len > 0);

    const route_fd = try createModulePackGraphFd(&.{
        .{ .specifier = specifier, .source = source, .bytecode = bytecode },
    }, 0);
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 501, specifier, route_fd, "/bytecode");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 501);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "bytecode-ok"));
}

test "corrupted bytecode header degrades to source parse and still serves" {
    // JSC refuses a blob whose cache version differs from its own. With
    // `USE_BUN_JSC_ADDITIONS`, which the build sets, the version
    // (`computeJSCBytecodeCacheVersion`) hashes the `__TIMESTAMP__` of
    // `JSCBytecodeCacheVersion.cpp`, so two engine builds can disagree. Byte
    // 0 sits in the cache entry's version field, so flipping it gives such a
    // mismatch: JSC refuses the cache and parses the source, and the request
    // never notices.
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

    const specifier = "/__collo_route/demo/bytecode-stale.js";
    const source = "export default function handle() { return 'stale-fallback-ok'; }";
    const bytecode = try bindings.generateModuleBytecodeAlloc(std.testing.allocator, specifier, source);
    defer std.testing.allocator.free(bytecode);
    bytecode[0] ^= 0xff;

    const route_fd = try createModulePackGraphFd(&.{
        .{ .specifier = specifier, .source = source, .bytecode = bytecode },
    }, 0);
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 502, specifier, route_fd, "/bytecode-stale");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 502);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "stale-fallback-ok"));
}

test "truncated bytecode degrades to source parse and still serves" {
    // JSC's decoder reads the cache entry header, for its version check,
    // before it checks any bounds, so a blob shorter than that header would
    // be read out of bounds. The loader treats a blob under
    // `minimumPlausibleCacheBytes` as absent (`ColloSourceProvider` in
    // `bindings/jsc/runtime/module_loader.cpp`), and the module is parsed
    // from source.
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

    const specifier = "/__collo_route/demo/bytecode-truncated.js";
    const source = "export default function handle() { return 'truncated-fallback-ok'; }";
    const bytecode = try bindings.generateModuleBytecodeAlloc(std.testing.allocator, specifier, source);
    defer std.testing.allocator.free(bytecode);

    const route_fd = try createModulePackGraphFd(&.{
        .{ .specifier = specifier, .source = source, .bytecode = bytecode[0..32] },
    }, 0);
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 503, specifier, route_fd, "/bytecode-truncated");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 503);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "truncated-fallback-ok"));
}

test "top level await route module parks the request and settles through the callback" {
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

    const specifier = "/__collo_route/demo/tla.js";
    const route_fd = try createModulePackFd(specifier,
        \\const gate = new Promise((resolve) => { globalThis.__resolveGate = resolve; });
        \\await gate;
        \\export default function handle() {
        \\    return "settled";
        \\}
    );
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 501, specifier, route_fd, "/tla");
    try executeNextReady(&runtime);

    // The synchronous part ran (gate resolver stashed), the evaluation
    // promise is parked, and the request joined the waiter list.
    const parked = runtime.modules.state.route_modules.get(specifier) orelse
        return error.MissingEvaluatingRecord;
    try std.testing.expect(parked == .evaluating);
    try std.testing.expect(runtime.requests.active.contains(501));

    // Resolving the gate from another module evaluation drives the JSC
    // microtask drain: the module body completes, the evaluation promise
    // settles, and the bindings reaction enqueues the settlement.
    try support.registerModule(&vm, "/gate-resolve.js",
        \\globalThis.__resolveGate();
        \\export default 1;
    );
    try support.evaluateOk(&vm, "/gate-resolve.js");
    try std.testing.expectEqual(@as(usize, 1), runtime.modules.state.pending_settlements.items.len);

    runtime.collectModuleSettlements();
    const ready = runtime.modules.state.route_modules.get(specifier) orelse
        return error.MissingReadyRecord;
    try std.testing.expect(ready == .ready);

    const response = try completeRequestResponse(&runtime, control_pair[1], 501);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "settled"));

    // Late/duplicate settlement is a no-op on both a ready record and an
    // unknown specifier.
    runtime.handleModuleEvaluationSettled(specifier, true);
    runtime.handleModuleEvaluationSettled("/__collo_route/demo/unknown.js", false);
    const still_ready = runtime.modules.state.route_modules.get(specifier) orelse
        return error.MissingReadyRecord;
    try std.testing.expect(still_ready == .ready);
}

test "top level await rejection settles waiters into the per-request exception path" {
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

    const specifier = "/__collo_route/demo/tla-reject.js";
    const route_fd = try createModulePackFd(specifier,
        \\const gate = new Promise((resolve, reject) => { globalThis.__rejectGate = reject; });
        \\await gate;
        \\export default function handle() {
        \\    return "unreachable";
        \\}
    );
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 502, specifier, route_fd, "/tla-reject");
    try executeNextReady(&runtime);
    if (!runtime.requests.active.contains(502))
        return error.RequestNotParked;

    try support.registerModule(&vm, "/gate-reject.js",
        \\globalThis.__rejectGate(new Error("gate boom"));
        \\export default 1;
    );
    try support.evaluateOk(&vm, "/gate-reject.js");
    if (runtime.modules.state.pending_settlements.items.len != 1)
        return error.SettlementNotEnqueued;

    // The rejection leaves a sticky failed record (`settleEvaluation` in
    // `worker/modules/routes.zig` says why re-evaluating is unsafe), so
    // waiters and later requests fail fast with a 500.
    runtime.collectModuleSettlements();
    const failed = runtime.modules.state.route_modules.get(specifier) orelse
        return error.MissingFailedRecord;
    if (failed != .failed)
        return error.RecordNotFailed;

    const response = try completeRequestResponse(&runtime, control_pair[1], 502);
    defer std.testing.allocator.free(response);
    if (std.mem.containsAtLeast(u8, response, 1, "unreachable"))
        return error.HandlerBodyRan;
}

test "a handler's import() of a module in its route's pack resolves without a packet" {
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

    // The pack lists no dependency for `packed.js`: the server packs the
    // target of a string-literal `import()` without making it one.
    const route_fd = try createModulePackGraphFd(&.{
        .{
            .specifier = "/__collo_route/demo/lazy-route.js",
            .source =
            \\export default async function handle() {
            \\    const first = await import("./packed.js");
            \\    const again = await import("/var/task/packed.js");
            \\    return "packed:" + first.answer + ":" + String(first === again);
            \\}
            ,
        },
        .{ .specifier = "/__collo_route/demo/packed.js", .source = "export const answer = 'from-pack';" },
    }, 0);
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 310, "/__collo_route/demo/lazy-route.js", route_fd, "/packed");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 310);
    defer std.testing.allocator.free(response);
    // Both spellings reach one module record.
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "packed:from-pack:true"));
    try expectControlSilent(control_pair[1]);
}

test "a handler's import() of a module its pack lacks rejects at once without a packet" {
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

    const route_fd = try createModulePackFd("/__collo_route/demo/missing-route.js",
        \\export default async function handle() {
        \\    try {
        \\        await import("./missing.js");
        \\    } catch (err) {
        \\        return err.name + ": " + err.message;
        \\    }
        \\    return "unexpected";
        \\}
    );
    defer std.posix.close(route_fd);

    // The request completes on its own turns: the rejection waits on no
    // packet from the server, which never sends one here.
    try registerAndEnqueueRoute(&runtime, 311, "/__collo_route/demo/missing-route.js", route_fd, "/missing");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 311);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "Error: Cannot find module '/var/task/missing.js'"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "imported from '/var/task/missing-route.js'"));
    try expectControlSilent(control_pair[1]);
}

test "a handler's import() after a timer continuation resolves from its pack" {
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

    const route_fd = try createModulePackGraphFd(&.{
        .{
            .specifier = "/__collo_route/demo/timer-route.js",
            .source =
            \\export default async function handle() {
            \\    await new Promise(resolve => setTimeout(resolve, 0));
            \\    const mod = await import("./after-timer.js");
            \\    return "timer-dynamic:" + mod.answer;
            \\}
            ,
        },
        .{ .specifier = "/__collo_route/demo/after-timer.js", .source = "export const answer = 'loaded-after-timer';" },
    }, 0);
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 303, "/__collo_route/demo/timer-route.js", route_fd, "/dynamic-after-timer");
    try executeNextReady(&runtime);
    try runtime.collectDueTimers();
    try executeNextReady(&runtime);

    const response = try completeRequestResponse(&runtime, control_pair[1], 303);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "timer-dynamic:loaded-after-timer"));
    try expectControlSilent(control_pair[1]);
}

test "a route pack in an unsealed memfd fails the boot evaluation without being mapped" {
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

    // A well-formed pack in a memfd nobody sealed: the bytes are valid, so
    // only the seal check stands between them and the bridge.
    const specifier = "/__collo_route/demo/unsealed-route.js";
    const pack = try ipc.module_pack.buildSingleAlloc(std.testing.allocator, specifier, "export default function handle() {}");
    defer std.testing.allocator.free(pack);
    const unsealed_fd = try std.posix.memfd_create("collo-unsealed-pack", std.os.linux.MFD.CLOEXEC);
    defer std.posix.close(unsealed_fd);
    try fd_mod.writeAllRaw(unsealed_fd, pack);

    const mappings_before = bindings.liveMappingCount();
    try std.testing.expectError(
        error.MissingFdSeals,
        runtime.evaluateBootRouteEntry(unsealed_fd, specifier, 0, null),
    );
    try std.testing.expectEqual(mappings_before, bindings.liveMappingCount());
    try std.testing.expect(!runtime.modules.state.loaded_sources.contains(specifier));
}

test "a request for a route no registered pack holds answers 500 and the worker keeps serving" {
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

    const unregistered = "/__collo_route/demo/never-registered.js";
    const refused = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 320, unregistered, .{});
    defer std.testing.allocator.free(refused);
    try std.testing.expect(std.mem.containsAtLeast(u8, refused, 1, "internal server error"));
    try std.testing.expect(!runtime.modules.state.route_modules.contains(unregistered));
    try std.testing.expect(runtime.core.running);

    const served = try runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return "registered";
        \\}
    , 321, "/__collo_route/demo/registered.js");
    defer std.testing.allocator.free(served);
    try std.testing.expect(std.mem.containsAtLeast(u8, served, 1, "registered"));
}

test "a bare import() specifier rejects inside the worker" {
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

    var response = try rt.runRouteAndReadIngressResponseWithRequest(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    await import("react");
        \\    return "unreachable";
        \\}
    , 305, "/__collo_route/demo/unscoped.js", .{});
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 500), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "internal server error"));
    try expectControlSilent(control_pair[1]);
}
