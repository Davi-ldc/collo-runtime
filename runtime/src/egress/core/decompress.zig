//! Content decoding for fetch response bodies: gzip and deflate through zlib,
//! br through the brotli decoder, both compiled into the binary from their
//! pinned trees (`collo_zlib`, `collo_brotli`). Every coding is therefore
//! always available: the transport advertises one constant Accept-Encoding,
//! and no process loads anything to decode, inside its sandbox or before it.
//! The gateway's HTTP/1 pump decodes on the engine owner thread and the worker
//! decodes forwarded HTTP/2 bodies on its event loop. A `StreamDecoder` has no
//! synchronization and serves one response.

const std = @import("std");
const brotli = @import("collo_brotli");
const zlib = @import("collo_zlib");

pub const Encoding = enum {
    identity,
    gzip,
    deflate,
    br,
};

/// The Accept-Encoding the transport sends: every coding `StreamDecoder`
/// decodes.
pub const default_accept_encoding = "gzip, deflate, br";

/// The decoder for a response's Content-Encoding headers. `x-gzip` is an
/// alias of gzip (RFC 9110 §8.4.1.3), and empty or `identity` entries are
/// skipped. Any unknown coding makes the body pass through raw as
/// `.identity`, per fetch passthrough behavior; the consumer still sees the
/// original Content-Encoding header. More than one supported coding fails
/// with `error.UnsupportedCompressionMethod`, because the decoder pipeline
/// decodes a single coding.
pub fn encodingFromHeaders(headers: anytype) !Encoding {
    var known: ?Encoding = null;
    var known_count: usize = 0;
    var saw_unknown = false;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "content-encoding"))
            continue;
        var values = std.mem.splitScalar(u8, header.value, ',');
        while (values.next()) |value| {
            const coding = std.mem.trim(u8, value, &std.ascii.whitespace);
            if (coding.len == 0 or std.ascii.eqlIgnoreCase(coding, "identity"))
                continue;
            if (encodingFromToken(coding)) |encoding| {
                known = encoding;
                known_count += 1;
            } else {
                saw_unknown = true;
            }
        }
    }
    if (saw_unknown)
        return .identity;
    if (known_count > 1)
        return error.UnsupportedCompressionMethod;
    return known orelse .identity;
}

fn encodingFromToken(token: []const u8) ?Encoding {
    if (std.ascii.eqlIgnoreCase(token, "gzip") or std.ascii.eqlIgnoreCase(token, "x-gzip"))
        return .gzip;
    if (std.ascii.eqlIgnoreCase(token, "deflate"))
        return .deflate;
    if (std.ascii.eqlIgnoreCase(token, "br"))
        return .br;
    return null;
}

pub const StreamDecoder = struct {
    state: union(Encoding) {
        identity: void,
        gzip: ZlibStream,
        deflate: ZlibStream,
        br: BrotliStream,
    },
    finished: bool = false,

    pub fn init(encoding: Encoding) !StreamDecoder {
        return .{ .state = switch (encoding) {
            .identity => .{ .identity = {} },
            .gzip => .{ .gzip = try ZlibStream.init(.gzip) },
            .deflate => .{ .deflate = try ZlibStream.init(.deflate) },
            .br => .{ .br = try BrotliStream.init() },
        } };
    }

    pub fn deinit(self: *StreamDecoder) void {
        switch (self.state) {
            .identity => {},
            .gzip => |*stream| stream.deinit(),
            .deflate => |*stream| stream.deinit(),
            .br => |*stream| stream.deinit(),
        }
        self.* = undefined;
    }

    // Every push and finish takes an output bound and stops there. Deflate
    // expands up to about 1030:1, so decoding a 64 KiB push without a bound
    // could allocate about 65 MB before the ratio guard sees the output;
    // callers bound each call by the smaller of the free watermark space and
    // the remaining budget.

    /// One decode step: output owned by the caller's allocator, the input
    /// bytes consumed, whether the stream finished, and whether the codec
    /// holds output it could not emit within the bound.
    pub const DecodeSlice = struct {
        bytes: []u8,
        consumed: usize,
        finished: bool,
        needs_output: bool,

        pub fn deinit(self: *DecodeSlice, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }

        pub fn takeBytes(self: *DecodeSlice) []u8 {
            const bytes = self.bytes;
            self.bytes = &.{};
            return bytes;
        }
    };

    /// Decodes as much of `bytes` as fits in `max_output_bytes` of output;
    /// the identity coding copies all of `bytes` or, when they exceed the
    /// bound, nothing. Fails with `error.FetchResponseTooLarge` once output
    /// would pass `max_body_bytes` or `bytes` exceed what zlib takes in one
    /// call, `error.InvalidCompressedResponse` or
    /// `error.FetchResponseTruncated` on bad data,
    /// `error.UnsupportedCompressionMethod` when deflate's deferred
    /// `inflateInit2` fails, or `error.OutOfMemory`.
    pub fn pushToOwnedSliceLimited(
        self: *StreamDecoder,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        max_body_bytes: usize,
        max_output_bytes: usize,
    ) !DecodeSlice {
        var out: std.array_list.Aligned(u8, null) = .empty;
        errdefer out.deinit(allocator);
        switch (self.state) {
            .identity => {
                if (bytes.len > max_output_bytes)
                    return .{
                        .bytes = try out.toOwnedSlice(allocator),
                        .consumed = 0,
                        .finished = false,
                        .needs_output = true,
                    };
                try out.appendSlice(allocator, bytes);
                return .{
                    .bytes = try out.toOwnedSlice(allocator),
                    .consumed = bytes.len,
                    .finished = false,
                    .needs_output = false,
                };
            },
            .gzip => |*stream| {
                const result = try stream.pushLimited(allocator, bytes, &out, max_body_bytes, max_output_bytes);
                self.finished = result.finished;
                return .{
                    .bytes = try out.toOwnedSlice(allocator),
                    .consumed = result.consumed,
                    .finished = result.finished,
                    .needs_output = result.needs_output,
                };
            },
            .deflate => |*stream| {
                const result = try stream.pushLimited(allocator, bytes, &out, max_body_bytes, max_output_bytes);
                self.finished = result.finished;
                return .{
                    .bytes = try out.toOwnedSlice(allocator),
                    .consumed = result.consumed,
                    .finished = result.finished,
                    .needs_output = result.needs_output,
                };
            },
            .br => |*stream| {
                const result = try stream.pushLimited(allocator, bytes, &out, max_body_bytes, max_output_bytes);
                self.finished = result.finished;
                return .{
                    .bytes = try out.toOwnedSlice(allocator),
                    .consumed = result.consumed,
                    .finished = result.finished,
                    .needs_output = result.needs_output,
                };
            },
        }
    }

    /// Flushes the codec trailer and returns the rest of the output, owned by
    /// `allocator`. Fails with `error.FetchResponseTooLarge` when output
    /// remains past `max_body_bytes` and `error.FetchResponseTruncated` when
    /// the stream did not end.
    pub fn finishToOwnedSlice(
        self: *StreamDecoder,
        allocator: std.mem.Allocator,
        max_body_bytes: usize,
    ) ![]u8 {
        var decoded = try self.finishToOwnedSliceLimited(allocator, max_body_bytes, max_body_bytes);
        errdefer decoded.deinit(allocator);
        if (decoded.needs_output)
            return error.FetchResponseTooLarge;
        if (!decoded.finished and self.state != .identity)
            return error.FetchResponseTruncated;
        return decoded.takeBytes();
    }

    /// Flushes the codec trailer within `max_output_bytes`. A result with
    /// `needs_output` must be finished again once capacity frees; one that is
    /// neither finished nor needs output means the stream ended early.
    pub fn finishToOwnedSliceLimited(
        self: *StreamDecoder,
        allocator: std.mem.Allocator,
        max_body_bytes: usize,
        max_output_bytes: usize,
    ) !DecodeSlice {
        var out: std.array_list.Aligned(u8, null) = .empty;
        errdefer out.deinit(allocator);
        switch (self.state) {
            .identity => return .{
                .bytes = try out.toOwnedSlice(allocator),
                .consumed = 0,
                .finished = true,
                .needs_output = false,
            },
            .gzip => |*stream| {
                const result = try stream.finishLimited(allocator, &out, max_body_bytes, max_output_bytes);
                self.finished = result.finished;
                return .{
                    .bytes = try out.toOwnedSlice(allocator),
                    .consumed = 0,
                    .finished = result.finished,
                    .needs_output = result.needs_output,
                };
            },
            .deflate => |*stream| {
                const result = try stream.finishLimited(allocator, &out, max_body_bytes, max_output_bytes);
                self.finished = result.finished;
                return .{
                    .bytes = try out.toOwnedSlice(allocator),
                    .consumed = 0,
                    .finished = result.finished,
                    .needs_output = result.needs_output,
                };
            },
            .br => |*stream| {
                const result = try stream.finishLimited(allocator, &out, max_body_bytes, max_output_bytes);
                self.finished = result.finished;
                return .{
                    .bytes = try out.toOwnedSlice(allocator),
                    .consumed = 0,
                    .finished = result.finished,
                    .needs_output = result.needs_output,
                };
            },
        }
    }
};

const ZlibMode = enum { gzip, deflate };

const ZlibStream = struct {
    mode: ZlibMode,
    /// On the C heap because zlib's state points back at the stream, which
    /// therefore must not move while this value is copied around.
    stream: *zlib.Stream,
    initialized: bool = false,
    /// `Content-Encoding: deflate` is served both zlib-wrapped (RFC 1950)
    /// and raw (RFC 1951) in the wild; browsers and curl sniff the first two
    /// bytes to tell them apart. Deflate therefore defers `inflateInit2`
    /// until those bytes arrive and picks the window-bits sign from them.
    awaiting_deflate_header: bool = false,
    /// The first stream byte when it arrived alone, since the sniff needs
    /// two.
    held_first_byte: ?u8 = null,
    finished: bool = false,
    member_ended: bool = false,

    const LimitedResult = struct {
        consumed: usize,
        finished: bool,
        needs_output: bool,
    };

    fn init(mode: ZlibMode) !ZlibStream {
        const stream = try std.heap.c_allocator.create(zlib.Stream);
        errdefer std.heap.c_allocator.destroy(stream);
        // Null allocator fields make zlib allocate with malloc.
        stream.* = std.mem.zeroes(zlib.Stream);

        var out = ZlibStream{
            .mode = mode,
            .stream = stream,
        };
        switch (mode) {
            .gzip => try out.initWindowBits(15 + 16),
            .deflate => out.awaiting_deflate_header = true,
        }
        return out;
    }

    fn initWindowBits(self: *ZlibStream, window_bits: c_int) !void {
        switch (zlib.inflateInit2(self.stream, window_bits)) {
            zlib.ok => self.initialized = true,
            zlib.mem_error => return error.OutOfMemory,
            else => return error.UnsupportedCompressionMethod,
        }
    }

    /// RFC 1950 header check: CM must be 8 (deflate), CINFO at most 7
    /// (32 KiB window), and the two bytes are a multiple-of-31 checksum.
    /// Anything else under `Content-Encoding: deflate` is raw RFC 1951.
    fn looksZlibWrapped(b0: u8, b1: u8) bool {
        if ((b0 & 0x0f) != 8)
            return false;
        if ((b0 >> 4) > 7)
            return false;
        return (@as(u16, b0) * 256 + @as(u16, b1)) % 31 == 0;
    }

    fn deinit(self: *ZlibStream) void {
        // inflateEnd only frees here; its one failure, a stream it does not
        // recognize, cannot occur for a stream inflateInit2 initialized.
        if (self.initialized and (!self.finished or self.stream.state != null))
            _ = zlib.inflateEnd(self.stream);
        std.heap.c_allocator.destroy(self.stream);
        self.* = undefined;
    }

    fn pushLimited(
        self: *ZlibStream,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        out: *std.array_list.Aligned(u8, null),
        max_body_bytes: usize,
        max_output_bytes: usize,
    ) !LimitedResult {
        if (self.finished) {
            if (bytes.len == 0)
                return .{ .consumed = 0, .finished = true, .needs_output = false };
            return error.InvalidCompressedResponse;
        }
        if (self.member_ended) {
            if (bytes.len == 0)
                return .{ .consumed = 0, .finished = false, .needs_output = false };
            try self.resetForNextGzipMember();
        }
        if (bytes.len > std.math.maxInt(c_uint))
            return error.FetchResponseTooLarge;
        if (max_output_bytes == 0)
            return .{ .consumed = 0, .finished = false, .needs_output = true };

        if (self.awaiting_deflate_header) {
            if (self.held_first_byte == null) {
                if (bytes.len == 0)
                    return .{ .consumed = 0, .finished = false, .needs_output = false };
                if (bytes.len == 1) {
                    self.held_first_byte = bytes[0];
                    return .{ .consumed = 1, .finished = false, .needs_output = false };
                }
            } else if (bytes.len == 0) {
                return .{ .consumed = 0, .finished = false, .needs_output = false };
            }
            const first = self.held_first_byte orelse bytes[0];
            const second = if (self.held_first_byte != null) bytes[0] else bytes[1];
            try self.initWindowBits(if (looksZlibWrapped(first, second)) 15 else -15);
            self.awaiting_deflate_header = false;
        }

        // A held first byte was consumed by an earlier call; inflate it ahead
        // of the current chunk (it is not part of `consumed` below).
        if (self.held_first_byte) |held| {
            const held_buf = [1]u8{held};
            self.stream.next_in = &held_buf;
            self.stream.avail_in = 1;
            const held_result = try self.drainLimited(allocator, out, max_body_bytes, max_output_bytes, zlib.no_flush);
            const held_remaining = self.stream.avail_in;
            self.stream.next_in = null;
            self.stream.avail_in = 0;
            if (held_remaining == 0)
                self.held_first_byte = null;
            if (held_result.needs_output)
                return .{ .consumed = 0, .finished = held_result.finished, .needs_output = true };
            if (held_result.finished)
                return .{ .consumed = 0, .finished = true, .needs_output = false };
        }

        self.stream.next_in = if (bytes.len == 0) null else bytes.ptr;
        self.stream.avail_in = @intCast(bytes.len);
        const result = try self.drainLimited(allocator, out, max_body_bytes, max_output_bytes, zlib.no_flush);
        const consumed = bytes.len - @as(usize, @intCast(self.stream.avail_in));
        self.stream.next_in = null;
        self.stream.avail_in = 0;
        return .{
            .consumed = consumed,
            .finished = result.finished,
            .needs_output = result.needs_output,
        };
    }

    fn finishLimited(
        self: *ZlibStream,
        allocator: std.mem.Allocator,
        out: *std.array_list.Aligned(u8, null),
        max_body_bytes: usize,
        max_output_bytes: usize,
    ) !LimitedResult {
        if (self.finished)
            return .{ .consumed = 0, .finished = true, .needs_output = false };
        if (self.member_ended) {
            self.member_ended = false;
            self.finished = true;
            return .{ .consumed = 0, .finished = true, .needs_output = false };
        }
        // A deflate stream that ended before the two sniff bytes, zero or one
        // byte in all, is invalid under both wrappings, so it is truncated.
        if (self.awaiting_deflate_header)
            return .{ .consumed = 0, .finished = false, .needs_output = false };
        if (max_output_bytes == 0)
            return .{ .consumed = 0, .finished = false, .needs_output = true };
        self.stream.next_in = null;
        self.stream.avail_in = 0;
        return try self.drainLimited(allocator, out, max_body_bytes, max_output_bytes, zlib.finish);
    }

    // Inflate writes straight into the unused capacity of `out`, so decoded
    // bytes are never copied through a scratch buffer. Capacity is reserved
    // from an input-ratio estimate and grown geometrically toward
    // `max_output_bytes`, never reserved at the bound at once: on the finish
    // path the bound can be the whole remaining body budget, megabytes for a
    // tiny body.
    fn drainLimited(
        self: *ZlibStream,
        allocator: std.mem.Allocator,
        out: *std.array_list.Aligned(u8, null),
        max_body_bytes: usize,
        max_output_bytes: usize,
        flush: c_int,
    ) !LimitedResult {
        while (true) {
            const output_remaining = max_output_bytes -| out.items.len;
            if (output_remaining == 0)
                return .{ .consumed = 0, .finished = false, .needs_output = true };
            if (out.unusedCapacitySlice().len == 0) {
                const input_hint: usize = self.stream.avail_in;
                // Deflate payloads commonly expand 2 to 4 times. Reserving
                // too much is cheap, since `toOwnedSlice` shrinks once, and
                // reserving too little costs another growth realloc.
                const grow = @min(output_remaining, @max(@max(4096, input_hint *| 4), out.items.len));
                try out.ensureUnusedCapacity(allocator, grow);
            }
            const dst_full = out.unusedCapacitySlice();
            const dst_len: usize = @min(@min(dst_full.len, output_remaining), std.math.maxInt(c_uint));
            self.stream.next_out = dst_full.ptr;
            self.stream.avail_out = @intCast(dst_len);
            const status = zlib.inflate(self.stream, flush);
            const produced = dst_len - @as(usize, @intCast(self.stream.avail_out));
            self.stream.next_out = null;
            self.stream.avail_out = 0;
            if (produced != 0) {
                const body_remaining = max_body_bytes -| out.items.len;
                if (produced > body_remaining)
                    return error.FetchResponseTooLarge;
                out.items.len += produced;
            }
            if (out.items.len >= max_output_bytes and status != zlib.stream_end)
                return .{ .consumed = 0, .finished = false, .needs_output = true };
            switch (status) {
                zlib.ok => {
                    if (self.stream.avail_in == 0 and produced < dst_len)
                        return .{ .consumed = 0, .finished = false, .needs_output = false };
                    continue;
                },
                zlib.stream_end => {
                    if (self.mode == .gzip and self.stream.avail_in != 0) {
                        try self.resetForNextGzipMember();
                        continue;
                    }
                    if (self.mode == .gzip and flush == zlib.no_flush) {
                        self.member_ended = true;
                        return .{ .consumed = 0, .finished = false, .needs_output = false };
                    }
                    self.finished = true;
                    return .{ .consumed = 0, .finished = true, .needs_output = false };
                },
                zlib.buf_error => {
                    if (flush == zlib.no_flush and self.stream.avail_in == 0)
                        return .{ .consumed = 0, .finished = false, .needs_output = false };
                    return error.FetchResponseTruncated;
                },
                zlib.need_dict, zlib.data_error => return error.InvalidCompressedResponse,
                zlib.mem_error => return error.OutOfMemory,
                zlib.stream_error => return error.InvalidCompressedResponse,
                else => return error.InvalidCompressedResponse,
            }
        }
    }

    fn resetForNextGzipMember(self: *ZlibStream) !void {
        if (self.mode != .gzip)
            return error.InvalidCompressedResponse;
        switch (zlib.inflateReset(self.stream)) {
            zlib.ok => self.member_ended = false,
            zlib.mem_error => return error.OutOfMemory,
            else => return error.InvalidCompressedResponse,
        }
    }
};

const BrotliStream = struct {
    state: *brotli.DecoderState,
    finished: bool = false,

    const LimitedResult = struct {
        consumed: usize,
        finished: bool,
        needs_output: bool,
    };

    fn init() !BrotliStream {
        const state = brotli.decoderCreate() orelse return error.OutOfMemory;
        return .{ .state = state };
    }

    fn deinit(self: *BrotliStream) void {
        brotli.decoderDestroy(self.state);
        self.* = undefined;
    }

    fn pushLimited(
        self: *BrotliStream,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        out: *std.array_list.Aligned(u8, null),
        max_body_bytes: usize,
        max_output_bytes: usize,
    ) !LimitedResult {
        if (self.finished) {
            if (bytes.len == 0)
                return .{ .consumed = 0, .finished = true, .needs_output = false };
            return error.InvalidCompressedResponse;
        }
        if (max_output_bytes == 0)
            return .{ .consumed = 0, .finished = false, .needs_output = true };
        var available_in: usize = bytes.len;
        var next_in: [*c]const u8 = if (bytes.len == 0) null else bytes.ptr;
        const result = try self.drainLimited(allocator, &available_in, &next_in, out, max_body_bytes, max_output_bytes);
        return .{
            .consumed = bytes.len - available_in,
            .finished = result.finished,
            .needs_output = result.needs_output,
        };
    }

    fn finishLimited(
        self: *BrotliStream,
        allocator: std.mem.Allocator,
        out: *std.array_list.Aligned(u8, null),
        max_body_bytes: usize,
        max_output_bytes: usize,
    ) !LimitedResult {
        if (self.finished)
            return .{ .consumed = 0, .finished = true, .needs_output = false };
        if (max_output_bytes == 0)
            return .{ .consumed = 0, .finished = false, .needs_output = true };
        var available_in: usize = 0;
        var next_in: [*c]const u8 = null;
        return try self.drainLimited(allocator, &available_in, &next_in, out, max_body_bytes, max_output_bytes);
    }

    // Decodes straight into the unused capacity of `out`, as
    // `ZlibStream.drainLimited` does.
    fn drainLimited(
        self: *BrotliStream,
        allocator: std.mem.Allocator,
        available_in: *usize,
        next_in: *[*c]const u8,
        out: *std.array_list.Aligned(u8, null),
        max_body_bytes: usize,
        max_output_bytes: usize,
    ) !LimitedResult {
        while (true) {
            const output_remaining = max_output_bytes -| out.items.len;
            if (output_remaining == 0)
                return .{ .consumed = 0, .finished = false, .needs_output = true };
            if (out.unusedCapacitySlice().len == 0) {
                const grow = @min(output_remaining, @max(@max(4096, available_in.* *| 4), out.items.len));
                try out.ensureUnusedCapacity(allocator, grow);
            }
            const dst_full = out.unusedCapacitySlice();
            const dst_len: usize = @min(dst_full.len, output_remaining);
            var available_out: usize = dst_len;
            var next_out: [*c]u8 = dst_full.ptr;
            const result = brotli.decompressStream(self.state, available_in, next_in, &available_out, &next_out);
            const produced = dst_len - available_out;
            if (produced != 0) {
                const body_remaining = max_body_bytes -| out.items.len;
                if (produced > body_remaining)
                    return error.FetchResponseTooLarge;
                out.items.len += produced;
            }
            switch (result) {
                .success => {
                    self.finished = true;
                    return .{ .consumed = 0, .finished = true, .needs_output = false };
                },
                .needs_more_output => {
                    if (out.items.len >= max_output_bytes)
                        return .{ .consumed = 0, .finished = false, .needs_output = true };
                    continue;
                },
                .needs_more_input => return .{ .consumed = 0, .finished = false, .needs_output = false },
                .failure => return error.InvalidCompressedResponse,
                _ => return error.InvalidCompressedResponse,
            }
        }
    }
};
