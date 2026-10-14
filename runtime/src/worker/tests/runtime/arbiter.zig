//! Covers the sentinel's fires inside a running runtime and what follows
//! them (`runtime/sentinel.zig`, `runtime/owner.zig`, `runtime/retirement.zig`,
//! `serve/termination.zig`). A timer callback turn runs in the window of the
//! owner of the timer, so that owner's deadline stops a callback that hangs,
//! and so it stops a stream source's pull or a sink's abort inside a
//! signal's abort, whose cleanup then runs on the terminated VM. A fire
//! poisons the VM for good: the loop's retirement check answers the
//! request it stopped by its cause, sends the server one `worker_retiring`
//! notice and keeps serving, and a begin that arrives after it answers 503
//! `worker_retiring` without running JavaScript. A top-level turn that never
//! yields is stopped by its own evaluation's budget, which fails only its
//! route and still retires the worker. A request already past its deadline
//! when its work item comes up is answered without running the item's
//! JavaScript, and the VM stays in service.
//!
//! The sentinel measures real monotonic time, while the runtime here reads a
//! fake clock, so a deadline that should fire is set in real time and the
//! fake clock only steers the cooperative deadline heap. The sentinel on its
//! own is covered in `worker/tests/sentinel.zig`. Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const process = @import("collo_os").process;
const request_context = @import("collo_worker_request").context;
const retirement_notice = @import("retirement_notice.zig");

const sentinel = worker.testing.sentinel;
const fakeNow = rt.fakeNow;
const socketPairType = rt.socketPairType;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;

/// A runtime on a fake clock with its sentinel started, as the arbiter
/// tests drive it.
const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    completion: rt.CompletionFixture,
    now_mono_ns: u64,
    runtime: worker.Runtime,

    /// `start_sentinel` starts the sentinel's thread. A test whose deadlines
    /// live on the fake clock leaves it stopped: in real time they are long
    /// past, and a running sentinel would stop the first owner that
    /// publishes one.
    fn init(self: *Fixture, start_mono_ns: u64, start_sentinel: bool) !void {
        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer {
            std.posix.close(self.control_pair[0]);
            std.posix.close(self.control_pair[1]);
        }
        self.completion = try rt.CompletionFixture.init();
        errdefer self.completion.deinit();
        self.now_mono_ns = start_mono_ns;
        self.runtime = try worker.Runtime.init(
            std.testing.allocator,
            &self.vm,
            self.control_pair[0],
            &self.completion.view,
            try rt.createCompletionEventfd(),
            worker.RuntimeOptions{ .clock = .{ .ctx = &self.now_mono_ns, .now_fn = fakeNow } },
        );
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
        if (start_sentinel)
            try self.runtime.startSentinel();
    }

    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        std.posix.close(self.control_pair[0]);
        std.posix.close(self.control_pair[1]);
        self.vm.deinit();
    }

    fn serverFd(self: *const Fixture) std.posix.fd_t {
        return self.control_pair[1];
    }
};

fn enqueue(runtime: *worker.Runtime, request_id: u64, route_index: u16, stream_id: u32, deadline_ns: u64) !void {
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = deadline_ns,
        .request = .{ .path = "/arbiter" },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, stream_id, .{ .path = "/arbiter" });
}

test "a hung timer callback is stopped by its request's deadline, which answers 504, and the worker announces vm_terminated and answers a later begin 503 without JavaScript" {
    var fixture: Fixture = undefined;
    try fixture.init(0, true);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // The callback's busy-wait ends on its own after 8 s, so a callback turn
    // published under the wrong owner fails the elapsed-time check below
    // instead of hanging the lane.
    const route_index = try rt.registerRoute(runtime, "/var/task/arbiter-hung-timer.js",
        \\export default function handle(request) {
        \\    globalThis.__handled = (globalThis.__handled ?? 0) + 1;
        \\    setTimeout(() => {
        \\        const end = Date.now() + 8000;
        \\        while (Date.now() < end) {}
        \\    }, 0);
        \\    return new Promise(() => {});
        \\}
    );

    // The deadline is real monotonic time, which the sentinel thread reads,
    // while the runtime's fake clock keeps the cooperative deadline heap
    // from firing, so only the sentinel can stop the turn.
    const request_id: u64 = 91;
    try enqueue(runtime, request_id, route_index, 1, process.monotonicNowNsOrZero() + 400 * std.time.ns_per_ms);
    try executeNextReady(runtime);
    try std.testing.expect(runtime.requests.active.contains(request_id));

    try runtime.collectDueTimers();
    const hang_started_ns = process.monotonicNowNsOrZero();
    try executeNextReady(runtime);
    try std.testing.expect(process.monotonicNowNsOrZero() - hang_started_ns < 4 * std.time.ns_per_s);
    const fired = runtime.observability.sentinel.fired() orelse return error.SentinelDidNotFire;
    try std.testing.expectEqual(request_id, fired.owner_id);
    try std.testing.expectEqual(sentinel.Cause.deadline, fired.cause);

    // Nothing has stopped the worker: the loop's check answers the fire.
    try std.testing.expect(runtime.core.running);
    try std.testing.expect(!runtime.vm_terminated);
    try runtime.checkRetirement();
    try std.testing.expect(runtime.vm_terminated);
    try std.testing.expectEqual(ipc.WorkerRetiringReason.vm_terminated, runtime.retirement.reason.?);
    try std.testing.expectEqual(ipc.WorkerRetiringReason.vm_terminated, try retirement_notice.read(fixture.serverFd()));
    var response = try rt.readIngressResponse(runtime, fixture.serverFd(), request_id);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.deadline_timeout, response.doneStatus());

    // A second check sends nothing more: the server needs one notice.
    try runtime.checkRetirement();
    try retirement_notice.expectNone(fixture.serverFd());

    // The worker keeps serving what reaches it, and a begin that arrives
    // after the notice runs none of its JavaScript.
    const late_id: u64 = 92;
    try enqueue(runtime, late_id, route_index, 3, process.monotonicNowNsOrZero() + std.time.ns_per_min);
    try executeUntilRequestDone(runtime, late_id);
    var late = try rt.readIngressResponse(runtime, fixture.serverFd(), late_id);
    defer late.deinit();
    try std.testing.expectEqual(@as(u16, 503), late.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.worker_retiring, late.doneStatus());
    try std.testing.expect(runtime.core.running);
}

test "a top-level turn that never yields is stopped by its own evaluation's budget, which fails only its route and retires the worker" {
    // An evaluation's budget is the fake clock plus the evaluation budget,
    // while the sentinel compares it with real monotonic time; this start
    // puts the deadline about 400 ms of real time ahead.
    const budget_ns = worker.testing.module_routes.module_eval_budget_ns;
    var fixture: Fixture = undefined;
    try fixture.init((process.monotonicNowNsOrZero() + 400 * std.time.ns_per_ms) -| budget_ns, true);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // Route 1's top-level timer busy-waits 8 s before it settles the await,
    // so a turn published under the wrong owner fails the elapsed-time check
    // below instead of hanging the lane.
    const ok_entry = "/var/task/arbiter-boot-ok.js";
    const hung_entry = "/var/task/arbiter-boot-hung.js";
    const pack_fd = try rt.createDefinitionFd(&.{
        .{ .specifier = ok_entry, .source = "export default () => \"ok\";" },
        .{
            .specifier = hung_entry,
            .source =
            \\await new Promise((resolve) => setTimeout(() => {
            \\    const end = Date.now() + 8000;
            \\    while (Date.now() < end) {}
            \\    resolve();
            \\}, 0));
            \\export default () => "never";
            ,
        },
    }, &.{ .{ .entry_module = 0 }, .{ .entry_module = 1 } });
    defer std.posix.close(pack_fd);
    try rt.bootDefinition(runtime, pack_fd);
    runtime.sealStartupEvaluations();
    const hung_evaluation_id = request_context.evaluationId(1);
    const evaluation = runtime.requests.active.get(hung_evaluation_id) orelse
        return error.MissingEvaluation;
    try std.testing.expect(evaluation.deadline_armed);
    const evaluation_deadline_ns = evaluation.exec.deadline_monotonic_ns;

    // The timer turn runs in the window of route 1's evaluation, so that
    // evaluation's deadline fires on it after about 400 ms.
    try runtime.collectDueTimers();
    const hang_started_ns = process.monotonicNowNsOrZero();
    try executeNextReady(runtime);
    try std.testing.expect(process.monotonicNowNsOrZero() - hang_started_ns < 4 * std.time.ns_per_s);
    const fired = runtime.observability.sentinel.fired() orelse return error.SentinelDidNotFire;
    try std.testing.expectEqual(hung_evaluation_id, fired.owner_id);

    // The deadline turn expires route 1 alone, and route 0 could still
    // serve, but the fire forbade execution in the VM for good, so the
    // worker asks to retire.
    fixture.now_mono_ns = evaluation_deadline_ns + std.time.ns_per_ms;
    try runtime.collectDueRequestDeadlines();
    try executeNextReady(runtime);
    try std.testing.expect(rt.routeModule(runtime, hung_entry).?.* == .failed);
    try std.testing.expect(rt.routeModule(runtime, ok_entry).?.* == .ready);
    try std.testing.expect(!runtime.requests.active.contains(hung_evaluation_id));
    try std.testing.expect(!runtime.modules.state.fresh_worker_may_serve);
    try runtime.checkRetirement();
    try std.testing.expectEqual(ipc.WorkerRetiringReason.vm_terminated, try retirement_notice.read(fixture.serverFd()));
    try std.testing.expect(runtime.core.running);
}

test "a request already past its deadline when its timer comes up answers 504 without the callback running, and the VM stays in service" {
    var fixture: Fixture = undefined;
    try fixture.init(0, false);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try rt.registerRoute(runtime, "/var/task/arbiter-boundary.js",
        \\export default function handle(request) {
        \\    if (new URL(request.url).pathname.endsWith("/next"))
        \\        return new Response(String(globalThis.__callbackRan === true));
        \\    setTimeout(() => { globalThis.__callbackRan = true; }, 0);
        \\    return new Promise(() => {});
        \\}
    );

    // The deadline lies on the fake clock and the sentinel is not started,
    // so only the cooperative paths can answer it.
    const request_id: u64 = 93;
    const deadline_ns: u64 = 10 * std.time.ns_per_ms;
    try enqueue(runtime, request_id, route_index, 1, deadline_ns);
    try executeNextReady(runtime);
    try runtime.collectDueTimers();
    // The timer's item is queued; the deadline passes before it runs.
    fixture.now_mono_ns = deadline_ns + std.time.ns_per_ms;
    try executeNextReady(runtime);
    try std.testing.expect(!runtime.requests.active.contains(request_id));
    var response = try rt.readIngressResponse(runtime, fixture.serverFd(), request_id);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);

    // No fire, so the next request runs JavaScript, which shows the
    // callback never ran.
    try std.testing.expect(runtime.observability.sentinel.fired() == null);
    var next = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 94,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
        .request = .{ .path = "/next" },
    });
    defer next.deinit();
    try rt.enqueueIngressRoute(runtime, &next, 3, .{ .path = "/next" });
    try executeUntilRequestDone(runtime, 94);
    const body = try rt.readIngressResponseBody(runtime, fixture.serverFd(), 94);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("false", body);
    try runtime.checkRetirement();
    try std.testing.expect(runtime.retirement.reason == null);
}

// The deadline's termination reaches stream code that calls back into
// JavaScript: a source's pull, a sink's abort inside a signal's abort
// algorithms, and the cancels the request's cleanup runs afterwards on the
// terminated VM. Code that went on calling JavaScript with the termination
// pending trips the Debug engine's `assertNoException`, so these pass in
// Release before and after the bridge's fix, and the Debug engine run is
// their evidence.
test "a stream source whose pull hangs with a read pending is stopped by its request's deadline, and the worker answers it 504 and retires" {
    var fixture: Fixture = undefined;
    try fixture.init(0, true);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // The pull's busy-wait ends on its own after 8 s, as in the timer test
    // above, so a missed fire fails the elapsed-time check instead of
    // hanging the lane.
    const route_index = try rt.registerRoute(runtime, "/var/task/arbiter-hung-pull.js",
        \\export default function handle(request) {
        \\    const stream = new ReadableStream({
        \\        pull() {
        \\            const end = Date.now() + 8000;
        \\            while (Date.now() < end) {}
        \\        },
        \\    });
        \\    stream.getReader().read().catch(() => {});
        \\    return new Promise(() => {});
        \\}
    );
    // The first pull runs in the handler's own drain, once the source's
    // start settles.
    const request_id: u64 = 95;
    try enqueue(runtime, request_id, route_index, 1, process.monotonicNowNsOrZero() + 400 * std.time.ns_per_ms);
    const hang_started_ns = process.monotonicNowNsOrZero();
    try executeNextReady(runtime);
    // The pull traps inside the handler's own drain, whose failure path
    // answers the request at once.
    try expectDeadlineFireRetires(&fixture, request_id, route_index, hang_started_ns, .answer_first);
}

test "a pipe's sink whose abort hangs inside an AbortController's abort is stopped by its request's deadline, and the worker answers it 504 and retires" {
    var fixture: Fixture = undefined;
    try fixture.init(0, true);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // The source never enqueues, so no write is in flight when the signal
    // aborts the pipe, and the sink's abort runs inside `abort()` itself.
    const route_index = try rt.registerRoute(runtime, "/var/task/arbiter-hung-sink-abort.js",
        \\export default function handle(request) {
        \\    const controller = new AbortController();
        \\    const readable = new ReadableStream({ pull() {} });
        \\    const writable = new WritableStream({
        \\        abort() {
        \\            const end = Date.now() + 8000;
        \\            while (Date.now() < end) {}
        \\        },
        \\    });
        \\    readable.pipeTo(writable, { signal: controller.signal }).catch(() => {});
        \\    setTimeout(() => controller.abort(), 0);
        \\    return new Promise(() => {});
        \\}
    );
    const request_id: u64 = 97;
    try enqueue(runtime, request_id, route_index, 1, process.monotonicNowNsOrZero() + 400 * std.time.ns_per_ms);
    try executeNextReady(runtime);
    try std.testing.expect(runtime.requests.active.contains(request_id));

    try runtime.collectDueTimers();
    const hang_started_ns = process.monotonicNowNsOrZero();
    try executeNextReady(runtime);
    try expectDeadlineFireRetires(&fixture, request_id, route_index, hang_started_ns, .notice_first);
}

/// Which reaches the server first after a fire: the retiring notice, when
/// the loop's check answers the stopped request (`endAfterFire`), or the
/// 504, when the request's own trapped turn answers it before the check
/// runs.
const FireAnswerOrder = enum { notice_first, answer_first };

/// Checks what follows a hang of `request_id` that began at
/// `hang_started_ns`: its deadline fired well before the hang would end on
/// its own, the request answers 504 and the loop's check announces
/// `vm_terminated`, in `order`, and a later begin for `route_index`,
/// request `request_id + 1`, answers 503 `worker_retiring` without
/// JavaScript while the worker keeps running.
fn expectDeadlineFireRetires(
    fixture: *Fixture,
    request_id: u64,
    route_index: u16,
    hang_started_ns: u64,
    order: FireAnswerOrder,
) !void {
    const runtime = &fixture.runtime;
    try std.testing.expect(process.monotonicNowNsOrZero() - hang_started_ns < 4 * std.time.ns_per_s);
    const fired = runtime.observability.sentinel.fired() orelse return error.SentinelDidNotFire;
    try std.testing.expectEqual(request_id, fired.owner_id);
    try std.testing.expectEqual(sentinel.Cause.deadline, fired.cause);

    try runtime.checkRetirement();
    try std.testing.expect(runtime.vm_terminated);
    if (order == .notice_first)
        try std.testing.expectEqual(ipc.WorkerRetiringReason.vm_terminated, try retirement_notice.read(fixture.serverFd()));
    var response = try rt.readIngressResponse(runtime, fixture.serverFd(), request_id);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.deadline_timeout, response.doneStatus());
    // The read ends at the request's `request_done`, so a notice behind the
    // answer is the next packet.
    if (order == .answer_first)
        try std.testing.expectEqual(ipc.WorkerRetiringReason.vm_terminated, try retirement_notice.read(fixture.serverFd()));

    const late_id = request_id + 1;
    try enqueue(runtime, late_id, route_index, 3, process.monotonicNowNsOrZero() + std.time.ns_per_min);
    try executeUntilRequestDone(runtime, late_id);
    var late = try rt.readIngressResponse(runtime, fixture.serverFd(), late_id);
    defer late.deinit();
    try std.testing.expectEqual(@as(u16, 503), late.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.worker_retiring, late.doneStatus());
    try std.testing.expect(runtime.core.running);
}
