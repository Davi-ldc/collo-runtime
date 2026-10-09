//! Validates an outbound fetch's HTTP/2 response: the head, the trailers and
//! the body against its declared length and the caller's size cap. Malformed
//! content is a stream error, so one bad response never fails the connection
//! that other fetches share.

const std = @import("std");
const hpack = @import("collo_hpack");
const http = @import("collo_http");

// The byte cap, limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX, is the
// binding limit; this count only stops a block split into many tiny fields.
pub const max_response_header_count: usize = 512;

pub const ResponseHead = struct {
    status_code: u16,
    content_length: ?usize = null,
    headers: []const hpack.Header,
    end_stream: bool,
};

/// Malformed response content (RFC 9113 §8.1.1) is a stream error: its fetch
/// fails and the shared connection keeps serving the other streams.
/// `Http2ProtocolError`, which fails the connection, is kept for framing and
/// session-state violations.
pub fn parseResponseHead(headers: []const hpack.Header, end_stream: bool) !ResponseHead {
    var status_code: ?u16 = null;
    var saw_regular = false;
    var content_length: ?usize = null;

    for (headers) |header| {
        if (header.name.len == 0)
            return error.InvalidHttp2ResponseHeader;
        if (header.name[0] == ':') {
            if (saw_regular)
                return error.Http2MalformedResponse;
            if (!std.mem.eql(u8, header.name, ":status"))
                return error.Http2MalformedResponse;
            if (status_code != null)
                return error.Http2MalformedResponse;
            status_code = try parseStatus(header.value);
            continue;
        }

        saw_regular = true;
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
        .headers = headers,
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

/// One stream's response as it arrives. Interim (1xx) heads are dropped and
/// 101 is refused. The body may not exceed `max_body_bytes` and must be empty
/// for 204, 304 or when the caller sets `body_forbidden`, as it does for
/// HEAD; any other body must match its content-length.
pub const ResponseAccumulator = struct {
    allocator: std.mem.Allocator,
    max_body_bytes: usize,
    body: std.array_list.Aligned(u8, null) = .empty,
    headers: std.array_list.Aligned(hpack.Header, null) = .empty,
    status_code: ?u16 = null,
    content_length: ?usize = null,
    complete: bool = false,
    body_forbidden: bool = false,
    received_body_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_body_bytes: usize) ResponseAccumulator {
        return .{ .allocator = allocator, .max_body_bytes = max_body_bytes };
    }

    pub fn deinit(self: *ResponseAccumulator) void {
        self.body.deinit(self.allocator);
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn receiveHead(self: *ResponseAccumulator, head: ResponseHead) !void {
        if (self.status_code != null)
            return error.Http2MalformedResponse;
        if (head.status_code == 101)
            return error.UnsupportedFetchProtocolUpgrade;
        if (isInformational(head.status_code)) {
            if (head.end_stream)
                return error.Http2MalformedResponse;
            return;
        }
        self.status_code = head.status_code;
        self.content_length = head.content_length;
        for (head.headers) |header| {
            if (header.name[0] == ':')
                continue;
            const name = try self.allocator.dupe(u8, header.name);
            errdefer self.allocator.free(name);
            const value = try self.allocator.dupe(u8, header.value);
            errdefer self.allocator.free(value);
            try self.headers.append(self.allocator, .{ .name = name, .value = value });
        }
        if (head.status_code == 204 or head.status_code == 304)
            self.body_forbidden = true;
        if (head.end_stream)
            try self.finish();
    }

    pub fn receiveData(self: *ResponseAccumulator, bytes: []const u8, end_stream: bool) !void {
        try self.receiveDataMode(bytes, end_stream, true);
    }

    /// Validates and counts the bytes without keeping them, for callers that
    /// deliver the body as chunks.
    pub fn receiveDataNoStore(self: *ResponseAccumulator, bytes: []const u8, end_stream: bool) !void {
        try self.receiveDataMode(bytes, end_stream, false);
    }

    fn receiveDataMode(self: *ResponseAccumulator, bytes: []const u8, end_stream: bool, store_body: bool) !void {
        if (self.status_code == null)
            return error.Http2MalformedResponse;
        if (self.complete)
            return error.Http2MalformedResponse;
        if (self.body_forbidden and bytes.len != 0)
            return error.Http2ResponseBodyForbidden;
        if (bytes.len > self.max_body_bytes -| self.received_body_bytes)
            return error.FetchResponseTooLarge;
        if (store_body)
            try self.body.appendSlice(self.allocator, bytes);
        self.received_body_bytes += bytes.len;
        if (end_stream)
            try self.finish();
    }

    pub fn finish(self: *ResponseAccumulator) !void {
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

    pub fn takeBody(self: *ResponseAccumulator) ![]u8 {
        if (!self.complete)
            return error.Http2ResponseIncomplete;
        return self.body.toOwnedSlice(self.allocator);
    }

    pub fn takeHeaders(self: *ResponseAccumulator) ![]hpack.Header {
        if (!self.complete)
            return error.Http2ResponseIncomplete;
        return self.headers.toOwnedSlice(self.allocator);
    }
};

fn validateRegularHeader(header: hpack.Header) !void {
    http.headers.validate(header.name, header.value) catch return error.InvalidHttp2ResponseHeader;
    for (header.name) |byte| {
        if (byte >= 'A' and byte <= 'Z')
            return error.InvalidHttp2ResponseHeader;
    }
    if (std.mem.eql(u8, header.name, "transfer-encoding") or
        std.mem.eql(u8, header.name, "connection") or
        std.mem.eql(u8, header.name, "keep-alive") or
        std.mem.eql(u8, header.name, "proxy-connection") or
        std.mem.eql(u8, header.name, "upgrade"))
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
