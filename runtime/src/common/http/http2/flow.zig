//! HTTP/2 flow-control framing: the WINDOW_UPDATE codec and the protocol's
//! initial window. Pure functions, callable from any thread. Neither
//! direction lets a zero increment through, because RFC 9113 §6.9 makes one a
//! protocol error.

const wire = @import("wire.zig");

/// The window every stream and the connection start with. SETTINGS can
/// change the initial window of streams but never the connection's, which
/// only WINDOW_UPDATE raises (RFC 9113 §6.9.2).
pub const default_initial_window_size: u32 = 65_535;

/// Writes a WINDOW_UPDATE for `stream_id`, 0 meaning the connection window,
/// into the first `frame_header_len + 4` bytes of `out`. Fails with
/// `error.ShortHttp2Frame` when `out` is smaller and with
/// `error.Http2ProtocolError` for an increment of zero or above
/// `max_window_size`.
pub fn encodeWindowUpdateFrame(out: []u8, stream_id: u32, increment: u32) !void {
    if (out.len < wire.frame_header_len + 4)
        return error.ShortHttp2Frame;
    if (increment == 0 or increment > wire.max_window_size)
        return error.Http2ProtocolError;
    var header = wire.FrameHeader{
        .length = 4,
        .frame_type_raw = @intFromEnum(wire.FrameType.window_update),
        .frame_type = .window_update,
        .flags = wire.Flags.fromByte(0),
        .stream_id = stream_id,
    };
    try header.encode(out[0..wire.frame_header_len]);
    wire.writeU31(out[wire.frame_header_len..][0..4], increment);
}

/// The increment of a WINDOW_UPDATE payload, reserved bit cleared. A payload
/// other than four bytes is `error.Http2FrameSizeError`. A zero increment is
/// `error.Http2ProtocolError`, which RFC 9113 §6.9 makes a stream error on a
/// stream and a connection error on stream 0, so the caller decides which.
pub fn parseWindowUpdateIncrement(payload: []const u8) !u32 {
    if (payload.len != 4)
        return error.Http2FrameSizeError;
    const increment = wire.readU31(payload);
    if (increment == 0)
        return error.Http2ProtocolError;
    return increment;
}
