//! The HTTP/2 SETTINGS codec and the peer settings a connection tracks.
//! `Settings.parseInto` and `SettingsState.applyPayload` check every value
//! against the bounds of RFC 9113 §6.5.2 before it is used; unknown
//! identifiers are ignored, as the RFC requires.

const wire = @import("wire.zig");

pub const setting_wire_len: usize = 6;
pub const default_header_table_size: u32 = 4096;
/// Cap on the HPACK encoder's dynamic table, per connection. A larger
/// SETTINGS_HEADER_TABLE_SIZE from the peer is clamped to it, so a peer cannot
/// make a connection spend more memory on its table. RFC 7541 §4.2 lets an
/// encoder use less than the decoder allows.
pub const max_header_table_size: u32 = default_header_table_size;

pub const SettingId = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
    unknown = 0xffff,

    pub fn decode(raw: u16) SettingId {
        return switch (raw) {
            0x1 => .header_table_size,
            0x2 => .enable_push,
            0x3 => .max_concurrent_streams,
            0x4 => .initial_window_size,
            0x5 => .max_frame_size,
            0x6 => .max_header_list_size,
            else => .unknown,
        };
    }
};

pub const Setting = struct {
    id_raw: u16,
    id: SettingId,
    value: u32,

    pub fn parse(bytes: []const u8) !Setting {
        if (bytes.len < setting_wire_len)
            return error.ShortHttp2Setting;
        const id_raw = wire.readU16(bytes[0..2]);
        const value = wire.readU32(bytes[2..6]);
        return .{
            .id_raw = id_raw,
            .id = SettingId.decode(id_raw),
            .value = value,
        };
    }

    /// Checks the value against the bound RFC 9113 §6.5.2 sets for its
    /// identifier. Both errors it returns are connection errors.
    pub fn validate(self: Setting) !void {
        switch (self.id) {
            .enable_push => if (self.value > 1)
                return error.Http2ProtocolError,
            .initial_window_size => if (self.value > wire.max_window_size)
                return error.Http2FlowControlError,
            .max_frame_size => if (self.value < wire.default_max_frame_size or self.value > wire.max_frame_payload_len)
                return error.Http2ProtocolError,
            else => {},
        }
    }
};

pub const Settings = struct {
    /// Entries one SETTINGS frame may carry before it fails with
    /// `error.TooManyHttp2Settings`. RFC 9113 sets no such bound. It defines
    /// six identifiers, and extensions such as RFC 8441 and RFC 9218 and
    /// GREASE values add only a few more, so this leaves ample room for a
    /// legitimate peer.
    pub const max_settings_per_frame: usize = 32;

    values: []const Setting,

    pub fn parseInto(out: []Setting, payload: []const u8) !Settings {
        if (payload.len % setting_wire_len != 0)
            return error.Http2FrameSizeError;
        const count = payload.len / setting_wire_len;
        if (count > out.len)
            return error.TooManyHttp2Settings;
        if (count > max_settings_per_frame)
            return error.TooManyHttp2Settings;
        for (0..count) |index| {
            out[index] = try Setting.parse(payload[index * setting_wire_len ..][0..setting_wire_len]);
            try out[index].validate();
        }
        return .{ .values = out[0..count] };
    }
};

/// The peer's settings, starting at the protocol's initial values, with
/// `header_table_size` clamped to `max_header_table_size`. Null means no
/// limit, which is the initial value of both optional fields.
pub const SettingsState = struct {
    header_table_size: u32 = default_header_table_size,
    enable_push: bool = true,
    max_concurrent_streams: ?u32 = null,
    initial_window_size: u32 = @import("flow.zig").default_initial_window_size,
    max_frame_size: u32 = wire.default_max_frame_size,
    max_header_list_size: ?u32 = null,

    /// Applies `settings` without checking them, so they must come from
    /// `Settings.parseInto`.
    pub fn apply(self: *SettingsState, settings: []const Setting) void {
        for (settings) |setting|
            self.applyOne(setting);
    }

    /// Parses, checks and applies one SETTINGS payload, returning the values
    /// the caller must compare to react to a change. Entries before a failing
    /// one stay applied; every error here is a connection error, so the
    /// caller closes the connection rather than keep using the state.
    pub fn applyPayload(self: *SettingsState, payload: []const u8) !SettingsChange {
        if (payload.len % setting_wire_len != 0)
            return error.Http2FrameSizeError;
        if (payload.len / setting_wire_len > Settings.max_settings_per_frame)
            return error.TooManyHttp2Settings;
        const change = SettingsChange{
            .old_header_table_size = self.header_table_size,
            .old_initial_window_size = self.initial_window_size,
        };
        var offset: usize = 0;
        while (offset < payload.len) : (offset += setting_wire_len) {
            const setting = try Setting.parse(payload[offset..][0..setting_wire_len]);
            try setting.validate();
            self.applyOne(setting);
        }
        return change;
    }

    fn applyOne(self: *SettingsState, setting: Setting) void {
        switch (setting.id) {
            .header_table_size => self.header_table_size = @min(setting.value, max_header_table_size),
            .enable_push => self.enable_push = setting.value != 0,
            .max_concurrent_streams => self.max_concurrent_streams = setting.value,
            .initial_window_size => self.initial_window_size = setting.value,
            .max_frame_size => self.max_frame_size = setting.value,
            .max_header_list_size => self.max_header_list_size = setting.value,
            .unknown => {},
        }
    }
};

pub const SettingsChange = struct {
    old_header_table_size: u32,
    old_initial_window_size: u32,

    pub fn headerTableSizeChanged(self: SettingsChange, state: SettingsState) bool {
        return self.old_header_table_size != state.header_table_size;
    }

    pub fn initialWindowSizeChanged(self: SettingsChange, state: SettingsState) bool {
        return self.old_initial_window_size != state.initial_window_size;
    }
};

/// Writes one entry into the first `setting_wire_len` bytes of `out`.
/// `.unknown` has no wire identifier and fails with `error.Http2ProtocolError`.
pub fn encodeSetting(out: []u8, id: SettingId, value: u32) !void {
    if (out.len < setting_wire_len)
        return error.ShortHttp2Setting;
    if (id == .unknown)
        return error.Http2ProtocolError;
    wire.writeU16(out[0..2], @intFromEnum(id));
    wire.writeU32(out[2..6], value);
}
