//! The client connections of a whole ingress lane (`lane_harness.zig`): far
//! more of them at once than the lane once kept frame buffers for, each
//! holding part of a frame between its reads; the stream and request tables
//! refusing a stream with REFUSED_STREAM once full while the connection goes
//! on; and the one deadline each connection has
//! (`runner/deadline_driver.zig`): pre-request from the accept, idle while it
//! has no stream, and stall while the lane holds something of it that only
//! the client can move. A deadline test sweeps the lane at a time it picks,
//! so none waits for the clock. Lane `server-ingress-test`.

const std = @import("std");
const h2 = @import("collo_http").http2;
const lane_harness = @import("lane_harness.zig");

const Harness = lane_harness.Harness;

/// How long each shortened connection deadline runs in these tests. A sweep
/// names its own time, so the value only needs to stay far from the
/// requests' deadlines.
const short_timeout_ns: u64 = 50 * std.time.ns_per_ms;

const ping_payload = "pingpong";

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
