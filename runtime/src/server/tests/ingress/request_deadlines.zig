//! Request deadlines on an ingress lane. A request has one deadline, fixed
//! at admission and counted from the socket read that brought its head. A
//! request that still waits for a worker slot then is answered 503 and
//! leaves its pool's waiters, and one whose begin still waits for room in
//! its worker's socket is answered 504 with the worker left in service. Once
//! the begin reached the worker, the request's wheel entry sits at the
//! deadline plus `hard_timeout_grace_ns`, the backstop that, once it read
//! what the worker wrote and found no `request_done` for the request there,
//! faults the worker and queues its retirement, leaving the kill to the
//! reaper; the request's record carries the server's floor. A worker that
//! answers a deadline itself, or whose `request_done` waits in its socket
//! when the backstop fires, stays in service. A trailer block that a
//! deadline's answer overtakes between two reads is dropped with its stream,
//! and the connection goes on. Lane `server-ingress-test`, through
//! `lane_harness.zig`; the wheel itself is pinned in `deadline_wheel.zig`,
//! the reaper's teardown in `server/tests/supervisor/reaper/`, and a real
//! worker's own 504 in `local-e2e`.

const std = @import("std");
const h2 = @import("collo_http").http2;
const limits = @import("collo_limits");
const lane_harness = @import("lane_harness.zig");

const Harness = lane_harness.Harness;
const OneWorker = lane_harness.OneWorker;
const TwoLanes = lane_harness.TwoLanes;

test "a request_done the worker sent before the backstop fired wins over the deadline fault" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    // The whole response and its `request_done` are out, and the lane has
    // read none of it when the backstop fires.
    try scene.stub.answer(request, 200, "in time");
    try harness.expireDeadlines(0, harness.pastEveryDeadline());

    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
    try scene.expectStatus(1, 200);
    try std.testing.expectEqual(@as(?u16, 200), harness.takeAccessStatus(0));
    const counters = harness.lane(0).lane.counters;
    try std.testing.expectEqual(@as(u64, 1), counters.request_done_at_backstop);
    try std.testing.expectEqual(@as(u64, 0), counters.deadline_grace_faults);
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
    try std.testing.expectEqual(lane_harness.access.ErrorCode.deadline, record.facts.error_code);
    try std.testing.expectEqualStrings("deadline_grace_expired", record.facts.worker_fault);
    // No `request_done` came, so the record's usage is the server's.
    const usage = record.usage orelse return error.UsageMissing;
    try std.testing.expectEqual(lane_harness.access.Origin.server, usage.origin);
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
    try scene.stub.sendDone(late, .{ .http_status = 504, .done = .deadline_timeout });
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 504);
    try std.testing.expectEqual(@as(?u16, 504), harness.takeAccessStatus(0));
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
    try std.testing.expectEqual(@as(u8, 1), harness.workerView(scene.stub).?.slots_held);

    try scene.stub.answer(sibling, 200, "sibling");
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(3, 200);
    try std.testing.expect((try scene.client.stream(3)).ended);
    try std.testing.expectEqual(@as(?u16, 200), harness.takeAccessStatus(0));
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "the grace backstop reads the worker's output through a slow connection's backlog, so request_dones sent in time win (#44)" {
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
    const chunk_count = limits.http_body.INGRESS_RESPONSE_CHUNKS_IN_FLIGHT_MAX;
    for (0..chunk_count) |index|
        try scene.stub.sendChunk(slow, &chunk, index + 1 == chunk_count);
    try scene.stub.sendDone(slow, .{ .http_status = 200 });
    // Behind all of that, the worker answered stream 3's deadline itself.
    try scene.stub.sendHead(late, 504, true);
    try scene.stub.sendDone(late, .{ .http_status = 504, .done = .deadline_timeout });

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
    try harness.handleControl(0, scene.stub);
    try scene.first.expectStatus(1, 200);
    try harness.expectQueued(1, &.{});
    try std.testing.expect(!try scene.stub.controlReadable());
    try std.testing.expectEqual(@as(u8, 0), harness.workerView(scene.stub).?.slots_held);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "trailers split across reads on a stream the lane answered at its request's deadline meanwhile are dropped, and the connection goes on" {
    var harness: Harness = undefined;
    // A request deadline well inside the stall deadline, which an open
    // header block keeps even while a request runs.
    try harness.init(std.testing.allocator, .{
        .lane_count = 2,
        .routes = .{ .concurrency = 1, .timeout_ms = 1000 },
    });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const first = try harness.connect(0, .{});
    const second = try harness.connect(1, .{});
    try first.get(1);
    try first.drive();
    const holder = try stub.readRequestBegin();
    // An upload on lane 1 waits for the worker's one slot.
    try second.request(1, "POST", lane_harness.default_path, .{ .body_follows = true });
    try second.drive();
    try std.testing.expectEqual(@as(u32, 1), harness.poolOf(stub).snapshot().waiters);
    const waiting = harness.requestSlotOf(second, 1) orelse return error.RequestNotAdmitted;
    const waiting_deadline_ns = waiting.deadline_ns;

    // The trailers add `user-agent: probe/1` to the HPACK dynamic table
    // (a literal with incremental indexing of static name 58). The first
    // byte of their block arrives in one read, so their HEADERS frame marks
    // the block as trailers before the stream ends.
    const trailer_block = [_]u8{ 0x40 | 58, 7 } ++ "probe/1".*;
    var trailers_frame: [h2.frame_header_len + trailer_block.len]u8 = undefined;
    try encodeHeadersFrame(&trailers_frame, 1, true, &trailer_block);
    const cut = h2.frame_header_len + 1;
    try second.writeAll(trailers_frame[0..cut]);
    try second.drive();

    // Two wheel ticks past the waiter's deadline.
    try harness.expireDeadlines(1, waiting_deadline_ns + 10 * std.time.ns_per_ms);
    try second.expectStatus(1, 503);
    try std.testing.expect(harness.requestKeyOf(second, 1) == null);
    try std.testing.expectEqual(@as(?u16, 503), harness.takeAccessStatus(1));

    // The rest of the block reaches a stream the lane closed, which ignores
    // it (RFC 9113 §5.1) instead of failing the connection.
    try second.writeAll(trailers_frame[cut..]);
    try second.drive();
    try second.collect();
    try std.testing.expect(second.open());
    try std.testing.expectEqual(@as(?u32, null), second.goaway_code);

    // The dropped block was still decoded: a later head that names its
    // entry by dynamic index 62, the newest, decodes to that user agent.
    // The rest of the head adds nothing to the table: indexed static
    // fields and literals without indexing (`/__collo/none`, which the lane
    // answers 404 with an access record).
    const later_block = [_]u8{ 0x82, 0x87, 0x01, 17 } ++ "demo.example.test".* ++
        [_]u8{ 0x04, 13 } ++ "/__collo/none".* ++ [_]u8{0x80 | 62};
    var later_frame: [h2.frame_header_len + later_block.len]u8 = undefined;
    try encodeHeadersFrame(&later_frame, 3, true, &later_block);
    try second.writeAll(&later_frame);
    try second.drive();
    try std.testing.expect(second.open());
    const record = harness.takeAccessRecord(1) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(@as(u16, 404), record.status);
    try std.testing.expectEqualStrings("probe/1", record.facts.userAgentSlice());

    try stub.answer(holder, 200, "first");
    try harness.handleControl(0, stub);
    try first.expectStatus(1, 200);
    try harness.expectLanesRunning();
    try harness.expectServing(stub);
}

/// A lane clock a test drives (`runner.LaneClock`): each reading returns the
/// time and moves it on by `step_ns`, so no two readings agree and a stamp
/// shows which reading it came from.
const SteppingClock = struct {
    now_ns: u64,
    step_ns: u64,

    fn read(context: ?*anyopaque) u64 {
        const self: *SteppingClock = @ptrCast(@alignCast(context.?));
        const now_ns = self.now_ns;
        self.now_ns += self.step_ns;
        return now_ns;
    }
};

test "a request's deadline counts from the read that brought its head, not from the lane's later work on it" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const lane = harness.lane(0);
    var clock = SteppingClock{
        .now_ns = @import("collo_os").process.monotonicNowNsOrZero(),
        .step_ns = std.time.ns_per_ms,
    };
    lane.clock = .{ .context = &clock, .read = SteppingClock.read };

    try scene.client.get(1);
    try scene.client.drive();
    const request = try scene.stub.readRequestBegin();
    const slot = harness.requestSlotOf(scene.client, 1) orelse return error.RequestNotAdmitted;
    const connection = switch (lane.connections.lookup(scene.client.slot, scene.client.key.generation)) {
        .live => |runtime| runtime,
        .stale_generation, .vacant, .out_of_range => return error.ConnectionGone,
    };
    // The read that brought the head stamped the connection's progress and
    // the head's arrival with one reading; admission and dispatch read the
    // clock again after it, each a step later.
    try std.testing.expectEqual(connection.last_progress_ns, slot.admitted_ns);
    try std.testing.expect(clock.now_ns > slot.admitted_ns + std.time.ns_per_ms);
    const timeout_ns = harness.supervisor.routes.definition(lane_harness.default_definition).settings.limits.timeoutNs();
    try std.testing.expectEqual(slot.admitted_ns + timeout_ns, slot.deadline_ns);
    try std.testing.expectEqual(slot.deadline_ns, request.deadline_monotonic_ns);
    try std.testing.expectEqual(slot.admitted_ns, slot.access.started_mono_ns);
}

/// A HEADERS frame with END_HEADERS and the END_STREAM flag `end_stream`,
/// carrying `block` whole, into `out`, which holds exactly the frame.
fn encodeHeadersFrame(out: []u8, stream_id: u32, end_stream: bool, block: []const u8) !void {
    std.debug.assert(out.len == h2.frame_header_len + block.len);
    try (h2.FrameHeader{
        .length = @intCast(block.len),
        .frame_type_raw = @intFromEnum(h2.FrameType.headers),
        .frame_type = .headers,
        .flags = .{ .end_stream = end_stream, .end_headers_or_ack = true },
        .stream_id = stream_id,
    }).encode(out[0..h2.frame_header_len]);
    @memcpy(out[h2.frame_header_len..], block);
}
