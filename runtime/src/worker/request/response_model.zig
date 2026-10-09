//! The worker's model of a handler's response, a status, headers and a body
//! in one of several forms, and the bounds a response must pass before the
//! worker hands it to the host: `MATERIALIZED_BODY_BYTES_MAX` for the body,
//! and `max_response_header_count` and `max_response_header_bytes`, defined
//! here, for the headers. It holds no state and runs on the worker's VM
//! thread.

const std = @import("std");
const bindings = @import("collo_bindings");
const http_headers = @import("collo_http").headers;
const http_status_meta = @import("collo_http").status;
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

pub const Header = ipc.ingress_channel.ResponseHeader;

/// A response body in the form its producer handed over. `deinitOwned`
/// releases what a body owns, except a fetch stream, which goes back to the
/// runtime that owns it (`Runtime.releaseFetchBody`).
pub const Body = union(enum) {
    empty,
    /// Borrowed; the producer keeps the bytes alive until the response is
    /// written.
    bytes: []const u8,
    /// Allocated by the allocator later passed to `takeOwnedBytes` or
    /// `deinitOwned`.
    owned: []u8,
    /// A body the bridge extracted, whole or in segments.
    abi: bindings.ExtractedResponseBody,
    /// A fetch response body the response streams; no bytes are held here.
    fetch_stream: bindings.FetchBodyIdentity,

    /// The body's length in bytes; 0 for a fetch stream.
    pub fn len(self: Body) usize {
        return switch (self) {
            .empty => 0,
            .bytes => |bytes| bytes.len,
            .owned => |bytes| bytes.len,
            .abi => |body| body.total_len,
            .fetch_stream => 0,
        };
    }

    /// The body as one slice, or an empty slice when an extracted body spans
    /// several segments; `isContiguous` tells the two apart.
    pub fn contiguous(self: Body) []const u8 {
        return switch (self) {
            .empty => "",
            .bytes => |bytes| bytes,
            .owned => |bytes| bytes,
            .abi => |body| body.firstContiguousSlice(),
            .fetch_stream => "",
        };
    }

    pub fn segments(self: Body) []const bindings.ByteSegment {
        return switch (self) {
            .abi => |body| body.segmentsSlice(),
            else => &.{},
        };
    }

    pub fn isContiguous(self: Body) bool {
        return self.contiguous().len == self.len();
    }

    pub fn hasFetchStream(self: Body) bool {
        return switch (self) {
            .fetch_stream => true,
            else => false,
        };
    }

    pub fn takeFetchStream(self: *Body) ?bindings.FetchBodyIdentity {
        switch (self.*) {
            .fetch_stream => |identity| {
                self.* = .empty;
                return identity;
            },
            else => return null,
        }
    }

    /// Moves the body out as bytes that `allocator` owns, copying unless it
    /// is already `owned`, and leaves `.empty` behind. A fetch stream has no
    /// bytes and fails with `error.InvalidResponseBody`, as does an extracted
    /// body whose segments do not add up to its length; a failure leaves the
    /// body as it was.
    pub fn takeOwnedBytes(self: *Body, allocator: std.mem.Allocator) ![]u8 {
        switch (self.*) {
            .owned => |bytes| {
                self.* = .empty;
                return bytes;
            },
            .bytes => |bytes| {
                const owned = try allocator.dupe(u8, bytes);
                self.* = .empty;
                return owned;
            },
            .abi => |*body| {
                const copied = try copyAbiBody(allocator, body.*);
                body.deinit();
                self.* = .empty;
                return copied;
            },
            .empty => {
                self.* = .empty;
                return try allocator.dupe(u8, "");
            },
            .fetch_stream => return error.InvalidResponseBody,
        }
    }

    pub fn deinitOwned(self: *Body, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty,
            .bytes,
            .fetch_stream,
            => {},
            .owned => |bytes| allocator.free(bytes),
            .abi => |*body| body.deinit(),
        }
        self.* = .empty;
    }
};

/// A response as the worker writes it; `headers` is borrowed.
pub const Response = struct {
    status: u16 = 200,
    headers: []const Header = &.{},
    body: Body = .empty,
};

pub const max_response_header_count: usize = 256;
/// Counts the bytes of every header name and value, without separators.
pub const max_response_header_bytes: usize = 16 * 1024;

/// The bounds the bridge applies while it extracts a handler's Response
/// (`collo_response_extract`), the same ones `validate` checks.
pub fn extractionLimits() bindings.ResponseExtractLimits {
    return .{
        .max_body_bytes = limits.http_body.MATERIALIZED_BODY_BYTES_MAX,
        .max_header_count = max_response_header_count,
        .max_header_bytes = max_response_header_bytes,
    };
}

/// Checks the status, then the body length and headers (`validateShape`).
pub fn validate(response: Response) !void {
    try http_status_meta.validate(response.status);
    try validateShape(response.body.len(), response.headers);
}

/// Fails with `error.ResponseBodyTooLarge` for a body over
/// `MATERIALIZED_BODY_BYTES_MAX`, with `error.ResponseHeadersTooLarge` past
/// either header bound, or with the first header `validateHeader` refuses.
pub fn validateShape(body_len: usize, headers: []const Header) !void {
    if (body_len > limits.http_body.MATERIALIZED_BODY_BYTES_MAX)
        return error.ResponseBodyTooLarge;
    if (headers.len > max_response_header_count)
        return error.ResponseHeadersTooLarge;

    var header_bytes: usize = 0;
    for (headers) |header| {
        try validateHeader(header.name, header.value);
        header_bytes = std.math.add(usize, header_bytes, header.name.len) catch return error.ResponseHeadersTooLarge;
        header_bytes = std.math.add(usize, header_bytes, header.value.len) catch return error.ResponseHeadersTooLarge;
        if (header_bytes > max_response_header_bytes)
            return error.ResponseHeadersTooLarge;
    }
}

/// Fails with `error.ServerControlledResponseHeader` for a framing header a
/// handler may not set, or with the error of `http.headers.validate` for a
/// name or value that is not valid HTTP.
pub fn validateHeader(name: []const u8, value: []const u8) !void {
    if (serverControlsResponseHeader(name))
        return error.ServerControlledResponseHeader;
    try http_headers.validate(name, value);
}

/// The server frames a worker's response in HTTP/2 DATA frames, so a
/// handler's `content-length` could disagree with the bytes sent, and
/// RFC 9113 §8.2.2 forbids `connection` and `transfer-encoding` in an HTTP/2
/// message.
///
/// FIXME: the other connection-specific names RFC 9113 §8.2.2 forbids
/// (`keep-alive`, `proxy-connection`, `upgrade`) pass here. The server's
/// ingress then refuses the head (`validateResponseHeader` in
/// `server/ingress/http2/response.zig`) and resets the client's stream as a
/// protocol violation of the worker, instead of the worker answering 500.
fn serverControlsResponseHeader(name: []const u8) bool {
    // Content-Encoding stays with the handler: the body is opaque bytes, and
    // only the handler knows whether it already encoded them. A streamed
    // fetch body is the exception, handled where the response is extracted
    // (`shouldDropHostHeader` in `js/server_api/response.zig`).
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

fn copyAbiBody(
    allocator: std.mem.Allocator,
    body: bindings.ExtractedResponseBody,
) ![]u8 {
    const segments = body.segmentsSlice();
    const copied = try allocator.alloc(u8, body.total_len);
    errdefer allocator.free(copied);

    var offset: usize = 0;
    for (segments) |segment| {
        const bytes = segment.slice();
        if (bytes.len > copied.len - offset)
            return error.InvalidResponseBody;
        @memcpy(copied[offset..][0..bytes.len], bytes);
        offset += bytes.len;
    }
    if (offset != copied.len)
        return error.InvalidResponseBody;

    return copied;
}
