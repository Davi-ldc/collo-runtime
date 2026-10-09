//! The frame reader of one client connection: it splits the bytes of each
//! socket read into the client preface, frame headers and payload events for
//! the HTTP/2 driver (`reading.zig`), and keeps across reads only what a
//! frame cut by a read boundary needs. The lane reads every connection into
//! one shared buffer and handles every byte of a read before it reads another
//! connection, so nothing of a connection may stay in that buffer: DATA bytes
//! and header block fragments reach the driver in pieces as they arrive, and
//! only the short frames the driver needs whole wait here, in a buffer of
//! `control_payload_bytes_max` bytes.
//!
//! The reader decides only what framing alone decides: the preface, a length
//! the server never advertised, and the padding and priority fields of DATA
//! and HEADERS. After each frame header the driver, which holds the
//! connection's state, says what the payload is to it (`Disposition`), and
//! the reader reads the payload that way.
//!
//! Invariants:
//! - Events come in wire order. A frame yields `header`, then, by its
//!   disposition, one `control` with its whole payload, `data` or `fragment`
//!   pieces of which the first has `first` and the last has `last`, or
//!   nothing for a skipped payload.
//! - The `credit` of a frame's pieces sums to the frame's length: a piece
//!   carries the payload bytes consumed since the previous piece, the padding
//!   and priority fields included, and the last one also the padding that
//!   follows it. A frame the driver abandons midway (`skipRest`) is read to
//!   its end unread, and `skipRest` returns the credit no piece carried.
//! - A piece or a control payload borrows the input given to `next` or the
//!   reader's own buffer, and is valid until the next call.
//! - `next` consumes every input byte before it returns null.

const std = @import("std");

const h2 = @import("collo_http").http2;
const limits = @import("collo_limits");

/// The longest payload the reader buffers whole: a SETTINGS frame of
/// `h2.Settings.max_settings_per_frame` entries. The other frames it buffers
/// are shorter, and the driver refuses a longer SETTINGS frame at its header.
pub const control_payload_bytes_max: usize = h2.Settings.max_settings_per_frame * h2.setting_wire_len;

const preface = h2.client_connection_preface;

/// What the payload of a frame is to the driver.
pub const Disposition = enum {
    /// One `control` event with the whole payload, which must fit
    /// `control_payload_bytes_max`.
    buffer,
    /// DATA: `data` pieces of its data, without the padding.
    data,
    /// HEADERS or CONTINUATION: `fragment` pieces of its header block
    /// fragment, without the padding and the priority fields.
    fragment,
    /// No event; the payload is consumed unread.
    skip,
};

pub const Piece = struct {
    bytes: []const u8,
    /// The frame's first piece, which may be empty when its region is.
    first: bool,
    /// The frame's last piece: its region ends with it.
    last: bool,
    /// Flow-control credit the piece accounts for (the header's rule).
    credit: u32,
};

pub const Event = union(enum) {
    /// The client preface arrived whole.
    preface,
    /// A frame header arrived whole; the driver calls `accept` before the
    /// next `next`.
    header: h2.FrameHeader,
    control: []const u8,
    data: Piece,
    fragment: Piece,
};

pub const Error = error{
    Http2ProtocolError,
    Http2FrameSizeError,
};

const Phase = enum {
    /// The header arrived and the driver has not called `accept` yet.
    awaiting_disposition,
    buffer,
    pad_length,
    priority,
    region,
    padding,
    skip,
};

const Frame = struct {
    disposition: Disposition = .skip,
    phase: Phase = .awaiting_disposition,
    /// Payload bytes not consumed yet.
    remaining: u32,
    /// Bytes of the frame's padding, once its length byte is read.
    pad_len: u8 = 0,
    /// Priority bytes of HEADERS still to skip.
    priority_left: u8 = 0,
    /// Bytes of the region (data or fragment) still to deliver.
    region_left: u32 = 0,
    /// Payload bytes consumed and not yet carried by a piece's credit.
    uncredited: u32 = 0,
    region_started: bool = false,
    /// Bytes buffered for a `buffer` frame.
    buffered: u8 = 0,
};

pub const State = struct {
    preface_len: u8 = 0,
    header_len: u8 = 0,
    header_bytes: [h2.frame_header_len]u8 = undefined,
    /// The frame whose payload is being read; null between frames.
    frame: ?Frame = null,
    /// The header of the frame whose events come now: from its `header`
    /// event until the next frame's.
    header: h2.FrameHeader = undefined,
    /// The length of the current frame's region once its padding and
    /// priority fields are read.
    region_len: u32 = 0,
    control: [control_payload_bytes_max]u8 = undefined,

    pub fn prefaceComplete(self: *const State) bool {
        return self.preface_len == preface.len;
    }

    /// Whether the reader stands between frames with the preface behind it,
    /// where the driver may read whole frames from the input itself.
    pub fn atFrameBoundary(self: *const State) bool {
        return self.prefaceComplete() and self.header_len == 0 and self.frame == null;
    }

    /// Whether the reader holds part of the preface or of a frame, which
    /// only more bytes from the client complete.
    pub fn midFrame(self: *const State) bool {
        return (self.preface_len != 0 and !self.prefaceComplete()) or self.header_len != 0 or self.frame != null;
    }

    /// Says how to read the payload of the frame whose `header` event came
    /// last. Fails on padding that cannot fit and on priority fields that do
    /// not fit, as RFC 9113 §6.1 requires of DATA and RFC 9113 §6.2 of
    /// HEADERS, which the caller checks no earlier than this.
    pub fn accept(self: *State, disposition: Disposition) Error!void {
        const frame = &self.frame.?;
        std.debug.assert(frame.phase == .awaiting_disposition);
        frame.disposition = disposition;
        switch (disposition) {
            .skip => frame.phase = .skip,
            .buffer => {
                std.debug.assert(frame.remaining <= control_payload_bytes_max);
                frame.phase = .buffer;
            },
            .data, .fragment => {
                if (disposition == .data)
                    std.debug.assert(self.header.frame_type == .data)
                else
                    std.debug.assert(self.header.frame_type == .headers or self.header.frame_type == .continuation);
                const fields = self.header.frame_type != .continuation;
                if (fields and self.header.flags.padded) {
                    if (frame.remaining == 0)
                        return error.Http2ProtocolError;
                    frame.phase = .pad_length;
                } else {
                    try self.enterPriority(frame);
                }
            },
        }
        if (frame.remaining == 0 and frame.phase == .skip)
            self.frame = null;
    }

    /// Consumes the rest of the current frame unread, for a frame whose
    /// stream went away midway, and returns the payload bytes no piece's
    /// credit carried: what the frame still owes the connection's receive
    /// window. The last piece already carried the padding after it, and a
    /// payload already skipped owes nothing more.
    pub fn skipRest(self: *State) u32 {
        const frame = if (self.frame) |*frame| frame else return 0;
        const uncredited = switch (frame.phase) {
            .padding, .skip => 0,
            else => frame.uncredited + frame.remaining,
        };
        frame.uncredited = 0;
        if (frame.remaining == 0)
            self.frame = null
        else
            frame.phase = .skip;
        return uncredited;
    }

    /// The next event `input` holds, consuming its bytes, or null once it is
    /// empty.
    pub fn next(self: *State, input: *[]const u8) Error!?Event {
        if (!self.prefaceComplete())
            return self.readPreface(input);
        while (true) {
            if (self.frame) |*frame| {
                switch (frame.phase) {
                    .awaiting_disposition => unreachable,
                    .buffer => return self.readBuffered(frame, input),
                    .skip, .padding => {
                        const take = takeLen(frame.remaining, input.len);
                        input.* = input.*[take..];
                        frame.remaining -= take;
                        if (frame.remaining != 0)
                            return null;
                        self.frame = null;
                    },
                    .pad_length => {
                        if (input.len == 0)
                            return null;
                        frame.pad_len = input.*[0];
                        input.* = input.*[1..];
                        frame.remaining -= 1;
                        frame.uncredited += 1;
                        // Padding that fills the payload is a connection
                        // error (RFC 9113 §6.1 for DATA, RFC 9113 §6.2 for
                        // HEADERS).
                        if (frame.pad_len > frame.remaining)
                            return error.Http2ProtocolError;
                        try self.enterPriority(frame);
                    },
                    .priority => {
                        const take: u8 = @intCast(takeLen(frame.priority_left, input.len));
                        input.* = input.*[take..];
                        frame.priority_left -= take;
                        frame.remaining -= take;
                        frame.uncredited += take;
                        if (frame.priority_left != 0)
                            return null;
                        self.enterRegion(frame);
                    },
                    .region => {
                        if (frame.region_left != 0 and input.len == 0)
                            return null;
                        return self.readRegion(frame, input);
                    },
                }
                continue;
            }
            if (input.len == 0)
                return null;
            return try self.readHeader(input);
        }
    }

    fn readPreface(self: *State, input: *[]const u8) Error!?Event {
        if (input.len == 0)
            return null;
        const take = @min(preface.len - self.preface_len, input.len);
        // A wrong preface means the peer does not speak HTTP/2, and the close
        // it leads to sends no GOAWAY (RFC 9113 §3.4).
        if (!std.mem.eql(u8, input.*[0..take], preface[self.preface_len..][0..take]))
            return error.Http2ProtocolError;
        input.* = input.*[take..];
        self.preface_len += @intCast(take);
        if (!self.prefaceComplete())
            return null;
        return .preface;
    }

    fn readHeader(self: *State, input: *[]const u8) Error!?Event {
        var raw: *const [h2.frame_header_len]u8 = undefined;
        if (self.header_len == 0 and input.len >= h2.frame_header_len) {
            raw = input.*[0..h2.frame_header_len];
            input.* = input.*[h2.frame_header_len..];
        } else {
            const take = @min(h2.frame_header_len - self.header_len, input.len);
            @memcpy(self.header_bytes[self.header_len..][0..take], input.*[0..take]);
            self.header_len += @intCast(take);
            input.* = input.*[take..];
            if (self.header_len < h2.frame_header_len)
                return null;
            self.header_len = 0;
            raw = &self.header_bytes;
        }
        // The 24-bit length field cannot exceed what `parse` admits.
        const header = h2.FrameHeader.parse(raw) catch unreachable;
        if (header.length > limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES)
            return error.Http2FrameSizeError;
        self.header = header;
        self.region_len = 0;
        self.frame = .{ .remaining = header.length };
        return .{ .header = header };
    }

    fn readBuffered(self: *State, frame: *Frame, input: *[]const u8) ?Event {
        if (frame.buffered == 0 and input.len >= frame.remaining) {
            const payload = input.*[0..frame.remaining];
            input.* = input.*[frame.remaining..];
            self.frame = null;
            return .{ .control = payload };
        }
        if (input.len == 0)
            return null;
        const take = takeLen(frame.remaining, input.len);
        @memcpy(self.control[frame.buffered..][0..take], input.*[0..take]);
        input.* = input.*[take..];
        frame.buffered += @intCast(take);
        frame.remaining -= take;
        if (frame.remaining != 0)
            return null;
        const payload = self.control[0..frame.buffered];
        self.frame = null;
        return .{ .control = payload };
    }

    /// Moves past the padding length to the priority fields of HEADERS that
    /// carry them, or straight to the region. Priority fields that do not fit
    /// before the padding are a frame size error (RFC 9113 §6.2).
    fn enterPriority(self: *State, frame: *Frame) Error!void {
        if (self.header.frame_type == .headers and self.header.flags.priority) {
            if (frame.remaining - frame.pad_len < 5)
                return error.Http2FrameSizeError;
            frame.priority_left = 5;
            frame.phase = .priority;
            return;
        }
        self.enterRegion(frame);
    }

    fn enterRegion(self: *State, frame: *Frame) void {
        frame.region_left = frame.remaining - frame.pad_len;
        self.region_len = frame.region_left;
        frame.phase = .region;
    }

    fn readRegion(self: *State, frame: *Frame, input: *[]const u8) Event {
        const take = takeLen(frame.region_left, input.len);
        const bytes = input.*[0..take];
        input.* = input.*[take..];
        frame.region_left -= take;
        frame.remaining -= take;
        const first = !frame.region_started;
        frame.region_started = true;
        const last = frame.region_left == 0;
        var credit = frame.uncredited + take;
        frame.uncredited = 0;
        const disposition = frame.disposition;
        if (last) {
            // The padding left after the region goes with the last piece.
            credit += frame.remaining;
            if (frame.remaining == 0)
                self.frame = null
            else
                frame.phase = .padding;
        }
        const piece = Piece{ .bytes = bytes, .first = first, .last = last, .credit = credit };
        return switch (disposition) {
            .data => .{ .data = piece },
            .fragment => .{ .fragment = piece },
            .buffer, .skip => unreachable,
        };
    }
};

fn takeLen(wanted: u32, available: usize) u32 {
    return @intCast(@min(@as(usize, wanted), available));
}
