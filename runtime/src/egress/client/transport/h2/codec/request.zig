//! Encodes an outbound request's HEADERS, plus any inline body as DATA, and
//! validates a request head before it reaches a live session. Pseudo-headers
//! always come first, and content-length is synthesized for any request with
//! a body or body semantics. Connection-specific headers, `host`, a `te` other
//! than trailers, uppercase names, a caller's content-length and a head whose
//! header block could outgrow `EGRESS_H2_REQUEST_HEADER_BLOCK_BYTES` are
//! rejected.
//!
//! Encoding a head that passed validation can fail only for memory or for an
//! encoder its connection already lost, never for the head itself.

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

    pub fn deinit(self: *EncodedRequest) void {
        self.allocator.free(self.wire);
        self.* = undefined;
    }
};

/// Encodes the head through `encoder` into `encode_scratch`, which must hold
/// `EGRESS_H2_REQUEST_HEADER_BLOCK_BYTES`, then frames the block and any
/// inline body into one allocation of `allocator` that the result owns.
pub fn encodeRequest(
    allocator: std.mem.Allocator,
    encoder: *hpack.Encoder,
    encode_scratch: []u8,
    stream_id: u32,
    max_frame_size: u32,
    head: RequestHead,
) !EncodedRequest {
    if (stream_id == 0 or stream_id & 1 == 0)
        return error.InvalidHttp2StreamId;
    try validateRequestHead(head);

    var content_length_buffer: [content_length_digits_max]u8 = undefined;
    const content_length = contentLengthValue(head, &content_length_buffer);
    const hpack_headers = try buildHeaderList(allocator, head, content_length);
    defer allocator.free(hpack_headers);

    const block = try encoder.encodeHeaders(
        encode_scratch,
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
    };
}

/// The pool calls this before it picks a connection. A request rejected here
/// fails alone, while an error from opening its stream would fail the pool
/// entry and every stream already sharing that connection, so it refuses
/// everything about the head that `encodeRequest` could refuse.
///
/// Fails with `error.Http2RequestHeadersTooLarge` when the head's header
/// block could take more than `EGRESS_H2_REQUEST_HEADER_BLOCK_BYTES` before
/// compression. The encoder writes into a scratch of that size, and an
/// encode that runs out of room midway leaves the connection's dynamic table
/// changed for a block the peer never sees, which ends the connection for
/// every stream on it. The bound ignores what compression could save, so
/// whether a head fits never depends on the connection's table.
pub fn validateRequestHead(head: RequestHead) !void {
    try validatePseudoValue(head.method);
    try validatePseudoValue(head.scheme);
    try validatePseudoValue(head.authority);
    try http.request_target.validateOriginForm(head.path);
    for (head.headers) |header|
        try validateRegularHeader(header);
    var content_length_buffer: [content_length_digits_max]u8 = undefined;
    const content_length = contentLengthValue(head, &content_length_buffer);
    if (headerBlockBytesMax(head, content_length) > limits.headers.EGRESS_H2_REQUEST_HEADER_BLOCK_BYTES)
        return error.Http2RequestHeadersTooLarge;
}

/// The digits of the largest content-length, `maxInt(u64)`.
const content_length_digits_max: usize = 20;

/// The content-length the request declares, written into `buffer`, or null
/// for none. WAFs, request signers and strict origins expect an explicit
/// content-length on requests with body semantics, as curl, Bun and browsers
/// send. `validateRegularHeader` rejects a caller's content-length, so this
/// one is the only one.
fn contentLengthValue(head: RequestHead, buffer: *[content_length_digits_max]u8) ?[]const u8 {
    const body_len: ?u64 = head.declared_content_length orelse
        (if (head.body.len != 0 or methodHasRequestBody(head.method)) @as(?u64, head.body.len) else null);
    const len = body_len orelse return null;
    return std.fmt.bufPrint(buffer, "{d}", .{len}) catch unreachable;
}

/// The most bytes the header block `encodeRequest` builds for `head` can
/// take, whatever the connection's dynamic table holds and whatever table
/// size updates its encoder owes the peer (`hpack.encodedFieldBytesMax`).
fn headerBlockBytesMax(head: RequestHead, content_length: ?[]const u8) usize {
    var total: usize = hpack.table_size_updates_bytes_max;
    total +|= hpack.encodedFieldBytesMax(.{ .name = ":method", .value = head.method });
    total +|= hpack.encodedFieldBytesMax(.{ .name = ":scheme", .value = head.scheme });
    total +|= hpack.encodedFieldBytesMax(.{ .name = ":authority", .value = head.authority });
    total +|= hpack.encodedFieldBytesMax(.{ .name = ":path", .value = head.path });
    if (content_length) |value|
        total +|= hpack.encodedFieldBytesMax(.{ .name = "content-length", .value = value });
    for (head.headers) |header|
        total +|= hpack.encodedFieldBytesMax(header);
    return total;
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
    if (http.headers.isConnectionSpecificField(header.name, header.value, .request))
        return error.ForbiddenHttp2RequestHeader;
    if (isCodecOwnedRequestHeader(header.name))
        return error.ForbiddenHttp2RequestHeader;
}

/// `host` travels as `:authority`, and the codec writes the request's one
/// `content-length` itself. Names are lowercase by the time this runs.
fn isCodecOwnedRequestHeader(name: []const u8) bool {
    return std.mem.eql(u8, name, "host") or std.mem.eql(u8, name, "content-length");
}
