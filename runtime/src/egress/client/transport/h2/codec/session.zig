//! Connection-wide HTTP/2 client state: the HPACK encoder and decoder, the
//! local and peer SETTINGS, client stream ids and GOAWAY. `client.Connection`
//! drives it, and nothing here performs I/O.

const std = @import("std");
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const limits = @import("collo_limits");
const request = @import("request.zig");
const response = @import("response.zig");

pub const ClientSettings = struct {
    header_table_size: u32 = h2.default_header_table_size,
    enable_push: bool = false,
    initial_window_size: u32 = h2.default_initial_window_size,
    max_frame_size: u32 = h2.default_max_frame_size,
    /// Advertises the egress response header cap, so a server can learn it
    /// and fail an oversized response early instead of sending a header
    /// block the client will reject.
    max_header_list_size: u32 = @intCast(limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX),
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    encoder: hpack.Encoder,
    decoder: hpack.Decoder,
    peer_settings: h2.SettingsState = .{},
    local_settings: ClientSettings = .{},
    next_stream_id: u32 = 1,
    received_peer_settings: bool = false,
    /// The last stream id of the peer's latest GOAWAY, null until one
    /// arrives. Only a GOAWAY tells the client which streams the peer never
    /// processed: those above this id (RFC 9113 §6.8). Without one, any open
    /// stream may already have run.
    goaway_last_stream_id: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) !Session {
        return .{
            .allocator = allocator,
            .encoder = try hpack.Encoder.init(),
            .decoder = try hpack.Decoder.init(),
        };
    }

    pub fn deinit(self: *Session) void {
        self.encoder.deinit();
        self.decoder.deinit();
        self.* = undefined;
    }

    pub fn openStream(self: *Session) !u32 {
        if (self.goaway_last_stream_id != null)
            return error.Http2ConnectionClosed;
        const stream_id = self.next_stream_id;
        if (stream_id == 0 or stream_id > h2.max_window_size)
            return error.Http2StreamIdExhausted;
        self.next_stream_id = std.math.add(u32, stream_id, 2) catch return error.Http2StreamIdExhausted;
        return stream_id;
    }

    pub fn encodeConnectionPrefaceAndSettings(self: *const Session, allocator: std.mem.Allocator) ![]u8 {
        const settings_count: usize = 4;
        const payload_len = settings_count * h2.setting_wire_len;
        const total_len = h2.client_connection_preface.len + h2.frame_header_len + payload_len;
        const out = try allocator.alloc(u8, total_len);
        errdefer allocator.free(out);
        @memcpy(out[0..h2.client_connection_preface.len], h2.client_connection_preface);
        var header = h2.FrameHeader{
            .length = @intCast(payload_len),
            .frame_type_raw = @intFromEnum(h2.FrameType.settings),
            .frame_type = .settings,
            .flags = h2.Flags.fromByte(0),
            .stream_id = 0,
        };
        try header.encode(out[h2.client_connection_preface.len..][0..h2.frame_header_len]);
        var cursor = h2.client_connection_preface.len + h2.frame_header_len;
        try h2.encodeSetting(out[cursor..][0..h2.setting_wire_len], .header_table_size, self.local_settings.header_table_size);
        cursor += h2.setting_wire_len;
        try h2.encodeSetting(out[cursor..][0..h2.setting_wire_len], .enable_push, if (self.local_settings.enable_push) 1 else 0);
        cursor += h2.setting_wire_len;
        try h2.encodeSetting(out[cursor..][0..h2.setting_wire_len], .initial_window_size, self.local_settings.initial_window_size);
        cursor += h2.setting_wire_len;
        try h2.encodeSetting(out[cursor..][0..h2.setting_wire_len], .max_header_list_size, self.local_settings.max_header_list_size);
        return out;
    }

    pub fn handleSettingsFrame(self: *Session, header: h2.FrameHeader, payload: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        try header.validateControlStream();
        if (header.length != payload.len)
            return error.Http2FrameSizeError;
        // `end_stream` is flag bit 0x1, which SETTINGS uses as ACK.
        if (header.flags.end_stream) {
            if (payload.len != 0)
                return error.Http2FrameSizeError;
            return null;
        }
        const change = try self.peer_settings.applyPayload(payload);
        if (change.headerTableSizeChanged(self.peer_settings))
            try self.encoder.setMaxCapacity(self.peer_settings.header_table_size);
        self.received_peer_settings = true;
        return try encodeSettingsAck(allocator);
    }

    pub fn handleGoawayFrame(self: *Session, header: h2.FrameHeader, payload: []const u8) !void {
        try header.validateControlStream();
        if (header.length != payload.len)
            return error.Http2FrameSizeError;
        if (payload.len < 8)
            return error.Http2FrameSizeError;
        self.goaway_last_stream_id = h2.wire.readU31(payload[0..4]);
    }

    pub fn encodeRequest(self: *Session, stream_id: u32, head: request.RequestHead) !request.EncodedRequest {
        return request.encodeRequest(
            self.allocator,
            &self.encoder,
            stream_id,
            self.peer_settings.max_frame_size,
            head,
        );
    }
};

pub fn encodeSettingsAck(allocator: std.mem.Allocator) ![]u8 {
    const out = try allocator.alloc(u8, h2.frame_header_len);
    errdefer allocator.free(out);
    var header = h2.FrameHeader{
        .length = 0,
        .frame_type_raw = @intFromEnum(h2.FrameType.settings),
        .frame_type = .settings,
        .flags = h2.Flags.fromByte(0x1),
        .stream_id = 0,
    };
    try header.encode(out);
    return out;
}
