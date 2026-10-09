//! Tests for the HTTP/1 wire parser on literal byte strings: request and
//! response heads, request head serialization, bare-LF leniency,
//! transfer-coding rules, and the chunked decoder's bounds. Nothing here
//! opens a socket.

const std = @import("std");
const egress_client = @import("collo_egress_client");

const http1 = egress_client.transport.http1_protocol;

test "egress HTTP1 request-line parser is zero-copy by default" {
    const parsed = try http1.parseRequestLineView("GET /hello?q=1 HTTP/1.1\r\nHost: demo\r\n\r\n");

    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/hello", parsed.path);
    try std.testing.expectEqualStrings("q=1", parsed.raw_query);
    try std.testing.expectEqualStrings("Host: demo\r\n\r\n", parsed.prebuffer);
    try std.testing.expectError(
        error.InvalidRequestLine,
        http1.parseRequestLineView("GET https://demo.test/path HTTP/1.1\r\n"),
    );
    try std.testing.expectError(
        error.Http2OriginNotSupported,
        http1.parseRequestLineView(http1.http2_preface),
    );
}

test "egress HTTP1 request-head parser validates host and body framing" {
    var scan_start: usize = 0;
    var parsed = (try http1.completeHead(
        std.testing.allocator,
        "Host: Demo.Example.Test:443\r\nContent-Length: 5\r\n\r\nabc",
        &scan_start,
        http1.default_max_header_bytes,
    )).?;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("demo.example.test", parsed.host.?);
    try std.testing.expectEqual(.content_length, parsed.body_framing);
    try std.testing.expectEqual(@as(usize, 5), parsed.content_length);
    try std.testing.expectEqualStrings("abc", parsed.initial_body_bytes);
}

test "egress HTTP1 response parser handles fragmented heads and connection framing" {
    var parser = try http1.ResponseHeadParser.init(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnec",
    );
    defer parser.deinit();
    try std.testing.expect((try parser.complete()) == null);
    try parser.append("tion: close\r\n\r\nhello");
    var parsed = (try parser.complete()).?;
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u16, 200), parsed.status_code);
    try std.testing.expectEqual(http1.BodyFraming.content_length, parsed.body_framing);
    try std.testing.expectEqual(@as(usize, 5), parsed.content_length);
    try std.testing.expectEqualStrings("hello", parsed.initial_body_bytes);
    try std.testing.expect(parsed.close_after_response);

    var scan_start: usize = 0;
    var http10 = (try http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n",
        &scan_start,
        http1.default_max_header_bytes,
    )).?;
    defer http10.deinit();
    try std.testing.expect(http10.close_after_response);
}

test "egress HTTP1 response parser retains bytes after an informational head" {
    var scan_start: usize = 0;
    var interim = (try http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        &scan_start,
        http1.default_max_header_bytes,
    )).?;
    defer interim.deinit();

    try std.testing.expectEqual(@as(u16, 100), interim.status_code);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        interim.post_head_bytes,
    );
}

test "egress HTTP1 request serializer owns framing headers" {
    const encoded = try http1.serializeRequestHead(std.testing.allocator, .{
        .method = "POST",
        .target = "/path?q=1",
        .host = "[2001:db8::1]:8443",
        .headers = &.{.{ .name = "accept", .value = "application/json" }},
        .content_length = 3,
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        encoded,
        1,
        "POST /path?q=1 HTTP/1.1\r\n",
    ));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        encoded,
        1,
        "host: [2001:db8::1]:8443\r\n",
    ));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        encoded,
        1,
        "content-length: 3\r\n",
    ));
    try std.testing.expectError(
        error.ForbiddenRequestHeader,
        http1.serializeRequestHead(std.testing.allocator, .{
            .method = "GET",
            .target = "/",
            .host = "demo.test",
            .headers = &.{.{ .name = "connection", .value = "keep-alive" }},
        }),
    );
}

test "egress HTTP1 chunked decoder streams chunks and trailers" {
    var body = std.array_list.Aligned(u8, null).empty;
    defer body.deinit(std.testing.allocator);
    var decoder = http1.ChunkedDecoder{};

    const first = try decoder.decode(std.testing.allocator, "4\r\nWi", &body, .{
        .max_output_bytes = 16,
        .max_wire_bytes = 64,
    });
    try std.testing.expect(!first.done);
    const second = try decoder.decode(
        std.testing.allocator,
        "ki\r\n5\r\npedia\r\n0\r\nx-end: yes\r\n\r\n",
        &body,
        .{
            .max_output_bytes = 16,
            .max_wire_bytes = 64,
        },
    );
    try std.testing.expect(second.done);
    try std.testing.expectEqualStrings("Wikipedia", body.items);
}

test "egress HTTP1 parser tolerates bare-LF line terminators" {
    var scan_start: usize = 0;
    var parsed = (try http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\nContent-Length: 5\nConnection: close\n\nhello",
        &scan_start,
        http1.default_max_header_bytes,
    )).?;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 200), parsed.status_code);
    try std.testing.expectEqual(http1.BodyFraming.content_length, parsed.body_framing);
    try std.testing.expectEqualStrings("hello", parsed.initial_body_bytes);
    try std.testing.expect(parsed.close_after_response);

    var mixed_scan: usize = 0;
    var mixed = (try http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 204 No Content\r\nx-a: 1\nx-b: 2\r\n\n",
        &mixed_scan,
        http1.default_max_header_bytes,
    )).?;
    defer mixed.deinit();
    try std.testing.expectEqual(@as(u16, 204), mixed.status_code);
    try std.testing.expectEqual(@as(usize, 2), mixed.headers.len);
    try std.testing.expectEqualStrings("1", mixed.headers[0].value);
    try std.testing.expectEqualStrings("2", mixed.headers[1].value);
    try std.testing.expect(mixed.close_after_response);

    const request_line = try http1.parseRequestLineView("GET /x HTTP/1.1\nHost: demo\n\n");
    try std.testing.expectEqualStrings("GET", request_line.method);
    try std.testing.expectEqualStrings("/x", request_line.path);
    try std.testing.expectEqualStrings("Host: demo\n\n", request_line.prebuffer);
    try std.testing.expect(request_line.lenient_line_end);

    var head_scan: usize = 0;
    var head = (try http1.completeHead(
        std.testing.allocator,
        "Host: demo.test\nContent-Length: 3\n\nabc",
        &head_scan,
        http1.default_max_header_bytes,
    )).?;
    defer head.deinit();
    try std.testing.expectEqualStrings("demo.test", head.host.?);
    try std.testing.expectEqualStrings("abc", head.initial_body_bytes);
    try std.testing.expect(head.close_after_response);
}

test "egress HTTP1 chunked decoder tolerates bare-LF framing" {
    var body = std.array_list.Aligned(u8, null).empty;
    defer body.deinit(std.testing.allocator);
    var decoder = http1.ChunkedDecoder{};

    const result = try decoder.decode(
        std.testing.allocator,
        "4\nWiki\n5\npedia\n0\nx-end: yes\n\n",
        &body,
        .{
            .max_output_bytes = 16,
            .max_wire_bytes = 64,
        },
    );
    try std.testing.expect(result.done);
    try std.testing.expect(decoder.saw_lenient_line_end);
    try std.testing.expectEqualStrings("Wikipedia", body.items);
}

test "egress HTTP1 chunked decoder caps wire bytes independent of output" {
    var body = std.array_list.Aligned(u8, null).empty;
    defer body.deinit(std.testing.allocator);
    var decoder = http1.ChunkedDecoder{};

    try std.testing.expectError(
        error.FetchResponseEncodedTooLarge,
        decoder.decode(std.testing.allocator, "0\r\nx: y\r\n\r\n", &body, .{
            .max_output_bytes = 1024,
            .max_wire_bytes = 8,
        }),
    );
}

test "egress HTTP1 chunked decoder caps extension and trailer bytes" {
    var body = std.array_list.Aligned(u8, null).empty;
    defer body.deinit(std.testing.allocator);
    var extension_decoder = http1.ChunkedDecoder{};
    const extension_flood = "1;" ++ ("a" ** (http1.parser.max_chunk_extension_bytes + 1));
    try std.testing.expectError(
        error.ChunkExtensionTooLarge,
        extension_decoder.decode(std.testing.allocator, extension_flood, &body, .{
            .max_output_bytes = 16,
        }),
    );

    var trailer_decoder = http1.ChunkedDecoder{};
    const trailer_flood = "0\r\n" ++ ("x: y\r\n" ** (http1.parser.max_chunk_trailer_bytes / 4));
    try std.testing.expectError(
        error.ChunkedTrailersTooLarge,
        trailer_decoder.decode(std.testing.allocator, trailer_flood, &body, .{
            .max_output_bytes = 16,
        }),
    );
}

test "egress HTTP1 response parser accepts chunked-final transfer codings" {
    var scan_start: usize = 0;
    var gzip_chunked = (try http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        &scan_start,
        http1.default_max_header_bytes,
    )).?;
    defer gzip_chunked.deinit();
    try std.testing.expectEqual(http1.BodyFraming.http1_chunked, gzip_chunked.body_framing);
    try std.testing.expectEqual(http1.TransferCoding.gzip, gzip_chunked.transfer_coding);

    var sloppy_scan: usize = 0;
    var sloppy = (try http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: ,, identity , chunked ,\r\n\r\n",
        &sloppy_scan,
        http1.default_max_header_bytes,
    )).?;
    defer sloppy.deinit();
    try std.testing.expectEqual(http1.BodyFraming.http1_chunked, sloppy.body_framing);
    try std.testing.expectEqual(http1.TransferCoding.none, sloppy.transfer_coding);

    var split_scan: usize = 0;
    var split_headers = (try http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: deflate\r\nTransfer-Encoding: chunked\r\n\r\n",
        &split_scan,
        http1.default_max_header_bytes,
    )).?;
    defer split_headers.deinit();
    try std.testing.expectEqual(http1.BodyFraming.http1_chunked, split_headers.body_framing);
    try std.testing.expectEqual(http1.TransferCoding.deflate, split_headers.transfer_coding);

    var unknown_scan: usize = 0;
    try std.testing.expectError(error.UnsupportedTransferEncoding, http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: weird, chunked\r\n\r\n",
        &unknown_scan,
        http1.default_max_header_bytes,
    ));

    var stacked_scan: usize = 0;
    try std.testing.expectError(error.UnsupportedTransferEncoding, http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, br, chunked\r\n\r\n",
        &stacked_scan,
        http1.default_max_header_bytes,
    ));
}

test "egress HTTP1 response parser reads non-chunked transfer codings to close" {
    var scan_start: usize = 0;
    var gzip_only = (try http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
        &scan_start,
        http1.default_max_header_bytes,
    )).?;
    defer gzip_only.deinit();
    try std.testing.expectEqual(http1.BodyFraming.close_delimited, gzip_only.body_framing);
    try std.testing.expectEqual(http1.TransferCoding.none, gzip_only.transfer_coding);
    try std.testing.expect(gzip_only.close_after_response);

    var conflict_scan: usize = 0;
    try std.testing.expectError(error.InvalidResponseBodyFraming, http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
        &conflict_scan,
        http1.default_max_header_bytes,
    ));

    var reversed_scan: usize = 0;
    try std.testing.expectError(error.InvalidResponseBodyFraming, http1.completeResponseHead(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nContent-Length: 5\r\n\r\n",
        &reversed_scan,
        http1.default_max_header_bytes,
    ));
}
