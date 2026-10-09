//! Helpers for the HTTP/2 codec tests: they build the server's frames in
//! memory, drive a `Connection` until one stream's response is complete, and
//! parse the frames the client wrote after its preface.

const std = @import("std");
const egress_http2 = @import("collo_egress_client").http2;
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");

pub const CollectedH2Response = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    headers: []hpack.Header,
    body: []u8,
    wire_bytes: u64,
    /// The billed meters the codec events carry: the final head block length
    /// from `.head`, and the cumulative counter of the terminal `.end`.
    billed_head_bytes: u64 = 0,
    billed_sent: u64 = 0,
    billed_received: u64 = 0,

    pub fn deinit(self: *CollectedH2Response) void {
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

/// Reads events until `stream_id` ends, acking every body chunk as it arrives
/// and skipping other streams' events.
pub fn readCollectedResponse(
    allocator: std.mem.Allocator,
    connection: *egress_http2.Connection,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    stream_id: u32,
) !CollectedH2Response {
    var headers: []hpack.Header = &.{};
    var body: std.array_list.Aligned(u8, null) = .empty;
    errdefer {
        freeClonedHeaders(allocator, headers);
        body.deinit(allocator);
    }
    var status_code: ?u16 = null;
    var wire_bytes: u64 = 0;
    var billed_head_bytes: u64 = 0;

    while (true) {
        var event = try connection.readNextEvent(reader, writer);
        switch (event) {
            .head => |*head| {
                defer event.deinit();
                if (head.stream_id != stream_id)
                    continue;
                status_code = head.result.status_code;
                wire_bytes += head.result.wire_bytes.total();
                billed_head_bytes = head.billed_head_bytes;
                headers = try cloneHeaders(allocator, head.result.headers);
            },
            .progress => |progress| {
                defer event.deinit();
                if (progress.stream_id == stream_id)
                    wire_bytes += progress.wire_bytes.total();
            },
            .body_chunk => |*chunk| {
                const update_stream = chunk.update_stream_window;
                const flow_credit = chunk.flow_credit;
                const chunk_stream_id = chunk.stream_id;
                defer event.deinit();
                if (chunk_stream_id == stream_id) {
                    try body.appendSlice(allocator, chunk.bytes);
                    wire_bytes += chunk.wire_bytes.total();
                }
                var maybe_end = try connection.ackReceivedData(writer, chunk_stream_id, flow_credit, update_stream);
                if (maybe_end) |*end| {
                    defer end.deinit();
                    switch (end.*) {
                        .end => |done| {
                            if (done.stream_id != stream_id)
                                continue;
                            wire_bytes += done.wire_bytes.total();
                            return .{
                                .allocator = allocator,
                                .status_code = status_code orelse return error.ExpectedHttp2Head,
                                .headers = headers,
                                .body = try body.toOwnedSlice(allocator),
                                .wire_bytes = wire_bytes,
                                .billed_head_bytes = billed_head_bytes,
                                .billed_sent = done.billed_bytes.sent,
                                .billed_received = done.billed_bytes.received,
                            };
                        },
                        else => return error.UnexpectedHttp2Event,
                    }
                }
            },
            .end => |end| {
                defer event.deinit();
                if (end.stream_id != stream_id)
                    continue;
                wire_bytes += end.wire_bytes.total();
                return .{
                    .allocator = allocator,
                    .status_code = status_code orelse return error.ExpectedHttp2Head,
                    .headers = headers,
                    .body = try body.toOwnedSlice(allocator),
                    .wire_bytes = wire_bytes,
                    .billed_head_bytes = billed_head_bytes,
                    .billed_sent = end.billed_bytes.sent,
                    .billed_received = end.billed_bytes.received,
                };
            },
            .failure => |failure| {
                defer event.deinit();
                if (failure.stream_id == stream_id)
                    return failure.err;
            },
        }
    }
}

/// Reads events, acking body chunks, until `stream_id` fails, and expects the
/// failure to be `expected`.
pub fn expectStreamFailure(
    connection: *egress_http2.Connection,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    stream_id: u32,
    expected: anyerror,
) !void {
    while (true) {
        var event = try connection.readNextEvent(reader, writer);
        switch (event) {
            .head, .progress => {
                event.deinit();
            },
            .body_chunk => |chunk| {
                const update_stream = chunk.update_stream_window;
                const flow_credit = chunk.flow_credit;
                const chunk_stream_id = chunk.stream_id;
                event.deinit();
                var maybe_end = try connection.ackReceivedData(writer, chunk_stream_id, flow_credit, update_stream);
                if (maybe_end) |*end|
                    end.deinit();
            },
            .end => {
                event.deinit();
            },
            .failure => |failure| {
                const err = failure.err;
                const failed_stream_id = failure.stream_id;
                event.deinit();
                if (failed_stream_id == stream_id) {
                    try std.testing.expectEqual(expected, err);
                    return;
                }
            },
        }
    }
}

fn cloneHeaders(allocator: std.mem.Allocator, headers: []const hpack.Header) ![]hpack.Header {
    const out = try allocator.alloc(hpack.Header, headers.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer freeClonedHeaders(allocator, out[0..initialized]);
    for (headers, 0..) |header, index| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        out[index] = .{ .name = name, .value = value };
        initialized += 1;
    }
    return out;
}

fn freeClonedHeaders(allocator: std.mem.Allocator, headers: []hpack.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

/// HPACK block length of `headers` from a fresh encoder. These are the bytes
/// `appendHeaderFrames` and `appendResponseFrames` send, so tests can state
/// the expected billed header-block sizes exactly.
pub fn encodedHeaderBlockLen(headers: []const hpack.Header) !usize {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var block = try encoder.encodeHeaders(std.testing.allocator, headers, 4096);
    defer block.deinit(std.testing.allocator);
    return block.bytes().len;
}

pub fn appendSettingsFrame(writer: *std.Io.Writer) !void {
    var header = h2.FrameHeader{
        .length = 0,
        .frame_type_raw = @intFromEnum(h2.FrameType.settings),
        .frame_type = .settings,
        .flags = h2.Flags.fromByte(0),
        .stream_id = 0,
    };
    var wire: [h2.frame_header_len]u8 = undefined;
    try header.encode(&wire);
    try writer.writeAll(&wire);
}

/// Serves `chunks` in order and reports `.wait` after each one, like a
/// nonblocking socket that has run dry.
pub const PartialReadSource = struct {
    const Interest = enum { read, write };
    const Step = union(enum) {
        ready: usize,
        wait: Interest,
        eof,
    };

    chunks: []const []const u8,
    index: usize = 0,
    offset: usize = 0,
    paused: bool = false,

    pub fn readStep(self: *PartialReadSource, dest: []u8) !Step {
        if (self.paused) {
            self.paused = false;
            return .{ .wait = .read };
        }
        if (self.index >= self.chunks.len)
            return .{ .wait = .read };
        const chunk = self.chunks[self.index];
        const amount = @min(dest.len, chunk.len - self.offset);
        @memcpy(dest[0..amount], chunk[self.offset..][0..amount]);
        self.offset += amount;
        if (self.offset == chunk.len) {
            self.index += 1;
            self.offset = 0;
            self.paused = true;
        }
        return .{ .ready = amount };
    }
};

pub fn expectFrameReadWait(received: egress_http2.FrameReadStep) !void {
    var result = received;
    switch (result) {
        .wait => {},
        .frame => |*frame| {
            defer frame.deinit();
            return error.ExpectedHttp2FrameWait;
        },
        .eof => return error.ExpectedHttp2FrameWait,
    }
}

pub fn frameFromWire(wire: []const u8) !egress_http2.client.Frame {
    const header = try h2.FrameHeader.parse(wire[0..h2.frame_header_len]);
    const payload = try std.testing.allocator.dupe(u8, wire[h2.frame_header_len..]);
    return .{
        .allocator = std.testing.allocator,
        .header = header,
        .payload = payload,
    };
}

pub fn appendResponseFrames(
    writer: *std.Io.Writer,
    status: []const u8,
    headers: []const hpack.Header,
    body: []const u8,
) !void {
    try appendResponseFramesForStream(writer, 1, status, headers, body);
}

pub fn appendResponseFramesForStream(
    writer: *std.Io.Writer,
    stream_id: u32,
    status: []const u8,
    headers: []const hpack.Header,
    body: []const u8,
) !void {
    const all_headers = try std.testing.allocator.alloc(hpack.Header, headers.len + 1);
    defer std.testing.allocator.free(all_headers);
    all_headers[0] = .{ .name = ":status", .value = status };
    @memcpy(all_headers[1..], headers);
    try appendHeaderFramesForStream(writer, stream_id, all_headers, body.len == 0);
    if (body.len == 0)
        return;
    const wire = try h2.encodeDataFrames(
        std.testing.allocator,
        h2.default_max_frame_size,
        stream_id,
        body,
        true,
    );
    defer std.testing.allocator.free(wire);
    try writer.writeAll(wire);
}

pub fn appendHeaderFrames(writer: *std.Io.Writer, headers: []const hpack.Header, end_stream: bool) !void {
    try appendHeaderFramesForStream(writer, 1, headers, end_stream);
}

pub fn appendHeaderFramesForStream(writer: *std.Io.Writer, stream_id: u32, headers: []const hpack.Header, end_stream: bool) !void {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var block = try encoder.encodeHeaders(std.testing.allocator, headers, 4096);
    defer block.deinit(std.testing.allocator);
    const wire = try h2.encodeHeadersFrames(
        std.testing.allocator,
        h2.default_max_frame_size,
        stream_id,
        block.bytes(),
        end_stream,
    );
    defer std.testing.allocator.free(wire);
    try writer.writeAll(wire);
}

pub fn appendDataFrameForStream(writer: *std.Io.Writer, stream_id: u32, body: []const u8, end_stream: bool) !void {
    const wire = try h2.encodeDataFrames(
        std.testing.allocator,
        h2.default_max_frame_size,
        stream_id,
        body,
        end_stream,
    );
    defer std.testing.allocator.free(wire);
    try writer.writeAll(wire);
}

pub fn appendPaddedPriorityHeaderFrame(
    writer: *std.Io.Writer,
    stream_id: u32,
    headers: []const hpack.Header,
    end_stream: bool,
    pad_len: u8,
) !void {
    var encoder = try hpack.Encoder.init();
    defer encoder.deinit();
    var block = try encoder.encodeHeaders(std.testing.allocator, headers, 4096);
    defer block.deinit(std.testing.allocator);

    const payload_len: u32 = @intCast(1 + 5 + block.bytes().len + pad_len);
    var header = h2.FrameHeader{
        .length = payload_len,
        .frame_type_raw = @intFromEnum(h2.FrameType.headers),
        .frame_type = .headers,
        .flags = h2.Flags.fromByte(0x8 | 0x20 | 0x4 | if (end_stream) @as(u8, 0x1) else 0),
        .stream_id = stream_id,
    };
    var header_wire: [h2.frame_header_len]u8 = undefined;
    try header.encode(&header_wire);
    try writer.writeAll(&header_wire);
    try writer.writeByte(pad_len);
    try writer.writeAll(&[_]u8{ 0, 0, 0, 0, 1 });
    try writer.writeAll(block.bytes());
    try writer.splatByteAll(0, pad_len);
}

pub fn appendPaddedDataFrame(writer: *std.Io.Writer, stream_id: u32, body: []const u8, end_stream: bool, pad_len: u8) !void {
    var header = h2.FrameHeader{
        .length = @intCast(1 + body.len + pad_len),
        .frame_type_raw = @intFromEnum(h2.FrameType.data),
        .frame_type = .data,
        .flags = h2.Flags.fromByte(0x8 | if (end_stream) @as(u8, 0x1) else 0),
        .stream_id = stream_id,
    };
    var header_wire: [h2.frame_header_len]u8 = undefined;
    try header.encode(&header_wire);
    try writer.writeAll(&header_wire);
    try writer.writeByte(pad_len);
    try writer.writeAll(body);
    try writer.splatByteAll(0, pad_len);
}

pub fn appendWindowUpdateFrame(writer: *std.Io.Writer, stream_id: u32, increment: u32) !void {
    var wire: [h2.frame_header_len + 4]u8 = undefined;
    try h2.encodeWindowUpdateFrame(&wire, stream_id, increment);
    try writer.writeAll(&wire);
}

// The parsers below read the client's output, which starts with the
// connection preface.
pub fn countClientFrames(wire: []const u8, frame_type: h2.FrameType) !usize {
    var cursor: usize = h2.client_connection_preface.len;
    var count: usize = 0;
    while (cursor < wire.len) {
        const header = try h2.FrameHeader.parse(wire[cursor..][0..h2.frame_header_len]);
        if (header.frame_type == frame_type)
            count += 1;
        cursor += h2.frame_header_len + header.length;
    }
    return count;
}

pub fn sumClientFramePayloadBytes(wire: []const u8, frame_type: h2.FrameType) !usize {
    var cursor: usize = h2.client_connection_preface.len;
    var total: usize = 0;
    while (cursor < wire.len) {
        const header = try h2.FrameHeader.parse(wire[cursor..][0..h2.frame_header_len]);
        if (header.frame_type == frame_type)
            total += header.length;
        cursor += h2.frame_header_len + header.length;
    }
    return total;
}

pub fn clientFrameStreamIds(allocator: std.mem.Allocator, wire: []const u8, frame_type: h2.FrameType) !std.ArrayListUnmanaged(u32) {
    var ids = std.ArrayListUnmanaged(u32){};
    errdefer ids.deinit(allocator);
    var cursor: usize = h2.client_connection_preface.len;
    while (cursor < wire.len) {
        const header = try h2.FrameHeader.parse(wire[cursor..][0..h2.frame_header_len]);
        if (header.frame_type == frame_type)
            try ids.append(allocator, header.stream_id);
        cursor += h2.frame_header_len + header.length;
    }
    return ids;
}

pub fn sumClientWindowUpdateIncrements(wire: []const u8, stream_id: u32) !u32 {
    var cursor: usize = h2.client_connection_preface.len;
    var total: u32 = 0;
    while (cursor < wire.len) {
        const header = try h2.FrameHeader.parse(wire[cursor..][0..h2.frame_header_len]);
        const payload_start = cursor + h2.frame_header_len;
        if (header.frame_type == .window_update and header.stream_id == stream_id) {
            const increment = try h2.parseWindowUpdateIncrement(wire[payload_start..][0..header.length]);
            total = try std.math.add(u32, total, increment);
        }
        cursor += h2.frame_header_len + header.length;
    }
    return total;
}
