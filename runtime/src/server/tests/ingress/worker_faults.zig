//! Worker faults on an ingress lane: every input from a worker the lane must
//! refuse, from a malformed control or fault datagram to a corrupt completion
//! ring or payload ring, and a worker that dies while its client uploads. The
//! lane marks the worker dead with the reason `fault.WorkerFaultReason` names,
//! answers each of its requests in flight with 502, or resets a stream whose
//! response head went out, queues the worker's retirement to the reaper, and
//! keeps serving: no handler returns an error and nothing asks the server to
//! stop. A send to a worker that would block is backpressure and never a
//! fault. Lane `server-ingress-test`, through `lane_harness.zig`; the
//! classification tables are pinned in `fault.zig`, and real workers dying
//! mid-upload run in `local-e2e`.

const std = @import("std");
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

test "a fault datagram with 31 descriptors faults its worker (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    const descriptors_before = try lane_harness.openDescriptorCount();
    var packet: [32]u8 = @splat(0);
    std.mem.writeInt(u32, packet[0..4], @intFromEnum(@import("collo_ipc").MessageKind.fs_fault_request), .little);
    try scene.stub.sendFaultWithDescriptors(&packet, lane_harness.raw_descriptors_max);
    try scene.harness.handleFsFault(0, scene.stub);
    try scene.expectFaultAnswered(.too_many_descriptors);
    try std.testing.expectEqual(descriptors_before, try lane_harness.openDescriptorCount());
}

test "a completion ring the worker marked fatal faults its worker (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    try scene.stub.markCompletionRingFatal();
    try scene.harness.handleCompletions(0, scene.stub);
    try scene.expectFaultAnswered(.completion_ring_fatal);
}

test "a completion ring found fatal in the final drain of a dead worker leaves the lane serving (#34)" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    _ = try scene.get(1);

    try scene.stub.markCompletionRingFatal();
    try scene.stub.kill();
    try scene.harness.handleWorkerExit(0, scene.stub);
    // The exit is the fault; the corrupt ring the final drain meets ends that
    // drain and nothing more.
    try scene.expectFaultAnswered(.exited);
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

test "a send fault on a lane that only sends to its worker takes the worker out of service even when a forwarded completion ends the request in the same pass" {
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
    // forwards the response and the completion to lane 1.
    try scene.stub.answer(upload, 200, "early");
    try harness.serveWorker(0, scene.stub);
    try harness.expectQueued(1, &.{ .forwarded_descriptor, .forwarded_descriptor, .forwarded_completion });

    // One pass of lane 1: the body chunk meets a corrupt ring, a fault the
    // send defers, and then the forwarded completion ends the request.
    scene.stub.corruptServerToWorkerRing();
    const body = try std.testing.allocator.alloc(u8, body_len);
    defer std.testing.allocator.free(body);
    fillPattern(body, 0);
    try scene.second.data(1, body, true);
    const lane = harness.lane(1);
    try harness.discardPollCompletions(1);
    try lane.handleConnectionReadable(scene.second.slot);
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

    // The reader's completion wake raises both lanes' credit wake, and each
    // lane's next command wake retries its body. No client byte moves.
    try harness.handleCompletions(0, scene.stub);
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

test "a completion published before the worker died wins over the death" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // The whole response and its completion are out before the process
    // exits, and the lane has read neither yet.
    try scene.stub.respond(request, 201, "made");
    try scene.stub.publishCompletion(request, .{ .http_status = 201 });
    try scene.stub.kill();
    try scene.harness.handleWorkerExit(0, scene.stub);

    try scene.harness.expectLanesRunning();
    try scene.harness.expectFaulted(scene.stub, .exited);
    try scene.expectStatus(1, 201);
    const received = try scene.client.stream(1);
    try std.testing.expect(received.ended);
    try std.testing.expectEqual(@as(?u16, 201), scene.harness.takeAccessStatus(0));
}

test "after corrupt output a published completion loses to the death" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);

    // A completion is in the ring, but the control socket shows the worker
    // is corrupt first, and nothing a corrupt worker wrote is applied.
    try scene.stub.publishCompletion(request, .{ .http_status = 200 });
    try scene.stub.sendControlBytes(&.{0x0b});
    try scene.harness.handleControl(0, scene.stub);
    try scene.expectFaultAnswered(.packet_short);
}
