//! Covers the runtime's scheduling bookkeeping with a VM but no JavaScript:
//! one id counter shared by timers and immediates, the active request every
//! timer, immediate and fetch needs, the callback budget timers and
//! immediates share, the requeue slot a running interval holds, immediates
//! collected one generation at a time, the backlog behind a full ready
//! queue, how `Runtime.init` takes the benchmark marker switch and resolves
//! limits left at zero, and the precedence of a turn's outcomes
//! (`js/jsc/turn.zig:turnOutcome`). Timer and immediate callbacks that run
//! JavaScript are covered by the web API `timers` suite (`runtime/tests/webapi/timers/`,
//! `webapi-test`), and the cancellation of a finished request's timers and
//! immediates by `lifecycle.zig`. Runs in `worker-test`.

const std = @import("std");
const bindings = @import("collo_bindings");
const worker_limits = @import("collo_limits").worker;
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

test "runtime assigns timer ids monotonically" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    const active = try rt.ActiveRequest.init(std.testing.allocator, &runtime, 123, 1_000);
    defer active.deinit();

    const first = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, null, 5, false);
    const second = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, null, 10, false);

    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expectEqual(@as(u64, 2), second);
}

test "timer scheduling requires an active request" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    try std.testing.expectError(error.TimerOutsideActiveRequest, runtime.scheduleTimer(0, .{ .inner = .{} }, null, null, 5, false));
    try std.testing.expectError(error.TimerOutsideActiveRequest, runtime.scheduleTimer(999, .{ .inner = .{} }, null, null, 5, false));
}

test "runtime assigns ids across timers and immediates" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    const active = try rt.ActiveRequest.init(std.testing.allocator, &runtime, 123, 1_000);
    defer active.deinit();

    const timer_id = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, null, 5, false);
    const immediate_id = try runtime.scheduleImmediate(123, .{ .inner = .{} }, null, null);

    try std.testing.expectEqual(@as(u64, 1), timer_id);
    try std.testing.expectEqual(@as(u64, 2), immediate_id);
}

test "immediate scheduling requires an active request" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    try std.testing.expectError(
        error.TimerOutsideActiveRequest,
        runtime.scheduleImmediate(0, .{ .inner = .{} }, null, null),
    );
    try std.testing.expectError(
        error.TimerOutsideActiveRequest,
        runtime.scheduleImmediate(999, .{ .inner = .{} }, null, null),
    );
}

test "immediate scheduling shares worker callback limit" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .limits = .{ .max_timers_per_worker = 1 },
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    const active = try rt.ActiveRequest.init(std.testing.allocator, &runtime, 123, 1_000);
    defer active.deinit();

    _ = try runtime.scheduleImmediate(123, .{ .inner = .{} }, null, null);
    try std.testing.expectError(
        error.TimerWorkerLimitExceeded,
        runtime.scheduleTimer(123, .{ .inner = .{} }, null, null, 5, false),
    );
}

test "runtime collects immediates by generation" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    const active = try rt.ActiveRequest.init(std.testing.allocator, &runtime, 123, 1_000);
    defer active.deinit();

    const first = try runtime.scheduleImmediate(123, .{ .inner = .{} }, null, null);
    try runtime.collectReadyImmediates();
    try std.testing.expectEqual(first, runtime.scheduler.ready_queue.pop().?.immediate_callback);

    // The second immediate waits while the first is still in the ready map;
    // removing the first stands in for its callback having run.
    const second = try runtime.scheduleImmediate(123, .{ .inner = .{} }, null, null);
    try runtime.collectReadyImmediates();
    try std.testing.expect(runtime.scheduler.ready_queue.pop() == null);

    if (runtime.scheduler.ready_immediate_callbacks.fetchRemove(first)) |removed| {
        var immediate = removed.value;
        immediate.deinit(std.testing.allocator);
    } else {
        return error.MissingReadyImmediate;
    }

    try runtime.collectReadyImmediates();
    try std.testing.expectEqual(second, runtime.scheduler.ready_queue.pop().?.immediate_callback);
}

test "running interval reserves its requeue timer capacity" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .limits = .{ .max_timers_per_worker = 2 },
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    const active = try rt.ActiveRequest.init(std.testing.allocator, &runtime, 123, 1_000);
    defer active.deinit();

    runtime.scheduler.executing_repeating_timer_reserved = true;
    _ = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, null, 5, false);
    try std.testing.expectError(
        error.TimerWorkerLimitExceeded,
        runtime.scheduleTimer(123, .{ .inner = .{} }, null, null, 5, false),
    );
}

test "canceling running interval releases its reserved requeue slot" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .limits = .{ .max_timers_per_worker = 1 },
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    const active = try rt.ActiveRequest.init(std.testing.allocator, &runtime, 123, 1_000);
    defer active.deinit();

    runtime.scheduler.executing_timer_id = 7;
    runtime.scheduler.executing_timer_request_id = 123;
    runtime.scheduler.executing_repeating_timer_reserved = true;
    runtime.cancelTimeout(123, 7);
    try std.testing.expect(runtime.scheduler.executing_timer_cancelled);
    try std.testing.expect(!runtime.scheduler.executing_repeating_timer_reserved);
    _ = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, null, 5, false);
}

test "fetch scheduling requires an active request" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    try std.testing.expectError(
        error.FetchOutsideActiveRequest,
        runtime.scheduleFetch(0, .{
            .url = "https://example.com/",
            .method = "GET",
            .body = "",
            .headers = &.{},
            .flags = 0,
        }, .{}),
    );
}

test "ready work falls back to backlog and marks rescan when both queues are full" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = null,
        .limits = .{ .ready_queue_capacity = 1 },
        .now_fn = struct {
            fn now(_: ?*anyopaque) u64 {
                return 1_000;
            }
        }.now,
    });
    defer runtime.deinit();

    // Items other than egress ones fill the backlog only to the ready queue's
    // capacity, one slot each here, so the third item finds both full and
    // marks its kind for a rescan.
    try std.testing.expect(runtime.tryQueueReadyWork(.{ .request = 1 }));
    try std.testing.expect(runtime.tryQueueReadyWork(.{ .request = 2 }));
    try std.testing.expect(!runtime.tryQueueReadyWork(.{ .request = 3 }));
    try std.testing.expect(runtime.scheduler.ingress_rescan_needed);

    try std.testing.expectEqual(@as(u64, 1), runtime.scheduler.ready_queue.pop().?.request);
    runtime.drainReadyBacklog();
    try std.testing.expectEqual(@as(u64, 2), runtime.scheduler.ready_queue.pop().?.request);
}

// The handler benchmark switch must not publish a sample before a request
// enters its handler.
test "the handler benchmark switch publishes nothing before a request enters its handler" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(
        std.testing.allocator,
        &vm,
        null,
        &completion_fixture.view,
        try rt.createCompletionEventfd(),
        .{ .bench_handler = true },
    );
    defer runtime.deinit();
    try std.testing.expect(runtime.observability.bench_handler);
    try std.testing.expect(completion_fixture.reader.loadBenchHandler() == null);
}

test "runtime limits default to the worker constants" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{});
    defer runtime.deinit();

    try std.testing.expect(!runtime.observability.bench_handler);
    try std.testing.expectEqual(worker_limits.timers_per_worker_max, runtime.core.limits.max_timers_per_worker);
    try std.testing.expectEqual(worker_limits.ready_queue_capacity, runtime.core.limits.ready_queue_capacity);
    try std.testing.expectEqual(worker_limits.request_task_capacity, runtime.core.limits.request_task_capacity);
    try std.testing.expectEqual(
        worker_limits.ready_queue_capacity + worker_limits.egress_ready_items_max,
        runtime.scheduler.ready_backlog.items.len,
    );
}

// The drain's exception used to replace any operation result, a Zig error
// included, so an out-of-memory became the tenant's `js_exception` instead
// of reaching the request's boundary.
test "a turn's operation error wins over its drain's exception, and its exit error over both" {
    const turnOutcome = worker.testing.turn.turnOutcome;
    try std.testing.expectEqual(.operation_error, turnOutcome(false, true, true));
    try std.testing.expectEqual(.operation_error, turnOutcome(false, true, false));
    try std.testing.expectEqual(.drain_exception, turnOutcome(false, false, true));
    try std.testing.expectEqual(.operation, turnOutcome(false, false, false));
    try std.testing.expectEqual(.exit_error, turnOutcome(true, true, true));
    try std.testing.expectEqual(.exit_error, turnOutcome(true, false, false));
}
