//! Covers request identity with several live requests in one worker: a
//! continuation that another request's turn resumes still runs under the
//! request that registered it, and its CPU is that request's; a reaction
//! whose registrant finished runs under the worker owner, whose limit stops
//! it, and the request whose drain ran it answers 503 `worker_stopped`; and
//! every live slot of the page can hold a request at once, each with its own
//! console line id. Concurrent requests may share the VM only because this
//! holds (`ensureRequestTask` in `serve/dispatch.zig`); the WebKit patch
//! `0004-microtask-owner-context` carries the owner from a promise
//! reaction's registration to its execution, and `runtime/owner.zig`
//! charges the window the bridge reports. Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const worker_shared_page = @import("collo_worker_state").page;
const rt = @import("collo_test_harness");
const process = @import("collo_os").process;
const request_context = @import("collo_worker_request").context;

// The witness is the request id the log ring stores with each line, rather
// than CPU time: attribution is a discrete fact, and a microsecond delta
// would make the test a coin flip.
//
// The continuation crosses three hops. Carrying the owner on the pending
// reaction alone gets only the first right: the first `await` resumes under
// the waiter, but the continuation then enqueues through paths with no
// pending reaction (an already-settled promise takes the settled arm, and
// `queueMicrotask` has none at all). Those microtasks run after the restore
// has put the settling turn's owner back, so unless the enqueue records the
// owner as well, the identity is lost on the second hop, and a test with one
// hop would pass despite that bug.
//
// Request A awaits a promise held at module scope, the `const ready = init()`
// pattern real apps use. Request B resolves it, so A's continuation is
// enqueued during B's turn and runs there. The identity must not follow: the
// line A logs carries A's id.
test "a continuation resumed by another request keeps its own identity" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const page_fd = try worker_shared_page.createMemfd("multiplexing-identity");
    defer std.posix.close(page_fd);
    var view = try worker_shared_page.mapWorkerWriter(page_fd);
    defer view.deinit();
    var reader = try worker_shared_page.mapHostReader(page_fd);
    defer reader.deinit();

    var now_mono_ns: u64 = 9_000;
    var runtime = try worker.Runtime.init(
        std.testing.allocator,
        &vm,
        control_pair[0],
        &view,
        try rt.createCompletionEventfd(),
        .{ .ctx = &now_mono_ns, .now_fn = rt.fakeNow },
    );
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/var/task/multiplexing-identity.js";
    const route_index = try rt.registerRoute(&runtime, specifier,
        \\let release;
        \\const shared = new Promise((resolve) => { release = resolve; });
        \\
        \\export default async function handle(request) {
        \\    if (new URL(request.url).pathname.endsWith("/wait")) {
        \\        await shared;
        \\        await Promise.resolve(1);
        \\        await new Promise((done) => queueMicrotask(done));
        \\        console.log("continuation-of-waiter");
        \\        return new Response("waited");
        \\    }
        \\    release();
        \\    return new Response("released");
        \\}
    );

    const waiter_id: u64 = 101;
    const releaser_id: u64 = 202;

    // A: parks on the module-scope promise and stays alive.
    var waiter = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = waiter_id,
        .route_index = route_index,
        .request = .{ .path = "/wait" },
    });
    defer waiter.deinit();
    try rt.enqueueIngressRoute(&runtime, &waiter, 1, .{ .path = "/wait" });
    try rt.executeNextReady(&runtime);
    try std.testing.expect(runtime.requests.active.contains(waiter_id));

    // B: resolves it while A is still alive.
    var releaser = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = releaser_id,
        .route_index = route_index,
        .request_slot = 1,
        .request = .{ .path = "/release" },
    });
    defer releaser.deinit();
    // A client opens only odd-numbered streams (RFC 9113 §5.1.1), and
    // `validateStreamBeginDescriptor` refuses any other.
    try rt.enqueueIngressRoute(&runtime, &releaser, 3, .{ .path = "/release" });
    try rt.executeNextReady(&runtime);

    try rt.executeUntilRequestDone(&runtime, releaser_id);
    try rt.executeUntilRequestDone(&runtime, waiter_id);

    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [16]worker_shared_page.DrainedLogLine = undefined;
    var found_owner: ?u64 = null;
    while (true) {
        const count = try reader.drainLogLinesChecked(&scratch, &out);
        if (count == 0) break;
        for (out[0..count]) |line| {
            if (std.mem.containsAtLeast(u8, line.payload, 1, "continuation-of-waiter"))
                found_owner = line.header.request_id;
        }
    }

    const owner = found_owner orelse return error.ContinuationNeverLogged;
    try std.testing.expectEqual(waiter_id, owner);
}

// The CPU of a reaction belongs to the request that registered it, whichever
// request's drain runs it (`worker/runtime/owner.zig`, through the
// owner-transition hook). Request A parks on a module-scope promise, and its
// continuation busy-waits; request B resolves the promise, so the
// continuation runs inside B's drain. The witness here is CPU on purpose,
// with a spin long enough that the comparison cannot flip: A's
// `request_done` must hold the spin, and B's must not. The thread CPU clock
// is the real one.
test "a reaction that another request's drain runs is charged to the request that registered it" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var now_mono_ns: u64 = 9_000;
    var runtime = try worker.Runtime.init(
        std.testing.allocator,
        &vm,
        control_pair[0],
        &completion_fixture.view,
        try rt.createCompletionEventfd(),
        .{ .ctx = &now_mono_ns, .now_fn = rt.fakeNow },
    );
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/var/task/multiplexing-cpu.js";
    const route_index = try rt.registerRoute(&runtime, specifier,
        \\let release;
        \\const shared = new Promise((resolve) => { release = resolve; });
        \\
        \\export default async function handle(request) {
        \\    if (new URL(request.url).pathname.endsWith("/wait")) {
        \\        await shared;
        \\        const end = Date.now() + 50;
        \\        while (Date.now() < end) {}
        \\        return new Response("waited");
        \\    }
        \\    release();
        \\    return new Response("released");
        \\}
    );

    const waiter_id: u64 = 301;
    const releaser_id: u64 = 302;

    var waiter = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = waiter_id,
        .route_index = route_index,
        .request = .{ .path = "/wait" },
    });
    defer waiter.deinit();
    try rt.enqueueIngressRoute(&runtime, &waiter, 1, .{ .path = "/wait" });
    try rt.executeNextReady(&runtime);
    try std.testing.expect(runtime.requests.active.contains(waiter_id));

    var releaser = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = releaser_id,
        .route_index = route_index,
        .request_slot = 1,
        .request = .{ .path = "/release" },
    });
    defer releaser.deinit();
    try rt.enqueueIngressRoute(&runtime, &releaser, 3, .{ .path = "/release" });
    try rt.executeNextReady(&runtime);

    try rt.executeUntilRequestDone(&runtime, releaser_id);
    try rt.executeUntilRequestDone(&runtime, waiter_id);

    var dones: [2]rt.ReadRequestDone = undefined;
    try rt.readRequestDones(control_pair[1], &.{ waiter_id, releaser_id }, &dones);
    const waiter_cpu = dones[0].done.cpu_ns;
    const releaser_cpu = dones[1].done.cpu_ns;

    // The 50 ms spin is A's, however little of it a loaded machine schedules;
    // B ran a few microseconds of its own and drained the spin, which its
    // `request_done` must not hold.
    try std.testing.expect(waiter_cpu >= 5 * std.time.ns_per_ms);
    try std.testing.expect(releaser_cpu < waiter_cpu);
}

// Request A leaves a spinning reaction on a promise whose resolver it keeps
// on the module's scope, and finishes, which releases its exec context.
// Request B resolves the promise, so the reaction runs inside B's drain with
// no registrant left: the worker owner owns it, and only the worker owner's
// limit can stop it, since B's deadline is not the published one. The fire
// names the worker owner, B answers 503 `worker_stopped`, and B's own log
// gets no exception, since its code did nothing wrong. Before the worker
// owner had a limit, B's turn spun until the server's backstop.
test "a stranded reaction that spins inside another request's drain is stopped by the worker owner's limit, and that request answers 503 worker_stopped" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const page_fd = try worker_shared_page.createMemfd("multiplexing-stranded");
    defer std.posix.close(page_fd);
    var view = try worker_shared_page.mapWorkerWriter(page_fd);
    defer view.deinit();
    var reader = try worker_shared_page.mapHostReader(page_fd);
    defer reader.deinit();

    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(
        std.testing.allocator,
        &vm,
        control_pair[0],
        &view,
        try rt.createCompletionEventfd(),
        worker.RuntimeOptions{
            .clock = .{ .ctx = &now_mono_ns, .now_fn = rt.fakeNow },
            .unowned_time_limit_ns = 100 * std.time.ns_per_ms,
        },
    );
    defer runtime.deinit();
    try runtime.attachHostRuntime();
    try runtime.startSentinel();

    const specifier = "/var/task/multiplexing-stranded.js";
    const route_index = try rt.registerRoute(&runtime, specifier,
        \\let release;
        \\export default function handle(request) {
        \\    if (new URL(request.url).pathname.endsWith("/park")) {
        \\        new Promise((resolve) => { release = resolve; }).then(() => { for (;;) {} });
        \\        return new Response("parked");
        \\    }
        \\    release();
        \\    return new Response("released");
        \\}
    );

    // Real deadlines far out, since the sentinel reads real time.
    const deadline_ns = process.monotonicNowNsOrZero() + 30 * std.time.ns_per_s;
    const parker_id: u64 = 401;
    const releaser_id: u64 = 402;
    var parker = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = parker_id,
        .route_index = route_index,
        .deadline_monotonic_ns = deadline_ns,
        .request = .{ .path = "/park" },
    });
    defer parker.deinit();
    try rt.enqueueIngressRoute(&runtime, &parker, 1, .{ .path = "/park" });
    try rt.executeUntilRequestDone(&runtime, parker_id);
    var parked = try rt.readIngressResponse(&runtime, control_pair[1], parker_id);
    defer parked.deinit();
    try std.testing.expectEqual(@as(u16, 200), parked.status);

    var releaser = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = releaser_id,
        .route_index = route_index,
        .request_slot = 1,
        .deadline_monotonic_ns = deadline_ns,
        .request = .{ .path = "/release" },
    });
    defer releaser.deinit();
    try rt.enqueueIngressRoute(&runtime, &releaser, 3, .{ .path = "/release" });
    const started_ns = process.monotonicNowNsOrZero();
    try rt.executeUntilRequestDone(&runtime, releaser_id);
    try std.testing.expect(process.monotonicNowNsOrZero() - started_ns < 5 * std.time.ns_per_s);

    const fired = runtime.observability.sentinel.fired() orelse return error.SentinelDidNotFire;
    try std.testing.expectEqual(request_context.worker_owner_id, fired.owner_id);
    var response = try rt.readIngressResponse(&runtime, control_pair[1], releaser_id);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 503), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.worker_stopped, response.doneStatus());

    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [16]worker_shared_page.DrainedLogLine = undefined;
    while (true) {
        const count = try reader.drainLogLinesChecked(&scratch, &out);
        if (count == 0) break;
        for (out[0..count]) |line|
            try std.testing.expect(line.header.request_id != releaser_id);
    }
}

// Every live slot of the page holds a request at once: sixteen requests,
// each parked on a timer, all answer with their own responses and their own
// console lines. A worker held two before the concurrency maximum rose.
test "every live slot serves a request at once, each with its own console line id" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const page_fd = try worker_shared_page.createMemfd("multiplexing-all-slots");
    defer std.posix.close(page_fd);
    var view = try worker_shared_page.mapWorkerWriter(page_fd);
    defer view.deinit();
    var reader = try worker_shared_page.mapHostReader(page_fd);
    defer reader.deinit();

    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(
        std.testing.allocator,
        &vm,
        control_pair[0],
        &view,
        try rt.createCompletionEventfd(),
        .{ .ctx = &now_mono_ns, .now_fn = rt.fakeNow },
    );
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_index = try rt.registerRoute(&runtime, "/var/task/multiplexing-all-slots.js",
        \\export default async function handle(request) {
        \\    const id = new URL(request.url).pathname.slice(1);
        \\    await new Promise((resolve) => setTimeout(resolve, 1));
        \\    console.log("line:" + id);
        \\    return new Response(id);
        \\}
    );

    const slot_count = worker_shared_page.LIVE_SLOT_COUNT;
    comptime std.debug.assert(slot_count >= 16);
    var path_buffers: [slot_count][16]u8 = undefined;
    for (0..slot_count) |index| {
        const request_id: u64 = 501 + index;
        const path = try std.fmt.bufPrint(&path_buffers[index], "/{d}", .{request_id});
        var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .request_slot = @intCast(index),
            .deadline_monotonic_ns = std.time.ns_per_hour,
            .request = .{ .path = path },
        });
        defer dispatch.deinit();
        try rt.enqueueIngressRoute(&runtime, &dispatch, @intCast(2 * index + 1), .{ .path = path });
        try rt.executeNextReady(&runtime);
        try std.testing.expect(runtime.requests.active.contains(request_id));
    }

    now_mono_ns += std.time.ns_per_ms;
    for (0..slot_count) |index|
        try rt.executeUntilRequestDone(&runtime, 501 + index);

    var lines_seen: usize = 0;
    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [16]worker_shared_page.DrainedLogLine = undefined;
    while (true) {
        const count = try reader.drainLogLinesChecked(&scratch, &out);
        if (count == 0) break;
        for (out[0..count]) |line| {
            const prefix = "line:";
            const at = std.mem.indexOf(u8, line.payload, prefix) orelse continue;
            const id = try std.fmt.parseInt(u64, std.mem.trim(u8, line.payload[at + prefix.len ..], " \n"), 10);
            try std.testing.expectEqual(id, line.header.request_id);
            lines_seen += 1;
        }
    }
    try std.testing.expectEqual(slot_count, lines_seen);

    var request_ids: [slot_count]u64 = undefined;
    for (&request_ids, 0..) |*request_id, index|
        request_id.* = 501 + index;
    var dones: [slot_count]rt.ReadRequestDone = undefined;
    try rt.readRequestDones(control_pair[1], &request_ids, &dones);
    for (dones) |read|
        try std.testing.expectEqual(ipc.RequestDoneStatus.ok, read.done.status);
}
