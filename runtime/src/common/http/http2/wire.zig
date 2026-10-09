//! HTTP/2 framing: the frame header of RFC 9113 §4.1, the frame types and
//! flags of RFC 9113 §6, the error codes of RFC 9113 §7, the client
//! connection preface of RFC 9113 §3.4, big-endian integer helpers, and the
//! encoders for RST_STREAM and GOAWAY frames and for the frames that carry a
//! header block or a body.
//! A frame header never carries a length above `max_frame_payload_len` or a
//! stream id with the reserved bit set: parsing rejects the first and clears
//! the second, and encoding refuses both.

const std = @import("std");

pub const client_connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const frame_header_len: usize = 9;
/// Initial SETTINGS_MAX_FRAME_SIZE and the smallest value a peer may set.
pub const default_max_frame_size: u32 = 16_384;
/// Largest SETTINGS_MAX_FRAME_SIZE, and the largest length the 24-bit length
/// field of a frame header can carry.
pub const max_frame_payload_len: u32 = 16_777_215;
/// Largest flow-control window and largest stream id. As a mask it clears
/// the reserved high bit of a 31-bit field.
pub const max_window_size: u32 = (1 << 31) - 1;

pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
    unknown = 0xff,

    pub fn decode(raw: u8) FrameType {
        return switch (raw) {
            0x0 => .data,
            0x1 => .headers,
            0x2 => .priority,
            0x3 => .rst_stream,
            0x4 => .settings,
            0x5 => .push_promise,
            0x6 => .ping,
            0x7 => .goaway,
            0x8 => .window_update,
            0x9 => .continuation,
            else => .unknown,
        };
    }
};

pub const Flags = packed struct(u8) {
    /// END_STREAM (0x1) on DATA and HEADERS. On SETTINGS and PING the same bit
    /// is ACK.
    end_stream: bool = false,
    reserved_0x02: bool = false,
    /// END_HEADERS (0x4) on HEADERS, PUSH_PROMISE and CONTINUATION. Despite
    /// the name, it is not the ACK flag of SETTINGS or PING, which is
    /// `end_stream`'s bit.
    end_headers_or_ack: bool = false,
    padded: bool = false,
    reserved_0x10: bool = false,
    priority: bool = false,
    reserved_0x40: bool = false,
    reserved_0x80: bool = false,

    pub fn fromByte(raw: u8) Flags {
        return @bitCast(raw);
    }

    pub fn toByte(self: Flags) u8 {
        return @bitCast(self);
    }
};

pub const FrameHeader = struct {
    length: u32,
    /// The type byte `encode` writes. It keeps an unknown type's value, which
    /// `frame_type` collapses to `.unknown`, so a header built by hand must
    /// set both to the same type.
    frame_type_raw: u8,
    frame_type: FrameType,
    flags: Flags,
    stream_id: u32,

    pub fn parse(bytes: []const u8) !FrameHeader {
        if (bytes.len < frame_header_len)
            return error.ShortHttp2FrameHeader;
        const length = readU24(bytes[0..3]);
        if (length > max_frame_payload_len)
            return error.Http2FrameTooLarge;
        const frame_type_raw = bytes[3];
        return .{
            .length = length,
            .frame_type_raw = frame_type_raw,
            .frame_type = FrameType.decode(frame_type_raw),
            .flags = Flags.fromByte(bytes[4]),
            .stream_id = readU31(bytes[5..9]),
        };
    }

    pub fn encode(self: FrameHeader, out: []u8) !void {
        if (out.len < frame_header_len)
            return error.ShortHttp2FrameHeader;
        if (self.length > max_frame_payload_len)
            return error.Http2FrameTooLarge;
        if (self.stream_id > max_window_size)
            return error.InvalidHttp2StreamId;
        writeU24(out[0..3], self.length);
        out[3] = self.frame_type_raw;
        out[4] = self.flags.toByte();
        writeU31(out[5..9], self.stream_id);
    }

    /// Fails unless the frame is on stream 0, where connection-level frames
    /// must travel.
    pub fn validateControlStream(self: FrameHeader) !void {
        if (self.stream_id != 0)
            return error.Http2ProtocolError;
    }

    /// Fails when the frame is on stream 0, which stream-level frames may not
    /// use.
    pub fn validateStream(self: FrameHeader) !void {
        if (self.stream_id == 0)
            return error.Http2ProtocolError;
    }
};

pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
};

pub fn encodeRstStreamFrame(out: []u8, stream_id: u32, error_code: ErrorCode) !void {
    if (out.len < frame_header_len + 4)
        return error.ShortHttp2Frame;
    try encodeFrameHeader(out[0..frame_header_len], 4, .rst_stream, 0, stream_id);
    writeU32(out[frame_header_len..][0..4], @intFromEnum(error_code));
}

/// Writes a GOAWAY with no debug data into the first `frame_header_len + 8`
/// bytes of `out`; the reserved bit of `last_stream_id` is cleared.
pub fn encodeGoawayFrame(out: []u8, last_stream_id: u32, error_code: ErrorCode) !void {
    if (out.len < frame_header_len + 8)
        return error.ShortHttp2Frame;
    try encodeFrameHeader(out[0..frame_header_len], 8, .goaway, 0, 0);
    writeU32(out[frame_header_len..][0..4], last_stream_id & max_window_size);
    writeU32(out[frame_header_len + 4 ..][0..4], @intFromEnum(error_code));
}

/// Splits `block` into a HEADERS frame and as many CONTINUATION frames as
/// `max_frame_size` requires, the peer's SETTINGS_MAX_FRAME_SIZE. END_HEADERS
/// goes on the last frame and END_STREAM, when asked, on the HEADERS frame;
/// an empty block still yields one HEADERS frame. The result is one
/// allocation the caller frees with `allocator`.
pub fn encodeHeadersFrames(
    allocator: std.mem.Allocator,
    max_frame_size: u32,
    stream_id: u32,
    block: []const u8,
    end_stream: bool,
) ![]u8 {
    const budget: usize = @intCast(max_frame_size);
    if (budget == 0)
        return error.Http2FrameTooLarge;
    const frame_count = frameCount(block.len, budget);
    const total_len = std.math.add(usize, block.len, frame_count * frame_header_len) catch return error.MessageTooLarge;
    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);
    try encodeHeadersFramesInto(out, max_frame_size, stream_id, block, end_stream);
    return out;
}

/// Splits `payload` into DATA frames of at most `max_frame_size` bytes, with
/// END_STREAM on the last one when asked; an empty payload yields one empty
/// DATA frame. Flow control is the caller's job; this frames all it is given.
/// The result is one allocation the caller frees with `allocator`.
pub fn encodeDataFrames(
    allocator: std.mem.Allocator,
    max_frame_size: u32,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
) ![]u8 {
    const budget: usize = @intCast(max_frame_size);
    if (budget == 0)
        return error.Http2FrameTooLarge;
    const frame_count = frameCount(payload.len, budget);
    const total_len = std.math.add(usize, payload.len, frame_count * frame_header_len) catch return error.MessageTooLarge;
    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);
    try encodeDataFramesInto(out, max_frame_size, stream_id, payload, end_stream);
    return out;
}

/// `encodeHeadersFrames` followed by `encodeDataFrames` in one allocation.
/// An empty `payload` adds no DATA frame and ignores `data_end_stream`, so a
/// caller ending the stream without a body sets `headers_end_stream`.
pub fn encodeHeadersAndDataFrames(
    allocator: std.mem.Allocator,
    max_frame_size: u32,
    stream_id: u32,
    header_block: []const u8,
    headers_end_stream: bool,
    payload: []const u8,
    data_end_stream: bool,
) ![]u8 {
    const budget: usize = @intCast(max_frame_size);
    if (budget == 0)
        return error.Http2FrameTooLarge;
    const header_frame_count = frameCount(header_block.len, budget);
    const header_wire_len = std.math.add(usize, header_block.len, header_frame_count * frame_header_len) catch return error.MessageTooLarge;
    const data_frame_count = if (payload.len == 0) 0 else frameCount(payload.len, budget);
    const data_wire_len = std.math.add(usize, payload.len, data_frame_count * frame_header_len) catch return error.MessageTooLarge;
    const total_len = std.math.add(usize, header_wire_len, data_wire_len) catch return error.MessageTooLarge;
    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    var cursor: usize = 0;
    try encodeHeadersFramesInto(out[cursor..][0..header_wire_len], max_frame_size, stream_id, header_block, headers_end_stream);
    cursor += header_wire_len;
    if (payload.len != 0) {
        try encodeDataFramesInto(out[cursor..][0..data_wire_len], max_frame_size, stream_id, payload, data_end_stream);
        cursor += data_wire_len;
    }
    std.debug.assert(cursor == out.len);
    return out;
}

pub fn validatePreface(bytes: []const u8) !void {
    if (bytes.len < client_connection_preface.len)
        return error.ShortHttp2Preface;
    if (!std.mem.eql(u8, bytes[0..client_connection_preface.len], client_connection_preface))
        return error.InvalidHttp2Preface;
}

pub fn readU16(bytes: []const u8) u16 {
    std.debug.assert(bytes.len == 2);
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

pub fn writeU16(out: []u8, value: u16) void {
    std.debug.assert(out.len == 2);
    out[0] = @intCast((value >> 8) & 0xff);
    out[1] = @intCast(value & 0xff);
}

pub fn readU24(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 3);
    return (@as(u32, bytes[0]) << 16) | (@as(u32, bytes[1]) << 8) | bytes[2];
}

pub fn writeU24(out: []u8, value: u32) void {
    std.debug.assert(out.len == 3);
    out[0] = @intCast((value >> 16) & 0xff);
    out[1] = @intCast((value >> 8) & 0xff);
    out[2] = @intCast(value & 0xff);
}

pub fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}

pub fn writeU32(out: []u8, value: u32) void {
    std.debug.assert(out.len == 4);
    out[0] = @intCast((value >> 24) & 0xff);
    out[1] = @intCast((value >> 16) & 0xff);
    out[2] = @intCast((value >> 8) & 0xff);
    out[3] = @intCast(value & 0xff);
}

/// Reads a 31-bit field, dropping the reserved high bit.
pub fn readU31(bytes: []const u8) u32 {
    return readU32(bytes) & max_window_size;
}

/// Writes a 31-bit field with the reserved high bit clear.
pub fn writeU31(out: []u8, value: u32) void {
    std.debug.assert(out.len == 4);
    const masked = value & max_window_size;
    out[0] = @intCast((masked >> 24) & 0xff);
    out[1] = @intCast((masked >> 16) & 0xff);
    out[2] = @intCast((masked >> 8) & 0xff);
    out[3] = @intCast(masked & 0xff);
}

fn encodeHeadersFramesInto(out: []u8, max_frame_size: u32, stream_id: u32, block: []const u8, end_stream: bool) !void {
    const budget: usize = @intCast(max_frame_size);
    if (budget == 0)
        return error.Http2FrameTooLarge;
    const frame_count = frameCount(block.len, budget);
    const expected_len = std.math.add(usize, block.len, frame_count * frame_header_len) catch return error.MessageTooLarge;
    if (out.len != expected_len)
        return error.ShortHttp2Frame;
    var cursor: usize = 0;
    var offset: usize = 0;
    var frame_index: usize = 0;
    while (frame_index < frame_count) : (frame_index += 1) {
        const remaining = block.len - offset;
        const chunk_len = if (frame_index + 1 == frame_count) remaining else @min(remaining, budget);
        const is_last = frame_index + 1 == frame_count;
        var flag_bits: u8 = 0;
        if (frame_index == 0 and end_stream)
            flag_bits |= 0x1;
        if (is_last)
            flag_bits |= 0x4;
        const frame_type: FrameType = if (frame_index == 0) .headers else .continuation;
        try encodeFrameHeader(out[cursor..][0..frame_header_len], chunk_len, frame_type, flag_bits, stream_id);
        cursor += frame_header_len;
        if (chunk_len != 0) {
            @memcpy(out[cursor..][0..chunk_len], block[offset..][0..chunk_len]);
            cursor += chunk_len;
            offset += chunk_len;
        }
    }
    std.debug.assert(cursor == out.len);
}

fn encodeDataFramesInto(out: []u8, max_frame_size: u32, stream_id: u32, payload: []const u8, end_stream: bool) !void {
    const budget: usize = @intCast(max_frame_size);
    if (budget == 0)
        return error.Http2FrameTooLarge;
    const frame_count = frameCount(payload.len, budget);
    const expected_len = std.math.add(usize, payload.len, frame_count * frame_header_len) catch return error.MessageTooLarge;
    if (out.len != expected_len)
        return error.ShortHttp2Frame;

    var cursor: usize = 0;
    var offset: usize = 0;
    var frame_index: usize = 0;
    while (frame_index < frame_count) : (frame_index += 1) {
        const remaining = payload.len - offset;
        const chunk_len = if (frame_index + 1 == frame_count) remaining else @min(remaining, budget);
        const is_last = frame_index + 1 == frame_count;
        const flag_bits: u8 = if (is_last and end_stream) 0x1 else 0;
        try encodeFrameHeader(out[cursor..][0..frame_header_len], chunk_len, .data, flag_bits, stream_id);
        cursor += frame_header_len;
        if (chunk_len != 0) {
            @memcpy(out[cursor..][0..chunk_len], payload[offset..][0..chunk_len]);
            cursor += chunk_len;
            offset += chunk_len;
        }
    }
    std.debug.assert(cursor == out.len);
}

fn frameCount(payload_len: usize, budget: usize) usize {
    if (payload_len == 0)
        return 1;
    return (payload_len + budget - 1) / budget;
}

fn encodeFrameHeader(out: []u8, payload_len: usize, frame_type: FrameType, flags: u8, stream_id: u32) !void {
    if (payload_len > max_frame_payload_len)
        return error.Http2FrameTooLarge;
    var header = FrameHeader{
        .length = @intCast(payload_len),
        .frame_type_raw = @intFromEnum(frame_type),
        .frame_type = frame_type,
        .flags = Flags.fromByte(flags),
        .stream_id = stream_id,
    };
    try header.encode(out);
}
