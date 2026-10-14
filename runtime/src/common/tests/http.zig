//! The HTTP helpers in `collo_http` and the HPACK binding in `collo_hpack`:
//! Host header and request-target validation, HTTP/1 body framing, header
//! and status checks, the connection-specific fields HTTP/2 refuses in each
//! direction, HTTP/2 frame headers, SETTINGS, WINDOW_UPDATE and the
//! connection preface, and HPACK encoding and decoding into the caller's
//! scratch, one scratch shared by several coders, encoder poisoning, dynamic
//! table size updates and the skip that keeps the dynamic table in step past
//! the header caps. Expected
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

test "an HTTP/2 request may carry te only as trailers, a response never carries te, and the five connection fields are refused both ways" {
    const headers = http.headers;
    // `trailers` in any case, with the whitespace around a field value.
    for ([_][]const u8{ "trailers", "TRAILERS", " trailers\t" }) |value|
        try std.testing.expect(!headers.isConnectionSpecificField("te", value, .request));
    for ([_][]const u8{ "gzip", "trailers, gzip", "", "trailer" }) |value|
        try std.testing.expect(headers.isConnectionSpecificField("te", value, .request));
    for ([_][]const u8{ "trailers", "gzip" }) |value| {
        try std.testing.expect(headers.isConnectionSpecificField("te", value, .response));
        try std.testing.expect(headers.isConnectionSpecificField("TE", value, .response));
    }

    const connection_fields = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" };
    for (connection_fields) |name| {
        try std.testing.expect(headers.isConnectionSpecificField(name, "x", .request));
        try std.testing.expect(headers.isConnectionSpecificField(name, "x", .response));
        try std.testing.expect(headers.isConnectionSpecificName(name));
    }
    try std.testing.expect(headers.isConnectionSpecificField("Transfer-Encoding", "chunked", .response));
    // The name-only list the HTTP/1 serializer uses leaves `te` to the
    // direction rule.
    try std.testing.expect(!headers.isConnectionSpecificName("te"));
    try std.testing.expect(!headers.isConnectionSpecificField("x-te", "gzip", .request));
    try std.testing.expect(!headers.isConnectionSpecificField("accept", "*/*", .response));
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

/// The two buffers a coding thread keeps for every connection it serves: one
/// for the field being decoded and one for the block being encoded.
const Scratch = struct {
    decode: []u8,
    encode: []u8,

    const encode_bytes: usize = 128 * 1024;

    fn init() !Scratch {
        const decode = try std.testing.allocator.alloc(u8, hpack.max_single_header_decode_bytes);
        errdefer std.testing.allocator.free(decode);
        return .{
            .decode = decode,
            .encode = try std.testing.allocator.alloc(u8, encode_bytes),
        };
    }

    fn deinit(self: *Scratch) void {
        std.testing.allocator.free(self.decode);
        std.testing.allocator.free(self.encode);
        self.* = undefined;
    }
};

test "hpack round-trips http2 request pseudo headers" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const encoded = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/hello?x=1" },
        .{ .name = "accept", .value = "*/*" },
    }, 1024);

    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, encoded, 16, 4096);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), decoded.headers.len);
    try std.testing.expectEqualStrings(":method", decoded.headers[0].name);
    try std.testing.expectEqualStrings("GET", decoded.headers[0].value);
    try std.testing.expectEqualStrings(":authority", decoded.headers[2].name);
    try std.testing.expectEqualStrings("demo.example.test", decoded.headers[2].value);
    try std.testing.expectEqualStrings("accept", decoded.headers[4].name);
    try std.testing.expectEqualStrings("*/*", decoded.headers[4].value);
}

test "hpack decode storage is sized to decoded bytes" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const encoded = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/small" },
        .{ .name = "x-test", .value = "ok" },
    }, 1024);

    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, encoded, 16, 4096);
    defer decoded.deinit(std.testing.allocator);

    var expected_storage_len: usize = 0;
    for (decoded.headers) |header|
        expected_storage_len += header.name.len + header.value.len;
    try std.testing.expectEqual(expected_storage_len, decoded.storage.len);
    try std.testing.expect(decoded.storage.len < 4096);
}

test "an hpack skip keeps the dynamic table in step past the header caps" {
    const allocator = std.testing.allocator;
    // Two literals with incremental indexing (RFC 7541 §6.2.1), which every
    // decoder adds to its dynamic table, then `:status: 200` (static index 8)
    // until the block holds 600 fields, past a cap of 512.
    const field_count = 600;
    const literals = "\x40\x07x-first\x03one" ++ "\x40\x08x-second\x03two";
    const block = literals.* ++ [_]u8{0x88} ** (field_count - 2);
    // The two entries by their dynamic indexes: 62 is the newest, `x-second`.
    const references = [_]u8{ 0x80 | 63, 0x80 | 62 };

    var scratch = try Scratch.init();
    defer scratch.deinit();

    var capped = try hpack.Decoder.init();
    defer capped.deinit();
    try std.testing.expectError(error.HpackHeaderListTooLarge, capped.decodeBlock(allocator, scratch.decode, &block, 512, 4096));

    // A decoder that never saw the block has no entry the references name.
    var fresh = try hpack.Decoder.init();
    defer fresh.deinit();
    try std.testing.expectError(error.HpackBadData, fresh.decodeBlock(allocator, scratch.decode, &references, 16, 4096));

    // The skip passes the block no cap would take, and the table stays in
    // step, as does the capped decoder's, which decoded the block whole.
    var skipping = try hpack.Decoder.init();
    defer skipping.deinit();
    try skipping.skipBlock(scratch.decode, &block);

    for ([_]*hpack.Decoder{ &skipping, &capped }) |decoder| {
        var decoded = try decoder.decodeBlock(allocator, scratch.decode, &references, 16, 4096);
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), decoded.headers.len);
        try std.testing.expectEqualStrings("x-first", decoded.headers[0].name);
        try std.testing.expectEqualStrings("one", decoded.headers[0].value);
        try std.testing.expectEqualStrings("x-second", decoded.headers[1].name);
        try std.testing.expectEqualStrings("two", decoded.headers[1].value);
    }
}

test "one hpack scratch serves several connections' decoders and encoders in turn" {
    // A shard's two buffers carry nothing from one call to the next, so two
    // connections that alternate on them each keep their own dynamic table.
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var first_encoder = try hpack.Encoder.init();
    defer first_encoder.deinit();
    var second_encoder = try hpack.Encoder.init();
    defer second_encoder.deinit();
    var first_decoder = try hpack.Decoder.init();
    defer first_decoder.deinit();
    var second_decoder = try hpack.Decoder.init();
    defer second_decoder.deinit();

    for ([_][]const u8{ "one", "two" }) |value| {
        const fields = [_]hpack.Header{.{ .name = "x-connection", .value = value }};
        for (0..2) |_| {
            const first_block = try first_encoder.encodeHeaders(scratch.encode, &fields, 1024);
            var first = try first_decoder.decodeBlock(std.testing.allocator, scratch.decode, first_block, 16, 4096);
            defer first.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(value, first.headers[0].value);

            const second_block = try second_encoder.encodeHeaders(scratch.encode, &fields, 1024);
            var second = try second_decoder.decodeBlock(std.testing.allocator, scratch.decode, second_block, 16, 4096);
            defer second.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(value, second.headers[0].value);
        }
    }
}

test "an hpack encode whose worst case exceeds the caller's scratch fails before touching the table" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    var small: [4]u8 = undefined;
    const fields = [_]hpack.Header{.{ .name = "x-long", .value = "a value longer than the scratch" }};
    try std.testing.expectError(error.HpackOutputTooSmall, encoder.encodeHeaders(&small, &fields, 1024));

    // The refusal came before the shim saw a field, so the encoder is not
    // poisoned and its table matches a decoder that saw nothing.
    const block = try encoder.encodeHeaders(scratch.encode, &fields, 1024);
    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, block, 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x-long", decoded.headers[0].name);
}

test "hpack dynamic table size update is only accepted at header block start" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const valid = [_]u8{ 0x20, 0x82 };
    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, &valid, 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings(":method", decoded.headers[0].name);
    try std.testing.expectEqualStrings("GET", decoded.headers[0].value);

    const invalid = [_]u8{ 0x82, 0x20, 0x84 };
    try std.testing.expectError(
        error.HpackBadData,
        decoder.decodeBlock(std.testing.allocator, scratch.decode, &invalid, 16, 4096),
    );
}

test "hpack rejects truncated literal value" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const truncated_literal_value = [_]u8{0x41};
    try std.testing.expectError(
        error.HpackBadData,
        decoder.decodeBlock(std.testing.allocator, scratch.decode, &truncated_literal_value, 16, 4096),
    );
}

test "hpack rejects overflowing integer varint" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const overflowing_index = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f };
    try std.testing.expectError(
        error.HpackBadData,
        decoder.decodeBlock(std.testing.allocator, scratch.decode, &overflowing_index, 16, 4096),
    );
}

test "hpack decoder preserves opaque literal header name bytes" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const literal = [_]u8{
        0x00, 0x06,
        'x',  '-',
        'b',  'a',
        'd',  ' ',
        0x01, 'v',
    };
    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, &literal, 16, 4096);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("x-bad ", decoded.headers[0].name);
    try std.testing.expectEqualStrings("v", decoded.headers[0].value);
}

test "hpack decoder safely indexes an empty literal name" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    const literal = [_]u8{ 0x40, 0x00, 0x01, 'v' };
    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, &literal, 16, 4096);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("", decoded.headers[0].name);
    try std.testing.expectEqualStrings("v", decoded.headers[0].value);

    const indexed = [_]u8{0xbe};
    var decoded_again = try decoder.decodeBlock(std.testing.allocator, scratch.decode, &indexed, 16, 4096);
    defer decoded_again.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded_again.headers.len);
    try std.testing.expectEqualStrings("", decoded_again.headers[0].name);
    try std.testing.expectEqualStrings("v", decoded_again.headers[0].value);
}

test "hpack encoder emits pending dynamic table size updates before headers" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try encoder.setMaxCapacity(0);

    const first = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "x-mode", .value = "h2" },
    }, 1024);
    try std.testing.expect(first.len > 0);
    try std.testing.expectEqual(@as(u8, 0x20), first[0]);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    try decoder.setMaxCapacity(0);
    var decoded_first = try decoder.decodeBlock(std.testing.allocator, scratch.decode, first, 16, 4096);
    defer decoded_first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded_first.headers.len);

    const second = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "x-mode", .value = "h2" },
    }, 1024);
    try std.testing.expect(second.len > 0);
    try std.testing.expect(second[0] != 0x20);

    var decoded_second = try decoder.decodeBlock(std.testing.allocator, scratch.decode, second, 16, 4096);
    defer decoded_second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded_second.headers.len);
}

test "hpack encoder allows indexed blocks under tight output limits" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    const encoded = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1);

    try std.testing.expectEqualSlices(u8, &.{0x82}, encoded);
}

test "hpack encoder promotes duplicate static names to exact indexed values" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    const encoded = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":status", .value = "404" },
    }, 64);

    try std.testing.expectEqualSlices(u8, &.{ 0x83, 0x85, 0x87, 0x8d }, encoded);
}

test "hpack encoder output failure poisons encoder state" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var large_value: [256]u8 = undefined;
    @memset(large_value[0..], 'v');
    try std.testing.expectError(error.HpackEncoderPoisoned, encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "x-poison", .value = "small" },
        .{ .name = "x-large", .value = large_value[0..] },
    }, 64));

    try std.testing.expectError(error.HpackEncoderPoisoned, encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "x-poison", .value = "small" },
    }, 128));
    try std.testing.expectError(error.HpackEncoderPoisoned, encoder.setMaxCapacity(0));
}

test "hpack encoder oversized failure does not publish dynamic entries" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    const huge_value = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(huge_value);
    @memset(huge_value, 'v');

    try std.testing.expectError(error.HpackHeaderListTooLarge, encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "x-poison", .value = "small" },
        .{ .name = "x-huge", .value = huge_value },
    }, 128 * 1024));

    const next = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "x-poison", .value = "small" },
    }, 128);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(allocator, scratch.decode, next, 16, 4096);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("x-poison", decoded.headers[0].name);
    try std.testing.expectEqualStrings("small", decoded.headers[0].value);
}

test "hpack decoder consumes oversized header blocks before reporting limit" {
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();

    var large_value: [128]u8 = undefined;
    @memset(large_value[0..], 'a');

    const first = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "x-large", .value = large_value[0..] },
    }, 4096);
    try std.testing.expectError(
        error.HpackHeaderListTooLarge,
        decoder.decodeBlock(allocator, scratch.decode, first, 16, 32),
    );

    const second = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "x-large", .value = large_value[0..] },
    }, 4096);

    var decoded_second = try decoder.decodeBlock(allocator, scratch.decode, second, 16, 512);
    defer decoded_second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded_second.headers.len);
    try std.testing.expectEqualStrings("x-large", decoded_second.headers[0].name);
    try std.testing.expectEqualSlices(u8, large_value[0..], decoded_second.headers[0].value);
}

test "hpack dynamic table capacity is capped even after update requests" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    try decoder.setMaxCapacity(hpack.max_dynamic_table_capacity + 1024);

    // The update encodes `hpack.max_dynamic_table_capacity` plus one;
    // `setMaxCapacity` clamped the larger request to that maximum.
    const over_limit_update = [_]u8{ 0x3f, 0xe2, 0x1f };
    try std.testing.expectError(
        error.HpackBadData,
        decoder.decodeBlock(std.testing.allocator, scratch.decode, &over_limit_update, 16, 4096),
    );

    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try encoder.setMaxCapacity(0);
    try encoder.setMaxCapacity(hpack.max_dynamic_table_capacity + 1024);

    // RFC 7541 section 4.2 requires the smallest capacity of the interval,
    // zero here, before the final one, which the encoder clamps to
    // `hpack.max_dynamic_table_capacity`.
    const encoded = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":status", .value = "200" },
    }, 1024);
    try std.testing.expect(encoded.len >= 4);
    try std.testing.expectEqual(@as(u8, 0x20), encoded[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0xe1, 0x1f }, encoded[1..4]);
}

test "hpack encoder signals minimum capacity before raised capacity" {
    // RFC 7541 section 4.2 requires two size updates at the start of the
    // next block: the minimum, zero, and then the final capacity. A size
    // update is the 0x20 tag over a 5-bit-prefix integer (section 5.1).
    // 4096 exceeds the prefix maximum of 31, so the first byte is
    // 0x20 | 0x1f = 0x3f and the remainder 4096 - 31 = 4065 follows in 7-bit
    // groups, low group first: 4065 & 0x7f = 0x61 with the continuation bit
    // is 0xe1, and 4065 >> 7 = 31 is 0x1f.
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    try encoder.setMaxCapacity(0);
    try encoder.setMaxCapacity(4096);

    const encoded = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1024);

    try std.testing.expectEqual(@as(usize, 5), encoded.len);
    try std.testing.expectEqual(@as(u8, 0x20), encoded[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0xe1, 0x1f }, encoded[1..4]);
    try std.testing.expectEqual(@as(u8, 0x82), encoded[4]);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, encoded, 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings(":method", decoded.headers[0].name);
    try std.testing.expectEqualStrings("GET", decoded.headers[0].value);

    // Both pending updates are cleared after a successful encode.
    const next = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = ":method", .value = "GET" },
    }, 1024);
    try std.testing.expectEqualSlices(u8, &.{0x82}, next);
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
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    const first = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "set-cookie", .value = "sid=abc; HttpOnly" },
    }, 1024);
    try std.testing.expect(first.len > 0);
    try std.testing.expectEqual(@as(u8, 0x10), first[0] & 0xf0);

    const second = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "set-cookie", .value = "sid=abc; HttpOnly" },
    }, 1024);
    try std.testing.expect(second.len > 0);
    try std.testing.expectEqual(@as(u8, 0x10), second[0] & 0xf0);
    try std.testing.expectEqual(@as(u8, 0), second[0] & 0x80);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, second, 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("set-cookie", decoded.headers[0].name);
    try std.testing.expectEqualStrings("sid=abc; HttpOnly", decoded.headers[0].value);
}

test "hpack encoder huffman encodes never indexed values when smaller" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();

    var value: [128]u8 = undefined;
    @memset(value[0..], 'a');

    const encoded = try encoder.encodeHeaders(scratch.encode, &.{
        .{ .name = "cookie", .value = value[0..] },
    }, 1024);
    try std.testing.expect(encoded.len > 0);
    try std.testing.expectEqual(@as(u8, 0x10), encoded[0] & 0xf0);
    try std.testing.expect(encoded.len < value.len + 4);
    try std.testing.expect(std.mem.indexOf(u8, encoded, value[0..]) == null);

    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    var decoded = try decoder.decodeBlock(std.testing.allocator, scratch.decode, encoded, 16, 4096);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.headers.len);
    try std.testing.expectEqualStrings("cookie", decoded.headers[0].name);
    try std.testing.expectEqualSlices(u8, value[0..], decoded.headers[0].value);
}
