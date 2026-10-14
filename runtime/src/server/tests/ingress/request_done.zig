//! A worker's `request_done` on the ingress lane that owns its request
//! (`runner/request_done.zig`): the last descriptor of a request on the
//! worker's control socket, so a response and its `request_done` read in one
//! drain, as separate packets or in one batch, answer the client with the
//! worker's status and give the access record the worker's measures; the
//! record's status is the response head's the lane queued, and the worker's
//! own only when no head went out; a `request_done` ahead of the response's
//! end ends the request at once and resets its stream; one with no response
//! head answers 502; one naming a request that ended adds nothing, also once
//! a later request holds its slot; a request the lane answers early (a
//! client's reset, the worker's own 504, a body the lane refuses) keeps its
//! worker slot until its `request_done`, so a worker never holds more
//! requests than its `concurrency`; and a request the server ends after its
//! begin reached the worker carries the CPU of its live slot, which the
//! dispatch named (`DispatchWork.worker_slot`). Lane `server-ingress-test`,
//! through `lane_harness.zig`; a forwarded `request_done` is in
//! `lane_commands.zig`, one that fails to decode or names a request its
//! worker was never sent in `worker_faults.zig`, one read by the deadline
//! backstop in `request_deadlines.zig`, and the record's encoding in
//! `server/tests/analytics/`.

const std = @import("std");
const h2 = @import("collo_http").http2;
const lane_harness = @import("lane_harness.zig");

const access = lane_harness.access;
const OneWorker = lane_harness.OneWorker;

/// Asserts the access record of a request its worker's `request_done`
/// ended: the worker answered `status`, and the record carries the worker's
/// identity, its usage from origin `worker` and a wall time from the
/// dispatch.
fn expectWorkerRecord(scene: *OneWorker, status: u16) !access.AccessRecord {
    const record = scene.harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(status, record.status);
    try std.testing.expectEqual(access.AnsweredBy.worker, record.answered_by);
    try std.testing.expectEqual(scene.stub.key.worker_id, record.facts.worker_id);
    try std.testing.expect(record.facts.dispatched_mono_ns != 0);
    const usage = record.usage orelse return error.UsageMissing;
    try std.testing.expectEqual(access.Origin.worker, usage.origin);
    return record;
}

test "a response and its request_done read in one drain answer the client with the worker's status" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    try scene.stub.sendHead(request, 201, false);
    try scene.stub.sendChunk(request, "made", true);
    try scene.stub.sendDone(request, .{ .http_status = 201 });
    try harness.handleControl(0, scene.stub);

    try scene.expectStatus(1, 201);
    const received = try scene.client.stream(1);
    try std.testing.expect(received.ended);
    try std.testing.expectEqual(@as(usize, "made".len), received.body_len);
    const record = try expectWorkerRecord(&scene, 201);
    try std.testing.expectEqual(access.ErrorCode.done, record.facts.error_code);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expectEqual(@as(?u64, null), try harness.deadlineArmedFor(0, request.requestKey()));
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a response and its request_done in one batch packet answer the worker's status and give the record its measures" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    try scene.stub.answerInOneBatch(request, 200, "batched", .{
        .http_status = 200,
        .exec_ns = 1_000,
        .waiting_ns = 2_000,
        .io_ns = 3_000,
        .cpu_ns = 4_000,
        .client_served_bytes = "batched".len,
        .fetch_sent_bytes = 5,
        .fetch_received_bytes = 6,
    });
    try harness.handleControl(0, scene.stub);

    try scene.expectStatus(1, 200);
    try std.testing.expect((try scene.client.stream(1)).ended);
    const record = try expectWorkerRecord(&scene, 200);
    const usage = record.usage.?;
    try std.testing.expectEqual(@as(u64, 1_000), usage.exec_ns);
    try std.testing.expectEqual(@as(u64, 2_000), usage.waiting_ns);
    try std.testing.expectEqual(@as(u64, 3_000), usage.io_ns);
    try std.testing.expectEqual(@as(u64, 4_000), usage.cpu_ns);
    try std.testing.expectEqual(@as(u64, "batched".len), usage.client_served_bytes);
    try std.testing.expectEqual(@as(u64, 5), usage.fetch_sent_bytes);
    try std.testing.expectEqual(@as(u64, 6), usage.fetch_received_bytes);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a request_done ahead of its response's end ends the request at once and resets the stream" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    // The head and part of the body, then the worker is done: the response's
    // end will never come.
    try scene.stub.sendHead(request, 200, false);
    try scene.stub.sendChunk(request, "partial", false);
    try scene.stub.sendDone(request, .{ .http_status = 200 });
    try harness.handleControl(0, scene.stub);

    // No wait for the deadline: the request ended with the `request_done`,
    // and its worker slot and wheel entry went with it.
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expectEqual(@as(?u64, null), try harness.deadlineArmedFor(0, request.requestKey()));
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try scene.expectReset(1);
    const received = try scene.client.stream(1);
    try std.testing.expectEqual(@as(?u16, 200), received.status);
    try std.testing.expect(!received.ended);
    _ = try expectWorkerRecord(&scene, 200);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a request_done for a request whose response head the lane never queued answers 502" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    try scene.stub.sendDone(request, .{ .http_status = 200 });
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 502);
    // The record says what the client got, with the worker's measures.
    _ = try expectWorkerRecord(&scene, 502);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a request_done naming a request that ended adds nothing, also once a later request holds its slot" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const first = try scene.get(1);
    try scene.stub.answer(first, 200, "first");
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 200);
    _ = try expectWorkerRecord(&scene, 200);

    // A second `request_done` for the first request finds it gone.
    try scene.stub.sendDone(first, .{ .http_status = 500, .done = .js_exception });
    try harness.handleControl(0, scene.stub);
    try std.testing.expect(harness.takeAccessRecord(0) == null);

    // The next request takes the place the first one left, under a later
    // generation, and the worker repeats the first request's `request_done`.
    const second = try scene.get(3);
    try std.testing.expectEqual(first.identity.request_slot, second.identity.request_slot);
    try std.testing.expect(second.identity.request_generation != first.identity.request_generation);
    try scene.stub.sendDone(first, .{ .http_status = 500, .done = .js_exception });
    try harness.handleControl(0, scene.stub);

    try std.testing.expect(harness.takeAccessRecord(0) == null);
    try std.testing.expect(harness.requestKeyOf(scene.client, 3) != null);
    try std.testing.expectEqual(@as(u64, 2), harness.lane(0).lane.counters.stale_request_done);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "the access record carries the status of the response head the lane queued, not the one the request_done reports" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    // The client gets 200; the worker then claims 503 for the same request.
    try scene.stub.respond(request, 200, "sent");
    try scene.stub.sendDone(request, .{ .http_status = 503 });
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 200);
    _ = try expectWorkerRecord(&scene, 200);
    try harness.expectServing(scene.stub);
}

test "with no response head out, the access record carries the worker's status: the 499 of a client that reset its stream" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    try resetStream(scene.client, 1);
    try std.testing.expectEqual(
        @intFromEnum(lane_harness.ingress_channel.Op.request_reset),
        (try scene.stub.readDescriptor()).op,
    );
    try scene.stub.sendDone(request, .{ .http_status = 0, .done = .client_closed });
    try harness.handleControl(0, scene.stub);
    const record = try expectWorkerRecord(&scene, 499);
    try std.testing.expectEqual(access.ErrorCode.client_closed, record.facts.error_code);
    try harness.expectServing(scene.stub);
}

test "a client's reset answers at once, and its request keeps its worker slot until its request_done, so the request waiting for the slot gets it only then" {
    var scene: OneWorker = undefined;
    try scene.init(.{ .concurrency = 1 });
    defer scene.deinit();
    const harness = &scene.harness;
    const reset = try scene.get(1);

    try resetStream(scene.client, 1);
    try std.testing.expectEqual(
        @intFromEnum(lane_harness.ingress_channel.Op.request_reset),
        (try scene.stub.readDescriptor()).op,
    );
    // The stream is gone for the client at once, while the worker still runs
    // the request, so the next request waits for the slot it holds.
    const waiting = try scene.client.getAdmitted(3);
    try expectWaitsForTheSlot(&scene, waiting);

    try scene.stub.sendDone(reset, .{ .http_status = 0, .done = .client_closed });
    try harness.handleControl(0, scene.stub);
    const next = try scene.stub.readRequestBegin();
    try std.testing.expect(next.requestKey().eql(waiting));
    try harness.expectServing(scene.stub);
}

test "a worker's 504 at its request's deadline reaches the client at once, and the request keeps its worker slot until its request_done" {
    var scene: OneWorker = undefined;
    try scene.init(.{ .concurrency = 1 });
    defer scene.deinit();
    const harness = &scene.harness;
    const late = try scene.get(1);

    // The worker's own answer at the deadline; its `request_done` comes once
    // it has stopped the request's JavaScript.
    try scene.stub.sendHead(late, 504, true);
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 504);
    try std.testing.expect((try scene.client.stream(1)).ended);
    const waiting = try scene.client.getAdmitted(3);
    try expectWaitsForTheSlot(&scene, waiting);

    try scene.stub.sendDone(late, .{ .http_status = 504, .done = .deadline_timeout });
    try harness.handleControl(0, scene.stub);
    const next = try scene.stub.readRequestBegin();
    try std.testing.expect(next.requestKey().eql(waiting));
    try harness.expectServing(scene.stub);
}

test "a body the lane refuses is answered at once, and its request keeps its worker slot until its request_done" {
    var scene: OneWorker = undefined;
    try scene.init(.{ .concurrency = 1 });
    defer scene.deinit();
    const harness = &scene.harness;
    const upload = try scene.post(1, 4);

    // Twice the announced length: the lane answers 400 itself and tells the
    // worker the stream is gone.
    try scene.client.data(1, "too long", true);
    try scene.client.drive();
    try scene.expectStatus(1, 400);
    try std.testing.expectEqual(
        @intFromEnum(lane_harness.ingress_channel.Op.request_reset),
        (try scene.stub.readDescriptor()).op,
    );
    const waiting = try scene.client.getAdmitted(3);
    try expectWaitsForTheSlot(&scene, waiting);

    try scene.stub.sendDone(upload, .{ .http_status = 0, .done = .client_closed });
    try harness.handleControl(0, scene.stub);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(@as(u16, 400), record.status);
    try std.testing.expectEqual(access.AnsweredBy.server, record.answered_by);
    const next = try scene.stub.readRequestBegin();
    try std.testing.expect(next.requestKey().eql(waiting));
    try harness.expectServing(scene.stub);
}

test "a worker never holds more requests than its concurrency, however many of them their clients reset" {
    var scene: OneWorker = undefined;
    try scene.init(.{ .concurrency = 2 });
    defer scene.deinit();
    const harness = &scene.harness;
    const first = try scene.get(1);
    const second = try scene.get(3);
    for ([_]u32{ 1, 3 }) |stream_id| {
        try resetStream(scene.client, stream_id);
        try std.testing.expectEqual(
            @intFromEnum(lane_harness.ingress_channel.Op.request_reset),
            (try scene.stub.readDescriptor()).op,
        );
    }

    // Both requests still run on the worker, so two more wait.
    const third = try scene.client.getAdmitted(5);
    const fourth = try scene.client.getAdmitted(7);
    try expectWaitsForTheSlot(&scene, third);
    try expectWaitsForTheSlot(&scene, fourth);

    // Each `request_done` lets exactly one waiter in.
    try scene.stub.sendDone(first, .{ .http_status = 0, .done = .client_closed });
    try harness.handleControl(0, scene.stub);
    try std.testing.expect((try scene.stub.readRequestBegin()).requestKey().eql(third));
    try std.testing.expect(!try scene.stub.controlReadable());
    try std.testing.expectEqual(@as(u8, 2), harness.workerView(scene.stub).?.slots_held);
    try scene.stub.sendDone(second, .{ .http_status = 0, .done = .client_closed });
    try harness.handleControl(0, scene.stub);
    try std.testing.expect((try scene.stub.readRequestBegin()).requestKey().eql(fourth));
    try std.testing.expectEqual(@as(u8, 2), harness.workerView(scene.stub).?.slots_held);
    try harness.expectServing(scene.stub);
}

/// Sends RST_STREAM with CANCEL on `stream_id`, as a client that gives a
/// request up does, and lets the lane read it.
fn resetStream(client: *lane_harness.Client, stream_id: u32) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, @intFromEnum(h2.ErrorCode.cancel), .big);
    try client.writeFrame(.rst_stream, 0, stream_id, &payload);
    try client.drive();
}

/// Asserts the request `waiting` waits in its pool because every slot of
/// the worker is held, and the worker heard nothing of it.
fn expectWaitsForTheSlot(scene: *OneWorker, waiting: lane_harness.lane_commands.RequestKey) !void {
    const harness = &scene.harness;
    try std.testing.expect(harness.lane(0).requests.entries[waiting.slot].waiting());
    const view = harness.workerView(scene.stub) orelse return error.WorkerLeftThePool;
    try std.testing.expectEqual(harness.poolOf(scene.stub).concurrency, view.slots_held);
    try std.testing.expect(!try scene.stub.controlReadable());
}

test "a request the server ends after its begin reached the worker carries its live slot's CPU in its access record" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);
    // The dispatch named the pool slot the request holds, which is where the
    // worker writes its live slot.
    const slot = harness.requestSlotOf(scene.client, 1) orelse return error.RequestNotAdmitted;
    try std.testing.expectEqual(slot.worker_slot, request.worker_slot);

    // The worker charged the request 7 ms of CPU, then died without its
    // `request_done`.
    scene.stub.chargeLiveSlot(request, 7 * std.time.ns_per_ms);
    try scene.stub.kill();
    try harness.handleWorkerExit(0, scene.stub);

    try scene.expectStatus(1, 502);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(@as(u16, 502), record.status);
    try std.testing.expectEqualStrings("exited", record.facts.worker_fault);
    const usage = record.usage orelse return error.UsageMissing;
    try std.testing.expectEqual(access.Origin.server, usage.origin);
    try std.testing.expectEqual(@as(u64, 7 * std.time.ns_per_ms), usage.cpu_ns);
    try harness.expectFaulted(scene.stub, .exited);
}
