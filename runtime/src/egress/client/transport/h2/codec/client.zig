//! HTTP/2 client connection: concurrent streams over one byte stream that the
//! caller owns. Frames come in through `readNextEvent`, which reads from a
//! blocking reader, or through `processEventFrame` when the caller has read
//! the frame itself; such a caller calls `nextUnprocessedStreamFailure`
//! before each read. Every frame the client sends goes to the caller's
//! writer, and each call yields at most one `Event`.
//!
//! `Http2StreamNotProcessed` promises the peer never processed the stream, so
//! a stream fails with it only when a peer GOAWAY excludes it. Closing for
//! any other reason stops new streams and leaves the open ones to finish.
//!
//! Response bodies reach the consumer as `.body_chunk` events whose flow
//! credit comes back through `ackReceivedData`. The receive windows reopen
//! only then, so a slow consumer slows the peer, and the body bytes it holds
//! stay under the per-stream and per-connection credit caps. A finished
//! stream reports `.end` only after its last credit is acked, because an ack
//! for a stream the connection no longer knows is a connection error.
//!
//! Malformed response content fails only its own stream; framing,
//! flow-control and HPACK violations fail the connection. Each stream counts
//! its plaintext frame bytes in `wire_bytes` and its HTTP payload in `billed`.

const std = @import("std");
const accounting = @import("collo_egress_accounting");
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const collo_limits = @import("collo_limits");
const request_mod = @import("request.zig");
const response = @import("response.zig");
const session_mod = @import("session.zig");

// A stream the client resets stays remembered until the peer ends it,
// because frames the peer sent before seeing the reset still arrive: their
// header blocks must be decoded to keep the HPACK table in sync, and their
// DATA still counts against the connection window (RFC 9113 §5.1). A peer
// that saw the reset before answering sends nothing more, so its entry stays
// until the connection ends. This bounds that memory, and
// `rememberLocalResetStream` states what happens at the bound.
pub const max_local_reset_tombstones: usize = 1024;
// Bounds the frames one read may consume without producing an event, so a
// peer flooding PING, SETTINGS or unknown frames fails the connection
// instead of holding the reader.
pub const max_frames_without_event_per_read: usize = 256;
// Empty CONTINUATION frames never grow the header block, so the byte cap
// alone cannot stop a CONTINUATION flood.
const max_header_block_frames: usize = 64;
const default_max_active_streams: usize = 64;

pub const HeadResult = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    headers: []hpack.Header,
    end_stream: bool,
    wire_bytes: accounting.Bytes = .{},

    pub fn deinit(self: *HeadResult) void {
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
        self.* = undefined;
    }
};

pub const Event = union(enum) {
    head: struct {
        stream_id: u32,
        result: HeadResult,
        /// HPACK length of the final response header block, which drivers
        /// add to their billed-received meter. Interim (1xx) blocks are never
        /// billed and never reported here.
        billed_head_bytes: u64 = 0,
    },
    /// An interim (1xx) header block arrived for the stream. The final head
    /// is still pending, but the origin is alive, so drivers restart their
    /// stall clocks on it; a 103 Early Hints followed by a slow final response
    /// would otherwise look like a silent origin.
    progress: struct {
        stream_id: u32,
        wire_bytes: accounting.Bytes = .{},
    },
    /// The consumer returns `flow_credit` through `ackReceivedData` once it
    /// has taken `bytes`; the receive windows reopen only then.
    /// `update_stream_window` is false on the stream's last chunk, whose
    /// stream window needs no update.
    body_chunk: struct {
        allocator: std.mem.Allocator,
        stream_id: u32,
        bytes: []u8,
        end_stream: bool,
        flow_credit: usize,
        update_stream_window: bool,
        wire_bytes: accounting.Bytes = .{},
    },
    end: struct {
        stream_id: u32,
        wire_bytes: accounting.Bytes = .{},
        /// The stream's cumulative billed bytes: the request header block
        /// and upload DATA payload sent, the final head, trailers and DATA
        /// payload received. Framing, padding, interim 1xx blocks and control
        /// frames are excluded. The pool overwrites `wire_bytes` with the
        /// connection's ciphertext delta and leaves this field alone.
        billed_bytes: accounting.Bytes = .{},
    },
    failure: struct {
        stream_id: u32,
        err: anyerror,
        wire_bytes: accounting.Bytes = .{},
        /// The stream's billed bytes up to the failure, counted as in
        /// `.end.billed_bytes`.
        billed_bytes: accounting.Bytes = .{},
    },

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .head => |*head| head.result.deinit(),
            .progress => {},
            .body_chunk => |*body| body.allocator.free(body.bytes),
            .end => {},
            .failure => {},
        }
        self.* = undefined;
    }
};

pub const IoInterest = enum {
    read,
    write,
};

pub const Limits = struct {
    max_active_streams: usize = default_max_active_streams,
    stream_receive_window: u32 = collo_limits.h2.EGRESS_STREAM_RECV_WINDOW_BYTES,
    connection_receive_window: u32 = collo_limits.h2.EGRESS_CONNECTION_RECV_WINDOW_BYTES,
    receive_window_update_threshold: u32 = collo_limits.h2.EGRESS_RECV_WINDOW_UPDATE_THRESHOLD_BYTES,
    max_pending_body_credit_per_stream: usize = collo_limits.h2.EGRESS_STREAM_RECV_WINDOW_BYTES,
    max_pending_body_credit_per_connection: usize = collo_limits.h2.EGRESS_CONNECTION_RECV_WINDOW_BYTES,

    /// Clamps each receive window to its credit cap. Every byte the peer may
    /// send under an advertised window becomes credit the consumer holds
    /// until it acks, so a window above the cap would let a compliant peer
    /// trip `Http2BodyBackpressureExceeded`.
    pub fn normalized(self: Limits) !Limits {
        if (self.max_active_streams == 0)
            return error.InvalidHttp2Limits;
        if (self.max_pending_body_credit_per_stream == 0)
            return error.InvalidHttp2Limits;
        if (self.max_pending_body_credit_per_connection == 0)
            return error.InvalidHttp2Limits;
        if (self.stream_receive_window > h2.max_window_size or self.connection_receive_window > h2.max_window_size)
            return error.InvalidHttp2Limits;
        var out = self;
        out.max_pending_body_credit_per_stream = @min(
            out.max_pending_body_credit_per_stream,
            out.max_pending_body_credit_per_connection,
        );
        out.stream_receive_window = @intCast(@min(
            @as(usize, out.stream_receive_window),
            out.max_pending_body_credit_per_stream,
        ));
        out.connection_receive_window = @intCast(@min(
            @as(usize, out.connection_receive_window),
            out.max_pending_body_credit_per_connection,
        ));
        out.receive_window_update_threshold = receiveWindowThreshold(
            @min(out.stream_receive_window, out.connection_receive_window),
            out.receive_window_update_threshold,
        );
        return out;
    }
};

pub const default_limits = Limits{};

pub const FrameReadStep = union(enum) {
    frame: Frame,
    wait: IoInterest,
    eof,
};

/// Assembles one frame across nonblocking reads: `readFrom` returns `.wait`
/// mid-frame and resumes where it stopped on the next call.
pub const FrameReader = struct {
    allocator: std.mem.Allocator,
    header_wire: [h2.frame_header_len]u8 = undefined,
    header_len: usize = 0,
    header: ?h2.FrameHeader = null,
    payload: []u8 = &.{},
    payload_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FrameReader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameReader) void {
        if (self.header != null)
            self.allocator.free(self.payload);
        self.* = undefined;
    }

    pub fn readFrom(self: *FrameReader, source: anytype, max_frame_size: u32) !FrameReadStep {
        while (self.header_len < h2.frame_header_len) {
            switch (try source.readStep(self.header_wire[self.header_len..])) {
                .ready => |read_len| self.header_len += read_len,
                .wait => |interest| return .{ .wait = mapIoInterest(interest) },
                .eof => return .eof,
            }
        }

        if (self.header == null) {
            const header = try h2.FrameHeader.parse(&self.header_wire);
            if (header.length > max_frame_size)
                return error.Http2FrameTooLarge;
            self.payload = try self.allocator.alloc(u8, header.length);
            self.payload_len = 0;
            self.header = header;
        }

        while (self.payload_len < self.payload.len) {
            switch (try source.readStep(self.payload[self.payload_len..])) {
                .ready => |read_len| self.payload_len += read_len,
                .wait => |interest| return .{ .wait = mapIoInterest(interest) },
                .eof => return .eof,
            }
        }

        const frame = Frame{
            .allocator = self.allocator,
            .header = self.header.?,
            .payload = self.payload,
        };
        self.header_len = 0;
        self.header = null;
        self.payload = &.{};
        self.payload_len = 0;
        return .{ .frame = frame };
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    session: session_mod.Session,
    limits: Limits,
    send_connection_window: i64 = h2.default_initial_window_size,
    recv_connection_window: ReceiveWindow,
    started: bool = false,
    closing: bool = false,
    active_streams: std.array_list.Aligned(ActiveStream, null) = .empty,
    local_reset_streams: std.array_list.Aligned(u32, null) = .empty,
    /// The header block in progress belongs to the connection, not to the
    /// stream `pending_header_stream_id` names: the HPACK table advances only
    /// as whole blocks decode, so a block that HEADERS begins ends only at
    /// END_HEADERS, even when its stream leaves the active set first.
    pending_header_block: std.array_list.Aligned(u8, null) = .empty,
    pending_header_stream_id: ?u32 = null,
    pending_headers_end_stream: bool = false,
    pending_header_frame_count: usize = 0,
    /// Plaintext bytes of frames that belong to no active stream. While
    /// streams are active those bytes go to the oldest one; otherwise they
    /// wait here for the next stream to open.
    pending_control_bytes: accounting.Bytes = .{},
    pending_body_credit_total: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Connection {
        return try initWithLimits(allocator, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) !Connection {
        const normalized_limits = try limits.normalized();
        var session = try session_mod.Session.init(allocator);
        errdefer session.deinit();
        session.local_settings.initial_window_size = normalized_limits.stream_receive_window;
        return .{
            .allocator = allocator,
            .session = session,
            .limits = normalized_limits,
            .recv_connection_window = ReceiveWindow.initConnection(
                normalized_limits.connection_receive_window,
                normalized_limits.receive_window_update_threshold,
            ),
        };
    }

    pub fn deinit(self: *Connection) void {
        for (self.active_streams.items) |*stream|
            stream.deinit();
        self.active_streams.deinit(self.allocator);
        self.local_reset_streams.deinit(self.allocator);
        self.pending_header_block.deinit(self.allocator);
        self.session.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Connection, writer: *std.Io.Writer) !void {
        if (self.started)
            return;
        const preface = try self.session.encodeConnectionPrefaceAndSettings(self.allocator);
        defer self.allocator.free(preface);
        try writer.writeAll(preface);
        self.pending_control_bytes.addSent(preface.len);
        if (self.recv_connection_window.initialIncrement()) |increment| {
            var update: [h2.frame_header_len + 4]u8 = undefined;
            try h2.encodeWindowUpdateFrame(&update, 0, increment);
            try writer.writeAll(&update);
            self.pending_control_bytes.addSent(update.len);
        }
        self.started = true;
    }

    /// The stream id and the billed request bytes already written at open:
    /// the HPACK header block plus whatever upload DATA payload the initial
    /// windows allowed, which is the whole body when it is small. Upload
    /// bytes written later, as windows open, appear only in the cumulative
    /// `billed_bytes` of the terminal `.end` or `.failure` event.
    pub const OpenedRequest = struct {
        stream_id: u32,
        billed_sent: u64,
    };

    pub fn openRequest(
        self: *Connection,
        writer: *std.Io.Writer,
        head: request_mod.RequestHead,
        max_response_body_bytes: usize,
    ) !u32 {
        return try self.openRequestAlloc(writer, head, max_response_body_bytes, self.allocator);
    }

    pub fn openRequestAlloc(
        self: *Connection,
        writer: *std.Io.Writer,
        head: request_mod.RequestHead,
        max_response_body_bytes: usize,
        result_allocator: std.mem.Allocator,
    ) !u32 {
        return (try self.openRequestAllocMetered(writer, head, max_response_body_bytes, result_allocator)).stream_id;
    }

    pub fn openRequestAllocMetered(
        self: *Connection,
        writer: *std.Io.Writer,
        head: request_mod.RequestHead,
        max_response_body_bytes: usize,
        result_allocator: std.mem.Allocator,
    ) !OpenedRequest {
        try self.start(writer);
        return try self.openRequestWithMode(writer, head, max_response_body_bytes, result_allocator, true);
    }

    pub fn readNextEvent(
        self: *Connection,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) !Event {
        var frames_without_event: usize = 0;
        while (self.active_streams.items.len != 0) {
            if (self.firstReportedCompleteStream()) |index|
                return try self.completeStreamAt(index);
            if (self.nextUnprocessedStreamFailure()) |failure|
                return failure;
            var frame = try readFrame(self.allocator, reader, self.session.local_settings.max_frame_size);
            defer frame.deinit();
            if (try self.processEventFrame(writer, &frame)) |event|
                return event;
            frames_without_event += 1;
            if (frames_without_event > max_frames_without_event_per_read)
                return error.Http2FrameProgressLimitExceeded;
        }
        return error.Http2NoActiveStreams;
    }

    pub fn processEventFrame(
        self: *Connection,
        writer: *std.Io.Writer,
        frame: *Frame,
    ) !?Event {
        if (!self.session.received_peer_settings and frame.header.frame_type != .settings)
            return error.Http2MissingInitialSettings;
        if (self.pending_header_stream_id != null and frame.header.frame_type != .continuation)
            return error.Http2ProtocolError;
        self.recordReceivedFrame(frame);
        if (self.active_streams.items.len == 0)
            return try self.processIdleFrame(writer, frame);

        switch (frame.header.frame_type) {
            .settings => {
                // `end_stream` is flag bit 0x1, the ACK flag on SETTINGS and
                // PING. The server's first frame must be a SETTINGS that is
                // not an ACK (RFC 9113 §3.4).
                if (!self.session.received_peer_settings and frame.header.flags.end_stream)
                    return error.Http2MissingInitialSettings;
                const previous_initial_window = self.session.peer_settings.initial_window_size;
                if (try self.session.handleSettingsFrame(frame.header, frame.payload, self.allocator)) |ack| {
                    defer self.allocator.free(ack);
                    try writer.writeAll(ack);
                    self.recordControlSent(ack.len);
                    try self.applyInitialWindowChange(previous_initial_window, self.session.peer_settings.initial_window_size);
                    try self.writeAvailableUploads(writer);
                    try writer.flush();
                }
            },
            .headers => return try self.receiveHeadersFrame(writer, frame),
            .continuation => return try self.receiveContinuationFrame(writer, frame),
            .data => {
                try frame.header.validateStream();
                const data_payload = try dataPayload(frame);
                const index = self.findStreamIndex(frame.header.stream_id) orelse {
                    if (self.hasLocalResetStream(frame.header.stream_id)) {
                        try self.discardResetData(writer, frame.header.stream_id, frame.payload, frame.header.flags.end_stream);
                        return null;
                    }
                    return error.Http2ProtocolError;
                };
                try self.receiveDataFlowControl(index, frame.payload.len);
                const emit_body = self.active_streams.items[index].head_reported;
                if (emit_body) {
                    self.active_streams.items[index].accumulator.receiveDataNoStore(data_payload, frame.header.flags.end_stream) catch |err| {
                        if (isStreamResponseFailure(err)) {
                            if (frame.payload.len != 0) {
                                const update_bytes = try self.writeConnectionReceiveWindowUpdate(writer, frame.payload.len);
                                self.active_streams.items[index].wire_bytes.addSent(update_bytes);
                                if (update_bytes != 0)
                                    try writer.flush();
                            }
                            return try self.cancelFailedStreamAt(writer, index, err, frame.header.flags.end_stream);
                        }
                        return err;
                    };
                    const flow_credit = frame.payload.len;
                    const update_stream = !frame.header.flags.end_stream;
                    // A padded frame copies its stripped payload before any
                    // credit is registered, so a failed copy leaves none.
                    const padded_copy: ?[]u8 = if (frame.header.flags.padded)
                        try frame.allocator.dupe(u8, data_payload)
                    else
                        null;
                    self.addPendingBodyCredit(index, flow_credit) catch |err| {
                        if (padded_copy) |copy|
                            frame.allocator.free(copy);
                        if (flow_credit != 0) {
                            const update_bytes = try self.writeConnectionReceiveWindowUpdate(writer, flow_credit);
                            self.active_streams.items[index].wire_bytes.addSent(update_bytes);
                            if (update_bytes != 0)
                                try writer.flush();
                        }
                        return try self.cancelFailedStreamAt(writer, index, err, frame.header.flags.end_stream);
                    };
                    // Only the payload is billed; padding and the frame
                    // header are transport cost.
                    self.active_streams.items[index].billed.addReceived(data_payload.len);
                    // Unpadded DATA hands the frame's payload buffer to the
                    // event without a copy, leaving the frame nothing to free.
                    const bytes = padded_copy orelse blk: {
                        const owned = frame.payload;
                        frame.payload = &.{};
                        break :blk owned;
                    };
                    return .{ .body_chunk = .{
                        .allocator = frame.allocator,
                        .stream_id = frame.header.stream_id,
                        .bytes = bytes,
                        .end_stream = frame.header.flags.end_stream,
                        .flow_credit = flow_credit,
                        .update_stream_window = update_stream,
                    } };
                }
                self.active_streams.items[index].accumulator.receiveData(data_payload, frame.header.flags.end_stream) catch |err| {
                    if (isStreamResponseFailure(err)) {
                        if (frame.payload.len != 0) {
                            const update_bytes = try self.writeConnectionReceiveWindowUpdate(writer, frame.payload.len);
                            self.active_streams.items[index].wire_bytes.addSent(update_bytes);
                            if (update_bytes != 0)
                                try writer.flush();
                        }
                        return try self.cancelFailedStreamAt(writer, index, err, frame.header.flags.end_stream);
                    }
                    return err;
                };
                self.active_streams.items[index].billed.addReceived(data_payload.len);
                if (frame.payload.len != 0) {
                    const update_stream = !frame.header.flags.end_stream;
                    const update_bytes = try self.writeReceiveWindowUpdates(writer, index, frame.payload.len, update_stream);
                    self.active_streams.items[index].wire_bytes.addSent(update_bytes);
                    if (update_bytes != 0)
                        try writer.flush();
                }
                if (self.active_streams.items[index].accumulator.complete)
                    return try self.completeStreamAt(index);
            },
            .ping => {
                try frame.header.validateControlStream();
                if (frame.payload.len != 8)
                    return error.Http2FrameSizeError;
                if (!frame.header.flags.end_stream) {
                    var ack: [h2.frame_header_len + 8]u8 = undefined;
                    var ack_header = h2.FrameHeader{
                        .length = 8,
                        .frame_type_raw = @intFromEnum(h2.FrameType.ping),
                        .frame_type = .ping,
                        .flags = h2.Flags.fromByte(0x1),
                        .stream_id = 0,
                    };
                    try ack_header.encode(ack[0..h2.frame_header_len]);
                    @memcpy(ack[h2.frame_header_len..], frame.payload);
                    try writer.writeAll(&ack);
                    self.recordControlSent(ack.len);
                    try writer.flush();
                }
            },
            .window_update => {
                const increment = try h2.parseWindowUpdateIncrement(frame.payload);
                if (frame.header.stream_id == 0) {
                    try self.addSendConnectionWindow(increment);
                } else if (self.findStreamIndex(frame.header.stream_id)) |index| {
                    try self.active_streams.items[index].upload.addStreamWindow(increment);
                }
                try self.writeAvailableUploads(writer);
                try writer.flush();
            },
            .rst_stream => {
                try frame.header.validateStream();
                if (frame.payload.len != 4)
                    return error.Http2FrameSizeError;
                if (self.findStreamIndex(frame.header.stream_id)) |index| {
                    // nginx sends RST_STREAM(NO_ERROR) after a complete
                    // response. It must not fail a stream that has received
                    // everything and only waits for its body-credit acks to
                    // report `.end`.
                    if (self.active_streams.items[index].accumulator.complete)
                        return null;
                    try self.restorePendingConnectionCreditBeforeReset(writer, index);
                    try writer.flush();
                    // REFUSED_STREAM guarantees the server did not process
                    // the request (RFC 9113 §8.7), so the engine may retry it
                    // without the caller noticing.
                    const code = h2.wire.readU32(frame.payload[0..4]);
                    const err: anyerror = if (code == @intFromEnum(h2.ErrorCode.refused_stream))
                        error.Http2StreamRefused
                    else
                        error.Http2StreamReset;
                    return self.failStreamAt(index, err);
                }
                _ = self.removeLocalResetStream(frame.header.stream_id);
            },
            .goaway => {
                try self.session.handleGoawayFrame(frame.header, frame.payload);
                self.closing = true;
                return self.nextUnprocessedStreamFailure();
            },
            .push_promise => return error.Http2ServerPushDisabled,
            .priority => {
                try frame.header.validateStream();
                if (frame.payload.len != 5)
                    return error.Http2FrameSizeError;
            },
            .unknown => {},
        }
        return null;
    }

    fn processIdleFrame(
        self: *Connection,
        writer: *std.Io.Writer,
        frame: *const Frame,
    ) !?Event {
        switch (frame.header.frame_type) {
            .settings => {
                if (!self.session.received_peer_settings and frame.header.flags.end_stream)
                    return error.Http2MissingInitialSettings;
                const previous_initial_window = self.session.peer_settings.initial_window_size;
                if (try self.session.handleSettingsFrame(frame.header, frame.payload, self.allocator)) |ack| {
                    defer self.allocator.free(ack);
                    try writer.writeAll(ack);
                    self.recordControlSent(ack.len);
                    try self.applyInitialWindowChange(previous_initial_window, self.session.peer_settings.initial_window_size);
                    try writer.flush();
                }
            },
            .ping => {
                try frame.header.validateControlStream();
                if (frame.payload.len != 8)
                    return error.Http2FrameSizeError;
                if (!frame.header.flags.end_stream) {
                    var ack: [h2.frame_header_len + 8]u8 = undefined;
                    var ack_header = h2.FrameHeader{
                        .length = 8,
                        .frame_type_raw = @intFromEnum(h2.FrameType.ping),
                        .frame_type = .ping,
                        .flags = h2.Flags.fromByte(0x1),
                        .stream_id = 0,
                    };
                    try ack_header.encode(ack[0..h2.frame_header_len]);
                    @memcpy(ack[h2.frame_header_len..], frame.payload);
                    try writer.writeAll(&ack);
                    self.recordControlSent(ack.len);
                    try writer.flush();
                }
            },
            .window_update => {
                if (frame.header.stream_id != 0) {
                    // WINDOW_UPDATE may still arrive for a stream that has
                    // closed (RFC 9113 §5.1); it is checked for size and
                    // ignored.
                    if (frame.payload.len != 4)
                        return error.Http2FrameSizeError;
                    return null;
                }
                const increment = try h2.parseWindowUpdateIncrement(frame.payload);
                try self.addSendConnectionWindow(increment);
            },
            .headers => return try self.receiveHeadersFrame(writer, frame),
            .continuation => return try self.receiveContinuationFrame(writer, frame),
            .data => {
                try frame.header.validateStream();
                _ = try dataPayload(frame);
                if (!self.hasLocalResetStream(frame.header.stream_id))
                    return error.Http2ProtocolError;
                try self.discardResetData(writer, frame.header.stream_id, frame.payload, frame.header.flags.end_stream);
            },
            .goaway => {
                try self.session.handleGoawayFrame(frame.header, frame.payload);
                self.closing = true;
            },
            .rst_stream => {
                try frame.header.validateStream();
                if (frame.payload.len != 4)
                    return error.Http2FrameSizeError;
                _ = self.removeLocalResetStream(frame.header.stream_id);
            },
            .priority => {
                // PRIORITY is deprecated but legal on any stream in any
                // state, and some servers still send it.
                try frame.header.validateStream();
                if (frame.payload.len != 5)
                    return error.Http2FrameSizeError;
            },
            .unknown => {},
            .push_promise => return error.Http2ProtocolError,
        }
        return null;
    }

    /// Resets an active stream with CANCEL and drops it, returning the body
    /// credit its consumer still held to the connection window. Frames the
    /// peer sent before it saw the reset are still consumed, including the
    /// rest of a header block the stream had begun.
    pub fn cancelStream(self: *Connection, writer: *std.Io.Writer, stream_id: u32) !void {
        const index = self.findStreamIndex(stream_id) orelse return error.Http2UnknownStream;
        try self.restorePendingConnectionCreditBeforeReset(writer, index);
        self.rememberLocalResetStream(stream_id);
        try self.sendCancel(writer, stream_id);
        self.active_streams.items[index].wire_bytes.addSent(h2.frame_header_len + 4);
        // A header block this stream began stays pending, and
        // `endPendingHeaderBlock` decodes and drops it at END_HEADERS.
        var stream = self.active_streams.orderedRemove(index);
        stream.deinit();
    }

    /// Stops opening streams on a connection the peer has not ended with
    /// GOAWAY, such as one with a dead write side, a clean EOF, a poisoned
    /// HPACK encoder or full reset tracking. No open stream fails: the peer
    /// may already have processed any of them, so they finish from what the
    /// peer sends, and only a GOAWAY marks a stream unprocessed.
    pub fn closeWithoutPeerGoaway(self: *Connection) void {
        self.closing = true;
    }

    /// Fails the first open stream above the last stream id of the peer's
    /// GOAWAY. The peer never processed it (RFC 9113 §6.8), so the caller may
    /// replay it on another connection whatever its method. Returns null
    /// before a GOAWAY arrives, and once no open stream is above that id.
    ///
    /// The GOAWAY frame itself reports only one such stream. A caller that
    /// reads frames and passes them to `processEventFrame` calls this before
    /// each read, so the rest surface without waiting for a later frame,
    /// which may never come.
    pub fn nextUnprocessedStreamFailure(self: *Connection) ?Event {
        const last_stream_id = self.session.goaway_last_stream_id orelse return null;
        for (self.active_streams.items, 0..) |stream, index| {
            if (stream.id > last_stream_id)
                return self.failStreamAt(index, error.Http2StreamNotProcessed);
        }
        return null;
    }

    pub fn ackReceivedData(
        self: *Connection,
        writer: *std.Io.Writer,
        stream_id: u32,
        flow_credit: usize,
        update_stream: bool,
    ) !?Event {
        const index = self.findStreamIndex(stream_id) orelse return error.Http2UnknownStream;
        const sent = try self.writeReceiveWindowUpdates(writer, index, flow_credit, update_stream);
        self.active_streams.items[index].wire_bytes.addSent(sent);
        if (flow_credit != 0)
            try self.releasePendingBodyCredit(index, flow_credit);
        if (update_stream)
            try self.maybeGrowStreamReceiveWindow(writer, index);
        // The acked stream goes first when it is ready, so each stream's
        // last ack surfaces its own deferred `.end`. Returning another
        // stream's end here would leave the acked one with no ack left to
        // complete it.
        const acked = &self.active_streams.items[index];
        if (acked.head_reported and acked.accumulator.complete and acked.pending_body_credit == 0)
            return try self.completeStreamAt(index);
        if (self.firstReportedCompleteStream()) |complete_index|
            return try self.completeStreamAt(complete_index);
        return null;
    }

    pub fn hasActiveStreams(self: *const Connection) bool {
        return self.active_streams.items.len != 0;
    }

    /// True when some stream still expects bytes from the peer. Streams that
    /// already received END_STREAM but whose `.end` event is deferred behind
    /// the body-credit ack do not count: they finish from received data.
    pub fn hasIncompleteRemoteStreams(self: *const Connection) bool {
        for (self.active_streams.items) |*stream| {
            if (!stream.accumulator.complete)
                return true;
        }
        return false;
    }

    pub fn canOpenStream(self: *const Connection) bool {
        if (self.closing or self.session.goaway_last_stream_id != null)
            return false;
        if (self.active_streams.items.len >= self.limits.max_active_streams)
            return false;
        if (self.session.peer_settings.max_concurrent_streams) |limit|
            return self.active_streams.items.len < limit;
        return true;
    }

    fn openRequestWithMode(
        self: *Connection,
        writer: *std.Io.Writer,
        head: request_mod.RequestHead,
        max_response_body_bytes: usize,
        result_allocator: std.mem.Allocator,
        reusable: bool,
    ) !OpenedRequest {
        if (self.closing)
            return error.Http2ConnectionClosed;
        if (!self.canOpenStream())
            return error.Http2MaxConcurrentStreamsExceeded;

        var accumulator = response.ResponseAccumulator.init(result_allocator, max_response_body_bytes);
        errdefer accumulator.deinit();
        if (std.mem.eql(u8, head.method, "HEAD"))
            accumulator.body_forbidden = true;

        const stream_id = try self.session.openStream();
        var encoded = self.session.encodeRequest(stream_id, .{
            .method = head.method,
            .scheme = head.scheme,
            .authority = head.authority,
            .path = head.path,
            .headers = head.headers,
            .body = &.{},
            .end_stream_after_headers = head.body.len == 0,
            .declared_content_length = if (head.body.len != 0) head.body.len else null,
        }) catch |err| {
            // A poisoned encoder fails every later request, so the connection
            // takes no new streams while the open ones finish.
            if (isHpackEncoderFatal(err))
                self.closeWithoutPeerGoaway();
            return err;
        };
        defer encoded.deinit();
        try writer.writeAll(encoded.wire);
        var stream = ActiveStream{
            .id = stream_id,
            .accumulator = accumulator,
            .upload = UploadState.init(self, head.body),
            .recv_window = ReceiveWindow.initStream(
                self.limits.stream_receive_window,
                self.limits.receive_window_update_threshold,
            ),
            .reusable = reusable,
            .pending_credit_cap = self.limits.max_pending_body_credit_per_stream,
        };
        stream.wire_bytes.add(self.pending_control_bytes);
        self.pending_control_bytes = .{};
        stream.wire_bytes.addSent(encoded.wire.len);
        // The request side bills the HPACK block as sent; the preface,
        // SETTINGS and frame headers are transport cost.
        stream.billed.addSent(encoded.header_block_len);
        var stream_owned = true;
        errdefer if (stream_owned)
            stream.deinit();
        const upload = try stream.upload.writeAvailable(writer, stream_id);
        stream.wire_bytes.addSent(upload.wire);
        stream.billed.addSent(upload.payload);
        const billed_sent = stream.billed.sent;
        try writer.flush();
        try self.active_streams.append(self.allocator, stream);
        stream_owned = false;
        return .{ .stream_id = stream_id, .billed_sent = billed_sent };
    }

    fn applyInitialWindowChange(self: *Connection, previous: u32, next: u32) !void {
        for (self.active_streams.items) |*stream|
            try stream.upload.applyInitialWindowChange(previous, next);
    }

    fn writeAvailableUploads(self: *Connection, writer: *std.Io.Writer) !void {
        for (self.active_streams.items) |*stream| {
            const written = try stream.upload.writeAvailable(writer, stream.id);
            stream.wire_bytes.addSent(written.wire);
            // Upload DATA payload is billed; its 9-byte frame headers are not.
            stream.billed.addSent(written.payload);
        }
    }

    fn addSendConnectionWindow(self: *Connection, increment: u32) !void {
        try addWindow(&self.send_connection_window, increment);
    }

    fn findStreamIndex(self: *const Connection, stream_id: u32) ?usize {
        for (self.active_streams.items, 0..) |stream, index| {
            if (stream.id == stream_id)
                return index;
        }
        return null;
    }

    /// Begins a header block for an active stream, or for a reset stream
    /// whose response was already on the way. HEADERS for any other stream is
    /// a connection error.
    fn receiveHeadersFrame(self: *Connection, writer: *std.Io.Writer, frame: *const Frame) !?Event {
        // `processEventFrame` refuses every frame but CONTINUATION while a
        // block is pending.
        std.debug.assert(self.pending_header_stream_id == null);
        try frame.header.validateStream();
        const header_block = try headersBlockFragment(frame);
        const stream_id = frame.header.stream_id;
        if (self.findStreamIndex(stream_id) == null and !self.hasLocalResetStream(stream_id))
            return error.Http2ProtocolError;
        self.pending_header_stream_id = stream_id;
        self.pending_headers_end_stream = frame.header.flags.end_stream;
        self.pending_header_frame_count = 1;
        try self.pending_header_block.appendSlice(self.allocator, header_block);
        if (!frame.header.flags.end_headers_or_ack)
            return null;
        return try self.endPendingHeaderBlock(writer);
    }

    fn receiveContinuationFrame(self: *Connection, writer: *std.Io.Writer, frame: *const Frame) !?Event {
        const stream_id = self.pending_header_stream_id orelse return error.Http2ProtocolError;
        if (frame.header.stream_id != stream_id)
            return error.Http2ProtocolError;
        try self.recordPendingHeaderContinuationFrame();
        try self.pending_header_block.appendSlice(self.allocator, frame.payload);
        if (self.pending_header_block.items.len > collo_limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX)
            return error.Http2HeaderBlockTooLarge;
        if (!frame.header.flags.end_headers_or_ack)
            return null;
        return try self.endPendingHeaderBlock(writer);
    }

    /// Ends the pending block at END_HEADERS. A stream still active receives
    /// it. A stream that has left the active set, such as one reset before
    /// the block began or canceled while the block waited for CONTINUATION,
    /// has its block decoded and dropped; a block that carried END_STREAM
    /// also ends the stream's reset tracking, since the peer sends nothing
    /// more on it.
    fn endPendingHeaderBlock(self: *Connection, writer: *std.Io.Writer) !?Event {
        const stream_id = self.pending_header_stream_id.?;
        if (self.findStreamIndex(stream_id)) |index|
            return try self.finishHeadersOrFailStream(writer, index);
        if (try self.discardPendingHeaderBlock())
            _ = self.removeLocalResetStream(stream_id);
        return null;
    }

    fn finishPendingHeaderBlock(self: *Connection, index: usize) !void {
        defer self.clearPendingHeaderBlock();
        try finishHeaderBlock(
            self.allocator,
            &self.session,
            &self.active_streams.items[index].accumulator,
            self.pending_header_block.items,
            self.pending_headers_end_stream,
        );
    }

    fn finishHeadersOrFailStream(self: *Connection, writer: *std.Io.Writer, index: usize) !?Event {
        const remote_complete = self.pending_headers_end_stream;
        // Read before finishing clears the pending block. The billed unit is
        // the HPACK block across HEADERS and CONTINUATION, with padding and
        // the priority section already stripped.
        const block_len = self.pending_header_block.items.len;
        self.finishPendingHeaderBlock(index) catch |err| {
            if (isStreamResponseFailure(err))
                return try self.cancelFailedStreamAt(writer, index, err, remote_complete);
            return err;
        };
        if (self.active_streams.items[index].accumulator.status_code == null) {
            // No status after a successful finish means an interim (1xx)
            // block, which the accumulator drops; 101 and a 1xx with
            // END_STREAM have already failed. It surfaces as progress so the
            // driver sees the origin is alive, and it is not billed.
            return .{ .progress = .{ .stream_id = self.active_streams.items[index].id } };
        }
        if (!self.active_streams.items[index].head_reported) {
            self.active_streams.items[index].billed.addReceived(block_len);
            return try self.reportHeadAt(index, remote_complete, block_len);
        }
        // A block after the reported head is the trailer block, already
        // validated inside finishPendingHeaderBlock.
        self.active_streams.items[index].billed.addReceived(block_len);
        if (self.active_streams.items[index].accumulator.complete) {
            // Trailers can end a stream whose consumer still holds unacked
            // flow credit. Removing the stream now would orphan those acks,
            // which fail the connection as acks for an unknown stream, and
            // would leak the connection's pending-credit budget. The `.end`
            // waits for the last credit ack, as it does for a stream ending
            // in DATA with END_STREAM.
            if (self.active_streams.items[index].pending_body_credit == 0)
                return try self.completeStreamAt(index);
        }
        return null;
    }

    fn cancelFailedStreamAt(self: *Connection, writer: *std.Io.Writer, index: usize, err: anyerror, remote_complete: bool) !Event {
        const stream_id = self.active_streams.items[index].id;
        try self.restorePendingConnectionCreditBeforeReset(writer, index);
        if (!remote_complete)
            self.rememberLocalResetStream(stream_id);
        try self.sendCancel(writer, stream_id);
        self.active_streams.items[index].wire_bytes.addSent(h2.frame_header_len + 4);
        return self.failStreamAt(index, err);
    }

    /// Decodes a reset stream's header block only to keep the HPACK dynamic
    /// table in step with the peer's encoder, then drops it. Returns whether
    /// the block ended the stream.
    fn discardPendingHeaderBlock(self: *Connection) !bool {
        defer self.clearPendingHeaderBlock();
        const end_stream = self.pending_headers_end_stream;
        var decoded = try self.session.decoder.decodeBlock(
            self.allocator,
            self.pending_header_block.items,
            response.max_response_header_count,
            collo_limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX,
        );
        defer decoded.deinit(self.allocator);
        return end_stream;
    }

    fn discardResetData(self: *Connection, writer: *std.Io.Writer, stream_id: u32, payload: []const u8, end_stream: bool) !void {
        try self.recv_connection_window.receive(payload.len);
        if (payload.len != 0) {
            const update_bytes = try self.writeConnectionReceiveWindowUpdate(writer, payload.len);
            if (update_bytes != 0) {
                self.recordControlSent(update_bytes);
                try writer.flush();
            }
        }
        if (end_stream)
            _ = self.removeLocalResetStream(stream_id);
    }

    fn sendCancel(self: *Connection, writer: *std.Io.Writer, stream_id: u32) !void {
        _ = self;
        var wire: [h2.frame_header_len + 4]u8 = undefined;
        try h2.encodeRstStreamFrame(&wire, stream_id, .cancel);
        try writer.writeAll(&wire);
        try writer.flush();
    }

    fn recordReceivedFrame(self: *Connection, frame: *const Frame) void {
        const len = h2.frame_header_len + frame.payload.len;
        if (frame.header.stream_id != 0) {
            if (self.findStreamIndex(frame.header.stream_id)) |index| {
                self.active_streams.items[index].wire_bytes.addReceived(len);
                return;
            }
        }
        self.recordControlReceived(len);
    }

    fn recordControlReceived(self: *Connection, len: usize) void {
        if (self.active_streams.items.len != 0) {
            self.active_streams.items[0].wire_bytes.addReceived(len);
            return;
        }
        self.pending_control_bytes.addReceived(len);
    }

    fn recordControlSent(self: *Connection, len: usize) void {
        if (self.active_streams.items.len != 0) {
            self.active_streams.items[0].wire_bytes.addSent(len);
            return;
        }
        self.pending_control_bytes.addSent(len);
    }

    fn recordPendingHeaderContinuationFrame(self: *Connection) !void {
        self.pending_header_frame_count += 1;
        if (self.pending_header_frame_count > max_header_block_frames)
            return error.Http2HeaderContinuationLimitExceeded;
    }

    fn clearPendingHeaderBlock(self: *Connection) void {
        self.pending_header_block.clearRetainingCapacity();
        self.pending_header_stream_id = null;
        self.pending_headers_end_stream = false;
        self.pending_header_frame_count = 0;
    }

    fn hasLocalResetStream(self: *const Connection, stream_id: u32) bool {
        for (self.local_reset_streams.items) |candidate| {
            if (candidate == stream_id)
                return true;
        }
        return false;
    }

    /// At `max_local_reset_tombstones` the oldest entry makes room, since the
    /// newest reset is the one whose frames are most likely still in flight,
    /// and the connection stops opening streams, so only the streams already
    /// open can evict more. The oldest is spared when its discarded header
    /// block still waits for CONTINUATION, because that stream's frames are
    /// arriving now; the next oldest goes instead. When the entry cannot be
    /// allocated the stream stays untracked, so a late HEADERS or DATA frame
    /// for it fails the connection, and the connection stops opening streams
    /// in that case too. A header block already pending still completes,
    /// because its CONTINUATION frames need no entry.
    fn rememberLocalResetStream(self: *Connection, stream_id: u32) void {
        if (self.hasLocalResetStream(stream_id))
            return;
        if (self.local_reset_streams.items.len >= max_local_reset_tombstones) {
            comptime std.debug.assert(max_local_reset_tombstones >= 2);
            const evicted: usize = if (self.pending_header_stream_id == self.local_reset_streams.items[0]) 1 else 0;
            _ = self.local_reset_streams.orderedRemove(evicted);
            self.closeWithoutPeerGoaway();
        }
        self.local_reset_streams.append(self.allocator, stream_id) catch {
            self.closeWithoutPeerGoaway();
        };
    }

    fn removeLocalResetStream(self: *Connection, stream_id: u32) bool {
        for (self.local_reset_streams.items, 0..) |candidate, index| {
            if (candidate != stream_id)
                continue;
            _ = self.local_reset_streams.orderedRemove(index);
            return true;
        }
        return false;
    }

    fn completeStreamAt(self: *Connection, index: usize) !Event {
        var stream = self.active_streams.orderedRemove(index);
        defer stream.deinit();
        const wire_bytes = stream.wire_bytes;
        _ = stream.accumulator.status_code orelse return error.Http2ResponseIncomplete;
        return .{ .end = .{
            .stream_id = stream.id,
            .wire_bytes = wire_bytes,
            .billed_bytes = stream.billed,
        } };
    }

    fn reportHeadAt(self: *Connection, index: usize, end_stream: bool, billed_head_bytes: usize) !Event {
        const stream = &self.active_streams.items[index];
        stream.head_reported = true;
        const headers = try cloneHeaders(stream.accumulator.allocator, stream.accumulator.headers.items);
        errdefer freeHeaders(stream.accumulator.allocator, headers);
        return .{ .head = .{
            .stream_id = stream.id,
            .result = .{
                .allocator = stream.accumulator.allocator,
                .status_code = stream.accumulator.status_code orelse return error.Http2ResponseIncomplete,
                .headers = headers,
                .end_stream = end_stream,
            },
            .billed_head_bytes = billed_head_bytes,
        } };
    }

    fn failStreamAt(self: *Connection, index: usize, err: anyerror) Event {
        var stream = self.active_streams.orderedRemove(index);
        defer stream.deinit();
        return .{ .failure = .{
            .stream_id = stream.id,
            .err = err,
            .wire_bytes = stream.wire_bytes,
            .billed_bytes = stream.billed,
        } };
    }

    fn firstReportedCompleteStream(self: *Connection) ?usize {
        for (self.active_streams.items, 0..) |stream, index| {
            if (stream.head_reported and stream.accumulator.complete and stream.pending_body_credit == 0)
                return index;
        }
        return null;
    }

    /// A consumer that has drained at least one full window of body and
    /// holds no outstanding credit keeps pace with the wire, so the stream
    /// window, not the network, limits throughput to window/RTT. The window
    /// doubles toward the stream's fair share of the connection window; the
    /// connection window and credit caps remain the memory bounds.
    fn maybeGrowStreamReceiveWindow(self: *Connection, writer: *std.Io.Writer, stream_index: usize) !void {
        const stream = &self.active_streams.items[stream_index];
        if (!stream.head_reported or stream.accumulator.complete)
            return;
        if (stream.pending_body_credit != 0)
            return;
        const target = stream.recv_window.target;
        if (stream.accumulator.received_body_bytes < target)
            return;
        const fair_share: u32 = @intCast(@min(
            @as(usize, self.limits.connection_receive_window),
            @max(
                @as(usize, self.limits.stream_receive_window),
                @as(usize, self.limits.connection_receive_window) / @max(@as(usize, 1), self.active_streams.items.len),
            ),
        ));
        if (target >= fair_share)
            return;
        const delta = @min(target, fair_share - target);
        if (delta == 0)
            return;
        const sent = try writeWindowUpdate(writer, stream.id, delta);
        stream.wire_bytes.addSent(sent);
        try stream.recv_window.grow(delta);
        stream.pending_credit_cap += delta;
    }

    fn writeReceiveWindowUpdates(
        self: *Connection,
        writer: *std.Io.Writer,
        stream_index: usize,
        payload_len: usize,
        update_stream: bool,
    ) !usize {
        var sent: usize = try self.writeConnectionReceiveWindowUpdate(writer, payload_len);
        if (!update_stream)
            return sent;
        if (try self.active_streams.items[stream_index].recv_window.record(payload_len)) |increment|
            sent += try writeWindowUpdate(writer, self.active_streams.items[stream_index].id, increment);
        return sent;
    }

    fn receiveDataFlowControl(self: *Connection, stream_index: usize, payload_len: usize) !void {
        try self.recv_connection_window.receive(payload_len);
        try self.active_streams.items[stream_index].recv_window.receive(payload_len);
    }

    fn writeConnectionReceiveWindowUpdate(
        self: *Connection,
        writer: *std.Io.Writer,
        payload_len: usize,
    ) !usize {
        if (try self.recv_connection_window.record(payload_len)) |increment|
            return try writeWindowUpdate(writer, 0, increment);
        return 0;
    }

    fn restorePendingConnectionCreditBeforeReset(self: *Connection, writer: *std.Io.Writer, stream_index: usize) !void {
        const pending = self.active_streams.items[stream_index].pending_body_credit;
        if (pending == 0)
            return;
        const sent = try self.writeConnectionReceiveWindowUpdate(writer, pending);
        self.active_streams.items[stream_index].wire_bytes.addSent(sent);
        try self.releasePendingBodyCredit(stream_index, pending);
    }

    fn addPendingBodyCredit(self: *Connection, stream_index: usize, bytes: usize) !void {
        const next_total = try std.math.add(usize, self.pending_body_credit_total, bytes);
        if (next_total > self.limits.max_pending_body_credit_per_connection)
            return error.Http2BodyBackpressureExceeded;
        try self.active_streams.items[stream_index].addPendingBodyCredit(
            bytes,
            self.active_streams.items[stream_index].pending_credit_cap,
        );
        self.pending_body_credit_total = next_total;
    }

    fn releasePendingBodyCredit(self: *Connection, stream_index: usize, bytes: usize) !void {
        if (bytes > self.pending_body_credit_total)
            return error.Http2FlowControlError;
        try self.active_streams.items[stream_index].releasePendingBodyCredit(bytes);
        self.pending_body_credit_total -= bytes;
    }
};

fn isStreamResponseFailure(err: anyerror) bool {
    return switch (err) {
        error.FetchResponseTooLarge,
        error.Http2ResponseBodyForbidden,
        error.Http2ContentLengthMismatch,
        error.UnsupportedCompressionMethod,
        error.UnsupportedFetchProtocolUpgrade,
        // Malformed response content (RFC 9113 §8.1.1) fails only its own
        // stream, and the connection keeps serving every other fetch on it.
        // HpackHeaderListTooLarge is safe at stream scope because decodeBlock
        // decodes an oversized list in full, keeping the dynamic table in
        // sync. HpackOutputTooSmall and Http2HeaderBlockTooLarge, the wire
        // cap checked before decoding, still fail the connection.
        error.Http2MalformedResponse,
        error.InvalidHttp2ResponseHeader,
        error.HpackHeaderListTooLarge,
        => true,
        else => false,
    };
}

fn isHpackEncoderFatal(err: anyerror) bool {
    return switch (err) {
        error.HpackEncoderPoisoned => true,
        else => false,
    };
}

fn cloneHeaders(allocator: std.mem.Allocator, input: []const hpack.Header) ![]hpack.Header {
    const out = try allocator.alloc(hpack.Header, input.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer freeHeaderFields(allocator, out[0..initialized]);
    for (input, 0..) |header, index| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        out[index] = .{ .name = name, .value = value };
        initialized += 1;
    }
    return out;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []hpack.Header) void {
    freeHeaderFields(allocator, headers);
    allocator.free(headers);
}

fn freeHeaderFields(allocator: std.mem.Allocator, headers: []hpack.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
}

const ActiveStream = struct {
    id: u32,
    accumulator: response.ResponseAccumulator,
    upload: UploadState,
    recv_window: ReceiveWindow,
    reusable: bool,
    head_reported: bool = false,
    pending_body_credit: usize = 0,
    /// Most body credit the consumer may hold unacked on this stream. It
    /// starts at the per-stream budget and grows with the stream's receive
    /// window; the connection-level cap stays the memory bound.
    pending_credit_cap: usize = 0,
    wire_bytes: accounting.Bytes = .{},
    /// The HTTP payload this stream moved, counted as `Event.end.billed_bytes`
    /// describes. It stays apart from `wire_bytes` and from the connection's
    /// ciphertext delta: both already include the payload, so adding it to
    /// either would bill the payload twice.
    billed: accounting.Bytes = .{},

    fn deinit(self: *ActiveStream) void {
        self.accumulator.deinit();
        self.* = undefined;
    }

    fn addPendingBodyCredit(self: *ActiveStream, bytes: usize, limit: usize) !void {
        const next = try std.math.add(usize, self.pending_body_credit, bytes);
        if (next > limit)
            return error.Http2BodyBackpressureExceeded;
        self.pending_body_credit = next;
    }

    fn releasePendingBodyCredit(self: *ActiveStream, bytes: usize) !void {
        if (bytes > self.pending_body_credit)
            return error.Http2FlowControlError;
        self.pending_body_credit -= bytes;
    }
};

const ReceiveWindow = struct {
    target: u32,
    threshold: u32,
    configured_threshold: u32,
    pending: u32 = 0,
    available: i64,

    fn initStream(target: u32, threshold: u32) ReceiveWindow {
        return .{
            .target = target,
            .threshold = receiveWindowThreshold(target, threshold),
            .configured_threshold = threshold,
            .available = target,
        };
    }

    /// The connection window starts at the protocol default and only
    /// WINDOW_UPDATE changes it, upward, so a smaller target still begins
    /// with the default available (RFC 9113 §6.9.2).
    fn initConnection(target: u32, threshold: u32) ReceiveWindow {
        return .{
            .target = target,
            .threshold = receiveWindowThreshold(target, threshold),
            .configured_threshold = threshold,
            .available = @max(target, h2.default_initial_window_size),
        };
    }

    /// Raises the advertised window. The update threshold scales with it so
    /// batching stays proportional.
    fn grow(self: *ReceiveWindow, delta: u32) !void {
        self.target +|= delta;
        self.available = try addReceiveWindowAvailable(self.available, delta);
        self.threshold = receiveWindowThreshold(self.target, self.configured_threshold);
    }

    fn initialIncrement(self: ReceiveWindow) ?u32 {
        if (self.target <= h2.default_initial_window_size)
            return null;
        return self.target - h2.default_initial_window_size;
    }

    fn record(self: *ReceiveWindow, payload_len: usize) !?u32 {
        if (payload_len == 0)
            return null;
        if (payload_len > h2.max_window_size)
            return error.Http2FlowControlError;
        self.pending = std.math.add(u32, self.pending, @intCast(payload_len)) catch
            return error.Http2FlowControlError;
        if (self.pending < self.threshold)
            return null;
        const increment = self.pending;
        self.pending = 0;
        self.available = try addReceiveWindowAvailable(self.available, increment);
        return increment;
    }

    fn receive(self: *ReceiveWindow, payload_len: usize) !void {
        if (payload_len == 0)
            return;
        if (payload_len > h2.max_window_size)
            return error.Http2FlowControlError;
        self.available -= @intCast(payload_len);
        if (self.available < 0)
            return error.Http2FlowControlError;
    }
};

fn addReceiveWindowAvailable(current: i64, increment: u32) !i64 {
    const next = current + @as(i64, increment);
    if (next > h2.max_window_size)
        return error.Http2FlowControlError;
    return next;
}

const UploadState = struct {
    /// Points at the owning connection, whose send window and peer SETTINGS
    /// every stream shares, so a `Connection` must not move while it has
    /// active streams.
    connection: *Connection,
    body: []const u8,
    offset: usize = 0,
    stream_window: i64,

    fn init(connection: *Connection, body: []const u8) UploadState {
        return .{
            .connection = connection,
            .body = body,
            .stream_window = connection.session.peer_settings.initial_window_size,
        };
    }

    /// A new SETTINGS_INITIAL_WINDOW_SIZE shifts every open stream's send
    /// window by the difference, which may leave it negative
    /// (RFC 9113 §6.9.2).
    fn applyInitialWindowChange(self: *UploadState, previous: u32, next: u32) !void {
        self.stream_window += @as(i64, next) - @as(i64, previous);
        if (self.stream_window > h2.max_window_size)
            return error.Http2FlowControlError;
    }

    fn addConnectionWindow(self: *UploadState, increment: u32) !void {
        try self.connection.addSendConnectionWindow(increment);
    }

    fn addStreamWindow(self: *UploadState, increment: u32) !void {
        try addWindow(&self.stream_window, increment);
    }

    /// Bytes one upload pass wrote: `wire` counts frame headers and payload
    /// for the plaintext wire counter, `payload` counts the DATA payload
    /// alone, which is billed.
    const Written = struct {
        wire: usize = 0,
        payload: usize = 0,
    };

    fn writeAvailable(
        self: *UploadState,
        writer: *std.Io.Writer,
        stream_id: u32,
    ) !Written {
        var written = Written{};
        while (self.offset < self.body.len and self.connection.send_connection_window > 0 and self.stream_window > 0) {
            const window_budget: usize = @intCast(@min(self.connection.send_connection_window, self.stream_window));
            const frame_budget: usize = @intCast(self.connection.session.peer_settings.max_frame_size);
            const chunk_len = @min(@min(window_budget, frame_budget), self.body.len - self.offset);
            const is_last = self.offset + chunk_len == self.body.len;
            written.wire += try writeDataFrame(
                writer,
                stream_id,
                self.body[self.offset..][0..chunk_len],
                is_last,
            );
            written.payload += chunk_len;
            self.offset += chunk_len;
            self.connection.send_connection_window -= @intCast(chunk_len);
            self.stream_window -= @intCast(chunk_len);
        }
        return written;
    }
};

fn addWindow(window: *i64, increment: u32) !void {
    window.* += increment;
    if (window.* > h2.max_window_size)
        return error.Http2FlowControlError;
}

// At most half the window, so the update goes out while the peer still has
// window left and a steady sender never stalls on the batching.
fn receiveWindowThreshold(target: u32, configured: u32) u32 {
    const half = @max(@as(u32, 1), target / 2);
    if (configured == 0)
        return half;
    return @min(configured, half);
}

fn writeWindowUpdate(writer: *std.Io.Writer, stream_id: u32, increment: u32) !usize {
    var update: [h2.frame_header_len + 4]u8 = undefined;
    try h2.encodeWindowUpdateFrame(&update, stream_id, increment);
    try writer.writeAll(&update);
    return update.len;
}

fn writeDataFrame(writer: *std.Io.Writer, stream_id: u32, payload: []const u8, end_stream: bool) !usize {
    var header_wire: [h2.frame_header_len]u8 = undefined;
    var header = h2.FrameHeader{
        .length = @intCast(payload.len),
        .frame_type_raw = @intFromEnum(h2.FrameType.data),
        .frame_type = .data,
        .flags = h2.Flags.fromByte(if (end_stream) 0x1 else 0),
        .stream_id = stream_id,
    };
    try header.encode(&header_wire);
    try writer.writeAll(&header_wire);
    if (payload.len != 0)
        try writer.writeAll(payload);
    return h2.frame_header_len + payload.len;
}

pub const Frame = struct {
    allocator: std.mem.Allocator,
    header: h2.FrameHeader,
    payload: []u8,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

fn headersBlockFragment(frame: *const Frame) ![]const u8 {
    var start: usize = 0;
    var pad_len: usize = 0;
    if (frame.header.flags.padded) {
        if (frame.payload.len == 0)
            return error.Http2FrameSizeError;
        pad_len = frame.payload[0];
        start += 1;
    }
    if (frame.header.flags.priority) {
        if (frame.payload.len < start + 5)
            return error.Http2FrameSizeError;
        start += 5;
    }
    if (pad_len > frame.payload.len -| start)
        return error.Http2ProtocolError;
    return frame.payload[start .. frame.payload.len - pad_len];
}

fn dataPayload(frame: *const Frame) ![]const u8 {
    if (!frame.header.flags.padded)
        return frame.payload;
    if (frame.payload.len == 0)
        return error.Http2FrameSizeError;
    const pad_len: usize = frame.payload[0];
    if (pad_len > frame.payload.len - 1)
        return error.Http2ProtocolError;
    return frame.payload[1 .. frame.payload.len - pad_len];
}

fn mapIoInterest(interest: anytype) IoInterest {
    return switch (interest) {
        .read => .read,
        .write => .write,
    };
}

fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_frame_size: u32) !Frame {
    var header_wire: [h2.frame_header_len]u8 = undefined;
    try reader.readSliceAll(&header_wire);
    const header = try h2.FrameHeader.parse(&header_wire);
    if (header.length > max_frame_size)
        return error.Http2FrameTooLarge;
    const payload = try allocator.alloc(u8, header.length);
    errdefer allocator.free(payload);
    if (payload.len != 0)
        try reader.readSliceAll(payload);
    return .{ .allocator = allocator, .header = header, .payload = payload };
}

fn finishHeaderBlock(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    accumulator: *response.ResponseAccumulator,
    block: []const u8,
    end_stream: bool,
) !void {
    if (block.len > collo_limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX)
        return error.Http2HeaderBlockTooLarge;
    var decoded = try session.decoder.decodeBlock(
        allocator,
        block,
        response.max_response_header_count,
        collo_limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX,
    );
    defer decoded.deinit(allocator);
    if (accumulator.status_code != null) {
        if (!end_stream)
            return error.Http2ProtocolError;
        try response.validateTrailers(decoded.headers);
        try accumulator.finish();
        return;
    }
    try accumulator.receiveHead(try response.parseResponseHead(decoded.headers, end_stream));
}
