//! Covers what a request's timeline (`request/context.zig`) puts on its
//! usage record. On the runtime's injected clock, two ways it once
//! misplaced time between waiting and I/O: a timer the request clears after
//! its work item was queued gives its ready count back, so the time until
//! the stale item pops is I/O and not waiting (`ReadyQueue.withdraw`); and a
//! begin that waits for room in a full ready queue keeps the instant it
//! became ready, so that wait counts as waiting and not I/O
//! (`ingress/runtime.zig:queueStamped`). On the real clock, the record
//! carries the time the request ran (`RequestContext.execNs`). The
//! transitions themselves are covered in `worker/tests/request/context.zig`.
//! Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const process = @import("collo_os").process;
const worker_shared_page = @import("collo_worker_state").page;

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

    fn usageRecord(self: *Fixture, request_id: u64) !worker_shared_page.CompletedRecord {
        var records: [8]worker_shared_page.CompletedRecord = undefined;
        var cursor: worker_shared_page.RecordCursor = .{};
        const count = cursor.drain(self.completion.view.header, self.completion.view.completed_records, &records) orelse
            return error.UsageRingCorrupt;
        for (records[0..count]) |record| {
            if (record.request_id == request_id)
                return record;
        }
        return error.UsageRecordMissing;
    }
};

test "a timer the request clears after its item was queued leaves the time until that item pops as I/O" {
    var fixture: Fixture = undefined;
    try fixture.init(256);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // The first zero-delay timer clears the second, whose item is already
    // queued behind it; a third answers 100 ms later.
    const route_index = try rt.registerRoute(runtime, "/__collo_route/demo/timeline-cleared.js",
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

    const record = try fixture.usageRecord(request_id);
    try std.testing.expect(record.waiting_ns < std.time.ns_per_ms);
    try std.testing.expect(record.io_ns >= 100 * std.time.ns_per_ms);
}

test "a begin that waits for room in a full ready queue counts that wait as waiting, not I/O" {
    var fixture: Fixture = undefined;
    // One slot in the queue and one in its backlog.
    try fixture.init(1);
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try rt.registerRoute(runtime, "/__collo_route/demo/timeline-full-queue.js",
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

    const record = try fixture.usageRecord(903);
    try std.testing.expect(record.waiting_ns >= 30 * std.time.ns_per_ms);
    try std.testing.expect(record.io_ns < 30 * std.time.ns_per_ms);
}

// The server takes a request's wall time from its own clock, so the worker's
// record must carry the time the request ran: once the wall time stopped
// being the worker's, nothing could derive it from the rest.
test "a request's usage record carries the time it ran, which with its waiting and I/O fits in its span in the worker" {
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
    const route_index = try rt.registerRoute(&runtime, "/__collo_route/demo/timeline-exec.js",
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
    try rt.executeUntilRequestDone(&runtime, request_id);
    const span_ns_max = process.monotonicNowNsOrZero() - before_ns;

    var records: [8]worker_shared_page.CompletedRecord = undefined;
    var cursor: worker_shared_page.RecordCursor = .{};
    const count = cursor.drain(completion.view.header, completion.view.completed_records, &records) orelse
        return error.UsageRingCorrupt;
    try std.testing.expectEqual(@as(usize, 1), count);
    const record = records[0];
    try std.testing.expect(record.exec_ns >= 20 * std.time.ns_per_ms);
    try std.testing.expect(record.io_ns >= 10 * std.time.ns_per_ms);
    try std.testing.expect(record.exec_ns + record.waiting_ns + record.io_ns <= span_ns_max);
}
