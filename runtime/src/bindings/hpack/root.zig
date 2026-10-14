//! HPACK encoder and decoder over the patched ls-hpack shim (`shim.c`).
//!
//! A `Decoder` or `Encoder` holds its ls-hpack handle and its table capacity
//! state, nothing else. Every decode, skip and encode takes the caller's
//! scratch: the server keeps one per ingress lane and the egress client one
//! per engine shard, since one thread codes one block at a time for every
//! connection it serves. A decode or a skip leaves nothing in the scratch
//! that the caller needs, while the block `Encoder.encodeHeaders` returns
//! lives in the scratch until the caller's next use of it.
//!
//! An encoder's output for a list of fields never exceeds the sum of
//! `encodedFieldBytesMax` over them plus `table_size_updates_bytes_max`,
//! whatever its dynamic table holds. A caller that must refuse a list
//! before any connection's encoder sees it checks that bound.

const std = @import("std");

const RawDecoder = opaque {};
const RawEncoder = opaque {};

/// Hard memory cap for HPACK dynamic tables. Peers may advertise a larger
/// SETTINGS_HEADER_TABLE_SIZE, but using less table capacity is always valid.
pub const max_dynamic_table_capacity: u32 = 4096;

/// The longest name or value one decoded field may have, and so the length
/// of every decode scratch (`Decoder.decodeBlock`, `Decoder.skipBlock`).
pub const max_single_header_decode_bytes: usize = 64 * 1024 - 1;

/// One field, as HTTP/1 and HTTP/2 code across the runtime spell it.
pub const Header = @import("collo_http").Header;

/// The most bytes an encoder writes for `header`: a literal whose name is a
/// literal too, neither string Huffman-coded. The shim keeps a Huffman
/// string only when it is no longer than the raw one, and an indexed form is
/// never longer than the literal it replaces. Saturates rather than
/// overflowing.
pub fn encodedFieldBytesMax(header: Header) usize {
    return 1 +| encodedStringBytesMax(header.name.len) +| encodedStringBytesMax(header.value.len);
}

/// The most bytes the dynamic table size updates an encoder owes its peer
/// add before a block's first field (RFC 7541 §4.2): the lowest capacity
/// since the last block, then the current one, each at most
/// `max_dynamic_table_capacity`.
pub const table_size_updates_bytes_max: usize = 2 * hpackIntegerEncodedLen(5, max_dynamic_table_capacity);

const RawDecodedHeader = extern struct {
    name_offset: u32,
    name_len: u32,
    value_offset: u32,
    value_len: u32,
};

const DecodedHeaderOffset = struct {
    name_start: usize,
    name_len: usize,
    value_start: usize,
    value_len: usize,
};

/// A decoded block: `headers` slice into `storage`, both allocated with the
/// allocator `Decoder.decodeBlock` took, and freed together by `deinit`.
pub const DecodedBlock = struct {
    storage: []u8 = &.{},
    headers: []Header = &.{},

    pub fn deinit(self: *DecodedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
        allocator.free(self.storage);
        self.* = .{};
    }
};

pub const Decoder = struct {
    handle: ?*RawDecoder = null,

    pub fn init() !Decoder {
        var self = Decoder{};
        try self.ensureInitialized();
        return self;
    }

    pub fn deinit(self: *Decoder) void {
        if (self.handle) |handle| {
            collo_hpack_decoder_free(handle);
            self.handle = null;
        }
    }

    fn ensureInitialized(self: *Decoder) !void {
        if (self.handle != null)
            return;
        var raw: ?*RawDecoder = null;
        try statusToError(collo_hpack_decoder_new(&raw));
        self.handle = raw orelse return error.HpackInvalidArgument;
        collo_hpack_decoder_set_max_capacity(self.handle.?, clampDynamicTableCapacity(default_dynamic_table_capacity));
    }

    pub fn setMaxCapacity(self: *Decoder, capacity: u32) !void {
        try self.ensureInitialized();
        collo_hpack_decoder_set_max_capacity(self.handle.?, clampDynamicTableCapacity(capacity));
    }

    /// Decodes `block` into one allocation of `allocator` for the field bytes
    /// and one for the field list; the caller owns both through the result.
    /// `scratch` holds the field being decoded and must be
    /// `max_single_header_decode_bytes` long.
    ///
    /// A list over `max_header_count` fields or `max_header_bytes` bytes is
    /// decoded to its end, so the dynamic table stays in step, and then
    /// fails with `HpackHeaderListTooLarge`. Every other error
    /// (`HpackBadData`, `HpackOutputTooSmall`, the shim's) leaves the table
    /// out of step, so the caller fails the connection on it.
    pub fn decodeBlock(
        self: *Decoder,
        allocator: std.mem.Allocator,
        scratch: []u8,
        block: []const u8,
        max_header_count: usize,
        max_header_bytes: usize,
    ) !DecodedBlock {
        std.debug.assert(scratch.len >= max_single_header_decode_bytes);
        try self.ensureInitialized();
        if (block.len == 0)
            return .{};

        var storage = try std.array_list.Aligned(u8, null).initCapacity(
            allocator,
            initialDecodedStorageCapacity(block.len, max_header_bytes),
        );
        errdefer storage.deinit(allocator);

        var header_offsets = std.array_list.Aligned(DecodedHeaderOffset, null).empty;
        errdefer header_offsets.deinit(allocator);

        var header_list_too_large = false;
        var offset: usize = 0;
        while (true) {
            if (offset != 0 and offset < block.len and isDynamicTableSizeUpdate(block[offset]))
                return error.HpackBadData;

            var raw = RawDecodedHeader{
                .name_offset = 0,
                .name_len = 0,
                .value_offset = 0,
                .value_len = 0,
            };
            const status = collo_hpack_decode_one(
                self.handle.?,
                block.ptr,
                block.len,
                &offset,
                @ptrCast(scratch.ptr),
                scratch.len,
                &raw,
            );
            switch (status) {
                collo_hpack_ok => {},
                collo_hpack_done => break,
                // A single header overflowing the scratch buffer aborts the
                // block mid-entry: unlike the graceful list-size cap below,
                // the dynamic table may be out of sync, so callers must treat
                // this as connection-fatal.
                collo_hpack_output_too_small => return error.HpackOutputTooSmall,
                else => {
                    try statusToError(status);
                    unreachable;
                },
            }

            const name = try decodedSlice(scratch, raw.name_offset, raw.name_len);
            const value = try decodedSlice(scratch, raw.value_offset, raw.value_len);
            const needed = std.math.add(usize, name.len, value.len) catch
                return error.HpackHeaderListTooLarge;
            if (header_offsets.items.len == max_header_count or
                storage.items.len > max_header_bytes or
                needed > max_header_bytes - storage.items.len)
            {
                header_list_too_large = true;
                continue;
            }

            const name_start = storage.items.len;
            try storage.appendSlice(allocator, name);
            const value_start = storage.items.len;
            try storage.appendSlice(allocator, value);

            try header_offsets.append(allocator, .{
                .name_start = name_start,
                .name_len = name.len,
                .value_start = value_start,
                .value_len = value.len,
            });
        }

        if (header_list_too_large)
            return error.HpackHeaderListTooLarge;

        const owned_storage = try storage.toOwnedSlice(allocator);
        errdefer allocator.free(owned_storage);
        const owned_offsets = try header_offsets.toOwnedSlice(allocator);
        defer allocator.free(owned_offsets);

        const owned_headers = try allocator.alloc(Header, owned_offsets.len);
        errdefer allocator.free(owned_headers);
        for (owned_offsets, 0..) |header_offset, index| {
            owned_headers[index] = .{
                .name = owned_storage[header_offset.name_start..][0..header_offset.name_len],
                .value = owned_storage[header_offset.value_start..][0..header_offset.value_len],
            };
        }

        return .{
            .storage = owned_storage,
            .headers = owned_headers,
        };
    }

    /// Decodes `block` only to keep the dynamic table in step with the
    /// peer's encoder and keeps no field, for a block whose stream takes no
    /// more headers. No count or size cap applies, so a block `decodeBlock`
    /// would refuse with `HpackHeaderListTooLarge` passes. `scratch` is as
    /// `decodeBlock` takes it. Every error it returns leaves the table out of
    /// step, so the caller fails the connection on it.
    pub fn skipBlock(self: *Decoder, scratch: []u8, block: []const u8) !void {
        std.debug.assert(scratch.len >= max_single_header_decode_bytes);
        try self.ensureInitialized();
        if (block.len == 0)
            return;
        var offset: usize = 0;
        while (true) {
            if (offset != 0 and offset < block.len and isDynamicTableSizeUpdate(block[offset]))
                return error.HpackBadData;
            var raw = RawDecodedHeader{
                .name_offset = 0,
                .name_len = 0,
                .value_offset = 0,
                .value_len = 0,
            };
            const status = collo_hpack_decode_one(
                self.handle.?,
                block.ptr,
                block.len,
                &offset,
                @ptrCast(scratch.ptr),
                scratch.len,
                &raw,
            );
            switch (status) {
                collo_hpack_ok => {},
                collo_hpack_done => return,
                collo_hpack_output_too_small => return error.HpackOutputTooSmall,
                else => {
                    try statusToError(status);
                    unreachable;
                },
            }
        }
    }
};

pub const Encoder = struct {
    handle: ?*RawEncoder = null,
    max_capacity: u32 = default_dynamic_table_capacity,
    pending_capacity_update: ?u32 = null,
    /// RFC 7541 §4.2: when the capacity is lowered and raised again between
    /// header blocks, the next block must first signal the lowest
    /// intermediate capacity so the peer evicts the same entries. Set and
    /// cleared together with pending_capacity_update.
    pending_capacity_min: ?u32 = null,
    poisoned: ?anyerror = null,

    pub fn init() !Encoder {
        var self = Encoder{};
        try self.ensureInitialized();
        return self;
    }

    pub fn deinit(self: *Encoder) void {
        if (self.handle) |handle| {
            collo_hpack_encoder_free(handle);
            self.handle = null;
        }
        self.max_capacity = default_dynamic_table_capacity;
        self.pending_capacity_update = null;
        self.pending_capacity_min = null;
        self.poisoned = null;
    }

    fn ensureInitialized(self: *Encoder) !void {
        if (self.poisoned != null)
            return error.HpackEncoderPoisoned;
        if (self.handle != null)
            return;
        var raw: ?*RawEncoder = null;
        try statusToError(collo_hpack_encoder_new(&raw));
        self.handle = raw orelse return error.HpackInvalidArgument;
        collo_hpack_encoder_set_max_capacity(
            self.handle.?,
            clampDynamicTableCapacity(self.max_capacity),
        );
    }

    pub fn setMaxCapacity(self: *Encoder, capacity: u32) !void {
        if (self.poisoned != null)
            return error.HpackEncoderPoisoned;
        try self.ensureInitialized();
        const clamped = clampDynamicTableCapacity(capacity);
        if (clamped != self.max_capacity) {
            self.pending_capacity_update = clamped;
            const pending_min = self.pending_capacity_min orelse clamped;
            self.pending_capacity_min = @min(pending_min, clamped);
        }
        self.max_capacity = clamped;
        collo_hpack_encoder_set_max_capacity(self.handle.?, clamped);
    }

    /// Encodes `headers` into the caller's `scratch` and returns the block,
    /// which borrows `scratch` until the caller's next use of it. The block
    /// is at most `max_block_bytes` long. Fails with
    /// `error.HpackOutputTooSmall` when the worst case for `headers`, capped
    /// at `max_block_bytes`, does not fit `scratch`, and with
    /// `error.HpackEncoderPoisoned` from the first failed encode on, because
    /// a field the shim refused may have changed the dynamic table. A list
    /// whose worst case is over `max_block_bytes` is still tried, since
    /// compression may make it fit, and poisons the encoder when it does
    /// not; a caller that must not lose the connection over one list refuses
    /// it first by the bound in the file header.
    pub fn encodeHeaders(
        self: *Encoder,
        scratch: []u8,
        headers: []const Header,
        max_block_bytes: usize,
    ) ![]const u8 {
        const storage_len = try self.encodedStorageLen(headers, max_block_bytes);
        if (storage_len > scratch.len)
            return error.HpackOutputTooSmall;
        const len = try self.encodeHeadersInto(scratch[0..storage_len], headers);
        return scratch[0..len];
    }

    fn encodedStorageLen(
        self: *const Encoder,
        headers: []const Header,
        max_block_bytes: usize,
    ) !usize {
        if (self.poisoned != null)
            return error.HpackEncoderPoisoned;
        const storage_len = try encodedHeadersStorageLen(
            headers,
            max_block_bytes,
            self.pending_capacity_update,
            self.pending_capacity_min,
        );
        if (storage_len == 0 and (headers.len != 0 or self.pending_capacity_update != null))
            return error.HpackOutputTooSmall;
        return storage_len;
    }

    fn encodeHeadersInto(
        self: *Encoder,
        storage: []u8,
        headers: []const Header,
    ) !usize {
        try self.ensureInitialized();

        var offset: usize = 0;
        if (self.pending_capacity_update) |capacity| {
            const minimum = self.pending_capacity_min orelse capacity;
            std.debug.assert(minimum <= capacity);
            if (minimum != capacity)
                offset = try encodeDynamicTableSizeUpdate(storage, minimum);
            offset += try encodeDynamicTableSizeUpdate(storage[offset..], capacity);
        }
        for (headers) |header| {
            statusToError(collo_hpack_encode_header(
                self.handle.?,
                storage.ptr,
                storage.len,
                &offset,
                @ptrCast(header.name.ptr),
                header.name.len,
                @ptrCast(header.value.ptr),
                header.value.len,
            )) catch |err| {
                self.poison(err);
                return error.HpackEncoderPoisoned;
            };
        }
        self.pending_capacity_update = null;
        self.pending_capacity_min = null;

        return offset;
    }

    fn poison(self: *Encoder, err: anyerror) void {
        self.poisoned = err;
        if (self.handle) |handle| {
            collo_hpack_encoder_free(handle);
            self.handle = null;
        }
    }
};

const default_dynamic_table_capacity: u32 = max_dynamic_table_capacity;

fn encodedHeadersStorageLen(
    headers: []const Header,
    max_block_bytes: usize,
    pending_capacity_update: ?u32,
    pending_capacity_min: ?u32,
) !usize {
    var len: usize = 0;
    if (pending_capacity_update) |capacity| {
        len = hpackIntegerEncodedLen(5, capacity);
        const minimum = pending_capacity_min orelse capacity;
        std.debug.assert(minimum <= capacity);
        if (minimum != capacity)
            len += hpackIntegerEncodedLen(5, minimum);
    }
    std.debug.assert(len <= table_size_updates_bytes_max);

    for (headers) |header| {
        if (header.name.len > max_single_header_decode_bytes)
            return error.HpackHeaderListTooLarge;
        if (header.value.len > max_single_header_decode_bytes)
            return error.HpackHeaderListTooLarge;
        len +|= encodedFieldBytesMax(header);
    }
    return @min(len, max_block_bytes);
}

fn encodedStringBytesMax(len: usize) usize {
    return hpackIntegerEncodedLen(7, len) +| len;
}

fn hpackIntegerEncodedLen(prefix_bits: u5, value: usize) usize {
    const prefix_max = (@as(usize, 1) << prefix_bits) - 1;
    if (value < prefix_max)
        return 1;

    var len: usize = 1;
    var remaining = value - prefix_max;
    while (remaining >= 128) {
        remaining >>= 7;
        len += 1;
    }
    return len + 1;
}

fn clampDynamicTableCapacity(capacity: u32) u32 {
    return @min(capacity, max_dynamic_table_capacity);
}

const collo_hpack_ok: c_int = 0;
const collo_hpack_done: c_int = 1;
const collo_hpack_invalid_argument: c_int = -1;
const collo_hpack_out_of_memory: c_int = -2;
const collo_hpack_bad_data: c_int = -3;
const collo_hpack_too_large: c_int = -4;
const collo_hpack_output_too_small: c_int = -5;

fn initialDecodedStorageCapacity(block_len: usize, max_header_bytes: usize) usize {
    if (max_header_bytes == 0)
        return 0;
    const doubled = std.math.mul(usize, block_len, 2) catch max_header_bytes;
    return @min(max_header_bytes, @max(@as(usize, 128), doubled));
}

extern fn collo_hpack_decoder_new(out: *?*RawDecoder) c_int;
extern fn collo_hpack_decoder_free(handle: *RawDecoder) void;
extern fn collo_hpack_decoder_set_max_capacity(handle: *RawDecoder, capacity: u32) void;
extern fn collo_hpack_decode_one(
    handle: *RawDecoder,
    src: [*]const u8,
    src_len: usize,
    offset: *usize,
    out: [*]u8,
    out_len: usize,
    header: *RawDecodedHeader,
) c_int;

extern fn collo_hpack_encoder_new(out: *?*RawEncoder) c_int;
extern fn collo_hpack_encoder_free(handle: *RawEncoder) void;
extern fn collo_hpack_encoder_set_max_capacity(handle: *RawEncoder, capacity: u32) void;
extern fn collo_hpack_encode_header(
    handle: *RawEncoder,
    dst: [*]u8,
    dst_len: usize,
    offset: *usize,
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
) c_int;

fn decodedSlice(buffer: []const u8, offset: u32, len: u32) ![]const u8 {
    const start: usize = offset;
    const size: usize = len;
    if (start > buffer.len or size > buffer.len - start)
        return error.HpackBadData;
    return buffer[start .. start + size];
}

fn isDynamicTableSizeUpdate(byte: u8) bool {
    return (byte & 0xe0) == 0x20;
}

fn encodeDynamicTableSizeUpdate(out: []u8, capacity: u32) !usize {
    if (out.len == 0)
        return error.HpackOutputTooSmall;
    const prefix_max: u32 = 31;
    if (capacity < prefix_max) {
        out[0] = 0x20 | @as(u8, @intCast(capacity));
        return 1;
    }

    out[0] = 0x20 | @as(u8, @intCast(prefix_max));
    var offset: usize = 1;
    var remaining = capacity - prefix_max;
    while (remaining >= 128) {
        if (offset == out.len)
            return error.HpackOutputTooSmall;
        out[offset] = @as(u8, @intCast((remaining & 0x7f) | 0x80));
        remaining >>= 7;
        offset += 1;
    }
    if (offset == out.len)
        return error.HpackOutputTooSmall;
    out[offset] = @as(u8, @intCast(remaining));
    return offset + 1;
}

fn statusToError(status: c_int) !void {
    return switch (status) {
        collo_hpack_ok => {},
        collo_hpack_invalid_argument => error.HpackInvalidArgument,
        collo_hpack_out_of_memory => error.OutOfMemory,
        collo_hpack_bad_data => error.HpackBadData,
        collo_hpack_too_large => error.HpackHeaderListTooLarge,
        collo_hpack_output_too_small => error.HpackOutputTooSmall,
        else => error.HpackBadData,
    };
}
