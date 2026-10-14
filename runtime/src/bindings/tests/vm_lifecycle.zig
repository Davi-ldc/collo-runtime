//! VM lifecycle through the wrappers: the engine's page ceiling matches the build option that
//! chose the engine and fits the kernel the lane runs on; a value handle with no VM, or one
//! whose VM was destroyed, fails instead of crashing; the fork sequence (`prepareForFork`, `postForkChild`,
//! `reseedAfterFork`) leaves a VM that evaluates and invokes, with and without web APIs;
//! `postForkChild` refuses a VM inside a turn; and a VM watches for deferred work from its
//! creation, so a worker never sets that up after its filter. The sequence runs in this
//! process without a fork; a real fork is covered in `zygote-integration`. Lanes:
//! `bindings-test` and both bindings smokes.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

test "the engine's page ceiling is the one its build option promised and fits this kernel" {
    const ceiling = bindings.enginePageSizeCeiling();
    // The option that chose the engine (`jscPageSizeCeilingBytes` in `runtime/build/options.zig`) and
    // WTF's constant inside the engine are two derivations, and this is where they must agree.
    try std.testing.expectEqual(support.engine_options.page_size_ceiling_bytes, ceiling);
    try std.testing.expect(std.math.isPowerOfTwo(ceiling));
    // Every VM this lane creates depends on it; `collo_vm_create` refuses a kernel where it fails.
    try std.testing.expectEqual(@as(u64, 0), ceiling % std.heap.pageSize());
}

test "null Value handle returns InvalidJsValue instead of panicking" {
    var value = bindings.Value{};

    try std.testing.expectError(error.InvalidJsValue, value.retain());
}

test "detached handle retain fails after vm destroy" {
    var vm = try support.createVm();
    var value = try vm.stringValueUtf8("after destroy");

    vm.deinit();

    try std.testing.expectError(error.InvalidArgument, value.retain());
    value.deinit();
}

test "prepare_for_fork post_fork_child reseed roundtrip stays valid" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function ping() {
        \\    return "pong";
        \\}
    ;

    try support.registerModule(&vm, "/forkable.js", source);
    try bindings.setHelperThreadsTimeoutOverrideNs(5_000_000);
    defer bindings.clearHelperThreadsOverrides();

    try vm.prepareForFork();
    try vm.postForkChild();
    try vm.reseedAfterFork(.{
        .weak_random_seed = 101,
        .vm_random_seed = 202,
        .heap_random_seed = 303,
    });

    try support.evaluateOk(&vm, "/forkable.js");

    var entry = try support.getExportOk(&vm, "/forkable.js", "default");
    defer entry.deinit();

    var exec_ctx = support.makeExecCtx(1);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    var result = try support.invokeOk(&vm, &exec_ctx, &entry, &.{});
    defer result.deinit();

    try support.expectValueString(&vm, &result, "pong");
}

const forkable_specifier = "/forkable-flags.js";
const forkable_source =
    \\export default function ping() {
    \\    return "pong";
    \\}
;

/// Runs the fork sequence of the test above on `vm`, whose pack holds `forkable_specifier`,
/// then evaluates that module and invokes it as request `request_id`. The zygote creates its
/// VM with the default flags (`zygote/state.zig:Zygote.init`), as the other tests here do, so a
/// fork-path branch that depends on a flag, such as the navigator refresh
/// `collo_vm_post_fork_child` skips on a VM without web APIs, runs only on a VM built with that
/// flag.
fn expectForkLifecycleHolds(vm: *bindings.Vm, request_id: u64) !void {
    try bindings.setHelperThreadsTimeoutOverrideNs(5_000_000);
    defer bindings.clearHelperThreadsOverrides();

    try vm.prepareForFork();
    try vm.postForkChild();
    try vm.reseedAfterFork(.{
        .weak_random_seed = 404,
        .vm_random_seed = 505,
        .heap_random_seed = 606,
    });

    try support.evaluateOk(vm, forkable_specifier);

    var entry = try support.getExportOk(vm, forkable_specifier, "default");
    defer entry.deinit();

    var exec_ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    var result = try support.invokeOk(vm, &exec_ctx, &entry, &.{});
    defer result.deinit();

    try support.expectValueString(vm, &result, "pong");
}

test "fork lifecycle holds without web APIs and the flag really disables them" {
    var vm = try bindings.Vm.create(bindings.VmOptions.withoutWebApis());
    defer vm.deinit();

    // A VM holds one pack, so the probe below travels in the forked module's pack.
    const probe_source =
        \\export default function probe() {
        \\    return typeof globalThis.fetch;
        \\}
    ;
    try support.registerModules(&vm, &.{
        .{ .specifier = forkable_specifier, .source = forkable_source },
        .{ .specifier = "/webapi-probe.js", .source = probe_source },
    });
    try expectForkLifecycleHolds(&vm, 8801);

    // A flag the VM ignored would make the run above prove nothing, so the web APIs must be
    // absent.
    try support.evaluateOk(&vm, "/webapi-probe.js");

    var probe = try support.getExportOk(&vm, "/webapi-probe.js", "default");
    defer probe.deinit();

    var exec_ctx = support.makeExecCtx(8802);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    var result = try support.invokeOk(&vm, &exec_ctx, &probe, &.{});
    defer result.deinit();
    // `withoutWebApis()` installs no `fetch` global; a VM with web APIs would answer
    // "function".
    try support.expectValueString(&vm, &result, "undefined");
}

test "post_fork_child rejects active turn state" {
    var vm = try support.createVm();
    defer vm.deinit();

    var exec_ctx = support.makeExecCtx(7);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    try std.testing.expectError(error.InvalidArgument, vm.postForkChild());
}

test "gc max heap size override setters are callable" {
    try bindings.setGcMaxHeapSizeOverrideBytes(32 * 1024 * 1024);
    bindings.clearGcMaxHeapSizeOverride();
}

test "a VM watches for deferred work from its creation, so a fresh one reports none and needs no fd" {
    var vm = try support.createVm();
    defer vm.deinit();

    // The notification registered at creation misses no schedule, so nothing makes the gate read
    // pending until work is scheduled, and registering or dropping a wakeup fd only stores it.
    try std.testing.expect(!vm.deferredWorkScheduled());
    try vm.setDeferredWorkWakeupFd(-1);
    try std.testing.expect(!vm.deferredWorkScheduled());
}
