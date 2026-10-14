//! Validates an outbound fetch's HTTP/2 response: the head, the trailers and
//! the body against its declared length and the caller's size cap. Malformed
//! content, a connection-specific field such as `te` included, is a stream
//! error, so one bad response never fails the connection that other fetches
//! share.
//!
//! Nothing here keeps a field or a body byte: the caller owns the decoded
//! head, and body bytes travel as chunks the codec hands out.

const std = @import("std");
const hpack = @import("collo_hpack");
const http = @import("collo_http");

// The byte cap, limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX, is the
// binding limit; this count only stops a block split into many tiny fields.
pub const max_response_header_count: usize = 512;

pub const ResponseHead = struct {
    status_code: u16,
    content_length: ?usize = null,
    /// Every field after `:status`, which RFC 9113 §8.3 puts first.
    regular_headers: []const hpack.Header,
    end_stream: bool,
};

/// Malformed response content (RFC 9113 §8.1.1) is a stream error: its fetch
/// fails and the shared connection keeps serving the other streams.
/// `Http2ProtocolError`, which fails the connection, is kept for framing and
/// session-state violations.
pub fn parseResponseHead(headers: []const hpack.Header, end_stream: bool) !ResponseHead {
    var status_code: ?u16 = null;
    var first_regular: usize = headers.len;
    var content_length: ?usize = null;

    for (headers, 0..) |header, index| {
        if (header.name.len == 0)
            return error.InvalidHttp2ResponseHeader;
        if (header.name[0] == ':') {
            if (first_regular != headers.len)
                return error.Http2MalformedResponse;
            if (!std.mem.eql(u8, header.name, ":status"))
                return error.Http2MalformedResponse;
            if (status_code != null)
                return error.Http2MalformedResponse;
            status_code = try parseStatus(header.value);
            continue;
        }

        if (first_regular == headers.len)
            first_regular = index;
        try validateRegularHeader(header);
        if (std.mem.eql(u8, header.name, "content-length")) {
            const parsed = http.framing.parseContentLengthValue(header.value) catch
                return error.Http2MalformedResponse;
            if (content_length) |existing| {
                if (existing != parsed)
                    return error.Http2MalformedResponse;
            } else {
                content_length = parsed;
            }
        }
    }

    return .{
        .status_code = status_code orelse return error.Http2MalformedResponse,
        .content_length = content_length,
        .regular_headers = headers[first_regular..],
        .end_stream = end_stream,
    };
}

pub fn validateTrailers(headers: []const hpack.Header) !void {
    for (headers) |header| {
        if (header.name.len == 0 or header.name[0] == ':')
            return error.Http2MalformedResponse;
        try validateRegularHeader(header);
        if (std.mem.eql(u8, header.name, "content-length"))
            return error.Http2MalformedResponse;
    }
}

/// One stream's response as it arrives: whether its final head came, what
/// that head declared, and how many body bytes followed. Interim (1xx) heads
/// are dropped and 101 is refused. The body may not exceed `max_body_bytes`
/// and must be empty for 204, 304 or when the caller sets `body_forbidden`,
/// as it does for HEAD; any other body must match its content-length.
pub const ResponseState = struct {
    max_body_bytes: usize,
    status_code: ?u16 = null,
    content_length: ?usize = null,
    complete: bool = false,
    body_forbidden: bool = false,
    received_body_bytes: usize = 0,

    pub const HeadKind = enum { interim, final };

    pub fn init(max_body_bytes: usize) ResponseState {
        return .{ .max_body_bytes = max_body_bytes };
    }

    pub fn receiveHead(self: *ResponseState, head: ResponseHead) !HeadKind {
        if (self.status_code != null)
            return error.Http2MalformedResponse;
        if (head.status_code == 101)
            return error.UnsupportedFetchProtocolUpgrade;
        if (isInformational(head.status_code)) {
            if (head.end_stream)
                return error.Http2MalformedResponse;
            return .interim;
        }
        self.status_code = head.status_code;
        self.content_length = head.content_length;
        if (head.status_code == 204 or head.status_code == 304)
            self.body_forbidden = true;
        if (head.end_stream)
            try self.finish();
        return .final;
    }

    /// Counts and checks body bytes; DATA before the final head fails the
    /// stream.
    pub fn receiveData(self: *ResponseState, byte_count: usize, end_stream: bool) !void {
        if (self.status_code == null)
            return error.Http2MalformedResponse;
        if (self.complete)
            return error.Http2MalformedResponse;
        if (self.body_forbidden and byte_count != 0)
            return error.Http2ResponseBodyForbidden;
        if (byte_count > self.max_body_bytes -| self.received_body_bytes)
            return error.FetchResponseTooLarge;
        self.received_body_bytes += byte_count;
        if (end_stream)
            try self.finish();
    }

    pub fn finish(self: *ResponseState) !void {
        if (self.status_code == null)
            return error.Http2MalformedResponse;
        // A HEAD or 304 response may declare the length of a body it never
        // sends, so no bodiless response is held to its content-length.
        if (!self.body_forbidden) if (self.content_length) |expected| {
            if (self.received_body_bytes != expected)
                return error.Http2ContentLengthMismatch;
        };
        self.complete = true;
    }
};

fn validateRegularHeader(header: hpack.Header) !void {
    http.headers.validate(header.name, header.value) catch return error.InvalidHttp2ResponseHeader;
    for (header.name) |byte| {
        if (byte >= 'A' and byte <= 'Z')
            return error.InvalidHttp2ResponseHeader;
    }
    // `te` is among them: RFC 9113 §8.2.2 admits it only in a request.
    if (http.headers.isConnectionSpecificField(header.name, header.value, .response))
        return error.Http2MalformedResponse;
}

fn parseStatus(value: []const u8) !u16 {
    if (value.len != 3)
        return error.Http2MalformedResponse;
    const status = std.fmt.parseInt(u16, value, 10) catch return error.Http2MalformedResponse;
    if (status < 100 or status > 599)
        return error.Http2MalformedResponse;
    return status;
}

fn isInformational(status_code: u16) bool {
    return status_code >= 100 and status_code < 200;
}
