//! The ingress frame reader (`server/ingress/http2/frame_reader.zig`) on a
//! corpus that passes through every phase it reads: the client preface,
//! frame headers, control payloads up to the longest it buffers, DATA and
//! header block fragments with and without padding and priority fields,
//! skipped payloads, and DATA frames the driver abandons after their first
//! piece. The corpus is fed split at every offset and a byte at a time, and
//! every feed must yield the frames the corpus holds with nothing held back:
//! once a read is handled, each region byte that arrived has reached the
//! driver and each frame that arrived whole has had all its events.
//! Malformed framing fails the same way wherever the reads split it. Root of
//! the `h2-frame-reader` suite, which runs with no engine in
//! `server-fast-test`, `h2-transport-test` and the `test` aggregate; the
//! driver over the reader is covered in `connection.zig`.

const std = @import("std");

const h2 = @import("collo_http").http2;
const limits = @import("collo_limits");
const server_h2 = @import("collo_server_h2");

const frame_reader = server_h2.http2.frame_reader;
const LaneResources = server_h2.http2.lane_resources.LaneResources;

const preface_len = h2.client_connection_preface.len;

/// DATA on this stream is abandoned by the test's driver after its first
/// piece, as the server's driver abandons a frame whose stream went away.
const abandoned_stream: u32 = 7;

/// An exclusive dependency on stream 3 with weight 16.
const priority_fields = [_]u8{ 0x80, 0, 0, 3, 15 };

/// A SETTINGS payload as long as the reader buffers. The reader never
/// parses it, so any bytes do.
const longest_control_payload: [frame_reader.control_payload_bytes_max]u8 = blk: {
    var payload: [frame_reader.control_payload_bytes_max]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 1);
    break :blk payload;
};

/// A frame of a corpus. `region` is its data, its header block fragment or
/// its whole payload, without the padding and priority fields its flags add.
const FrameSpec = struct {
    frame_type: h2.FrameType,
    /// The type byte on the wire, for a type the reader does not know.
    type_raw: ?u8 = null,
    flags: h2.Flags = .{},
    stream_id: u32 = 0,
    pad_len: u8 = 0,
    region: []const u8 = "",

    fn padded(self: FrameSpec) bool {
        return self.flags.padded and (self.frame_type == .data or self.frame_type == .headers);
    }

    fn prioritized(self: FrameSpec) bool {
        return self.flags.priority and self.frame_type == .headers;
    }

    fn length(self: FrameSpec) u32 {
        var len = self.region.len;
        if (self.padded()) len += 1 + @as(usize, self.pad_len);
        if (self.prioritized()) len += priority_fields.len;
        return @intCast(len);
    }

    fn typeByte(self: FrameSpec) u8 {
        return self.type_raw orelse @intFromEnum(self.frame_type);
    }

    fn abandoned(self: FrameSpec) bool {
        return self.frame_type == .data and self.stream_id == abandoned_stream;
    }
};

/// Where a frame's bytes lie in its corpus.
const Layout = struct {
    header_end: usize,
    region_start: usize,
    region_end: usize,
    frame_end: usize,
};

/// The disposition the server's driver gives each frame type it admits
/// (`reading.zig:frameDisposition`).
fn dispositionOf(frame_type: h2.FrameType) frame_reader.Disposition {
    return switch (frame_type) {
        .data => .data,
        .headers, .continuation => .fragment,
        .settings, .rst_stream, .ping, .window_update => .buffer,
        .priority, .goaway, .push_promise, .unknown => .skip,
    };
}

const Corpus = struct {
    bytes: std.ArrayList(u8) = .empty,
    frames: std.ArrayList(FrameSpec) = .empty,
    layouts: std.ArrayList(Layout) = .empty,

    fn deinit(self: *Corpus, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.frames.deinit(allocator);
        self.layouts.deinit(allocator);
    }

    fn append(self: *Corpus, allocator: std.mem.Allocator, spec: FrameSpec) !void {
        var header: [h2.frame_header_len]u8 = undefined;
        try (h2.FrameHeader{
            .length = spec.length(),
            .frame_type_raw = spec.typeByte(),
            .frame_type = spec.frame_type,
            .flags = spec.flags,
            .stream_id = spec.stream_id,
        }).encode(&header);
        try self.bytes.appendSlice(allocator, &header);
        const header_end = self.bytes.items.len;
        if (spec.padded()) try self.bytes.append(allocator, spec.pad_len);
        if (spec.prioritized()) try self.bytes.appendSlice(allocator, &priority_fields);
        const region_start = self.bytes.items.len;
        try self.bytes.appendSlice(allocator, spec.region);
        const region_end = self.bytes.items.len;
        if (spec.padded()) try self.bytes.appendNTimes(allocator, 0, spec.pad_len);
        try self.frames.append(allocator, spec);
        try self.layouts.append(allocator, .{
            .header_end = header_end,
            .region_start = region_start,
            .region_end = region_end,
            .frame_end = self.bytes.items.len,
        });
    }

    /// The transcript `Driver` must write for the whole corpus.
    fn expectedTranscript(self: *const Corpus, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.print(allocator, "preface\n", .{});
        for (self.frames.items) |spec| {
            try printHeader(&out, allocator, spec.length(), spec.typeByte(), spec.flags, spec.stream_id);
            switch (dispositionOf(spec.frame_type)) {
                .buffer => try out.print(allocator, "control {x}\n", .{spec.region}),
                .data, .fragment => |disposition| if (spec.abandoned())
                    try out.print(allocator, "abandoned stream={d} credit={d}\n", .{ spec.stream_id, spec.length() })
                else
                    try out.print(allocator, "{s} stream={d} bytes={x} credit={d}\n", .{
                        @tagName(disposition), spec.stream_id, spec.region, spec.length(),
                    }),
                .skip => {},
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

/// The preface and one frame of every shape the reader tells apart.
fn buildCorpus(allocator: std.mem.Allocator) !Corpus {
    var corpus: Corpus = .{};
    errdefer corpus.deinit(allocator);
    try corpus.bytes.appendSlice(allocator, h2.client_connection_preface);
    const frames = [_]FrameSpec{
        .{ .frame_type = .settings, .region = &longest_control_payload },
        .{ .frame_type = .settings, .flags = .{ .end_stream = true } },
        .{ .frame_type = .headers, .flags = .{ .padded = true, .priority = true }, .stream_id = 1, .pad_len = 3, .region = "\x82\x86\x84\x41\x8a" },
        .{ .frame_type = .continuation, .flags = .{ .end_headers_or_ack = true }, .stream_id = 1, .region = "fragment two" },
        .{ .frame_type = .data, .stream_id = 1, .region = "body bytes of an unpadded frame" },
        .{ .frame_type = .data, .flags = .{ .padded = true }, .stream_id = 1, .pad_len = 7, .region = "padded body" },
        .{ .frame_type = .data, .flags = .{ .padded = true }, .stream_id = 1, .region = "no padding bytes" },
        .{ .frame_type = .data, .flags = .{ .padded = true }, .stream_id = 1, .pad_len = 4 },
        .{ .frame_type = .ping, .region = "pingpong" },
        .{ .frame_type = .window_update, .region = "\x00\x00\x10\x00" },
        .{ .frame_type = .priority, .stream_id = 3, .region = "\x00\x00\x00\x01\x10" },
        .{ .frame_type = .unknown, .type_raw = 0x42, .region = "an extension's payload" },
        .{ .frame_type = .goaway, .region = "\x00\x00\x00\x09\x00\x00\x00\x00debug" },
        .{ .frame_type = .headers, .flags = .{ .end_headers_or_ack = true, .end_stream = true }, .stream_id = 5, .region = "whole block" },
        .{ .frame_type = .data, .flags = .{ .padded = true }, .stream_id = abandoned_stream, .pad_len = 2, .region = "dropped midway" },
        .{ .frame_type = .data, .stream_id = abandoned_stream, .region = "dropped unpadded" },
        .{ .frame_type = .rst_stream, .stream_id = 5, .region = "\x00\x00\x00\x08" },
        .{ .frame_type = .headers, .flags = .{ .priority = true, .end_headers_or_ack = true }, .stream_id = 9 },
        .{ .frame_type = .data, .flags = .{ .end_stream = true }, .stream_id = 1 },
        .{ .frame_type = .data, .flags = .{ .end_stream = true }, .stream_id = 11, .region = "last frame" },
    };
    for (frames) |spec| try corpus.append(allocator, spec);
    return corpus;
}

fn printHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, length: u32, type_byte: u8, flags: h2.Flags, stream_id: u32) !void {
    try out.print(allocator, "header type=0x{x:0>2} flags=0x{x:0>2} stream={d} length={d}\n", .{
        type_byte, flags.toByte(), stream_id, length,
    });
}

/// Plays the server's driver over a reader: accepts each header with the
/// disposition its type gets, gathers each frame's pieces, abandons DATA on
/// `abandoned_stream` after its first piece, and writes a transcript line
/// for the preface and for each header, control payload, region and
/// abandoned frame.
const Driver = struct {
    allocator: std.mem.Allocator,
    reader: frame_reader.State = .{},
    transcript: std.ArrayList(u8) = .empty,
    header: h2.FrameHeader = undefined,
    region: std.ArrayList(u8) = .empty,
    region_credit: u64 = 0,
    /// Pieces of the current frame so far.
    frame_pieces: u32 = 0,
    // What has reached the driver, for the checks after each read.
    prefaces: usize = 0,
    headers: usize = 0,
    controls: usize = 0,
    regions: usize = 0,
    pieces: usize = 0,
    /// Region bytes of the frames the driver keeps.
    region_bytes: usize = 0,

    fn deinit(self: *Driver) void {
        self.transcript.deinit(self.allocator);
        self.region.deinit(self.allocator);
    }

    /// Hands the reader one read's bytes and handles every event they make.
    fn feed(self: *Driver, bytes: []const u8) !void {
        var input = bytes;
        while (try self.reader.next(&input)) |event| {
            switch (event) {
                .preface => {
                    self.prefaces += 1;
                    try self.transcript.print(self.allocator, "preface\n", .{});
                },
                .header => |header| {
                    self.header = header;
                    self.headers += 1;
                    try printHeader(&self.transcript, self.allocator, header.length, header.frame_type_raw, header.flags, header.stream_id);
                    try self.reader.accept(dispositionOf(header.frame_type));
                },
                .control => |payload| {
                    self.controls += 1;
                    try self.transcript.print(self.allocator, "control {x}\n", .{payload});
                },
                .data => |piece| try self.handlePiece(.data, piece),
                .fragment => |piece| try self.handlePiece(.fragment, piece),
            }
        }
        try std.testing.expectEqual(@as(usize, 0), input.len);
    }

    fn handlePiece(self: *Driver, disposition: frame_reader.Disposition, piece: frame_reader.Piece) !void {
        try std.testing.expectEqual(self.frame_pieces == 0, piece.first);
        self.frame_pieces += 1;
        self.pieces += 1;
        if (disposition == .data and self.header.stream_id == abandoned_stream) {
            const credit = @as(u64, piece.credit) + self.reader.skipRest();
            try self.transcript.print(self.allocator, "abandoned stream={d} credit={d}\n", .{ self.header.stream_id, credit });
            self.frame_pieces = 0;
            return;
        }
        try self.region.appendSlice(self.allocator, piece.bytes);
        self.region_bytes += piece.bytes.len;
        self.region_credit += piece.credit;
        if (!piece.last)
            return;
        self.regions += 1;
        try self.transcript.print(self.allocator, "{s} stream={d} bytes={x} credit={d}\n", .{
            @tagName(disposition), self.header.stream_id, self.region.items, self.region_credit,
        });
        self.region.clearRetainingCapacity();
        self.region_credit = 0;
        self.frame_pieces = 0;
    }
};

/// Checks what the driver has once the corpus's first `consumed` bytes are
/// handled: the event of every header, control payload and region that
/// arrived whole, every region byte that arrived, and where the reader
/// stands.
fn expectCaughtUp(corpus: *const Corpus, driver: *const Driver, consumed: usize) !void {
    var headers: usize = 0;
    var controls: usize = 0;
    var regions: usize = 0;
    var region_bytes: usize = 0;
    var boundary = consumed == preface_len;
    for (corpus.frames.items, corpus.layouts.items) |spec, layout| {
        if (layout.header_end <= consumed) headers += 1;
        if (layout.frame_end == consumed) boundary = true;
        switch (dispositionOf(spec.frame_type)) {
            .buffer => {
                if (layout.frame_end <= consumed) controls += 1;
            },
            .data, .fragment => if (!spec.abandoned()) {
                if (layout.region_end <= consumed) regions += 1;
                region_bytes += std.math.clamp(consumed, layout.region_start, layout.region_end) - layout.region_start;
            },
            .skip => {},
        }
    }
    try std.testing.expectEqual(@as(usize, @intFromBool(consumed >= preface_len)), driver.prefaces);
    try std.testing.expectEqual(headers, driver.headers);
    try std.testing.expectEqual(controls, driver.controls);
    try std.testing.expectEqual(regions, driver.regions);
    try std.testing.expectEqual(region_bytes, driver.region_bytes);
    try std.testing.expectEqual(boundary, driver.reader.atFrameBoundary());
    try std.testing.expectEqual(consumed != 0 and !boundary, driver.reader.midFrame());
}

test "the frame reader yields the corpus's frames, with no region byte held back, wherever two reads split it" {
    const allocator = std.testing.allocator;
    var corpus = try buildCorpus(allocator);
    defer corpus.deinit(allocator);
    const expected = try corpus.expectedTranscript(allocator);
    defer allocator.free(expected);

    const bytes = corpus.bytes.items;
    for (0..bytes.len + 1) |split| {
        errdefer std.debug.print("reads split at byte {d}\n", .{split});
        var driver: Driver = .{ .allocator = allocator };
        defer driver.deinit();
        try driver.feed(bytes[0..split]);
        try expectCaughtUp(&corpus, &driver, split);
        try driver.feed(bytes[split..]);
        try expectCaughtUp(&corpus, &driver, bytes.len);
        try std.testing.expectEqualStrings(expected, driver.transcript.items);
    }
}

test "the frame reader fed a byte at a time hands each event over once its bytes are in, and an empty read changes nothing" {
    const allocator = std.testing.allocator;
    var corpus = try buildCorpus(allocator);
    defer corpus.deinit(allocator);
    const expected = try corpus.expectedTranscript(allocator);
    defer allocator.free(expected);

    const bytes = corpus.bytes.items;
    var driver: Driver = .{ .allocator = allocator };
    defer driver.deinit();
    for (1..bytes.len + 1) |consumed| {
        errdefer std.debug.print("after byte {d}\n", .{consumed});
        try driver.feed(bytes[consumed - 1 .. consumed]);
        try expectCaughtUp(&corpus, &driver, consumed);
        try driver.feed(bytes[consumed..consumed]);
        try expectCaughtUp(&corpus, &driver, consumed);
    }
    try std.testing.expectEqualStrings(expected, driver.transcript.items);
}

test "a DATA frame of the longest payload the server admits fits one read of the lane's buffer and reaches its stream in one piece" {
    const allocator = std.testing.allocator;
    var corpus: Corpus = .{};
    defer corpus.deinit(allocator);
    try corpus.bytes.appendSlice(allocator, h2.client_connection_preface);
    const payload = try allocator.alloc(u8, limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES);
    defer allocator.free(payload);
    @memset(payload, 'a');
    try corpus.append(allocator, .{ .frame_type = .data, .stream_id = 1, .region = payload });

    const frame = corpus.bytes.items[preface_len..];
    try std.testing.expectEqual(LaneResources.read_buffer_bytes, frame.len);
    var driver: Driver = .{ .allocator = allocator };
    defer driver.deinit();
    try driver.feed(corpus.bytes.items[0..preface_len]);
    try driver.feed(frame);
    try std.testing.expectEqual(@as(usize, 1), driver.pieces);
    try std.testing.expectEqual(@as(usize, 1), driver.regions);
    try std.testing.expectEqual(payload.len, driver.region_bytes);
}

const Malformed = struct {
    what: []const u8,
    bytes: []const u8,
    err: frame_reader.Error,
};

/// The preface followed by one frame header and `payload`.
fn prefacedFrame(allocator: std.mem.Allocator, header: h2.FrameHeader, payload: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, h2.client_connection_preface);
    var raw: [h2.frame_header_len]u8 = undefined;
    try header.encode(&raw);
    try bytes.appendSlice(allocator, &raw);
    try bytes.appendSlice(allocator, payload);
    return bytes.toOwnedSlice(allocator);
}

fn frameHeader(frame_type: h2.FrameType, flags: h2.Flags, length: u32) h2.FrameHeader {
    return .{ .length = length, .frame_type_raw = @intFromEnum(frame_type), .frame_type = frame_type, .flags = flags, .stream_id = 1 };
}

fn feedSplit(driver: *Driver, bytes: []const u8, split: usize) !void {
    try driver.feed(bytes[0..split]);
    try driver.feed(bytes[split..]);
}

fn feedBytewise(driver: *Driver, bytes: []const u8) !void {
    for (0..bytes.len) |index| try driver.feed(bytes[index..][0..1]);
}

test "malformed framing fails the same way wherever the reads split it" {
    const allocator = std.testing.allocator;
    var wrong_preface = h2.client_connection_preface.*;
    wrong_preface[preface_len - 1] = 'X';
    const cases = [_]Malformed{
        .{ .what = "a preface that differs in its last byte", .bytes = try allocator.dupe(u8, &wrong_preface), .err = error.Http2ProtocolError },
        .{
            .what = "a frame longer than the server admits",
            .bytes = try prefacedFrame(allocator, frameHeader(.data, .{}, limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES + 1), ""),
            .err = error.Http2FrameSizeError,
        },
        .{
            .what = "padded DATA with no payload for the padding length",
            .bytes = try prefacedFrame(allocator, frameHeader(.data, .{ .padded = true }, 0), ""),
            .err = error.Http2ProtocolError,
        },
        .{
            .what = "DATA whose padding fills its payload",
            .bytes = try prefacedFrame(allocator, frameHeader(.data, .{ .padded = true }, 3), "\x03\x00\x00"),
            .err = error.Http2ProtocolError,
        },
        .{
            .what = "HEADERS whose padding fills its payload",
            .bytes = try prefacedFrame(allocator, frameHeader(.headers, .{ .padded = true }, 1), "\x01"),
            .err = error.Http2ProtocolError,
        },
        .{
            .what = "HEADERS too short for its priority fields",
            .bytes = try prefacedFrame(allocator, frameHeader(.headers, .{ .priority = true }, 4), "\x00\x00\x00\x00"),
            .err = error.Http2FrameSizeError,
        },
        .{
            .what = "padded HEADERS whose priority fields do not fit before the padding",
            .bytes = try prefacedFrame(allocator, frameHeader(.headers, .{ .padded = true, .priority = true }, 7), "\x02\x00\x00\x00\x00\x00\x00"),
            .err = error.Http2FrameSizeError,
        },
    };
    defer for (cases) |case| allocator.free(case.bytes);

    for (cases) |case| {
        errdefer std.debug.print("malformed: {s}\n", .{case.what});
        for (0..case.bytes.len + 1) |split| {
            errdefer std.debug.print("reads split at byte {d}\n", .{split});
            var driver: Driver = .{ .allocator = allocator };
            defer driver.deinit();
            try std.testing.expectError(case.err, feedSplit(&driver, case.bytes, split));
        }
        var driver: Driver = .{ .allocator = allocator };
        defer driver.deinit();
        try std.testing.expectError(case.err, feedBytewise(&driver, case.bytes));
    }
}
