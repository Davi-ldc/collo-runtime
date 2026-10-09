//! The HTTP helpers in `collo_http` and the HPACK binding in `collo_hpack`:
//! Host header and request-target validation, HTTP/1 body framing, header
//! and status checks, HTTP/2 frame headers, SETTINGS, WINDOW_UPDATE and the
//! connection preface, and HPACK encoding and decoding with prepared headers,
//! scratch reuse, encoder poisoning and dynamic table size updates. Expected
//! HPACK bytes follow RFC 7541: the high bits of a field's first byte select
//! its representation (section 6), and indexes 1 to 61 name the static table
//! (Appendix A). Besides `common-test`, the file runs alone, without JSC, as
//! the `common-http` suite of `common-fast-test`.

const std = @import("std");
const http = @import("collo_http");
const hpack = @import("collo_hpack");

test "http host parsing splits the port and keeps the host's case" {
    const parsed = try http.authority.parse("Demo.Example.Test:443");
    try std.testing.expectEqualStrings("Demo.Example.Test", parsed.host);
    try std.testing.expectEqual(@as(?u16, 443), parsed.port);

    const allocator = std.testing.allocator;
    const normalized = try http.authority.normalizeAlloc(allocator, "Demo.Example.Test:8080");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("demo.example.test", normalized);
    try std.testing.expectError(error.InvalidHostHeader, http.authority.parse("[2001:db8::1]:443"));
}

test "a server authority keeps a port other than the default and lowercases the host" {
    var buffer: [http.authority.max_server_authority_bytes]u8 = undefined;
    const cases = [_]struct { value: []const u8, expected: []const u8 }{
        .{ .value = "Demo.Example.Test", .expected = "demo.example.test" },
        .{ .value = "Demo.Example.Test:443", .expected = "demo.example.test" },
        .{ .value = "Demo.Example.Test:8443", .expected = "demo.example.test:8443" },
        .{ .value = " 127.0.0.1:8443 ", .expected = "127.0.0.1:8443" },
        .{ .value = "[::1]:8443", .expected = "[::1]:8443" },
        .{ .value = "[2001:DB8::1]", .expected = "[2001:db8::1]" },
        .{ .value = "[2001:db8::1]:443", .expected = "[2001:db8::1]" },
    };
    for (cases) |case|
        try std.testing.expectEqualStrings(case.expected, try http.authority.normalizeServerStack(case.value, 443, &buffer));

    // The longest host name with the longest port fits the buffer.
    const longest_host = ("a" ** 63 ++ ".") ** 3 ++ "a" ** 61;
    comptime std.debug.assert(longest_host.len == http.authority.max_host_name_bytes);
    try std.testing.expectEqualStrings(longest_host ++ ":65535", try http.authority.normalizeServerStack(longest_host ++ ":65535", 443, &buffer));
}

test "a server authority refuses what names no origin of this server" {
    var buffer: [http.authority.max_server_authority_bytes]u8 = undefined;
    const invalid = [_][]const u8{
        "",
        "demo.example.test:",
        "demo.example.test:abc",
        "demo.example.test:0",
        "demo.example.test:65536",
        "bad host",
        "user@demo.example.test",
        "demo.example.test/path",
        "[::1",
        "[::1]x",
        "[::1]:",
        "[fe80::1%eth0]:8443",
        "[not-an-address]",
        "::1",
    };
    for (invalid) |value|
        try std.testing.expectError(error.InvalidHostHeader, http.authority.normalizeServerStack(value, 443, &buffer));
}

test "http framing parses content length and chunked transfer encoding" {
    try std.testing.expectEqual(@as(usize, 42), try http.framing.parseContentLengthValue("42"));
    try std.testing.expect(http.framing.transferEncodingIsChunked("chunked"));
    try std.testing.expect(http.framing.transferEncodingIsChunked(" chunked , chunked "));
    try std.testing.expect(!http.framing.transferEncodingIsChunked("gzip, chunked"));
}

test "http framing validates request body limit" {
    try http.framing.validateContentLength(8, 8);
    try std.testing.expectError(error.RequestTooLarge, http.framing.validateContentLength(9, 8));
    try std.testing.expectError(error.InvalidContentLength, http.framing.parseContentLengthValue("4x"));
}

test "http framing finds content length header" {
    try std.testing.expectEqual(
        @as(?usize, 12),
        try http.framing.parseUniqueContentLengthHeader("date: now\r\ncontent-length: 12\r\n"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        try http.framing.parseUniqueContentLengthHeader("date: now\r\n"),
    );
    try std.testing.expectError(
        error.InvalidContentLength,
        http.framing.parseUniqueContentLengthHeader("content-length: nope\r\n"),
    );
    try std.testing.expectError(
        error.DuplicateContentLength,
        http.framing.parseUniqueContentLengthHeader("content-length: 12\r\ncontent-length: 12\r\n"),
    );
}

test "http request target validation accepts only origin-form targets" {
    try http.request_target.validateOriginForm("/");
    try http.request_target.validateOriginForm("/users/123?q=1");

    try std.testing.expectError(error.InvalidRequestLine, http.request_target.validateOriginForm(""));
    try std.testing.expectError(error.InvalidRequestLine, http.request_target.validateOriginForm("*"));
    try std.testing.expectError(error.InvalidRequestLine, http.request_target.validateOriginForm("https://demo.test/path"));
    try std.testing.expectError(error.InvalidRequestLine, http.request_target.validateOriginForm("demo.test:443"));
    try std.testing.expectError(error.InvalidRequestLine, http.request_target.validateOriginForm("/bad path"));
    try std.testing.expectError(error.InvalidRequestLine, http.request_target.validateOriginForm("/bad#fragment"));
    try std.testing.expectError(error.InvalidRequestLine, http.request_target.validateOriginForm("/bad\x7fpath"));
}

test "http header validation accepts token names and tab values" {
    try http.status.validate(204);
    try http.headers.validate("x-demo_token", "a\tb");
}

test "http header validation rejects invalid response metadata" {
    try std.testing.expectError(error.InvalidResponseStatus, http.status.validate(199));
    try std.testing.expectError(error.InvalidResponseHeader, http.headers.validate("", "ok"));
    try std.testing.expectError(error.InvalidResponseHeader, http.headers.validate("bad name", "ok"));
    try std.testing.expectError(error.InvalidResponseHeader, http.headers.validate("x-demo", "bad\r\n"));
}

test "common HTTP status phrase table covers common server statuses" {
    try std.testing.expectEqualStrings("Moved Permanently", http.status.phrase(301));
    try std.testing.expectEqualStrings("Not Modified", http.status.phrase(304));
    try std.testing.expectEqualStrings("Unauthorized", http.status.phrase(401));
    try std.testing.expectEqualStrings("Service Unavailable", http.status.phrase(503));
    try std.testing.expectEqualStrings("Response", http.status.phrase(599));
}

test "http2 parses and encodes frame headers" {
    const h2 = http.http2;
    const raw = [_]u8{
        0x00, 0x00, 0x05,
        0x01, 0x05, 0x80,
        0x00, 0x00, 0x03,
    };
    const parsed = try h2.FrameHeader.parse(&raw);
    try std.testing.expectEqual(@as(u32, 5), parsed.length);
    try std.testing.expectEqual(h2.FrameType.headers, parsed.frame_type);
    try std.testing.expect(parsed.flags.end_stream);
    try std.testing.expect(parsed.flags.end_headers_or_ack);
    try std.testing.expectEqual(@as(u32, 3), parsed.stream_id);

    var encoded: [h2.frame_header_len]u8 = undefined;
    try parsed.encode(&encoded);
    try std.testing.expectEqualSlices(u8, raw[0..5], encoded[0..5]);
    try std.testing.expectEqual(@as(u8, 0x00), encoded[5]);
    try std.testing.expectEqualSlices(u8, raw[6..9], encoded[6..9]);
}

test "http2 encodes and parses window update increments" {
    const h2 = http.http2;
    var encoded: [h2.frame_header_len + 4]u8 = undefined;
    try h2.encodeWindowUpdateFrame(&encoded, 7, 1024);

    const header = try h2.FrameHeader.parse(encoded[0..h2.frame_header_len]);
    try std.testing.expectEqual(h2.FrameType.window_update, header.frame_type);
    try std.testing.expectEqual(@as(u32, 4), header.length);
    try std.testing.expectEqual(@as(u32, 7), header.stream_id);
    try std.testing.expectEqual(@as(u32, 1024), try h2.parseWindowUpdateIncrement(encoded[h2.frame_header_len..]));

    try std.testing.expectError(error.Http2ProtocolError, h2.encodeWindowUpdateFrame(&encoded, 7, 0));
    try std.testing.expectError(error.Http2FrameSizeError, h2.parseWindowUpdateIncrement("\x00"));
    try std.testing.expectError(error.Http2ProtocolError, h2.parseWindowUpdateIncrement("\x00\x00\x00\x00"));
}

test "http2 settings validate and apply known identifiers" {
    const h2 = http.http2;
    var payload = [_]u8{
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x04, 0x00, 0x00, 0xff, 0xff,
        0x00, 0x05, 0x00, 0x00, 0x40, 0x00,
    };
    try h2.encodeSetting(payload[0..h2.setting_wire_len], .enable_push, 0);
    try h2.encodeSetting(payload[h2.setting_wire_len..][0..h2.setting_wire_len], .initial_window_size, 65_535);
    try h2.encodeSetting(payload[h2.setting_wire_len * 2 ..][0..h2.setting_wire_len], .max_frame_size, 16_384);
    var storage: [h2.Settings.max_settings_per_frame]h2.Setting = undefined;
    const settings = try h2.Settings.parseInto(&storage, &payload);
    try std.testing.expectEqual(@as(usize, 3), settings.values.len);

    var state = h2.SettingsState{};
    state.apply(settings.values);
    try std.testing.expect(!state.enable_push);
    try std.testing.expectEqual(@as(u32, 65_535), state.initial_window_size);
    try std.testing.expectEqual(@as(u32, 16_384), state.max_frame_size);
}

test "http2 settings state enforces per-frame cap" {
    const h2 = http.http2;
    const count = h2.Settings.max_settings_per_frame + 8;
    var payload: [h2.setting_wire_len * count]u8 = undefined;
    for (0..count) |index| {
        try h2.encodeSetting(
            payload[index * h2.setting_wire_len ..][0..h2.setting_wire_len],
            .max_concurrent_streams,
            @intCast(index + 1),
        );
    }

    var state = h2.SettingsState{};
    try std.testing.expectError(error.TooManyHttp2Settings, state.applyPayload(&payload));
}

test "http2 rejects malformed settings and bad prefaces" {
    const h2 = http.http2;
    var storage: [h2.Settings.max_settings_per_frame]h2.Setting = undefined;

    try std.testing.expectError(error.Http2FrameSizeError, h2.Settings.parseInto(&storage, "\x00"));
    try std.testing.expectError(
        error.Http2ProtocolError,
        h2.Settings.parseInto(&storage, "\x00\x02\x00\x00\x00\x02"),
    );
    try std.testing.expectError(error.ShortHttp2Preface, h2.validatePreface("PRI"));
    try std.testing.expectError(error.InvalidHttp2Preface, h2.validatePreface("GET / HTTP/1.1\r\n\r\nxxxxxx"));
    try h2.validatePreface(h2.client_connection_preface);
}

test "hpack round-trips http2 request pseudo headers" {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    var encoded = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/hello?x=1" },
        .{ .name = "accept", .value = "*/*" },
    }, 1024);
    defer encoded.deinit(std.testing.allocator);

    var decoded = try decoder.decodeBlock(std.testing.allocator, encoded.bytes(), 16, 4096);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), decoded.headers.len);
    try std.testing.expectEqualStrings(":method", decoded.headers[0].name);
    try std.testing.expectEqualStrings("GET", decoded.headers[0].value);
    try std.testing.expectEqualStrings(":authority", decoded.headers[2].name);
    try std.testing.expectEqualStrings("demo.example.test", decoded.headers[2].value);
    try std.testing.expectEqualStrings("accept", decoded.headers[4].name);
    try std.testing.expectEqualStrings("*/*", decoded.headers[4].value);
}

test "hpack prepared headers own bytes and match raw encoding" {
    const allocator = std.testing.allocator;
    var method = [_]u8{ 'P', 'O', 'S', 'T' };
    var custom_name = [_]u8{ 'x', '-', 'p', 'l', 'a', 'n' };
    var custom_value = [_]u8{ 'r', 'e', 'u', 's', 'e', 'd' };
    const headers = [_]hpack.Header{
        .{ .name = ":method", .value = method[0..] },
        .{ .name = custom_name[0..], .value = custom_value[0..] },
    };

    var raw_encoder = try hpack.Encoder.init();
    defer raw_encoder.deinit();
    var expected = try raw_encoder.encodeHeaders(allocator, &headers, 1024);
    defer expected.deinit(allocator);

    var prepared = try hpack.PreparedHeaders.init(allocator, &headers);
    defer prepared.deinit(allocator);
    @memset(method[0..], 'X');
    @memset(custom_name[0..], 'y');
    @memset(custom_value[0..], 'z');

    var prepared_encoder = try hpack.Encoder.init();
    defer prepared_encoder.deinit();
    var actual = try prepared_encoder.encodePreparedHeaders(
        allocator,
        &prepared,
        1024,
    );
    defer actual.deinit(allocator);
    try std.testing.expectEqualSlices(u8, expected.bytes(), actual.bytes());

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(allocator, actual.bytes(), 8, 1024);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualStrings("POST", decoded.headers[0].value);
    try std.testing.expectEqualStrings("x-plan", decoded.headers[1].name);
    try std.testing.expectEqualStrings("reused", decoded.headers[1].value);
}

test "hpack prepared headers match raw blocks as dynamic state evolves" {
    const allocator = std.testing.allocator;
    var large_value: [640]u8 = undefined;
    @memset(large_value[0..], 'a');
    const headers = [_]hpack.Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = "x-large-plan", .value = large_value[0..] },
        .{ .name = "authorization", .value = "Bearer prepared-secret" },
    };
    var prepared = try hpack.PreparedHeaders.init(allocator, &headers);
    defer prepared.deinit(allocator);

    var raw_encoder = try hpack.Encoder.init();
    defer raw_encoder.deinit();
    var prepared_encoder = try hpack.Encoder.init();
    defer prepared_encoder.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    for (0..2) |_| {
        var expected = try raw_encoder.encodeHeaders(allocator, &headers, 4096);
        defer expected.deinit(allocator);
        var actual = try prepared_encoder.encodePreparedHeaders(
            allocator,
            &prepared,
            4096,
        );
        defer actual.deinit(allocator);
        try std.testing.expectEqualSlices(u8, expected.bytes(), actual.bytes());

        var decoded = try decoder.decodeBlock(allocator, actual.bytes(), 8, 4096);
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), decoded.headers.len);
        try std.testing.expectEqualStrings("x-large-plan", decoded.headers[1].name);
        try std.testing.expectEqualSlices(u8, large_value[0..], decoded.headers[1].value);
    }
}

test "hpack prepared sensitive headers stay literal never indexed" {
    const allocator = std.testing.allocator;
    const headers = [_]hpack.Header{
        .{ .name = "set-cookie", .value = "sid=prepared; HttpOnly" },
    };
    var prepared = try hpack.PreparedHeaders.init(allocator, &headers);
    defer prepared.deinit(allocator);
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var first = try encoder.encodePreparedHeaders(allocator, &prepared, 1024);
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x10), first.bytes()[0] & 0xf0);

    var second = try encoder.encodePreparedHeaders(allocator, &prepared, 1024);
    defer second.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x10), second.bytes()[0] & 0xf0);
    try std.testing.expectEqual(@as(u8, 0), second.bytes()[0] & 0x80);
}

test "hpack prepared headers preserve exact static indexes" {
    const allocator = std.testing.allocator;
    var prepared = try hpack.PreparedHeaders.init(allocator, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":status", .value = "404" },
    });
    defer prepared.deinit(allocator);
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var encoded = try encoder.encodePreparedHeaders(allocator, &prepared, 64);
    defer encoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x83, 0x85, 0x87, 0x8d }, encoded.bytes());
}

test "hpack prepared scratch preserves capacity updates and empty blocks" {
    const allocator = std.testing.allocator;
    var prepared = try hpack.PreparedHeaders.init(allocator, &.{
        .{ .name = ":method", .value = "GET" },
    });
    defer prepared.deinit(allocator);
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try encoder.setMaxCapacity(0);
    try encoder.setMaxCapacity(4096);

    const first = try encoder.encodePreparedHeadersScratch(allocator, &prepared, 1024);
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x3f, 0xe1, 0x1f, 0x82 }, first);
    const scratch_ptr = encoder.scratch.ptr;
    const second = try encoder.encodePreparedHeadersScratch(allocator, &prepared, 1024);
    try std.testing.expectEqualSlices(u8, &.{0x82}, second);
    try std.testing.expectEqual(scratch_ptr, encoder.scratch.ptr);

    var empty = try hpack.PreparedHeaders.init(allocator, &.{});
    defer empty.deinit(allocator);
    const empty_block = try encoder.encodePreparedHeadersScratch(allocator, &empty, 0);
    try std.testing.expectEqual(@as(usize, 0), empty_block.len);
}

test "hpack prepared header allocation failures do not leak" {
    const headers = [_]hpack.Header{
        .{ .name = "x-plan", .value = "value" },
    };
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            hpack.PreparedHeaders.init(failing.allocator(), &headers),
        );
    }
}

test "hpack prepared headers reject oversized fields before touching encoders" {
    const allocator = std.testing.allocator;
    const huge_value = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(huge_value);
    @memset(huge_value, 'v');
    try std.testing.expectError(
        error.HpackHeaderListTooLarge,
        hpack.PreparedHeaders.init(allocator, &.{
            .{ .name = "x-huge", .value = huge_value },
        }),
    );

    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var encoded = try encoder.encodeHeaders(allocator, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1);
    defer encoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{0x82}, encoded.bytes());
}

test "hpack prepared output failure poisons encoder state" {
    const allocator = std.testing.allocator;
    var large_value: [256]u8 = undefined;
    @memset(large_value[0..], 'v');
    var prepared = try hpack.PreparedHeaders.init(allocator, &.{
        .{ .name = "x-poison", .value = "small" },
        .{ .name = "x-large", .value = large_value[0..] },
    });
    defer prepared.deinit(allocator);
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    try std.testing.expectError(
        error.HpackEncoderPoisoned,
        encoder.encodePreparedHeaders(allocator, &prepared, 64),
    );
    try std.testing.expectError(
        error.HpackEncoderPoisoned,
        encoder.encodePreparedHeaders(allocator, &prepared, 1024),
    );
    try std.testing.expectError(error.HpackEncoderPoisoned, encoder.setMaxCapacity(0));
}

test "hpack decode storage is sized to decoded bytes" {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    var encoded = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/small" },
        .{ .name = "x-test", .value = "ok" },
    }, 1024);
    defer encoded.deinit(std.testing.allocator);

    var decoded = try decoder.decodeBlock(std.testing.allocator, encoded.bytes(), 16, 4096);
    defer decoded.deinit(std.testing.allocator);

    var expected_storage_len: usize = 0;
    for (decoded.headers) |header|
        expected_storage_len += header.name.len + header.value.len;
    try std.testing.expectEqual(expected_storage_len, decoded.storage.len);
    try std.testing.expect(decoded.storage.len < 4096);
}

test "hpack dynamic table size update is only accepted at header block start" {
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const valid = [_]u8{ 0x20, 0x82 };
    var decoded = try decoder.decodeBlock(std.testing.allocator, &valid, 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings(":method", decoded.headers[0].name);
    try std.testing.expectEqualStrings("GET", decoded.headers[0].value);

    const invalid = [_]u8{ 0x82, 0x20, 0x84 };
    try std.testing.expectError(
        error.HpackBadData,
        decoder.decodeBlock(std.testing.allocator, &invalid, 16, 4096),
    );
}

test "hpack rejects truncated literal value" {
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const truncated_literal_value = [_]u8{0x41};
    try std.testing.expectError(
        error.HpackBadData,
        decoder.decodeBlock(std.testing.allocator, &truncated_literal_value, 16, 4096),
    );
}

test "hpack rejects overflowing integer varint" {
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const overflowing_index = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f };
    try std.testing.expectError(
        error.HpackBadData,
        decoder.decodeBlock(std.testing.allocator, &overflowing_index, 16, 4096),
    );
}

test "hpack decoder preserves opaque literal header name bytes" {
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const literal = [_]u8{
        0x00, 0x06,
        'x',  '-',
        'b',  'a',
        'd',  ' ',
        0x01, 'v',
    };
    var decoded = try decoder.decodeBlock(std.testing.allocator, &literal, 16, 4096);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("x-bad ", decoded.headers[0].name);
    try std.testing.expectEqualStrings("v", decoded.headers[0].value);
}

test "hpack decoder safely indexes an empty literal name" {
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const literal = [_]u8{ 0x40, 0x00, 0x01, 'v' };
    var decoded = try decoder.decodeBlock(std.testing.allocator, &literal, 16, 4096);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("", decoded.headers[0].name);
    try std.testing.expectEqualStrings("v", decoded.headers[0].value);

    const indexed = [_]u8{0xbe};
    var decoded_again = try decoder.decodeBlock(std.testing.allocator, &indexed, 16, 4096);
    defer decoded_again.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded_again.headers.len);
    try std.testing.expectEqualStrings("", decoded_again.headers[0].name);
    try std.testing.expectEqualStrings("v", decoded_again.headers[0].value);
}

test "hpack encoder emits pending dynamic table size updates before headers" {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try encoder.setMaxCapacity(0);

    var first = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "x-mode", .value = "h2" },
    }, 1024);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.bytes().len > 0);
    try std.testing.expectEqual(@as(u8, 0x20), first.bytes()[0]);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    try decoder.setMaxCapacity(0);
    var decoded_first = try decoder.decodeBlock(std.testing.allocator, first.bytes(), 16, 4096);
    defer decoded_first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded_first.headers.len);

    var second = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "x-mode", .value = "h2" },
    }, 1024);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.bytes().len > 0);
    try std.testing.expect(second.bytes()[0] != 0x20);

    var decoded_second = try decoder.decodeBlock(std.testing.allocator, second.bytes(), 16, 4096);
    defer decoded_second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded_second.headers.len);
}

test "hpack encoder allows indexed blocks under tight output limits" {
    const allocator = std.testing.allocator;
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var encoded = try encoder.encodeHeaders(allocator, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1);
    defer encoded.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &.{0x82}, encoded.bytes());
}

test "hpack encoder promotes duplicate static names to exact indexed values" {
    const allocator = std.testing.allocator;
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var encoded = try encoder.encodeHeaders(allocator, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":status", .value = "404" },
    }, 64);
    defer encoded.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &.{ 0x83, 0x85, 0x87, 0x8d }, encoded.bytes());
}

test "hpack encoder output failure poisons encoder state" {
    const allocator = std.testing.allocator;
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var large_value: [256]u8 = undefined;
    @memset(large_value[0..], 'v');
    if (encoder.encodeHeaders(allocator, &.{
        .{ .name = "x-poison", .value = "small" },
        .{ .name = "x-large", .value = large_value[0..] },
    }, 64)) |block| {
        var owned = block;
        defer owned.deinit(allocator);
        return error.ExpectedHpackOutputTooSmall;
    } else |err| {
        try std.testing.expectEqual(error.HpackEncoderPoisoned, err);
    }

    try std.testing.expectError(error.HpackEncoderPoisoned, encoder.encodeHeaders(allocator, &.{
        .{ .name = "x-poison", .value = "small" },
    }, 128));
    try std.testing.expectError(error.HpackEncoderPoisoned, encoder.setMaxCapacity(0));
}

test "hpack encoder oversized failure does not publish dynamic entries" {
    const allocator = std.testing.allocator;
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    const huge_value = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(huge_value);
    @memset(huge_value, 'v');

    if (encoder.encodeHeaders(allocator, &.{
        .{ .name = "x-poison", .value = "small" },
        .{ .name = "x-huge", .value = huge_value },
    }, 128 * 1024)) |block| {
        var owned = block;
        defer owned.deinit(allocator);
        return error.ExpectedHpackHeaderListTooLarge;
    } else |err| {
        try std.testing.expectEqual(error.HpackHeaderListTooLarge, err);
    }

    var next = try encoder.encodeHeaders(allocator, &.{
        .{ .name = "x-poison", .value = "small" },
    }, 128);
    defer next.deinit(allocator);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(allocator, next.bytes(), 16, 4096);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("x-poison", decoded.headers[0].name);
    try std.testing.expectEqualStrings("small", decoded.headers[0].value);
}

test "hpack decoder consumes oversized header blocks before reporting limit" {
    const allocator = std.testing.allocator;
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    var large_value: [128]u8 = undefined;
    @memset(large_value[0..], 'a');

    var first = try encoder.encodeHeaders(allocator, &.{
        .{ .name = "x-large", .value = large_value[0..] },
    }, 4096);
    defer first.deinit(allocator);

    if (decoder.decodeBlock(allocator, first.bytes(), 16, 32)) |decoded_block| {
        var owned = decoded_block;
        defer owned.deinit(allocator);
        return error.ExpectedHpackHeaderListTooLarge;
    } else |err| {
        try std.testing.expectEqual(error.HpackHeaderListTooLarge, err);
    }

    var second = try encoder.encodeHeaders(allocator, &.{
        .{ .name = "x-large", .value = large_value[0..] },
    }, 4096);
    defer second.deinit(allocator);

    var decoded_second = try decoder.decodeBlock(allocator, second.bytes(), 16, 512);
    defer decoded_second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded_second.headers.len);
    try std.testing.expectEqualStrings("x-large", decoded_second.headers[0].name);
    try std.testing.expectEqualSlices(u8, large_value[0..], decoded_second.headers[0].value);
}

test "hpack dynamic table capacity is capped even after update requests" {
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    try decoder.setMaxCapacity(hpack.max_dynamic_table_capacity + 1024);

    // The update encodes `hpack.max_dynamic_table_capacity` plus one;
    // `setMaxCapacity` clamped the larger request to that maximum.
    const over_limit_update = [_]u8{ 0x3f, 0xe2, 0x1f };
    try std.testing.expectError(
        error.HpackBadData,
        decoder.decodeBlock(std.testing.allocator, &over_limit_update, 16, 4096),
    );

    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try encoder.setMaxCapacity(0);
    try encoder.setMaxCapacity(hpack.max_dynamic_table_capacity + 1024);

    // RFC 7541 section 4.2 requires the smallest capacity of the interval,
    // zero here, before the final one, which the encoder clamps to
    // `hpack.max_dynamic_table_capacity`.
    var encoded = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = ":status", .value = "200" },
    }, 1024);
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expect(encoded.bytes().len >= 4);
    try std.testing.expectEqual(@as(u8, 0x20), encoded.bytes()[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0xe1, 0x1f }, encoded.bytes()[1..4]);
}

test "hpack decoder reuses decode scratch across blocks" {
    // The scratch outlives every block, so the testing allocator's leak and
    // double-free checks are what prove `deinit` frees it exactly once.
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoder.scratch.len);

    const block = [_]u8{0x82};
    var first = try decoder.decodeBlock(std.testing.allocator, &block, 16, 4096);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.headers.len);
    try std.testing.expect(decoder.scratch.len != 0);
    const scratch_ptr = decoder.scratch.ptr;

    var second = try decoder.decodeBlock(std.testing.allocator, &block, 16, 4096);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second.headers.len);
    try std.testing.expectEqualStrings(":method", second.headers[0].name);
    try std.testing.expectEqualStrings("GET", second.headers[0].value);
    try std.testing.expectEqual(scratch_ptr, decoder.scratch.ptr);
}

test "hpack encoder signals minimum capacity before raised capacity" {
    // RFC 7541 section 4.2 requires two size updates at the start of the
    // next block: the minimum, zero, and then the final capacity. A size
    // update is the 0x20 tag over a 5-bit-prefix integer (section 5.1).
    // 4096 exceeds the prefix maximum of 31, so the first byte is
    // 0x20 | 0x1f = 0x3f and the remainder 4096 - 31 = 4065 follows in 7-bit
    // groups, low group first: 4065 & 0x7f = 0x61 with the continuation bit
    // is 0xe1, and 4065 >> 7 = 31 is 0x1f.
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try encoder.setMaxCapacity(0);
    try encoder.setMaxCapacity(4096);

    var encoded = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1024);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), encoded.bytes().len);
    try std.testing.expectEqual(@as(u8, 0x20), encoded.bytes()[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0xe1, 0x1f }, encoded.bytes()[1..4]);
    try std.testing.expectEqual(@as(u8, 0x82), encoded.bytes()[4]);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(std.testing.allocator, encoded.bytes(), 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings(":method", decoded.headers[0].name);
    try std.testing.expectEqualStrings("GET", decoded.headers[0].value);

    // Both pending updates are cleared after a successful encode.
    var next = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1024);
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{0x82}, next.bytes());
}

test "hpack encoder reuses encode scratch across blocks" {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try std.testing.expectEqual(@as(usize, 0), encoder.scratch.len);

    const first = try encoder.encodeHeadersScratch(std.testing.allocator, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1024);
    try std.testing.expectEqualSlices(u8, &.{0x82}, first);
    try std.testing.expect(encoder.scratch.len != 0);
    const scratch_ptr = encoder.scratch.ptr;

    const second = try encoder.encodeHeadersScratch(std.testing.allocator, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1024);
    try std.testing.expectEqualSlices(u8, &.{0x82}, second);
    try std.testing.expectEqual(scratch_ptr, encoder.scratch.ptr);
}

test "http2 settings clamp peer header table size" {
    var state = http.http2.SettingsState{};
    var payload: [http.http2.setting_wire_len]u8 = undefined;
    try http.http2.encodeSetting(&payload, .header_table_size, http.http2.max_header_table_size + 1024);
    const change = try state.applyPayload(&payload);
    try std.testing.expect(change.headerTableSizeChanged(state) == false);
    try std.testing.expectEqual(http.http2.max_header_table_size, state.header_table_size);

    try http.http2.encodeSetting(&payload, .header_table_size, 0);
    const zero_change = try state.applyPayload(&payload);
    try std.testing.expect(zero_change.headerTableSizeChanged(state));
    try std.testing.expectEqual(@as(u32, 0), state.header_table_size);
}

test "hpack encoder emits sensitive headers as literal never indexed" {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var first = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = "set-cookie", .value = "sid=abc; HttpOnly" },
    }, 1024);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.bytes().len > 0);
    try std.testing.expectEqual(@as(u8, 0x10), first.bytes()[0] & 0xf0);

    var second = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = "set-cookie", .value = "sid=abc; HttpOnly" },
    }, 1024);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.bytes().len > 0);
    try std.testing.expectEqual(@as(u8, 0x10), second.bytes()[0] & 0xf0);
    try std.testing.expectEqual(@as(u8, 0), second.bytes()[0] & 0x80);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(std.testing.allocator, second.bytes(), 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("set-cookie", decoded.headers[0].name);
    try std.testing.expectEqualStrings("sid=abc; HttpOnly", decoded.headers[0].value);
}

test "hpack encoder huffman encodes never indexed values when smaller" {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var value: [128]u8 = undefined;
    @memset(value[0..], 'a');

    var encoded = try encoder.encodeHeaders(std.testing.allocator, &.{
        .{ .name = "cookie", .value = value[0..] },
    }, 1024);
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expect(encoded.bytes().len > 0);
    try std.testing.expectEqual(@as(u8, 0x10), encoded.bytes()[0] & 0xf0);
    try std.testing.expect(encoded.bytes().len < value.len + 4);
    try std.testing.expect(std.mem.indexOf(u8, encoded.bytes(), value[0..]) == null);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(std.testing.allocator, encoded.bytes(), 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("cookie", decoded.headers[0].name);
    try std.testing.expectEqualSlices(u8, value[0..], decoded.headers[0].value);
}
