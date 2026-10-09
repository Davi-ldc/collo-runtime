//! The turn contract of `collo_turn_enter`, `collo_invoke` and `collo_turn_exit_ex`: entering
//! again with the same exec context nests, and microtasks drain only when the outermost turn
//! exits; entering with another context, or invoking outside a turn or with another turn's
//! context, fails with InvalidArgument. A failed allocation of the wrapper's argument array
//! returns OutOfMemory, and `Vm.invokeWithTiming` records when a handler's first statement ran
//! only through the marker it scopes to one synchronous call (`collo_invoke` in
//! `jsc/runtime/invoke.cpp`). Lane: `bindings-test`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

test "nested same req ctx is allowed and microtasks drain only on outermost exit" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\let last = "none";
        \\
        \\export function greet(name) {
        \\    Promise.resolve().then(() => {
        \\        last = String(name);
        \\    });
        \\    return "hello " + String(name);
        \\}
        \\
        \\export function check() {
        \\    return "done:" + last;
        \\}
    ;

    try support.registerModule(&vm, "/main.js", source);
    try support.evaluateOk(&vm, "/main.js");

    var greet = try support.getExportOk(&vm, "/main.js", "greet");
    defer greet.deinit();

    var check = try support.getExportOk(&vm, "/main.js", "check");
    defer check.deinit();

    var exec_ctx = support.makeExecCtx(11);
    try vm.turnEnter(&exec_ctx);

    var arg = try vm.stringValueUtf8("world");
    defer arg.deinit();

    var result = try support.invokeOk(&vm, &exec_ctx, &greet, &.{&arg});
    defer result.deinit();
    try support.expectValueString(&vm, &result, "hello world");

    try vm.turnEnter(&exec_ctx);

    var nested_before_inner_exit = try support.invokeOk(&vm, &exec_ctx, &check, &.{});
    defer nested_before_inner_exit.deinit();
    try support.expectValueString(&vm, &nested_before_inner_exit, "done:none");

    try vm.turnExit();

    var nested_before_outer_exit = try support.invokeOk(&vm, &exec_ctx, &check, &.{});
    defer nested_before_outer_exit.deinit();
    try support.expectValueString(&vm, &nested_before_outer_exit, "done:none");

    try vm.turnExit();

    try vm.turnEnter(&exec_ctx);
    var nested_after_outer_exit = try support.invokeOk(&vm, &exec_ctx, &check, &.{});
    defer nested_after_outer_exit.deinit();
    try support.expectValueString(&vm, &nested_after_outer_exit, "done:world");
    try vm.turnExit();
}

test "nested enter with different req ctx fails" {
    var vm = try support.createVm();
    defer vm.deinit();

    var exec_ctx_a = support.makeExecCtx(21);
    var exec_ctx_b = support.makeExecCtx(22);

    try vm.turnEnter(&exec_ctx_a);
    defer vm.turnExit() catch {};

    try std.testing.expectError(error.InvalidArgument, vm.turnEnter(&exec_ctx_b));
}

test "invoke with different req ctx fails" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function noop() {
        \\    return "ok";
        \\}
    ;

    try support.registerModule(&vm, "/wrong-invoke-ctx.js", source);
    try support.evaluateOk(&vm, "/wrong-invoke-ctx.js");

    var entry = try support.getExportOk(&vm, "/wrong-invoke-ctx.js", "default");
    defer entry.deinit();

    var exec_ctx_a = support.makeExecCtx(31);
    var exec_ctx_b = support.makeExecCtx(32);

    try vm.turnEnter(&exec_ctx_a);
    defer vm.turnExit() catch {};

    try std.testing.expectError(error.InvalidArgument, vm.invoke(std.testing.allocator, &exec_ctx_b, &entry, null, &.{}));
}

test "invoke outside turn is rejected" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function noop() {
        \\    return "ok";
        \\}
    ;

    try support.registerModule(&vm, "/turn.js", source);
    try support.evaluateOk(&vm, "/turn.js");

    var entry = try support.getExportOk(&vm, "/turn.js", "default");
    defer entry.deinit();

    var exec_ctx = support.makeExecCtx(92);
    try std.testing.expectError(error.InvalidArgument, vm.invoke(std.testing.allocator, &exec_ctx, &entry, null, &.{}));
}

test "invoke argument allocation failure propagates out of memory" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function passthrough(value) {
        \\    return value;
        \\}
    ;

    try support.registerModule(&vm, "/oom-invoke.js", source);
    try support.evaluateOk(&vm, "/oom-invoke.js");

    var entry = try support.getExportOk(&vm, "/oom-invoke.js", "default");
    defer entry.deinit();

    var exec_ctx = support.makeExecCtx(93);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    // One argument more than `Vm.invokeWithTiming` keeps on the stack, so the argument array
    // comes from the failing allocator.
    var args: [9]bindings.Value = undefined;
    for (&args, 0..) |*arg, index|
        arg.* = try vm.numberValue(@floatFromInt(index));
    defer {
        for (&args) |*arg|
            arg.deinit();
    }

    var arg_ptrs: [9]*const bindings.Value = undefined;
    for (&args, 0..) |*arg, index|
        arg_ptrs[index] = arg;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var started_ns: u64 = 99;
    try std.testing.expectError(error.OutOfMemory, vm.invokeWithTiming(
        failing.allocator(),
        &exec_ctx,
        &entry,
        null,
        &arg_ptrs,
        &started_ns,
    ));
    try std.testing.expectEqual(@as(u64, 0), started_ns);
}

// Only a handler that calls the marker during its own instrumented call records a time. The
// marker and the output it writes through exist only for that call, so a copy kept for later,
// a call that passes no output and a microtask run at turn exit record nothing.
test "invoke timing requires a scoped first-statement marker" {
    var vm = try support.createVm();
    defer vm.deinit();
    try support.registerModule(&vm, "/timed-invoke.js",
        \\let retainedMarker;
        \\export function ok() {
        \\    globalThis.__colloBenchHandlerEntered?.();
        \\    retainedMarker = globalThis.__colloBenchHandlerEntered;
        \\    return "ok";
        \\}
        \\export function fail() {
        \\    globalThis.__colloBenchHandlerEntered?.();
        \\    throw new Error("expected");
        \\}
        \\export function unmarked() { return "unmarked"; }
        \\export function present() { return typeof globalThis.__colloBenchHandlerEntered; }
        \\export function retained() { retainedMarker?.(); return "retained"; }
        \\export function deferred() {
        \\    const marker = globalThis.__colloBenchHandlerEntered;
        \\    Promise.resolve().then(() => marker?.());
        \\    return "deferred";
        \\}
    );
    try support.evaluateOk(&vm, "/timed-invoke.js");
    var entry = try support.getExportOk(&vm, "/timed-invoke.js", "ok");
    defer entry.deinit();
    var throws = try support.getExportOk(&vm, "/timed-invoke.js", "fail");
    defer throws.deinit();
    var unmarked = try support.getExportOk(&vm, "/timed-invoke.js", "unmarked");
    defer unmarked.deinit();
    var present = try support.getExportOk(&vm, "/timed-invoke.js", "present");
    defer present.deinit();
    var retained = try support.getExportOk(&vm, "/timed-invoke.js", "retained");
    defer retained.deinit();
    var deferred = try support.getExportOk(&vm, "/timed-invoke.js", "deferred");
    defer deferred.deinit();
    var exec_ctx = support.makeExecCtx(94);
    var started_ns: u64 = 99;
    try std.testing.expectError(error.InvalidArgument, vm.invokeWithTiming(
        std.testing.allocator,
        &exec_ctx,
        &entry,
        null,
        &.{},
        &started_ns,
    ));
    try std.testing.expectEqual(@as(u64, 0), started_ns);

    try vm.turnEnter(&exec_ctx);
    var turn_active = true;
    defer if (turn_active) {
        vm.turnExit() catch |err| std.debug.panic("turn exit failed: {s}", .{@errorName(err)});
    };
    var absent_before = try support.invokeOk(&vm, &exec_ctx, &present, &.{});
    defer absent_before.deinit();
    try support.expectValueString(&vm, &absent_before, "undefined");
    var no_marker = try timedInvokeOk(&vm, &exec_ctx, &unmarked, &started_ns);
    defer no_marker.deinit();
    try std.testing.expectEqual(@as(u64, 0), started_ns);
    var result = try timedInvokeOk(&vm, &exec_ctx, &entry, &started_ns);
    defer result.deinit();
    try std.testing.expect(started_ns != 0);
    try support.expectValueString(&vm, &result, "ok");
    var absent_after = try support.invokeOk(&vm, &exec_ctx, &present, &.{});
    defer absent_after.deinit();
    try support.expectValueString(&vm, &absent_after, "undefined");
    started_ns = 777;
    var retained_result = try support.invokeOk(&vm, &exec_ctx, &retained, &.{});
    defer retained_result.deinit();
    try std.testing.expectEqual(@as(u64, 777), started_ns);

    started_ns = 0;
    var exception = switch (try vm.invokeWithTiming(
        std.testing.allocator,
        &exec_ctx,
        &throws,
        null,
        &.{},
        &started_ns,
    )) {
        .exception => |value| value,
        .success => |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedException;
        },
    };
    defer exception.deinit();
    try std.testing.expect(started_ns != 0);
    var absent_exception = try support.invokeOk(&vm, &exec_ctx, &present, &.{});
    defer absent_exception.deinit();
    try support.expectValueString(&vm, &absent_exception, "undefined");

    const invalid: bindings.Value = .{};
    try std.testing.expectError(error.InvalidJsValue, vm.invokeWithTiming(
        std.testing.allocator,
        &exec_ctx,
        &invalid,
        null,
        &.{},
        &started_ns,
    ));
    try std.testing.expectEqual(@as(u64, 0), started_ns);

    var deferred_result = try timedInvokeOk(&vm, &exec_ctx, &deferred, &started_ns);
    defer deferred_result.deinit();
    try std.testing.expectEqual(@as(u64, 0), started_ns);
    try vm.turnExit();
    turn_active = false;
    try std.testing.expectEqual(@as(u64, 0), started_ns);
}

fn timedInvokeOk(
    vm: *bindings.Vm,
    exec_ctx: *const bindings.ExecCtx,
    entry: *const bindings.Value,
    started_ns: *u64,
) !bindings.Value {
    return switch (try vm.invokeWithTiming(
        std.testing.allocator, exec_ctx, entry, null, &.{}, started_ns,
    )) {
        .success => |value| value,
        .exception => |value| {
            var exception = value;
            exception.deinit();
            return error.UnexpectedException;
        },
    };
}
