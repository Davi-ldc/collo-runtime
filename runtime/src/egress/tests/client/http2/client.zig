//! Tests of single streams on the codec's `Connection`: response validation,
//! the head event that owns the stream's one header decode, also when an
//! allocation fails, request heads refused by their worst-case block before
//! the encoder sees them, flow control in both directions with the checks on
//! a consumer's acks, trailers, interim 1xx responses, DATA before a head,
//! and resets that must or must not fail a stream. Everything runs in
//! memory: tests feed hand-built server frames, or header lists straight to
//! the response parser, and inspect the events and the frames the client
//! wrote.

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
    try std.testing.expectEqual(@as(usize, 2), head.regular_headers.len);
    try std.testing.expectEqualStrings("content-length", head.regular_headers[0].name);

    var short = egress_http2.ResponseState.init(16);
    try std.testing.expectEqual(egress_http2.ResponseState.HeadKind.final, try short.receiveHead(head));
    try short.receiveData(3, false);
    try std.testing.expectError(error.Http2ContentLengthMismatch, short.receiveData(1, true));

    var ok = egress_http2.ResponseState.init(16);
    head = try egress_http2.parseResponseHead(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-length", .value = "5" },
    }, false);
    _ = try ok.receiveHead(head);
    try ok.receiveData(5, true);
    try std.testing.expect(ok.complete);
    try std.testing.expectEqual(@as(usize, 5), ok.received_body_bytes);

    // An interim head leaves the state waiting for the final one.
    var waiting = egress_http2.ResponseState.init(16);
    const interim = try egress_http2.parseResponseHead(&.{.{ .name = ":status", .value = "103" }}, false);
    try std.testing.expectEqual(egress_http2.ResponseState.HeadKind.interim, try waiting.receiveHead(interim));
    try std.testing.expectError(error.Http2MalformedResponse, waiting.receiveData(1, false));
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

test "egress http2 response parser refuses te in a head and in trailers, even as trailers" {
    try std.testing.expectError(error.Http2MalformedResponse, egress_http2.parseResponseHead(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "te", .value = "trailers" },
    }, true));
    try std.testing.expectError(error.Http2MalformedResponse, egress_http2.parseResponseHead(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "te", .value = "gzip" },
    }, true));
    try std.testing.expectError(error.Http2MalformedResponse, egress_http2.response.validateTrailers(&.{
        .{ .name = "te", .value = "trailers" },
    }));
}

test "an oversized request head fails alone and never reaches the connection's encoder" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer connection.deinit();

    // '~' has a 13-bit Huffman code, so the value would go out raw, and the
    // block could not fit the request block cap. The fields before it are
    // ones an encoder that ran would have added to its dynamic table.
    const large = try std.testing.allocator.alloc(u8, 64 * 1024 - 1);
    defer std.testing.allocator.free(large);
    @memset(large, '~');
    const oversized: egress_http2.RequestHead = .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/oversized",
        .headers = &.{
            .{ .name = "x-before", .value = "indexed" },
            .{ .name = "x-large", .value = large },
        },
    };
    try std.testing.expectError(error.Http2RequestHeadersTooLarge, egress_http2.validateRequestHead(oversized));
    try std.testing.expectError(error.Http2RequestHeadersTooLarge, connection.openRequest(&sent_wire.writer, oversized, 16));
    try std.testing.expect(!connection.closing);
    try std.testing.expect(connection.canOpenStream());

    // The next block is the first the peer sees. A fresh decoder takes it
    // only if the encoder's table holds nothing from the refused head, which
    // its fields would otherwise refer to.
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/oversized",
        .headers = &.{.{ .name = "x-before", .value = "indexed" }},
    }, 16);
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(
        std.testing.allocator,
        test_support.scratch.decode,
        try test_support.clientHeaderBlock(sent_wire.written(), stream_id),
        16,
        4096,
    );
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), decoded.headers.len);
    try std.testing.expectEqualStrings(":authority", decoded.headers[2].name);
    try std.testing.expectEqualStrings("demo.example.test", decoded.headers[2].value);
    try std.testing.expectEqualStrings("x-before", decoded.headers[4].name);
    try std.testing.expectEqualStrings("indexed", decoded.headers[4].value);
}

test "a request head's worst-case block, not its compressed size, decides whether it fits" {
    // Every field counts as a raw literal: one prefix byte, then each
    // string's length byte or bytes and its bytes.
    const value = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(value);
    @memset(value, 'a');
    try egress_http2.validateRequestHead(.{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/",
        .headers = &.{.{ .name = "x-half", .value = value }},
    });
    // Two such values compress far below the cap, since 'a' takes five bits,
    // but their raw form does not fit it.
    try std.testing.expectError(error.Http2RequestHeadersTooLarge, egress_http2.validateRequestHead(.{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/",
        .headers = &.{
            .{ .name = "x-first", .value = value },
            .{ .name = "x-second", .value = value },
        },
    }));
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
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
    }, &test_support.scratch);
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

    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
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

    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
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

    var head = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expectEqual(@as(u16, 200), event.status_code);
            try std.testing.expect(!event.end_stream);
            try std.testing.expectEqualStrings("x-test", event.headers[1].name);
            try std.testing.expectEqualStrings("early", event.headers[1].value);
        },
        .progress => return error.UnexpectedHttp2Progress,
        .end => return error.UnexpectedHttp2End,
        .failure => return error.UnexpectedHttp2Failure,
        .body_chunk => return error.UnexpectedHttp2BodyChunk,
    }

    var chunk = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
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
    var second_head = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer second_head.deinit();
    switch (second_head) {
        .head => |event| {
            try std.testing.expectEqual(second_stream_id, event.stream_id);
            try std.testing.expect(event.end_stream);
            try std.testing.expectEqualStrings("other", event.headers[1].value);
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer connection.deinit();

    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/early-hints",
    }, 16);

    // The 103 block never becomes the head, but it must surface as progress
    // because the engine restarts its stall clock on it.
    var progress = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer progress.deinit();
    switch (progress) {
        .progress => |event| try std.testing.expectEqual(stream_id, event.stream_id),
        else => return error.ExpectedHttp2Progress,
    }

    var head = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expectEqual(@as(u16, 200), event.status_code);
            // The interim headers must not leak into the final response.
            for (event.headers) |header|
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer connection.deinit();

    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/early-hints-end",
    }, 16);

    var failure = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
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
    }, &test_support.scratch);
    defer connection.deinit();

    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/cancel-after-chunk",
    }, 16);

    var head = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => {},
        else => return error.ExpectedHttp2Head,
    }

    var chunk = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/trailing",
    }, 16);

    var head = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => |event| try std.testing.expect(!event.end_stream),
        else => return error.ExpectedHttp2Head,
    }

    var chunk = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
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
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/reset-after-end",
    }, 16);

    var head = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => {},
        else => return error.ExpectedHttp2Head,
    }
    var chunk = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
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
    }, &test_support.scratch);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/reset-mid-body",
    }, 16);

    var head = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => {},
        else => return error.ExpectedHttp2Head,
    }
    var chunk = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
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

/// Opens a GET on `connection`, then feeds it the server's SETTINGS and a
/// final head without END_STREAM for that stream. Returns the stream id.
fn openStreamWithHead(connection: *egress_http2.Connection, writer: *std.Io.Writer) !u32 {
    const stream_id = try connection.openRequest(writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/credit",
    }, 64);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    var settings_frame = try frameFromWire(settings_wire.written());
    defer settings_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(writer, &settings_frame)) == null);

    var headers_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer headers_wire.deinit();
    try appendHeaderFramesForStream(&headers_wire.writer, stream_id, &.{.{ .name = ":status", .value = "200" }}, false);
    var headers_frame = try frameFromWire(headers_wire.written());
    defer headers_frame.deinit();
    var head = (try connection.processEventFrame(writer, &headers_frame)) orelse return error.ExpectedHttp2Head;
    defer head.deinit();
    if (head != .head)
        return error.ExpectedHttp2Head;
    return stream_id;
}

/// Feeds `connection` one DATA frame for `stream_id` and returns the body
/// chunk it yields, which the caller deinits.
fn receiveBodyChunk(
    connection: *egress_http2.Connection,
    writer: *std.Io.Writer,
    stream_id: u32,
    bytes: []const u8,
    end_stream: bool,
) !egress_http2.Event {
    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, stream_id, bytes, end_stream);
    var frame = try frameFromWire(data_wire.written());
    defer frame.deinit();
    var event = (try connection.processEventFrame(writer, &frame)) orelse return error.ExpectedHttp2BodyChunk;
    if (event != .body_chunk) {
        event.deinit();
        return error.ExpectedHttp2BodyChunk;
    }
    return event;
}

test "an ack above the credit a stream holds fails before any window reopens" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    // With a one-byte threshold every acked byte goes out as WINDOW_UPDATE
    // at once, on both windows, so a window the ack reopened would show.
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
    }, &test_support.scratch);
    defer connection.deinit();
    const stream_id = try openStreamWithHead(&connection, &sent_wire.writer);
    var chunk = try receiveBodyChunk(&connection, &sent_wire.writer, stream_id, "hello", false);
    defer chunk.deinit();
    try std.testing.expectEqual(@as(usize, 5), chunk.body_chunk.flow_credit);

    const sent_before = sent_wire.written().len;
    try std.testing.expectError(
        error.Http2AckExceedsPendingCredit,
        connection.ackReceivedData(&sent_wire.writer, stream_id, 6, true),
    );
    try std.testing.expectEqual(sent_before, sent_wire.written().len);
    try std.testing.expectEqual(@as(usize, 5), connection.pending_body_credit_total);

    // The stream still holds its credit, and acking exactly that reopens
    // each window by exactly that much.
    try std.testing.expect((try connection.ackReceivedData(&sent_wire.writer, stream_id, 5, true)) == null);
    try std.testing.expectEqual(@as(u32, 5), try sumClientWindowUpdateIncrements(sent_wire.written(), 0));
    try std.testing.expectEqual(@as(u32, 5), try sumClientWindowUpdateIncrements(sent_wire.written(), stream_id));
    try std.testing.expectEqual(@as(usize, 0), connection.pending_body_credit_total);
}

test "one ack returns several chunks' credit, and the last chunk's own ack ends the stream" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
    }, &test_support.scratch);
    defer connection.deinit();
    const stream_id = try openStreamWithHead(&connection, &sent_wire.writer);

    // A consumer may sum the credits that reopen the stream window into one
    // ack, and ack the chunk that ended the stream, whose stream window
    // needs no update, on its own.
    var first = try receiveBodyChunk(&connection, &sent_wire.writer, stream_id, "ab", false);
    defer first.deinit();
    var second = try receiveBodyChunk(&connection, &sent_wire.writer, stream_id, "cde", false);
    defer second.deinit();
    var last = try receiveBodyChunk(&connection, &sent_wire.writer, stream_id, "f", true);
    defer last.deinit();
    try std.testing.expect(first.body_chunk.update_stream_window);
    try std.testing.expect(second.body_chunk.update_stream_window);
    try std.testing.expect(!last.body_chunk.update_stream_window);

    const summed = first.body_chunk.flow_credit + second.body_chunk.flow_credit;
    try std.testing.expect((try connection.ackReceivedData(&sent_wire.writer, stream_id, summed, true)) == null);
    var done = (try connection.ackReceivedData(&sent_wire.writer, stream_id, last.body_chunk.flow_credit, false)) orelse
        return error.ExpectedHttp2End;
    defer done.deinit();
    switch (done) {
        .end => |event| try std.testing.expectEqual(stream_id, event.stream_id),
        else => return error.ExpectedHttp2End,
    }
    try std.testing.expectEqual(@as(usize, 0), connection.pending_body_credit_total);
    try std.testing.expectEqual(@as(u32, 6), try sumClientWindowUpdateIncrements(sent_wire.written(), 0));
    try std.testing.expectEqual(@as(u32, 5), try sumClientWindowUpdateIncrements(sent_wire.written(), stream_id));
}

test "egress http2 rejects DATA beyond stream receive window" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .stream_receive_window = 16,
        .connection_receive_window = h2.default_initial_window_size,
        .max_pending_body_credit_per_stream = 64,
        .max_pending_body_credit_per_connection = 1024,
    }, &test_support.scratch);
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
    }, &test_support.scratch);
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

test "a head event owns the stream's one header decode and outlives a later header block" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/owned-head",
    }, 64);
    const later_stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/later-head",
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
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "x-trace", .value = "abc" },
    }, false);
    var headers_frame = try frameFromWire(headers_wire.written());
    defer headers_frame.deinit();
    var head = (try connection.processEventFrame(&sent_wire.writer, &headers_frame)) orelse
        return error.ExpectedHttp2Head;
    defer head.deinit();

    // The later block runs through the same decode scratch and the same
    // pending-block buffer, with fields of the same lengths in the same
    // order, so a head that pointed into either would now read the later
    // values.
    var later_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer later_wire.deinit();
    try appendHeaderFramesForStream(&later_wire.writer, later_stream_id, &.{
        .{ .name = ":status", .value = "404" },
        .{ .name = "content-type", .value = "image/webp" },
        .{ .name = "x-trace", .value = "xyz" },
    }, false);
    var later_frame = try frameFromWire(later_wire.written());
    defer later_frame.deinit();
    var later = (try connection.processEventFrame(&sent_wire.writer, &later_frame)) orelse
        return error.ExpectedHttp2Head;
    defer later.deinit();
    switch (later) {
        .head => |event| {
            try std.testing.expectEqual(later_stream_id, event.stream_id);
            try std.testing.expectEqualStrings("image/webp", event.headers[0].value);
            try std.testing.expectEqualStrings("xyz", event.headers[1].value);
        },
        else => return error.ExpectedHttp2Head,
    }

    switch (head) {
        .head => |event| {
            try std.testing.expectEqual(@as(u16, 200), event.status_code);
            // The regular fields only: `:status` stays in the block.
            try std.testing.expectEqual(@as(usize, 2), event.headers.len);
            try std.testing.expectEqual(event.block.headers.len, event.headers.len + 1);
            try std.testing.expectEqualStrings(":status", event.block.headers[0].name);
            try std.testing.expectEqualStrings("content-type", event.headers[0].name);
            try std.testing.expectEqualStrings("text/plain", event.headers[0].value);
            try std.testing.expectEqualStrings("x-trace", event.headers[1].name);
            try std.testing.expectEqualStrings("abc", event.headers[1].value);
        },
        else => return error.ExpectedHttp2Head,
    }
}

/// Reads one head through a connection that takes every allocation from
/// `allocator`: the request, the server's SETTINGS acknowledgement, the
/// pending header block and the head's decode.
fn decodeOneHead(allocator: std.mem.Allocator, server_frames: []const u8) !void {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(allocator, &test_support.scratch);
    defer connection.deinit();
    _ = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/allocation-failure",
    }, 16);
    var reader = std.Io.Reader.fixed(server_frames);
    var event = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer event.deinit();
    switch (event) {
        .head => |head| {
            try std.testing.expectEqual(@as(u16, 200), head.status_code);
            try std.testing.expectEqual(@as(usize, 2), head.headers.len);
            try std.testing.expectEqualStrings("x-trace", head.headers[1].name);
            try std.testing.expectEqualStrings("abc", head.headers[1].value);
        },
        else => return error.ExpectedHttp2Head,
    }
}

test "a head decode that runs out of memory at any allocation keeps nothing it took" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendHeaderFramesForStream(&server_wire.writer, 1, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "x-trace", .value = "abc" },
    }, false);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeOneHead, .{server_wire.written()});
}

test "a head that ends its stream surfaces the stream's end on a zero-credit ack" {
    var server_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer server_wire.deinit();
    try appendSettingsFrame(&server_wire.writer);
    try appendResponseFrames(&server_wire.writer, "204", &.{}, "");

    var reader = std.Io.Reader.fixed(server_wire.written());
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer connection.deinit();
    const stream_id = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/nothing",
    }, 16);

    var head = try test_support.readEvent(&connection, &reader, &sent_wire.writer);
    defer head.deinit();
    switch (head) {
        .head => |event| {
            try std.testing.expectEqual(@as(u16, 204), event.status_code);
            try std.testing.expect(event.end_stream);
        },
        else => return error.ExpectedHttp2Head,
    }
    // No credit is outstanding, so the stream waits only for an ack to report
    // its end; the engine acks zero credit for exactly this.
    try std.testing.expect(connection.hasActiveStreams());
    var done = (try connection.ackReceivedData(&sent_wire.writer, stream_id, 0, false)) orelse
        return error.ExpectedHttp2End;
    defer done.deinit();
    switch (done) {
        .end => |event| try std.testing.expectEqual(stream_id, event.stream_id),
        else => return error.ExpectedHttp2End,
    }
    try std.testing.expect(!connection.hasActiveStreams());
}

test "DATA before a stream's final head fails only that stream and reopens the connection window" {
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .connection_receive_window = h2.default_initial_window_size,
        .receive_window_update_threshold = 1,
    }, &test_support.scratch);
    defer connection.deinit();
    const early_stream = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/early-data",
    }, 64);
    const healthy_stream = try connection.openRequest(&sent_wire.writer, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/healthy",
    }, 64);

    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    var settings_frame = try frameFromWire(settings_wire.written());
    defer settings_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(&sent_wire.writer, &settings_frame)) == null);
    const window_updates_before = try sumClientWindowUpdateIncrements(sent_wire.written(), 0);

    var data_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_wire.deinit();
    try appendDataFrameForStream(&data_wire.writer, early_stream, "early", false);
    var data_frame = try frameFromWire(data_wire.written());
    defer data_frame.deinit();
    var failure = (try connection.processEventFrame(&sent_wire.writer, &data_frame)) orelse
        return error.ExpectedHttp2Failure;
    defer failure.deinit();
    switch (failure) {
        .failure => |event| {
            try std.testing.expectEqual(early_stream, event.stream_id);
            try std.testing.expectEqual(error.Http2MalformedResponse, event.err);
        },
        else => return error.ExpectedHttp2Failure,
    }
    try std.testing.expectEqual(
        window_updates_before + 5,
        try sumClientWindowUpdateIncrements(sent_wire.written(), 0),
    );
    try std.testing.expectEqual(@as(usize, 0), connection.pending_body_credit_total);

    // The other stream on the connection still gets its response.
    var headers_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer headers_wire.deinit();
    try appendHeaderFramesForStream(&headers_wire.writer, healthy_stream, &.{
        .{ .name = ":status", .value = "200" },
    }, false);
    var headers_frame = try frameFromWire(headers_wire.written());
    defer headers_frame.deinit();
    var head = (try connection.processEventFrame(&sent_wire.writer, &headers_frame)) orelse
        return error.ExpectedHttp2Head;
    defer head.deinit();
    switch (head) {
        .head => |event| try std.testing.expectEqual(healthy_stream, event.stream_id),
        else => return error.ExpectedHttp2Head,
    }
}

test "two connections sharing one HPACK scratch each keep their own dynamic table" {
    // Each server encoder indexes its field, so its second block refers to
    // its connection's dynamic table. The heads arrive interleaved through
    // the one scratch, as on an engine shard.
    var first_server = try hpack.Encoder.init();
    defer first_server.deinit();
    var second_server = try hpack.Encoder.init();
    defer second_server.deinit();

    var first_sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first_sent.deinit();
    var second_sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second_sent.deinit();
    var first = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer first.deinit();
    var second = try egress_http2.Connection.init(std.testing.allocator, &test_support.scratch);
    defer second.deinit();
    try startServedConnection(&first, &first_sent.writer);
    try startServedConnection(&second, &second_sent.writer);

    for ([_]u32{ 1, 3 }) |stream_id| {
        const first_open = try first.openRequest(&first_sent.writer, .{
            .method = "GET",
            .scheme = "https",
            .authority = "first.example.test",
            .path = "/",
        }, 16);
        const second_open = try second.openRequest(&second_sent.writer, .{
            .method = "GET",
            .scheme = "https",
            .authority = "second.example.test",
            .path = "/",
        }, 16);
        try std.testing.expectEqual(stream_id, first_open);
        try std.testing.expectEqual(stream_id, second_open);

        try expectServedHead(&first, &first_sent.writer, &first_server, stream_id, "first-connection-value");
        try expectServedHead(&second, &second_sent.writer, &second_server, stream_id, "second-connection-value");
    }
}

fn startServedConnection(connection: *egress_http2.Connection, writer: *std.Io.Writer) !void {
    var settings_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer settings_wire.deinit();
    try appendSettingsFrame(&settings_wire.writer);
    var settings_frame = try frameFromWire(settings_wire.written());
    defer settings_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(writer, &settings_frame)) == null);
}

/// Feeds `connection` a head for `stream_id` that `server` encodes with a
/// `x-shared` field of `value`, which the server indexes, and expects the
/// decoded head to carry it, ending the stream through the zero-credit ack.
fn expectServedHead(
    connection: *egress_http2.Connection,
    writer: *std.Io.Writer,
    server: *hpack.Encoder,
    stream_id: u32,
    value: []const u8,
) !void {
    var storage: [512]u8 = undefined;
    const block = try server.encodeHeaders(&storage, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "x-shared", .value = value },
    }, storage.len);
    const wire = try h2.encodeHeadersFrames(std.testing.allocator, h2.default_max_frame_size, stream_id, block, true);
    defer std.testing.allocator.free(wire);
    var frame = try frameFromWire(wire);
    defer frame.deinit();
    var head = (try connection.processEventFrame(writer, &frame)) orelse return error.ExpectedHttp2Head;
    defer head.deinit();
    switch (head) {
        .head => |event| {
            try std.testing.expectEqual(stream_id, event.stream_id);
            try std.testing.expectEqualStrings("x-shared", event.headers[0].name);
            try std.testing.expectEqualStrings(value, event.headers[0].value);
        },
        else => return error.ExpectedHttp2Head,
    }
    var done = (try connection.ackReceivedData(writer, stream_id, 0, false)) orelse return error.ExpectedHttp2End;
    done.deinit();
}
