//! VM lifecycle through the wrappers: a value handle with no VM, or one whose VM was destroyed,
//! fails instead of crashing; the fork sequence (`prepareForFork`, `postForkChild`,
//! `reseedAfterFork`) leaves a VM that evaluates and invokes, with and without web APIs; and
//! `postForkChild` refuses a VM inside a turn. The sequence runs in this process without a
//! fork; a real fork is covered in `zygote-integration`. Lanes: `bindings-test` and both
//! bindings smokes.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

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
    defer bindings.clearHelperThreadsTimeoutOverride();

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

/// Runs the fork sequence of the test above on `vm`, then evaluates a module and invokes it as
/// request `request_id`. The zygote creates its VM with flags from its environment
/// (`zygote_env_vm_flags` in `zygote/fork_loop.zig`), while the other tests here use
/// `createDefault()`, so a fork-path branch that depends on a flag, such as the navigator
/// refresh `collo_vm_post_fork_child` skips on a VM without web APIs, needs a VM built with it.
fn expectForkLifecycleHolds(vm: *bindings.Vm, request_id: u64) !void {
    const source =
        \\export default function ping() {
        \\    return "pong";
        \\}
    ;

    try support.registerModule(vm, "/forkable-flags.js", source);
    try bindings.setHelperThreadsTimeoutOverrideNs(5_000_000);
    defer bindings.clearHelperThreadsTimeoutOverride();

    try vm.prepareForFork();
    try vm.postForkChild();
    try vm.reseedAfterFork(.{
        .weak_random_seed = 404,
        .vm_random_seed = 505,
        .heap_random_seed = 606,
    });

    try support.evaluateOk(vm, "/forkable-flags.js");

    var entry = try support.getExportOk(vm, "/forkable-flags.js", "default");
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

    try expectForkLifecycleHolds(&vm, 8801);

    // A flag the VM ignored would make the run above prove nothing, so the web APIs must be
    // absent.
    const probe_source =
        \\export default function probe() {
        \\    return typeof globalThis.fetch;
        \\}
    ;
    try support.registerModule(&vm, "/webapi-probe.js", probe_source);
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
