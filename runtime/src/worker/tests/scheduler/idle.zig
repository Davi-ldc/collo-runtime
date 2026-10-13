//! The VM thread's idle work (`scheduler/idle.zig`) on a real VM with a
//! fake clock: once a request has finished and the worker holds none, the
//! idle collection falls due `idle_collection_delay_ns` after the last owner
//! window and runs once per stretch between requests; a worker whose
//! requests leave its heap near its baseline gets only the young pass, and
//! one whose old generation grew past `idle_full_collection_growth_min_bytes`
//! gets a full collection that gives back what its requests dropped; the
//! collection waits while a dispatched request is held and lets a ready
//! descriptor go first; and a request whose begin waits in the control
//! socket while the collection runs is served after it, its route's module
//! state intact. The test calls the steps the loop calls, `idle.start`
//! before the first wait and `idle.runDue` after a blocked one, with the
//! events that wait would report. That a worker serving small requests
//! keeps the pages it shares with the zygote, and that a worker gives its
//! garbage back through its seccomp filter, measured by its cgroup leaf and
//! its smaps, is covered by the zygote-integration lane
//! (`runtime/tests/integration/zygote.zig`). Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker_limits = @import("collo_limits").worker;
const worker = @import("collo_worker");
const worker_testing = @import("collo_worker_test_support");
const rt = @import("collo_test_harness");

const idle = worker_testing.scheduler.idle;

/// The smallest handler, whose requests leave a few cells behind.
const small_source = "export default () => new Response(\"small\");";

/// A handler whose `/retain` keeps 262,144 objects reachable from module
/// state and whose `/drop` lets them go, so the old generation grows far
/// past the bound and then holds only garbage.
const retaining_source =
    \\let retained = null;
    \\export default function handle(request) {
    \\    if (request.url.endsWith("/retain")) {
    \\        const rounds = [];
    \\        for (let round = 0; round < 64; round++) {
    \\            const items = [];
    \\            for (let i = 0; i < 4096; i++) items.push({ round, index: i, label: `item-${round}-${i}` });
    \\            rounds.push(items);
    \\        }
    \\        retained = rounds;
    \\        return new Response(`retained:${rounds.length * rounds[0].length}`);
    \\    }
    \\    const count = retained.length * retained[0].length;
    \\    retained = null;
    \\    return new Response(`dropped:${count}`);
    \\}
;

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

    /// Registers the route of `source` and records the heap's baseline, as
    /// the boot and then the loop do before the first request.
    fn registerRoute(self: *Fixture, specifier: []const u8, source: []const u8) !u16 {
        const route_index = try rt.registerRoute(&self.runtime, specifier, source);
        idle.start(&self.runtime);
        return route_index;
    }

    fn dispatch(request_id: u64, route_index: u16, path: []const u8) !ipc.DispatchWork {
        return rt.initDispatchWork(std.testing.allocator, .{
            .request_id = request_id,
            .route_index = route_index,
            .deadline_monotonic_ns = request_deadline_ns,
            .request = .{ .path = path },
        });
    }

    /// The client stream `request_id` arrives on: a client opens only
    /// odd-numbered streams, one per request.
    fn streamId(request_id: u64) u32 {
        return @intCast(2 * request_id - 1);
    }

    /// Queues `request_id`'s begin on the runtime as the control channel
    /// would deliver it, without running it.
    fn begin(self: *Fixture, request_id: u64, route_index: u16, path: []const u8) !void {
        var work = try dispatch(request_id, route_index, path);
        defer work.deinit();
        try rt.enqueueIngressRoute(&self.runtime, &work, streamId(request_id), .{ .path = path });
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

    fn serve(self: *Fixture, request_id: u64, route_index: u16, path: []const u8, expected_body: []const u8) !void {
        try self.begin(request_id, route_index, path);
        try self.finish(request_id, expected_body);
    }

    /// Moves the fake clock to the moment the idle collection falls due.
    fn reachCollectionDeadline(self: *Fixture) void {
        self.now_mono_ns = self.runtime.owners.idle_since_mono_ns + worker_limits.idle_collection_delay_ns;
    }

    fn capacityBytes(self: *Fixture) !u64 {
        return (try self.vm.heapStats()).capacity_bytes;
    }
};

test "a worker whose small requests leave its heap near its baseline gets one young pass per stretch, after the idle delay, and never a full collection" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try fixture.registerRoute("/var/task/idle-small.js", small_source);
    try std.testing.expect(!runtime.scheduler.idle.collection_owed);
    for (1..11) |request_id| try fixture.serve(request_id, route_index, "/", "small");
    try std.testing.expect(runtime.scheduler.idle.collection_owed);

    // The cache release has the same delay, so the wait wakes once for both.
    const due_ns = runtime.owners.idle_since_mono_ns + worker_limits.idle_collection_delay_ns;
    try std.testing.expectEqual(due_ns, idle.deadlineNs(runtime));

    fixture.now_mono_ns = due_ns - 1;
    try std.testing.expectEqual(idle.Collection.none, idle.runDue(runtime, &.{.timer_deadline}));
    try std.testing.expect(runtime.scheduler.idle.collection_owed);

    fixture.now_mono_ns = due_ns;
    try std.testing.expectEqual(idle.Collection.young, idle.runDue(runtime, &.{.timer_deadline}));
    try std.testing.expect(!runtime.scheduler.idle.collection_owed);
    try std.testing.expect(runtime.scheduler.idle.heap_baseline_bytes <= try fixture.capacityBytes());

    // Nothing is left to wake for until another request finishes.
    try std.testing.expectEqual(@as(u64, 0), idle.deadlineNs(runtime));
    fixture.now_mono_ns += 10 * worker_limits.idle_collection_delay_ns;
    try std.testing.expectEqual(idle.Collection.none, idle.runDue(runtime, &.{.timer_deadline}));

    try fixture.serve(11, route_index, "/", "small");
    try std.testing.expect(runtime.scheduler.idle.collection_owed);
    fixture.reachCollectionDeadline();
    try std.testing.expectEqual(idle.Collection.young, idle.runDue(runtime, &.{.timer_deadline}));
}

test "a worker whose old generation grew past the bound gets a full collection, which gives back what its requests dropped" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try fixture.registerRoute("/var/task/idle-retaining.js", retaining_source);
    const baseline_bytes = runtime.scheduler.idle.heap_baseline_bytes;
    try std.testing.expectEqual(baseline_bytes, try fixture.capacityBytes());

    // The young pass moves what `/retain` keeps into the old generation,
    // which then stands far past the bound; the full collection frees
    // nothing it keeps.
    try fixture.serve(1, route_index, "/retain", "retained:262144");
    fixture.reachCollectionDeadline();
    try std.testing.expectEqual(idle.Collection.full, idle.runDue(runtime, &.{.timer_deadline}));
    const retained_bytes = try fixture.capacityBytes();
    try std.testing.expect(retained_bytes - baseline_bytes >= worker_limits.idle_full_collection_growth_min_bytes);

    // Dropped, those cells are old garbage, which the young pass cannot
    // see and the full collection frees.
    try fixture.serve(2, route_index, "/drop", "dropped:262144");
    fixture.reachCollectionDeadline();
    try std.testing.expectEqual(idle.Collection.full, idle.runDue(runtime, &.{.timer_deadline}));
    const dropped_bytes = try fixture.capacityBytes();
    try std.testing.expect(dropped_bytes -| baseline_bytes < (retained_bytes - baseline_bytes) / 2);
}

test "the idle collection waits while a dispatched request is held, and a ready descriptor goes before it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;

    const route_index = try fixture.registerRoute("/var/task/idle-held.js", small_source);
    try fixture.serve(1, route_index, "/", "small");
    try std.testing.expect(runtime.scheduler.idle.collection_owed);

    // A begun request is held from its begin to its finish, run or not.
    try fixture.begin(2, route_index, "/");
    fixture.now_mono_ns = runtime.owners.idle_since_mono_ns + 10 * worker_limits.idle_collection_delay_ns;
    try std.testing.expectEqual(idle.Collection.none, idle.runDue(runtime, &.{.timer_deadline}));
    try std.testing.expect(runtime.scheduler.idle.collection_owed);

    try fixture.finish(2, "small");
    const due_ns = runtime.owners.idle_since_mono_ns + worker_limits.idle_collection_delay_ns;
    try std.testing.expectEqual(due_ns, idle.deadlineNs(runtime));
    fixture.now_mono_ns = due_ns;
    // The control socket may hold the next request's begin.
    try std.testing.expectEqual(idle.Collection.none, idle.runDue(runtime, &.{ .timer_deadline, .control_ready }));
    try std.testing.expect(runtime.scheduler.idle.collection_owed);
    // The next wait finds the deadline passed and nothing else ready.
    try std.testing.expectEqual(idle.Collection.young, idle.runDue(runtime, &.{.timer_deadline}));
    try std.testing.expect(!runtime.scheduler.idle.collection_owed);
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
    // reachable from module state. The handler allocates enough that the
    // idle collection runs its full pass too.
    const route_index = try fixture.registerRoute("/var/task/idle-state.js",
        \\const cache = new Map();
        \\let finalized = 0;
        \\const registry = new FinalizationRegistry(() => { finalized += 1; });
        \\const held = { label: "held" };
        \\registry.register(held, "held");
        \\const weak = new WeakRef(held);
        \\const kept = [];
        \\export default function handle() {
        \\    const size = cache.size;
        \\    cache.set(size, `entry-${size}`);
        \\    for (let i = 0; i < 65536; i++) kept.push({ index: i, label: `kept-${i}` });
        \\    return new Response(`${size}:${cache.get(0)}:${held.label}:${weak.deref()?.label}:${finalized}:${kept.length}`);
        \\}
    );
    try fixture.serve(1, route_index, "/", "0:entry-0:held:held:0:65536");
    fixture.reachCollectionDeadline();

    // The server sends the next begin after the wait returned for the
    // deadline alone, so the begin is unread while the collection runs.
    var work = try Fixture.dispatch(2, route_index, "/");
    defer work.deinit();
    try rt.sendIngressRoute(fixture.control_pair[1], &work, Fixture.streamId(2), .{ .path = "/" });
    try std.testing.expectEqual(idle.Collection.full, idle.runDue(runtime, &.{.timer_deadline}));
    try std.testing.expect(!runtime.requests.active.contains(2));

    // The harness's reader pumps the runtime, which reads the begin then.
    var response = try rt.readIngressResponse(runtime, fixture.control_pair[1], 2);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("1:entry-0:held:held:0:131072", response.body);
}
