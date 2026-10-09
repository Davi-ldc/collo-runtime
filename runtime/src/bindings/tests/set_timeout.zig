//! Timers from JavaScript to the worker scheduler: `setTimeout` and `setInterval` reach the
//! worker runtime's timer table through the host runtime, and each firing is one scheduler work
//! item, due once the injected clock reaches the delay. The callback gets the global object as
//! `this` and the extra arguments; `clearTimeout` accepts an id passed as a string; an interval
//! whose callback throws keeps firing; a delay is converted to a number, and one that converts
//! to NaN counts as zero; and the four globals are writable and configurable. Lane:
//! `bindings-test`. Timers across requests and the worker's lifecycle are covered in
//! `worker-test` (`worker/tests/runtime/`), and the web-facing contract in the `webapi` lane's
//! `runtime/tests/webapi/timers/`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const worker_testing = @import("collo_worker_test_support");
const rt = @import("collo_test_harness");

fn fakeNow(ctx: ?*anyopaque) u64 {
    return @as(*u64, @ptrCast(@alignCast(ctx.?))).*;
}

test "setTimeout schedules a callback through the Zig runtime" {
    var vm = try support.createVm();
    defer vm.deinit();

    var now_mono_ns: u64 = 1_000;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const module_specifier = "/__collo_route/test/timers.js";
    const request_headers = [_]ipc.RequestHeader{.{ .name = "host", .value = "demo.test" }};
    var dispatch = try ipc.DispatchWork.initOwned(std.testing.allocator, .{
        .request_id = 41,
        .request_generation = 1,
        .authority = "demo.test",
        .deadline_monotonic_ns = 10_000,
        .method = "GET",
        .path = "/timers",
        .raw_query = "",
        .request_headers = &request_headers,
        .body_framing = .none,
        .route_captures = &.{},
        .route_entry_specifier = module_specifier,
    });
    var dispatch_owned = true;
    errdefer if (dispatch_owned)
        dispatch.deinit();
    var request_ctx = try std.testing.allocator.create(worker_testing.RequestContext);
    errdefer std.testing.allocator.destroy(request_ctx);
    request_ctx.* = worker_testing.RequestContext.initOwnedDispatch(
        std.testing.allocator,
        1,
        dispatch,
        .{ .index = 0, .generation = 0 },
        now_mono_ns,
    );
    dispatch_owned = false;
    var request_ctx_owned = true;
    errdefer if (request_ctx_owned) {
        request_ctx.deinit();
        std.testing.allocator.destroy(request_ctx);
    };
    try runtime.requests.active.putNoClobber(std.testing.allocator, 41, request_ctx);
    request_ctx_owned = false;
    defer {
        if (runtime.requests.active.fetchRemove(41)) |removed| {
            removed.value.deinit();
            std.testing.allocator.destroy(removed.value);
        }
    }

    const source =
        \\let marker = "pending";
        \\let intervalCount = 0;
        \\let intervalId = 0;
        \\let throwingIntervalCount = 0;
        \\let throwingIntervalId = 0;
        \\export function schedule() {
        \\    const cancelled = setTimeout(() => {
        \\        marker = "cancelled-fired";
        \\    }, 5);
        \\    clearTimeout(String(cancelled));
        \\    return String(setTimeout(function (text, suffix) {
        \\        marker = text + ":" + suffix + ":" + (this === globalThis);
        \\    }, "5", "done", 7));
        \\}
        \\export function scheduleCoercedImmediate() {
        \\    marker = "waiting";
        \\    return String(setTimeout(() => {
        \\        marker = "coerced-immediate";
        \\    }, "not-a-number"));
        \\}
        \\export function startInterval() {
        \\    intervalId = setInterval(function (label) {
        \\        intervalCount++;
        \\        marker = label + ":" + intervalCount + ":" + (this === globalThis);
        \\        if (intervalCount === 2)
        \\            clearInterval(intervalId);
        \\    }, 5, "tick");
        \\    return String(intervalId);
        \\}
        \\export function startThrowingInterval() {
        \\    throwingIntervalId = setInterval(function () {
        \\        throwingIntervalCount++;
        \\        marker = "throwing:" + throwingIntervalCount;
        \\        if (throwingIntervalCount === 1)
        \\            throw new Error("interval boom");
        \\        clearInterval(throwingIntervalId);
        \\    }, 5);
        \\    return String(throwingIntervalId);
        \\}
        \\export function attrs() {
        \\    const desc = Object.getOwnPropertyDescriptor(globalThis, "setTimeout");
        \\    const clearDesc = Object.getOwnPropertyDescriptor(globalThis, "clearTimeout");
        \\    const intervalDesc = Object.getOwnPropertyDescriptor(globalThis, "setInterval");
        \\    const clearIntervalDesc = Object.getOwnPropertyDescriptor(globalThis, "clearInterval");
        \\    return JSON.stringify({
        \\        writable: !!desc.writable,
        \\        configurable: !!desc.configurable,
        \\        clearWritable: !!clearDesc.writable,
        \\        clearConfigurable: !!clearDesc.configurable,
        \\        intervalWritable: !!intervalDesc.writable,
        \\        intervalConfigurable: !!intervalDesc.configurable,
        \\        clearIntervalWritable: !!clearIntervalDesc.writable,
        \\        clearIntervalConfigurable: !!clearIntervalDesc.configurable
        \\    });
        \\}
        \\export function read() {
        \\    return marker;
        \\}
    ;

    try support.registerModule(&vm, module_specifier, source);
    try support.evaluateOk(&vm, module_specifier);

    var schedule = try support.getExportOk(&vm, module_specifier, "schedule");
    defer schedule.deinit();

    var read = try support.getExportOk(&vm, module_specifier, "read");
    defer read.deinit();

    var start_interval = try support.getExportOk(&vm, module_specifier, "startInterval");
    defer start_interval.deinit();

    var start_throwing_interval = try support.getExportOk(&vm, module_specifier, "startThrowingInterval");
    defer start_throwing_interval.deinit();

    var schedule_coerced_immediate = try support.getExportOk(&vm, module_specifier, "scheduleCoercedImmediate");
    defer schedule_coerced_immediate.deinit();

    var attrs = try support.getExportOk(&vm, module_specifier, "attrs");
    defer attrs.deinit();

    var exec_ctx = support.makeExecCtx(41);
    try vm.turnEnter(&exec_ctx);
    var attrs_result = try support.invokeOk(&vm, &exec_ctx, &attrs, &.{});
    defer attrs_result.deinit();
    try support.expectValueString(&vm, &attrs_result, "{\"writable\":true,\"configurable\":true,\"clearWritable\":true,\"clearConfigurable\":true,\"intervalWritable\":true,\"intervalConfigurable\":true,\"clearIntervalWritable\":true,\"clearIntervalConfigurable\":true}");
    var timer_id = try support.invokeOk(&vm, &exec_ctx, &schedule, &.{});
    defer timer_id.deinit();
    try vm.turnExit();

    now_mono_ns += 5 * std.time.ns_per_ms;
    try runtime.collectDueTimers();
    const item = runtime.scheduler.ready_queue.pop() orelse return error.MissingTimerWork;
    try worker_testing.executeWorkItem(&runtime, item);

    try vm.turnEnter(&exec_ctx);
    var result = try support.invokeOk(&vm, &exec_ctx, &read, &.{});
    defer result.deinit();
    try support.expectValueString(&vm, &result, "done:7:true");
    try vm.turnExit();

    try vm.turnEnter(&exec_ctx);
    var interval_id = try support.invokeOk(&vm, &exec_ctx, &start_interval, &.{});
    defer interval_id.deinit();
    try vm.turnExit();

    now_mono_ns += 5 * std.time.ns_per_ms;
    try runtime.collectDueTimers();
    const first_interval = runtime.scheduler.ready_queue.pop() orelse return error.MissingTimerWork;
    try worker_testing.executeWorkItem(&runtime, first_interval);

    try vm.turnEnter(&exec_ctx);
    var interval_first = try support.invokeOk(&vm, &exec_ctx, &read, &.{});
    defer interval_first.deinit();
    try support.expectValueString(&vm, &interval_first, "tick:1:true");
    try vm.turnExit();

    now_mono_ns += 5 * std.time.ns_per_ms;
    try runtime.collectDueTimers();
    const second_interval = runtime.scheduler.ready_queue.pop() orelse return error.MissingTimerWork;
    try worker_testing.executeWorkItem(&runtime, second_interval);

    try vm.turnEnter(&exec_ctx);
    var interval_second = try support.invokeOk(&vm, &exec_ctx, &read, &.{});
    defer interval_second.deinit();
    try support.expectValueString(&vm, &interval_second, "tick:2:true");
    try vm.turnExit();

    now_mono_ns += 5 * std.time.ns_per_ms;
    try runtime.collectDueTimers();
    try std.testing.expect(runtime.scheduler.ready_queue.pop() == null);

    try vm.turnEnter(&exec_ctx);
    var throwing_interval_id = try support.invokeOk(&vm, &exec_ctx, &start_throwing_interval, &.{});
    defer throwing_interval_id.deinit();
    try vm.turnExit();

    now_mono_ns += 5 * std.time.ns_per_ms;
    try runtime.collectDueTimers();
    const throwing_first_interval = runtime.scheduler.ready_queue.pop() orelse return error.MissingTimerWork;
    try worker_testing.executeWorkItem(&runtime, throwing_first_interval);

    try vm.turnEnter(&exec_ctx);
    var throwing_first = try support.invokeOk(&vm, &exec_ctx, &read, &.{});
    defer throwing_first.deinit();
    try support.expectValueString(&vm, &throwing_first, "throwing:1");
    try vm.turnExit();

    now_mono_ns += 5 * std.time.ns_per_ms;
    try runtime.collectDueTimers();
    const throwing_second_interval = runtime.scheduler.ready_queue.pop() orelse return error.MissingTimerWork;
    try worker_testing.executeWorkItem(&runtime, throwing_second_interval);

    try vm.turnEnter(&exec_ctx);
    var throwing_second = try support.invokeOk(&vm, &exec_ctx, &read, &.{});
    defer throwing_second.deinit();
    try support.expectValueString(&vm, &throwing_second, "throwing:2");
    try vm.turnExit();

    now_mono_ns += 5 * std.time.ns_per_ms;
    try runtime.collectDueTimers();
    try std.testing.expect(runtime.scheduler.ready_queue.pop() == null);

    try vm.turnEnter(&exec_ctx);
    var coerced_id = try support.invokeOk(&vm, &exec_ctx, &schedule_coerced_immediate, &.{});
    defer coerced_id.deinit();
    try vm.turnExit();

    try runtime.collectDueTimers();
    const coerced_item = runtime.scheduler.ready_queue.pop() orelse return error.MissingTimerWork;
    try worker_testing.executeWorkItem(&runtime, coerced_item);

    try vm.turnEnter(&exec_ctx);
    var coerced_result = try support.invokeOk(&vm, &exec_ctx, &read, &.{});
    defer coerced_result.deinit();
    try support.expectValueString(&vm, &coerced_result, "coerced-immediate");
    try vm.turnExit();
}
