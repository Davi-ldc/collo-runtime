//! The socket operations a whole ingress lane (`lane_harness.zig`) spends on
//! a request, and the bounds it keeps while it spends fewer: a connection is
//! read only while no read poll of it is in flight, and a read that leaves
//! room in the read buffer arms the poll instead of reading again
//! (`http2/connection.zig`); a worker's reader stops draining its control
//! socket after the packet that leaves the worker owing no `request_done`
//! (`runner/worker_control.zig`). Each test pins one saving against the
//! behavior it replaced, by what the client, the worker or the lane can see.
//! Lane `server-ingress-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
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
