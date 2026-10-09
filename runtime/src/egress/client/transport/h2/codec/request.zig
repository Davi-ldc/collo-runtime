//! Encodes an outbound request's HEADERS, plus any inline body as DATA, and
//! validates a request head before it reaches a live session. Pseudo-headers
//! always come first, and content-length is synthesized for any request with
//! a body or body semantics. Connection-specific headers, `host`, a `te` other
//! than trailers, uppercase names and a caller's content-length are rejected.

const std = @import("std");
const h2 = @import("collo_http").http2;
const http = @import("collo_http");
const hpack = @import("collo_hpack");
const limits = @import("collo_limits");

pub const RequestHead = struct {
    method: []const u8,
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,
    headers: []const hpack.Header = &.{},
    body: []const u8 = &.{},
    /// Overrides END_STREAM on the HEADERS frame. `client.Connection` always
    /// sets it and leaves `body` empty, because it sends the body itself as
    /// flow-controlled DATA frames.
    end_stream_after_headers: ?bool = null,
    /// The content-length to declare when the body follows as separate DATA
    /// frames and `body` is empty at encode time.
    declared_content_length: ?u64 = null,
};

pub const EncodedRequest = struct {
    allocator: std.mem.Allocator,
    wire: []u8,
    /// Length of the HPACK header block as sent, without frame headers or
    /// padding. The request side bills this compressed block, never the
    /// framing around it.
    header_block_len: usize = 0,

    pub fn deinit(self: *EncodedRequest) void {
        self.allocator.free(self.wire);
        self.* = undefined;
    }
};

pub fn encodeRequest(
    allocator: std.mem.Allocator,
    encoder: *hpack.Encoder,
    stream_id: u32,
    max_frame_size: u32,
    head: RequestHead,
) !EncodedRequest {
    if (stream_id == 0 or stream_id & 1 == 0)
        return error.InvalidHttp2StreamId;
    try validateRequestHead(head);

    // WAFs, request signers and strict origins expect an explicit
    // content-length on requests with body semantics, as curl, Bun and
    // browsers send. validateRegularHeader rejects a caller's content-length,
    // so the synthesized one is the only one.
    var content_length_buf: [20]u8 = undefined;
    const body_len: ?u64 = head.declared_content_length orelse
        (if (head.body.len != 0 or methodHasRequestBody(head.method)) @as(?u64, head.body.len) else null);
    const content_length = if (body_len) |len|
        std.fmt.bufPrint(&content_length_buf, "{d}", .{len}) catch unreachable
    else
        null;
    const hpack_headers = try buildHeaderList(allocator, head, content_length);
    defer allocator.free(hpack_headers);

    const block = try encoder.encodeHeadersScratch(
        allocator,
        hpack_headers,
        limits.headers.EGRESS_H2_REQUEST_HEADER_BLOCK_BYTES,
    );

    const has_body = head.body.len != 0;
    const headers_end_stream = head.end_stream_after_headers orelse !has_body;
    return .{
        .allocator = allocator,
        .wire = try h2.encodeHeadersAndDataFrames(
            allocator,
            max_frame_size,
            stream_id,
            block,
            headers_end_stream,
            head.body,
            has_body,
        ),
        .header_block_len = block.len,
    };
}

/// The pool calls this before it picks a connection. A request rejected here
/// fails alone, while an error from opening its stream would fail the pool
/// entry and every stream already sharing that connection.
pub fn validateRequestHead(head: RequestHead) !void {
    try validatePseudoValue(head.method);
    try validatePseudoValue(head.scheme);
    try validatePseudoValue(head.authority);
    try http.request_target.validateOriginForm(head.path);
    for (head.headers) |header|
        try validateRegularHeader(header);
}

fn methodHasRequestBody(method: []const u8) bool {
    return std.mem.eql(u8, method, "POST") or
        std.mem.eql(u8, method, "PUT") or
        std.mem.eql(u8, method, "PATCH");
}

fn buildHeaderList(allocator: std.mem.Allocator, head: RequestHead, content_length: ?[]const u8) ![]hpack.Header {
    const extra: usize = if (content_length != null) 1 else 0;
    const out = try allocator.alloc(hpack.Header, 4 + extra + head.headers.len);
    errdefer allocator.free(out);
    out[0] = .{ .name = ":method", .value = head.method };
    out[1] = .{ .name = ":scheme", .value = head.scheme };
    out[2] = .{ .name = ":authority", .value = head.authority };
    out[3] = .{ .name = ":path", .value = head.path };

    var cursor: usize = 4;
    if (content_length) |value| {
        out[cursor] = .{ .name = "content-length", .value = value };
        cursor += 1;
    }
    for (head.headers) |header| {
        out[cursor] = header;
        cursor += 1;
    }
    return out[0..cursor];
}

fn validatePseudoValue(value: []const u8) !void {
    if (value.len == 0)
        return error.InvalidHttp2RequestHeader;
    for (value) |byte| {
        if (byte == '\r' or byte == '\n' or byte == 0)
            return error.InvalidHttp2RequestHeader;
    }
}

fn validateRegularHeader(header: hpack.Header) !void {
    http.headers.validate(header.name, header.value) catch return error.InvalidHttp2RequestHeader;
    if (header.name[0] == ':')
        return error.ForbiddenHttp2RequestHeader;
    for (header.name) |byte| {
        if (byte >= 'A' and byte <= 'Z')
            return error.InvalidHttp2RequestHeader;
    }
    if (isForbiddenRequestHeader(header.name))
        return error.ForbiddenHttp2RequestHeader;
    if (std.ascii.eqlIgnoreCase(header.name, "te") and !std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, &std.ascii.whitespace), "trailers"))
        return error.ForbiddenHttp2RequestHeader;
}

fn isForbiddenRequestHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "proxy-connection") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "upgrade") or
        std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "content-length");
}
