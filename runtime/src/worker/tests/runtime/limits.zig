//! Covers the limits of the owners the worker's VM thread works for
//! (`runtime/owner.zig`, `serve/termination.zig`): a request's CPU budget,
//! its definition's `cpuMs`, stops a handler that spins at the sentinel's
//! CPU deadline with 503 `cpu` and retires the worker; a request that
//! spends its budget across short turns is answered 503 at a boundary and
//! leaves the VM serving; waiting is not CPU; and JavaScript no request owns, a
//! FinalizationRegistry callback the deferred-work pump runs, is stopped by
//! the worker owner's wall limit. Fires of a request's wall deadline are in
//! `arbiter.zig`, and a reaction of a finished request stopped inside
//! another's drain in `multiplexing.zig`. Runs in `worker-test`, on a real
//! VM, with the VM thread's real CPU clock.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");
const process = @import("collo_os").process;
const request_context = @import("collo_worker_request").context;
const retirement_notice = @import("retirement_notice.zig");

const sentinel = worker.testing.sentinel;

/// A runtime on a fake clock whose owners have the limits a test names.
/// Request deadlines a test wants the sentinel to watch are real
/// CLOCK_MONOTONIC instants, since the sentinel reads that clock.
const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    completion: rt.CompletionFixture,
    now_mono_ns: u64,
    runtime: worker.Runtime,

    const Limits = struct {
        request_cpu_budget_ns: u64 = 0,
        unowned_time_limit_ns: u64 = ipc.WorkerInit.default_unowned_time_limit_ns,
        start_sentinel: bool,
    };

    fn init(self: *Fixture, limits: Limits) !void {
        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer {
            std.posix.close(self.control_pair[0]);
            std.posix.close(self.control_pair[1]);
        }
        self.completion = try rt.CompletionFixture.init();
        errdefer self.completion.deinit();
        self.now_mono_ns = 0;
        self.runtime = try worker.Runtime.init(
            std.testing.allocator,
            &self.vm,
            self.control_pair[0],
            &self.completion.view,
            try rt.createCompletionEventfd(),
            worker.RuntimeOptions{
                .clock = .{ .ctx = &self.now_mono_ns, .now_fn = rt.fakeNow },
                .request_cpu_budget_ns = limits.request_cpu_budget_ns,
                .unowned_time_limit_ns = limits.unowned_time_limit_ns,
            },
        );
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
        if (limits.start_sentinel)
            try self.runtime.startSentinel();
    }

    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        std.posix.close(self.control_pair[0]);
        std.posix.close(self.control_pair[1]);
        self.vm.deinit();
    }

    fn enqueue(self: *Fixture, request_id: u64, route_index: u16, stream_id: u32, deadline_ns: u64) !void {
        var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .deadline_monotonic_ns = deadline_ns,
            .request = .{ .path = "/limits" },
        });
        defer dispatch.deinit();
        try rt.enqueueIngressRoute(&self.runtime, &dispatch, stream_id, .{ .path = "/limits" });
    }
};

test "a handler that spins past its CPU budget is stopped for CPU and answers 503 cpu, and the worker asks to retire" {
    var fixture: Fixture = undefined;
    try fixture.init(.{ .request_cpu_budget_ns = 30 * std.time.ns_per_ms, .start_sentinel = true });
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try rt.registerRoute(runtime, "/var/task/limits-spin.js",
        \\export default function handle() {
        \\    for (;;) {}
        \\}
    );
    const request_id: u64 = 31;
    try fixture.enqueue(request_id, route_index, 1, process.monotonicNowNsOrZero() + 10 * std.time.ns_per_s);

    const started_ns = process.monotonicNowNsOrZero();
    try rt.executeNextReady(runtime);
    // 30 ms of CPU; the wall deadline lies 10 s out.
    try std.testing.expect(process.monotonicNowNsOrZero() - started_ns < 5 * std.time.ns_per_s);
    const fired = runtime.observability.sentinel.fired() orelse return error.SentinelDidNotFire;
    try std.testing.expectEqual(request_id, fired.owner_id);
    try std.testing.expectEqual(sentinel.Cause.cpu, fired.cause);

    var response = try rt.readIngressResponse(runtime, fixture.control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 503), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.cpu_exceeded, response.doneStatus());
    try std.testing.expect(response.done.cpu_ns >= 30 * std.time.ns_per_ms);

    try runtime.checkRetirement();
    try std.testing.expectEqual(ipc.WorkerRetiringReason.vm_terminated, try retirement_notice.read(fixture.control_pair[1]));
}

test "a handler that waits on a timer spends no CPU budget waiting and answers 200" {
    var fixture: Fixture = undefined;
    try fixture.init(.{ .request_cpu_budget_ns = 30 * std.time.ns_per_ms, .start_sentinel = false });
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try rt.registerRoute(runtime, "/var/task/limits-wait.js",
        \\export default async function handle() {
        \\    await new Promise((resolve) => setTimeout(resolve, 200));
        \\    return new Response("waited");
        \\}
    );
    const request_id: u64 = 32;
    try fixture.enqueue(request_id, route_index, 1, std.time.ns_per_hour);
    try rt.executeNextReady(runtime);
    try std.testing.expect(runtime.requests.active.contains(request_id));

    fixture.now_mono_ns += 200 * std.time.ns_per_ms;
    try rt.executeUntilRequestDone(runtime, request_id);
    var response = try rt.readIngressResponse(runtime, fixture.control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqualStrings("waited", response.body);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, response.doneStatus());
}

test "a handler that spends its CPU budget across short turns answers 503 at a boundary, and the worker serves on" {
    var fixture: Fixture = undefined;
    try fixture.init(.{ .request_cpu_budget_ns = 30 * std.time.ns_per_ms, .start_sentinel = false });
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // Each timer turn spins 5 ms of real time; 40 of them would take
    // 200 ms, far past the budget, unless a boundary stops the chain.
    const route_index = try rt.registerRoute(runtime, "/var/task/limits-turns.js",
        \\export default function handle(request) {
        \\    if (new URL(request.url).pathname.endsWith("/quick"))
        \\        return new Response("quick");
        \\    return new Promise((resolve) => {
        \\        let turns = 0;
        \\        const step = () => {
        \\            const end = Date.now() + 5;
        \\            while (Date.now() < end) {}
        \\            turns += 1;
        \\            globalThis.__turns = turns;
        \\            if (turns === 40) resolve(new Response("all turns"));
        \\            else setTimeout(step, 0);
        \\        };
        \\        setTimeout(step, 0);
        \\    });
        \\}
    );
    const request_id: u64 = 33;
    try fixture.enqueue(request_id, route_index, 1, std.time.ns_per_hour);
    try rt.executeNextReady(runtime);
    try rt.executeUntilRequestDone(runtime, request_id);
    var response = try rt.readIngressResponse(runtime, fixture.control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 503), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.cpu_exceeded, response.doneStatus());

    // No fire: the boundary answered, so the VM still runs JavaScript.
    try std.testing.expect(runtime.observability.sentinel.fired() == null);
    var quick = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = 34,
        .route_index = route_index,
        .deadline_monotonic_ns = std.time.ns_per_hour,
        .request = .{ .path = "/quick" },
    });
    defer quick.deinit();
    try rt.enqueueIngressRoute(runtime, &quick, 3, .{ .path = "/quick" });
    try rt.executeUntilRequestDone(runtime, 34);
    const body = try rt.readIngressResponseBody(runtime, fixture.control_pair[1], 34);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("quick", body);
    try runtime.checkRetirement();
    try std.testing.expect(runtime.retirement.reason == null);
}

test "a FinalizationRegistry callback that spins is stopped by the worker owner's limit, and the worker asks to retire" {
    var fixture: Fixture = undefined;
    try fixture.init(.{
        .unowned_time_limit_ns = 100 * std.time.ns_per_ms,
        .start_sentinel = true,
    });
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // Many targets, so a collection finds some of them dead whatever a
    // conservative scan of the stack keeps.
    const route_index = try rt.registerRoute(runtime, "/var/task/limits-registry.js",
        \\export default function handle() {
        \\    globalThis.__registry = new FinalizationRegistry(() => { for (;;) {} });
        \\    for (let i = 0; i < 4096; i++) globalThis.__registry.register({ i }, i);
        \\    return new Response("registered");
        \\}
    );
    const request_id: u64 = 36;
    try fixture.enqueue(request_id, route_index, 1, process.monotonicNowNsOrZero() + 10 * std.time.ns_per_s);
    try rt.executeNextReady(runtime);
    try rt.executeUntilRequestDone(runtime, request_id);
    const body = try rt.readIngressResponseBody(runtime, fixture.control_pair[1], request_id);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("registered", body);

    // The collection schedules the cleanup on the engine's deferred work,
    // which only the pump runs, under the worker owner. Before the worker
    // owner had a limit, nothing stopped it.
    try fixture.vm.collectFullGCAndTrim();
    const started_ns = process.monotonicNowNsOrZero();
    _ = worker.testing.scheduler.loop.pumpDeferredWork(runtime, false);
    try std.testing.expect(process.monotonicNowNsOrZero() - started_ns < 5 * std.time.ns_per_s);
    const fired = runtime.observability.sentinel.fired() orelse return error.SentinelDidNotFire;
    try std.testing.expectEqual(request_context.worker_owner_id, fired.owner_id);
    try std.testing.expectEqual(sentinel.Cause.deadline, fired.cause);

    try runtime.checkRetirement();
    try std.testing.expectEqual(ipc.WorkerRetiringReason.vm_terminated, try retirement_notice.read(fixture.control_pair[1]));
}
