//! The pools and worker records as the supervisor builds and keeps them
//! (`Supervisor.init` in `server/supervisor/supervisor.zig`): one pool
//! per worker definition, sized from that definition's `concurrency` and the
//! pool caps of `scheduler_limits.zig`; the record storage each launch ticket
//! names, which holds one worker at a time from the build for its publish to
//! its teardown (`worker_registry.zig`); the cap on launches in flight; the
//! memory gate, which refuses growth at the node's memory ceiling and wakes
//! demand reclaim above the high water; a slot that frees, which goes to the
//! request waiting for it at once; a worker whose launch ends after another
//! worker served its waiter, which stays idle for the reaper; and a settle,
//! which takes no pool lock. One pool on its own, through every interleaving
//! of two lanes, is covered in `pool.zig`, and lanes acting on these results
//! in `server/tests/ingress/`. Lane `server-supervisor-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const supervision = @import("collo_server_supervisor");
const config = @import("collo_server_config");
const lifecycle = @import("collo_server_lifecycle");
const limits = @import("collo_limits");
const fixture = @import("supervisor_fixture");

const testing = std.testing;
const pool_mod = supervision.pool;
const capacity = supervision.scheduler_limits.capacity;
const memory_limits = supervision.scheduler_limits.memory;
const worker_registry = supervision.worker_registry;
const Supervisor = supervision.Supervisor;
const WorkerRecord = supervision.worker_table.Record;
const WorkerPool = pool_mod.Pool(WorkerRecord);

const demo = fixture.default_definition;
const beta: config.DefinitionIndex = 1;
const far_ns: u64 = std.math.maxInt(u64);

fn requestKey(lane: pool_mod.LaneId, request: u32) lifecycle.RequestKey {
    return .{ .lane_id = lane, .slot = request, .generation = 1 };
}

fn expectAcquired(worker_pool: *WorkerPool, lane: pool_mod.LaneId, request: u32) !WorkerPool.Acquired {
    return switch (worker_pool.acquire(lane, requestKey(lane, request), far_ns)) {
        .acquired => |acquired| acquired,
        .wait, .full => error.TestExpectedAcquired,
    };
}

fn expectHandoff(released: WorkerPool.Released) !WorkerPool.Handoff {
    return switch (released) {
        .handed_to => |handoff| handoff,
        .idle, .retire => error.TestExpectedHandoff,
    };
}

/// A ticket for a launch of `worker_pool`, which has no worker with a free
/// slot, claimed for a request that stops waiting before the launch ends.
fn claimTicket(worker_pool: *WorkerPool) !pool_mod.LaunchTicket {
    const waiter = requestKey(9, 1);
    if (worker_pool.acquire(9, waiter, far_ns) != .wait) return error.TestExpectedWait;
    const ticket = worker_pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    if (!worker_pool.cancelWaiter(waiter)) return error.TestExpectedWaiter;
    return ticket;
}

/// Builds the record of a worker that reported ready, as the launcher's
/// publish does (`worker_registry.buildRecord`), from what the launcher hands
/// over (`launcher.ReadyWorker`): an inert handle and the send scratch the
/// launch allocated before its fork, which the record keeps.
fn buildReadyRecord(
    supervisor: *Supervisor,
    definition: config.DefinitionIndex,
    ticket: pool_mod.LaunchTicket,
) !*WorkerRecord {
    var handle = try fixture.inertHandle(supervisor.allocator);
    errdefer handle.deinit();
    const scratch = try supervisor.allocator.alloc(u8, ipc.max_message_bytes);
    errdefer supervisor.allocator.free(scratch);
    return worker_registry.buildRecord(supervisor, definition, ticket, .{
        .handle = handle,
        .egress_wake_set = .{},
        .egress_generation = 0,
        .egress_session_id = 0,
        .dispatch_send_scratch = scratch,
    });
}

/// What claims wrote to the demand-reclaim eventfd since the last call.
fn takeNudges(eventfd: std.posix.fd_t) !u64 {
    var count: u64 = 0;
    _ = std.posix.read(eventfd, std.mem.asBytes(&count)) catch |err| switch (err) {
        error.WouldBlock => return 0,
        else => return err,
    };
    return count;
}

test "the supervisor builds one pool per definition from that definition's concurrency and the pool caps" {
    var supervisor = try fixture.minimalSupervisorWith(testing.allocator, .{ .routes = .{ .concurrency = 1 } });
    defer fixture.deinitMinimal(&supervisor);

    const definition_count: usize = supervisor.routes.definitionCount();
    try testing.expectEqual(definition_count, supervisor.pools.len);
    for (supervisor.pools, 0..) |*worker_pool, index| {
        const definition: config.DefinitionIndex = @intCast(index);
        try testing.expect(supervisor.poolFor(definition) == worker_pool);
        try testing.expectEqual(supervisor.routes.definition(definition).settings.limits.concurrency, worker_pool.concurrency);
        try testing.expectEqual(@as(u8, 1), worker_pool.concurrency);
        try testing.expectEqual(@as(usize, capacity.pool_workers_max), worker_pool.entries.len);
        try testing.expectEqual(capacity.pool_cold_starts_in_flight_max, worker_pool.launches_max);
        try testing.expectEqual(@as(usize, limits.pool.pool_waiters_max), worker_pool.waiters.len);
        const snapshot = worker_pool.snapshot();
        try testing.expectEqual(@as(u32, 0), snapshot.workers_live);
        try testing.expectEqual(@as(u32, 0), snapshot.launching);
        try testing.expectEqual(@as(u32, 0), snapshot.waiters);
    }

    // Every entry of every pool has its record storage from the start, vacant
    // and fixed to the entry's definition, so a launch never allocates one.
    try testing.expectEqual(definition_count * capacity.pool_workers_max, supervisor.records.len);
    for (supervisor.records, 0..) |*record, index| {
        const definition: config.DefinitionIndex = @intCast(index / capacity.pool_workers_max);
        try testing.expectEqual(definition, record.definition_index);
        try testing.expectEqualStrings(fixture.definition_names[definition], record.name);
        try testing.expectEqual(@as(u64, 0), record.id);
        try testing.expect(!record.page_mapped);
    }
    for (0..definition_count) |index| {
        const definition: config.DefinitionIndex = @intCast(index);
        const records = supervisor.recordsOf(definition);
        try testing.expectEqual(@as(usize, capacity.pool_workers_max), records.len);
        try testing.expect(&records[0] == &supervisor.records[index * capacity.pool_workers_max]);
    }
}

test "a worker in one definition's pool never serves another definition's request" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{ .definition_index = demo });

    // Beta has no worker, so its request waits while demo's worker sits idle.
    try testing.expect(supervisor.poolFor(beta).acquire(0, requestKey(0, 1), far_ns) == .wait);
    const served = try expectAcquired(supervisor.poolFor(demo), 0, 2);
    try testing.expect(served.worker == worker);
    try testing.expect((try supervisor.poolFor(demo).release(served.worker, served.slot, 1)) == .idle);
    try testing.expect(supervisor.poolFor(beta).cancelWaiter(requestKey(0, 1)));
}

test "a launch ticket names the record storage its worker is built in" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const beta_pool = supervisor.poolFor(beta);

    try testing.expect(beta_pool.acquire(1, requestKey(1, 7), far_ns) == .wait);
    const ticket = beta_pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    const storage = supervisor.ticketRecord(beta, ticket);
    try testing.expect(storage == &supervisor.records[@as(usize, beta) * capacity.pool_workers_max + ticket.entry]);
    try testing.expect(storage == fixture.recordFor(&supervisor, beta, ticket.entry));
    try testing.expectEqual(beta, storage.definition_index);
    try testing.expectEqual(@as(u64, 0), storage.id);

    const worker = try fixture.buildRecord(&supervisor, beta, ticket, try fixture.inertHandle(testing.allocator), .{});
    try testing.expect(worker == storage);
    try testing.expect(worker.id != 0);
    const handoffs = try beta_pool.publish(ticket, worker, 10);
    try testing.expectEqual(@as(usize, 1), handoffs.slice().len);
    const handoff = handoffs.slice()[0];
    try testing.expect(handoff.waiter.request_key.eql(requestKey(1, 7)));
    try testing.expect(handoff.worker == worker);
    // The pool of another definition never holds the record.
    try testing.expect(supervisor.poolFor(demo).inspect(worker) == null);
    try testing.expect((try beta_pool.release(worker, handoff.slot, 11)) == .idle);
}

test "a record holds one worker at a time, built under a fresh key and torn down vacant for its entry's next launch" {
    var analytics_dir = try fixture.AnalyticsDir.init(testing.allocator);
    defer analytics_dir.deinit(testing.allocator);
    var supervisor = try fixture.minimalSupervisorWithAnalytics(testing.allocator, analytics_dir.path);
    defer fixture.deinitMinimal(&supervisor);
    const demo_pool = supervisor.poolFor(demo);
    const beta_pool = supervisor.poolFor(beta);

    // Keys follow the order of the builds, whichever pool a worker joins.
    const first_ticket = try claimTicket(demo_pool);
    const first = try buildReadyRecord(&supervisor, demo, first_ticket);
    try testing.expect(first == supervisor.ticketRecord(demo, first_ticket));
    try testing.expect(first.key().eql(.{ .worker_id = 1, .worker_generation = 1 }));
    try testing.expect(first.page_mapped);
    try testing.expectEqual(@as(usize, ipc.max_message_bytes), first.dispatch_send_scratch.len);
    _ = try demo_pool.publish(first_ticket, first, 10);
    const second_ticket = try claimTicket(beta_pool);
    const second = try buildReadyRecord(&supervisor, beta, second_ticket);
    try testing.expect(second.key().eql(.{ .worker_id = 2, .worker_generation = 2 }));
    _ = try beta_pool.publish(second_ticket, second, 10);

    // The first worker retires with a usage record still in its ring. The
    // teardown writes that record, unmaps the page and leaves the storage
    // vacant, and only then does the pool let the entry go.
    try fixture.publishCompletedRecord(first, 61);
    try testing.expect(demo_pool.retireIdle(first) == .retire);
    worker_registry.teardown(&supervisor, first);
    try testing.expectEqual(@as(u64, 0), first.id);
    try testing.expect(!first.page_mapped);
    try demo_pool.remove(first);
    var lines = try analytics_dir.readUsage(testing.allocator, supervisor.analytics);
    defer lines.deinit();
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqual(@as(u64, 61), lines.items[0].request_id);

    // The entry's next launch builds its worker in the same storage, under a
    // key no earlier worker had.
    const third_ticket = try claimTicket(demo_pool);
    try testing.expect(supervisor.ticketRecord(demo, third_ticket) == first);
    const third = try buildReadyRecord(&supervisor, demo, third_ticket);
    try testing.expect(third.key().eql(.{ .worker_id = 3, .worker_generation = 3 }));
    _ = try demo_pool.publish(third_ticket, third, 20);
}

test "a pool claims at most pool_cold_starts_in_flight_max launches at once" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const demo_pool = supervisor.poolFor(demo);

    // More requests wait than the capped launches can serve between them.
    const waiting = capacity.pool_cold_starts_in_flight_max * demo_pool.concurrency + 1;
    var request: u32 = 0;
    while (request < waiting) : (request += 1)
        try testing.expect(demo_pool.acquire(0, requestKey(0, request), far_ns) == .wait);
    var tickets: [capacity.pool_cold_starts_in_flight_max]pool_mod.LaunchTicket = undefined;
    for (&tickets) |*ticket|
        ticket.* = demo_pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    // One waiter is left uncovered, and the cap still refuses a third launch.
    try testing.expect(demo_pool.launchStarted(true) == null);
    try testing.expectEqual(capacity.pool_cold_starts_in_flight_max, demo_pool.snapshot().launching);

    // With the launches gone and no worker live, nothing can serve the
    // waiters, and the pool hands every one of them back.
    for (tickets) |ticket|
        try demo_pool.launchEnded(ticket);
    var stranded: [8]pool_mod.Waiter = undefined;
    try testing.expectEqual(@as(usize, waiting), demo_pool.takeStranded(&stranded).len);
}

test "the memory gate refuses growth at the node's memory ceiling, and a claim from the high water up wakes demand reclaim" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const demo_pool = supervisor.poolFor(demo);
    // The eventfd the reaper publishes for demand reclaim (`Reaper.init`).
    const nudges = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(nudges);
    supervisor.demand_reclaim_eventfd.store(nudges, .release);
    defer supervisor.demand_reclaim_eventfd.store(-1, .release);
    try testing.expect(demo_pool.acquire(0, requestKey(0, 1), far_ns) == .wait);

    // Below the high water a claim launches and asks nothing of the reaper.
    supervisor.cached_used_percent.store(memory_limits.autoscale_high_water_percent - 1, .monotonic);
    try testing.expect(demo_pool.growthWanted(supervisor.memoryGate()));
    const calm_ticket = supervisor.claimLaunch(demo) orelse return error.TestExpectedLaunch;
    try demo_pool.launchEnded(calm_ticket);
    try testing.expectEqual(@as(u64, 0), try takeNudges(nudges));

    // From the high water to just below the ceiling a claim still launches,
    // and wakes the reaper to give idle workers' memory back.
    supervisor.cached_used_percent.store(memory_limits.autoscale_high_water_percent, .monotonic);
    const high_ticket = supervisor.claimLaunch(demo) orelse return error.TestExpectedLaunch;
    try demo_pool.launchEnded(high_ticket);
    try testing.expectEqual(@as(u64, 1), try takeNudges(nudges));

    // At the ceiling a lane's growth check and the launcher's claim both
    // refuse, and the refused claim wakes the reaper too.
    supervisor.cached_used_percent.store(memory_limits.fork_deny_percent, .monotonic);
    try testing.expect(!supervisor.memoryGate());
    try testing.expect(!demo_pool.growthWanted(supervisor.memoryGate()));
    try testing.expect(supervisor.claimLaunch(demo) == null);
    try testing.expectEqual(@as(u64, 1), try takeNudges(nudges));
    try testing.expect(demo_pool.cancelWaiter(requestKey(0, 1)));
}

test "a settle takes no pool lock, so it finishes while its worker's pool is locked" {
    var supervisor = try fixture.minimalSupervisor(testing.allocator);
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    const demo_pool = supervisor.poolFor(demo);
    const served = try expectAcquired(demo_pool, 0, 1);
    try worker.requests.record(fixture.dispatchedRequest(1));

    // A lane settles its request before it gives the slot back, under the
    // worker's own locks only, so no other lane's pool call can hold it up.
    // This thread holding the pool's mutex stands in for such a call: a
    // settle that took the mutex would deadlock here, which a Debug build
    // reports as a panic.
    demo_pool.mutex.lock();
    supervisor.settleRequest(worker, 1, .{ .floor = .{ .status = .crash } });
    demo_pool.mutex.unlock();

    try testing.expect(worker.requests.dispatchedFor(1) == null);
    try testing.expect((try demo_pool.release(worker, served.slot, 1)) == .idle);
}

test "a slot that frees goes to the request waiting for it at once (#29)" {
    var supervisor = try fixture.minimalSupervisorWith(testing.allocator, .{ .routes = .{ .concurrency = 1 } });
    defer fixture.deinitMinimal(&supervisor);
    const worker = try fixture.publishInertWorker(&supervisor, .{});
    const demo_pool = supervisor.poolFor(demo);

    const first = try expectAcquired(demo_pool, 0, 1);
    try testing.expect(first.worker == worker);
    // The only slot is held, so lane 1's request waits, and nothing in the
    // pool moves it until that slot comes back.
    try testing.expect(demo_pool.acquire(1, requestKey(1, 1), far_ns) == .wait);
    var snapshot = demo_pool.snapshot();
    try testing.expectEqual(@as(u32, 1), snapshot.waiters);
    try testing.expectEqual(@as(u64, 0), snapshot.counters.handed_off);

    // The release itself returns the handoff: no timer or later wake stands
    // between the freed slot and the waiter.
    const handoff = try expectHandoff(try demo_pool.release(worker, first.slot, 5));
    try testing.expectEqual(@as(pool_mod.LaneId, 1), handoff.waiter.lane);
    try testing.expect(handoff.waiter.request_key.eql(requestKey(1, 1)));
    try testing.expect(handoff.worker == worker);
    try testing.expectEqual(first.slot, handoff.slot);
    snapshot = demo_pool.snapshot();
    try testing.expectEqual(@as(u32, 0), snapshot.waiters);
    try testing.expectEqual(@as(u32, 1), snapshot.slots_held);
    try testing.expectEqual(@as(u64, 1), snapshot.counters.handed_off);
    try testing.expect((try demo_pool.release(worker, handoff.slot, 6)) == .idle);
}

test "a worker whose launch ends after its waiter was served stays idle for the reaper (#32)" {
    var supervisor = try fixture.minimalSupervisorWith(testing.allocator, .{ .routes = .{ .concurrency = 1 } });
    defer fixture.deinitMinimal(&supervisor);
    const warm = try fixture.publishInertWorker(&supervisor, .{});
    const demo_pool = supervisor.poolFor(demo);

    // The next request arrives while the warm worker's only slot is still
    // held, waits, and starts a launch.
    const busy = try expectAcquired(demo_pool, 0, 1);
    try testing.expect(demo_pool.acquire(0, requestKey(0, 2), far_ns) == .wait);
    try testing.expect(demo_pool.growthWanted(true));
    const ticket = demo_pool.launchStarted(true) orelse return error.TestExpectedLaunch;

    // The warm slot frees before the launch ends, and the waiter takes it.
    const handoff = try expectHandoff(try demo_pool.release(warm, busy.slot, 10));
    try testing.expect(handoff.worker == warm);
    try testing.expect(handoff.waiter.request_key.eql(requestKey(0, 2)));

    // The launch ends with nobody left to serve: its worker joins the free
    // list idle, with no reader, and the reaper's idle list names it.
    const fresh = try fixture.buildRecord(&supervisor, demo, ticket, try fixture.inertHandle(testing.allocator), .{});
    try testing.expectEqual(@as(usize, 0), (try demo_pool.publish(ticket, fresh, 20)).slice().len);
    const view = demo_pool.inspect(fresh) orelse return error.TestExpectedWorker;
    try testing.expectEqual(pool_mod.EntryState.live, view.state);
    try testing.expectEqual(@as(u8, 0), view.slots_held);
    try testing.expect(view.reader == null);
    var idle: [2]WorkerPool.IdleWorker = undefined;
    const listed = demo_pool.idleWorkers(&idle);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expect(listed[0].worker == fresh);
    try testing.expectEqual(@as(u64, 20), listed[0].idle_since_ns);
    try testing.expectEqual(@as(u64, 1), demo_pool.snapshot().counters.handed_off);

    // Once the warm worker is free again it takes the next request, being
    // the most recently used, so the fresh one stays at the free list's cold
    // end until it retires.
    try testing.expect((try demo_pool.release(warm, handoff.slot, 30)) == .idle);
    const next = try expectAcquired(demo_pool, 0, 3);
    try testing.expect(next.worker == warm);
    try testing.expect((try demo_pool.release(warm, next.slot, 40)) == .idle);
}
