//! Request-head validation (`server/ingress/http2/request_head.zig`) on
//! decoded header lists: pseudo-headers and the `:path` split, body framing
//! with and without content-length, the HTTP/2 header rules with `te`,
//! Host against `:authority`, authority normalization, a declared body over
//! the bound left to the lane, the arrival a head keeps, the bound on a
//! head's fields, the `expect: 100-continue` expectation, trailers, and what
//! a refused head keeps for its record. Root
//! of the `h2-request` suite, which runs with no engine in
//! `server-fast-test`, `h2-transport-test` and the `test` aggregate; the
//! driver that decodes a connection's header blocks into these lists, and
//! answers the heads `parse` refuses, is covered in `connection.zig`.

const std = @import("std");

const ipc = @import("collo_ipc");
const h2_request = @import("collo_server_h2").http2.request_head;

/// A decoded header field, as `parse` takes them.
const Header = std.meta.Elem(@FieldType(h2_request.ParsedHead, "headers"));

test "http2 request parser normalizes pseudo headers and query split" {
    const parsed = try h2_request.parse(&.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/submit?x=1" },
        .{ .name = "content-length", .value = "12" },
        .{ .name = "content-type", .value = "text/plain" },
    }, false, 0);

    try std.testing.expectEqualStrings("POST", parsed.method);
    try std.testing.expectEqualStrings("/submit", parsed.path);
    try std.testing.expectEqualStrings("x=1", parsed.raw_query);
    try std.testing.expectEqualStrings("demo.example.test", parsed.authority());
    try std.testing.expectEqual(ipc.RequestBodyFraming.ingress_channel, parsed.body_framing);
    try std.testing.expectEqual(@as(?usize, 12), parsed.content_length);
    try std.testing.expectEqual(@as(usize, 2), parsed.headers.len);
    try std.testing.expectEqualStrings("content-length", parsed.headers[0].name);
}

test "http2 request parser supports end-stream delimited bodies without content length" {
    const parsed = try h2_request.parse(&.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/upload" },
        .{ .name = "content-type", .value = "text/plain" },
    }, false, 0);

    try std.testing.expectEqual(ipc.RequestBodyFraming.ingress_channel, parsed.body_framing);
    try std.testing.expectEqual(@as(?usize, null), parsed.content_length);
    try std.testing.expect(!parsed.end_stream);
}

test "http2 request parser rejects invalid h2-only header shapes" {
    try std.testing.expectError(error.Http2UppercaseHeaderName, h2_request.parse(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "X-Bad", .value = "1" },
    }, true, 0));

    try std.testing.expectError(error.Http2PseudoHeaderAfterRegularHeader, h2_request.parse(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = "accept", .value = "*/*" },
        .{ .name = ":path", .value = "/" },
    }, true, 0));

    try std.testing.expectError(error.Http2ConnectionSpecificHeader, h2_request.parse(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "connection", .value = "close" },
    }, true, 0));
}

test "http2 request parser requires host to match authority when present" {
    const parsed = try h2_request.parse(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "Demo.Example.Test:443" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "demo.example.test" },
    }, true, 0);
    // The head carries the authority as `normalizeAuthority` spells it,
    // lowercased and without the default port.
    try std.testing.expectEqualStrings("demo.example.test", parsed.authority());

    try std.testing.expectError(error.Http2HostAuthorityMismatch, h2_request.parse(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "evil.example.test" },
    }, true, 0));

    try std.testing.expectError(error.Http2DuplicateHostHeader, h2_request.parse(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "demo.example.test" },
        .{ .name = "host", .value = "demo.example.test" },
    }, true, 0));
}

test "http2 request authority keeps its port and accepts an IPv6 literal" {
    const parsed = try h2_request.parse(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "[::1]:8443" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "[::1]:8443" },
    }, true, 0);
    try std.testing.expectEqualStrings("[::1]:8443", parsed.authority());
    var buffer: [h2_request.authority_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("127.0.0.1:8443", try h2_request.normalizeAuthority("127.0.0.1:8443", &buffer));
    try std.testing.expectEqualStrings("demo.example.test", try h2_request.normalizeAuthority("Demo.Example.Test:443", &buffer));

    // The port is part of the origin, so a Host on another port names
    // another origin.
    try std.testing.expectError(error.Http2HostAuthorityMismatch, h2_request.parse(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test:8443" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "host", .value = "demo.example.test" },
    }, true, 0));
}

test "http2 request parser rejects bodies ended before declared content length" {
    try std.testing.expectError(error.Http2ContentLengthMismatch, h2_request.parse(&.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "content-length", .value = "1" },
    }, true, 0));
}

test "http2 request parser leaves a declared body over the bound to the lane, which answers it once the route is known" {
    // One byte past `limits.http_body.MATERIALIZED_BODY_BYTES_MAX`: the head
    // parses, so the lane's 413 and its record can name the matched route
    // (`runner/admission.zig`).
    const parsed = try h2_request.parse(&.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "content-length", .value = "4194305" },
    }, false, 0);
    try std.testing.expectEqual(@as(?usize, 4_194_305), parsed.content_length);
}

test "http2 a request may carry te only as trailers, and the head keeps when it arrived" {
    const fields = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "te", .value = "gzip" },
    };
    try std.testing.expectError(error.Http2ConnectionSpecificHeader, h2_request.parse(&fields, true, 0));

    var trailers = fields;
    for ([_][]const u8{ "trailers", "Trailers", " trailers\t" }) |value| {
        trailers[4].value = value;
        const parsed = try h2_request.parse(&trailers, true, 42);
        try std.testing.expectEqual(@as(u64, 42), parsed.received_ns);
        try std.testing.expectEqualStrings("te", parsed.headers[0].name);
    }
    // A list that names trailers among other codings is still not trailers.
    trailers[4].value = "trailers, deflate";
    try std.testing.expectError(error.Http2ConnectionSpecificHeader, h2_request.parse(&trailers, true, 0));
}

test "a refused head keeps the method, path and user agent its block carried, for its record" {
    const refused = h2_request.RefusedHead.of(&.{
        .{ .name = ":method", .value = "DELETE" },
        .{ .name = ":path", .value = "/items/7?force=1" },
        .{ .name = "user-agent", .value = "probe/2" },
        .{ .name = "host", .value = "evil.example.test" },
        .{ .name = ":path", .value = "/second" },
    }, .malformed, false, 9);
    try std.testing.expectEqual(h2_request.RefusedHead.Reason.malformed, refused.reason);
    try std.testing.expectEqualStrings("DELETE", refused.method);
    try std.testing.expectEqualStrings("/items/7", refused.path);
    try std.testing.expectEqualStrings("probe/2", refused.user_agent);
    try std.testing.expect(!refused.request_ended);
    try std.testing.expectEqual(@as(u64, 9), refused.received_ns);

    const bare = h2_request.RefusedHead.of(&.{}, .fields_too_large, true, 0);
    try std.testing.expectEqualStrings("", bare.method);
    try std.testing.expectEqualStrings("", bare.path);
}

test "http2 request parser refuses a head of more fields than max_header_count" {
    // The bound counts the pseudo-header fields too.
    var fields: [h2_request.max_header_count + 1]Header = undefined;
    fields[0] = .{ .name = ":method", .value = "GET" };
    fields[1] = .{ .name = ":scheme", .value = "https" };
    fields[2] = .{ .name = ":authority", .value = "demo.example.test" };
    fields[3] = .{ .name = ":path", .value = "/" };
    for (fields[4..]) |*field|
        field.* = .{ .name = "x-repeat", .value = "1" };

    const admitted = try h2_request.parse(fields[0..h2_request.max_header_count], true, 0);
    try std.testing.expectEqual(h2_request.max_header_count - 4, admitted.headers.len);
    try std.testing.expectError(error.TooManyRequestHeaders, h2_request.parse(&fields, true, 0));
}

test "http2 request parser expects 100-continue only from a head that announces a body" {
    // The expectation matches without regard to case or the whitespace
    // around it.
    const expecting = [_]Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/upload" },
        .{ .name = "expect", .value = " 100-Continue\t" },
    };
    try std.testing.expect((try h2_request.parse(&expecting, false, 0)).expects_continue);
    // A head that ends its stream sends no body to wait for.
    try std.testing.expect(!(try h2_request.parse(&expecting, true, 0)).expects_continue);

    const empty_body = [_]Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/upload" },
        .{ .name = "content-length", .value = "0" },
        .{ .name = "expect", .value = "100-continue" },
    };
    try std.testing.expect(!(try h2_request.parse(&empty_body, false, 0)).expects_continue);

    const other_expectation = [_]Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "demo.example.test" },
        .{ .name = ":path", .value = "/upload" },
        .{ .name = "expect", .value = "100-continue-later" },
    };
    try std.testing.expect(!(try h2_request.parse(&other_expectation, false, 0)).expects_continue);
}

test "http2 request trailer validator accepts regular h2 headers only" {
    try h2_request.validateTrailers(&.{
        .{ .name = "x-checksum", .value = "abc" },
    });

    try std.testing.expectError(error.Http2InvalidTrailerPseudoHeader, h2_request.validateTrailers(&.{
        .{ .name = ":path", .value = "/late" },
    }));

    try std.testing.expectError(error.Http2ConnectionSpecificHeader, h2_request.validateTrailers(&.{
        .{ .name = "connection", .value = "close" },
    }));
}
