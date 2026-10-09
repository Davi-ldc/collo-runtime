//! Tests of the codec's session and framing layer: the client preface and
//! SETTINGS, the initial connection window, request encoding (pseudo-header
//! order, synthesized content-length, forbidden headers), SETTINGS and idle
//! control frames, and frames split across partial reads. Everything runs in
//! memory: tests feed hand-built frames and decode what the client or the
//! encoder wrote.

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

test "egress http2 session emits preface and client settings" {
    var session = try egress_http2.Session.init(std.testing.allocator);
    defer session.deinit();

    const wire = try session.encodeConnectionPrefaceAndSettings(std.testing.allocator);
    defer std.testing.allocator.free(wire);

    try std.testing.expectEqualStrings(h2.client_connection_preface, wire[0..h2.client_connection_preface.len]);
    const header = try h2.FrameHeader.parse(wire[h2.client_connection_preface.len..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.settings, header.frame_type);
    try std.testing.expectEqual(@as(u32, 0), header.stream_id);
    try std.testing.expectEqual(@as(u32, h2.setting_wire_len * 4), header.length);

    const payload = wire[h2.client_connection_preface.len + h2.frame_header_len ..];
    var settings_storage: [h2.Settings.max_settings_per_frame]h2.Setting = undefined;
    const settings = try h2.Settings.parseInto(&settings_storage, payload);
    try std.testing.expectEqual(@as(usize, 4), settings.values.len);
    try std.testing.expectEqual(h2.SettingId.header_table_size, settings.values[0].id);
    try std.testing.expectEqual(h2.SettingId.enable_push, settings.values[1].id);
    try std.testing.expectEqual(@as(u32, 0), settings.values[1].value);
    try std.testing.expectEqual(h2.SettingId.initial_window_size, settings.values[2].id);
    try std.testing.expectEqual(h2.SettingId.max_header_list_size, settings.values[3].id);
    try std.testing.expectEqual(@as(u32, 256 * 1024), settings.values[3].value);
}

test "egress http2 connection advertises bounded receive windows" {
    var connection = try egress_http2.Connection.init(std.testing.allocator);
    defer connection.deinit();
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();

    try connection.start(&sent_wire.writer);
    const wire = sent_wire.written();
    var cursor: usize = h2.client_connection_preface.len;
    const settings_header = try h2.FrameHeader.parse(wire[cursor..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.settings, settings_header.frame_type);
    cursor += h2.frame_header_len;
    var settings_storage: [h2.Settings.max_settings_per_frame]h2.Setting = undefined;
    const settings = try h2.Settings.parseInto(&settings_storage, wire[cursor..][0..settings_header.length]);
    cursor += settings_header.length;
    try std.testing.expectEqual(h2.SettingId.initial_window_size, settings.values[2].id);
    try std.testing.expectEqual(@as(u32, 256 * 1024), settings.values[2].value);

    const update_header = try h2.FrameHeader.parse(wire[cursor..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.window_update, update_header.frame_type);
    try std.testing.expectEqual(@as(u32, 0), update_header.stream_id);
    try std.testing.expectEqual(@as(u32, 4), update_header.length);
    const increment = h2.wire.readU31(wire[cursor + h2.frame_header_len ..][0..4]);
    try std.testing.expectEqual(@as(u32, 4 * 1024 * 1024 - h2.default_initial_window_size), increment);
}

test "egress http2 request encoder creates pseudo headers before regular headers" {
    var session = try egress_http2.Session.init(std.testing.allocator);
    defer session.deinit();
    const stream_id = try session.openStream();

    var encoded = try session.encodeRequest(stream_id, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/hello?x=1",
        .headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    defer encoded.deinit();

    const first_header = try h2.FrameHeader.parse(encoded.wire[0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.headers, first_header.frame_type);
    try std.testing.expect(first_header.flags.end_stream);
    try std.testing.expect(first_header.flags.end_headers_or_ack);
    try std.testing.expectEqual(stream_id, first_header.stream_id);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(
        std.testing.allocator,
        encoded.wire[h2.frame_header_len..],
        16,
        4096,
    );
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), decoded.headers.len);
    try std.testing.expectEqualStrings(":method", decoded.headers[0].name);
    try std.testing.expectEqualStrings("GET", decoded.headers[0].value);
    try std.testing.expectEqualStrings(":scheme", decoded.headers[1].name);
    try std.testing.expectEqualStrings(":authority", decoded.headers[2].name);
    try std.testing.expectEqualStrings(":path", decoded.headers[3].name);
    try std.testing.expectEqualStrings("accept", decoded.headers[4].name);
}

test "egress http2 request encoder synthesizes content-length for bodies" {
    var session = try egress_http2.Session.init(std.testing.allocator);
    defer session.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    // An inline body declares its own length.
    var with_body = try session.encodeRequest(try session.openStream(), .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/submit",
        .body = "hello",
    });
    defer with_body.deinit();
    const with_body_header = try h2.FrameHeader.parse(with_body.wire[0..h2.frame_header_len]);
    var decoded_with_body = try decoder.decodeBlock(
        std.testing.allocator,
        with_body.wire[h2.frame_header_len..][0..with_body_header.length],
        16,
        4096,
    );
    defer decoded_with_body.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("content-length", decoded_with_body.headers[4].name);
    try std.testing.expectEqualStrings("5", decoded_with_body.headers[4].value);

    // A body sent later as DATA frames declares its length up front.
    var declared = try session.encodeRequest(try session.openStream(), .{
        .method = "PUT",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/upload",
        .end_stream_after_headers = false,
        .declared_content_length = 1234,
    });
    defer declared.deinit();
    const declared_header = try h2.FrameHeader.parse(declared.wire[0..h2.frame_header_len]);
    var decoded_declared = try decoder.decodeBlock(
        std.testing.allocator,
        declared.wire[h2.frame_header_len..][0..declared_header.length],
        16,
        4096,
    );
    defer decoded_declared.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("content-length", decoded_declared.headers[4].name);
    try std.testing.expectEqualStrings("1234", decoded_declared.headers[4].value);

    // A POST with an empty body still declares zero, as curl and Bun do.
    var empty_post = try session.encodeRequest(try session.openStream(), .{
        .method = "POST",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/submit",
    });
    defer empty_post.deinit();
    const empty_post_header = try h2.FrameHeader.parse(empty_post.wire[0..h2.frame_header_len]);
    var decoded_empty_post = try decoder.decodeBlock(
        std.testing.allocator,
        empty_post.wire[h2.frame_header_len..][0..empty_post_header.length],
        16,
        4096,
    );
    defer decoded_empty_post.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("content-length", decoded_empty_post.headers[4].name);
    try std.testing.expectEqualStrings("0", decoded_empty_post.headers[4].value);

    // A GET without a body carries no content-length.
    var get = try session.encodeRequest(try session.openStream(), .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/",
    });
    defer get.deinit();
    const get_header = try h2.FrameHeader.parse(get.wire[0..h2.frame_header_len]);
    var decoded_get = try decoder.decodeBlock(
        std.testing.allocator,
        get.wire[h2.frame_header_len..][0..get_header.length],
        16,
        4096,
    );
    defer decoded_get.deinit(std.testing.allocator);
    for (decoded_get.headers) |header|
        try std.testing.expect(!std.mem.eql(u8, header.name, "content-length"));
}

test "egress http2 request encoder rejects connection scoped headers" {
    var session = try egress_http2.Session.init(std.testing.allocator);
    defer session.deinit();
    const stream_id = try session.openStream();

    try std.testing.expectError(error.ForbiddenHttp2RequestHeader, egress_http2.validateRequestHead(.{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/",
        .headers = &.{.{ .name = "connection", .value = "keep-alive" }},
    }));
    try std.testing.expectError(error.ForbiddenHttp2RequestHeader, session.encodeRequest(stream_id, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/",
        .headers = &.{.{ .name = "connection", .value = "keep-alive" }},
    }));
    try std.testing.expectError(error.InvalidHttp2RequestHeader, session.encodeRequest(stream_id, .{
        .method = "GET",
        .scheme = "https",
        .authority = "demo.example.test",
        .path = "/",
        .headers = &.{.{ .name = "X-UPPER", .value = "bad" }},
    }));
}

test "egress http2 settings frame updates peer settings and returns ack" {
    var session = try egress_http2.Session.init(std.testing.allocator);
    defer session.deinit();

    var payload: [h2.setting_wire_len * 2]u8 = undefined;
    try h2.encodeSetting(payload[0..h2.setting_wire_len], .max_frame_size, 32 * 1024);
    try h2.encodeSetting(payload[h2.setting_wire_len..][0..h2.setting_wire_len], .header_table_size, 0);
    var header = h2.FrameHeader{
        .length = payload.len,
        .frame_type_raw = @intFromEnum(h2.FrameType.settings),
        .frame_type = .settings,
        .flags = h2.Flags.fromByte(0),
        .stream_id = 0,
    };

    const ack = (try session.handleSettingsFrame(header, &payload, std.testing.allocator)).?;
    defer std.testing.allocator.free(ack);
    const ack_header = try h2.FrameHeader.parse(ack);
    try std.testing.expectEqual(h2.FrameType.settings, ack_header.frame_type);
    try std.testing.expect(ack_header.flags.end_stream);
    try std.testing.expectEqual(@as(u8, 0x1), ack_header.flags.toByte());
    try std.testing.expectEqual(@as(u32, 0), ack_header.length);
    try std.testing.expectEqual(@as(u32, 32 * 1024), session.peer_settings.max_frame_size);
    try std.testing.expectEqual(@as(u32, 0), session.peer_settings.header_table_size);

    header.flags = h2.Flags.fromByte(0x1);
    header.length = 0;
    try std.testing.expect((try session.handleSettingsFrame(header, "", std.testing.allocator)) == null);
}

test "egress http2 connection processes idle control frames" {
    var connection = try egress_http2.Connection.initWithLimits(std.testing.allocator, .{
        .stream_receive_window = 1024 * 1024,
        .connection_receive_window = 4 * 1024 * 1024,
        .max_pending_body_credit_per_stream = 1024 * 1024,
        .max_pending_body_credit_per_connection = 4 * 1024 * 1024,
    });
    defer connection.deinit();
    var sent_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent_wire.deinit();

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
    try std.testing.expect(connection.session.received_peer_settings);
    try std.testing.expectEqual(@as(usize, h2.frame_header_len), sent_wire.written().len);

    var ping_wire: [h2.frame_header_len + 8]u8 = undefined;
    var ping = h2.FrameHeader{
        .length = 8,
        .frame_type_raw = @intFromEnum(h2.FrameType.ping),
        .frame_type = .ping,
        .flags = h2.Flags.fromByte(0),
        .stream_id = 0,
    };
    try ping.encode(ping_wire[0..h2.frame_header_len]);
    @memcpy(ping_wire[h2.frame_header_len..], "12345678");
    var ping_frame = try frameFromWire(&ping_wire);
    defer ping_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(&sent_wire.writer, &ping_frame)) == null);
    const ping_ack = try h2.FrameHeader.parse(sent_wire.written()[h2.frame_header_len..][0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.ping, ping_ack.frame_type);
    try std.testing.expect(ping_ack.flags.end_stream);

    var goaway_wire: [h2.frame_header_len + 8]u8 = undefined;
    try h2.encodeGoawayFrame(&goaway_wire, 0, .no_error);
    var goaway_frame = try frameFromWire(&goaway_wire);
    defer goaway_frame.deinit();
    try std.testing.expect((try connection.processEventFrame(&sent_wire.writer, &goaway_frame)) == null);
    try std.testing.expect(connection.closing);
}

test "egress http2 frame reader waits across partial frames" {
    const wire = try h2.encodeDataFrames(std.testing.allocator, h2.default_max_frame_size, 1, "abc", true);
    defer std.testing.allocator.free(wire);
    const chunks = [_][]const u8{
        wire[0..2],
        wire[2..h2.frame_header_len],
        wire[h2.frame_header_len .. h2.frame_header_len + 1],
        wire[h2.frame_header_len + 1 ..],
    };
    var source = PartialReadSource{ .chunks = &chunks };
    var reader = egress_http2.FrameReader.init(std.testing.allocator);
    defer reader.deinit();

    try expectFrameReadWait(try reader.readFrom(&source, h2.default_max_frame_size));
    try expectFrameReadWait(try reader.readFrom(&source, h2.default_max_frame_size));
    try expectFrameReadWait(try reader.readFrom(&source, h2.default_max_frame_size));
    var result = try reader.readFrom(&source, h2.default_max_frame_size);
    switch (result) {
        .frame => |*frame| {
            defer frame.deinit();
            try std.testing.expectEqual(h2.FrameType.data, frame.header.frame_type);
            try std.testing.expectEqual(@as(u32, 1), frame.header.stream_id);
            try std.testing.expectEqualStrings("abc", frame.payload);
        },
        else => return error.ExpectedHttp2Frame,
    }
}
