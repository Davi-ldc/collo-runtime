//! Covers the sentinel's deadline set (`runtime/sentinel.zig`) and the turn
//! ownership it fires under. The set holds one deadline per request
//! identity, up to `max_armed_deadlines`, so arming one request never erases
//! another's deadline. An expired deadline fires only while its own request
//! is the published turn owner, because a termination stops whatever
//! JavaScript is running. A timer callback turn is published under the
//! request that owns the timer, so that request's deadline can stop a
//! callback that hangs. A fire that no response path read is still folded
//! into the worker's stop when its request is disarmed.
//!
//! The set tests drive a `Sentinel` directly. It measures real monotonic
//! time, and inside a full runtime a real deadline would race the module
//! evaluation turns the harness drives on its fake clock. The runtime tests
//! pay that real-time cost end to end. Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const process = @import("collo_os").process;

const sentinel = worker.testing.sentinel;
const fakeNow = rt.fakeNow;
const socketPairType = rt.socketPairType;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;

/// A termination hook that counts requests instead of terminating the VM,
/// so the set tests can watch fires without any JavaScript running.
const TestTermination = struct {
    requested_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn request(ctx: *anyopaque) !void {
        const self: *TestTermination = @ptrCast(@alignCast(ctx));
        _ = self.requested_count.fetchAdd(1, .acq_rel);
    }
};

/// Polls until the sentinel marks the entry fired; fails with
/// `error.SentinelDeadlineDidNotFire` after `budget_ns` of real time.
fn waitRequested(
    guard: *sentinel.Sentinel,
    request_id: u64,
    generation: u64,
    budget_ns: u64,
) !void {
    const stop = process.monotonicNowNsOrZero() + budget_ns;
    while (!guard.terminationWasRequested(request_id, generation)) {
        if (process.monotonicNowNsOrZero() >= stop)
            return error.SentinelDeadlineDidNotFire;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "co-scheduled deadlines fire at their own turn and survive each other" {
    var vm = try support.createVm();
    defer vm.deinit();
    var termination = TestTermination{};

    var guard = try sentinel.Sentinel.init(&vm, .{
        .termination_hook = .{
            .ctx = &termination,
            .request = TestTermination.request,
        },
    });
    defer guard.deinit();

    const request_a: u64 = 11;
    const request_b: u64 = 22;
    const now = process.monotonicNowNsOrZero();
    // Both deadlines stay armed: arming B must not erase A's.
    const generation_a = try guard.arm(request_a, now + 20 * std.time.ns_per_ms);
    const generation_b = try guard.arm(request_b, now + 600 * std.time.ns_per_ms);

    // B's turn holds the loop while A's deadline expires. A termination
    // would stop B's JavaScript, so A's deadline must not fire while B owns
    // the turn.
    guard.publishTurnOwner(request_b);
    try guard.start();

    std.Thread.sleep(120 * std.time.ns_per_ms);
    try std.testing.expect(!guard.terminationWasRequested(request_a, generation_a));
    try std.testing.expect(!guard.terminationWasRequested(request_b, generation_b));
    try std.testing.expectEqual(@as(u32, 0), termination.requested_count.load(.acquire));

    // A's turn takes the loop and hangs. The entry that expired while B
    // owned the turn now matches the owner, and the sentinel's recheck tick
    // (`foreign_expiry_recheck_ns`) fires it.
    guard.publishTurnOwner(request_a);
    try waitRequested(&guard, request_a, generation_a, 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), termination.requested_count.load(.acquire));
    try std.testing.expect(!guard.terminationWasRequested(request_b, generation_b));

    // Disarming A stands in for its cooperative 504. B's deadline is still
    // in the set and fires at its own instant, once B owns the turn.
    guard.disarm(request_a, generation_a);
    guard.publishTurnOwner(request_b);
    try waitRequested(&guard, request_b, generation_b, 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 2), termination.requested_count.load(.acquire));
    guard.clearTurnOwner();
}

test "hung timer callback is terminated by its owning request's deadline" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    try runtime.startSentinel();

    // The callback's busy-wait ends on its own after 8 s, so a callback
    // turn published under the wrong owner fails the elapsed-time check
    // below instead of hanging the lane.
    const specifier = "/__collo_route/demo/arbiter-hung-timer.js";
    const route_index = try rt.registerRoute(&runtime, specifier,
        \\export default function handle() {
        \\    setTimeout(() => {
        \\        const end = Date.now() + 8000;
        \\        while (Date.now() < end) {}
        \\        globalThis.__escaped = true;
        \\    }, 0);
        \\    return new Promise(() => {});
        \\}
    );

    // The deadline is real monotonic time, which the sentinel thread reads,
    // while the runtime's fake clock keeps the cooperative deadline heap
    // from firing. The termination can therefore come only from the
    // sentinel seeing the timer turn published under this request.
    const request_id: u64 = 91;
    const deadline_ns = process.monotonicNowNsOrZero() + 400 * std.time.ns_per_ms;
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = deadline_ns,
        .request = .{ .path = "/hung-timer" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/hung-timer" });

    // The request turn evaluates the route, schedules the timer and parks on
    // a promise that never settles, so the request stays active with its
    // deadline armed.
    try executeNextReady(&runtime);
    const request_ctx = runtime.requests.active.get(request_id) orelse
        return error.RequestNotActive;
    try std.testing.expect(request_ctx.deadline_armed);

    // The zero-delay timer is due on the fake clock. Its callback turn hangs
    // until the sentinel terminates the VM at the request's real deadline.
    try runtime.collectDueTimers();
    const hang_started_ns = process.monotonicNowNsOrZero();
    try executeNextReady(&runtime);
    const hang_ns = process.monotonicNowNsOrZero() - hang_started_ns;

    // The request's deadline stops the turn after about 400 ms, long before
    // the callback's own 8 s exit. A callback turn published with no owner
    // would match no deadline and run until that exit.
    try std.testing.expect(hang_ns < 4 * std.time.ns_per_s);
    {
        const guard = &runtime.observability.sentinel;
        try std.testing.expect(guard.terminationWasRequested(
            request_id,
            request_ctx.deadline_generation,
        ));
    }

    // The termination stopped only the hung turn. The request stays active
    // for its cooperative 504, and the worker keeps running until that
    // response is written, so the response is not lost.
    try std.testing.expect(runtime.core.running);
    try std.testing.expect(runtime.requests.active.contains(request_id));

    // The fake clock reaches the deadline, and the deadline turn reads the
    // fire and writes the request's 504.
    now_mono_ns = deadline_ns + std.time.ns_per_ms;
    try executeUntilRequestDone(&runtime, request_id);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);

    // The VM is created with `forbidExecutionOnTermination`, so the fire
    // forbade execution for good. With the response written and nothing
    // left queued, the worker stops instead of answering every later
    // request with a 500.
    runtime.maybeRecycleAfterFailedEvaluation();
    try std.testing.expect(!runtime.core.running);
}

test "an unsampled terminal folds the sentinel fire into the self-stop at the disarm chokepoint" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{
        .clock = .{
            .ctx = &now_mono_ns,
            .now_fn = fakeNow,
        },
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    try runtime.startSentinel();

    const specifier = "/__collo_route/demo/arbiter-unsampled-terminal.js";
    const route_index = try rt.registerRoute(&runtime, specifier,
        \\export default function handle() {
        \\    setTimeout(() => {
        \\        const end = Date.now() + 8000;
        \\        while (Date.now() < end) {}
        \\    }, 0);
        \\    return new Promise(() => {});
        \\}
    );

    const request_id: u64 = 92;
    const deadline_ns = process.monotonicNowNsOrZero() + 400 * std.time.ns_per_ms;
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = deadline_ns,
        .request = .{ .path = "/unsampled" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{ .path = "/unsampled" });

    try executeNextReady(&runtime);
    const request_ctx = runtime.requests.active.get(request_id) orelse
        return error.RequestNotActive;
    try std.testing.expect(request_ctx.deadline_armed);

    // Drive the hung timer turn until the sentinel fires requestTermination.
    try runtime.collectDueTimers();
    try executeNextReady(&runtime);
    {
        const guard = &runtime.observability.sentinel;
        try std.testing.expect(guard.terminationWasRequested(
            request_id,
            request_ctx.deadline_generation,
        ));
    }

    // A terminal path that never reads the fire, such as one after the turn
    // or an extract exception turned into a local 500, reaches
    // `disarmRequestDeadline` directly. The fired bit must be folded into
    // `stop_after_deadline_fire` there instead of being dropped with the
    // entry.
    try std.testing.expect(!runtime.stop_after_deadline_fire);
    runtime.disarmRequestDeadline(request_ctx);
    try std.testing.expect(runtime.stop_after_deadline_fire);
}

test "re-arming the same identity replaces its entry without disturbing neighbors" {
    var vm = try support.createVm();
    defer vm.deinit();
    var termination = TestTermination{};

    var guard = try sentinel.Sentinel.init(&vm, .{
        .termination_hook = .{
            .ctx = &termination,
            .request = TestTermination.request,
        },
    });
    defer guard.deinit();

    const request_a: u64 = 11;
    const request_b: u64 = 22;
    const now = process.monotonicNowNsOrZero();
    const generation_a = try guard.arm(request_a, now + 30 * std.time.ns_per_s);
    const generation_b = try guard.arm(request_b, now + 300 * std.time.ns_per_ms);

    // Arming an identity the set already holds replaces its entry in place
    // with a fresh generation: the old generation goes stale and no second
    // entry appears.
    const rearmed_a = try guard.arm(request_a, now + 10 * std.time.ns_per_ms);
    try std.testing.expect(rearmed_a != generation_a);
    try std.testing.expect(!guard.terminationWasRequested(request_a, generation_a));

    // The replacement's deadline governs: the original sat 30 s out, so a
    // fire within the 2 s wait can only come from the replacement.
    guard.publishTurnOwner(request_a);
    try guard.start();
    try waitRequested(&guard, request_a, rearmed_a, 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), termination.requested_count.load(.acquire));
    try std.testing.expect(!guard.terminationWasRequested(request_b, generation_b));

    // The neighbor's entry was untouched and still fires on its own
    // deadline, in its own turn.
    guard.disarm(request_a, rearmed_a);
    guard.publishTurnOwner(request_b);
    try waitRequested(&guard, request_b, generation_b, 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 2), termination.requested_count.load(.acquire));
    guard.clearTurnOwner();
}

test "a fourth distinct identity is refused while a full set still re-arms in place" {
    var vm = try support.createVm();
    defer vm.deinit();

    var guard = try sentinel.Sentinel.init(&vm, .{});
    defer guard.deinit();

    const now = process.monotonicNowNsOrZero();
    var generations: [sentinel.max_armed_deadlines]u64 = undefined;
    for (&generations, 0..) |*generation, index|
        generation.* = try guard.arm(@as(u64, index) + 1, now + 30 * std.time.ns_per_s);

    // `max_armed_deadlines` covers every deadline that can be live at once,
    // the co-scheduled requests plus the boot context, so one more distinct
    // identity is refused and displaces nobody.
    try std.testing.expectError(
        error.DeadlineSetFull,
        guard.arm(sentinel.max_armed_deadlines + 1, now + 30 * std.time.ns_per_s),
    );
    for (generations, 0..) |generation, index|
        try std.testing.expect(!guard.terminationWasRequested(@as(u64, index) + 1, generation));

    // Replacing an entry admits nothing new, so a held identity still
    // re-arms in place at a full set, with a fresh generation.
    const rearmed = try guard.arm(1, now + 60 * std.time.ns_per_s);
    try std.testing.expect(rearmed != generations[0]);
}

test "disarm with a stale generation is a no-op and the live entry still fires" {
    var vm = try support.createVm();
    defer vm.deinit();
    var termination = TestTermination{};

    var guard = try sentinel.Sentinel.init(&vm, .{
        .termination_hook = .{
            .ctx = &termination,
            .request = TestTermination.request,
        },
    });
    defer guard.deinit();

    const request_id: u64 = 11;
    const now = process.monotonicNowNsOrZero();
    const stale_generation = try guard.arm(request_id, now + 30 * std.time.ns_per_s);
    const live_generation = try guard.arm(request_id, now + 10 * std.time.ns_per_ms);

    // A disarm that carries a replaced entry's generation is stale
    // (`Sentinel.disarm`) and must not remove the live entry.
    guard.disarm(request_id, stale_generation);

    guard.publishTurnOwner(request_id);
    try guard.start();
    try waitRequested(&guard, request_id, live_generation, 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u32, 1), termination.requested_count.load(.acquire));
    guard.clearTurnOwner();
}
