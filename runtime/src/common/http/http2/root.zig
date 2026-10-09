//! HTTP/2 wire primitives that the ingress server and the egress fetch client
//! build on; the worker's response writer also uses its error codes.
//! `wire.zig` holds the frame header, flags, error codes, the
//! connection preface and the encoders that split a header block or a body
//! into frames; `settings.zig` holds the SETTINGS codec and the peer settings
//! a connection tracks; `flow.zig` holds the WINDOW_UPDATE codec. The functions
//! keep no state of their own, and the only allocations are the frame
//! encoders' results, which the caller frees.

pub const wire = @import("wire.zig");
pub const settings = @import("settings.zig");
pub const flow = @import("flow.zig");

pub const client_connection_preface = wire.client_connection_preface;
pub const frame_header_len = wire.frame_header_len;
pub const setting_wire_len = settings.setting_wire_len;
pub const default_max_frame_size = wire.default_max_frame_size;
pub const default_initial_window_size = flow.default_initial_window_size;
pub const default_header_table_size = settings.default_header_table_size;
pub const max_header_table_size = settings.max_header_table_size;
pub const max_frame_payload_len = wire.max_frame_payload_len;
pub const max_window_size = wire.max_window_size;

pub const FrameType = wire.FrameType;
pub const Flags = wire.Flags;
pub const FrameHeader = wire.FrameHeader;
pub const ErrorCode = wire.ErrorCode;

pub const SettingId = settings.SettingId;
pub const Setting = settings.Setting;
pub const Settings = settings.Settings;
pub const SettingsState = settings.SettingsState;
pub const SettingsChange = settings.SettingsChange;

pub const validatePreface = wire.validatePreface;
pub const encodeRstStreamFrame = wire.encodeRstStreamFrame;
pub const encodeGoawayFrame = wire.encodeGoawayFrame;
pub const encodeHeadersFrames = wire.encodeHeadersFrames;
pub const encodeDataFrames = wire.encodeDataFrames;
pub const encodeHeadersAndDataFrames = wire.encodeHeadersAndDataFrames;
pub const encodeSetting = settings.encodeSetting;
pub const encodeWindowUpdateFrame = flow.encodeWindowUpdateFrame;
pub const parseWindowUpdateIncrement = flow.parseWindowUpdateIncrement;
