//! The VM thread's idle work (`scheduler/idle.zig`) on a real VM with a
//! fake clock: once a request has finished and the worker holds none, the
//! idle collection falls due `idle_collection_delay_ns` after the last owner
//! window, runs once per stretch between requests and gives the request's
//! garbage back; it waits while a dispatched request is held and lets a
//! ready descriptor go first; and a request whose begin waits in the control
//! socket while the collection runs is served after it, its route's module
//! state intact. The test calls the idle step the loop calls after a
//! blocked wait, with the events that wait would report. The same
//! collection inside a sandboxed worker, with its memory measured by the
//! worker's cgroup leaf, is covered by the zygote-integration lane
//! (`runtime/tests/integration/zygote.zig`). Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker_limits = @import("collo_limits").worker;
const worker = @import("collo_worker");
const worker_testing = @import("collo_worker_test_support");
const rt = @import("collo_test_harness");

const idle = worker_testing.scheduler.idle;

/// A handler that leaves its garbage behind: objects, strings and the
/// arrays holding them, and an ArrayBuffer per round, none of which
/// outlives the request.
const garbage_source =
    \\export default function handle() {
    \\    let total = 0;
    \\    for (let round = 0; round < 48; round++) {
    \\        const items = [];
    \\        for (let i = 0; i < 4096; i++) items.push({ round, index: i, label: `item-${round}-${i}` });
    \\        total += items.length;
    \\        total += new Uint8Array(128 * 1024).fill(round)[round];
    \\    }
    \\    return new Response(String(total));
    \\}
;
/// 48 rounds of 4096 items, plus the round number each round reads back.
const garbage_body = "197736";

/// The least the garbage handler grows the heap's capacity by, well below
/// what it allocates, so the bound holds however many collections the
/// engine ran on its own during the request.
const request_growth_min_bytes: u64 = 4 * 1024 * 1024;

/// A request deadline past every fake instant these tests reach.
const request_deadline_ns: u64 = 3600 * std.time.ns_per_s;

/// A runtime on a fake clock, with a socket pair standing in for the
/// server.
const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    completion: rt.CompletionFixture,
    now_mono_ns: u64,
    runtime: worker.Runtime,

    fn init(self: *Fixture) !void {
        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer {
            std.posix.close(self.control_pair[0]);
            std.posix.close(self.control_pair[1]);
        }
        self.completion = try rt.CompletionFixture.init();
        errdefer self.completion.deinit();
        self.now_mono_ns = std.time.ns_per_s;
        self.runtime = try worker.Runtime.init(
            std.testing.allocator,
            &self.vm,
            self.control_pair[0],
            &self.completion.view,
            try rt.createCompletionEventfd(),
            worker.RuntimeOptions{ .clock = .{ .ctx = &self.now_mono_ns, .now_fn = rt.fakeNow } },
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

    fn dispatch(request_id: u64, route_index: u16) !ipc.DispatchWork {
        return rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .deadline_monotonic_ns = request_deadline_ns,
            .request = .{ .path = "/idle" },
        });
    }

    /// The client stream `request_id` arrives on: a client opens only
    /// odd-numbered streams, one per request.
    fn streamId(request_id: u64) u32 {
        return @intCast(2 * request_id - 1);
    }

    /// Queues `request_id`'s begin on the runtime as the control channel
    /// would deliver it, without running it.
    fn begin(self: *Fixture, request_id: u64, route_index: u16) !void {
        var work = try dispatch(request_id, route_index);
        defer work.deinit();
        try rt.enqueueIngressRoute(&self.runtime, &work, streamId(request_id), .{ .path = "/idle" });
    }

    /// Runs `request_id`, begun already, to its end and checks its body.
    fn finish(self: *Fixture, request_id: u64, expected_body: []const u8) !void {
        try rt.executeUntilRequestDoneOnFakeClock(&self.runtime, &self.now_mono_ns, request_id, .{
            .budget_ns = 60 * std.time.ns_per_s,
        });
        var response = try rt.readIngressResponse(&self.runtime, self.control_pair[1], request_id);
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqualStrings(expected_body, response.body);
    }

    fn serve(self: *Fixture, request_id: u64, route_index: u16, expected_body: []const u8) !void {
        try self.begin(request_id, route_index);
        try self.finish(request_id, expected_body);
    }

    fn capacityBytes(self: *Fixture) !u64 {
        return (try self.vm.heapStats()).capacity_bytes;
    }
};

test "a worker that finished a request and went idle collects once, after the idle delay, and gives the request's garbage back" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try rt.registerRoute(runtime, "/var/task/idle-garbage.js", garbage_source);
    try std.testing.expect(!runtime.requests.idle_collection_owed);
    const quiet_bytes = try fixture.capacityBytes();
    try fixture.serve(1, route_index, garbage_body);
    const used_bytes = try fixture.capacityBytes();
    try std.testing.expect(used_bytes >= quiet_bytes + request_growth_min_bytes);
    try std.testing.expect(runtime.requests.idle_collection_owed);

    // The cache release has the same delay, so the wait wakes once for both.
    const due_ns = runtime.owners.idle_since_mono_ns + worker_limits.idle_collection_delay_ns;
    try std.testing.expectEqual(due_ns, idle.deadlineNs(runtime));

    fixture.now_mono_ns = due_ns - 1;
    idle.runDue(runtime, &.{.timer_deadline});
    try std.testing.expect(runtime.requests.idle_collection_owed);
    try std.testing.expectEqual(used_bytes, try fixture.capacityBytes());

    fixture.now_mono_ns = due_ns;
    idle.runDue(runtime, &.{.timer_deadline});
    try std.testing.expect(!runtime.requests.idle_collection_owed);
    const collected_bytes = try fixture.capacityBytes();
    // More than half of what the request grew the heap by is gone.
    try std.testing.expect(collected_bytes -| quiet_bytes < (used_bytes - quiet_bytes) / 2);

    // Nothing is left to wake for until another request finishes.
    try std.testing.expectEqual(@as(u64, 0), idle.deadlineNs(runtime));
    fixture.now_mono_ns += 10 * worker_limits.idle_collection_delay_ns;
    idle.runDue(runtime, &.{.timer_deadline});
    try std.testing.expect(!runtime.requests.idle_collection_owed);

    try fixture.serve(2, route_index, garbage_body);
    try std.testing.expect(runtime.requests.idle_collection_owed);
}

test "the idle collection waits while a dispatched request is held, and a ready descriptor goes before it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try rt.registerRoute(runtime, "/var/task/idle-held.js", garbage_source);
    try fixture.serve(1, route_index, garbage_body);
    try std.testing.expect(runtime.requests.idle_collection_owed);

    // A begun request is held from its begin to its finish, run or not.
    try fixture.begin(2, route_index);
    fixture.now_mono_ns = runtime.owners.idle_since_mono_ns + 10 * worker_limits.idle_collection_delay_ns;
    idle.runDue(runtime, &.{.timer_deadline});
    try std.testing.expect(runtime.requests.idle_collection_owed);

    try fixture.finish(2, garbage_body);
    const due_ns = runtime.owners.idle_since_mono_ns + worker_limits.idle_collection_delay_ns;
    try std.testing.expectEqual(due_ns, idle.deadlineNs(runtime));
    fixture.now_mono_ns = due_ns;
    // The control socket may hold the next request's begin.
    idle.runDue(runtime, &.{ .timer_deadline, .control_ready });
    try std.testing.expect(runtime.requests.idle_collection_owed);
    // The next wait finds the deadline passed and nothing else ready.
    idle.runDue(runtime, &.{.timer_deadline});
    try std.testing.expect(!runtime.requests.idle_collection_owed);
}

test "a request whose begin waits in the control socket during the idle collection is served after it, with its module's state intact" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    // Module state a request reads back: a cache it fills, an object the
    // handler reads, a WeakRef to it and a registry that would count its
    // finalization. A top-level binding no function reads may live only in
    // the evaluation's frame, so the handler reads `held` to keep it
    // reachable from module state.
    const route_index = try rt.registerRoute(runtime, "/var/task/idle-state.js",
        \\const cache = new Map();
        \\let finalized = 0;
        \\const registry = new FinalizationRegistry(() => { finalized += 1; });
        \\const held = { label: "held" };
        \\registry.register(held, "held");
        \\const weak = new WeakRef(held);
        \\export default function handle() {
        \\    const size = cache.size;
        \\    cache.set(size, `entry-${size}`);
        \\    const garbage = [];
        \\    for (let i = 0; i < 65536; i++) garbage.push({ index: i, label: `garbage-${i}` });
        \\    return new Response(`${size}:${cache.get(0)}:${held.label}:${weak.deref()?.label}:${finalized}:${garbage.length}`);
        \\}
    );
    try fixture.serve(1, route_index, "0:entry-0:held:held:0:65536");
    fixture.now_mono_ns = runtime.owners.idle_since_mono_ns + worker_limits.idle_collection_delay_ns;

    // The server sends the next begin after the wait returned for the
    // deadline alone, so the begin is unread while the collection runs.
    var work = try Fixture.dispatch(2, route_index);
    defer work.deinit();
    try rt.sendIngressRoute(fixture.control_pair[1], &work, Fixture.streamId(2), .{ .path = "/idle" });
    idle.runDue(runtime, &.{.timer_deadline});
    try std.testing.expect(!runtime.requests.idle_collection_owed);
    try std.testing.expect(!runtime.requests.active.contains(2));

    // The harness's reader pumps the runtime, which reads the begin then.
    var response = try rt.readIngressResponse(runtime, fixture.control_pair[1], 2);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("1:entry-0:held:held:0:65536", response.body);
}
