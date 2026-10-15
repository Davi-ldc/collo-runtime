//! The socket operations a whole ingress lane (`lane_harness.zig`) spends on
//! a request, and the bounds it keeps while it spends fewer: a connection is
//! read only while no read poll of it is in flight, and a read that leaves
//! room in the read buffer arms the poll instead of reading again
//! (`http2/connection.zig`); a worker's reader stops draining its control
//! socket after the packet that leaves the worker owing no `request_done`
//! (`runner/worker_control.zig`); the frames a pass queues for a connection
//! leave in one write, with the receive credit the connection owes at its
//! tail, while a response larger than the socket takes still leaves in
//! parts, whole and in order (`http2/writing.zig`). Each test pins one saving
//! against the behavior it replaced, by what the client, the worker or the
//! lane can see. Lane `server-ingress-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const lane_harness = @import("lane_harness.zig");

const OneWorker = lane_harness.OneWorker;
const read_interest = lane_harness.runner.event_sources.read_interest;

test "a connection's turn reads nothing while its read poll is in flight, and the poll's completion reads what came" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    // The read that took the client's preface and SETTINGS left room in the
    // read buffer, so the connection waits on its read poll.
    const runtime = harness.lane(0).connections.get(scene.client.slot) orelse return error.ConnectionGone;
    try std.testing.expect(runtime.registered_wait_events & read_interest != 0);

    // A turn queued for the connection, as a request's finish or a worker's
    // response queues one, leaves the client's request on the socket.
    try scene.client.get(1);
    try harness.runConnectionTurn(0, scene.client.slot);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expect(!try scene.stub.controlReadable());

    // The poll's completion reads it.
    try scene.client.drive();
    const request = try scene.stub.readRequestBegin();
    try std.testing.expectEqual(@as(u32, 1), request.stream_id);
}

test "a read that leaves room in the read buffer arms the read poll, whose completion meets what the client did next" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;

    // The client sends a request and closes its side at once. The drive
    // reads the request and stops there: a second read in the same drive
    // would have met the close.
    try scene.client.get(1);
    try std.posix.shutdown(scene.client.fd, .send);
    try scene.client.drive();
    const request = try scene.stub.readRequestBegin();
    try std.testing.expectEqual(@as(u32, 1), request.stream_id);
    try std.testing.expect(scene.client.open());
    const runtime = harness.lane(0).connections.get(scene.client.slot) orelse return error.ConnectionGone;
    try std.testing.expect(runtime.registered_wait_events & read_interest != 0);

    // The poll completes at once for the close, which closes the connection.
    try scene.client.drive();
    try std.testing.expect(!scene.client.open());
}

test "a worker's head, body and end that one drain reads reach the client in one write" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const counters = &harness.lane(0).lane.counters;
    const request = try scene.get(1);
    const writes_before = counters.client_socket_writes;

    // The head, the body with END_STREAM and the request_done as three
    // packets, as a worker sends a response it streamed. One drain reads
    // them, and the connection's turn at the end of the pass writes them.
    try scene.stub.answer(request, 200, "hello");
    try harness.handleControl(0, scene.stub);
    try std.testing.expectEqual(writes_before + 1, counters.client_socket_writes);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try scene.expectStatus(1, 200);
    const stream = try scene.client.stream(1);
    try std.testing.expect(stream.ended);
    try std.testing.expectEqual(@as(usize, 5), stream.body_len);
    try std.testing.expectEqual(writes_before + 1, counters.client_socket_writes);
}

test "the receive credit a request's body left owed rides the write of the response" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const counters = &harness.lane(0).lane.counters;
    const runtime = harness.lane(0).connections.get(scene.client.slot) orelse return error.ConnectionGone;

    // The body reaches the worker and its credit is owed, far above half
    // the connection's window, so nothing is written for it alone.
    try scene.client.post(1, 5);
    try scene.client.data(1, "hello", true);
    try scene.client.drive();
    const request = try scene.stub.readRequestBegin();
    try std.testing.expectEqual(@as(u32, 5), runtime.h2_pending_connection_window_update);
    const writes_before = counters.client_socket_writes;

    // The worker's head, body and end in one packet, and the credit at the
    // tail of the write that carries them.
    try scene.stub.answerInOneBatch(request, 200, "ok", .{});
    try harness.handleControl(0, scene.stub);
    try std.testing.expectEqual(writes_before + 1, counters.client_socket_writes);
    try std.testing.expectEqual(@as(u32, 0), runtime.h2_pending_connection_window_update);
    try scene.expectStatus(1, 200);
    const stream = try scene.client.stream(1);
    try std.testing.expect(stream.ended);
    try std.testing.expectEqual(@as(usize, 2), stream.body_len);
}

test "a response larger than the socket takes reaches the client whole and in order, a part per write poll" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const counters = &harness.lane(0).lane.counters;
    const runtime = harness.lane(0).connections.get(scene.client.slot) orelse return error.ConnectionGone;
    // A small send buffer on the lane's end of the client's socket, so one
    // write takes only part of what the queue offers.
    const send_buffer_bytes: c_int = 4096;
    try std.posix.setsockopt(runtime.fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&send_buffer_bytes));
    // The connection's window takes the whole body; the stream's already
    // does.
    var increment: [4]u8 = undefined;
    std.mem.writeInt(u32, &increment, 1024 * 1024, .big);
    try scene.client.writeFrame(.window_update, 0, 0, &increment);
    const request = try scene.get(1);
    const writes_before = counters.client_socket_writes;

    // Three chunks of the largest size through the worker's ring, each byte
    // set by its offset in the body.
    const chunk_bytes = limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES;
    const body = try std.testing.allocator.alloc(u8, 3 * chunk_bytes);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*byte, offset|
        byte.* = @truncate(offset *% 31 +% offset / 251);
    try scene.stub.sendHead(request, 200, false);
    for (0..3) |index|
        try scene.stub.sendRingChunk(request, body[index * chunk_bytes ..][0..chunk_bytes], index == 2);
    try scene.stub.sendDone(request, .{});

    // Each round lets the lane read the worker as far as the client's
    // connection takes more, then the client reads, and the write poll's
    // drive writes the next part.
    var rounds: usize = 0;
    while (!(try scene.client.stream(1)).ended) : (rounds += 1) {
        if (rounds == 1024)
            return error.ResponseNeverEnded;
        try harness.drainControl(0, scene.stub);
        try scene.client.collect();
    }
    try std.testing.expect(rounds > 1);
    try std.testing.expect(counters.client_socket_writes - writes_before > 3);
    const stream = try scene.client.stream(1);
    try std.testing.expectEqual(@as(?u16, 200), stream.status);
    try std.testing.expectEqual(body.len, stream.body_len);
    try std.testing.expectEqual(std.hash.Fnv1a_64.hash(body), stream.body_digest.value);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try harness.expectServing(scene.stub);
}

test "a reader stops draining a worker after the packet that leaves it owing no request_done, and its re-armed poll reads the rest" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;
    const request = try scene.get(1);

    // The worker answers its only request, then asks to be retired.
    try scene.stub.answerInOneBatch(request, 200, "ok", .{});
    const notice = ipc.WorkerRetiring.init(.vm_terminated);
    try scene.stub.sendControlBytes(std.mem.asBytes(&notice));

    // One drain ends the request, then stops before a receive: the notice
    // waits in the socket.
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(1, 200);
    try std.testing.expect(harness.requestKeyOf(scene.client, 1) == null);
    try std.testing.expectEqual(@as(u64, 0), harness.lane(0).lane.counters.retirement_notices);
    try std.testing.expect(try scene.stub.sentUnread());

    // The drain armed the read poll again, and its completion reads it.
    try harness.handleControl(0, scene.stub);
    try std.testing.expectEqual(@as(u64, 1), harness.lane(0).lane.counters.retirement_notices);
    try std.testing.expect(!try scene.stub.sentUnread());
}
