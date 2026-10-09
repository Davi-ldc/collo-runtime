//! Covers the callbacks a worker runtime registers on its VM
//! (`runtime/vm_hooks.zig`) once the runtime is gone: its teardown takes the
//! owner-transition hook off the VM, so a later runtime in the same memory
//! never receives the owner crossings of turns it does not run. What the
//! hook does for two live requests is covered in `multiplexing.zig`, and the
//! console and exception-log sinks in `console.zig`. Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const bindings = support.bindings;

const request_a: u64 = 11;
const request_b: u64 = 22;

test "a runtime's teardown takes its owner-transition hook off the VM" {
    // A hook left on the VM runs on whatever holds the dead runtime's memory.
    // Here that is a second runtime that registers nothing on the VM, so a
    // turn owner its sentinel shows after an owner crossing can only come
    // from the first runtime's hook.
    var vm = try support.createVm();
    defer vm.deinit();
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var now_mono_ns: u64 = 0;
    const clock: worker.Clock = .{ .ctx = &now_mono_ns, .now_fn = rt.fakeNow };

    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), clock);
    runtime.attachHostRuntime() catch |err| {
        runtime.deinit();
        return err;
    };
    runtime.deinit();

    // The second runtime takes the first one's place.
    runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), clock);
    defer runtime.deinit();

    // Request A registers a continuation and request B settles its promise,
    // so B's turn runs A's continuation under A: an owner crossing, which
    // the VM reports to its hook as it enters A and again as it leaves.
    try support.registerModule(&vm, "/owner-hook.js",
        \\let settle = null;
        \\export function arm() {
        \\    const pending = new Promise((resolve) => { settle = resolve; });
        \\    pending.then(() => {});
        \\}
        \\export function fire() { settle(1); }
    );
    try support.evaluateOk(&vm, "/owner-hook.js");
    var exec_a = support.makeExecCtx(request_a);
    defer releaseExecCtx(&vm, &exec_a);
    var exec_b = support.makeExecCtx(request_b);
    defer releaseExecCtx(&vm, &exec_b);

    const crossings_before = vm.ownerCrossings();
    try runTurn(&vm, "/owner-hook.js", "arm", &exec_a);
    try runTurn(&vm, "/owner-hook.js", "fire", &exec_b);

    try std.testing.expect(vm.ownerCrossings() > crossings_before);
    try std.testing.expectEqual(@as(u64, 0), runtime.observability.sentinel.turn_owner.load(.acquire));
}

/// Runs `export_name` of `specifier` in a turn owned by `exec_ctx`, then
/// leaves the turn, which drains the microtask queue: the turn that settles
/// another request's promise runs that request's continuation.
fn runTurn(
    vm: *bindings.Vm,
    specifier: []const u8,
    export_name: []const u8,
    exec_ctx: *bindings.ExecCtx,
) !void {
    var callable = try support.getExportOk(vm, specifier, export_name);
    defer callable.deinit();

    try vm.turnEnter(exec_ctx);
    var result = try support.invokeOk(vm, exec_ctx, &callable, &.{});
    result.deinit();
    try vm.turnExit();
}

/// Drops `exec_ctx` from the VM's owner table, which must happen before the
/// context's storage goes (`Vm.releaseExecCtx`). It fails only for a null
/// argument, and the error log then fails the run.
fn releaseExecCtx(vm: *bindings.Vm, exec_ctx: *bindings.ExecCtx) void {
    vm.releaseExecCtx(exec_ctx) catch |err|
        std.log.err("releasing exec context {d} failed: {s}", .{ exec_ctx.request_id, @errorName(err) });
}
