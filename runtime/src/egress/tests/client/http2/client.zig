//! Tests of single streams on the codec's `Connection`: response validation,
//! HPACK encoder poisoning, flow control in both directions, trailers,
//! interim 1xx responses, resets that must or must not fail a stream, and the
//! billed-byte meters. Everything runs in memory: tests feed hand-built
//! server frames, or header lists straight to the response parser, and
//! inspect the events and the frames the client wrote.

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

test "egress http2 response parser validates status and content length" {
    var head = try egress_http2.parseResponseHead(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
        .{ .name = "content-type", .value = "text/plain" },
    }, false);
    try std.testing.expectEqual(@as(u16, 200), head.status_code);
    try std.testing.expectEqual(@as(?usize, 5), head.content_length);

    var acc = egress_http2.ResponseAccumulator.init(std.testing.allocator, 16);
    defer acc.deinit();
    try acc.receiveHead(head);
    try acc.receiveData("hel", false);
    try std.testing.expectError(error.Http2ContentLengthMismatch, acc.receiveData("!", true));

    var ok = egress_http2.ResponseAccumulator.init(std.testing.allocator, 16);
    defer ok.deinit();
    head = try egress_http2.parseResponseHead(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false);
    try ok.receiveHead(head);
    try ok.receiveData("hello", true);
    const body = try ok.takeBody();
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "egress http2 response parser rejects malformed header blocks" {
    try std.testing.expectError(error.Http2MalformedResponse, egress_http2.parseResponseHead(&.{
        .{ .name = "x-before", .value = "bad" },
        .{ .name = ":status", .value = "200" },
    }, true));
    try std.testing.expectError(error.InvalidHttp2ResponseHeader, egress_http2.parseResponseHead(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "X-UPPER", .value = "bad" },
    }, true));
    try std.testing.expectError(error.Http2MalformedResponse, egress_http2.parseResponseHead(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "transfer-encoding", .value = "chunked" },
    }, true));
}

test "egress http2 hpack encoder poison closes connection for reuse" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const large = try std.testing.allocator.alloc(u8, 64 * 1024 - 1);
    defer std.testing.allocator.free(large);
    @memset(large, '~');

    try std.testing.expectError(error.HpackEncoderPoisoned, connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/poison",
        .headers = &.{
            .{ .name = "x-large", .value = large },
        },
    }, 16));
    try std.testing.expect(connection.closing);

    try std.testing.expectError(error.Http2ConnectionClosed, connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/after",
    }, 16));
}

test "egress http2 client drives settings response and body flow control" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFrames(&server_wire.writer, "200", &.{
        .{ .name = "content-length", .value = "5" },
    }, "hello");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/hello",
    }, 16);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_id);
    defer result.deinit();

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expectEqualStrings("hello", result.body);
    try std.testing.expectEqual(@as(usize, 1), result.headers.len);
    try std.testing.expectEqualStrings("content-length", result.headers[0].name);
    try std.testing.expectEqualStrings("5", result.headers[0].value);
    try std.testing.expectEqualStrings(h2.client_connection_preface, sent_wire.written()[0..h2.client_connection_preface.len]);
    try std.testing.expectEqual(@as(usize, 1), countClientFrames(sent_wire.written(), .window_update));
    try std.testing.expectEqual(
        @as(u64, @intCast(sent_wire.written().len + server_wire.written().len)),
        result.wire_bytes,
    );
}

test "egress http2 client accepts padded data and priority headers" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendPaddedPriorityHeaderFrame(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false, 2);
    try appendPaddedDataFrame(&server_wire.writer, 1, "hello", true, 3);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/padded",
    }, 16);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_id);
    defer result.deinit();

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expectEqualStrings("hello", result.body);
}

test "egress http2 client batches receive window updates" {
    const body = try std.testing.allocator.alloc(u8, 700 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'r');
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFrames(&server_wire.writer, "200", &.{}, body);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .stream_receive_window = 1024 * 1024,
        .connection_receive_window = 4 * 1024 * 1024,
        .max_pending_body_credit_per_stream = 1024 * 1024,
        .max_pending_body_credit_per_connection = 4 * 1024 * 1024,
    });
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/large",
    }, body.len);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_id);
    defer result.deinit();

    try std.testing.expectEqual(body.len, result.body.len);
    try std.testing.expectEqual(@as(usize, 3), countClientFrames(sent_wire.written(), .window_update));
}

test "egress http2 client requires initial peer settings" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendResponseFrames(&server_wire.writer, "200", &.{}, "");
    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();

    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/",
    }, 16);
    try std.testing.expectError(error.Http2MissingInitialSettings, readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_id));
}

test "egress http2 client resumes a large upload after window update" {
    const body = try std.testing.allocator.alloc(u8, h2.default_initial_window_size + 1);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendWindowUpdateFrame(&server_wire.writer, 0, 1);
    try appendWindowUpdateFrame(&server_wire.writer, 1, 1);
    try appendResponseFrames(&server_wire.writer, "204", &.{}, "");
    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();

    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/",
        .body = body,
    }, 16);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_id);
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 204), result.status_code);
    try std.testing.expect(sent_wire.written().len > body.len);
}

test "egress http2 upload emits DATA frames without staging a joined body" {
    const body = try std.testing.allocator.alloc(u8, 40 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'u');
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    _ = try connection.openRequest(
        &sent_wire.writer,
        .{
            .method = "POST",
            .scheme = "https",
            .authority = "demo.example.test",
            .path = "/upload",
            .body = body,
        },
        16,
    );

    try std.testing.expectEqual(@as(usize, 3), countClientFrames(sent_wire.written(), .data));
    try std.testing.expectEqual(body.len, try sumClientFramePayloadBytes(sent_wire.written(), .data));
}

test "egress http2 client accepts validated trailing headers" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFrames(&server_wire.writer, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false);
    const data_wire = try h2.encodeDataFrames(std.testing.allocator, h2.default_max_frame_size, 1, "hello", false);
    defer std.testing.allocator.free(data_wire);
    try server_wire.writer.writeAll(data_wire);
    try appendHeaderFrames(&server_wire.writer, &.{
        .{ .name = "x-checksum", .value = "ok" },
    }, true);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/trailers",
    }, 16);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, stream_id);
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.body);
}

test "egress http2 connection reuses one preface across sequential streams" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFramesForStream(&server_wire.writer, 1, "200", &.{
        .{ .name = "content-length", .value = "3" },
    }, "one");
    try appendResponseFramesForStream(&server_wire.writer, 3, "200", &.{
        .{ .name = "content-length", .value = "3" },
    }, "two");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const first_stream = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/one",
    }, 16);
    var first = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, first_stream);
    defer first.deinit();
    const second_stream = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/two",
    }, 16);
    var second = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, second_stream);
    defer second.deinit();

    try std.testing.expectEqualStrings("one", first.body);
    try std.testing.expectEqualStrings("two", second.body);
    try std.testing.expectEqualStrings(h2.client_connection_preface, sent_wire.written()[0..h2.client_connection_preface.len]);
    var request_stream_ids = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .headers);
    defer request_stream_ids.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, request_stream_ids.items);
}

test "egress http2 event reader reports headers before body completion" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
        .{ .name = "x-test", .value = "early" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 1, "hello", true);
    try appendHeaderFramesForStream(&server_wire.writer, 3, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "0" },
        .{ .name = "x-test", .value = "other" },
    }, true);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/early",
    }, 16);
    const second_stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/other",
    }, 16);

    var head = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expectEqual(@as(u16, 200), event.result.status_code);
            try std.testing.expect(!event.result.end_stream);
            try std.testing.expectEqualStrings("x-test", event.result.headers[1].name);
            try std.testing.expectEqualStrings("early", event.result.headers[1].value);
        },
        .progress => return error.UnexpectedHttp2Progress,
        .end => return error.UnexpectedHttp2End,
        .failure => return error.UnexpectedHttp2Failure,
        .body_chunk => return error.UnexpectedHttp2BodyChunk,
    }

    var chunk = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer chunk.deinit();
    switch (chunk) {
        .body_chunk => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expectEqualStrings("hello", event.bytes);
            try std.testing.expect(event.end_stream);
            try std.testing.expectEqual(@as(usize, 5), event.flow_credit);
            try std.testing.expect(!event.update_stream_window);
        },
        .end => return error.UnexpectedHttp2End,
        .head => return error.UnexpectedHttp2Head,
        .progress => return error.UnexpectedHttp2Progress,
        .failure => return error.UnexpectedHttp2Failure,
    }
    var second_head = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer second_head.deinit();
    switch (second_head) {
        .head => |event| {
            try std.testing.expectEqual(second_stream_id, event.stream_id);
            try std.testing.expect(event.result.end_stream);
            try std.testing.expectEqualStrings("other", event.result.headers[1].value);
        },
        .progress => return error.UnexpectedHttp2Progress,
        .end => return error.UnexpectedHttp2End,
        .body_chunk => return error.UnexpectedHttp2BodyChunk,
        .failure => return error.UnexpectedHttp2Failure,
    }

    const maybe_done = try connection.ackReceivedData(&sent_wire.writer, stream_id, 5, true);
    var done = maybe_done orelse return error.ExpectedHttp2End;
    defer done.deinit();
    switch (done) {
        .end => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
        },
        .head => return error.UnexpectedHttp2Head,
        .progress => return error.UnexpectedHttp2Progress,
        .failure => return error.UnexpectedHttp2Failure,
        .body_chunk => return error.UnexpectedHttp2BodyChunk,
    }
}

test "egress http2 interim 1xx surfaces progress before the final head" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "103" },
        .{ .name = "link", .value = "</style.css>; rel=preload; as=style" },
    }, false);
    try appendResponseFramesForStream(&server_wire.writer, 1, "200", &.{
        .{ .name = "content-length", .value = "5" },
    }, "hello");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/early-hints",
    }, 16);

    // The 103 block never becomes the head, but it must surface as progress
    // because the engine restarts its stall clock on it.
    var progress = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer progress.deinit();
    switch (progress) {
        .progress => |event| try std.testing.expectEqual(stream_id, event.stream_id),
        else => return error.ExpectedHttp2Progress,
    }

    var head = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expectEqual(@as(u16, 200), event.result.status_code);
            // The interim headers must not leak into the final response.
            for (event.result.headers) |header|
                try std.testing.expect(!std.mem.eql(u8, header.name, "link"));
        },
        else => return error.ExpectedHttp2Head,
    }
}

test "egress http2 interim 1xx with END_STREAM fails the stream" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "103" },
    }, true);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/early-hints-end",
    }, 16);

    var failure = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer failure.deinit();
    switch (failure) {
        .failure => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expectEqual(error.Http2MalformedResponse, event.err);
        },
        else => return error.ExpectedHttp2Failure,
    }
}

test "egress http2 cancel restores connection credit for delivered body chunk" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 1, "hello", false);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
    });
    defer connection.deinit();

    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/cancel-after-chunk",
    }, 16);

    var head = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => {},
        else => return error.ExpectedHttp2Head,
    }

    var chunk = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer chunk.deinit();
    switch (chunk) {
        .body_chunk => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expectEqual(@as(usize, 5), event.flow_credit);
        },
        else => return error.ExpectedHttp2BodyChunk,
    }

    try connection.cancelStream(&sent_wire.writer, stream_id);
    try std.testing.expectEqual(@as(u32, 5), try sumClientWindowUpdateIncrements(sent_wire.written(), 0));
    var resets = try clientFrameStreamIds(std.testing.allocator, sent_wire.written(), .rst_stream);
    defer resets.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{stream_id}, resets.items);
}

test "egress http2 trailers defer end behind body credit acks" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 1, "hello", false);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/trailing",
    }, 16);

    var head = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => |event| try std.testing.expect(!event.result.end_stream),
        else => return error.ExpectedHttp2Head,
    }

    var chunk = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer chunk.deinit();
    switch (chunk) {
        .body_chunk => |event| {
            try std.testing.expectEqual(@as(usize, 5), event.flow_credit);
            try std.testing.expect(!event.end_stream);
        },
        else => return error.ExpectedHttp2BodyChunk,
    }

    // Trailers arrive while the consumer still holds the chunk's credit. The
    // stream must stay active, with no `.end`, until that credit is acked;
    // otherwise the late ack fails as Http2UnknownStream and the connection's
    // pending-credit budget leaks.
    var trailer_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer trailer_wire.deinit();
    try appendHeaderFramesForStream(&trailer_wire.writer, 1, &.{
        .{ .name = "x-checksum", .value = "ok" },
    }, true);
    var trailer_frame = try frameFromWire(trailer_wire.written());
    defer trailer_frame.deinit();
    var trailer_event = try connection.processEventFrame(&sent_wire.writer, &trailer_frame);
    defer if (trailer_event) |*event| event.deinit();
    try std.testing.expect(trailer_event == null);

    const maybe_done = try connection.ackReceivedData(&sent_wire.writer, stream_id, 5, true);
    var done = maybe_done orelse return error.ExpectedHttp2End;
    defer done.deinit();
    switch (done) {
        .end => |event| try std.testing.expectEqual(stream_id, event.stream_id),
        else => return error.ExpectedHttp2End,
    }
    try std.testing.expectEqual(@as(usize, 0), connection.pending_body_credit_total);
}

test "egress http2 reset after end stream keeps a credit-deferred stream alive" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 1, "hello", true);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/reset-after-end",
    }, 16);

    var head = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => {},
        else => return error.ExpectedHttp2Head,
    }
    var chunk = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer chunk.deinit();
    switch (chunk) {
        .body_chunk => |event| try std.testing.expect(event.end_stream),
        else => return error.ExpectedHttp2BodyChunk,
    }

    // nginx sends RST_STREAM(NO_ERROR) after the full response. The body is
    // already received and only the credit ack is outstanding, so the stream
    // must not fail.
    var rst_wire: [h2.frame_header_len + 4]u8 = undefined;
    try h2.encodeRstStreamFrame(&rst_wire, stream_id, .no_error);
    var rst_frame = try frameFromWire(&rst_wire);
    defer rst_frame.deinit();
    var rst_event = try connection.processEventFrame(&sent_wire.writer, &rst_frame);
    defer if (rst_event) |*event| event.deinit();
    try std.testing.expect(rst_event == null);

    const maybe_done = try connection.ackReceivedData(&sent_wire.writer, stream_id, 5, false);
    var done = maybe_done orelse return error.ExpectedHttp2End;
    defer done.deinit();
    switch (done) {
        .end => |event| try std.testing.expectEqual(stream_id, event.stream_id),
        else => return error.ExpectedHttp2End,
    }
    try std.testing.expectEqual(@as(usize, 0), connection.pending_body_credit_total);
}

test "egress http2 peer reset restores pending connection credit" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
    }, false);
    try appendDataFrameForStream(&server_wire.writer, 1, "hello", false);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
    });
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/reset-mid-body",
    }, 16);

    var head = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => {},
        else => return error.ExpectedHttp2Head,
    }
    var chunk = try connection.readNextEvent(&reader, &sent_wire.writer);
    defer chunk.deinit();
    switch (chunk) {
        .body_chunk => |event| try std.testing.expectEqual(@as(usize, 5), event.flow_credit),
        else => return error.ExpectedHttp2BodyChunk,
    }

    // A reset mid-body removes the stream while the consumer still holds its
    // chunk credit, so the connection window and the pending-credit budget
    // must be refilled at reset time. The engine drops the consumer's late
    // ack.
    var rst_wire: [h2.frame_header_len + 4]u8 = undefined;
    try h2.encodeRstStreamFrame(&rst_wire, stream_id, .cancel);
    var rst_frame = try frameFromWire(&rst_wire);
    defer rst_frame.deinit();
    const maybe_failure = try connection.processEventFrame(&sent_wire.writer, &rst_frame);
    var failure = maybe_failure orelse return error.ExpectedHttp2Failure;
    defer failure.deinit();
    switch (failure) {
        .failure => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expect(event.err == error.Http2StreamReset);
        },
        else => return error.ExpectedHttp2Failure,
    }
    try std.testing.expectEqual(@as(u32, 5), try sumClientWindowUpdateIncrements(sent_wire.written(), 0));
    try std.testing.expectEqual(@as(usize, 0), connection.pending_body_credit_total);
}

test "egress http2 rejects DATA beyond stream receive window" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .stream_receive_window = 16,
        .connection_receive_window = h2.default_initial_window_size,
        .max_pending_body_credit_per_stream = 64,
        .max_pending_body_credit_per_connection = 1024,
    });
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/flow",
    }, 64);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    var settings_frame = try frameFromWire(settings_wire.written());
    defer settings_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(&sent_wire.writer, &settings_frame)) == null);

    var headers_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer headers_wire.deinit();
    try appendHeaderFramesForStream(&headers_wire.writer, stream_id, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "17" },
    }, false);
    var headers_frame = try frameFromWire(headers_wire.written());
    defer headers_frame.deinit();
    var head = (try connection.processEventFrame(&sent_wire.writer, &headers_frame)) orelse
        return error.ExpectedHttp2Head;
    defer head.deinit();
    try std.testing.expect(head == .head);

    var body: [17]u8 = undefined;
    @memset(&body, 'x');
    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, stream_id, &body, false);
    var data_frame = try frameFromWire(data_wire.written());
    defer data_frame.deinit();
    try std.testing.expectError(
        error.Http2FlowControlError,
        connection.processEventFrame(&sent_wire.writer, &data_frame),
    );
}

test "egress http2 rejects DATA beyond connection receive window" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .stream_receive_window = 128 * 1024,
        .connection_receive_window = h2.default_initial_window_size,
        .max_pending_body_credit_per_stream = 128 * 1024,
        .max_pending_body_credit_per_connection = 128 * 1024,
    });
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/conn-flow",
    }, 128 * 1024);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    var settings_frame = try frameFromWire(settings_wire.written());
    defer settings_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(&sent_wire.writer, &settings_frame)) == null);

    var headers_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer headers_wire.deinit();
    try appendHeaderFramesForStream(&headers_wire.writer, stream_id, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "65536" },
    }, false);
    var headers_frame = try frameFromWire(headers_wire.written());
    defer headers_frame.deinit();
    var head = (try connection.processEventFrame(&sent_wire.writer, &headers_frame)) orelse
        return error.ExpectedHttp2Head;
    defer head.deinit();
    try std.testing.expect(head == .head);

    var chunk: [16 * 1024]u8 = undefined;
    @memset(&chunk, 'x');
    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, stream_id, &chunk, false);
    const wire = data_wire.written();
    const frame_len = h2.frame_header_len + chunk.len;
    var index: usize = 0;
    while (index < 3) : (index += 1) {
        var frame = try frameFromWire(wire);
        defer frame.deinit();
        var event = (try connection.processEventFrame(&sent_wire.writer, &frame)) orelse
            return error.ExpectedHttp2BodyChunk;
        defer event.deinit();
        try std.testing.expect(event == .body_chunk);
    }

    var fourth = try frameFromWire(wire[0..frame_len]);
    defer fourth.deinit();
    try std.testing.expectError(
        error.Http2FlowControlError,
        connection.processEventFrame(&sent_wire.writer, &fourth),
    );
}

// The billed meters count the HTTP payload as sent: HPACK header blocks and
// DATA payload in both directions. Frame headers, padding, the preface,
// SETTINGS, WINDOW_UPDATE and interim 1xx blocks are transport cost and must
// never appear in them.

test "egress http2 billed meters count header blocks and body payload only" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFrames(&server_wire.writer, "200", &.{
        .{ .name = "content-length", .value = "5" },
    }, "hello");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const opened = try connection.openRequestAllocMetered(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/billed",
    }, 16, std.testing.allocator);
    // The request side bills, at open, exactly the HEADERS payload on the
    // wire, which is the HPACK block; the preface, SETTINGS and window
    // updates are excluded.
    try std.testing.expectEqual(
        @as(u64, @intCast(try sumClientFramePayloadBytes(sent_wire.written(), .headers))),
        opened.billed_sent,
    );

    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, opened.stream_id);
    defer result.deinit();
    const head_block_len = try test_support.encodedHeaderBlockLen(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    });
    try std.testing.expectEqual(@as(u64, @intCast(head_block_len)), result.billed_head_bytes);
    try std.testing.expectEqual(opened.billed_sent, result.billed_sent);
    try std.testing.expectEqual(@as(u64, @intCast(head_block_len + 5)), result.billed_received);
    // Billed stays strictly below the plaintext wire counter; the difference
    // is the framing and control overhead, which is cost.
    try std.testing.expect(result.billed_sent + result.billed_received < result.wire_bytes);
}

test "egress http2 billed meters count a bodyless 204 as head block only" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFrames(&server_wire.writer, "204", &.{}, "");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const opened = try connection.openRequestAllocMetered(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/nothing",
    }, 16, std.testing.allocator);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, opened.stream_id);
    defer result.deinit();

    try std.testing.expectEqual(@as(u16, 204), result.status_code);
    const head_block_len = try test_support.encodedHeaderBlockLen(&.{
        .{ .name = ":status", .value = "204" },
    });
    try std.testing.expectEqual(@as(u64, @intCast(head_block_len)), result.billed_received);
    try std.testing.expectEqual(opened.billed_sent, result.billed_sent);
}

test "egress http2 billed meters exclude interim 1xx header blocks" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFrames(&server_wire.writer, &.{
        .{ .name = ":status", .value = "103" },
        .{ .name = "link", .value = "</style.css>; rel=preload" },
    }, false);
    try appendResponseFrames(&server_wire.writer, "200", &.{
        .{ .name = "content-length", .value = "5" },
    }, "hello");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const opened = try connection.openRequestAllocMetered(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/hints",
    }, 16, std.testing.allocator);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, opened.stream_id);
    defer result.deinit();

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    // Billed received counts only the final head block and the payload; the
    // 103 block surfaced as progress and is never billed.
    const head_block_len = try test_support.encodedHeaderBlockLen(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    });
    try std.testing.expectEqual(@as(u64, @intCast(head_block_len)), result.billed_head_bytes);
    try std.testing.expectEqual(@as(u64, @intCast(head_block_len + 5)), result.billed_received);
}

test "egress http2 billed meters count trailer blocks" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFrames(&server_wire.writer, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false);
    const data_wire = try h2.encodeDataFrames(std.testing.allocator, h2.default_max_frame_size, 1, "hello", false);
    defer std.testing.allocator.free(data_wire);
    try server_wire.writer.writeAll(data_wire);
    try appendHeaderFrames(&server_wire.writer, &.{
        .{ .name = "x-checksum", .value = "ok" },
    }, true);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const opened = try connection.openRequestAllocMetered(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/trailers",
    }, 16, std.testing.allocator);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, opened.stream_id);
    defer result.deinit();

    const head_block_len = try test_support.encodedHeaderBlockLen(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    });
    const trailer_block_len = try test_support.encodedHeaderBlockLen(&.{
        .{ .name = "x-checksum", .value = "ok" },
    });
    try std.testing.expectEqual(
        @as(u64, @intCast(head_block_len + 5 + trailer_block_len)),
        result.billed_received,
    );
}

test "egress http2 billed meters strip padding and priority sections" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendPaddedPriorityHeaderFrame(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false, 2);
    try appendPaddedDataFrame(&server_wire.writer, 1, "hello", true, 3);

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    const opened = try connection.openRequestAllocMetered(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/padded",
    }, 16, std.testing.allocator);
    var result = try readCollectedResponse(std.testing.allocator, &connection, &reader, &sent_wire.writer, opened.stream_id);
    defer result.deinit();

    // Payload counts; the pad-length octet, padding, and the 5-byte priority
    // section do not.
    const head_block_len = try test_support.encodedHeaderBlockLen(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    });
    try std.testing.expectEqual(@as(u64, @intCast(head_block_len + 5)), result.billed_received);
}

test "egress http2 billed meters count upload DATA payload" {
    const body = try std.testing.allocator.alloc(u8, 40 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'u');
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();

    const opened = try connection.openRequestAllocMetered(&sent_wire.writer, .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/upload",
        .body = body,
    }, 16, std.testing.allocator);

    // The whole body fits the default send windows, so open reports the
    // header block plus the upload payload, without DATA frame headers.
    const headers_payload = try sumClientFramePayloadBytes(sent_wire.written(), .headers);
    const data_payload = try sumClientFramePayloadBytes(sent_wire.written(), .data);
    try std.testing.expectEqual(body.len, data_payload);
    try std.testing.expectEqual(@as(u64, @intCast(headers_payload + data_payload)), opened.billed_sent);
}
