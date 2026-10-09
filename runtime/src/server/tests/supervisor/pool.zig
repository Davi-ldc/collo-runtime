//! The pool of one worker definition (`server/supervisor/pool.zig`), driven
//! with no lane, launcher or reaper behind it. The first tests check each
//! call against its documented result. The rest run every interleaving of two
//! lanes' scripts against a model of the lanes that discharges what each
//! result asks for, the way `server/ingress/lane_commands.zig` says lanes do,
//! with a post landing only at its sender's next step so another lane can run
//! between a pool call and its command. After every step the model checks
//! that no slot is lost or doubled, that a handoff goes to the oldest waiter
//! that is neither expired nor cancelled, that no slot of a dead or retiring
//! worker is handed out, that one lane at most reads a worker and its epoch
//! moves only when the reader changes, and that a worker retires once. The
//! lanes, the launcher and the reaper that act on these results run in
//! `server-ingress` and `local-e2e`.

const std = @import("std");
const lifecycle = @import("collo_server_lifecycle");
const limits = @import("collo_limits");
const pool_mod = @import("collo_server_supervisor").pool;

const testing = std.testing;
const LaneId = pool_mod.LaneId;
const Slot = pool_mod.Slot;
const ReaderEpoch = pool_mod.ReaderEpoch;
const ReaderGrant = pool_mod.ReaderGrant;
const ReaderTenure = pool_mod.ReaderTenure;
const Transfer = pool_mod.Transfer;
const RequestKey = lifecycle.RequestKey;

/// A record the pool only points at; `index` is its place in the test's
/// array, and `generation` tells apart the workers one storage holds.
const Worker = struct {
    index: u8,
    generation: u64 = 1,

    pub fn key(self: *const Worker) lifecycle.WorkerKey {
        return .{ .worker_id = @as(u64, self.index) + 1, .worker_generation = self.generation };
    }
};
const TestPool = pool_mod.Pool(Worker);

const far_ns: u64 = std.math.maxInt(u64);
const lane_a: LaneId = 0;
const lane_b: LaneId = 1;

fn requestKey(lane: LaneId, request: u32) RequestKey {
    return .{ .lane_id = lane, .slot = request, .generation = 1 };
}

fn shape(concurrency: u8, workers_max: u32) pool_mod.Options {
    return .{
        .concurrency = concurrency,
        .workers_max = workers_max,
        .launches_max = workers_max,
        .waiters_max = 8,
    };
}

/// The production FIFO bound and slot count, on a small table.
const real_fifo: pool_mod.Options = .{
    .concurrency = limits.server.worker_concurrency_max,
    .workers_max = 4,
    .launches_max = 2,
    .waiters_max = limits.pool.pool_waiters_max,
};

fn expectWait(pool: *TestPool, lane: LaneId, request: u32, deadline_ns: u64) !void {
    try testing.expect(pool.acquire(lane, requestKey(lane, request), deadline_ns) == .wait);
}

fn expectAcquired(pool: *TestPool, lane: LaneId, request: u32) !TestPool.Acquired {
    return switch (pool.acquire(lane, requestKey(lane, request), far_ns)) {
        .acquired => |acquired| acquired,
        .wait, .full => error.TestExpectedAcquired,
    };
}

fn expectHandoff(released: TestPool.Released) !TestPool.Handoff {
    return switch (released) {
        .handed_to => |handoff| handoff,
        .idle, .retire => error.TestExpectedHandoff,
    };
}

/// Publishes `worker` to the one request `lane` queues for it, which then
/// holds slot 0, and returns that grant.
fn publishToNewWaiter(pool: *TestPool, worker: *Worker, lane: LaneId, request: u32) !ReaderGrant {
    try expectWait(pool, lane, request, far_ns);
    const ticket = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    const handoffs = try pool.publish(ticket, worker, 0);
    try testing.expectEqual(@as(usize, 1), handoffs.slice().len);
    try testing.expect(handoffs.slice()[0].waiter.request_key.eql(requestKey(lane, request)));
    return handoffs.slice()[0].reader;
}

fn expectSlotsBalanced(pool: *TestPool) !void {
    const snapshot = pool.snapshot();
    try testing.expectEqual(snapshot.slot_capacity, snapshot.slots_held + snapshot.slots_free);
}

test "init refuses options outside their documented ranges" {
    var pool: TestPool = undefined;
    const invalid = [_]pool_mod.Options{
        .{ .concurrency = 0, .workers_max = 2, .launches_max = 1, .waiters_max = 1 },
        .{ .concurrency = pool_mod.slots_per_worker_max + 1, .workers_max = 2, .launches_max = 1, .waiters_max = 1 },
        .{ .concurrency = 1, .workers_max = 0, .launches_max = 1, .waiters_max = 1 },
        .{ .concurrency = 1, .workers_max = pool_mod.entries_max + 1, .launches_max = 1, .waiters_max = 1 },
        .{ .concurrency = 1, .workers_max = 2, .launches_max = 0, .waiters_max = 1 },
        .{ .concurrency = 1, .workers_max = 2, .launches_max = 3, .waiters_max = 1 },
        .{ .concurrency = 1, .workers_max = 2, .launches_max = 1, .waiters_max = 0 },
    };
    for (invalid) |options|
        try testing.expectError(error.InvalidPoolOptions, pool.init(testing.allocator, options));
    try pool.init(testing.allocator, shape(1, 2));
    pool.deinit();
}

test "init frees what it allocated when the table or the FIFO cannot be allocated" {
    var fail_index: usize = 0;
    while (fail_index <= 2) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var pool: TestPool = undefined;
        pool.init(failing.allocator(), real_fifo) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(fail_index < 2);
            continue;
        };
        // The table and the FIFO are the only two allocations.
        try testing.expectEqual(@as(usize, 2), fail_index);
        pool.deinit();
    }
}

test "an empty pool queues requests and answers full past pool_waiters_max" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, real_fifo);
    defer pool.deinit();

    var request: u32 = 0;
    while (request < limits.pool.pool_waiters_max) : (request += 1)
        try expectWait(&pool, lane_a, request, far_ns);
    try testing.expect(pool.acquire(lane_b, requestKey(lane_b, 0), far_ns) == .full);
    var snapshot = pool.snapshot();
    try testing.expectEqual(limits.pool.pool_waiters_max, snapshot.waiters);
    try testing.expectEqual(@as(u64, 1), snapshot.counters.full);

    // A cancel opens one place, which the next request takes.
    try testing.expect(pool.cancelWaiter(requestKey(lane_a, 7)));
    try expectWait(&pool, lane_b, 0, far_ns);
    try testing.expect(pool.acquire(lane_b, requestKey(lane_b, 1), far_ns) == .full);
    snapshot = pool.snapshot();
    try testing.expectEqual(limits.pool.pool_waiters_max, snapshot.waiters);
    try testing.expectEqual(@as(u64, 2), snapshot.counters.full);
}

test "publish serves the oldest waiters first and the first handoff makes its lane the reader" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(2, 2));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    try expectWait(&pool, lane_a, 0, far_ns);
    try expectWait(&pool, lane_b, 0, far_ns);
    try expectWait(&pool, lane_a, 1, far_ns);
    const ticket = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    const handoffs = try pool.publish(ticket, &worker, 10);
    const served = handoffs.slice();
    try testing.expectEqual(@as(usize, 2), served.len);
    try testing.expect(served[0].waiter.request_key.eql(requestKey(lane_a, 0)));
    try testing.expectEqual(ReaderGrant{ .you_become_reader = 1 }, served[0].reader);
    try testing.expect(served[1].waiter.request_key.eql(requestKey(lane_b, 0)));
    try testing.expectEqual(ReaderGrant.already, served[1].reader);
    try testing.expect(served[0].slot != served[1].slot);

    const snapshot = pool.snapshot();
    try testing.expectEqual(@as(u32, 1), snapshot.waiters);
    try testing.expectEqual(@as(u32, 2), snapshot.slots_held);
    try testing.expectEqual(@as(u32, 0), snapshot.slots_free);
    try testing.expectEqual(@as(u32, 0), snapshot.launching);
}

test "a freed slot goes to the oldest waiter whose deadline has not passed" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    try expectWait(&pool, lane_b, 0, 50);
    try expectWait(&pool, lane_a, 1, 500);
    try expectWait(&pool, lane_b, 1, 500);

    const handoff = try expectHandoff(try pool.release(&worker, 0, 100));
    try testing.expect(handoff.waiter.request_key.eql(requestKey(lane_a, 1)));
    try testing.expectEqual(ReaderGrant.already, handoff.reader);
    const snapshot = pool.snapshot();
    try testing.expectEqual(@as(u64, 1), snapshot.counters.waiters_expired);
    try testing.expectEqual(@as(u32, 1), snapshot.waiters);
    // The expired waiter is gone, so its lane's cancel finds nothing.
    try testing.expect(!pool.cancelWaiter(requestKey(lane_b, 0)));
}

test "a cancelled waiter is never served, and a cancel after the handoff reports it" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    try expectWait(&pool, lane_b, 0, far_ns);
    try expectWait(&pool, lane_a, 1, far_ns);
    try testing.expect(pool.cancelWaiter(requestKey(lane_b, 0)));

    const handoff = try expectHandoff(try pool.release(&worker, 0, 1));
    try testing.expect(handoff.waiter.request_key.eql(requestKey(lane_a, 1)));
    // The handoff took the waiter, so the lane learns that its slot is on the
    // way and gives it back when `dispatch_ready` arrives.
    try testing.expect(!pool.cancelWaiter(requestKey(lane_a, 1)));
    try testing.expect(!pool.cancelWaiter(requestKey(lane_b, 5)));
    try testing.expect((try pool.release(&worker, handoff.slot, 2)) == .idle);

    const snapshot = pool.snapshot();
    try testing.expectEqual(@as(u32, 0), snapshot.waiters);
    try testing.expectEqual(@as(u32, 0), snapshot.slots_held);
    try testing.expectEqual(@as(u64, 1), snapshot.counters.waiters_cancelled);
}

test "the free list hands out the most recently used worker first and a fresh idle worker last" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 3));
    defer pool.deinit();
    var workers = [_]Worker{ .{ .index = 0 }, .{ .index = 1 }, .{ .index = 2 } };

    _ = try publishToNewWaiter(&pool, &workers[0], lane_a, 0);
    _ = try publishToNewWaiter(&pool, &workers[1], lane_a, 1);
    // The third launch's waiter leaves before the worker is published.
    try expectWait(&pool, lane_a, 2, far_ns);
    const ticket = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    try testing.expect(pool.cancelWaiter(requestKey(lane_a, 2)));
    try testing.expectEqual(@as(usize, 0), (try pool.publish(ticket, &workers[2], 3)).slice().len);

    try testing.expect((try pool.release(&workers[1], 0, 4)) == .idle);
    try testing.expect((try pool.release(&workers[0], 0, 5)) == .idle);
    try testing.expectEqual(&workers[0], (try expectAcquired(&pool, lane_b, 0)).worker);
    try testing.expectEqual(&workers[1], (try expectAcquired(&pool, lane_b, 1)).worker);
    try testing.expectEqual(&workers[2], (try expectAcquired(&pool, lane_b, 2)).worker);
    try expectSlotsBalanced(&pool);
}

test "a death names each holder and the reader once, never serves the dead worker, and retires it after the last hold" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(2, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    try testing.expectEqual(ReaderGrant{ .you_become_reader = 1 }, try publishToNewWaiter(&pool, &worker, lane_a, 0));
    const second = try expectAcquired(&pool, lane_b, 0);
    try testing.expectEqual(ReaderGrant.already, second.reader);
    try expectWait(&pool, lane_a, 1, far_ns);

    const death = pool.markDead(&worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expectEqualSlices(LaneId, &.{ lane_a, lane_b }, death.slice());
    try testing.expect(!death.retire);
    try testing.expect(pool.markDead(&worker, worker.key()) == null);

    // The dead worker's slots go nowhere, so the waiter keeps waiting.
    try testing.expect((try pool.release(&worker, second.slot, 10)) == .idle);
    try testing.expectEqual(@as(u32, 1), pool.snapshot().waiters);
    try testing.expectEqual(Transfer.vacated, pool.transferReader(&worker, .{ .lane = lane_a, .epoch = 1 }, .nothing));
    try testing.expect((try pool.release(&worker, 0, 11)) == .retire);

    var snapshot = pool.snapshot();
    try testing.expectEqual(@as(u32, 1), snapshot.workers_dead);
    try testing.expectEqual(@as(u32, 0), snapshot.slots_held_dead);
    try testing.expectEqual(@as(u64, 1), snapshot.counters.retirements);
    try pool.remove(&worker);
    try testing.expect(pool.inspect(&worker) == null);
    try expectWait(&pool, lane_b, 1, far_ns);
    snapshot = pool.snapshot();
    try testing.expectEqual(@as(u32, 0), snapshot.workers_dead);
}

test "the reader keeps its role across idle and busy and gives it up only at an idle moment, and only a new reader moves the epoch" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };
    const tenure_a: ReaderTenure = .{ .lane = lane_a, .epoch = 1 };

    try testing.expectEqual(ReaderGrant{ .you_become_reader = 1 }, try publishToNewWaiter(&pool, &worker, lane_a, 0));
    _ = try pool.release(&worker, 0, 1);
    try testing.expectEqual(ReaderGrant.already, (try expectAcquired(&pool, lane_a, 1)).reader);
    _ = try pool.release(&worker, 0, 2);

    // Another lane takes the idle worker and is asked to request the role.
    try testing.expectEqual(ReaderGrant{ .transfer_from = tenure_a }, (try expectAcquired(&pool, lane_b, 0)).reader);
    // The reader answers while that request runs, so it keeps the role.
    try testing.expectEqual(Transfer.kept, pool.transferReader(&worker, tenure_a, .nothing));
    try testing.expectEqual(@as(?ReaderTenure, tenure_a), pool.inspect(&worker).?.reader);
    _ = try pool.release(&worker, 0, 3);

    // The answer cleared the request, so the next idle take asks again.
    try testing.expectEqual(ReaderGrant{ .transfer_from = tenure_a }, (try expectAcquired(&pool, lane_b, 1)).reader);
    _ = try pool.release(&worker, 0, 4);
    try testing.expectEqual(Transfer.vacated, pool.transferReader(&worker, tenure_a, .nothing));
    // A second `release_worker` for the same tenure finds it over.
    try testing.expectEqual(Transfer.stale, pool.transferReader(&worker, tenure_a, .nothing));
    try testing.expect(pool.inspect(&worker).?.reader == null);

    try testing.expectEqual(ReaderGrant{ .you_become_reader = 2 }, (try expectAcquired(&pool, lane_b, 2)).reader);
    try testing.expectEqual(Transfer.stale, pool.transferReader(&worker, tenure_a, .nothing));
    const counters = pool.snapshot().counters;
    try testing.expectEqual(@as(u64, 2), counters.readers_assigned);
    try testing.expectEqual(@as(u64, 2), counters.reader_releases_requested);
    try testing.expectEqual(@as(u64, 1), counters.readers_released);
}

test "an entry's reader epoch keeps counting across the workers it holds, so an old release never ends a later tenure" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    // The supervisor reuses a record's storage for the entry's next worker,
    // so the pointer alone cannot tell the two apart.
    var storage: Worker = .{ .index = 0 };

    try testing.expectEqual(ReaderGrant{ .you_become_reader = 1 }, try publishToNewWaiter(&pool, &storage, lane_a, 0));
    _ = pool.markDead(&storage, storage.key()) orelse return error.TestExpectedDeath;
    try testing.expect((try pool.release(&storage, 0, 1)) == .idle);
    try testing.expectEqual(Transfer.retire, pool.transferReader(&storage, .{ .lane = lane_a, .epoch = 1 }, .nothing));
    try pool.remove(&storage);

    try testing.expectEqual(ReaderGrant{ .you_become_reader = 2 }, try publishToNewWaiter(&pool, &storage, lane_a, 1));
    _ = try pool.release(&storage, 0, 2);
    try testing.expectEqual(Transfer.stale, pool.transferReader(&storage, .{ .lane = lane_a, .epoch = 1 }, .nothing));
    try testing.expectEqual(Transfer.vacated, pool.transferReader(&storage, .{ .lane = lane_a, .epoch = 2 }, .nothing));
}

test "a reader is asked for its role once until it answers" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };
    const tenure_a: ReaderTenure = .{ .lane = lane_a, .epoch = 1 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    _ = try pool.release(&worker, 0, 1);
    try testing.expectEqual(ReaderGrant{ .transfer_from = tenure_a }, (try expectAcquired(&pool, lane_b, 0)).reader);
    _ = try pool.release(&worker, 0, 2);
    // The `release_worker` the first grant asked for is still on its way.
    try testing.expectEqual(ReaderGrant.already, (try expectAcquired(&pool, lane_b, 1)).reader);
    try testing.expectEqual(Transfer.kept, pool.transferReader(&worker, tenure_a, .nothing));
    _ = try pool.release(&worker, 0, 3);
    try testing.expectEqual(@as(u64, 1), pool.snapshot().counters.reader_releases_requested);
}

test "a reader that still holds ring payloads frees them before it gives the role up, keeping the role meanwhile" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };
    const tenure_a: ReaderTenure = .{ .lane = lane_a, .epoch = 1 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    // A request in flight can still answer a payload, so the role stays.
    try testing.expectEqual(Transfer.kept, pool.transferReader(&worker, tenure_a, .ring_payloads));
    _ = try pool.release(&worker, 0, 1);
    // Idle, nothing is left to answer what the reader holds: it frees the
    // payloads first, and the role is unchanged until it asks again.
    try testing.expectEqual(Transfer.free_held_payloads, pool.transferReader(&worker, tenure_a, .ring_payloads));
    try testing.expectEqual(@as(?ReaderTenure, tenure_a), pool.inspect(&worker).?.reader);
    // A lane that takes a slot in between finds the reader in place.
    try testing.expectEqual(ReaderGrant{ .transfer_from = tenure_a }, (try expectAcquired(&pool, lane_b, 0)).reader);
    try testing.expectEqual(Transfer.kept, pool.transferReader(&worker, tenure_a, .nothing));
    _ = try pool.release(&worker, 0, 2);
    try testing.expectEqual(Transfer.vacated, pool.transferReader(&worker, tenure_a, .nothing));
    try testing.expect(pool.inspect(&worker).?.reader == null);
}

test "a dead worker's reader gives its role up whatever it holds of the ring" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    _ = pool.markDead(&worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expect((try pool.release(&worker, 0, 1)) == .idle);
    try testing.expectEqual(Transfer.retire, pool.transferReader(&worker, .{ .lane = lane_a, .epoch = 1 }, .ring_payloads));
}

test "a handoff its lane never takes goes back with the tenure it granted, so the slot's next holder reads the worker" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    try expectWait(&pool, lane_a, 0, far_ns);
    try expectWait(&pool, lane_b, 0, far_ns);
    const ticket = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    const handoffs = try pool.publish(ticket, &worker, 0);
    try testing.expectEqual(@as(usize, 1), handoffs.slice().len);
    const refused = handoffs.slice()[0];
    try testing.expectEqual(ReaderGrant{ .you_become_reader = 1 }, refused.reader);

    // Lane a refuses the `dispatch_ready`: the tenure it never took up ends
    // with the slot, and lane b's waiter, next in line, becomes the reader.
    const next = try expectHandoff(try pool.returnHandoff(&worker, refused.slot, lane_a, refused.reader, 1));
    try testing.expect(next.waiter.request_key.eql(requestKey(lane_b, 0)));
    try testing.expectEqual(ReaderGrant{ .you_become_reader = 2 }, next.reader);
    try testing.expectEqual(@as(?ReaderTenure, .{ .lane = lane_b, .epoch = 2 }), pool.inspect(&worker).?.reader);
    try expectSlotsBalanced(&pool);
}

test "a release a grant asked for but its lane never sent is forgotten, so the next grant asks again" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };
    const tenure_a: ReaderTenure = .{ .lane = lane_a, .epoch = 1 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    _ = try pool.release(&worker, 0, 1);
    try testing.expectEqual(ReaderGrant{ .transfer_from = tenure_a }, (try expectAcquired(&pool, lane_b, 0)).reader);
    // Lane b's `release_worker` post was refused.
    pool.releaseRequestLost(&worker, tenure_a);
    _ = try pool.release(&worker, 0, 2);
    try testing.expectEqual(ReaderGrant{ .transfer_from = tenure_a }, (try expectAcquired(&pool, lane_b, 1)).reader);
    pool.releaseRequestLost(&worker, tenure_a);

    // A `dispatch_ready` that carried such a grant and was refused forgets
    // its request the same way.
    try expectWait(&pool, lane_b, 2, far_ns);
    const handoff = try expectHandoff(try pool.release(&worker, 0, 3));
    try testing.expectEqual(ReaderGrant{ .transfer_from = tenure_a }, handoff.reader);
    try testing.expect((try pool.returnHandoff(&worker, handoff.slot, lane_b, handoff.reader, 4)) == .idle);
    try testing.expectEqual(ReaderGrant{ .transfer_from = tenure_a }, (try expectAcquired(&pool, lane_b, 3)).reader);
    try testing.expectEqual(@as(u64, 4), pool.snapshot().counters.reader_releases_requested);
}

test "markDead leaves alone a record that holds another worker than the caller names" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0, .generation = 2 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    const earlier: lifecycle.WorkerKey = .{ .worker_id = worker.key().worker_id, .worker_generation = 1 };
    try testing.expect(pool.markDead(&worker, earlier) == null);
    try testing.expectEqual(pool_mod.EntryState.live, pool.inspect(&worker).?.state);
    _ = pool.markDead(&worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expectEqual(pool_mod.EntryState.dead, pool.inspect(&worker).?.state);
}

test "a death after an idle retirement started leaves the retirement to finish it" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 2));
    defer pool.deinit();
    var read: Worker = .{ .index = 0 };
    var unread: Worker = .{ .index = 1 };

    _ = try publishToNewWaiter(&pool, &read, lane_a, 0);
    try expectWait(&pool, lane_a, 1, far_ns);
    const ticket = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    try testing.expect(pool.cancelWaiter(requestKey(lane_a, 1)));
    _ = try pool.publish(ticket, &unread, 1);
    _ = try pool.release(&read, 0, 2);

    try testing.expect(pool.retireIdle(&unread) == .retire);
    try testing.expect(pool.markDead(&unread, unread.key()) == null);
    try testing.expect(pool.retireIdle(&read) == .release_reader);
    try testing.expect(pool.markDead(&read, read.key()) == null);
    try testing.expectEqual(Transfer.retire, pool.transferReader(&read, .{ .lane = lane_a, .epoch = 1 }, .nothing));
    try testing.expectEqual(@as(u64, 2), pool.snapshot().counters.retirements);
}

test "idle retirement takes a worker out of service and leaves its finish to the reader" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 2));
    defer pool.deinit();
    var read: Worker = .{ .index = 0 };
    var unread: Worker = .{ .index = 1 };

    _ = try publishToNewWaiter(&pool, &read, lane_a, 0);
    try expectWait(&pool, lane_a, 1, far_ns);
    const ticket = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    try testing.expect(pool.cancelWaiter(requestKey(lane_a, 1)));
    _ = try pool.publish(ticket, &unread, 1);
    _ = try pool.release(&read, 0, 2);

    const busy = try expectAcquired(&pool, lane_b, 0);
    try testing.expectEqual(&read, busy.worker);
    try testing.expect(pool.retireIdle(&read) == .not_idle);
    _ = try pool.release(&read, 0, 3);

    try testing.expect(pool.retireIdle(&unread) == .retire);
    const tenure = switch (pool.retireIdle(&read)) {
        .release_reader => |tenure| tenure,
        .not_idle, .retire => return error.TestExpectedReaderRelease,
    };
    try testing.expectEqual(ReaderTenure{ .lane = lane_a, .epoch = 1 }, tenure);
    try testing.expect(pool.retireIdle(&read) == .not_idle);
    // Neither leaving worker is served again.
    try expectWait(&pool, lane_b, 1, far_ns);
    try testing.expectEqual(Transfer.retire, pool.transferReader(&read, tenure, .nothing));
    try pool.remove(&read);
    try pool.remove(&unread);
    try testing.expectError(error.WorkerNotFinished, pool.remove(&read));
}

test "growth is wanted only for uncovered waiters, with room in the table and under the launch cap and the memory gate" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, .{ .concurrency = 1, .workers_max = 3, .launches_max = 2, .waiters_max = 8 });
    defer pool.deinit();
    var workers = [_]Worker{ .{ .index = 0 }, .{ .index = 1 }, .{ .index = 2 } };

    try testing.expect(!pool.growthWanted(true));
    try expectWait(&pool, lane_a, 0, far_ns);
    try testing.expect(pool.growthWanted(true));
    try testing.expect(!pool.growthWanted(false));
    try testing.expect(pool.launchStarted(false) == null);
    const first = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    // The launch in flight covers the one waiter.
    try testing.expect(!pool.growthWanted(true));

    try expectWait(&pool, lane_a, 1, far_ns);
    try testing.expect(pool.growthWanted(true));
    const second = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    try expectWait(&pool, lane_a, 2, far_ns);
    // Three waiters and two launches, but the launch cap is reached.
    try testing.expect(!pool.growthWanted(true));
    try testing.expect(pool.launchStarted(true) == null);

    _ = try pool.publish(first, &workers[0], 1);
    _ = try pool.publish(second, &workers[1], 2);
    try testing.expect(pool.growthWanted(true));
    _ = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    try expectWait(&pool, lane_a, 3, far_ns);
    // Two waiters, one launch, one launch below the cap, but no entry left.
    try testing.expectEqual(@as(u32, 2), pool.snapshot().waiters);
    try testing.expect(!pool.growthWanted(true));
    try testing.expect(pool.launchStarted(true) == null);
}

test "a launch ticket ends once, through publish or launchEnded" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 2));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    try expectWait(&pool, lane_a, 0, far_ns);
    const failed = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    try testing.expectEqual(@as(u32, 1), pool.snapshot().launching);
    try pool.launchEnded(failed);
    try testing.expectEqual(@as(u32, 0), pool.snapshot().launching);
    try testing.expectError(error.TicketNotLaunching, pool.launchEnded(failed));
    try testing.expectError(error.TicketNotLaunching, pool.publish(failed, &worker, 1));

    const published = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    _ = try pool.publish(published, &worker, 1);
    try testing.expectError(error.TicketNotLaunching, pool.publish(published, &worker, 2));
    try testing.expectError(error.TicketNotLaunching, pool.launchEnded(published));
    const counters = pool.snapshot().counters;
    try testing.expectEqual(@as(u64, 2), counters.launches_started);
    try testing.expectEqual(@as(u64, 1), counters.launches_ended);
    try testing.expectEqual(@as(u64, 1), counters.published);
}

test "waiters are stranded only when no worker is live and no launch is in flight" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 2));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };
    var out: [2]pool_mod.Waiter = undefined;

    try expectWait(&pool, lane_a, 0, far_ns);
    try expectWait(&pool, lane_b, 0, far_ns);
    try expectWait(&pool, lane_a, 1, far_ns);
    const ticket = pool.launchStarted(true) orelse return error.TestExpectedLaunch;
    try testing.expectEqual(@as(usize, 0), pool.takeStranded(&out).len);
    try pool.launchEnded(ticket);

    const first = pool.takeStranded(&out);
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expect(first[0].request_key.eql(requestKey(lane_a, 0)));
    try testing.expect(first[1].request_key.eql(requestKey(lane_b, 0)));
    const rest = pool.takeStranded(&out);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expect(rest[0].request_key.eql(requestKey(lane_a, 1)));
    try testing.expectEqual(@as(usize, 0), pool.takeStranded(&out).len);
    try testing.expectEqual(@as(u64, 3), pool.snapshot().counters.waiters_stranded);

    // A live worker will serve whoever waits for it.
    _ = try publishToNewWaiter(&pool, &worker, lane_a, 2);
    try expectWait(&pool, lane_b, 1, far_ns);
    try testing.expectEqual(@as(usize, 0), pool.takeStranded(&out).len);
}

test "release refuses a slot that is not held and changes nothing" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(2, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };
    var stranger: Worker = .{ .index = 9 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    try testing.expectError(error.SlotNotHeld, pool.release(&stranger, 0, 1));
    try testing.expectError(error.SlotNotHeld, pool.release(&worker, 1, 1));
    try testing.expectError(error.SlotNotHeld, pool.release(&worker, 2, 1));
    try testing.expectEqual(@as(u32, 1), pool.snapshot().slots_held);
    try testing.expect((try pool.release(&worker, 0, 1)) == .idle);
    try testing.expectError(error.SlotNotHeld, pool.release(&worker, 0, 2));
    const snapshot = pool.snapshot();
    try testing.expectEqual(@as(u32, 0), snapshot.slots_held);
    try testing.expectEqual(@as(u32, 2), snapshot.slots_free);
    try testing.expectEqual(@as(u64, 1), snapshot.counters.released);
}

test "remove refuses a worker that is live, held or read" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    try testing.expectError(error.WorkerNotFinished, pool.remove(&worker));
    const death = pool.markDead(&worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expectEqualSlices(LaneId, &.{lane_a}, death.slice());
    try testing.expectError(error.WorkerNotFinished, pool.remove(&worker));
    try testing.expect((try pool.release(&worker, 0, 1)) == .idle);
    try testing.expectError(error.WorkerNotFinished, pool.remove(&worker));
    try testing.expectEqual(Transfer.retire, pool.transferReader(&worker, .{ .lane = lane_a, .epoch = 1 }, .nothing));
    try pool.remove(&worker);
    try testing.expectEqual(@as(u64, 1), pool.snapshot().counters.removed);
}

test "retireForEgress takes a live worker out of service as markDead does, once, and records the egress departure" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(2, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0, .generation = 2 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    const second = try expectAcquired(&pool, lane_b, 0);
    const earlier: lifecycle.WorkerKey = .{ .worker_id = worker.key().worker_id, .worker_generation = 1 };
    try testing.expect(pool.retireForEgress(&worker, earlier) == null);
    try testing.expectEqual(pool_mod.EntryState.live, pool.inspect(&worker).?.state);

    const death = pool.retireForEgress(&worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expectEqualSlices(LaneId, &.{ lane_a, lane_b }, death.slice());
    try testing.expect(!death.retire);
    const view = pool.inspect(&worker).?;
    try testing.expectEqual(pool_mod.EntryState.dead, view.state);
    try testing.expectEqual(@as(?pool_mod.Departure, .egress), view.departure);
    try testing.expect(pool.retireForEgress(&worker, worker.key()) == null);
    try testing.expect(pool.markDead(&worker, worker.key()) == null);
    var snapshot = pool.snapshot();
    try testing.expectEqual(@as(u64, 1), snapshot.counters.egress_retirements);
    try testing.expectEqual(@as(u64, 0), snapshot.counters.deaths);

    // The lanes finish it as they finish a dead worker.
    try testing.expect((try pool.release(&worker, second.slot, 10)) == .idle);
    try testing.expectEqual(Transfer.vacated, pool.transferReader(&worker, .{ .lane = lane_a, .epoch = 1 }, .nothing));
    try testing.expect((try pool.release(&worker, 0, 11)) == .retire);
    snapshot = pool.snapshot();
    try testing.expectEqual(@as(u64, 1), snapshot.counters.retirements);
    try pool.remove(&worker);
}

test "retireForEgress of a worker no lane holds or reads asks for its retirement at once" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };

    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);
    try testing.expect((try pool.release(&worker, 0, 1)) == .idle);
    try testing.expectEqual(Transfer.vacated, pool.transferReader(&worker, .{ .lane = lane_a, .epoch = 1 }, .nothing));

    const death = pool.retireForEgress(&worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expectEqual(@as(usize, 0), death.slice().len);
    try testing.expect(death.retire);
    try testing.expectEqual(@as(u64, 1), pool.snapshot().counters.retirements);
    try pool.remove(&worker);
}

test "findLive visits live workers only, in table order, and stops at the first one picked" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 3));
    defer pool.deinit();
    var workers = [_]Worker{ .{ .index = 0 }, .{ .index = 1 }, .{ .index = 2 } };
    for (&workers, 0..) |*worker, index|
        _ = try publishToNewWaiter(&pool, worker, lane_a, @intCast(index));
    _ = pool.markDead(&workers[0], workers[0].key()) orelse return error.TestExpectedDeath;

    var picks_second: WorkerPicker = .{ .pick = 1 };
    try testing.expectEqual(@as(?*Worker, &workers[1]), pool.findLive(&picks_second));
    try testing.expectEqualSlices(u8, &.{1}, picks_second.visited());

    var picks_none: WorkerPicker = .{ .pick = null };
    try testing.expectEqual(@as(?*Worker, null), pool.findLive(&picks_none));
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, picks_none.visited());
}

test "visitWorker runs its visitor with the entry's state and runs nothing for a worker the table does not hold" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 1));
    defer pool.deinit();
    var worker: Worker = .{ .index = 0 };
    var stranger: Worker = .{ .index = 9 };
    _ = try publishToNewWaiter(&pool, &worker, lane_a, 0);

    var states: StateRecorder = .{};
    try testing.expect(!pool.visitWorker(&stranger, &states));
    try testing.expectEqual(@as(u32, 0), states.visits);
    try testing.expect(pool.visitWorker(&worker, &states));
    try testing.expectEqual(@as(?pool_mod.EntryState, .live), states.last);

    _ = pool.markDead(&worker, worker.key()) orelse return error.TestExpectedDeath;
    try testing.expect(pool.visitWorker(&worker, &states));
    try testing.expectEqual(@as(?pool_mod.EntryState, .dead), states.last);

    try testing.expect((try pool.release(&worker, 0, 1)) == .idle);
    try testing.expectEqual(Transfer.retire, pool.transferReader(&worker, .{ .lane = lane_a, .epoch = 1 }, .nothing));
    try pool.remove(&worker);
    try testing.expect(!pool.visitWorker(&worker, &states));
    try testing.expectEqual(@as(u32, 2), states.visits);
}

/// A `findLive` visitor that notes each worker it sees and picks the one
/// whose index is `pick`, or none.
const WorkerPicker = struct {
    pick: ?u8,
    seen: [4]u8 = undefined,
    seen_len: usize = 0,

    pub fn visit(self: *WorkerPicker, worker: *Worker) bool {
        self.seen[self.seen_len] = worker.index;
        self.seen_len += 1;
        const pick = self.pick orelse return false;
        return pick == worker.index;
    }

    fn visited(self: *const WorkerPicker) []const u8 {
        return self.seen[0..self.seen_len];
    }
};

/// A `visitWorker` visitor that counts its visits and keeps the last state.
const StateRecorder = struct {
    visits: u32 = 0,
    last: ?pool_mod.EntryState = null,

    pub fn visit(self: *StateRecorder, worker: *Worker, state: pool_mod.EntryState) void {
        _ = worker;
        self.visits += 1;
        self.last = state;
    }
};

test "idleWorkers lists idle live workers longest idle first and keeps the longest idle when out is short" {
    var pool: TestPool = undefined;
    try pool.init(testing.allocator, shape(1, 3));
    defer pool.deinit();
    var workers = [_]Worker{ .{ .index = 0 }, .{ .index = 1 }, .{ .index = 2 } };

    for (&workers, 0..) |*worker, index|
        _ = try publishToNewWaiter(&pool, worker, lane_a, @intCast(index));
    _ = try pool.release(&workers[0], 0, 10);
    _ = try pool.release(&workers[1], 0, 20);
    _ = try pool.release(&workers[2], 0, 30);

    var out3: [3]TestPool.IdleWorker = undefined;
    const all = pool.idleWorkers(&out3);
    try testing.expectEqual(@as(usize, 3), all.len);
    for (all, 0..) |idle, index|
        try testing.expectEqual(&workers[index], idle.worker);
    var out2: [2]TestPool.IdleWorker = undefined;
    const longest = pool.idleWorkers(&out2);
    try testing.expectEqual(&workers[0], longest[0].worker);
    try testing.expectEqual(&workers[1], longest[1].worker);

    // The most recently used worker takes the next request and leaves the list.
    try testing.expectEqual(&workers[2], (try expectAcquired(&pool, lane_b, 0)).worker);
    try testing.expectEqual(@as(usize, 2), pool.idleWorkers(&out3).len);
}

// The model of two lanes, the launcher and the reaper around one pool.

const model_lanes = 2;
const model_workers = 2;
const model_requests = 6;
const queue_capacity = 16;
const fifo_capacity = 16;

const Command = union(enum) {
    dispatch_ready: struct { request: u8, worker: u8, slot: Slot, reader: ReaderGrant },
    release_worker: struct { worker: u8, tenure: ReaderTenure },
    worker_died: struct { worker: u8 },
};

const Posted = struct { to: LaneId, command: Command };

const RequestState = enum { unused, waiting, holding, answered };

const Request = struct {
    state: RequestState = .unused,
    worker: u8 = 0,
    slot: Slot = 0,
    cancelled: bool = false,
};

const Lane = struct {
    id: LaneId,
    /// Commands posted to the lane, which it runs in order at `drain`.
    inbox: [queue_capacity]Command = undefined,
    inbox_len: usize = 0,
    /// What the lane's last pool calls asked it to post, posted when its next
    /// step starts.
    outbox: [queue_capacity]Posted = undefined,
    outbox_len: usize = 0,
    requests: [model_requests]Request = @splat(Request{}),
    reading: [model_workers]?ReaderEpoch = @splat(null),
    known_dead: [model_workers]bool = @splat(false),

    fn post(lane: *Lane, to: LaneId, command: Command) !void {
        if (lane.outbox_len == lane.outbox.len) return error.ModelQueueFull;
        lane.outbox[lane.outbox_len] = .{ .to = to, .command = command };
        lane.outbox_len += 1;
    }

    fn receive(lane: *Lane, command: Command) !void {
        if (lane.inbox_len == lane.inbox.len) return error.ModelQueueFull;
        lane.inbox[lane.inbox_len] = command;
        lane.inbox_len += 1;
    }

    fn takeFirst(lane: *Lane) ?Command {
        if (lane.inbox_len == 0) return null;
        const first = lane.inbox[0];
        std.mem.copyForwards(Command, lane.inbox[0 .. lane.inbox_len - 1], lane.inbox[1..lane.inbox_len]);
        lane.inbox_len -= 1;
        return first;
    }
};

const ModelWaiter = struct { lane: LaneId, request: u8, deadline_ns: u64 };

const Op = union(enum) {
    /// The lane admits a request with this deadline.
    acquire: struct { request: u8, deadline_ns: u64 = far_ns },
    /// The lane's dispatched request ends and gives its slot back.
    finish: u8,
    /// The deadline of the lane's waiting request fires.
    expire: u8,
    /// The lane runs every command in its queue.
    drain,
    /// The launcher claims a launch, which takes the next empty entry.
    launch,
    /// The launcher publishes the worker of the entry it claimed.
    publish: u8,
    /// The lane observes the worker's death.
    mark_dead: u8,
    /// The reaper starts the idle worker's retirement.
    retire_idle: u8,
    /// The clock moves forward to this time.
    advance: u64,
};

const Step = struct { lane: u1, op: Op };

const Scenario = struct {
    options: pool_mod.Options,
    setup: []const Step,
    a: []const Op,
    b: []const Op,
};

const World = struct {
    pool: TestPool,
    concurrency: u8,
    /// Entry `i` of the table holds `workers[i]`, since launches take the
    /// entries in order and no scenario removes a worker before the end.
    workers: [model_workers]Worker,
    tickets: [model_workers]?pool_mod.LaunchTicket,
    published: [model_workers]bool,
    dead: [model_workers]bool,
    retiring: [model_workers]bool,
    removed: [model_workers]bool,
    retirements: [model_workers]u8,
    reader: [model_workers]?ReaderTenure,
    epoch: [model_workers]ReaderEpoch,
    lanes: [model_lanes]Lane,
    fifo: [fifo_capacity]ModelWaiter,
    fifo_len: usize,
    expired: u64,
    now_ns: u64,

    fn init(world: *World, options: pool_mod.Options) !void {
        world.* = .{
            .pool = undefined,
            .concurrency = options.concurrency,
            .workers = .{ .{ .index = 0 }, .{ .index = 1 } },
            .tickets = @splat(null),
            .published = @splat(false),
            .dead = @splat(false),
            .retiring = @splat(false),
            .removed = @splat(false),
            .retirements = @splat(0),
            .reader = @splat(null),
            .epoch = @splat(0),
            .lanes = .{ .{ .id = lane_a }, .{ .id = lane_b } },
            .fifo = undefined,
            .fifo_len = 0,
            .expired = 0,
            .now_ns = 0,
        };
        try world.pool.init(testing.allocator, options);
    }

    fn deinit(world: *World) void {
        world.pool.deinit();
    }

    fn run(world: *World, lane_index: u1, op: Op) !void {
        try world.flush(&world.lanes[lane_index]);
        const lane = &world.lanes[lane_index];
        switch (op) {
            .acquire => |admission| try world.admit(lane, admission.request, admission.deadline_ns),
            .finish => |request| try world.finish(lane, request),
            .expire => |request| try world.expire(lane, request),
            .drain => try world.drain(lane),
            .launch => try world.launch(),
            .publish => |worker| try world.publish(lane, worker),
            .mark_dead => |worker| try world.markDead(lane, worker),
            .retire_idle => |worker| try world.retireIdle(lane, worker),
            .advance => |now_ns| world.now_ns = @max(world.now_ns, now_ns),
        }
        try world.check();
    }

    fn flush(world: *World, lane: *Lane) !void {
        for (lane.outbox[0..lane.outbox_len]) |posted|
            try world.lanes[posted.to].receive(posted.command);
        lane.outbox_len = 0;
    }

    fn admit(world: *World, lane: *Lane, number: u8, deadline_ns: u64) !void {
        const request = &lane.requests[number];
        try testing.expectEqual(RequestState.unused, request.state);
        switch (world.pool.acquire(lane.id, requestKey(lane.id, number), deadline_ns)) {
            .acquired => |acquired| {
                // A request takes a free slot only when nobody waits ahead.
                try testing.expectEqual(@as(usize, 0), world.fifo_len);
                const worker = acquired.worker.index;
                try testing.expect(world.inService(worker));
                try world.expectGrant(worker, lane.id, acquired.reader, world.heldCount(worker) == 0);
                request.* = .{ .state = .holding, .worker = worker, .slot = acquired.slot };
                try world.discharge(lane, worker, acquired.reader);
            },
            .wait => {
                // Waiting means no worker in service has a free slot.
                for (0..model_workers) |index| {
                    const worker: u8 = @intCast(index);
                    if (world.inService(worker))
                        try testing.expectEqual(@as(usize, world.concurrency), world.heldCount(worker));
                }
                request.state = .waiting;
                if (world.fifo_len == world.fifo.len) return error.ModelQueueFull;
                world.fifo[world.fifo_len] = .{ .lane = lane.id, .request = number, .deadline_ns = deadline_ns };
                world.fifo_len += 1;
            },
            .full => request.state = .answered,
        }
    }

    fn finish(world: *World, lane: *Lane, number: u8) !void {
        const request = &lane.requests[number];
        if (request.state != .holding) return;
        request.state = .answered;
        try world.giveBack(lane, request.worker, request.slot);
    }

    fn expire(world: *World, lane: *Lane, number: u8) !void {
        const request = &lane.requests[number];
        if (request.state != .waiting) return;
        const queued = world.fifoIndex(lane.id, number);
        const cancelled = world.pool.cancelWaiter(requestKey(lane.id, number));
        // The pool holds exactly the waiters the model holds.
        try testing.expectEqual(queued != null, cancelled);
        if (queued) |index| world.fifoRemove(index);
        request.cancelled = cancelled;
        request.state = .answered;
    }

    fn drain(world: *World, lane: *Lane) !void {
        while (lane.takeFirst()) |command| {
            switch (command) {
                .dispatch_ready => |ready| {
                    try world.dischargeArrived(lane, ready.worker, ready.reader);
                    const request = &lane.requests[ready.request];
                    if (request.state == .waiting and !lane.known_dead[ready.worker]) {
                        request.* = .{ .state = .holding, .worker = ready.worker, .slot = ready.slot };
                        continue;
                    }
                    // The request ended while the slot travelled, or the
                    // worker's death reached the lane first: the slot goes
                    // back, and so does a reader role on a dead worker.
                    if (request.state == .waiting) request.state = .answered;
                    try world.giveBack(lane, ready.worker, ready.slot);
                    if (lane.known_dead[ready.worker]) try world.giveUpReading(lane, ready.worker);
                },
                .release_worker => |release| {
                    const expected = world.expectedTransfer(release.worker, release.tenure);
                    const result = world.pool.transferReader(&world.workers[release.worker], release.tenure, .nothing);
                    try testing.expectEqual(expected, result);
                    try world.applyTransfer(lane, release.worker, result);
                },
                .worker_died => |died| try world.onWorkerDied(lane, died.worker),
            }
        }
    }

    fn launch(world: *World) !void {
        const ticket = world.pool.launchStarted(true) orelse return;
        try testing.expect(ticket.entry < model_workers);
        try testing.expect(world.tickets[ticket.entry] == null);
        world.tickets[ticket.entry] = ticket;
    }

    fn publish(world: *World, lane: *Lane, worker: u8) !void {
        const ticket = world.tickets[worker] orelse return;
        world.tickets[worker] = null;
        const handoffs = try world.pool.publish(ticket, &world.workers[worker], world.now_ns);
        world.published[worker] = true;
        for (handoffs.slice()) |handoff|
            try world.onHandoff(lane, handoff);
        // Fewer handoffs than slots means the pool emptied the FIFO.
        if (handoffs.len < world.concurrency) try world.expectNoLiveWaiter();
    }

    fn markDead(world: *World, lane: *Lane, worker: u8) !void {
        const death = world.pool.markDead(&world.workers[worker], world.workers[worker].key()) orelse {
            try testing.expect(!world.inService(worker));
            return;
        };
        try testing.expect(world.inService(worker));
        const concerned = world.concernedLanes(worker);
        world.dead[worker] = true;
        // The death names every lane that holds a slot of the worker or
        // reads it, each once.
        var named: u8 = 0;
        for (death.slice()) |named_lane| {
            const bit = @as(u8, 1) << @intCast(named_lane);
            try testing.expectEqual(@as(u8, 0), named & bit);
            named |= bit;
        }
        try testing.expectEqual(concerned, named);
        try testing.expectEqual(concerned == 0, death.retire);
        if (death.retire) try world.onRetire(worker);
        for (death.slice()) |named_lane| {
            if (named_lane == lane.id) {
                try world.onWorkerDied(lane, worker);
            } else {
                try lane.post(named_lane, .{ .worker_died = .{ .worker = worker } });
            }
        }
    }

    fn retireIdle(world: *World, lane: *Lane, worker: u8) !void {
        switch (world.pool.retireIdle(&world.workers[worker])) {
            .not_idle => try testing.expect(!world.inService(worker) or world.heldCount(worker) != 0),
            .retire => {
                try testing.expect(world.inService(worker));
                try testing.expectEqual(@as(usize, 0), world.heldCount(worker));
                try testing.expect(world.reader[worker] == null);
                world.retiring[worker] = true;
                try world.onRetire(worker);
            },
            .release_reader => |tenure| {
                try testing.expect(world.inService(worker));
                try testing.expectEqual(@as(usize, 0), world.heldCount(worker));
                try testing.expectEqual(world.reader[worker], tenure);
                world.retiring[worker] = true;
                try lane.post(tenure.lane, .{ .release_worker = .{ .worker = worker, .tenure = tenure } });
            },
        }
    }

    fn giveBack(world: *World, lane: *Lane, worker: u8, slot: Slot) !void {
        const was_in_service = world.inService(worker);
        switch (try world.pool.release(&world.workers[worker], slot, world.now_ns)) {
            .idle => if (was_in_service) try world.expectNoLiveWaiter(),
            .handed_to => |handoff| {
                try testing.expect(was_in_service);
                try world.onHandoff(lane, handoff);
            },
            .retire => {
                try testing.expect(!was_in_service);
                try world.onRetire(worker);
            },
        }
    }

    fn onHandoff(world: *World, poster: *Lane, handoff: TestPool.Handoff) !void {
        const worker = handoff.worker.index;
        try testing.expect(world.inService(worker));
        // The pool drops waiters whose deadline passed on its way to the
        // head, and so does the model.
        while (world.fifo_len != 0 and world.fifo[0].deadline_ns <= world.now_ns) {
            world.fifoRemove(0);
            world.expired += 1;
        }
        try testing.expect(world.fifo_len != 0);
        const head = world.fifo[0];
        try testing.expectEqual(head.lane, handoff.waiter.lane);
        try testing.expect(requestKey(head.lane, head.request).eql(handoff.waiter.request_key));
        try testing.expectEqual(head.deadline_ns, handoff.waiter.deadline_ns);
        world.fifoRemove(0);
        const request = &world.lanes[head.lane].requests[head.request];
        try testing.expectEqual(RequestState.waiting, request.state);
        try testing.expect(!request.cancelled);
        try world.expectGrant(worker, head.lane, handoff.reader, world.heldCount(worker) == 0);
        try poster.post(head.lane, .{ .dispatch_ready = .{
            .request = head.request,
            .worker = worker,
            .slot = handoff.slot,
            .reader = handoff.reader,
        } });
    }

    fn onWorkerDied(world: *World, lane: *Lane, worker: u8) !void {
        lane.known_dead[worker] = true;
        for (&lane.requests) |*request| {
            if (request.state != .holding or request.worker != worker) continue;
            request.state = .answered;
            try world.giveBack(lane, worker, request.slot);
        }
        try world.giveUpReading(lane, worker);
    }

    fn giveUpReading(world: *World, lane: *Lane, worker: u8) !void {
        const epoch = lane.reading[worker] orelse return;
        const tenure: ReaderTenure = .{ .lane = lane.id, .epoch = epoch };
        const expected = world.expectedTransfer(worker, tenure);
        try testing.expect(expected == .vacated or expected == .retire);
        const result = world.pool.transferReader(&world.workers[worker], tenure, .nothing);
        try testing.expectEqual(expected, result);
        try world.applyTransfer(lane, worker, result);
    }

    fn onRetire(world: *World, worker: u8) !void {
        try testing.expect(world.dead[worker] or world.retiring[worker]);
        try testing.expectEqual(@as(usize, 0), world.heldCount(worker));
        try testing.expect(world.reader[worker] == null);
        world.retirements[worker] += 1;
        try testing.expectEqual(@as(u8, 1), world.retirements[worker]);
    }

    /// Checks a grant against the model's reader and adopts what it assigns.
    fn expectGrant(world: *World, worker: u8, lane: LaneId, grant: ReaderGrant, was_idle: bool) !void {
        switch (grant) {
            .you_become_reader => |epoch| {
                // Only a worker without a reader gets one, under the next
                // epoch of its entry.
                try testing.expect(world.reader[worker] == null);
                try testing.expectEqual(nextEpoch(world.epoch[worker]), epoch);
                world.epoch[worker] = epoch;
                world.reader[worker] = .{ .lane = lane, .epoch = epoch };
            },
            .already => try testing.expect(world.reader[worker] != null),
            .transfer_from => |tenure| {
                try testing.expectEqual(world.reader[worker], tenure);
                try testing.expect(tenure.lane != lane);
                try testing.expect(was_idle);
            },
        }
    }

    /// The lane's side of a grant it took inline.
    fn discharge(world: *World, lane: *Lane, worker: u8, grant: ReaderGrant) !void {
        _ = world;
        switch (grant) {
            .already => {},
            .you_become_reader => |epoch| {
                try testing.expect(lane.reading[worker] == null);
                lane.reading[worker] = epoch;
            },
            .transfer_from => |tenure| try lane.post(tenure.lane, .{ .release_worker = .{ .worker = worker, .tenure = tenure } }),
        }
    }

    /// The lane's side of a grant that came with `dispatch_ready`. Nothing
    /// can change the reader while the slot travels, since a release needs an
    /// idle worker and the travelling slot keeps it busy.
    fn dischargeArrived(world: *World, lane: *Lane, worker: u8, grant: ReaderGrant) !void {
        if (grant == .you_become_reader)
            try testing.expectEqual(world.reader[worker], ReaderTenure{ .lane = lane.id, .epoch = grant.you_become_reader });
        try world.discharge(lane, worker, grant);
    }

    fn expectedTransfer(world: *World, worker: u8, tenure: ReaderTenure) Transfer {
        const reader = world.reader[worker] orelse return .stale;
        if (reader.lane != tenure.lane) return .stale;
        if (reader.epoch != tenure.epoch) return .stale;
        const held = world.heldCount(worker);
        if (world.inService(worker)) return if (held != 0) .kept else .vacated;
        return if (held == 0) .retire else .vacated;
    }

    fn applyTransfer(world: *World, lane: *Lane, worker: u8, result: Transfer) !void {
        switch (result) {
            .stale, .kept => {},
            // The model's readers hold no ring payload.
            .free_held_payloads => return error.ModelReaderHoldsNoPayload,
            .vacated, .retire => {
                try testing.expect(lane.reading[worker] != null);
                lane.reading[worker] = null;
                world.reader[worker] = null;
                if (result == .retire) try world.onRetire(worker);
            },
        }
    }

    /// An `.idle` release on a worker in service, or a publish that served
    /// fewer waiters than slots, means every waiter left had expired.
    fn expectNoLiveWaiter(world: *World) !void {
        for (world.fifo[0..world.fifo_len]) |waiter|
            try testing.expect(waiter.deadline_ns <= world.now_ns);
        world.expired += world.fifo_len;
        world.fifo_len = 0;
    }

    fn inService(world: *const World, worker: u8) bool {
        return world.published[worker] and !world.dead[worker] and !world.retiring[worker] and !world.removed[worker];
    }

    /// The model's owners of the worker's slots, counted per slot: requests
    /// holding one and `dispatch_ready` commands carrying one, posted or not.
    fn owners(world: *const World, worker: u8) [pool_mod.slots_per_worker_max]usize {
        var counts: [pool_mod.slots_per_worker_max]usize = @splat(0);
        for (&world.lanes) |*lane| {
            for (lane.requests) |request| {
                if (request.state == .holding and request.worker == worker) counts[request.slot] += 1;
            }
            for (lane.inbox[0..lane.inbox_len]) |command| {
                if (readyFor(command, worker)) |slot| counts[slot] += 1;
            }
            for (lane.outbox[0..lane.outbox_len]) |posted| {
                if (readyFor(posted.command, worker)) |slot| counts[slot] += 1;
            }
        }
        return counts;
    }

    fn heldCount(world: *const World, worker: u8) usize {
        var total: usize = 0;
        for (world.owners(worker)) |count| total += count;
        return total;
    }

    /// The lanes a death of the worker concerns, as a bit per lane: holders,
    /// including those a slot is travelling to, and the reader.
    fn concernedLanes(world: *const World, worker: u8) u8 {
        var lanes: u8 = 0;
        for (&world.lanes) |*lane| {
            for (lane.requests) |request| {
                if (request.state == .holding and request.worker == worker)
                    lanes |= @as(u8, 1) << @intCast(lane.id);
            }
            for (lane.inbox[0..lane.inbox_len]) |command| {
                if (readyFor(command, worker) != null) lanes |= @as(u8, 1) << @intCast(lane.id);
            }
            for (lane.outbox[0..lane.outbox_len]) |posted| {
                if (readyFor(posted.command, worker) != null) lanes |= @as(u8, 1) << @intCast(posted.to);
            }
        }
        if (world.reader[worker]) |reader| lanes |= @as(u8, 1) << @intCast(reader.lane);
        return lanes;
    }

    fn check(world: *World) !void {
        const snapshot = world.pool.snapshot();
        try testing.expectEqual(snapshot.slot_capacity, snapshot.slots_held + snapshot.slots_free);
        try testing.expectEqual(world.fifo_len, snapshot.waiters);
        try testing.expectEqual(world.expired, snapshot.counters.waiters_expired);
        for (0..model_workers) |index| {
            const worker: u8 = @intCast(index);
            // No slot is lost or doubled: each slot the pool holds has
            // exactly one owner in the model.
            var total: usize = 0;
            for (world.owners(worker)) |count| {
                try testing.expect(count <= 1);
                total += count;
            }
            if (world.pool.inspect(&world.workers[worker])) |view| {
                try testing.expectEqual(total, view.slots_held);
                try testing.expectEqual(world.reader[worker], view.reader);
                const state: pool_mod.EntryState = if (world.dead[worker])
                    .dead
                else if (world.retiring[worker])
                    .retiring
                else
                    .live;
                try testing.expectEqual(state, view.state);
            } else {
                try testing.expectEqual(@as(usize, 0), total);
                try testing.expect(!world.published[worker] or world.removed[worker]);
                try testing.expect(world.reader[worker] == null);
            }
            // One lane at most reads the worker, and only as its reader.
            var reading: usize = 0;
            for (&world.lanes) |*lane| {
                const epoch = lane.reading[worker] orelse continue;
                reading += 1;
                try testing.expectEqual(world.reader[worker], ReaderTenure{ .lane = lane.id, .epoch = epoch });
            }
            try testing.expect(reading <= 1);
            try testing.expect(world.retirements[worker] <= 1);
        }
    }

    /// Runs every lane until nothing moves, ends the requests left waiting,
    /// and checks that every slot came back and that every worker out of
    /// service retired once and can be removed.
    fn quiesce(world: *World) !void {
        var round: usize = 0;
        while (round < 64) : (round += 1) {
            var progressed = false;
            for (&world.lanes) |*lane| {
                if (lane.outbox_len == 0) continue;
                try world.flush(lane);
                progressed = true;
            }
            for (&world.lanes) |*lane| {
                if (lane.inbox_len == 0) continue;
                try world.drain(lane);
                progressed = true;
            }
            for (&world.lanes) |*lane| {
                for (lane.requests, 0..) |request, number| {
                    if (request.state != .holding) continue;
                    try world.finish(lane, @intCast(number));
                    progressed = true;
                }
            }
            if (!progressed) {
                for (&world.lanes) |*lane| {
                    for (lane.requests, 0..) |request, number| {
                        if (request.state != .waiting) continue;
                        try world.expire(lane, @intCast(number));
                        progressed = true;
                    }
                }
            }
            try world.check();
            if (!progressed) break;
        } else return error.ModelDidNotSettle;

        const snapshot = world.pool.snapshot();
        try testing.expectEqual(@as(u32, 0), snapshot.slots_held);
        try testing.expectEqual(@as(u32, 0), snapshot.slots_held_dead);
        try testing.expectEqual(@as(u32, 0), snapshot.waiters);
        for (0..model_workers) |index| {
            const worker: u8 = @intCast(index);
            if (!world.published[worker]) continue;
            if (world.inService(worker)) {
                try testing.expectError(error.WorkerNotFinished, world.pool.remove(&world.workers[worker]));
                continue;
            }
            try testing.expectEqual(@as(u8, 1), world.retirements[worker]);
            try world.pool.remove(&world.workers[worker]);
            world.removed[worker] = true;
        }
        try world.check();
    }

    fn fifoIndex(world: *const World, lane: LaneId, number: u8) ?usize {
        for (world.fifo[0..world.fifo_len], 0..) |waiter, index| {
            if (waiter.lane == lane and waiter.request == number) return index;
        }
        return null;
    }

    fn fifoRemove(world: *World, index: usize) void {
        std.mem.copyForwards(ModelWaiter, world.fifo[index .. world.fifo_len - 1], world.fifo[index + 1 .. world.fifo_len]);
        world.fifo_len -= 1;
    }
};

fn readyFor(command: Command, worker: u8) ?Slot {
    return switch (command) {
        .dispatch_ready => |ready| if (ready.worker == worker) ready.slot else null,
        .release_worker, .worker_died => null,
    };
}

fn nextEpoch(epoch: ReaderEpoch) ReaderEpoch {
    const next = epoch +% 1;
    return if (next == 0) 1 else next;
}

/// Runs `scenario` once per interleaving of its two scripts and returns how
/// many ran.
fn runEveryInterleaving(scenario: Scenario) !usize {
    const total = scenario.a.len + scenario.b.len;
    std.debug.assert(total <= 16);
    var runs: usize = 0;
    var order: u32 = 0;
    while (order < (@as(u32, 1) << @intCast(total))) : (order += 1) {
        if (@popCount(order) != scenario.a.len) continue;
        runInterleaving(scenario, order) catch |err| {
            std.debug.print("pool interleaving failed: order {b} ({d} steps of lane a)\n", .{ order, scenario.a.len });
            return err;
        };
        runs += 1;
    }
    return runs;
}

/// Bit `i` of `order` set means step `i` belongs to lane a.
fn runInterleaving(scenario: Scenario, order: u32) !void {
    var world: World = undefined;
    try world.init(scenario.options);
    defer world.deinit();
    for (scenario.setup) |step| try world.run(step.lane, step.op);
    var next_a: usize = 0;
    var next_b: usize = 0;
    var position: u5 = 0;
    while (position < scenario.a.len + scenario.b.len) : (position += 1) {
        if ((order >> position) & 1 == 1) {
            try world.run(0, scenario.a[next_a]);
            next_a += 1;
        } else {
            try world.run(1, scenario.b[next_b]);
            next_b += 1;
        }
    }
    try world.quiesce();
}

fn expectEveryInterleaving(scenario: Scenario) !void {
    const runs = try runEveryInterleaving(scenario);
    const expected = binomial(scenario.a.len + scenario.b.len, scenario.a.len);
    try testing.expectEqual(expected, runs);
}

fn binomial(n: usize, k: usize) usize {
    var result: usize = 1;
    var index: usize = 0;
    while (index < k) : (index += 1)
        result = result * (n - index) / (index + 1);
    return result;
}

/// Lane a's request 0 is served by a fresh worker 0, which makes lane a its
/// reader, and then ends, leaving the worker idle.
const idle_worker_read_by_a = [_]Step{
    .{ .lane = 0, .op = .{ .acquire = .{ .request = 0 } } },
    .{ .lane = 0, .op = .launch },
    .{ .lane = 0, .op = .{ .publish = 0 } },
    .{ .lane = 0, .op = .drain },
    .{ .lane = 0, .op = .{ .finish = 0 } },
};

/// As `idle_worker_read_by_a`, with request 0 still running.
const busy_worker_read_by_a = [_]Step{
    .{ .lane = 0, .op = .{ .acquire = .{ .request = 0 } } },
    .{ .lane = 0, .op = .launch },
    .{ .lane = 0, .op = .{ .publish = 0 } },
    .{ .lane = 0, .op = .drain },
};

test "two lanes racing for one idle worker never share or lose its slot" {
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &idle_worker_read_by_a,
        .a = &.{ .{ .acquire = .{ .request = 1 } }, .{ .finish = 1 }, .drain },
        .b = &.{ .{ .acquire = .{ .request = 0 } }, .drain, .{ .finish = 0 }, .drain },
    });
}

test "a freed slot racing a waiter's deadline that has not passed reaches the waiter or the next one" {
    const setup = busy_worker_read_by_a ++ [_]Step{
        .{ .lane = 1, .op = .{ .acquire = .{ .request = 0, .deadline_ns = 100 } } },
        .{ .lane = 1, .op = .{ .acquire = .{ .request = 1 } } },
    };
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &setup,
        .a = &.{ .{ .advance = 50 }, .{ .finish = 0 }, .drain },
        .b = &.{ .{ .expire = 0 }, .drain, .{ .finish = 1 }, .drain },
    });
}

test "a freed slot skips a waiter whose deadline passed, whether or not its lane cancelled it yet" {
    const setup = busy_worker_read_by_a ++ [_]Step{
        .{ .lane = 1, .op = .{ .acquire = .{ .request = 0, .deadline_ns = 100 } } },
        .{ .lane = 1, .op = .{ .acquire = .{ .request = 1 } } },
    };
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &setup,
        .a = &.{ .{ .advance = 150 }, .{ .finish = 0 }, .drain },
        .b = &.{ .{ .expire = 0 }, .drain, .{ .finish = 1 }, .drain },
    });
}

test "a publish racing a release serves the waiter once and leaves the other worker free" {
    const setup = busy_worker_read_by_a ++ [_]Step{
        .{ .lane = 1, .op = .{ .acquire = .{ .request = 0 } } },
        .{ .lane = 1, .op = .launch },
    };
    try expectEveryInterleaving(.{
        .options = shape(1, 2),
        .setup = &setup,
        .a = &.{ .{ .finish = 0 }, .drain },
        .b = &.{ .{ .publish = 1 }, .drain, .{ .finish = 0 }, .drain },
    });
}

test "a waiter's cancel racing the publish meant for it never serves the cancelled request" {
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &.{
            .{ .lane = 0, .op = .{ .acquire = .{ .request = 0 } } },
            .{ .lane = 1, .op = .{ .acquire = .{ .request = 0 } } },
            .{ .lane = 0, .op = .launch },
        },
        .a = &.{ .{ .expire = 0 }, .drain },
        .b = &.{ .{ .publish = 0 }, .drain, .{ .finish = 0 } },
    });
}

test "a death racing another lane's acquire and release reaches every holder and retires the worker once" {
    try expectEveryInterleaving(.{
        .options = shape(2, 1),
        .setup = &busy_worker_read_by_a,
        .a = &.{ .{ .mark_dead = 0 }, .drain },
        .b = &.{ .{ .acquire = .{ .request = 0 } }, .drain, .{ .finish = 0 }, .drain },
    });
}

test "the reader's own traffic racing another lane's transfer keeps one reader and moves its epoch only on a change" {
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &idle_worker_read_by_a,
        .a = &.{ .drain, .{ .acquire = .{ .request = 1 } }, .drain, .{ .finish = 1 }, .drain },
        .b = &.{ .{ .acquire = .{ .request = 0 } }, .drain, .{ .finish = 0 }, .drain },
    });
}

test "an idle retirement racing the reader's acquire never serves the leaving worker" {
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &idle_worker_read_by_a,
        .a = &.{ .{ .acquire = .{ .request = 1 } }, .drain, .{ .finish = 1 }, .drain },
        .b = &.{ .{ .retire_idle = 0 }, .drain, .{ .acquire = .{ .request = 0 } }, .drain },
    });
}

test "a death racing the idle retirement of a worker with a reader retires it once" {
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &idle_worker_read_by_a,
        .a = &.{ .drain, .{ .mark_dead = 0 }, .drain },
        .b = &.{ .{ .retire_idle = 0 }, .drain },
    });
}

test "a death racing the idle retirement of a worker nobody reads retires it once" {
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &.{
            .{ .lane = 0, .op = .{ .acquire = .{ .request = 0 } } },
            .{ .lane = 0, .op = .launch },
            .{ .lane = 0, .op = .{ .expire = 0 } },
            .{ .lane = 0, .op = .{ .publish = 0 } },
        },
        .a = &.{ .{ .mark_dead = 0 }, .drain },
        .b = &.{ .{ .retire_idle = 0 }, .drain },
    });
}

test "a death racing a reader transfer ends the tenure once and retires the worker once" {
    try expectEveryInterleaving(.{
        .options = shape(1, 1),
        .setup = &idle_worker_read_by_a,
        .a = &.{ .drain, .{ .mark_dead = 0 }, .drain },
        .b = &.{ .{ .acquire = .{ .request = 0 } }, .drain, .{ .finish = 0 }, .drain },
    });
}

test "two lanes releasing, publishing and observing a death on two workers keep every slot accounted" {
    try expectEveryInterleaving(.{
        .options = shape(2, 2),
        .setup = &.{
            .{ .lane = 0, .op = .{ .acquire = .{ .request = 0 } } },
            .{ .lane = 1, .op = .{ .acquire = .{ .request = 0 } } },
            .{ .lane = 0, .op = .launch },
            .{ .lane = 0, .op = .{ .publish = 0 } },
            .{ .lane = 0, .op = .drain },
            .{ .lane = 1, .op = .drain },
            .{ .lane = 0, .op = .{ .acquire = .{ .request = 1 } } },
            .{ .lane = 1, .op = .{ .acquire = .{ .request = 1 } } },
            .{ .lane = 0, .op = .launch },
        },
        .a = &.{ .{ .finish = 0 }, .drain, .{ .publish = 1 }, .{ .finish = 1 } },
        .b = &.{ .{ .finish = 0 }, .drain, .{ .mark_dead = 0 }, .drain, .{ .finish = 1 } },
    });
}
