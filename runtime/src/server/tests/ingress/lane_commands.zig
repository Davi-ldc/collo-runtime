//! The commands an ingress lane takes from its queue (`handleCommands`), each
//! run through the lane's own handlers: a slot a pool hands a waiting request
//! (`dispatch_ready`), a waiting request no worker can serve
//! (`dispatch_failed`), the response and completion the reader of a worker
//! forwards to the lane that owns the request (`forwarded_descriptor`,
//! `forwarded_completion`), a reader asked to give its role up
//! (`release_worker`), and a death another lane saw (`worker_died`), with the
//! reserve a worker's forwarded output takes, the window that stops its
//! reader while too much of that output waits, the reader's check of a
//! descriptor against the worker's request table, and the queue a stopping
//! lane runs dry before it closes. A command that crosses lanes runs between
//! two lanes sharing one stub worker, or two stub workers when a worker's
//! output names a request on the other.
//! Lane `server-ingress-test`, through `lane_harness.zig`; the pool's side of
//! each exchange is pinned in `server/tests/supervisor/pool.zig`, and the
//! queue itself in `command_queue.zig`.

const std = @import("std");
const limits = @import("collo_limits");
const lane_harness = @import("lane_harness.zig");

const commands = lane_harness.commands;
const fault = lane_harness.fault;
const pool = lane_harness.pool;
const Harness = lane_harness.Harness;
const TwoLanes = lane_harness.TwoLanes;

test "dispatch_ready sends a waiting request on the slot another lane freed, with no timer but its deadline (#29)" {
    var scene: TwoLanes = undefined;
    try scene.init(.{ .concurrency = 1 });
    defer scene.deinit();
    const harness = &scene.harness;
    const holder = try scene.get(scene.first, 1);
    const waiter_key = try scene.second.getAdmitted(1);
    try std.testing.expect(!try scene.stub.controlReadable());

    // The deadline fixed at admission is the waiting request's only timer,
    // so nothing retries it while it waits.
    const deadline_ns = (try harness.deadlineArmedFor(1, waiter_key)) orelse return error.WaiterDeadlineNotArmed;
    try std.testing.expectEqual(@as(usize, 1), harness.armedDeadlineCount(1));

    // The holder's finish hands the freed slot to the waiter at once.
    try scene.stub.answer(holder, 200, "first");
    try harness.serveWorker(0, scene.stub);
    try scene.first.expectStatus(1, 200);
    var buffer: [lane_harness.queued_commands_max]commands.Command = undefined;
    const queued = try harness.queuedCommands(1, &buffer);
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const ready = switch (queued[0]) {
        .dispatch_ready => |ready| ready,
        else => return error.ExpectedDispatchReady,
    };
    try std.testing.expect(ready.request_key.eql(waiter_key));
    try std.testing.expect(ready.worker_key.eql(scene.stub.key));

    try harness.handleCommands(1);
    const dispatched = try scene.stub.readRequestBegin();
    try std.testing.expect(dispatched.requestKey().eql(waiter_key));
    try std.testing.expectEqual(deadline_ns, dispatched.deadline_monotonic_ns);
    // Dispatched, the request's one wheel entry moves to the grace backstop.
    try std.testing.expectEqual(
        @as(?u64, deadline_ns + harness.service.hard_timeout_grace_ns),
        try harness.deadlineArmedFor(1, waiter_key),
    );
    try std.testing.expectEqual(@as(usize, 1), harness.armedDeadlineCount(1));

    // Lane 0 still reads the worker and forwards the response to lane 1.
    try scene.stub.answer(dispatched, 200, "second");
    try harness.serveWorker(0, scene.stub);
    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 200);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "dispatch_ready for a request that expired while the slot travelled gives the slot back" {
    var scene: TwoLanes = undefined;
    try scene.init(.{ .concurrency = 1 });
    defer scene.deinit();
    const harness = &scene.harness;
    const holder = try scene.get(scene.first, 1);
    _ = try scene.second.getAdmitted(1);

    try scene.stub.answer(holder, 200, "first");
    try harness.serveWorker(0, scene.stub);
    try harness.expectQueued(1, &.{.dispatch_ready});
    // The waiter's deadline passes before its lane runs the command: it is
    // answered 503 while the pool still counts the slot as its own.
    try harness.expireDeadlines(1, harness.pastEveryDeadline());
    try scene.second.expectStatus(1, 503);
    try std.testing.expectEqual(@as(?u16, 503), harness.takeAccessStatus(1));
    try std.testing.expectEqual(@as(u8, 1), harness.workerView(scene.stub).?.slots_held);

    try harness.handleCommands(1);
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try std.testing.expect(!try scene.stub.controlReadable());
    // The slot came with a grant to take the reader role from lane 0, which a
    // lane discharges even for a slot it gives back unused.
    try harness.expectQueued(0, &.{.release_worker});
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a request that waited for a launch reports the launched worker's own boot as its cold start" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    const client = try harness.connect(0, .{});
    const waiter_key = try client.getAdmitted(1);
    // The pool has no worker, so the request waits and asks for a launch.
    try std.testing.expectEqual(@as(usize, 1), harness.launcher.submission_count);

    // The launch publishes a worker whose boot took 7 ms, and the publish
    // hands the waiter its slot.
    const boot_work_ns: u64 = 7 * std.time.ns_per_ms;
    const stub = try harness.publishWorker(.{ .launched = true, .boot_work_ns = boot_work_ns });
    try harness.expectQueued(0, &.{.dispatch_ready});
    try harness.handleCommands(0);
    const request = try stub.readRequestBegin();
    try std.testing.expect(request.requestKey().eql(waiter_key));

    try stub.answer(request, 200, "cold");
    try harness.serveWorker(0, stub);
    try client.expectStatus(1, 200);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expect(record.facts.cold_start);
    try std.testing.expectEqual(boot_work_ns, record.facts.cold_start_ns);
    try harness.expectLanesRunning();
    try harness.expectServing(stub);
}

test "dispatch_failed answers 503 a request that waited for a launch that failed" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    const client = try harness.connect(0, .{});
    const waiter_key = try client.getAdmitted(1);
    // The pool has no worker, so the request waits and asks for a launch.
    try std.testing.expectEqual(@as(usize, 1), harness.launcher.submission_count);

    // The launcher's side of a failed launch (`Deps.failed`): the claim ends
    // without a worker, and the waiters nothing can serve now leave the pool
    // for their lanes.
    const definition_pool = harness.supervisor.poolFor(lane_harness.default_definition);
    const ticket = definition_pool.launchStarted(true) orelse return error.LaunchNotClaimed;
    try definition_pool.launchEnded(ticket);
    try harness.service.strandWaiters(lane_harness.default_definition, .launch_failed);
    var buffer: [lane_harness.queued_commands_max]commands.Command = undefined;
    const queued = try harness.queuedCommands(0, &buffer);
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const failed = switch (queued[0]) {
        .dispatch_failed => |failed| failed,
        else => return error.ExpectedDispatchFailed,
    };
    try std.testing.expect(failed.request_key.eql(waiter_key));

    try harness.handleCommands(0);
    try client.expectStatus(1, 503);
    try std.testing.expectEqual(@as(?u16, 503), harness.takeAccessStatus(0));
    try std.testing.expect(harness.requestKeyOf(client, 1) == null);
    try std.testing.expectEqual(@as(u32, 0), definition_pool.snapshot().waiters);
    try harness.expectLanesRunning();
}

test "the reader forwards another lane's response and completion to that lane in the order it read them (#43)" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    _ = try scene.get(scene.first, 1);
    const other = try scene.get(scene.second, 1);
    // Lane 0 took the first slot, so it reads the worker for both lanes.
    const reader = harness.workerView(scene.stub).?.reader orelse return error.WorkerHasNoReader;
    try std.testing.expectEqual(@as(pool.LaneId, 0), reader.lane);

    try scene.stub.answer(other, 200, "lane one");
    try harness.serveWorker(0, scene.stub);
    try harness.expectQueued(1, &.{ .forwarded_descriptor, .forwarded_descriptor, .forwarded_completion });
    var buffer: [lane_harness.queued_commands_max]commands.Command = undefined;
    for (try harness.queuedCommands(1, &buffer)) |command| {
        switch (command) {
            .forwarded_descriptor => |forwarded| {
                try std.testing.expect(forwarded.request_key.eql(other.requestKey()));
                try std.testing.expect(forwarded.worker_key.eql(scene.stub.key));
                try std.testing.expectEqual(reader.lane, forwarded.reader_lane_id);
            },
            .forwarded_completion => |forwarded| {
                try std.testing.expect(forwarded.request_key.eql(other.requestKey()));
                try std.testing.expect(forwarded.worker_key.eql(scene.stub.key));
            },
            else => return error.UnexpectedCommand,
        }
    }
    // Nothing reaches lane 1's client before lane 1 runs its queue.
    try scene.second.collect();
    try std.testing.expectEqual(@as(?u16, null), (try scene.second.stream(1)).status);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a forwarded completion ends the owner lane's request with the worker's response (#43)" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const own = try scene.get(scene.first, 1);
    const other = try scene.get(scene.second, 1);

    try scene.stub.answer(other, 200, "lane one");
    try harness.serveWorker(0, scene.stub);
    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 200);
    const received = try scene.second.stream(1);
    try std.testing.expect(received.ended);
    try std.testing.expectEqual(@as(usize, "lane one".len), received.body_len);
    try std.testing.expectEqual(@as(?u16, 200), harness.takeAccessStatus(1));
    // Lane 0's request still holds the worker's other slot.
    try std.testing.expectEqual(@as(u8, 1), harness.workerView(scene.stub).?.slots_held);

    try scene.stub.answer(own, 200, "lane zero");
    try harness.serveWorker(0, scene.stub);
    try scene.first.expectStatus(1, 200);
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a ring chunk for another lane's request travels by reference, and its reader frees the ring bytes once that lane consumed them (#43)" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    _ = try scene.get(scene.first, 1);
    const other = try scene.get(scene.second, 1);

    // Above the inline threshold, so the chunk's bytes ride in the ring.
    const body_len = lane_harness.ingress_channel.shared_payload_threshold + 1024;
    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);
    @memset(body, 'r');
    try scene.stub.sendHead(other, 200, false);
    try scene.stub.sendRingChunk(other, body, true);
    try harness.handleControl(0, scene.stub);
    try harness.expectQueued(1, &.{ .forwarded_descriptor, .forwarded_descriptor });
    // Lane 0, the reader, holds the chunk's ring bytes until lane 1 answers.
    const reader_index = try harness.expectRegistration(0, scene.stub);
    const holds = &harness.lane(0).registrations.entries[reader_index].ring_payloads;
    try std.testing.expect(!holds.isEmpty());
    const cursors = scene.stub.responseRingCursors();
    try std.testing.expect(cursors.read < cursors.write);

    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 200);
    const received = try scene.second.stream(1);
    try std.testing.expect(received.ended);
    try std.testing.expectEqual(body_len, received.body_len);
    try harness.expectQueued(0, &.{.payload_consumed});

    try harness.handleCommands(0);
    try std.testing.expect(holds.isEmpty());
    const freed = scene.stub.responseRingCursors();
    try std.testing.expectEqual(freed.write, freed.read);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a descriptor naming another lane's request its worker was never sent drops at the reader and costs that lane nothing" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .lane_count = 2, .routes = .{ .concurrency = 1 } });
    defer harness.deinit();
    // Lane 0's request takes the sender's only slot, so lane 0 reads it; the
    // other worker, published next, serves lane 1's request.
    const sender = try harness.publishWorker(.{});
    const first = try harness.connect(0, .{});
    try first.get(1);
    try first.drive();
    _ = try sender.readRequestBegin();
    const other = try harness.publishWorker(.{});
    const second = try harness.connect(1, .{});
    try second.get(1);
    try second.drive();
    const victim = try other.readRequestBegin();

    // The sender answers lane 1's request, which runs on the other worker.
    // Its request table holds no such request, so its reader drops the head
    // instead of taking a place in lane 1's queue.
    try sender.sendHead(victim, 200, true);
    try harness.handleControl(0, sender);
    try harness.expectQueued(1, &.{});
    try std.testing.expectEqual(@as(u64, 1), harness.lane(0).lane.counters.forwarded_descriptor_drops);
    try std.testing.expectEqual(@as(u32, 0), sender.record.forwarded_in_queues.load(.seq_cst));

    // The named request, its worker and the sender's own request go on.
    try harness.expectLanesRunning();
    try harness.expectServing(sender);
    try harness.expectServing(other);
    try std.testing.expect(harness.requestKeyOf(second, 1) != null);
    try second.collect();
    try std.testing.expectEqual(@as(?u16, null), (try second.stream(1)).status);
    try std.testing.expect(harness.requestKeyOf(first, 1) != null);
}

test "a descriptor naming a request its worker holds under another key takes the worker out of service at its reader" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    // Lane 0 reads the worker, and both lanes hold a request on it.
    const own = try scene.get(scene.first, 1);
    const other = try scene.get(scene.second, 1);

    // The worker names lane 1's request with the id of lane 0's: its table
    // holds that id under lane 0's key.
    var crossed = other;
    crossed.identity.request_id = own.identity.request_id;
    try scene.stub.sendHead(crossed, 200, true);
    try harness.handleControl(0, scene.stub);

    try harness.expectQueued(1, &.{.worker_died});
    try harness.handleCommands(1);
    try scene.first.expectStatus(1, 502);
    try scene.second.expectStatus(1, 502);
    try harness.expectLanesRunning();
    try harness.expectFaulted(scene.stub, .descriptor_names_no_request);
}

test "release_worker leaves the reader role with a lane while the worker has a request in flight" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const first = try scene.get(scene.first, 1);
    try scene.stub.answer(first, 200, "first");
    try harness.serveWorker(0, scene.stub);
    try scene.first.expectStatus(1, 200);
    const tenure = harness.workerView(scene.stub).?.reader orelse return error.WorkerHasNoReader;
    try std.testing.expectEqual(@as(pool.LaneId, 0), tenure.lane);

    // Lane 1 takes a slot of the idle worker lane 0 reads: it asks lane 0
    // for the role and sends its request at once.
    const second = try scene.get(scene.second, 1);
    try harness.expectQueued(0, &.{.release_worker});
    try harness.handleCommands(0);
    try std.testing.expectEqual(@as(?pool.ReaderTenure, tenure), harness.workerView(scene.stub).?.reader);
    try std.testing.expect(harness.registration(0, scene.stub) != null);
    try std.testing.expectEqual(@as(u32, 0), harness.reaper.pidfd_scan_wakes);

    // Lane 0 goes on reading for lane 1.
    try scene.stub.answer(second, 200, "second");
    try harness.serveWorker(0, scene.stub);
    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 200);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "release_worker ends the reader role over an idle worker, and the next lane to take a slot reads it" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const first = try scene.get(scene.first, 1);
    try scene.stub.answer(first, 200, "first");
    try harness.serveWorker(0, scene.stub);
    const tenure = harness.workerView(scene.stub).?.reader orelse return error.WorkerHasNoReader;
    try std.testing.expectEqual(@as(pool.LaneId, 0), tenure.lane);

    // Lane 1's request ends before lane 0 runs the `release_worker` it was
    // sent, so lane 0 finds the worker idle.
    const second = try scene.get(scene.second, 1);
    try scene.stub.answer(second, 200, "second");
    try harness.serveWorker(0, scene.stub);
    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 200);
    try harness.expectQueued(0, &.{.release_worker});

    try harness.handleCommands(0);
    try std.testing.expect(harness.workerView(scene.stub).?.reader == null);
    // Lane 0 neither reads the worker nor holds a request on it, and it woke
    // the reaper to watch the worker's pidfd instead.
    try std.testing.expect(harness.registration(0, scene.stub) == null);
    try std.testing.expectEqual(@as(u32, 1), harness.reaper.pidfd_scan_wakes);
    try harness.expectServing(scene.stub);

    const third = try scene.get(scene.second, 3);
    const next = harness.workerView(scene.stub).?.reader orelse return error.WorkerHasNoReader;
    try std.testing.expectEqual(@as(pool.LaneId, 1), next.lane);
    try std.testing.expect(next.epoch != tenure.epoch);
    try std.testing.expect(harness.registration(1, scene.stub) != null);
    try scene.stub.answer(third, 200, "third");
    try harness.serveWorker(1, scene.stub);
    try scene.second.expectStatus(3, 200);
    try harness.expectLanesRunning();
}

test "worker_died answers 502 the request a lane holds on a worker another lane saw die" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    _ = try scene.get(scene.first, 1);
    _ = try scene.get(scene.second, 1);

    // Lane 0 reads the worker, so its pidfd poll is the one that sees the
    // exit.
    try scene.stub.kill();
    try harness.handleWorkerExit(0, scene.stub);
    try scene.first.expectStatus(1, 502);
    var buffer: [lane_harness.queued_commands_max]commands.Command = undefined;
    const queued = try harness.queuedCommands(1, &buffer);
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const died = switch (queued[0]) {
        .worker_died => |died| died,
        else => return error.ExpectedWorkerDied,
    };
    try std.testing.expect(died.worker_key.eql(scene.stub.key));
    try std.testing.expectEqual(fault.WorkerFaultReason.exited, died.reason);
    // Lane 1's request still holds a slot, so nothing retires the worker yet.
    try std.testing.expectEqual(@as(usize, 0), harness.reaper.retirementsOf(scene.stub.key));

    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 502);
    // The notice carried the reason, so the holder's record names it too.
    const record = harness.takeAccessRecord(1) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(@as(u16, 502), record.status);
    try std.testing.expectEqualStrings("exited", record.facts.worker_fault);
    try harness.expectLanesRunning();
    try harness.expectFaulted(scene.stub, .exited);
}

test "a stopping lane runs the dispatch_ready queued for a request that ended, so the slot goes back before the lane closes" {
    var scene: TwoLanes = undefined;
    try scene.init(.{ .concurrency = 1 });
    defer scene.deinit();
    const harness = &scene.harness;
    const holder = try scene.get(scene.first, 1);
    _ = try scene.second.getAdmitted(1);

    // The holder's finish hands the slot to lane 1's waiter, whose deadline
    // passes before lane 1 runs the command.
    try scene.stub.answer(holder, 200, "first");
    try harness.serveWorker(0, scene.stub);
    try harness.expectQueued(1, &.{.dispatch_ready});
    try harness.expireDeadlines(1, harness.pastEveryDeadline());
    try scene.second.expectStatus(1, 503);
    try std.testing.expectEqual(@as(u8, 1), harness.workerView(scene.stub).?.slots_held);

    // Lane 1 has no request and reads no worker, but its queue holds the
    // slot: the stop drain runs it before the lane closes to posts.
    try harness.lane(1).handleStop();
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try std.testing.expectEqual(lane_harness.runner.LaneRuntimeState.closed, harness.lane(1).state());
    try std.testing.expect(!try harness.service.postToLane(1, .shutdown));
    // The slot's grant asked lane 0 for the reader role, which lane 0 gives
    // up at once, the worker being idle, so its own stop drain can end.
    try harness.expectQueued(0, &.{.release_worker});
    try harness.handleCommands(0);
    try std.testing.expect(harness.workerView(scene.stub).?.reader == null);
    try std.testing.expect(harness.registration(0, scene.stub) == null);
    try harness.expectServing(scene.stub);
}

test "a worker's output takes reserved places of the owner lane's queue, so a queue full of other commands still delivers its whole response" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    _ = try scene.get(scene.first, 1);
    const other = try scene.get(scene.second, 1);

    // Stale `dispatch_failed` notices, which hold nothing, fill every
    // ordinary place of lane 1's queue.
    const queue = &harness.lane(1).lane.command_queue;
    const ordinary_places = queue.capacity() - queue.reserve;
    var posted: usize = 0;
    while (posted <= ordinary_places) : (posted += 1) {
        if (!try harness.service.postToLane(1, .{ .dispatch_failed = .{
            .request_key = .{ .lane_id = 1, .slot = 0, .generation = 0 },
            .reason = .growth_refused,
        } }))
            break;
    }
    try std.testing.expectEqual(ordinary_places, posted);

    // The worker answers lane 1's request. Its descriptors and its
    // completion take reserved places, so nothing of it drops.
    try scene.stub.answer(other, 200, "lane one");
    try harness.serveWorker(0, scene.stub);
    try harness.handleCommands(1);
    try std.testing.expect(harness.requestKeyOf(scene.second, 1) == null);
    try scene.second.expectStatus(1, 200);
    try std.testing.expectEqual(@as(?u16, 200), harness.takeAccessStatus(1));
    try std.testing.expectEqual(@as(u64, 0), harness.lane(0).lane.counters.forwarded_descriptor_drops);
    // Every forwarded command was applied, so the worker's window is empty.
    try std.testing.expectEqual(@as(u32, 0), scene.stub.record.forwarded_in_queues.load(.seq_cst));
    try std.testing.expectEqual(@as(u8, 1), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a reader stops receiving a worker whose forwarded output fills its window, and receives again once the owner lane applied it" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    _ = try scene.get(scene.first, 1);
    const other = try scene.get(scene.second, 1);

    // One descriptor per packet, more of them than the window holds.
    const chunk_count = 40;
    try scene.stub.sendHead(other, 200, false);
    for (0..chunk_count) |index| try scene.stub.sendChunk(other, "c", index + 1 == chunk_count);
    try harness.handleControl(0, scene.stub);

    // The reader received packets while a whole batch still fit, then
    // stopped with the rest left in the worker's socket.
    const window = &scene.stub.record.forwarded_in_queues;
    const window_units = limits.ingress.forwarded_commands_per_worker_max;
    try std.testing.expectEqual(window_units - lane_harness.ingress_channel.max_batch_descriptors + 1, window.load(.seq_cst));
    const reader_index = try harness.expectRegistration(0, scene.stub);
    const reader = &harness.lane(0).registrations.entries[reader_index];
    try std.testing.expect(reader.window_blocked);
    try std.testing.expectEqual(@as(u64, 1), harness.lane(0).lane.counters.forward_window_waits);

    // Lane 1 applies what its queue holds, and the release that reopens the
    // window wakes lane 0, whose next commands pass receives the rest.
    try harness.handleCommands(1);
    try std.testing.expectEqual(@as(u32, 0), window.load(.seq_cst));
    try harness.handleCommands(0);
    try std.testing.expect(!reader.window_blocked);
    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 200);
    const received = try scene.second.stream(1);
    try std.testing.expect(received.ended);
    try std.testing.expectEqual(@as(usize, chunk_count), received.body_len);
    try std.testing.expectEqual(@as(u32, 0), window.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), harness.lane(0).lane.counters.forwarded_descriptor_drops);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a completion a worker publishes twice for another lane's request is forwarded once" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    _ = try scene.get(scene.first, 1);
    const other = try scene.get(scene.second, 1);

    try scene.stub.respond(other, 200, "lane one");
    try scene.stub.publishCompletion(other, .{ .http_status = 200 });
    try scene.stub.publishCompletion(other, .{ .http_status = 200 });
    try harness.serveWorker(0, scene.stub);
    try harness.expectQueued(1, &.{ .forwarded_descriptor, .forwarded_descriptor, .forwarded_completion });
    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 200);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a lane that only sends to a worker keeps no registration of it once its requests end, completed or ended by a death another lane saw (#49)" {
    var scene: TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    _ = try scene.get(scene.first, 1);
    const completed = try scene.get(scene.second, 1);
    // Lane 0 reads the worker; lane 1 sends to it and keeps a registration
    // only for its request in flight.
    try std.testing.expect(harness.registration(1, scene.stub) != null);

    try scene.stub.answer(completed, 200, "lane one");
    try harness.serveWorker(0, scene.stub);
    try harness.handleCommands(1);
    try scene.second.expectStatus(1, 200);
    try std.testing.expect(harness.registration(1, scene.stub) == null);

    // A second request, ended by the worker's death, which lane 0 sees.
    _ = try scene.get(scene.second, 3);
    try std.testing.expect(harness.registration(1, scene.stub) != null);
    try scene.stub.kill();
    try harness.handleWorkerExit(0, scene.stub);
    try harness.handleCommands(1);
    try scene.second.expectStatus(3, 502);
    try std.testing.expect(harness.registration(1, scene.stub) == null);
    try std.testing.expect(harness.registration(0, scene.stub) == null);
    try harness.expectLanesRunning();
    try harness.expectFaulted(scene.stub, .exited);
}
