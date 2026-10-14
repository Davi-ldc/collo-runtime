//! Covers how the worker runtime boots its definition's artifact and loads a
//! handler's dynamic imports. The boot registers the artifact once and for
//! the worker's life, so the VM refuses a second pack and a second boot
//! fails; any module of the artifact can be a route's entry; an artifact in
//! an unsealed memfd is refused before it is mapped, and one with no route
//! or with a module outside `/var/task` fails the boot with nothing
//! registered; a top-level await parks requests until the evaluation
//! settles, after which a rejection fails them for good. A handler's
//! `import()` resolves a module of the artifact, also after a timer
//! continuation, and rejects a module the artifact lacks, or a bare
//! specifier, at once inside the worker: nothing but the response reaches the
//! control socket. Imports that climb above their module's directory and
//! come back down, in an artifact the server's own builder made, resolve in
//! the worker to the packed modules. Runs in `worker-test`; the boot
//! evaluation of the routes is covered by `boot_eval.zig` and `routes.zig`,
//! the artifact's format by `common/tests/ipc/module_pack.zig`, the server's
//! keys and root by `server/tests/routes/artifacts.zig`, and the engine's
//! module loader by the `bindings` lane.

const std = @import("std");
const support = @import("bindings_support");
const bindings = @import("collo_bindings");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const server_config = @import("collo_server_config");
const server_routes = @import("collo_server_routes");

const module_pack = ipc.module_pack;
const fakeNow = rt.fakeNow;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
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

/// Boots `runtime` with the artifact of `modules` and `routes`, as a worker's
/// boot does.
fn bootDefinition(
    runtime: *worker.Runtime,
    modules: []const module_pack.Module,
    routes: []const ipc.route_table.RouteInput,
) !void {
    const pack_fd = try rt.createDefinitionFd(modules, routes);
    defer std.posix.close(pack_fd);
    try rt.bootDefinition(runtime, pack_fd);
}

/// Queues one request for the route at `route_index`.
fn enqueueRoute(runtime: *worker.Runtime, request_id: u64, route_index: u16, path: []const u8) !void {
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .request = .{ .path = path },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, 1, .{ .path = path });
}

fn completeRequestResponse(runtime: *worker.Runtime, control_fd: std.posix.fd_t, request_id: u64) ![]u8 {
    try executeUntilRequestDone(runtime, request_id);
    return rt.readIngressResponseBody(runtime, control_fd, request_id);
}

test "the booted artifact stays registered for the worker's life and the VM refuses a second pack" {
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
    , 302, "/var/task/permanent-route.js");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "ok"));

    const other = try module_pack.buildSingleRouteAlloc(std.testing.allocator, "/var/task/other.js", "export default 1;");
    defer std.testing.allocator.free(other);
    try std.testing.expectError(error.AlreadyExists, vm.registerModulePack(other));

    // The route still serves from the pack the boot registered.
    const again = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 303, "/var/task/permanent-route.js", .{});
    defer std.testing.allocator.free(again);
    try std.testing.expect(std.mem.containsAtLeast(u8, again, 1, "ok"));
}

test "a route's entry need not be the artifact's first module" {
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

    try bootDefinition(&runtime, &.{
        .{ .specifier = "/var/task/primary.js", .source = "export default function primary() { return 'primary'; }" },
        .{ .specifier = "/var/task/route.js", .source = "export default function handle() { return 'non-primary'; }" },
    }, &.{.{ .entry_module = 1 }});

    try enqueueRoute(&runtime, 101, 0, "/route");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 101);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "non-primary"));
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

    // The gate module is no route's entry; the test evaluates it itself to
    // resolve the route's await from outside the worker's loop.
    const specifier = "/var/task/tla.js";
    const gate_specifier = "/var/task/gate-resolve.js";
    try bootDefinition(&runtime, &.{
        .{
            .specifier = specifier,
            .source =
            \\const gate = new Promise((resolve) => { globalThis.__resolveGate = resolve; });
            \\await gate;
            \\export default function handle() {
            \\    return "settled";
            \\}
            ,
        },
        .{ .specifier = gate_specifier, .source = "globalThis.__resolveGate();\nexport default 1;\n" },
    }, &.{.{ .entry_module = 0 }});

    // The boot ran the synchronous part (gate resolver stashed) and parked
    // the evaluation promise; a request for the route joins the waiter list.
    const parked = rt.routeModule(&runtime, specifier) orelse
        return error.MissingEvaluatingRecord;
    try std.testing.expect(parked.* == .evaluating);
    try enqueueRoute(&runtime, 501, 0, "/tla");
    try executeNextReady(&runtime);
    try std.testing.expect(runtime.requests.active.contains(501));

    // Resolving the gate from another module evaluation drives the JSC
    // microtask drain: the module body completes, the evaluation promise
    // settles, and the bindings reaction enqueues the settlement.
    try support.evaluateOk(&vm, gate_specifier);
    try std.testing.expectEqual(@as(usize, 1), runtime.modules.state.pending_settlements.items.len);

    runtime.collectModuleSettlements();
    const ready = rt.routeModule(&runtime, specifier) orelse
        return error.MissingReadyRecord;
    try std.testing.expect(ready.* == .ready);

    const response = try completeRequestResponse(&runtime, control_pair[1], 501);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "settled"));

    // Late/duplicate settlement is a no-op on a ready record, an unknown
    // specifier, and the right specifier under a realm that never evaluated
    // it.
    runtime.handleModuleEvaluationSettled(0, specifier, true);
    runtime.handleModuleEvaluationSettled(0, "/var/task/unknown.js", false);
    runtime.handleModuleEvaluationSettled(7, specifier, false);
    const still_ready = rt.routeModule(&runtime, specifier) orelse
        return error.MissingReadyRecord;
    try std.testing.expect(still_ready.* == .ready);
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

    const specifier = "/var/task/tla-reject.js";
    const gate_specifier = "/var/task/gate-reject.js";
    try bootDefinition(&runtime, &.{
        .{
            .specifier = specifier,
            .source =
            \\const gate = new Promise((resolve, reject) => { globalThis.__rejectGate = reject; });
            \\await gate;
            \\export default function handle() {
            \\    return "unreachable";
            \\}
            ,
        },
        .{ .specifier = gate_specifier, .source = "globalThis.__rejectGate(new Error(\"gate boom\"));\nexport default 1;\n" },
    }, &.{.{ .entry_module = 0 }});

    try enqueueRoute(&runtime, 502, 0, "/tla-reject");
    try executeNextReady(&runtime);
    if (!runtime.requests.active.contains(502))
        return error.RequestNotParked;

    try support.evaluateOk(&vm, gate_specifier);
    if (runtime.modules.state.pending_settlements.items.len != 1)
        return error.SettlementNotEnqueued;

    // The rejection leaves a sticky failed record (`RouteModuleState` in
    // `worker/modules/state.zig` says why re-evaluating is unsafe), so
    // waiters and later requests fail fast with a 500.
    runtime.collectModuleSettlements();
    const failed = rt.routeModule(&runtime, specifier) orelse
        return error.MissingFailedRecord;
    if (failed.* != .failed)
        return error.RecordNotFailed;

    const response = try completeRequestResponse(&runtime, control_pair[1], 502);
    defer std.testing.allocator.free(response);
    if (std.mem.containsAtLeast(u8, response, 1, "unreachable"))
        return error.HandlerBodyRan;
}

test "a handler's import() of a module in its route's artifact resolves without a packet" {
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

    // `packed.js` is in the artifact without being a route: the server packs
    // the target of a string-literal `import()` as well.
    try bootDefinition(&runtime, &.{
        .{
            .specifier = "/var/task/lazy-route.js",
            .source =
            \\export default async function handle() {
            \\    const first = await import("./packed.js");
            \\    const again = await import("/var/task/packed.js");
            \\    return "packed:" + first.answer + ":" + String(first === again);
            \\}
            ,
        },
        .{ .specifier = "/var/task/packed.js", .source = "export const answer = 'from-pack';" },
    }, &.{.{ .entry_module = 0 }});

    try enqueueRoute(&runtime, 310, 0, "/packed");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 310);
    defer std.testing.allocator.free(response);
    // Both spellings reach one module record.
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "packed:from-pack:true"));
    try expectControlSilent(control_pair[1]);
}

test "a handler's import() of a module its artifact lacks rejects at once without a packet" {
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

    const route_index = try rt.registerRoute(&runtime, "/var/task/missing-route.js",
        \\export default async function handle() {
        \\    try {
        \\        await import("./missing.js");
        \\    } catch (err) {
        \\        return err.name + ": " + err.message;
        \\    }
        \\    return "unexpected";
        \\}
    );

    // The request completes on its own turns: the rejection waits on no
    // packet from the server, which never sends one here.
    try enqueueRoute(&runtime, 311, route_index, "/missing");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 311);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "Error: Cannot find module '/var/task/missing.js'"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "imported from '/var/task/missing-route.js'"));
    try expectControlSilent(control_pair[1]);
}

test "a handler's import() after a timer continuation resolves from its artifact" {
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

    try bootDefinition(&runtime, &.{
        .{
            .specifier = "/var/task/timer-route.js",
            .source =
            \\export default async function handle() {
            \\    await new Promise(resolve => setTimeout(resolve, 0));
            \\    const mod = await import("./after-timer.js");
            \\    return "timer-dynamic:" + mod.answer;
            \\}
            ,
        },
        .{ .specifier = "/var/task/after-timer.js", .source = "export const answer = 'loaded-after-timer';" },
    }, &.{.{ .entry_module = 0 }});

    try enqueueRoute(&runtime, 303, 0, "/dynamic-after-timer");
    try executeNextReady(&runtime);
    try runtime.collectDueTimers();
    try executeNextReady(&runtime);

    const response = try completeRequestResponse(&runtime, control_pair[1], 303);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "timer-dynamic:loaded-after-timer"));
    try expectControlSilent(control_pair[1]);
}

test "an artifact in an unsealed memfd fails the boot without being mapped" {
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

    // A well-formed artifact in a memfd nobody sealed: the bytes are valid,
    // so only the seal check stands between them and the bridge.
    const pack = try module_pack.buildSingleRouteAlloc(std.testing.allocator, "/var/task/unsealed-route.js", "export default function handle() {}");
    defer std.testing.allocator.free(pack);
    const unsealed_fd = try std.posix.memfd_create("collo-unsealed-pack", std.os.linux.MFD.CLOEXEC);
    defer std.posix.close(unsealed_fd);
    try fd_mod.writeAllRaw(unsealed_fd, pack);

    const mappings_before = bindings.liveMappingCount();
    try std.testing.expectError(
        error.MissingFdSeals,
        runtime.evaluateBootRoutes(unsealed_fd, 0, null),
    );
    try std.testing.expectEqual(mappings_before, bindings.liveMappingCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.modules.state.routes.items.len);
}

test "an artifact with a module outside /var/task or without a route fails the boot and registers nothing" {
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

    const mappings_before = bindings.liveMappingCount();

    // A key in the zygote's namespace would let a tenant module take one of
    // the zygote's own keys.
    const outside_fd = try rt.createDefinitionFd(&.{
        .{ .specifier = "/var/task/route.js", .source = "export default () => 'route';" },
        .{ .specifier = "/__collo/zygote/route.js", .source = "export default () => 'outside';" },
    }, &.{.{ .entry_module = 0 }});
    defer std.posix.close(outside_fd);
    try std.testing.expectError(error.InvalidModulePack, rt.bootDefinition(&runtime, outside_fd));

    // The zygote's warmup travels without routes; a worker serves none.
    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/var/task/no-route.js", "export default () => 'none';");
    defer std.testing.allocator.free(pack);
    const routeless_fd = try std.posix.memfd_create("collo-routeless-pack", std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    defer std.posix.close(routeless_fd);
    try fd_mod.writeAllRaw(routeless_fd, pack);
    try fd_mod.addSeals(routeless_fd, fd_mod.memfd_readonly_seals);
    try std.testing.expectError(error.InvalidModulePack, rt.bootDefinition(&runtime, routeless_fd));

    try std.testing.expectEqual(mappings_before, bindings.liveMappingCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.modules.state.routes.items.len);

    // Nothing was registered, so a valid artifact still boots the runtime.
    const served = try runRouteAndReadBody(&runtime, control_pair[1],
        \\export default function handle() {
        \\    return "booted";
        \\}
    , 330, "/var/task/booted.js");
    defer std.testing.allocator.free(served);
    try std.testing.expect(std.mem.containsAtLeast(u8, served, 1, "booted"));
}

test "a runtime boots once: a second boot fails and the first routes keep serving" {
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

    try bootDefinition(&runtime, &.{
        .{ .specifier = "/var/task/first.js", .source = "export default () => 'first';" },
    }, &.{.{ .entry_module = 0 }});

    const second_fd = try rt.createModulePackFd("/var/task/second.js", "export default () => 'second';");
    defer std.posix.close(second_fd);
    const mappings_before = bindings.liveMappingCount();
    try std.testing.expectError(error.RoutesAlreadyBooted, rt.bootDefinition(&runtime, second_fd));
    try std.testing.expectEqual(mappings_before, bindings.liveMappingCount());
    try std.testing.expectEqual(@as(usize, 1), runtime.modules.state.routes.items.len);

    const served = try rt.runRegisteredRouteAndReadBody(&runtime, control_pair[1], 340, "/var/task/first.js", .{});
    defer std.testing.allocator.free(served);
    try std.testing.expect(std.mem.containsAtLeast(u8, served, 1, "first"));
}

test "imports that climb above their module's directory and descend into it again load from the artifact the server built" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const index_source =
        \\import { util } from "../src/util.js";
        \\export default async function handle() {
        \\    const lazy = await import("../src/lib/lazy.js");
        \\    return util + "+" + lazy.value;
        \\}
    ;
    try tmp.dir.makePath("app/src/lib");
    try tmp.dir.writeFile(.{ .sub_path = "app/src/index.js", .data = index_source });
    try tmp.dir.writeFile(.{ .sub_path = "app/src/util.js", .data = "export const util = 'climbed';\n" });
    try tmp.dir.writeFile(.{ .sub_path = "app/src/lib/lazy.js", .data = "export const value = 'lazy';\n" });
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &directory_buffer);
    const config_path = try std.fs.path.join(allocator, &.{ directory, "collo.json" });
    defer allocator.free(config_path);

    // The server's own builder makes the artifact, so the keys are the ones
    // a worker of `collo serve` receives.
    var diagnostic: server_config.Diagnostic = .{};
    const parsed = try server_config.parse(allocator,
        \\{"workers": {"api": {"routes": {"/*": {"entry": "./app/src/index.js"}}}}}
    , config_path, &diagnostic);
    var built: server_routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    try rt.bootDefinition(&runtime, built.artifact(0).module_pack.fd());

    // The boot evaluated the entry, so its static import resolved; the
    // handler's `import()` resolves the same way at run time.
    try std.testing.expect(runtime.modules.state.routes.items[0].module == .ready);
    try enqueueRoute(&runtime, 350, 0, "/");
    try executeNextReady(&runtime);
    const response = try completeRequestResponse(&runtime, control_pair[1], 350);
    defer allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "climbed+lazy"));
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
    , 305, "/var/task/unscoped.js", .{});
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 500), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "internal server error"));
    try expectControlSilent(control_pair[1]);
}
