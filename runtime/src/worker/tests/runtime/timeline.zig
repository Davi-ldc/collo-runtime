//! Covers what a request's timeline (`request/context.zig`) puts in its
//! `request_done`. On the runtime's injected clock, two ways it once
//! misplaced time between waiting and I/O: a timer the request clears after
//! its work item was queued gives its ready count back, so the time until
//! the stale item pops is I/O and not waiting (`ReadyQueue.withdraw`); and a
//! begin that waits for room in a full ready queue keeps the instant it
//! became ready, so that wait counts as waiting and not I/O
//! (`ingress/runtime.zig:queueStamped`). On the real clock, the packet
//! carries the measures the timeline produced: the time the request ran
//! (`RequestContext.execNs`), as I/O exactly the wait from the end of the
//! turn that armed a timer to the timer's due time, and the three inside the
//! request's span. The transitions themselves are covered in
//! `worker/tests/request/context.zig`. Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const process = @import("collo_os").process;

/// The fake clock starts away from 0, which a readiness stamp reads as now.
const start_mono_ns: u64 = std.time.ns_per_s;

const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    completion: rt.CompletionFixture,
    now_mono_ns: u64,
    runtime: worker.Runtime,

    fn init(self: *Fixture, ready_queue_capacity: usize) !void {
        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
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
            worker.RuntimeOptions{
                .clock = .{ .ctx = &self.now_mono_ns, .now_fn = rt.fakeNow },
                .limits = .{ .ready_queue_capacity = ready_queue_capacity },
            },
        );
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
    }

    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        std.posix.close(self.control_pair[0]);
        std.posix.close(self.control_pair[1]);
        self.vm.deinit();
    }

    fn enqueue(self: *Fixture, request_id: u64, route_index: u16, slot: u32, path: []const u8) !void {
        var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .request_slot = slot,
            .deadline_monotonic_ns = start_mono_ns + std.time.ns_per_hour,
            .request = .{ .path = path },
        });
        defer dispatch.deinit();
        try rt.enqueueIngressRoute(&self.runtime, &dispatch, 2 * slot + 1, .{ .path = path });
    }

    /// The `request_done` of `request_id`, read from the server's end.
    fn requestDone(self: *Fixture, request_id: u64) !@import("collo_ipc").RequestDone {
        const read = try rt.readRequestDoneOf(self.control_pair[1], request_id);
        return read.done;
    }
};

test "a timer the request clears after its item was queued leaves the time until that item pops as I/O" {
    var fixture: Fixture = undefined;
    try fixture.init(256);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // The first zero-delay timer clears the second, whose item is already
    // queued behind it; a third answers 100 ms later.
    const route_index = try rt.registerRoute(runtime, "/var/task/timeline-cleared.js",
        \\export default function handle() {
        \\    return new Promise((resolve) => {
        \\        setTimeout(() => clearTimeout(globalThis.__cleared), 0);
        \\        globalThis.__cleared = setTimeout(() => {}, 0);
        \\        setTimeout(() => resolve(new Response("done")), 100);
        \\    });
        \\}
    );
    const request_id: u64 = 801;
    try fixture.enqueue(request_id, route_index, 0, "/cleared");
    try rt.executeNextReady(runtime);
    try runtime.collectDueTimers();
    // The clearing timer runs; the cleared one's item stays queued.
    try rt.executeNextReady(runtime);
    try std.testing.expect(!runtime.scheduler.ready_queue.isEmpty());

    // 50 ms pass before the stale item pops, with nothing of the request
    // ready: I/O. A count left behind made them waiting.
    fixture.now_mono_ns += 50 * std.time.ns_per_ms;
    try rt.executeNextReady(runtime);
    fixture.now_mono_ns += 50 * std.time.ns_per_ms;
    try rt.executeUntilRequestDone(runtime, request_id);

    const done = try fixture.requestDone(request_id);
    try std.testing.expect(done.waiting_ns < std.time.ns_per_ms);
    try std.testing.expect(done.io_ns >= 100 * std.time.ns_per_ms);
}

test "a begin that waits for room in a full ready queue counts that wait as waiting, not I/O" {
    var fixture: Fixture = undefined;
    // One slot in the queue and one in its backlog.
    try fixture.init(1);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try rt.registerRoute(runtime, "/var/task/timeline-full-queue.js",
        \\export default function handle(request) {
        \\    if (new URL(request.url).pathname.endsWith("/park")) {
        \\        setTimeout(() => {}, 0);
        \\        return new Promise(() => {});
        \\    }
        \\    return new Response("quick");
        \\}
    );
    // A parks and its timer's item takes the queue's slot; C's begin takes
    // the backlog's; B's begin finds both full.
    try fixture.enqueue(901, route_index, 0, "/park");
    try rt.executeNextReady(runtime);
    try runtime.collectDueTimers();
    try fixture.enqueue(902, route_index, 1, "/quick");
    try fixture.enqueue(903, route_index, 2, "/quick");
    try std.testing.expect(runtime.scheduler.ingress_rescan_needed);

    // 30 ms pass before the queue has room for B.
    fixture.now_mono_ns += 30 * std.time.ns_per_ms;
    try rt.executeNextReady(runtime);
    runtime.drainReadyBacklog();
    try rt.executeUntilRequestDone(runtime, 902);
    runtime.collectReadyIngressRequests();
    try rt.executeUntilRequestDone(runtime, 903);

    const done = try fixture.requestDone(903);
    try std.testing.expect(done.waiting_ns >= 30 * std.time.ns_per_ms);
    try std.testing.expect(done.io_ns < 30 * std.time.ns_per_ms);
}

// The server takes a request's wall time from its own clock, so the worker's
// `request_done` must carry the time the request ran: once the wall time
// stopped being the worker's, nothing could derive it from the rest.
test "a request's request_done carries the measures its timeline produced: the time it ran, its waiting and I/O, within its span in the worker" {
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var completion = try rt.CompletionFixture.init();
    defer completion.deinit();
    // The real clock: no fake clock moves while a turn runs.
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion.view, try rt.createCompletionEventfd(), worker.RuntimeOptions{});
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // `Date.now()` ticks in whole milliseconds, so waiting for 21 ticks
    // spins for more than 20 ms of real time.
    const route_index = try rt.registerRoute(&runtime, "/var/task/timeline-exec.js",
        \\export default async function handle() {
        \\    const end = Date.now() + 21;
        \\    while (Date.now() < end) {}
        \\    await new Promise((resolve) => setTimeout(resolve, 10));
        \\    return new Response("done");
        \\}
    );
    const request_id: u64 = 1001;
    const before_ns = process.monotonicNowNsOrZero();
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = before_ns + std.time.ns_per_min,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});

    // The handler's first turn spins and arms the timer. What the timeline
    // holds when the turn ends fixes how much of the timer's wait is I/O.
    try rt.executeNextReady(&runtime);
    const request_ctx = runtime.requests.active.get(request_id) orelse return error.ExpectedActiveRequest;
    const started_ns = request_ctx.started_mono_ns;
    const io_before_timer_ns = request_ctx.io_time_ns;
    const turn_end_ns = request_ctx.state_since_ns;
    const timer_due_ns = runtime.scheduler.timers.peekDueNs() orelse return error.ExpectedArmedTimer;
    try rt.executeUntilRequestDone(&runtime, request_id);
    const span_ns_max = process.monotonicNowNsOrZero() - before_ns;

    const done = (try rt.readRequestDoneOf(control_pair[1], request_id)).done;
    try std.testing.expect(done.exec_ns >= 20 * std.time.ns_per_ms);
    // The timer was armed inside the turn, and the rest of the turn was
    // execution, so the timer's wait is I/O only from the turn's end to its
    // due time, however late the loop noticed it. Nothing after that is
    // I/O: the callback queues the request's completion inside its own turn.
    try std.testing.expectEqual(io_before_timer_ns + (timer_due_ns -| turn_end_ns), done.io_ns);
    // The three measures partition the request's span from its begin's
    // decode to its finish, which lies past the timer's due time.
    try std.testing.expect(done.exec_ns + done.waiting_ns + done.io_ns >= timer_due_ns - started_ns);
    try std.testing.expect(done.exec_ns + done.waiting_ns + done.io_ns <= span_ns_max);
    // The CPU of the turns it ran: the spin, at least, and no more than the
    // time it ran.
    try std.testing.expect(done.cpu_ns > 0);
    try std.testing.expect(done.cpu_ns <= span_ns_max);
}
