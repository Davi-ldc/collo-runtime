//! HPACK encoding of response heads toward the client, with the header
//! checks every head passes first, on the lane thread that owns the
//! connection and its encoder.
//!
//! Invariants:
//! - Every header is validated before any is encoded. The encoder's dynamic
//!   table is shared by the whole connection, so a head rejected here leaves
//!   it as the client's decoder expects.
//! - A name must be a lowercase token and not a connection-specific field
//!   (RFC 9113 §8.2.2). A colon is not a token byte, so a worker's headers can
//!   never add a pseudo-header, and `:status` comes only from the status the
//!   caller passes.

const std = @import("std");

const http = @import("collo_http");
const hpack = @import("collo_hpack");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

/// Encodes `:status` followed by `headers` into a block that borrows
/// `scratch`, the lane's encode scratch, and stays valid only until its next
/// encode. Fails with `error.InvalidHttp2ResponseHeader` before encoding
/// anything when a header is invalid, and with `error.HpackEncoderPoisoned`
/// once an encode has failed midway and the connection's HPACK state is lost.
pub fn encodeResponseHeadersScratch(
    allocator: std.mem.Allocator,
    encoder: *hpack.Encoder,
    scratch: []u8,
    status_value: []const u8,
    headers: []const ipc.ingress_channel.ResponseHeader,
) ![]const u8 {
    const header_count = try std.math.add(usize, headers.len, 1);
    var hpack_headers = try allocator.alloc(hpack.Header, header_count);
    defer allocator.free(hpack_headers);

    hpack_headers[0] = .{ .name = ":status", .value = status_value };
    for (headers, 0..) |header, index| {
        try validateResponseHeader(header);
        hpack_headers[index + 1] = .{ .name = header.name, .value = header.value };
    }
    return encoder.encodeHeadersWithScratch(scratch, hpack_headers, limits.headers.INGRESS_H2_RESPONSE_HEADER_BLOCK_BYTES);
}

fn validateResponseHeader(header: ipc.ingress_channel.ResponseHeader) !void {
    if (!http.headers.isLowercaseTokenName(header.name))
        return error.InvalidHttp2ResponseHeader;
    if (http.headers.isConnectionSpecificName(header.name))
        return error.InvalidHttp2ResponseHeader;
    http.headers.validateValue(header.value) catch return error.InvalidHttp2ResponseHeader;
}
