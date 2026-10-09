//! What the HTTP/2 driver of one ingress lane shares across the lane's
//! connections, on the lane thread: the buffer every socket read goes into,
//! the HPACK scratch of the one header block decoded or encoded at a time,
//! the budget of unfinished header blocks, and the slab of the lane's streams.
//! A connection's own state holds none of these, so an idle connection costs
//! only its slot.
//!
//! Invariants:
//! - The buffers are one MAP_NORESERVE mapping, written only when first used.
//!   A read's bytes are handled before the lane reads another connection, and
//!   a header block is decoded and a response head encoded whole on the lane
//!   thread, so one of each serves every connection.
//! - `header_blocks` counts the bytes every connection's unfinished header
//!   block holds, and a block gives its charge back when it is taken or
//!   dropped (`connection_slot.zig`), so the count returns to zero once no
//!   connection assembles a block.

const std = @import("std");
const os = @import("collo_os");

const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const limits = @import("collo_limits");
const stream_table = @import("../runner/stream_table.zig");

const page_size = std.heap.page_size_min;

/// The bytes of header blocks a lane's connections hold before they can be
/// decoded, against `limits.ingress.header_block_bytes_per_lane_max`.
pub const HeaderBlockBudget = struct {
    used: usize = 0,
    limit: usize = limits.ingress.header_block_bytes_per_lane_max,

    /// Takes `bytes` from the budget, or fails with
    /// `error.Http2HeaderBlockBudgetExceeded`, taking nothing, when that would
    /// pass the limit. The connection that asked then closes.
    pub fn charge(self: *HeaderBlockBudget, bytes: usize) error{Http2HeaderBlockBudgetExceeded}!void {
        if (bytes > self.limit - self.used)
            return error.Http2HeaderBlockBudgetExceeded;
        self.used += bytes;
    }

    pub fn release(self: *HeaderBlockBudget, bytes: usize) void {
        std.debug.assert(bytes <= self.used);
        self.used -= bytes;
    }
};

pub const LaneResources = struct {
    /// One socket read of any connection.
    read_buffer: []u8,
    /// The HPACK decoder's room for the field being decoded.
    decode_scratch: []u8,
    /// The HPACK encoder's output for the response head being encoded.
    encode_scratch: []u8,
    header_blocks: HeaderBlockBudget = .{},
    streams: stream_table.StreamSlab,
    mapping: []align(page_size) u8,

    /// A frame header and the longest payload the server admits, so a read
    /// can take any frame whole: a client that sends one frame at a time has
    /// each reach its stream in one piece, and a run of whole DATA frames
    /// reaches the batch path.
    pub const read_buffer_bytes: usize = h2.frame_header_len + limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES;
    pub const decode_scratch_bytes: usize = hpack.max_single_header_decode_bytes;
    pub const encode_scratch_bytes: usize = limits.headers.INGRESS_H2_RESPONSE_HEADER_BLOCK_BYTES;

    /// Reserves the buffers and a slab of `stream_capacity` streams, and
    /// writes none of them (`os.memory.reserveFaultIn`).
    pub fn init(stream_capacity: u32) !LaneResources {
        const read_offset: usize = 0;
        const decode_offset = std.mem.alignForward(usize, read_offset + read_buffer_bytes, page_size);
        const encode_offset = std.mem.alignForward(usize, decode_offset + decode_scratch_bytes, page_size);
        const total = std.mem.alignForward(usize, encode_offset + encode_scratch_bytes, page_size);
        const mapping = try os.memory.reserveFaultIn(total);
        errdefer std.posix.munmap(mapping);
        var streams = try stream_table.StreamSlab.init(stream_capacity);
        errdefer streams.deinit();
        return .{
            .read_buffer = mapping[read_offset..][0..read_buffer_bytes],
            .decode_scratch = mapping[decode_offset..][0..decode_scratch_bytes],
            .encode_scratch = mapping[encode_offset..][0..encode_scratch_bytes],
            .streams = streams,
            .mapping = mapping,
        };
    }

    pub fn deinit(self: *LaneResources) void {
        self.streams.deinit();
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }

    /// The address space `init` reserves for `stream_capacity` streams, all
    /// of which a lane's busiest moment may make resident.
    pub fn residentCapBytes(stream_capacity: u32) usize {
        return read_buffer_bytes + decode_scratch_bytes + encode_scratch_bytes +
            @as(usize, stream_capacity) * @sizeOf(stream_table.H2StreamEntry);
    }
};
