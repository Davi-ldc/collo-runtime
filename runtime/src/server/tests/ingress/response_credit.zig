//! Response credit on the lane that owns a request
//! (`dispatch.zig:responseChunkRetired`, `grantResponseCredit`): an owned
//! payload moves into its chunk only from the lane's allocator, a chunk
//! keeps its bytes until the socket took the last of them, a reset or a
//! later request in the slot gets no credit, a grant goes out only once the
//! worker holds half its window or less, and always before it runs out, a
//! chunk past the window faults the worker, one
//! WINDOW_UPDATE drains a stream, a full control socket keeps the newest
//! total, and ring bytes go back at once. Also the order streams share a
//! flush in, and a write queue too full for a head. Lane
//! `server-ingress-test`; local-e2e covers real worker streams.

const std = @import("std");
const ipc = @import("collo_ipc");
const h2 = @import("collo_http").http2;
const fd = @import("collo_os").fd;
const ingress = @import("collo_server_main").ingress;
const lifecycle = @import("collo_server_lifecycle");
const runner = ingress.runner;
const writes = runner.write_queue;
const writing = ingress.http2.writing;
const Slot = runner.connection_slot.Slot;
const lane_harness = @import("lane_harness.zig");
const allocator = std.testing.allocator;
const key: lifecycle.RequestKey = .{ .lane_id = 0, .slot = 1, .generation = 2 };
const identity: ipc.ingress_channel.RequestIdentity = .{
    .request_lane_id = key.lane_id,
    .request_slot = key.slot,
    .request_generation = key.generation,
    .request_id = 3,
};

const Fixture = struct {
    streams: runner.stream_table.StreamSlab,
    slot: Slot,

    fn init(self: *Fixture) !void {
        self.streams = try runner.stream_table.StreamSlab.init(4);
        self.slot = .{ .streams = &self.streams, .state = .http2_connection };
        self.slot.slab_link.live = true;
        errdefer self.deinit();
        _ = try self.addStream(1, key, identity.request_id);
    }

    fn addStream(self: *Fixture, stream_id: u32, request_key: lifecycle.RequestKey, request_id: u64) !ipc.ingress_channel.RequestIdentity {
        try self.slot.h2ReserveStream(stream_id);
        try self.slot.h2ActivateStream(stream_id, request_key, request_id);
        try self.slot.h2MarkWorkerResponseHeadQueued(stream_id, false);
        return .{
            .request_id = request_id,
            .request_lane_id = request_key.lane_id,
            .request_slot = request_key.slot,
            .request_generation = request_key.generation,
        };
    }

    fn deinit(self: *Fixture) void {
        writes.h2DeinitWriteQueue(&self.slot, allocator);
        runner.stream_table.releaseAll(&self.slot, allocator);
        self.slot.h2_hpack_encoder.deinit();
        self.streams.deinit();
    }
};

fn receivedChunk(stream_id: u32, request_identity: ipc.ingress_channel.RequestIdentity, bytes: []const u8) ipc.ingress_channel.Received {
    var descriptor = ipc.ingress_channel.Descriptor.responseChunk(request_identity, stream_id, 0, @intCast(bytes.len), false);
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    return .{ .allocator = allocator, .descriptor = descriptor, .payload = @constCast(bytes), .payload_owned = false };
}

const Writer = struct {
    service: struct { allocator: std.mem.Allocator } = .{ .allocator = allocator },
    h2_lane: struct { encode_scratch: []u8 } = .{ .encode_scratch = &.{} },
    retired: [8]lifecycle.RequestKey = undefined,
    retired_len: usize = 0,
    /// `grantResponseCredit` calls, one per retired chunk after every
    /// chunk of the write was counted.
    grants: usize = 0,
    closed: bool = false,

    pub fn updateConnectionInterest(_: *Writer, _: *Slot) ingress.fault.LaneFault!void {}

    pub fn closeRuntimeConnection(self: *Writer, slot: *Slot, close: ingress.fault.ConnectionClose) void {
        self.closed = true;
        slot.closing = .{ .reason = close.reason, .flush = false };
    }

    pub fn responseChunkRetired(self: *Writer, owner: lifecycle.RequestKey) ingress.fault.LaneFault!void {
        self.retired[self.retired_len] = owner;
        self.retired_len += 1;
    }

    pub fn grantResponseCredit(self: *Writer, _: lifecycle.RequestKey) ingress.fault.LaneFault!void {
        self.grants += 1;
    }
};

test "an owned payload moves into its chunk without another allocation for its bytes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const bytes = try failing.allocator().dupe(u8, "body");
    var received = receivedChunk(1, identity, bytes);
    received.allocator = failing.allocator();
    received.payload_owned = true;
    defer received.deinit();
    // The chunk itself is the one allocation left; a copy would fail.
    failing.fail_index = failing.alloc_index + 1;
    try fixture.slot.h2AppendResponseChunk(failing.allocator(), &received);
    try std.testing.expect(!received.payload_owned);
    try std.testing.expect(fixture.slot.h2PendingResponseChunk(1).?.bytes.ptr == bytes.ptr);
}

test "a payload owned in another allocator is copied into its chunk and stays with its descriptor" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var other = std.testing.FailingAllocator.init(allocator, .{});
    const bytes = try other.allocator().dupe(u8, "body");
    var received = receivedChunk(1, identity, bytes);
    received.allocator = other.allocator();
    received.payload_owned = true;
    defer received.deinit();
    try fixture.slot.h2AppendResponseChunk(allocator, &received);
    try std.testing.expect(received.payload_owned);
    const chunk = fixture.slot.h2PendingResponseChunk(1).?;
    try std.testing.expect(chunk.bytes.ptr != bytes.ptr);
    try std.testing.expectEqualStrings("body", chunk.bytes);
}

test "a chunk keeps its bytes through partial writes and retires once its last byte is written" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var received = receivedChunk(1, identity, "body");
    try fixture.slot.h2AppendResponseChunk(allocator, &received);
    const chunk = fixture.slot.h2PendingResponseChunk(1).?;
    try fixture.slot.h2AppendWriteCopy(allocator, "hdr");
    try fixture.slot.h2AppendChunkWrite(allocator, chunk.bytes, chunk);
    try fixture.slot.h2DropPendingResponsePrefix(allocator, 1, 4);
    try std.testing.expect(fixture.slot.h2TakeRetiredResponseChunk() == null);
    fixture.slot.h2ConsumeQueuedWrite(allocator, 3);
    try std.testing.expect(fixture.slot.h2TakeRetiredResponseChunk() == null);
    fixture.slot.h2ConsumeQueuedWrite(allocator, 2);
    try std.testing.expect(fixture.slot.h2TakeRetiredResponseChunk() == null);
    fixture.slot.h2ConsumeQueuedWrite(allocator, 2);
    const retired = fixture.slot.h2TakeRetiredResponseChunk().?;
    defer allocator.destroy(retired);
    try std.testing.expectEqual(@as(usize, 0), retired.bytes.len);
    try std.testing.expectEqualDeep(key, retired.owner);
    try std.testing.expect(fixture.slot.h2TakeRetiredResponseChunk() == null);
}

test "a reset stream drops its waiting chunk, and the part already queued retires with no credit" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var received = receivedChunk(1, identity, "body");
    try fixture.slot.h2AppendResponseChunk(allocator, &received);
    const chunk = fixture.slot.h2PendingResponseChunk(1).?;
    try fixture.slot.h2AppendChunkWrite(allocator, chunk.bytes[0..2], chunk);
    try fixture.slot.h2DropPendingResponsePrefix(allocator, 1, 2);
    _ = fixture.slot.h2MarkStreamReset(allocator, 1);
    try std.testing.expectEqual(@as(usize, 0), fixture.slot.h2_pending_response_bytes);
    fixture.slot.h2ConsumeQueuedWrite(allocator, 2);
    try std.testing.expect(fixture.slot.h2TakeRetiredResponseChunk() == null);
}

test "a chunk written after its request ended gives no credit to the request that reused its slot" {
    var scene: lane_harness.OneWorker = undefined;
    try scene.init(.{ .initial_window_size = 0 });
    defer scene.deinit();
    const replacement = try scene.harness.connect(0, .{});
    const request = try scene.get(1);
    try scene.stub.sendHead(request, 200, false);
    try scene.stub.sendChunk(request, "old", true);
    try scene.stub.sendDone(request, .{});
    // The client's window is closed, so the reader reads one packet a pass.
    try scene.harness.drainControl(0, scene.stub);
    try std.testing.expect(scene.harness.requestKeyOf(scene.client, 1) == null);

    try replacement.get(1);
    try replacement.drive();
    _ = try scene.stub.readRequestBegin();
    const reused = scene.harness.requestSlotOf(replacement, 1).?;
    try std.testing.expectEqual(request.identity.request_slot, reused.request_key.slot);

    // The old stream's window opens, so the old chunk reaches its client now.
    var increment: [4]u8 = undefined;
    std.mem.writeInt(u32, &increment, 3, .big);
    try scene.client.writeFrame(.window_update, 0, 1, &increment);
    try scene.client.drive();
    try scene.client.receive();
    try std.testing.expect((try scene.client.stream(1)).ended);
    try std.testing.expect(!reused.response_credit_unsent);
    try std.testing.expectEqual(ipc.response_credit.window, reused.response_credit.granted);
    try std.testing.expect(!try scene.stub.controlReadable());
}

test "a streamed response of fewer than half its window's chunks gets no grant" {
    var scene: lane_harness.OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);
    try scene.stub.sendHead(request, 200, false);
    try scene.stub.sendChunk(request, "only chunk", false);
    try scene.harness.handleControl(0, scene.stub);
    try scene.client.receive();
    try std.testing.expectEqual(@as(usize, 10), (try scene.client.stream(1)).body_len);
    // The chunk retired, and the worker still holds three of its four
    // credits, more than half the window.
    try std.testing.expect(!try scene.stub.controlReadable());
    try scene.stub.sendChunk(request, "", true);
    try scene.stub.sendDone(request, .{});
    try scene.harness.handleControl(0, scene.stub);
    try scene.client.receive();
    try std.testing.expect((try scene.client.stream(1)).ended);
    try std.testing.expect(!try scene.stub.controlReadable());
    try scene.harness.expectServing(scene.stub);
}

test "a long streamed response gets each grant before its worker runs out of credit, at most one per half window" {
    var scene: lane_harness.OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const request = try scene.get(1);
    try scene.stub.sendHead(request, 200, false);
    try scene.harness.handleControl(0, scene.stub);
    const chunks_total: usize = 40;
    const chunk = "0123456789";
    // The worker publishes while it holds credit, as a worker does.
    var published: usize = 0;
    var held: u64 = ipc.response_credit.window;
    var grants: usize = 0;
    var rounds: usize = 0;
    while (published < chunks_total) : (rounds += 1) {
        // A worker with no credit and no grant on its way would wait for
        // good.
        try std.testing.expect(published < held);
        try std.testing.expect(rounds < chunks_total);
        while (published < held and published < chunks_total) : (published += 1)
            try scene.stub.sendChunk(request, chunk, false);
        try scene.harness.handleControl(0, scene.stub);
        try scene.client.receive();
        if (try takeNewestGrant(scene.stub, &grants)) |total|
            held = @max(held, total);
    }
    try std.testing.expect(grants * 2 <= chunks_total);
    try scene.stub.sendChunk(request, "", true);
    try scene.stub.sendDone(request, .{});
    try scene.harness.handleControl(0, scene.stub);
    try scene.client.receive();
    const stream = try scene.client.stream(1);
    try std.testing.expect(stream.ended);
    try std.testing.expectEqual(chunks_total * chunk.len, stream.body_len);
    try scene.harness.expectServing(scene.stub);
}

/// The highest cumulative total among the grants waiting on the worker's
/// end of its control socket, which the reads take, counting each in
/// `count`; null when none waits.
fn takeNewestGrant(stub: *lane_harness.StubWorker, count: *usize) !?u64 {
    var newest: ?u64 = null;
    while (true) {
        var packet = ipc.recvPacketWithFdsScratch(allocator, stub.control, stub.recv_scratch) catch |err| switch (err) {
            error.WouldBlock => return newest,
            else => return err,
        };
        defer packet.deinit();
        const credit = try ipc.response_credit.decode(&packet);
        count.* += 1;
        newest = @max(newest orelse 0, credit.grant_chunks_total);
    }
}

test "the owning lane faults a fifth unpaid chunk from its reader or another lane" {
    for ([_]u16{ 0, 1 }) |owner_lane| {
        var harness: lane_harness.Harness = undefined;
        try harness.init(allocator, .{ .lane_count = 2, .routes = .{ .concurrency = 2 } });
        defer harness.deinit();
        const stub = try harness.publishWorker(.{});
        const reader_client = try harness.connect(0, .{ .initial_window_size = 0 });
        try reader_client.get(1);
        try reader_client.drive();
        var request = try stub.readRequestBegin();
        if (owner_lane != 0) {
            const client = try harness.connect(owner_lane, .{ .initial_window_size = 0 });
            try client.get(1);
            try client.drive();
            request = try stub.readRequestBegin();
        }
        try stub.sendHead(request, 200, false);
        try harness.handleControl(0, stub);
        // A reader whose own client has bytes it cannot write yet stops
        // after each packet, so every chunk gets its own pass.
        for (0..ipc.response_credit.window) |_| {
            try stub.sendChunk(request, "x", false);
            try harness.handleControl(0, stub);
            try harness.handleCommands(owner_lane);
        }
        try harness.expectServing(stub);
        try stub.sendChunk(request, "x", false);
        try harness.handleControl(0, stub);
        try harness.handleCommands(owner_lane);
        try harness.handleCommands(0);
        try harness.handleCommands(1);
        try harness.expectFaulted(stub, .response_descriptor_invalid);
    }
}

test "a stream with no HTTP2 send window does not hold back its sibling" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pair = try fd.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    fixture.slot.fd = pair[0];
    fixture.slot.h2StreamEntry(1).?.send_window = 0;
    var slow = receivedChunk(1, identity, "slow");
    try fixture.slot.h2AppendResponseChunk(allocator, &slow);
    const sibling_identity = try fixture.addStream(3, .{ .lane_id = 0, .slot = 2, .generation = 3 }, 4);
    var fast = receivedChunk(3, sibling_identity, "fast");
    try fixture.slot.h2AppendResponseChunk(allocator, &fast);
    var writer: Writer = .{};
    try std.testing.expect(try writing.flushPendingResponseData(Writer, &writer, &fixture.slot, null));
    try std.testing.expect(!writer.closed);
    try std.testing.expectEqual(@as(usize, 1), writer.retired_len);
    try std.testing.expectEqual(sibling_identity.request_slot, writer.retired[0].slot);
    try std.testing.expectEqualStrings("slow", fixture.slot.h2PendingResponseSlice(1).?);
    var wire: [13]u8 = undefined;
    try std.testing.expectEqual(wire.len, try std.posix.read(pair[1], &wire));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, wire[5..9], .big));
    try std.testing.expectEqualStrings("fast", wire[9..]);
}

test "one WINDOW_UPDATE drains a completed response without another writable event" {
    var scene: lane_harness.OneWorker = undefined;
    try scene.init(.{ .initial_window_size = 0 });
    defer scene.deinit();
    const request = try scene.get(1);
    try scene.stub.sendHead(request, 200, false);
    const body = "abcd";
    for (body, 0..) |_, index|
        try scene.stub.sendChunk(request, body[index..][0..1], index + 1 == body.len);
    try scene.stub.sendDone(request, .{});
    // The client's window is closed, so the reader reads one packet a pass.
    try scene.harness.drainControl(0, scene.stub);

    const connection = scene.harness.lane(0).connections.get(scene.client.slot) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(body.len, connection.h2_pending_response_bytes);
    try std.testing.expect(!connection.slab_link.queued);

    var increment: [4]u8 = undefined;
    std.mem.writeInt(u32, &increment, body.len, .big);
    try scene.client.writeFrame(.window_update, 0, 1, &increment);
    try scene.client.drive();

    try scene.client.receive();
    const stream = try scene.client.stream(1);
    try std.testing.expect(stream.ended);
    try std.testing.expectEqual(body.len, stream.body_len);
    try std.testing.expectEqual(@as(usize, 0), connection.h2_pending_response_bytes);
    try std.testing.expect(!connection.slab_link.queued);
    try scene.harness.expectServing(scene.stub);
}

test "one flush drains each runnable stream before moving to the next" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pair = try fd.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    fixture.slot.fd = pair[0];
    const sibling_identity = try fixture.addStream(3, .{ .lane_id = 0, .slot = 2, .generation = 3 }, 4);
    for (0..2) |index| {
        var first = receivedChunk(1, identity, "ab"[index..][0..1]);
        try fixture.slot.h2AppendResponseChunk(allocator, &first);
        var second = receivedChunk(3, sibling_identity, "cd"[index..][0..1]);
        try fixture.slot.h2AppendResponseChunk(allocator, &second);
    }
    var writer: Writer = .{};
    try std.testing.expect(try writing.flushPendingResponseData(Writer, &writer, &fixture.slot, null));
    try std.testing.expectEqual(@as(usize, 4), writer.retired_len);
    try std.testing.expectEqual(@as(usize, 0), fixture.slot.h2_pending_response_bytes);
    try std.testing.expect(!try writing.flushPendingResponseData(Writer, &writer, &fixture.slot, null));
    var wire: [4 * (h2.frame_header_len + 1)]u8 = undefined;
    try std.testing.expectEqual(wire.len, try std.posix.read(pair[1], &wire));
    for ([_]u32{ 1, 1, 3, 3 }, "abcd", 0..) |stream_id, byte, index| {
        const offset = index * (h2.frame_header_len + 1);
        const header = try h2.FrameHeader.parse(wire[offset..][0..h2.frame_header_len]);
        try std.testing.expectEqual(stream_id, header.stream_id);
        try std.testing.expectEqual(byte, wire[offset + h2.frame_header_len]);
    }
}

test "a chunk the socket refused waits queued and retires once the socket takes its whole frame" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pair = try fd.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    fixture.slot.fd = pair[0];
    const filled = try fillSocket(pair[0]);
    var received = receivedChunk(1, identity, "body");
    try fixture.slot.h2AppendResponseChunk(allocator, &received);
    var writer: Writer = .{};
    _ = try writing.flushPendingResponseData(Writer, &writer, &fixture.slot, null);
    try std.testing.expect(fixture.slot.h2WritesPending());
    try std.testing.expectEqual(@as(usize, 0), writer.retired_len);
    var remaining = filled;
    var scratch: [256]u8 = undefined;
    while (remaining != 0) {
        const read = try std.posix.read(pair[1], scratch[0..@min(remaining, scratch.len)]);
        try std.testing.expect(read != 0);
        remaining -= read;
    }
    _ = try writing.flushPendingWrite(Writer, &writer, &fixture.slot);
    try std.testing.expect(!fixture.slot.h2WritesPending());
    try std.testing.expectEqual(@as(usize, 1), writer.retired_len);
    try std.testing.expect(!writer.closed);
}

fn fillSocket(socket: std.posix.fd_t) !usize {
    for (0..65536) |count| {
        _ = std.posix.write(socket, "x") catch |err| switch (err) {
            error.WouldBlock => {
                try std.testing.expect(count != 0);
                return count;
            },
            else => return err,
        };
    }
    return error.SocketDidNotFill;
}

test "a failed DATA payload append closes without flushing its queued header" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pair = try fd.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    fixture.slot.fd = pair[0];
    _ = try fillSocket(pair[0]);
    var received = receivedChunk(1, identity, "body");
    try fixture.slot.h2AppendResponseChunk(allocator, &received);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var writer: Writer = .{ .service = .{ .allocator = failing.allocator() } };
    try std.testing.expectError(error.OutOfMemory, writing.flushPendingResponseData(Writer, &writer, &fixture.slot, 1));
    try std.testing.expect(writer.closed);
    try std.testing.expect(!fixture.slot.closing.?.flush);
    try std.testing.expect(!try writing.flushPendingWrite(Writer, &writer, &fixture.slot));
}

test "a full worker control socket keeps the newest credit total, and the lane admits the chunks it allows meanwhile" {
    var scene: lane_harness.OneWorker = undefined;
    try scene.init(.{ .control_send_buffer_bytes = 4096 });
    defer scene.deinit();
    const request = try scene.get(1);
    const filler: ipc.ResponseCredit = .{
        .request_id = request.identity.request_id,
        .request_generation = request.identity.request_generation,
        .request_lane_id = request.identity.request_lane_id,
        .request_slot = request.identity.request_slot,
        .stream_id = request.stream_id,
        .grant_chunks_total = 4,
    };
    var filled: usize = 0;
    while (filled < 1024) : (filled += 1) {
        ipc.response_credit.send(scene.stub.record.handle.control_fd, filler) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    try std.testing.expect(filled != 0);
    try std.testing.expect(filled < 1024);
    try scene.stub.sendHead(request, 200, false);
    for (0..4) |_|
        try scene.stub.sendChunk(request, "x", false);
    try scene.harness.handleControl(0, scene.stub);
    try std.testing.expect(scene.harness.requestSlotOf(scene.client, 1).?.response_credit_unsent);
    const registration = try scene.harness.expectRegistration(0, scene.stub);
    try std.testing.expect(scene.harness.lane(0).registrations.entries[registration].control_writable_poll_registered);
    // All four chunks reached the client; the next fits even while the
    // worker has not received the grant.
    try scene.stub.sendChunk(request, "y", false);
    try scene.harness.handleControl(0, scene.stub);
    for (0..filled) |_| {
        var scratch: [40]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(allocator, scene.stub.control, &scratch);
        defer packet.deinit();
        try std.testing.expectEqual(@as(u64, 4), (try ipc.response_credit.decode(&packet)).grant_chunks_total);
    }
    try scene.harness.handleControlWritable(0, scene.stub);
    try std.testing.expect(!scene.harness.requestSlotOf(scene.client, 1).?.response_credit_unsent);
    var scratch: [40]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(allocator, scene.stub.control, &scratch);
    defer packet.deinit();
    try std.testing.expectEqual(@as(u64, 9), (try ipc.response_credit.decode(&packet)).grant_chunks_total);
    try std.testing.expect(!try scene.stub.controlReadable());
    try scene.stub.sendChunk(request, "", true);
    try scene.stub.sendDone(request, .{});
    try scene.harness.handleControl(0, scene.stub);
    try scene.harness.expectServing(scene.stub);
}

test "a slow response frees the shared ring while a sibling finishes through another lane" {
    var harness: lane_harness.Harness = undefined;
    try harness.init(allocator, .{ .lane_count = 2, .routes = .{ .concurrency = 2 } });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const slow_client = try harness.connect(0, .{ .initial_window_size = 0 });
    const fast_client = try harness.connect(1, .{});
    try slow_client.get(1);
    try slow_client.drive();
    const slow = try stub.readRequestBegin();
    try fast_client.get(1);
    try fast_client.drive();
    const fast = try stub.readRequestBegin();
    try stub.sendHead(slow, 200, false);
    const body: [33 * 1024]u8 = @splat('s');
    for (0..4) |_|
        try stub.sendRingChunk(slow, &body, false);
    for (0..4) |_|
        try harness.handleControl(0, stub);
    const cursors = stub.responseRingCursors();
    try std.testing.expectEqual(cursors.write, cursors.read);
    try stub.answer(fast, 200, "fast");
    try harness.handleControl(0, stub);
    try harness.handleCommands(1);
    try fast_client.expectStatus(1, 200);
    const fast_stream = try fast_client.stream(1);
    try std.testing.expect(fast_stream.ended);
    try std.testing.expectEqual(@as(usize, 4), fast_stream.body_len);
    try std.testing.expect(harness.requestSlotOf(slow_client, 1) != null);
    try std.testing.expect(harness.requestSlotOf(fast_client, 1) == null);
    try harness.expectServing(stub);
    var reset: [4]u8 = undefined;
    std.mem.writeInt(u32, &reset, 8, .big);
    try slow_client.writeFrame(.rst_stream, 0, 1, &reset);
    try slow_client.drive();
    try stub.sendDone(slow, .{ .done = .client_closed, .http_status = 499 });
    try harness.handleControl(0, stub);
    try harness.expectServing(stub);
}

test "a full connection write queue refuses a response head" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.slot.h2StreamEntry(1).?.worker_response_head_sent = false;
    const filler = try allocator.alloc(u8, writes.max_queued_write_bytes);
    @memset(filler, 0);
    try fixture.slot.h2AppendOwnedWrite(allocator, filler);
    var scratch: [128]u8 = undefined;
    const bytes = try ipc.ingress_channel.encodeResponseHeadInto(&scratch, 200, &.{});
    var descriptor = ipc.ingress_channel.Descriptor.responseHead(identity, 1, 0, @intCast(bytes.len), 200, 0, false);
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    var received: ipc.ingress_channel.Received = .{ .allocator = allocator, .descriptor = descriptor, .payload = bytes, .payload_owned = false };
    var encode_scratch: [16 * 1024]u8 = undefined;
    var writer: Writer = .{ .h2_lane = .{ .encode_scratch = &encode_scratch } };
    try std.testing.expectError(error.Http2WriteBackpressure, writing.queueWorkerResponseDescriptor(Writer, &writer, &fixture.slot, &received));
    _ = fixture.slot.h2MarkStreamReset(allocator, 1);
    try std.testing.expectEqual(writes.max_queued_write_bytes, fixture.slot.h2_write_len - fixture.slot.h2_write_offset);
}
