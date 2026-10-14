//! Worker faults on an ingress lane: every input from a worker the lane must
//! refuse, from a malformed control datagram to a `request_done` that fails
//! to decode, names a request it was never sent, one whose begin never left,
//! another stream, or another worker's request on the same lane (whose
//! victim keeps its request and its record), or a corrupt payload ring, and
//! a worker that dies while its client uploads; and, set against them, the
//! notice of a worker that asks to be retired, which ends no request and is
//! no fault unless it is malformed. The lane marks the worker dead with the
//! reason `fault.WorkerFaultReason` names, answers each of its requests in
//! flight with 502, or resets a stream whose response head went out, queues
//! the worker's retirement to the reaper, and keeps serving: no handler
//! returns an error and nothing asks the server to stop. A send to a worker
//! that would block is backpressure and never a fault. Lane
//! `server-ingress-test`, through `lane_harness.zig`; the classification
//! tables are pinned in `fault.zig`, and real workers dying mid-upload run
//! in `local-e2e`.

const std = @import("std");
const ipc = @import("collo_ipc");
const lane_harness = @import("lane_harness.zig");

const ingress_channel = lane_harness.ingress_channel;
const OneWorker = lane_harness.OneWorker;

/// Body bytes of the upload tests, each a byte of a pattern a test checks in
/// order on the worker's side.
fn patternByte(index: usize) u8 {
    return @truncate(index % 251);
}

fn fillPattern(bytes: []u8, start: usize) void {
    for (bytes, start..) |*byte, index| byte.* = patternByte(index);
}

test "a control packet shorter than its message kind faults its worker and the lane keeps serving (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    try scene.stub.sendControlBytes(&.{ 0x0b, 0x00 });
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.packet_short);

    // The connection and the lane serve the next stream: with the only worker
    // out of service, the request waits and asks the launcher for one.
    try scene.client.get(3);
    try scene.client.drive();
    try scene.harness.expectLanesRunning();
    try std.testing.expectEqual(@as(usize, 1), scene.harness.launcher.submission_count);
    try std.testing.expectEqual(.waiter, scene.harness.launcher.submissions[0].reason);
}

test "a control packet of an unknown message kind faults its worker (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    // 999 names no `ipc.MessageKind`.
    var packet: [16]u8 = @splat(0);
    std.mem.writeInt(u32, packet[0..4], 999, .little);
    try scene.stub.sendControlBytes(&packet);
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.unknown_kind);
}

test "a control datagram with 31 descriptors faults its worker and leaves no descriptor open (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    const descriptors_before = try lane_harness.openDescriptorCount();
    var packet: [16]u8 = @splat(0);
    std.mem.writeInt(u32, packet[0..4], @intFromEnum(@import("collo_ipc").MessageKind.ingress_channel), .little);
    try scene.stub.sendControlWithDescriptors(&packet, lane_harness.raw_descriptors_max);
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.too_many_descriptors);
    // The receive truncated the descriptors and closed the ones it was given.
    try std.testing.expectEqual(descriptors_before, try lane_harness.openDescriptorCount());
}

test "a zero-length datagram with descriptors faults its worker and leaves the descriptor count unchanged (#35)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    const descriptors_before = try lane_harness.openDescriptorCount();
    try scene.stub.sendControlWithDescriptors("", 3);
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.zero_length_datagram_with_descriptors);
    try std.testing.expectEqual(descriptors_before, try lane_harness.openDescriptorCount());
}

test "a request_begin-shaped packet that carries a descriptor faults its worker (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // A well-formed descriptor naming the live request, with one descriptor
    // attached: no packet from a worker carries one.
    var scratch: [256]u8 = undefined;
    const packet = try ingress_channel.encodeDescriptorInto(
        &scratch,
        ingress_channel.Descriptor.requestBegin(request.identity, request.stream_id, 0, 0, 0, true),
    );
    try scene.stub.sendControlWithDescriptors(packet, 1);
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.unexpected_descriptor);
}

test "a request_done whose record fails to decode faults its worker" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // A payload one byte short of a `RequestDonePayload`.
    var short: [@sizeOf(ingress_channel.RequestDonePayload) - 1]u8 = @splat(0);
    try scene.stub.sendRawDone(request, &short);
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.ingress_channel_undecodable);
}

test "a request_done with a status the vocabulary does not name faults its worker" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    var payload = ingress_channel.encodeRequestDone((lane_harness.Done{}).record());
    payload.status = 200;
    try scene.stub.sendRawDone(request, std.mem.asBytes(&payload));
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.ingress_channel_undecodable);
}

test "a request_done naming a request its worker was never sent faults the worker" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // The live request's key under another request id.
    var forged = request;
    forged.identity.request_id +%= 1000;
    try scene.stub.sendDone(forged, .{});
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.descriptor_names_no_request);
}

test "a request_done naming its request's identity on another stream faults its worker" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    var forged = request;
    forged.stream_id += 2;
    try scene.stub.sendDone(forged, .{});
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.descriptor_names_no_request);
}

test "a request_done naming a request whose begin never left faults its worker" {
    var scene: OneWorker = undefined;
    // The kernel doubles the value: 128 KiB in flight before a send would
    // block, above the largest packet the lane sends.
    try scene.init(.{ .control_send_buffer_bytes = 64 * 1024 });
    defer scene.deinit();
    const harness = &scene.harness;

    // An upload the worker does not read fills its control socket, so the
    // next request's begin waits in the lane.
    const frame_bytes: usize = 16 * 1024;
    const frame_count: usize = 24;
    _ = try scene.post(1, frame_bytes * frame_count);
    var frame: [frame_bytes]u8 = @splat('u');
    for (0..frame_count) |index| {
        try scene.client.data(1, &frame, index + 1 == frame_count);
        try scene.client.drive();
    }
    const parked_key = try scene.client.getAdmitted(3);
    const parked = harness.lane(0).requests.entries[parked_key.slot];
    try std.testing.expect(parked.dispatched());
    try std.testing.expect(!parked.begin_sent);

    // The worker names that request exactly, which only a worker that read
    // the lane's memory or guessed every field could.
    const guessed: lane_harness.Dispatched = .{
        .identity = .{
            .request_id = parked.request_id,
            .request_generation = parked_key.generation,
            .request_lane_id = parked_key.lane_id,
            .request_slot = parked_key.slot,
        },
        .stream_id = parked.ingress_channel_id,
        .body_follows = false,
        .deadline_monotonic_ns = parked.deadline_ns,
        .egress_token = ipc.egress_token.none,
        .worker_slot = parked.worker_slot,
    };
    try scene.stub.sendDone(guessed, .{ .http_status = 200 });
    try harness.handleControl(0, scene.stub);
    try harness.expectLanesRunning();
    try harness.expectFaulted(scene.stub, .descriptor_names_no_request);
    try scene.expectStatus(3, 502);
}

test "a request_done naming another worker's request on the same lane faults its sender and leaves the victim's request and record to the victim" {
    var harness: lane_harness.Harness = undefined;
    try harness.init(std.testing.allocator, .{ .routes = .{ .concurrency = 1 } });
    defer harness.deinit();
    // The sender's only slot goes to the first request; the victim, published
    // next, serves the second. One lane reads both.
    const sender = try harness.publishWorker(.{});
    const client = try harness.connect(0, .{});
    try client.get(1);
    try client.drive();
    _ = try sender.readRequestBegin();
    const victim = try harness.publishWorker(.{});
    try client.get(3);
    try client.drive();
    const target = try victim.readRequestBegin();

    // The sender names the victim's request exactly: only the worker key the
    // lane holds for the request tells the two workers apart.
    try sender.sendDone(target, .{ .http_status = 200, .cpu_ns = 99 });
    try harness.handleControl(0, sender);
    try expectSenderFaultedVictimUntouched(&harness, client, sender, victim);

    try victim.respond(target, 201, "victim");
    try victim.sendDone(target, .{ .http_status = 201, .cpu_ns = 7 });
    try harness.handleControl(0, victim);
    try expectVictimRecord(&harness, client, victim, 7);
}

test "a response head naming another worker's request on the same lane faults its sender and leaves the victim's stream to the victim" {
    var harness: lane_harness.Harness = undefined;
    try harness.init(std.testing.allocator, .{ .routes = .{ .concurrency = 1 } });
    defer harness.deinit();
    const sender = try harness.publishWorker(.{});
    const client = try harness.connect(0, .{});
    try client.get(1);
    try client.drive();
    _ = try sender.readRequestBegin();
    const victim = try harness.publishWorker(.{});
    try client.get(3);
    try client.drive();
    const target = try victim.readRequestBegin();

    try sender.sendHead(target, 200, true);
    try harness.handleControl(0, sender);
    try expectSenderFaultedVictimUntouched(&harness, client, sender, victim);

    try victim.respond(target, 201, "victim");
    try victim.sendDone(target, .{ .http_status = 201, .cpu_ns = 7 });
    try harness.handleControl(0, victim);
    try expectVictimRecord(&harness, client, victim, 7);
}

/// The sender of output that names the victim's request on stream 3 is out
/// of service with its own request on stream 1 answered 502, and the
/// victim still serves stream 3, which got nothing yet.
fn expectSenderFaultedVictimUntouched(
    harness: *lane_harness.Harness,
    client: *lane_harness.Client,
    sender: *const lane_harness.StubWorker,
    victim: *const lane_harness.StubWorker,
) !void {
    try harness.expectLanesRunning();
    try harness.expectFaulted(sender, .descriptor_names_no_request);
    try client.expectStatus(1, 502);
    const sender_record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(sender.key.worker_id, sender_record.facts.worker_id);
    try harness.expectServing(victim);
    try std.testing.expect(harness.requestKeyOf(client, 3) != null);
    try client.collect();
    try std.testing.expectEqual(@as(?u16, null), (try client.stream(3)).status);
    try std.testing.expect(harness.takeAccessRecord(0) == null);
}

/// The victim's own answer reaches stream 3, and its request's record
/// carries the victim's identity and the CPU it reported, `cpu_ns`.
fn expectVictimRecord(
    harness: *lane_harness.Harness,
    client: *lane_harness.Client,
    victim: *const lane_harness.StubWorker,
    cpu_ns: u64,
) !void {
    try client.expectStatus(3, 201);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(@as(u16, 201), record.status);
    try std.testing.expectEqual(victim.key.worker_id, record.facts.worker_id);
    const usage = record.usage orelse return error.UsageMissing;
    try std.testing.expectEqual(cpu_ns, usage.cpu_ns);
    try harness.expectServing(victim);
}

test "a request_done naming a lane the server does not have faults its worker" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    var forged = request;
    forged.identity.request_lane_id = 9;
    try scene.stub.sendDone(forged, .{});
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.descriptor_names_no_request);
}

test "a response head shorter than its payload header faults its worker (#46)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // A response head payload starts with an 8-byte status and count header,
    // so 7 bytes cannot hold one.
    try scene.stub.sendRawHead(request, &.{ 1, 2, 3, 4, 5, 6, 7 });
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.response_head_invalid);
}

test "a server-to-worker read cursor above its write cursor faults the worker on the next ring chunk (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();

    // Above `shared_payload_threshold`, so the chunk travels in the ring.
    const body_len = ingress_channel.shared_payload_threshold + 8 * 1024;
    const request = try scene.post(1, body_len);
    try std.testing.expect(request.body_follows);
    scene.stub.corruptServerToWorkerRing();

    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);
    fillPattern(body, 0);
    try scene.client.data(1, body, true);
    try scene.client.drive();
    try scene.expectFaultAnswered(.payload_ring_invalid);
}

test "a body upload against a full control socket waits behind the writability poll and arrives in order (#34)" {
    var scene: OneWorker = undefined;
    // The kernel doubles the value: 128 KiB in flight before a send would
    // block, above the largest packet the lane sends.
    try scene.init(.{ .control_send_buffer_bytes = 64 * 1024 });
    defer scene.deinit();

    const frame_bytes: usize = 16 * 1024;
    const frame_count: usize = 24;
    const body_len = frame_bytes * frame_count;
    const request = try scene.post(1, body_len);

    var frame: [frame_bytes]u8 = undefined;
    for (0..frame_count) |index| {
        fillPattern(&frame, index * frame_bytes);
        try scene.client.data(1, &frame, index + 1 == frame_count);
        try scene.client.drive();
    }
    // The worker read nothing yet, so the control socket filled long before
    // the whole body went out, and the lane kept the rest.
    try scene.harness.expectLanesRunning();
    try scene.harness.expectServing(scene.stub);

    const received = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(received);
    var body: lane_harness.Body = .{};
    try scene.stub.readBody(request, received, &body);
    try std.testing.expect(body.len < body_len);

    // Each time the worker drains its socket, the lane's writability handler
    // sends what waited, in order.
    var rounds: usize = 0;
    while (!body.ended) : (rounds += 1) {
        if (rounds == frame_count)
            return error.UploadDidNotComplete;
        try scene.harness.handleControlWritable(0, scene.stub);
        try scene.stub.readBody(request, received, &body);
    }
    try std.testing.expectEqual(body_len, body.len);
    for (received, 0..) |byte, index|
        try std.testing.expectEqual(patternByte(index), byte);
    try scene.harness.expectLanesRunning();
    try scene.harness.expectServing(scene.stub);
}

test "a send fault on a lane that only sends to its worker takes the worker out of service even when a forwarded request_done ends the request in the same pass" {
    var scene: lane_harness.TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    // Lane 0's request makes lane 0 the worker's reader; lane 1 only sends
    // to the worker.
    _ = try scene.get(scene.first, 1);
    const body_len = ingress_channel.shared_payload_threshold + 8 * 1024;
    try scene.second.post(1, body_len);
    try scene.second.drive();
    const upload = try scene.stub.readRequestBegin();

    // The worker answers the upload before it reads the body, and lane 0
    // forwards the response and its `request_done` to lane 1.
    try scene.stub.answer(upload, 200, "early");
    try harness.handleControl(0, scene.stub);
    try harness.expectQueued(1, &.{ .forwarded_descriptor, .forwarded_descriptor, .forwarded_request_done });

    // One pass of lane 1: the body chunk meets a corrupt ring, a fault the
    // send defers, and then the forwarded `request_done` ends the request.
    scene.stub.corruptServerToWorkerRing();
    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);
    fillPattern(body, 0);
    try scene.second.data(1, body, true);
    const lane = harness.lane(1);
    try harness.discardPollCompletions(1);
    try harness.handleReadable(1, scene.second.slot);
    try lane.handleCommands();
    try harness.finishPass(1);
    try scene.second.expectStatus(1, 200);

    // The fault outlived the request: the worker is out of service, and lane
    // 0, which holds a slot of it and reads it, is told.
    try harness.expectLanesRunning();
    try std.testing.expectEqual(lane_harness.pool.EntryState.dead, harness.workerView(scene.stub).?.state);
    try std.testing.expect(harness.registration(1, scene.stub) == null);
    try harness.expectQueued(0, &.{.worker_died});
    try harness.handleCommands(0);
    try scene.first.expectStatus(1, 502);
    try harness.expectFaulted(scene.stub, .payload_ring_invalid);
}

test "two lanes whose bodies wait on one worker's full payload ring both send once the worker frees room, woken by its reader and polling nothing" {
    var scene: lane_harness.TwoLanes = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    // Each chunk is above the inline threshold, so it rides in the
    // server-to-worker ring, and the worker reads nothing until the ring is
    // full.
    const chunk_bytes = ingress_channel.shared_payload_threshold + 16 * 1024;
    const content_length = 64 * chunk_bytes;
    const chunk = try std.testing.allocator.alloc(u8, chunk_bytes);
    defer std.testing.allocator.free(chunk);
    fillPattern(chunk, 0);
    try scene.first.post(1, content_length);
    try scene.first.drive();
    const first = try scene.stub.readRequestBegin();
    try scene.second.post(1, content_length);
    try scene.second.drive();
    _ = try scene.stub.readRequestBegin();
    const first_key = harness.requestKeyOf(scene.first, 1) orelse return error.RequestNotAdmitted;
    const second_key = harness.requestKeyOf(scene.second, 1) orelse return error.RequestNotAdmitted;

    // Lane 0 streams until a chunk waits on the full ring, and lane 1's
    // first chunk finds it full too.
    var chunks_sent: usize = 0;
    while (harness.lane(0).requests.entries[first_key.slot].send_blocked != .ring) : (chunks_sent += 1) {
        if (chunks_sent == 64)
            return error.RingNeverFilled;
        try scene.first.data(1, chunk, false);
        try scene.first.drive();
    }
    try scene.second.data(1, chunk, false);
    try scene.second.drive();
    try std.testing.expect(harness.lane(1).requests.entries[second_key.slot].send_blocked == .ring);

    // The worker reads what lane 0 sent. The lanes marked the ring waiting,
    // so the release writes the worker's completion eventfd, the one its
    // reader, lane 0, polls already; nothing writes the credit eventfd.
    const received = try std.testing.allocator.alloc(u8, content_length);
    defer std.testing.allocator.free(received);
    var body: lane_harness.Body = .{};
    try scene.stub.readBody(first, received, &body);
    try std.testing.expect(!try scene.stub.creditSignalled());

    // The reader's ring credit wake raises both lanes' credit wake, and each
    // lane's next command wake retries its body. No client byte moves.
    try harness.handleRingCredit(0, scene.stub);
    try harness.handleCommands(0);
    try harness.handleCommands(1);
    try std.testing.expect(harness.lane(0).requests.entries[first_key.slot].send_blocked == .none);
    try std.testing.expect(harness.lane(1).requests.entries[second_key.slot].send_blocked == .none);
    try std.testing.expectEqual(@as(u64, 1), harness.lane(0).lane.counters.h2_request_body_credit_wakes);
    try std.testing.expectEqual(@as(u64, 1), harness.lane(1).lane.counters.h2_request_body_credit_wakes);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}

test "a worker dying mid-upload is answered 502 and the lane keeps serving (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();

    const chunk_bytes: usize = 16 * 1024;
    const request = try scene.post(1, 2 * chunk_bytes);
    var chunk: [chunk_bytes]u8 = undefined;
    fillPattern(&chunk, 0);
    try scene.client.data(1, &chunk, false);
    try scene.client.drive();
    var received: [2 * chunk_bytes]u8 = undefined;
    var body: lane_harness.Body = .{};
    try scene.stub.readBody(request, &received, &body);
    try std.testing.expectEqual(chunk_bytes, body.len);

    // The process goes and the kernel closes its end of the control socket,
    // so the next chunk meets a hung-up peer.
    try scene.stub.kill();
    scene.stub.closeControl();
    fillPattern(&chunk, chunk_bytes);
    try scene.client.data(1, &chunk, true);
    try scene.client.drive();

    try scene.harness.expectLanesRunning();
    try scene.harness.expectFaulted(scene.stub, null);
    const reason = scene.harness.reaper.retirementOf(scene.stub.key).?.fault_reason;
    try std.testing.expect(reason == .peer_closed or reason == .exited);
    try scene.expectStatus(1, 502);
}

test "a worker fault answers its requests 502 and resets a stream whose response head went out" {
    var scene: OneWorker = undefined;
    try scene.init(.{ .concurrency = 2 });
    defer scene.deinit();
    const committed = try scene.get(1);
    _ = try scene.get(3);

    try scene.stub.sendHead(committed, 200, false);
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 200);

    try scene.stub.sendControlBytes(&.{0x0b});
    try scene.harness.handleControl(0, scene.stub);
    try scene.harness.expectLanesRunning();
    try scene.harness.expectFaulted(scene.stub, .packet_short);
    // The lane's own record says stream 1's head went out, so a second head
    // would be a protocol error: it resets the stream instead.
    try scene.expectReset(1);
    try scene.expectStatus(3, 502);
}

test "a dead worker's buffered response tail without END_STREAM gets RST_STREAM (#42)" {
    var scene: OneWorker = undefined;
    // A 16-byte stream window keeps all but 16 bytes of the chunk buffered
    // in the lane.
    try scene.init(.{ .initial_window_size = 16 });
    defer scene.deinit();
    const request = try scene.get(1);

    var chunk: [1024]u8 = undefined;
    fillPattern(&chunk, 0);
    try scene.stub.sendHead(request, 200, false);
    try scene.stub.sendChunk(request, &chunk, false);
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 200);

    try scene.stub.kill();
    try scene.harness.handleWorkerExit(0, scene.stub);
    try scene.harness.expectLanesRunning();
    try scene.harness.expectFaulted(scene.stub, .exited);
    // The buffered tail can never end the stream, so draining it is no
    // answer: the stream is reset.
    try scene.expectReset(1);
    const received = try scene.client.stream(1);
    try std.testing.expect(!received.ended);
}

test "a request_done sent before the worker died wins over the death" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // The whole response and its `request_done` are out before the process
    // exits, and the lane has read neither yet.
    try scene.stub.answer(request, 201, "made");
    try scene.stub.kill();
    try scene.harness.handleWorkerExit(0, scene.stub);

    try scene.harness.expectLanesRunning();
    try scene.harness.expectFaulted(scene.stub, .exited);
    try scene.expectStatus(1, 201);
    const received = try scene.client.stream(1);
    try std.testing.expect(received.ended);
    try std.testing.expectEqual(@as(?u16, 201), scene.harness.takeAccessStatus(0));
}

test "a request_done behind corrupt output loses to the death" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // The control socket shows the worker is corrupt before its
    // `request_done`, and nothing a corrupt worker wrote after that is read.
    try scene.stub.sendControlBytes(&.{0x0b});
    try scene.stub.sendDone(request, .{ .http_status = 200 });
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.packet_short);
}

test "a worker_retiring packet that names no reason faults its worker" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    var notice = ipc.WorkerRetiring.init(.vm_terminated);
    notice.reason = 9;
    try scene.stub.sendControlBytes(std.mem.asBytes(&notice));
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.retiring_notice_invalid);
}

test "a worker_retiring packet takes its worker out of service without failing the request it holds, and the worker retires once that request ends" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const held = try scene.get(1);

    const notice = ipc.WorkerRetiring.init(.vm_terminated);
    try scene.stub.sendControlBytes(std.mem.asBytes(&notice));
    try harness.handleControl(0, scene.stub);

    // Out of service with no death: no request failed, nothing is retired
    // while a slot is held, and the next request waits for another worker.
    try harness.expectLanesRunning();
    const retiring = harness.workerView(scene.stub) orelse return error.WorkerLeftThePool;
    try std.testing.expectEqual(lane_harness.pool.EntryState.retiring, retiring.state);
    try std.testing.expectEqual(@as(usize, 0), harness.reaper.retirementsOf(scene.stub.key));
    try std.testing.expectEqual(@as(u64, 1), harness.lane(0).lane.counters.retirement_notices);
    const waiting = try scene.client.getAdmitted(3);
    try std.testing.expect(harness.lane(0).requests.entries[waiting.slot].waiting());

    // The worker keeps answering what it holds.
    try scene.stub.answer(held, 200, "after the notice");
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 200);
    try std.testing.expectEqual(@as(?u16, 200), harness.takeAccessStatus(0));

    // Its last slot is back: its reader, this lane, gives the role up
    // through its own queue, and the reaper retires it as recycled.
    try harness.handleCommands(0);
    const retirement = harness.reaper.retirementOf(scene.stub.key) orelse return error.TestExpectedRetirement;
    try std.testing.expectEqual(lane_harness.RetireReason.recycled, retirement.reason);
    try std.testing.expectEqual(@as(?lane_harness.fault.WorkerFaultReason, null), retirement.fault_reason);
}
