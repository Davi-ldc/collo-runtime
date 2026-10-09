//! The payload of a response head: the status, the header count and the
//! name and value pairs. The worker encodes it on its event loop thread and
//! sends it inline, since a head may not use the payload ring, and the host
//! decodes it on the lane that reads the worker, from its own copy of the
//! packet. The bounded decoder refuses a head over the caller's header count
//! or byte bound before it allocates anything.

const std = @import("std");

const messages = @import("../messages.zig");
const packet = @import("../packet.zig");

pub const ResponseHeader = messages.RequestHeader;

/// A decoded response head; it owns `storage`, where the header names and
/// values live, and `headers`.
pub const DecodedResponseHead = struct {
    allocator: std.mem.Allocator,
    storage: []u8 = &.{},
    headers: []ResponseHeader = &.{},
    status: u16 = 0,

    pub fn deinit(self: *DecodedResponseHead) void {
        self.allocator.free(self.headers);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

const ResponseHeadPayloadHeader = extern struct {
    status: u16,
    header_count: u16,
    header_bytes_len: u32,
};

/// Encodes a response head payload, the status and the header pairs, into
/// `scratch` and returns that prefix. Fails with `error.MessageTooLarge` past
/// the format's 16-bit header count or 32-bit byte length, and with
/// `error.DispatchScratchTooSmall` when `scratch` is too short.
pub fn encodeResponseHeadInto(scratch: []u8, status: u16, headers: []const ResponseHeader) ![]u8 {
    if (headers.len > std.math.maxInt(u16))
        return error.MessageTooLarge;
    var header_bytes_len: usize = 0;
    for (headers) |header| {
        header_bytes_len = std.math.add(usize, header_bytes_len, @sizeOf(messages.NameValuePacket)) catch return error.MessageTooLarge;
        header_bytes_len = std.math.add(usize, header_bytes_len, header.name.len) catch return error.MessageTooLarge;
        header_bytes_len = std.math.add(usize, header_bytes_len, header.value.len) catch return error.MessageTooLarge;
    }
    if (header_bytes_len > std.math.maxInt(u32))
        return error.MessageTooLarge;
    const total_len = std.math.add(usize, @sizeOf(ResponseHeadPayloadHeader), header_bytes_len) catch return error.MessageTooLarge;
    if (total_len > scratch.len)
        return error.DispatchScratchTooSmall;
    const header = ResponseHeadPayloadHeader{
        .status = status,
        .header_count = @intCast(headers.len),
        .header_bytes_len = @intCast(header_bytes_len),
    };
    var cursor: usize = 0;
    cursor += packet.writeStruct(scratch[cursor..], &header);
    for (headers) |pair| {
        const pair_header = messages.NameValuePacket{
            .name_len = @intCast(pair.name.len),
            .value_len = @intCast(pair.value.len),
        };
        cursor += packet.writeStruct(scratch[cursor..], &pair_header);
        cursor += packet.writeSlice(scratch[cursor..], pair.name);
        cursor += packet.writeSlice(scratch[cursor..], pair.value);
    }
    return scratch[0..cursor];
}

pub fn decodeResponseHead(allocator: std.mem.Allocator, payload: []const u8) !DecodedResponseHead {
    return decodeResponseHeadBounded(
        allocator,
        payload,
        std.math.maxInt(usize),
        std.math.maxInt(usize),
    );
}

/// Decodes a response head payload into memory from `allocator`, which the
/// result owns. A head over `max_header_count` headers or `max_header_bytes`
/// bytes fails with `error.ResponseHeadersTooLarge` before anything is
/// allocated.
pub fn decodeResponseHeadBounded(
    allocator: std.mem.Allocator,
    payload: []const u8,
    max_header_count: usize,
    max_header_bytes: usize,
) !DecodedResponseHead {
    if (payload.len < @sizeOf(ResponseHeadPayloadHeader))
        return error.ShortRead;
    const header = packet.readStruct(ResponseHeadPayloadHeader, payload[0..@sizeOf(ResponseHeadPayloadHeader)]);
    if (header.header_count > max_header_count or header.header_bytes_len > max_header_bytes)
        return error.ResponseHeadersTooLarge;
    const header_bytes_start = @sizeOf(ResponseHeadPayloadHeader);
    const header_bytes_end = std.math.add(usize, header_bytes_start, header.header_bytes_len) catch return error.InvalidPacket;
    if (header_bytes_end != payload.len)
        return error.InvalidPacket;

    const storage = try allocator.alloc(u8, header.header_bytes_len);
    errdefer allocator.free(storage);
    const headers = try allocator.alloc(ResponseHeader, header.header_count);
    errdefer allocator.free(headers);

    var cursor: usize = header_bytes_start;
    var storage_cursor: usize = 0;
    for (headers) |*out| {
        if (cursor + @sizeOf(messages.NameValuePacket) > payload.len)
            return error.ShortRead;
        const pair = packet.readStruct(messages.NameValuePacket, payload[cursor..][0..@sizeOf(messages.NameValuePacket)]);
        cursor += @sizeOf(messages.NameValuePacket);
        const name = try packet.readSlice(payload, &cursor, pair.name_len);
        const value = try packet.readSlice(payload, &cursor, pair.value_len);
        if (storage_cursor + name.len + value.len > storage.len)
            return error.InvalidPacket;
        const name_start = storage_cursor;
        @memcpy(storage[name_start..][0..name.len], name);
        storage_cursor += name.len;
        const value_start = storage_cursor;
        @memcpy(storage[value_start..][0..value.len], value);
        storage_cursor += value.len;
        out.* = .{
            .name = storage[name_start .. name_start + name.len],
            .value = storage[value_start .. value_start + value.len],
        };
    }
    if (cursor != payload.len)
        return error.InvalidPacket;
    return .{
        .allocator = allocator,
        .storage = storage,
        .headers = headers,
        .status = header.status,
    };
}
