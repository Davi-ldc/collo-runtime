//! Request deadlines on an ingress lane. A request has one deadline, fixed
//! at admission. A request that still waits for a worker slot then is
//! answered 503 and leaves its pool's waiters, and one whose begin still
//! waits for room in its worker's socket is answered 504 with the worker left
//! in service. Once the begin reached the worker, the request's wheel entry
//! sits at the deadline plus `hard_timeout_grace_ns`, the backstop that,
//! once it read everything the worker wrote, faults a worker that never
//! ended the request and queues its retirement, leaving the kill to the
//! reaper. A completion parks only behind a response
//! head the lane queued, with that entry still armed, and a worker that
//! answers a deadline itself stays in service. Lane `server-ingress-test`,
//! through `lane_harness.zig`; the wheel itself is pinned in
//! `deadline_wheel.zig`, the reaper's teardown in
//! `server/tests/supervisor/reaper/`, and a real worker's own 504 in
//! `local-e2e`.

const std = @import("std");
const lane_harness = @import("lane_harness.zig");

const OneWorker = lane_harness.OneWorker;
const TwoLanes = lane_harness.TwoLanes;

test "a completion parked behind an unfinished response keeps the deadline armed, and the deadline still ends the request (#37)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);
    const backstop_ns = request.deadline_monotonic_ns + harness.service.hard_timeout_grace_ns;

    // The head and part of the body go out before the completion, and the
    // response's end never comes.
    try scene.stub.sendHead(request, 200, false);
    try scene.stub.sendChunk(request, "partial", false);
    try scene.stub.publishCompletion(request, .{});
    try harness.serveWorker(0, scene.stub);
    try scene.expectStatus(1, 200);
    try std.testing.expect(!(try scene.client.stream(1)).ended);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) != null);
    try std.testing.expectEqual(@as(?u64, backstop_ns), try harness.deadlineArmedFor(0, request.requestKey()));
    try std.testing.expectEqual(@as(u8, 1), harness.workerView(scene.stub).?.slots_held);

    try harness.expireDeadlines(0, harness.pastEveryDeadline());
    // The worker did answer, so the request ends with its completion and the
    // worker stays in service; the stream got a head and no end, so it is
    // reset.
    try scene.expectReset(1);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expectEqual(@as(?u16, 200), harness.takeAccessStatus(0));
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a completion for a request whose response head the lane never queued ends it at once instead of parking (#37)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    // The worker publishes its completion without having sent a head.
    try scene.stub.publishCompletion(request, .{});
    try harness.serveWorker(0, scene.stub);
    try scene.expectStatus(1, 502);
    try std.testing.expectEqual(@as(?u16, 502), harness.takeAccessStatus(0));
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expectEqual(@as(?u64, null), try harness.deadlineArmedFor(0, request.requestKey()));
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a parked completion ends its request once the response's end arrives" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);
    try scene.stub.sendHead(request, 200, false);
    try scene.stub.sendChunk(request, "partial", false);
    try scene.stub.publishCompletion(request, .{});
    try harness.serveWorker(0, scene.stub);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) != null);

    try scene.stub.sendChunk(request, ", then the rest", true);
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 200);
    const received = try scene.client.stream(1);
    try std.testing.expect(received.ended);
    try std.testing.expectEqual(@as(usize, "partial, then the rest".len), received.body_len);
    try std.testing.expectEqual(@as(?u16, 200), harness.takeAccessStatus(0));
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expectEqual(@as(?u64, null), try harness.deadlineArmedFor(0, request.requestKey()));
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "the grace backstop faults a worker that never ended its request and leaves the kill to the reaper (#39)" {
    var scene: OneWorker = undefined;
    // A deadline the clock passes during the test: the lane answers 504 only
    // to a request whose deadline its own clock has passed.
    try scene.init(.{ .timeout_ms = 10 });
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);
    try lane_harness.waitUntilClockPasses(request.deadline_monotonic_ns);

    try harness.expireDeadlines(0, harness.pastEveryDeadline());
    try harness.expectLanesRunning();
    try harness.expectFaulted(scene.stub, .deadline_grace_expired);
    // The retirement went to the reaper with the worker's process still
    // running: the lane neither signals the worker nor waits for its exit.
    try std.testing.expect(scene.stub.processAlive());
    try scene.expectStatus(1, 504);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(@as(u16, 504), record.status);
    try std.testing.expectEqual(lane_harness.page.CompletedStatus.deadline, record.facts.error_code);
    try std.testing.expectEqualStrings("deadline_grace_expired", record.facts.worker_fault);
}

test "a worker that answers one of its two requests 504 stays in service and finishes the other (#44)" {
    var scene: OneWorker = undefined;
    try scene.init(.{ .concurrency = 2 });
    defer scene.deinit();
    const harness = &scene.harness;
    const late = try scene.get(1);
    const sibling = try scene.get(3);

    // The worker ends the first request at that request's deadline itself.
    try scene.stub.sendHead(late, 504, true);
    try scene.stub.publishCompletion(late, .{ .http_status = 504, .done = .deadline_timeout });
    try harness.serveWorker(0, scene.stub);
    try scene.expectStatus(1, 504);
    try std.testing.expectEqual(@as(?u16, 504), harness.takeAccessStatus(0));
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
    try std.testing.expectEqual(@as(u8, 1), harness.workerView(scene.stub).?.slots_held);

    try scene.stub.answer(sibling, 200, "sibling");
    try harness.serveWorker(0, scene.stub);
    try scene.expectStatus(3, 200);
    try std.testing.expect((try scene.client.stream(3)).ended);
    try std.testing.expectEqual(@as(?u16, 200), harness.takeAccessStatus(0));
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "the grace backstop reads the worker's output through a slow connection's backlog, so completions published in time win (#44)" {
    var scene: OneWorker = undefined;
    // A 16-byte stream window keeps stream 1's body in the lane, so every
    // packet of it leaves the connection with bytes to write, which stops a
    // drain of the loop after that packet.
    try scene.init(.{ .initial_window_size = 16 });
    defer scene.deinit();
    const harness = &scene.harness;
    const slow = try scene.get(1);
    const late = try scene.get(3);

    const chunk: [1024]u8 = @splat('s');
    try scene.stub.sendHead(slow, 200, false);
    for (0..6) |_|
        try scene.stub.sendChunk(slow, &chunk, false);
    try scene.stub.sendChunk(slow, &chunk, true);
    try scene.stub.publishCompletion(slow, .{ .http_status = 200 });
    // Behind all of that, the worker answered stream 3's deadline itself.
    try scene.stub.sendHead(late, 504, true);
    try scene.stub.publishCompletion(late, .{ .http_status = 504, .done = .deadline_timeout });

    try harness.expireDeadlines(0, harness.pastEveryDeadline());
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expect(harness.requestKeyOf(scene.client, 3) == null);
    try scene.expectStatus(3, 504);
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
}

test "a request whose begin waits for room in its worker's control socket ends at its own deadline with 504, and the worker stays in service" {
    var scene: OneWorker = undefined;
    // The kernel doubles the value: 128 KiB in flight before a send would
    // block, above the largest packet the lane sends.
    try scene.init(.{ .control_send_buffer_bytes = 64 * 1024 });
    defer scene.deinit();
    const harness = &scene.harness;

    // An upload the worker does not read fills its control socket.
    const frame_bytes: usize = 16 * 1024;
    const frame_count: usize = 24;
    _ = try scene.post(1, frame_bytes * frame_count);
    var frame: [frame_bytes]u8 = @splat('u');
    for (0..frame_count) |index| {
        try scene.client.data(1, &frame, index + 1 == frame_count);
        try scene.client.drive();
    }
    // A second request takes the worker's other slot, and its begin waits
    // behind the full socket.
    const parked_key = try scene.client.getAdmitted(3);
    const parked = harness.lane(0).requests.entries[parked_key.slot];
    try std.testing.expect(parked.dispatched());
    try std.testing.expect(!parked.begin_sent);
    // Its one wheel entry stays at its own deadline, not at the backstop.
    const deadline_ns = (try harness.deadlineArmedFor(0, parked_key)) orelse return error.DeadlineNotArmed;
    try std.testing.expectEqual(parked.deadline_ns, deadline_ns);

    // Two wheel ticks past that deadline, and long before the upload's
    // backstop.
    try harness.expireDeadlines(0, deadline_ns + 10 * std.time.ns_per_ms);
    try scene.expectStatus(3, 504);
    try std.testing.expect(harness.requestKeyOf(scene.client, 3) == null);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(@as(u16, 504), record.status);
    try std.testing.expectEqualStrings("", record.facts.worker_fault);
    try std.testing.expectEqual(@as(u8, 1), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a request whose deadline passes while it waits for a slot is answered 503 and leaves the pool's waiters" {
    var scene: TwoLanes = undefined;
    try scene.init(.{ .concurrency = 1 });
    defer scene.deinit();
    const harness = &scene.harness;
    // The waiter sits on lane 1, so that lane's sweep reaches no other
    // request's deadline.
    const holder = try scene.get(scene.first, 1);
    _ = try scene.second.getAdmitted(1);
    const waiting = harness.poolOf(scene.stub).snapshot();
    try std.testing.expectEqual(@as(u32, 1), waiting.waiters);

    try harness.expireDeadlines(1, harness.pastEveryDeadline());
    try scene.second.expectStatus(1, 503);
    try std.testing.expectEqual(@as(?u16, 503), harness.takeAccessStatus(1));
    try std.testing.expect(harness.requestKeyOf(scene.second, 1) == null);
    const snapshot = harness.poolOf(scene.stub).snapshot();
    try std.testing.expectEqual(@as(u32, 0), snapshot.waiters);
    // Counted from the admission on: the fixture's publish cancels a waiter
    // of its own (`supervisor_fixture.publishWorker`).
    try std.testing.expectEqual(waiting.counters.waiters_cancelled + 1, snapshot.counters.waiters_cancelled);

    // The holder's finish finds no waiter: the slot goes back to the free
    // list, and lane 1 gets no `dispatch_ready`.
    try scene.stub.answer(holder, 200, "first");
    try harness.serveWorker(0, scene.stub);
    try scene.first.expectStatus(1, 200);
    try harness.expectQueued(1, &.{});
    try std.testing.expect(!try scene.stub.controlReadable());
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}
