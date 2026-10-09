//! Covers the runtime's scheduling bookkeeping with a VM but no JavaScript:
//! one id counter shared by timers and immediates, the active request every
//! timer, immediate and fetch needs, the callback budget timers and
//! immediates share, the requeue slot a running interval holds, immediates
//! collected one generation at a time, the backlog behind a full ready
//! queue, and how `Runtime.init` takes its boot flags and resolves limits
//! left at zero. Timer and immediate callbacks that run JavaScript are
//! covered by the web API `timers` suite (`runtime/tests/webapi/timers/`,
//! `webapi-test`), and the cancellation of a finished request's timers and
//! immediates by `lifecycle.zig`. Runs in `worker-test`.

const std = @import("std");
const bindings = @import("collo_bindings");
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

    const first = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, 5, false);
    const second = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, 10, false);

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

    try std.testing.expectError(error.TimerOutsideActiveRequest, runtime.scheduleTimer(0, .{ .inner = .{} }, null, 5, false));
    try std.testing.expectError(error.TimerOutsideActiveRequest, runtime.scheduleTimer(999, .{ .inner = .{} }, null, 5, false));
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

    const timer_id = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, 5, false);
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
        runtime.scheduleTimer(123, .{ .inner = .{} }, null, 5, false),
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
    _ = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, 5, false);
    try std.testing.expectError(
        error.TimerWorkerLimitExceeded,
        runtime.scheduleTimer(123, .{ .inner = .{} }, null, 5, false),
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
    _ = try runtime.scheduleTimer(123, .{ .inner = .{} }, null, 5, false);
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
        runtime.scheduleFetch(0, "https://example.com/", "GET", "", &.{}, 0, .{}),
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

    // The backlog has the ready queue's capacity, one slot each here, so the
    // third item finds both full and marks its kind for a rescan.
    try std.testing.expect(runtime.tryQueueReadyWork(.{ .request = 1 }));
    try std.testing.expect(runtime.tryQueueReadyWork(.{ .request = 2 }));
    try std.testing.expect(!runtime.tryQueueReadyWork(.{ .fetch_completion = 3 }));
    try std.testing.expect(runtime.egress.state.fetch_task_rescan_needed);

    try std.testing.expectEqual(@as(u64, 1), runtime.scheduler.ready_queue.pop().?.request);
    runtime.drainReadyBacklog();
    try std.testing.expectEqual(@as(u64, 2), runtime.scheduler.ready_queue.pop().?.request);
}

// The handler benchmark flag must neither turn on request tracing nor
// publish a sample before a request enters its handler.
test "handler benchmark option is independent of request tracing" {
    const ipc = @import("collo_ipc");
    const boot = ipc.WorkerRuntimeBootOptions{
        .runtime_flags = ipc.WorkerRuntimeBootOptions.flag_bench_handler,
    };
    try boot.validate();
    try std.testing.expectEqual(@as(u32, 0), boot.runtime_flags &
        (ipc.WorkerRuntimeBootOptions.flag_trace_requests |
            ipc.WorkerRuntimeBootOptions.flag_trace_all_requests));
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
    try std.testing.expect(!runtime.observability.trace_requests);
    try std.testing.expect(!runtime.observability.trace_all_requests);
    try std.testing.expect(completion_fixture.view.loadBenchHandler() == null);
}

test "runtime consumes pre-resolved boot flags and normalizes auto limits" {
    var vm = try bindings.Vm.createDefault();
    defer vm.deinit();

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, null, &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .trace_requests = true,
        .trace_all_requests = true,
        .log_full_js_exceptions = false,
        .limits = .{
            .crypto_thread_count = 0,
            .crypto_thread_stack_bytes = 0,
            .crypto_max_in_flight_per_request = 0,
            .crypto_max_in_flight_per_worker = 0,
        },
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.observability.trace_requests);
    try std.testing.expect(runtime.observability.trace_all_requests);
    try std.testing.expect(!runtime.observability.bench_handler);
    // A zero limit resolves to the default of `ipc.WorkerRuntimeBootOptions`,
    // and the per-worker crypto cap to `request_task_capacity` times the
    // per-request cap (`resolveAutoRuntimeLimits` in `runtime/types.zig`).
    try std.testing.expectEqual(@as(usize, 2), runtime.core.limits.crypto_thread_count);
    try std.testing.expectEqual(
        @as(usize, 4 * 1024 * 1024),
        runtime.core.limits.crypto_thread_stack_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 6),
        runtime.core.limits.crypto_max_in_flight_per_request,
    );
    try std.testing.expectEqual(
        @as(usize, 384),
        runtime.core.limits.crypto_max_in_flight_per_worker,
    );
}
