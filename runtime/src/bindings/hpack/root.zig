//! HPACK ABI wrapper around the patched ls-hpack encoder/decoder.

const std = @import("std");

pub const RawDecoder = opaque {};
pub const RawEncoder = opaque {};

/// Hard memory cap for HPACK dynamic tables. Peers may advertise a larger
/// SETTINGS_HEADER_TABLE_SIZE, but using less table capacity is always valid.
pub const max_dynamic_table_capacity: u32 = 4096;

pub const RawDecodedHeader = extern struct {
    name_offset: u32,
    name_len: u32,
    value_offset: u32,
    value_len: u32,
};

const RawPreparedHeader = extern struct {
    storage_offset: u32,
    name_hash: u32,
    name_value_hash: u32,
    name_len: u16,
    value_len: u16,
    static_index: u8,
    flags: u8,
    reserved: u16,
};

comptime {
    std.debug.assert(@sizeOf(RawPreparedHeader) == 20);
    std.debug.assert(@offsetOf(RawPreparedHeader, "storage_offset") == 0);
    std.debug.assert(@offsetOf(RawPreparedHeader, "name_hash") == 4);
    std.debug.assert(@offsetOf(RawPreparedHeader, "name_value_hash") == 8);
    std.debug.assert(@offsetOf(RawPreparedHeader, "name_len") == 12);
    std.debug.assert(@offsetOf(RawPreparedHeader, "value_len") == 14);
    std.debug.assert(@offsetOf(RawPreparedHeader, "static_index") == 16);
    std.debug.assert(@offsetOf(RawPreparedHeader, "flags") == 17);
    std.debug.assert(@offsetOf(RawPreparedHeader, "reserved") == 18);
}

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const PreparedHeaders = struct {
    storage: []u8 = &.{},
    headers: []RawPreparedHeader = &.{},
    encoded_bytes_max: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const Header,
    ) !PreparedHeaders {
        if (source.len == 0)
            return .{};

        var storage_len: usize = 0;
        var encoded_bytes_max: usize = 0;
        for (source) |header| {
            if (header.name.len > max_single_header_decode_bytes)
                return error.HpackHeaderListTooLarge;
            if (header.value.len > max_single_header_decode_bytes)
                return error.HpackHeaderListTooLarge;
            const header_storage_len = std.math.add(
                usize,
                header.name.len,
                header.value.len,
            ) catch return error.HpackHeaderListTooLarge;
            storage_len = std.math.add(
                usize,
                storage_len,
                header_storage_len,
            ) catch return error.HpackHeaderListTooLarge;
            if (storage_len > std.math.maxInt(u32))
                return error.HpackHeaderListTooLarge;
            encoded_bytes_max = std.math.add(
                usize,
                encoded_bytes_max,
                try encodedHeaderUpperBound(header),
            ) catch return error.HpackHeaderListTooLarge;
        }

        const prepared_headers = try allocator.alloc(RawPreparedHeader, source.len);
        errdefer allocator.free(prepared_headers);
        const storage = try allocator.alloc(u8, storage_len);
        errdefer allocator.free(storage);

        var storage_offset: usize = 0;
        for (source, prepared_headers) |header, *prepared| {
            try statusToError(collo_hpack_prepare_header(
                prepared,
                storage.ptr,
                storage.len,
                @intCast(storage_offset),
                @ptrCast(header.name.ptr),
                header.name.len,
                @ptrCast(header.value.ptr),
                header.value.len,
            ));
            storage_offset += header.name.len + header.value.len;
        }
        std.debug.assert(storage_offset == storage.len);
        return .{
            .storage = storage,
            .headers = prepared_headers,
            .encoded_bytes_max = encoded_bytes_max,
        };
    }

    pub fn deinit(self: *PreparedHeaders, allocator: std.mem.Allocator) void {
        if (self.headers.len != 0)
            allocator.free(self.headers);
        if (self.storage.len != 0)
            allocator.free(self.storage);
        self.* = .{};
    }
};

const DecodedHeaderOffset = struct {
    name_start: usize,
    name_len: usize,
    value_start: usize,
    value_len: usize,
};

pub const DecodedBlock = struct {
    storage: []u8 = &.{},
    headers: []Header = &.{},

    pub fn deinit(self: *DecodedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
        allocator.free(self.storage);
        self.* = .{};
    }
};

pub const EncodedBlock = struct {
    storage: []u8 = &.{},
    len: usize = 0,

    pub fn bytes(self: EncodedBlock) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn deinit(self: *EncodedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = .{};
    }
};

pub const Decoder = struct {
    handle: ?*RawDecoder = null,
    /// Decode scratch reused across decodeBlock calls so each HEADERS frame
    /// does not pay a 64KiB allocate/free round trip. First-allocator-wins:
    /// the buffer is allocated lazily with the allocator of the first
    /// decodeBlock call and freed in deinit. Callers pass one stable
    /// per-connection runtime allocator, so later calls assert the same
    /// allocator vtable instead of reallocating.
    scratch: []u8 = &.{},
    scratch_allocator: ?std.mem.Allocator = null,

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
        if (self.scratch_allocator) |scratch_allocator| {
            scratch_allocator.free(self.scratch);
            self.scratch = &.{};
            self.scratch_allocator = null;
        }
        std.debug.assert(self.scratch.len == 0);
    }

    pub fn ensureInitialized(self: *Decoder) !void {
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

    pub fn decodeBlock(
        self: *Decoder,
        allocator: std.mem.Allocator,
        block: []const u8,
        max_header_count: usize,
        max_header_bytes: usize,
    ) !DecodedBlock {
        try self.ensureInitialized();
        if (block.len == 0)
            return .{};
        return self.decodeBlockScratch(allocator, try self.ensureScratch(allocator), block, max_header_count, max_header_bytes);
    }

    /// `decodeBlock` with the caller's room for the field being decoded,
    /// `max_single_header_decode_bytes` long, instead of the decoder's own:
    /// for a caller that decodes many connections' blocks one at a time and
    /// keeps one scratch for all of them. The decoder never allocates its own
    /// scratch on this path.
    pub fn decodeBlockScratch(
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

    fn ensureScratch(self: *Decoder, allocator: std.mem.Allocator) ![]u8 {
        if (self.scratch_allocator) |scratch_allocator| {
            // First-allocator-wins: callers hold one stable allocator per
            // connection, so a different vtable here is a programmer error.
            std.debug.assert(scratch_allocator.ptr == allocator.ptr);
            std.debug.assert(scratch_allocator.vtable == allocator.vtable);
            std.debug.assert(self.scratch.len == max_single_header_decode_bytes);
            return self.scratch;
        }
        std.debug.assert(self.scratch.len == 0);
        const scratch = try allocator.alloc(u8, max_single_header_decode_bytes);
        self.scratch = scratch;
        self.scratch_allocator = allocator;
        return scratch;
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
    scratch: []u8 = &.{},
    scratch_allocator: ?std.mem.Allocator = null,

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
        if (self.scratch_allocator) |scratch_allocator| {
            scratch_allocator.free(self.scratch);
            self.scratch = &.{};
            self.scratch_allocator = null;
        }
        std.debug.assert(self.scratch.len == 0);
    }

    pub fn ensureInitialized(self: *Encoder) !void {
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

    pub fn encodeHeaders(
        self: *Encoder,
        allocator: std.mem.Allocator,
        headers: []const Header,
        max_block_bytes: usize,
    ) !EncodedBlock {
        const storage_len = try self.encodedStorageLen(headers, max_block_bytes);
        const storage = try allocator.alloc(u8, storage_len);
        errdefer allocator.free(storage);

        const len = try self.encodeHeadersInto(storage, headers);
        return .{ .storage = storage, .len = len };
    }

    pub fn encodeHeadersScratch(
        self: *Encoder,
        allocator: std.mem.Allocator,
        headers: []const Header,
        max_block_bytes: usize,
    ) ![]const u8 {
        const storage_len = try self.encodedStorageLen(headers, max_block_bytes);
        const storage = try self.ensureScratchCapacity(allocator, storage_len);
        const len = try self.encodeHeadersInto(storage, headers);
        return storage[0..len];
    }

    /// `encodeHeadersScratch` into the caller's `scratch` instead of the
    /// encoder's own: for a caller that encodes many connections' heads one
    /// at a time and keeps one scratch for all of them. The block borrows
    /// `scratch`. Fails with `error.HpackOutputTooSmall` when the block may
    /// not fit it.
    pub fn encodeHeadersWithScratch(
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

    pub fn encodePreparedHeaders(
        self: *Encoder,
        allocator: std.mem.Allocator,
        prepared: *const PreparedHeaders,
        max_block_bytes: usize,
    ) !EncodedBlock {
        const storage_len = try self.preparedStorageLen(prepared, max_block_bytes);
        const storage = try allocator.alloc(u8, storage_len);
        errdefer allocator.free(storage);

        const len = try self.encodePreparedHeadersInto(storage, prepared);
        return .{ .storage = storage, .len = len };
    }

    pub fn encodePreparedHeadersScratch(
        self: *Encoder,
        allocator: std.mem.Allocator,
        prepared: *const PreparedHeaders,
        max_block_bytes: usize,
    ) ![]const u8 {
        const storage_len = try self.preparedStorageLen(prepared, max_block_bytes);
        const storage = try self.ensureScratchCapacity(allocator, storage_len);
        const len = try self.encodePreparedHeadersInto(storage, prepared);
        return storage[0..len];
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

    fn preparedStorageLen(
        self: *const Encoder,
        prepared: *const PreparedHeaders,
        max_block_bytes: usize,
    ) !usize {
        if (self.poisoned != null)
            return error.HpackEncoderPoisoned;

        var storage_len = prepared.encoded_bytes_max;
        if (self.pending_capacity_update) |capacity| {
            storage_len = std.math.add(
                usize,
                storage_len,
                hpackIntegerEncodedLen(5, capacity),
            ) catch return error.HpackHeaderListTooLarge;
            const minimum = self.pending_capacity_min orelse capacity;
            std.debug.assert(minimum <= capacity);
            if (minimum != capacity) {
                storage_len = std.math.add(
                    usize,
                    storage_len,
                    hpackIntegerEncodedLen(5, minimum),
                ) catch return error.HpackHeaderListTooLarge;
            }
        }
        storage_len = @min(storage_len, max_block_bytes);
        if (storage_len == 0 and
            (prepared.headers.len != 0 or self.pending_capacity_update != null))
        {
            return error.HpackOutputTooSmall;
        }
        return storage_len;
    }

    fn encodePreparedHeadersInto(
        self: *Encoder,
        storage: []u8,
        prepared: *const PreparedHeaders,
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
        statusToError(collo_hpack_encode_prepared_block(
            self.handle.?,
            storage.ptr,
            storage.len,
            &offset,
            prepared.storage.ptr,
            prepared.storage.len,
            prepared.headers.ptr,
            prepared.headers.len,
        )) catch |err| {
            self.poison(err);
            return error.HpackEncoderPoisoned;
        };
        self.pending_capacity_update = null;
        self.pending_capacity_min = null;
        return offset;
    }

    fn ensureScratchCapacity(self: *Encoder, allocator: std.mem.Allocator, len: usize) ![]u8 {
        if (self.scratch_allocator) |scratch_allocator| {
            // First-allocator-wins, matching Decoder: connection-owned encoders
            // must be used with one stable runtime allocator.
            std.debug.assert(scratch_allocator.ptr == allocator.ptr);
            std.debug.assert(scratch_allocator.vtable == allocator.vtable);
            if (self.scratch.len >= len)
                return self.scratch;

            const scratch = try scratch_allocator.realloc(self.scratch, len);
            self.scratch = scratch;
            return scratch;
        }

        std.debug.assert(self.scratch.len == 0);
        const scratch = try allocator.alloc(u8, len);
        self.scratch = scratch;
        self.scratch_allocator = allocator;
        return scratch;
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
/// The longest name or value one decoded field may have: the size of the
/// decoder's scratch, its own or a caller's (`Decoder.decodeBlockScratch`).
pub const max_single_header_decode_bytes: usize = 64 * 1024 - 1;

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

    for (headers) |header| {
        if (header.name.len > max_single_header_decode_bytes)
            return error.HpackHeaderListTooLarge;
        if (header.value.len > max_single_header_decode_bytes)
            return error.HpackHeaderListTooLarge;
        const header_len = try encodedHeaderUpperBound(header);
        len = std.math.add(usize, len, header_len) catch return error.HpackHeaderListTooLarge;
    }
    return @min(len, max_block_bytes);
}

fn encodedHeaderUpperBound(header: Header) !usize {
    const name_len = encodedStringUpperBound(header.name.len);
    const value_len = encodedStringUpperBound(header.value.len);
    const name_and_value_len = std.math.add(usize, name_len, value_len) catch
        return error.HpackHeaderListTooLarge;
    return std.math.add(usize, 1, name_and_value_len) catch
        return error.HpackHeaderListTooLarge;
}

fn encodedStringUpperBound(len: usize) usize {
    std.debug.assert(len <= max_single_header_decode_bytes);
    return hpackIntegerEncodedLen(7, @intCast(len)) + len;
}

fn hpackIntegerEncodedLen(prefix_bits: u5, value: u32) usize {
    const prefix_max = (@as(u32, 1) << prefix_bits) - 1;
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

pub fn clampDynamicTableCapacity(capacity: u32) u32 {
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
extern fn collo_hpack_prepare_header(
    prepared: *RawPreparedHeader,
    storage: [*]u8,
    storage_len: usize,
    storage_offset: u32,
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
) c_int;
extern fn collo_hpack_encode_prepared_block(
    handle: *RawEncoder,
    dst: [*]u8,
    dst_len: usize,
    offset: *usize,
    storage: [*]const u8,
    storage_len: usize,
    headers: [*]const RawPreparedHeader,
    header_count: usize,
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
