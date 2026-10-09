//! Tests of streams sharing one codec `Connection`: out-of-order completion,
//! local and peer concurrency limits, frame and CONTINUATION floods, failures
//! and cancels that reset one stream while its neighbors finish, a cancel
//! between HEADERS and CONTINUATION that must leave HPACK in step, GOAWAY and
//! which streams may be reported unprocessed, the reset-tracking bound, late
//! frames for closed streams, and receive-window growth. Each test feeds
//! hand-built server frames from memory and inspects the events and the
//! frames the client wrote.

const std = @import("std");
const egress_http2 = @import("collo_egress_client").http2;
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const test_support = @import("support.zig");
const readCollectedResponse = test_support.readCollectedResponse;
const expectStreamFailure = test_support.expectStreamFailure;
const appendSettingsFrame = test_support.appendSettingsFrame;
const PartialReadSource = test_support.PartialReadSource;
const expectFrameReadWait = test_support.expectFrameReadWait;
const frameFromWire = test_support.frameFromWire;
const appendResponseFrames = test_support.appendResponseFrames;
const appendResponseFramesForStream = test_support.appendResponseFramesForStream;
const appendHeaderFrames = test_support.appendHeaderFrames;
const appendHeaderFramesForStream = test_support.appendHeaderFramesForStream;
const appendDataFrameForStream = test_support.appendDataFrameForStream;
const appendPaddedPriorityHeaderFrame = test_support.appendPaddedPriorityHeaderFrame;
const appendPaddedDataFrame = test_support.appendPaddedDataFrame;
const appendWindowUpdateFrame = test_support.appendWindowUpdateFrame;
const countClientFrames = test_support.countClientFrames;
const sumClientFramePayloadBytes = test_support.sumClientFramePayloadBytes;
const clientFrameStreamIds = test_support.clientFrameStreamIds;
const sumClientWindowUpdateIncrements = test_support.sumClientWindowUpdateIncrements;

fn appendEmptyFrame(writer: *std.Io.Writer, frame_type: h2.FrameType, flags: u8, stream_id: u32) !void {
    try appendFrame(writer, frame_type, h2.Flags.fromByte(flags), stream_id, &.{});
}

fn appendFrame(writer: *std.Io.Writer, frame_type: h2.FrameType, flags: h2.Flags, stream_id: u32, payload: []const u8) !void {
    var header = h2.FrameHeader{
        .length = @intCast(payload.len),
        .frame_type_raw = @intFromEnum(frame_type),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = stream_id,
    };
    var wire: [h2.frame_header_len]u8 = undefined;
    try header.encode(&wire);
    try writer.writeAll(&wire);
    try writer.writeAll(payload);
}

// One response header block split across HEADERS and CONTINUATION, spelled
// out byte by byte so each fragment's HPACK content is fixed. 0x88 is the
// static entry `:status: 200`, and each 0x40 starts a literal the decoder
// inserts into its dynamic table. The split falls inside the second
// literal's name, as a frame boundary may.
const split_block_headers_fragment = "\x88\x40\x07x-first\x03one\x40\x08x-se";
const split_block_continuation_fragment = "cond\x03two";
// A later block made only of references to those insertions: dynamic index
// 62 is the newest entry and 63 the one before it.
const dynamic_table_reference_block = "\x88\xbe\xbf";
const dynamic_table_reference_headers = [_]hpack.Header{
    .{ .name = "x-second", .value = "two" },
    .{ .name = "x-first", .value = "one" },
};

fn expectHeaders(expected: []const hpack.Header, actual: []const hpack.Header) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_header, actual_header| {
        try std.testing.expectEqualStrings(expected_header.name, actual_header.name);
        try std.testing.expectEqualStrings(expected_header.value, actual_header.value);
    }
}

/// Passes one frame to `processEventFrame`, the way the pool hands over every
/// frame it reads.
fn processFrameWire(connection: *egress_http2.Connection, writer: *std.Io.Writer, wire: []const u8) !?egress_http2.Event {
    var frame = try frameFromWire(wire);
    defer frame.deinit();
    return try connection.processEventFrame(writer, &frame);
}

fn expectNotProcessed(event: egress_http2.Event, stream_id: u32) !void {
    switch (event) {
        .failure => |failure| {
            try std.testing.expectEqual(stream_id, failure.stream_id);
            try std.testing.expectEqual(error.Http2StreamNotProcessed, failure.err);
        },
        else => return error.UnexpectedHttp2Event,
    }
}

/// Opens and cancels streams until reset tracking holds
/// `max_local_reset_tombstones` of them. The peer never ends them, as a peer
/// that saw each RST_STREAM before answering would not.
fn fillLocalResetTracking(connection: *egress_http2.Connection, writer: *std.Io.Writer) !void {
    for (0..egress_http2.client.max_local_reset_tombstones) |_| {
        const stream_id = try connection.openRequest(writer, .{
            .method = "GET",
            .scheme = "https",
            .authority = "demo.example.test",
            .path = "/abandoned",
        }, 16);
        try connection.cancelStream(writer, stream_id);
    }
    try std.testing.expect(connection.canOpenStream());
}

fn appendPingFrame(writer: *std.Io.Writer) !void {
    var header = h2.FrameHeader{
        .length = 8,
        .frame_type_raw = @intFromEnum(h2.FrameType.ping),
        .frame_type = .ping,
        .flags = h2.Flags.fromByte(0),
        .stream_id = 0,
    };
    var wire: [h2.frame_header_len]u8 = undefined;
    try header.encode(&wire);
    try writer.writeAll(&wire);
    try writer.writeAll(&[_]u8{0} ** 8);
}

test "egress http2 connection completes multiplexed streams out of order" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFramesForStream(&server_wire.writer, 3, "200", &.{
        .{ .name = "content-length", .value = "3" },
    }, "two");
    try appendResponseFramesForStream(&server_wire.writer, 1, "200", &.{
        .{ .name = "content-length", .value = "3" },
    }, "one");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const stream_one = try connection.openRequest(
        &sent_wire.writer,
        .{
            .method = "GET",
            .scheme = "https",
            .authority = "demo.example.test",
            .path = "/one",
        },
        16,
    );
    const stream_two = try connection.openRequest(
        &sent_wire.writer,
        .{
            .method = "GET",
            .scheme = "https",
            .authority = "demo.example.test",
            .path = "/two",
        },
        16,
    );
    try std.testing.expectEqual(@as(u32, 1), stream_one);
    try std.testing.expectEqual(@as(u32, 3), stream_two);

    var second_response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_two);
    defer second_response.deinit();
    try std.testing.expectEqualStrings("two", second_response.body);
    try std.testing.expect(second_response.wire_bytes > second_response.body.len);

    var first_response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_one);
    defer first_response.deinit();
    try std.testing.expectEqualStrings("one", first_response.body);
    try std.testing.expect(first_response.wire_bytes > first_response.body.len);

    var request_stream_ids = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .headers);
    defer request_stream_ids.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, request_stream_ids.items);
}

test "egress http2 caps frames without a delivered event" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    for (0..egress_http2.max_frames_without_event_per_read + 1) |_| {
        try appendPingFrame(&server_wire.writer);
    }

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/flood",
    }, 16);

    try std.testing.expectError(
        error.Http2FrameProgressLimitExceeded,
        connection.readNextEvent(&reader, &sent_wire.writer),
    );
}

test "egress http2 caps zero-byte continuation flood" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendEmptyFrame(&server_wire.writer, .headers, 0, 1);
    for (0..80) |_| {
        try appendEmptyFrame(&server_wire.writer, .continuation, 0, 1);
    }

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/continuation",
    }, 16);

    try std.testing.expectError(
        error.Http2HeaderContinuationLimitExceeded,
        connection.readNextEvent(&reader, &sent_wire.writer),
    );
}

test "egress http2 connection respects peer max concurrent streams" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    var payload: [h2.setting_wire_len]u8 = undefined;
    try h2.encodeSetting(&payload, .max_concurrent_streams, 1);
    const header = h2.FrameHeader{
        .length = payload.len,
        .frame_type_raw = @intFromEnum(h2.FrameType.settings),
        .frame_type = .settings,
        .flags = h2.Flags.fromByte(0),
        .stream_id = 0,
    };
    const ack = (try connection.session.handleSettingsFrame(header, &payload, std.testing.allocator)).?;
    defer std.testing.allocator.free(ack);

    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/one",
    }, 16);
    try std.testing.expectError(error.Http2MaxConcurrentStreamsExceeded, connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/two",
    }, 16));
}

test "egress http2 connection enforces local max active streams" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .max_active_streams = 1,
    });
    defer connection.deinit();

    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/one",
    }, 16);
    try std.testing.expectError(error.Http2MaxConcurrentStreamsExceeded, connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/two",
    }, 16));
}

test "egress http2 connection cancels one active stream without closing others" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFramesForStream(&server_wire.writer, 1, "200", &.{
        .{ .name = "content-length", .value = "4" },
    }, "late");
    try appendResponseFramesForStream(&server_wire.writer, 3, "200", &.{
        .{ .name = "content-length", .value = "2" },
    }, "ok");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const canceled = try connection.openRequest(
        &sent_wire.writer,
        .{
            .method = "GET",
            .scheme = "https",
            .authority = "demo.example.test",
            .path = "/cancel",
        },
        16,
    );
    const kept = try connection.openRequest(
        &sent_wire.writer,
        .{
            .method = "GET",
            .scheme = "https",
            .authority = "demo.example.test",
            .path = "/kept",
        },
        16,
    );
    try connection.cancelStream(&sent_wire.writer, canceled);

    var response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, kept);
    defer response.deinit();
    try std.testing.expectEqualStrings("ok", response.body);

    var rst_stream_ids = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .rst_stream);
    defer rst_stream_ids.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{canceled}, rst_stream_ids.items);
}

test "egress http2 connection discards reset stream frames while idle" {
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();

    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/cancelled",
    }, 16);
    try connection.cancelStream(&sent_wire.writer, stream_id);

    var settings = h2.FrameHeader{
        .length = 0,
        .frame_type_raw = @intFromEnum(h2.FrameType.settings),
        .frame_type = .settings,
        .flags = h2.Flags.fromByte(0),
        .stream_id = 0,
    };
    var settings_wire: [h2.frame_header_len]u8 = undefined;
    try settings.encode(&settings_wire);
    var settings_frame = try frameFromWire(&settings_wire);
    defer settings_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(&sent_wire.writer, &settings_frame)) == null);

    const data_wire = try h2.encodeDataFrames(std.testing.allocator, h2.default_max_frame_size, stream_id, "late", true);
    defer std.testing.allocator.free(data_wire);
    var data_frame = try frameFromWire(data_wire);
    defer data_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(&sent_wire.writer, &data_frame)) == null);
}

test "egress http2 goaway fails every unprocessed active stream without another read" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    var goaway: [h2.frame_header_len + 8]u8 = undefined;
    try h2.encodeGoawayFrame(&goaway, 0, .no_error);
    try server_wire.writer.writeAll(&goaway);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const first = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/one",
    }, 16);
    const second = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/two",
    }, 16);

    var first_completion = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer first_completion.deinit();
    switch (first_completion) {
        .head => return error.UnexpectedHttp2Head,
        .progress => return error.UnexpectedHttp2Progress,
        .end => return error.UnexpectedHttp2End,
        .failure => |failure| {
            try std.testing.expectEqual(first, failure.stream_id);
            try std.testing.expectEqual(error.Http2StreamNotProcessed, failure.err);
        },
        .body_chunk => return error.UnexpectedHttp2BodyChunk,
    }

    var second_completion = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer second_completion.deinit();
    switch (second_completion) {
        .head => return error.UnexpectedHttp2Head,
        .progress => return error.UnexpectedHttp2Progress,
        .end => return error.UnexpectedHttp2End,
        .failure => |failure| {
            try std.testing.expectEqual(second, failure.stream_id);
            try std.testing.expectEqual(error.Http2StreamNotProcessed, failure.err);
        },
        .body_chunk => return error.UnexpectedHttp2BodyChunk,
    }
}

test "egress http2 goaway leaves frames of processed streams to their streams" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const processed = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/one",
    }, 16);
    const first_unprocessed = try connection.openRequest(&sent_wire.writer, .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/two",
        .body = "{}",
    }, 16);
    const second_unprocessed = try connection.openRequest(&sent_wire.writer, .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/three",
        .body = "{}",
    }, 16);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, settings_wire.written()));

    var goaway: [h2.frame_header_len + 8]u8 = undefined;
    try h2.encodeGoawayFrame(&goaway, processed, .no_error);
    var goaway_event = (try processFrameWire(&connection, &sent_wire.writer, &goaway)) orelse return error.ExpectedHttp2Failure;
    defer goaway_event.deinit();
    try expectNotProcessed(goaway_event, first_unprocessed);

    var head_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer head_wire.deinit();
    try appendHeaderFramesForStream(&head_wire.writer, processed, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "2" },
    }, false);
    var head_event = (try processFrameWire(&connection, &sent_wire.writer, head_wire.written())) orelse return error.ExpectedHttp2Head;
    defer head_event.deinit();
    try std.testing.expect(head_event == .head);
    try std.testing.expectEqual(processed, head_event.head.stream_id);

    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, processed, "ok", true);
    var data_event = (try processFrameWire(&connection, &sent_wire.writer, data_wire.written())) orelse return error.ExpectedHttp2BodyChunk;
    defer data_event.deinit();
    try std.testing.expect(data_event == .body_chunk);
    try std.testing.expectEqualStrings("ok", data_event.body_chunk.bytes);
    var end_event = (try connection.ackReceivedData(&sent_wire.writer, processed, data_event.body_chunk.flow_credit, false)) orelse return error.ExpectedHttp2End;
    defer end_event.deinit();
    try std.testing.expect(end_event == .end);

    var unprocessed_event = connection.nextUnprocessedStreamFailure() orelse return error.ExpectedHttp2Failure;
    defer unprocessed_event.deinit();
    try expectNotProcessed(unprocessed_event, second_unprocessed);
    try std.testing.expect(connection.nextUnprocessedStreamFailure() == null);
    try std.testing.expect(!connection.hasActiveStreams());
}

test "egress http2 connection closed without goaway reports no stream as unprocessed" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/orders",
        .body = "{}",
    }, 16);
    connection.closeWithoutPeerGoaway();
    try std.testing.expect(!connection.canOpenStream());
    try std.testing.expect(connection.nextUnprocessedStreamFailure() == null);
    try std.testing.expect(connection.hasActiveStreams());
}

test "egress http2 cancel at the reset tracking bound leaves open streams processed" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    try fillLocalResetTracking(&connection, &sent_wire.writer);

    const post = try connection.openRequest(&sent_wire.writer, .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/orders",
        .body = "{}",
    }, 16);
    const canceled = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/canceled",
    }, 16);
    try connection.cancelStream(&sent_wire.writer, canceled);
    try std.testing.expect(!connection.canOpenStream());

    // No GOAWAY says the origin skipped the POST, so it must finish here
    // instead of failing as a stream the engine may replay.
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFramesForStream(&server_wire.writer, post, "201", &.{
        .{ .name = "content-length", .value = "2" },
    }, "ok");
    var reader = std.Io.Reader.fixed(server_wire.written());

    var response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, post);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 201), response.status_code);
    try std.testing.expectEqualStrings("ok", response.body);
}

test "egress http2 stream failure at the reset tracking bound leaves open streams processed" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    try fillLocalResetTracking(&connection, &sent_wire.writer);

    const post = try connection.openRequest(&sent_wire.writer, .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/orders",
        .body = "{}",
    }, 16);
    const rejected = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/too-large",
    }, 1);

    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, rejected, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "3" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, rejected, "ba", false);
    // In flight when the client resets the stream.
    try appendDataFrameForStream(&server_wire.writer, rejected, "d", true);
    try appendResponseFramesForStream(&server_wire.writer, post, "201", &.{
        .{ .name = "content-length", .value = "2" },
    }, "ok");
    var reader = std.Io.Reader.fixed(server_wire.written());

    try expectStreamFailure(&connection, &reader, &sent_wire.writer, rejected, error.FetchResponseTooLarge);
    try std.testing.expect(!connection.canOpenStream());

    var response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, post);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 201), response.status_code);
    try std.testing.expectEqualStrings("ok", response.body);
}

test "egress http2 reset tracking bound still discards late frames of the newest reset" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    try fillLocalResetTracking(&connection, &sent_wire.writer);

    const canceled = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/canceled",
    }, 16);
    try connection.cancelStream(&sent_wire.writer, canceled);
    try std.testing.expectEqual(egress_http2.client.max_local_reset_tombstones, connection.local_reset_streams.items.len);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, settings_wire.written()));

    // The origin answered before it saw the reset.
    var head_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer head_wire.deinit();
    try appendHeaderFramesForStream(&head_wire.writer, canceled, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "4" },
    }, false);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, head_wire.written()));
    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, canceled, "late", true);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, data_wire.written()));
}

test "egress http2 reset tracking bound keeps the reset stream whose header block is pending" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    try fillLocalResetTracking(&connection, &sent_wire.writer);
    // Client stream ids start at 1, so stream 1 holds the oldest entry.
    const oldest: u32 = 1;

    // An open stream sends the frames below through the active-stream path.
    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/kept",
    }, 16);
    const canceled = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/canceled",
    }, 16);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, settings_wire.written()));

    // The origin answered the oldest stream before it saw the reset, and the
    // header block goes on in a CONTINUATION frame: END_HEADERS (0x4) is
    // cleared on the HEADERS frame.
    var head_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer head_wire.deinit();
    try appendHeaderFramesForStream(&head_wire.writer, oldest, &.{
        .{ .name = ":status", .value = "200" },
    }, false);
    head_wire.written()[4] &= ~@as(u8, 0x4);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, head_wire.written()));

    try connection.cancelStream(&sent_wire.writer, canceled);
    try std.testing.expect(!connection.canOpenStream());

    var continuation_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer continuation_wire.deinit();
    try appendEmptyFrame(&continuation_wire.writer, .continuation, 0x4, oldest);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, continuation_wire.written()));
    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, oldest, "late", true);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, data_wire.written()));
}

test "egress http2 cancel inside a split header block keeps HPACK in step for the other streams" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const canceled = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/canceled",
    }, 16);
    const kept = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/kept",
    }, 16);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, settings_wire.written()));

    var headers_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer headers_wire.deinit();
    try appendFrame(&headers_wire.writer, .headers, .{}, canceled, split_block_headers_fragment);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, headers_wire.written()));
    try connection.cancelStream(&sent_wire.writer, canceled);

    // The origin sent the rest of the block, and a body, before it saw the
    // reset.
    var continuation_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer continuation_wire.deinit();
    try appendFrame(&continuation_wire.writer, .continuation, .{ .end_headers_or_ack = true }, canceled, split_block_continuation_fragment);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, continuation_wire.written()));
    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, canceled, "late", true);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, data_wire.written()));
    try std.testing.expectEqual(@as(usize, 0), connection.local_reset_streams.items.len);

    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendFrame(&server_wire.writer, .headers, .{ .end_stream = true, .end_headers_or_ack = true }, kept, dynamic_table_reference_block);
    var reader = std.Io.Reader.fixed(server_wire.written());
    var response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, kept);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try expectHeaders(&dynamic_table_reference_headers, response.headers);

    var resets = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .rst_stream);
    defer resets.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{canceled}, resets.items);
}

test "egress http2 cancel of the only stream inside a split header block keeps HPACK in step for the next stream" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const canceled = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/canceled",
    }, 16);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, settings_wire.written()));

    // END_STREAM on the HEADERS frame means the block is the whole response,
    // so its END_HEADERS also ends reset tracking for the stream.
    var headers_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer headers_wire.deinit();
    try appendFrame(&headers_wire.writer, .headers, .{ .end_stream = true }, canceled, split_block_headers_fragment);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, headers_wire.written()));
    try connection.cancelStream(&sent_wire.writer, canceled);
    try std.testing.expect(!connection.hasActiveStreams());

    var continuation_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer continuation_wire.deinit();
    try appendFrame(&continuation_wire.writer, .continuation, .{ .end_headers_or_ack = true }, canceled, split_block_continuation_fragment);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, continuation_wire.written()));
    try std.testing.expectEqual(@as(usize, 0), connection.local_reset_streams.items.len);

    const next = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/next",
    }, 16);
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendFrame(&server_wire.writer, .headers, .{ .end_stream = true, .end_headers_or_ack = true }, next, dynamic_table_reference_block);
    var reader = std.Io.Reader.fixed(server_wire.written());
    var response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, next);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
    try expectHeaders(&dynamic_table_reference_headers, response.headers);
}

test "egress http2 cancel inside a split header block at the reset tracking bound still discards the stream's late frames" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    try fillLocalResetTracking(&connection, &sent_wire.writer);

    const canceled = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/canceled",
    }, 16);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, settings_wire.written()));

    var headers_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer headers_wire.deinit();
    try appendFrame(&headers_wire.writer, .headers, .{}, canceled, split_block_headers_fragment);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, headers_wire.written()));
    try connection.cancelStream(&sent_wire.writer, canceled);
    try std.testing.expect(!connection.canOpenStream());

    var continuation_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer continuation_wire.deinit();
    try appendFrame(&continuation_wire.writer, .continuation, .{ .end_headers_or_ack = true }, canceled, split_block_continuation_fragment);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, continuation_wire.written()));
    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, canceled, "late", true);
    try std.testing.expectEqual(@as(?egress_http2.Event, null), try processFrameWire(&connection, &sent_wire.writer, data_wire.written()));
}

test "egress http2 response limit failure resets only its stream" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 3, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "3" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 3, "ba", false);
    // This frame may already be in flight when the client sends RST_STREAM.
    try appendDataFrameForStream(&server_wire.writer, 3, "d", true);
    try appendResponseFramesForStream(&server_wire.writer, 1, "200", &.{
        .{ .name = "content-length", .value = "2" },
    }, "ok");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
    });
    defer connection.deinit();

    const kept = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/kept",
    }, 16);
    const rejected = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/rejected",
    }, 1);

    try expectStreamFailure(&connection, &reader, &sent_wire.writer, rejected, error.FetchResponseTooLarge);

    var kept_response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, kept);
    defer kept_response.deinit();
    try std.testing.expectEqualStrings("ok", kept_response.body);

    var resets = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .rst_stream);
    defer resets.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{rejected}, resets.items);
    try std.testing.expectEqual(@as(u32, 5), try sumClientWindowUpdateIncrements(sent_wire.written(), 0));
}

test "egress http2 forbidden response body resets its stream and credits connection data" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 3, &.{
        .{ .name = ":status", .value = "204" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 3, "x", true);
    try appendResponseFramesForStream(&server_wire.writer, 1, "200", &.{
        .{ .name = "content-length", .value = "2" },
    }, "ok");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
    });
    defer connection.deinit();

    const kept = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/kept",
    }, 16);
    const rejected = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/body-forbidden",
    }, 16);

    try expectStreamFailure(&connection, &reader, &sent_wire.writer, rejected, error.Http2ResponseBodyForbidden);

    var kept_response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, kept);
    defer kept_response.deinit();
    try std.testing.expectEqualStrings("ok", kept_response.body);

    var resets = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .rst_stream);
    defer resets.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{rejected}, resets.items);
    try std.testing.expectEqual(@as(u32, 3), try sumClientWindowUpdateIncrements(sent_wire.written(), 0));
}

test "egress http2 per-stream body credit cap preserves multiplexed neighbors" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "2" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 1, "zz", false);
    try appendResponseFramesForStream(&server_wire.writer, 3, "200", &.{
        .{ .name = "content-length", .value = "2" },
    }, "ok");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
        .max_pending_body_credit_per_stream = 2,
        .max_pending_body_credit_per_connection = 32,
    });
    defer connection.deinit();

    const slow = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/slow",
    }, 16);
    const kept = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/kept",
    }, 16);

    var slow_chunk = try readUnackedBodyChunkForStream(&connection, &reader, &sent_wire.writer, slow);
    defer slow_chunk.deinit();
    switch (slow_chunk) {
        .body_chunk => |chunk| {
            try std.testing.expectEqualStrings("zz", chunk.bytes);
            try std.testing.expectEqual(@as(usize, 2), chunk.flow_credit);
            try std.testing.expect(chunk.update_stream_window);
        },
        else => return error.UnexpectedHttp2Event,
    }

    var kept_response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, kept);
    defer kept_response.deinit();
    try std.testing.expectEqualStrings("ok", kept_response.body);

    var resets = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .rst_stream);
    defer resets.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{}, resets.items);
    try std.testing.expectEqual(@as(u32, 2), try sumClientWindowUpdateIncrements(sent_wire.written(), 0));
}

test "egress http2 one stalled stream does not starve ninety nine small streams" {
    const small_count = 99;

    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "2" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 1, "zz", false);
    inline for (0..small_count) |index| {
        const stream_id: u32 = @intCast(3 + index * 2);
        try appendResponseFramesForStream(&server_wire.writer, stream_id, "200", &.{
            .{ .name = "content-length", .value = "2" },
        }, "ok");
    }

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .max_active_streams = 128,
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
        .max_pending_body_credit_per_stream = 2,
        .max_pending_body_credit_per_connection = 512,
    });
    defer connection.deinit();

    const slow = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/slow",
    }, 16);
    var small_streams: [small_count]u32 = undefined;
    inline for (0..small_count) |index| {
        small_streams[index] = try connection.openRequest(&sent_wire.writer, .{
            .method = "GET",
            .scheme = "https",
            .authority = "demo.example.test",
            .path = "/small",
        }, 16);
        try std.testing.expectEqual(@as(u32, @intCast(3 + index * 2)), small_streams[index]);
    }

    var slow_chunk = try readUnackedBodyChunkForStream(&connection, &reader, &sent_wire.writer, slow);
    defer slow_chunk.deinit();
    switch (slow_chunk) {
        .body_chunk => |chunk| {
            try std.testing.expectEqualStrings("zz", chunk.bytes);
            try std.testing.expectEqual(@as(usize, 2), chunk.flow_credit);
            try std.testing.expect(chunk.update_stream_window);
        },
        else => return error.UnexpectedHttp2Event,
    }

    for (small_streams) |stream_id| {
        var response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_id);
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status_code);
        try std.testing.expectEqualStrings("ok", response.body);
    }

    var resets = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .rst_stream);
    defer resets.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{}, resets.items);
    try std.testing.expectEqual(@as(u32, small_count * 2), try sumClientWindowUpdateIncrements(sent_wire.written(), 0));
}

fn readUnackedBodyChunkForStream(
    connection: *egress_http2.Connection,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    stream_id: u32,
) !egress_http2.Event {
    var saw_head = false;
    while (true) {
        var event = try connection.readNextEvent(reader, writer);
        switch (event) {
            .head => |*head| {
                if (head.stream_id != stream_id) {
                    event.deinit();
                    return error.UnexpectedHttp2Head;
                }
                try std.testing.expectEqual(@as(u16, 200), head.result.status_code);
                saw_head = true;
                event.deinit();
            },
            .body_chunk => |chunk| {
                if (chunk.stream_id != stream_id) {
                    event.deinit();
                    return error.UnexpectedHttp2BodyChunk;
                }
                try std.testing.expect(saw_head);
                return event;
            },
            .progress => {
                event.deinit();
                return error.UnexpectedHttp2Progress;
            },
            .end => {
                event.deinit();
                return error.UnexpectedHttp2End;
            },
            .failure => |failure| {
                const err = failure.err;
                event.deinit();
                return err;
            },
        }
    }
}

test "egress http2 multiplexed body allocation belongs to request allocator" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFrames(&server_wire.writer, "200", &.{
        .{ .name = "content-length", .value = "1" },
    }, "x");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    _ = try connection.openRequestAlloc(
        &sent_wire.writer,
        .{
            .method = "GET",
            .scheme = "https",
            .authority = "demo.example.test",
            .path = "/allocation-owner",
        },
        16,
        failing.allocator(),
    );
    try std.testing.expectError(error.OutOfMemory, readCollectedResponse(failing.allocator(), &connection, &reader, &sent_wire.writer, 1));
}

test "egress http2 malformed response fails only its own stream" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    // A connection-specific header makes stream 1's response malformed
    // (RFC 9113 §8.2.2), which is a stream error, not a connection error.
    try appendResponseFramesForStream(&server_wire.writer, 1, "200", &.{
        .{ .name = "connection", .value = "keep-alive" },
        .{ .name = "content-length", .value = "3" },
    }, "bad");
    try appendResponseFramesForStream(&server_wire.writer, 3, "200", &.{
        .{ .name = "content-length", .value = "2" },
    }, "ok");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/malformed",
    }, 16);
    const stream_two = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/clean",
    }, 16);

    try expectStreamFailure(&connection, &reader, &sent_wire.writer, 1, error.Http2MalformedResponse);

    var clean_response = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_two);
    defer clean_response.deinit();
    try std.testing.expectEqualStrings("ok", clean_response.body);
}

test "egress http2 refused stream surfaces a retryable failure" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    var rst: [h2.frame_header_len + 4]u8 = undefined;
    try h2.encodeRstStreamFrame(&rst, 1, .refused_stream);
    try server_wire.writer.writeAll(&rst);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/refused",
    }, 16);

    try expectStreamFailure(&connection, &reader, &sent_wire.writer, 1, error.Http2StreamRefused);
}

test "egress http2 idle connection tolerates late frames for closed streams" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    var settings_frame = try frameFromWire(settings_wire.written());
    defer settings_frame.deinit();
    try std.testing.expectEqual(@as(?egress_http2.client.Event, null), try connection.processEventFrame(&sent_wire.writer, &settings_frame));

    // A late WINDOW_UPDATE for a stream the client no longer tracks is legal
    // in the closed state (RFC 9113 §5.1) and must be ignored.
    var update_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer update_wire.deinit();
    try appendWindowUpdateFrame(&update_wire.writer, 7, 1024);
    var update_frame = try frameFromWire(update_wire.written());
    defer update_frame.deinit();
    try std.testing.expectEqual(@as(?egress_http2.client.Event, null), try connection.processEventFrame(&sent_wire.writer, &update_frame));

    // Deprecated PRIORITY frames are legal on any stream in any state.
    var priority_wire: [h2.frame_header_len + 5]u8 = undefined;
    var priority_header = h2.FrameHeader{
        .length = 5,
        .frame_type_raw = @intFromEnum(h2.FrameType.priority),
        .frame_type = .priority,
        .flags = h2.Flags.fromByte(0),
        .stream_id = 9,
    };
    try priority_header.encode(priority_wire[0..h2.frame_header_len]);
    @memset(priority_wire[h2.frame_header_len..], 0);
    var priority_frame = try frameFromWire(&priority_wire);
    defer priority_frame.deinit();
    try std.testing.expectEqual(@as(?egress_http2.client.Event, null), try connection.processEventFrame(&sent_wire.writer, &priority_frame));

    try std.testing.expect(!connection.closing);
}

test "egress http2 stream receive window grows for fast consumers" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "4096" },
    }, false);
    var chunk: [1024]u8 = undefined;
    @memset(&chunk, 'x');
    try appendDataFrameForStream(&server_wire.writer, 1, &chunk, false);
    try appendDataFrameForStream(&server_wire.writer, 1, &chunk, false);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .max_active_streams = 4,
        .stream_receive_window = 1024,
        .connection_receive_window = 8192,
        .max_pending_body_credit_per_stream = 1024,
        .max_pending_body_credit_per_connection = 8192,
    });
    defer connection.deinit();

    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/large",
    }, 8192);
    try std.testing.expectEqual(@as(u32, 1024), connection.active_streams.items[0].recv_window.target);

    var head_event = try connection.readNextEvent(&reader, &sent_wire.writer);
    try std.testing.expect(head_event == .head);
    head_event.deinit();

    // The consumer drains a full window and acks all of it, so the window
    // doubles toward the connection budget.
    var first_chunk = try connection.readNextEvent(&reader, &sent_wire.writer);
    try std.testing.expect(first_chunk == .body_chunk);
    const first_credit = first_chunk.body_chunk.flow_credit;
    first_chunk.deinit();
    var maybe_end = try connection.ackReceivedData(&sent_wire.writer, 1, first_credit, true);
    try std.testing.expect(maybe_end == null);
    try std.testing.expectEqual(@as(u32, 2048), connection.active_streams.items[0].recv_window.target);
    try std.testing.expectEqual(@as(usize, 2048), connection.active_streams.items[0].pending_credit_cap);

    // The second chunk keeps pace, and the window doubles again, still under
    // the 8192-byte budget.
    var second_chunk = try connection.readNextEvent(&reader, &sent_wire.writer);
    try std.testing.expect(second_chunk == .body_chunk);
    const second_credit = second_chunk.body_chunk.flow_credit;
    second_chunk.deinit();
    maybe_end = try connection.ackReceivedData(&sent_wire.writer, 1, second_credit, true);
    try std.testing.expect(maybe_end == null);
    try std.testing.expectEqual(@as(u32, 4096), connection.active_streams.items[0].recv_window.target);
}
