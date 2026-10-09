//! The client connections of a whole ingress lane (`lane_harness.zig`): far
//! more of them at once than the lane once kept frame buffers for, each
//! holding part of a frame between its reads; the stream and request tables
//! refusing a stream with REFUSED_STREAM once full while the connection goes
//! on; and the one deadline each connection has
//! (`runner/deadline_driver.zig`): pre-request from the accept until the
//! first stream, answered or refused, none while a stream serves a request,
//! idle while none does, which any new stream restarts, and stall while the
//! lane holds something of it that only the client can move, a close's
//! GOAWAY flush included and an open header block even while requests run.
//! A request that ends outside any drive leaves its connection under the
//! deadline its state then calls for. A
//! deadline test sweeps the lane at a time it picks, so none waits for the
//! deadline to pass on the clock. Lane `server-ingress-test`.

const std = @import("std");
const h2 = @import("collo_http").http2;
const lane_harness = @import("lane_harness.zig");

const Harness = lane_harness.Harness;
const connection_slot = lane_harness.runner.connection_slot;

/// How long each shortened connection deadline runs in these tests. A sweep
/// names its own time, so the value only needs to stay far from the
/// requests' deadlines.
const short_timeout_ns: u64 = 50 * std.time.ns_per_ms;

const ping_payload = "pingpong";

/// PING frames a test sends per read, under the read's frame budget
/// (`limits.ingress.budgeted_frames_per_read_max`).
const pings_per_batch = 100;

/// A path under the server's reserved prefix that it does not serve, which
/// the lane answers 404 within the drive that reads it.
const unserved_path = "/__collo/none";

fn pingFrame(flags: h2.Flags) [h2.frame_header_len + ping_payload.len]u8 {
    var frame: [h2.frame_header_len + ping_payload.len]u8 = undefined;
    (h2.FrameHeader{
        .length = ping_payload.len,
        .frame_type_raw = @intFromEnum(h2.FrameType.ping),
        .frame_type = .ping,
        .flags = flags,
        .stream_id = 0,
    }).encode(frame[0..h2.frame_header_len]) catch unreachable;
    @memcpy(frame[h2.frame_header_len..], ping_payload);
    return frame;
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len)
        written += try std.posix.write(fd, bytes[written..]);
}

/// Reads what the lane wrote on `fd` and checks that it holds the
/// acknowledgement of the test's PING.
fn expectPingAck(fd: std.posix.fd_t) !void {
    var buffer: [1024]u8 = undefined;
    var len: usize = 0;
    while (len < buffer.len) {
        const read_len = std.posix.read(fd, buffer[len..]) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (read_len == 0) break;
        len += read_len;
    }
    var cursor: usize = 0;
    while (len - cursor >= h2.frame_header_len) {
        const header = try h2.FrameHeader.parse(buffer[cursor..][0..h2.frame_header_len]);
        const end = cursor + h2.frame_header_len + header.length;
        if (end > len) break;
        if (header.frame_type == .ping and header.flags.end_stream) {
            try std.testing.expectEqualStrings(ping_payload, buffer[cursor + h2.frame_header_len .. end]);
            return;
        }
        cursor = end;
    }
    return error.MissingPingAck;
}

test "a lane holds hundreds of connections at once, each keeping part of a frame between its reads" {
    const connection_count = 300;
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{});
    defer harness.deinit();
    var client_fds: [connection_count]std.posix.fd_t = undefined;
    var slots: [connection_count]u32 = undefined;
    var opened: usize = 0;
    defer for (client_fds[0..opened]) |fd| std.posix.close(fd);

    const empty_settings = [_]u8{ 0, 0, 0, @intFromEnum(h2.FrameType.settings), 0, 0, 0, 0, 0 };
    const ping = pingFrame(.{});
    // Inside the PING's frame header, which the next read completes.
    const cut = 5;
    while (opened < connection_count) : (opened += 1) {
        const connection = try harness.openConnectionSlot(0);
        client_fds[opened] = connection.client_fd;
        slots[opened] = connection.key.slot;
        try writeAllFd(connection.client_fd, h2.client_connection_preface);
        try writeAllFd(connection.client_fd, &empty_settings);
        try writeAllFd(connection.client_fd, ping[0..cut]);
        try harness.driveConnection(0, connection.key.slot);
    }
    try std.testing.expectEqual(@as(u32, connection_count), harness.lane(0).connections.live_count);

    for (client_fds, slots) |fd, slot| {
        try writeAllFd(fd, ping[cut..]);
        try harness.driveConnection(0, slot);
        try expectPingAck(fd);
    }
    try std.testing.expectEqual(@as(u32, connection_count), harness.lane(0).connections.live_count);
}

test "a stream past the lane's stream table is refused with REFUSED_STREAM, and the connection goes on" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{
        .routes = .{ .concurrency = 2 },
        .table_capacities = .{ .streams = 2 },
    });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const client = try harness.connect(0, .{});

    try client.get(1);
    try client.get(3);
    try client.get(5);
    try client.drive();
    const first = try stub.readRequestBegin();
    const second = try stub.readRequestBegin();
    try client.expectReset(5);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.refused_stream)), (try client.stream(5)).reset_code);
    try std.testing.expect(client.open());

    // An answered stream leaves the table, and the next one fits.
    try stub.answer(first, 200, "one");
    try harness.serveWorker(0, stub);
    try client.expectStatus(1, 200);
    try client.get(7);
    try client.drive();
    const third = try stub.readRequestBegin();
    try stub.answer(second, 200, "two");
    try stub.answer(third, 200, "three");
    try harness.serveWorker(0, stub);
    try client.expectStatus(3, 200);
    try client.expectStatus(7, 200);
    try harness.expectLanesRunning();
}

test "a stream past the lane's request table is refused with REFUSED_STREAM, and the connection goes on" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .table_capacities = .{ .requests = 1 } });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const client = try harness.connect(0, .{});

    try client.get(1);
    try client.get(3);
    try client.drive();
    const first = try stub.readRequestBegin();
    try client.expectReset(3);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.refused_stream)), (try client.stream(3)).reset_code);

    try stub.answer(first, 200, "one");
    try harness.serveWorker(0, stub);
    try client.expectStatus(1, 200);
    try client.get(5);
    try client.drive();
    const second = try stub.readRequestBegin();
    try stub.answer(second, 200, "two");
    try harness.serveWorker(0, stub);
    try client.expectStatus(5, 200);
    try harness.expectLanesRunning();
}

test "a connection that starts no request by its pre-request deadline gets GOAWAY NO_ERROR and closes, and one that started a request stays" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .connection_timeouts = .{ .pre_request_ns = short_timeout_ns } });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const silent = try harness.connect(0, .{});
    const started = try harness.connect(0, .{});
    try started.get(1);
    try started.drive();
    const request = try stub.readRequestBegin();
    const lane = harness.lane(0);

    // Nothing the client sends moves the deadline from its accept.
    const silent_deadline = lane.connections.get(silent.slot).?.accepted_ns + short_timeout_ns;
    try silent.writeFrame(.ping, 0, 0, ping_payload);
    try silent.drive();
    try harness.expireDeadlines(0, silent_deadline - 1);
    try std.testing.expect(silent.open());
    try harness.expireDeadlines(0, silent_deadline);
    try std.testing.expect(!silent.open());
    try silent.collect();
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.no_error)), silent.goaway_code);
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.pre_request_timeouts);

    const started_deadline = lane.connections.get(started.slot).?.accepted_ns + short_timeout_ns;
    try harness.expireDeadlines(0, started_deadline);
    try std.testing.expect(started.open());
    try stub.answer(request, 200, "ok");
    try harness.serveWorker(0, stub);
    try started.expectStatus(1, 200);
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.pre_request_timeouts);
}

test "a connection with no stream for its idle timeout gets GOAWAY NO_ERROR naming its last stream; only a new stream keeps it" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .connection_timeouts = .{ .idle_ns = short_timeout_ns } });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const client = try harness.connect(0, .{});
    const lane = harness.lane(0);

    try client.get(1);
    try client.drive();
    const first = try stub.readRequestBegin();
    try stub.answer(first, 200, "one");
    try harness.serveWorker(0, stub);
    try client.expectStatus(1, 200);
    const idle_since = lane.connections.get(client.slot).?.idle_since_ns orelse return error.ConnectionNotIdle;

    // PING moves bytes but opens no stream, so the deadline stays.
    try client.writeFrame(.ping, 0, 0, ping_payload);
    try client.drive();
    try std.testing.expectEqual(@as(?u64, idle_since), lane.connections.get(client.slot).?.idle_since_ns);
    try harness.expireDeadlines(0, idle_since + short_timeout_ns - 1);
    try std.testing.expect(client.open());

    // A stream in flight holds the connection past the deadline.
    try client.get(3);
    try client.drive();
    const second = try stub.readRequestBegin();
    try harness.expireDeadlines(0, idle_since + short_timeout_ns);
    try std.testing.expect(client.open());
    try stub.answer(second, 200, "two");
    try harness.serveWorker(0, stub);
    try client.expectStatus(3, 200);

    const idle_again = lane.connections.get(client.slot).?.idle_since_ns orelse return error.ConnectionNotIdle;
    try harness.expireDeadlines(0, idle_again + short_timeout_ns);
    try std.testing.expect(!client.open());
    try client.collect();
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.no_error)), client.goaway_code);
    try std.testing.expectEqual(@as(?u32, 3), client.goaway_last_stream_id);
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.idle_timeouts);
}

test "a connection that stops inside a frame for its stall timeout closes without GOAWAY, and each byte it sends restarts the timeout" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .connection_timeouts = .{ .stall_ns = short_timeout_ns } });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const client = try harness.connect(0, .{});
    const lane = harness.lane(0);

    // A first request ends the pre-request deadline, which would come first.
    try client.get(1);
    try client.drive();
    const first = try stub.readRequestBegin();
    try stub.answer(first, 200, "one");
    try harness.serveWorker(0, stub);
    try client.expectStatus(1, 200);

    const ping = pingFrame(.{});
    try client.writeAll(ping[0..4]);
    try client.drive();
    const first_progress = lane.connections.get(client.slot).?.last_progress_ns;
    try harness.expireDeadlines(0, first_progress + short_timeout_ns - 1);
    try std.testing.expect(client.open());

    // So the clock reads later at the next byte.
    std.Thread.sleep(std.time.ns_per_ms);
    try client.writeAll(ping[4..5]);
    try client.drive();
    const later_progress = lane.connections.get(client.slot).?.last_progress_ns;
    try std.testing.expect(later_progress > first_progress);
    try harness.expireDeadlines(0, first_progress + short_timeout_ns);
    try std.testing.expect(client.open());

    try harness.expireDeadlines(0, later_progress + short_timeout_ns);
    try std.testing.expect(!client.open());
    try client.collect();
    try std.testing.expectEqual(@as(?u32, null), client.goaway_code);
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.stall_timeouts);
}

test "a client that stops reading a response keeps its connection past the stall timeout while the request runs" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .connection_timeouts = .{ .stall_ns = short_timeout_ns } });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    // A 16-byte stream window holds the body in the lane until the client
    // grants more, as a client that stopped reading a stream does.
    const client = try harness.connect(0, .{ .initial_window_size = 16 });
    const lane = harness.lane(0);

    try client.get(1);
    try client.drive();
    const request = try stub.readRequestBegin();
    const chunk: [1024]u8 = @splat('b');
    try stub.sendHead(request, 200, false);
    try stub.sendChunk(request, &chunk, false);
    try harness.serveWorker(0, stub);
    const runtime = lane.connections.get(client.slot).?;
    try std.testing.expect(runtime.stalled());

    // The request's own deadline governs, so the stall timeout passing
    // leaves the connection and its request alone.
    try harness.expireDeadlines(0, runtime.last_progress_ns + short_timeout_ns);
    try std.testing.expect(client.open());
    try std.testing.expect(harness.requestKeyOf(client, 1) != null);
    try std.testing.expectEqual(@as(u64, 0), lane.lane.counters.stall_timeouts);

    // Once the client grants credit, the response ends as usual.
    try stub.sendChunk(request, "!", true);
    try stub.publishCompletion(request, .{});
    try harness.serveWorker(0, stub);
    var increment: [4]u8 = undefined;
    std.mem.writeInt(u32, &increment, 4096, .big);
    try client.writeFrame(.window_update, 0, 1, &increment);
    try client.drive();
    try client.expectStatus(1, 200);
    const received = try client.stream(1);
    try std.testing.expect(received.ended);
    try std.testing.expectEqual(@as(usize, chunk.len + 1), received.body_len);
    try std.testing.expect(client.open());
    try harness.expectLanesRunning();
}

test "a stream the lane answers within the drive that reads it ends the pre-request deadline and restarts the idle one" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .connection_timeouts = .{
        .pre_request_ns = short_timeout_ns,
        .idle_ns = short_timeout_ns,
    } });
    defer harness.deinit();
    const client = try harness.connect(0, .{});
    const lane = harness.lane(0);
    const accepted_ns = lane.connections.get(client.slot).?.accepted_ns;

    // A head refused before admission, for a body over the bound: 413 and
    // RST_STREAM NO_ERROR, since the client was still sending.
    try client.post(1, 5 * 1024 * 1024);
    try client.drive();
    try client.expectStatus(1, 413);
    try harness.expireDeadlines(0, accepted_ns + short_timeout_ns);
    try std.testing.expect(client.open());
    const idle_since = lane.connections.get(client.slot).?.idle_since_ns orelse return error.ConnectionNotIdle;

    // So the clock reads later at the next stream.
    std.Thread.sleep(std.time.ns_per_ms);
    try client.request(3, "GET", unserved_path, .{});
    try client.drive();
    try client.expectStatus(3, 404);
    const idle_again = lane.connections.get(client.slot).?.idle_since_ns orelse return error.ConnectionNotIdle;
    try std.testing.expect(idle_again > idle_since);
    try harness.expireDeadlines(0, idle_since + short_timeout_ns);
    try std.testing.expect(client.open());

    try harness.expireDeadlines(0, idle_again + short_timeout_ns);
    try std.testing.expect(!client.open());
    try client.collect();
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.no_error)), client.goaway_code);
    try std.testing.expectEqual(@as(?u32, 3), client.goaway_last_stream_id);
    try std.testing.expectEqual(@as(u64, 0), lane.lane.counters.pre_request_timeouts);
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.idle_timeouts);
}

test "a first stream the lane refuses with REFUSED_STREAM ends the pre-request deadline" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{
        .table_capacities = .{ .streams = 1 },
        .connection_timeouts = .{ .pre_request_ns = short_timeout_ns },
    });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const holder = try harness.connect(0, .{});
    const client = try harness.connect(0, .{});
    const lane = harness.lane(0);

    // The holder's request takes the lane's one stream entry.
    try holder.get(1);
    try holder.drive();
    const request = try stub.readRequestBegin();
    try client.get(1);
    try client.drive();
    try client.expectReset(1);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.refused_stream)), (try client.stream(1)).reset_code);

    const accepted_ns = lane.connections.get(client.slot).?.accepted_ns;
    try harness.expireDeadlines(0, accepted_ns + short_timeout_ns);
    try std.testing.expect(client.open());
    try std.testing.expectEqual(@as(u64, 0), lane.lane.counters.pre_request_timeouts);

    try stub.answer(request, 200, "held");
    try harness.serveWorker(0, stub);
    try holder.expectStatus(1, 200);
    try harness.expectLanesRunning();
}

test "a waiting request answered outside any drive leaves its connection under its idle deadline" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{
        .routes = .{ .concurrency = 1 },
        .connection_timeouts = .{ .idle_ns = short_timeout_ns },
    });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const holder = try harness.connect(0, .{});
    const client = try harness.connect(0, .{});
    const lane = harness.lane(0);

    try holder.get(1);
    try holder.drive();
    const request = try stub.readRequestBegin();
    // The worker's one slot is taken, so this request waits for it.
    _ = try client.getAdmitted(1);
    const waiting = harness.requestSlotOf(client, 1) orelse return error.RequestNotAdmitted;
    try std.testing.expect(waiting.waiting());

    // Two wheel ticks past the waiter's deadline, and long before the
    // holder's backstop: the deadline sweep answers 503 with no drive of
    // the connection.
    try harness.expireDeadlines(0, waiting.deadline_ns + 10 * std.time.ns_per_ms);
    try std.testing.expect(harness.requestKeyOf(client, 1) == null);
    const runtime = lane.connections.get(client.slot).?;
    const deadline = runtime.deadline orelse return error.NoConnectionDeadline;
    try std.testing.expectEqual(connection_slot.DeadlineKind.idle, deadline.kind);
    const idle_since = runtime.idle_since_ns orelse return error.ConnectionNotIdle;

    try harness.expireDeadlines(0, idle_since + short_timeout_ns);
    try std.testing.expect(!client.open());
    try client.collect();
    try client.expectStatus(1, 503);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.no_error)), client.goaway_code);
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.idle_timeouts);

    try stub.answer(request, 200, "held");
    try harness.serveWorker(0, stub);
    try holder.expectStatus(1, 200);
    try harness.expectLanesRunning();
}

test "a header block left open stalls its connection even while another stream's request runs" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .connection_timeouts = .{ .stall_ns = short_timeout_ns } });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const client = try harness.connect(0, .{});
    const lane = harness.lane(0);

    try client.get(1);
    try client.drive();
    const request = try stub.readRequestBegin();
    // HEADERS for stream 3 without END_HEADERS, and no CONTINUATION after
    // it. The fragment is never decoded, so any byte will do.
    try client.writeFrame(.headers, 0x1, 3, &[_]u8{0x82});
    try client.drive();
    const runtime = lane.connections.get(client.slot).?;
    try std.testing.expect(runtime.h2HasPendingHeaderBlock());
    try std.testing.expect(runtime.servesRequest());

    try harness.expireDeadlines(0, runtime.last_progress_ns + short_timeout_ns);
    try std.testing.expect(!client.open());
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.stall_timeouts);

    // The close reset the request toward its worker, whose answer then
    // finds no stream and ends it.
    try stub.answer(request, 200, "late");
    try harness.serveWorker(0, stub);
    try std.testing.expect(harness.requestKeyOf(client, 1) == null);
    try harness.expectLanesRunning();
    try harness.expectServing(stub);
}

test "a client that opens no stream and reads nothing closes at its pre-request deadline, its GOAWAY given a whole stall period" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .connection_timeouts = .{
        .pre_request_ns = short_timeout_ns,
        .stall_ns = short_timeout_ns,
    } });
    defer harness.deinit();
    const client = try harness.connect(0, .{});
    const lane = harness.lane(0);
    const runtime = lane.connections.get(client.slot).?;

    // PINGs whose acknowledgements the client never reads, until the
    // lane's socket takes no more of them and its writes queue.
    const ping = pingFrame(.{});
    var batch: [pings_per_batch * ping.len]u8 = undefined;
    for (0..pings_per_batch) |index|
        @memcpy(batch[index * ping.len ..][0..ping.len], &ping);
    const batches_max = 4096;
    var batches: usize = 0;
    while (!runtime.h2WritesPending()) : (batches += 1) {
        if (batches == batches_max)
            return error.SocketNeverFilled;
        if (!client.open())
            return error.ConnectionClosed;
        try client.writeAll(&batch);
        try client.drive();
    }
    const last_progress_ns = runtime.last_progress_ns;

    // So the close is decided after the last byte moved.
    std.Thread.sleep(2 * std.time.ns_per_ms);
    try harness.expireDeadlines(0, runtime.accepted_ns + short_timeout_ns);
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.pre_request_timeouts);
    // The GOAWAY waits behind the acknowledgements.
    try std.testing.expect(client.open());
    const closing = runtime.closing orelse return error.ConnectionNotClosing;
    try std.testing.expect(closing.flush);
    try std.testing.expect(closing.decided_ns > last_progress_ns);

    try harness.expireDeadlines(0, last_progress_ns + short_timeout_ns);
    try std.testing.expect(client.open());
    try harness.expireDeadlines(0, closing.decided_ns + short_timeout_ns);
    try std.testing.expect(!client.open());
    try std.testing.expectEqual(@as(u64, 1), lane.lane.counters.stall_timeouts);
}
