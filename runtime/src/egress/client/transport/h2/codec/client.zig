//! HTTP/2 client connection: concurrent streams over one byte stream that the
//! caller owns. The caller reads each frame itself (`FrameReader`), hands it
//! to `processEventFrame`, and calls `nextUnprocessedStreamFailure` before
//! each read. Every frame the client sends goes to the caller's writer, and
//! each call yields at most one `Event`.
//!
//! The client preface comes before anything else the connection writes
//! (RFC 9113 §3.4): `start` writes it, and `openRequest` and
//! `processEventFrame` start the connection first, so a peer frame read
//! before the first request is answered only after the preface.
//!
//! `Http2StreamNotProcessed` promises the peer never processed the stream, so
//! a stream fails with it only when a peer GOAWAY excludes it. Closing for
//! any other reason stops new streams and leaves the open ones to finish.
//!
//! A final response head is decoded once, with the connection's allocator,
//! and the `.head` event hands that block to the caller. Response bodies
//! reach the consumer as `.body_chunk` events whose flow credit comes back
//! through `ackReceivedData`. The receive windows reopen only then, so a slow
//! consumer slows the peer, and the body bytes it holds stay under the
//! per-stream and per-connection credit caps. A finished stream reports
//! `.end` only after its last credit is acked, because an ack for a stream
//! the connection no longer knows is a connection error.
//!
//! Malformed response content fails only its own stream; framing,
//! flow-control and HPACK violations fail the connection.

const std = @import("std");
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const collo_limits = @import("collo_limits");
const request_mod = @import("request.zig");
const response = @import("response.zig");
const session_mod = @import("session.zig");

// A stream the client resets before the peer ended it stays remembered until
// the peer ends it, because frames the peer sent before seeing the reset
// still arrive: their header blocks must be decoded to keep the HPACK table
// in sync, and their DATA still counts against the connection window
// (RFC 9113 §5.1). A peer that saw the reset before answering sends nothing
// more, so its entry stays until the connection ends. A stream the peer had
// already ended leaves no entry (`resetStreamAt`). This bounds that memory,
// and `rememberLocalResetStream` states what happens at the bound.
pub const max_local_reset_tombstones: usize = 1024;
// The most frames a caller that reads frames itself lets one read consume
// without an event before it fails the connection
// (`pool.zig:Pool.readEntryEvent`), so a peer flooding PING, SETTINGS or
// unknown frames cannot hold the reader. The codec handles one frame per
// call and counts nothing.
pub const max_frames_without_event_per_read: usize = 256;
// Empty CONTINUATION frames never grow the header block, so the byte cap
// alone cannot stop a CONTINUATION flood.
const max_header_block_frames: usize = 64;
const default_max_active_streams: usize = 64;

pub const Event = union(enum) {
    /// The stream's final response head. `block` is the one decode of the
    /// header block, allocated with `allocator` and owned by the event, so
    /// `deinit` frees it; `headers` is its regular fields, without `:status`.
    head: struct {
        allocator: std.mem.Allocator,
        stream_id: u32,
        status_code: u16,
        block: hpack.DecodedBlock,
        headers: []const hpack.Header,
        end_stream: bool,
    },
    /// An interim (1xx) header block arrived for the stream. The final head
    /// is still pending, but the origin is alive, so drivers restart their
    /// stall clocks on it; a 103 Early Hints followed by a slow final response
    /// would otherwise look like a silent origin.
    progress: struct {
        stream_id: u32,
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
    },
    end: struct {
        stream_id: u32,
    },
    failure: struct {
        stream_id: u32,
        err: anyerror,
    },

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .head => |*head| head.block.deinit(head.allocator),
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
    pending_body_credit_total: usize = 0,

    /// `scratch` is borrowed for the connection's life (`HpackScratch`).
    pub fn init(allocator: std.mem.Allocator, scratch: *const session_mod.HpackScratch) !Connection {
        return try initWithLimits(allocator, .{}, scratch);
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        limits: Limits,
        scratch: *const session_mod.HpackScratch,
    ) !Connection {
        const normalized_limits = try limits.normalized();
        var session = try session_mod.Session.init(allocator, scratch);
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
        self.active_streams.deinit(self.allocator);
        self.local_reset_streams.deinit(self.allocator);
        self.pending_header_block.deinit(self.allocator);
        self.session.deinit();
        self.* = undefined;
    }

    /// Writes the client preface, the local SETTINGS and the WINDOW_UPDATE
    /// that raises the connection window to its target, once; later calls
    /// write nothing.
    pub fn start(self: *Connection, writer: *std.Io.Writer) !void {
        if (self.started)
            return;
        const preface = try self.session.encodeConnectionPrefaceAndSettings(self.allocator);
        defer self.allocator.free(preface);
        try writer.writeAll(preface);
        if (self.recv_connection_window.initialIncrement()) |increment|
            try writeWindowUpdate(writer, 0, increment);
        self.started = true;
    }

    /// Opens a stream for `head` and returns its id, starting the connection
    /// first when nothing has. The request body is borrowed until the stream
    /// ends; as much of it as the windows allow goes out now, the rest as
    /// WINDOW_UPDATEs arrive. A head `request.zig:validateRequestHead`
    /// refuses fails before the encoder sees it, and the connection goes on
    /// serving.
    pub fn openRequest(
        self: *Connection,
        writer: *std.Io.Writer,
        head: request_mod.RequestHead,
        max_response_body_bytes: usize,
    ) !u32 {
        try self.start(writer);
        if (self.closing)
            return error.Http2ConnectionClosed;
        if (!self.canOpenStream())
            return error.Http2MaxConcurrentStreamsExceeded;

        var state = response.ResponseState.init(max_response_body_bytes);
        if (std.mem.eql(u8, head.method, "HEAD"))
            state.body_forbidden = true;

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
            .response = state,
            .upload = UploadState.init(self, head.body),
            .recv_window = ReceiveWindow.initStream(
                self.limits.stream_receive_window,
                self.limits.receive_window_update_threshold,
            ),
            .pending_credit_cap = self.limits.max_pending_body_credit_per_stream,
        };
        try stream.upload.writeAvailable(writer, stream_id);
        try writer.flush();
        try self.active_streams.append(self.allocator, stream);
        return stream_id;
    }

    pub fn processEventFrame(
        self: *Connection,
        writer: *std.Io.Writer,
        frame: *Frame,
    ) !?Event {
        try self.start(writer);
        if (!self.session.received_peer_settings and frame.header.frame_type != .settings)
            return error.Http2MissingInitialSettings;
        if (self.pending_header_stream_id != null and frame.header.frame_type != .continuation)
            return error.Http2ProtocolError;
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
                    try self.applyInitialWindowChange(previous_initial_window, self.session.peer_settings.initial_window_size);
                    try self.writeAvailableUploads(writer);
                    try writer.flush();
                }
            },
            .headers => return try self.receiveHeadersFrame(writer, frame),
            .continuation => return try self.receiveContinuationFrame(writer, frame),
            .data => return try self.receiveDataFrame(writer, frame),
            .ping => try answerPing(writer, frame),
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
                    if (self.active_streams.items[index].response.complete)
                        return null;
                    try self.restorePendingConnectionCredit(writer, index);
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
                return try self.nextUnprocessedStreamFailure(writer);
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
                    try self.applyInitialWindowChange(previous_initial_window, self.session.peer_settings.initial_window_size);
                    try writer.flush();
                }
            },
            .ping => try answerPing(writer, frame),
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

    /// Drops an active stream, resetting it with CANCEL while either side is
    /// still open (`resetStreamAt`), and returns the body credit its consumer
    /// still held to the connection window. Frames the peer sent before it
    /// saw the reset are still consumed, including the rest of a header
    /// block the stream had begun.
    pub fn cancelStream(self: *Connection, writer: *std.Io.Writer, stream_id: u32) !void {
        const index = self.findStreamIndex(stream_id) orelse return error.Http2UnknownStream;
        try self.resetStreamAt(writer, index, false);
        // A header block this stream began stays pending, and
        // `endPendingHeaderBlock` decodes and drops it at END_HEADERS.
        _ = self.active_streams.orderedRemove(index);
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
    /// which may never come. `writer` takes the WINDOW_UPDATE that returns
    /// the body credit a failed stream's consumer still held.
    pub fn nextUnprocessedStreamFailure(self: *Connection, writer: *std.Io.Writer) !?Event {
        const last_stream_id = self.session.goaway_last_stream_id orelse return null;
        for (self.active_streams.items, 0..) |stream, index| {
            if (stream.id > last_stream_id) {
                // A peer may send DATA on a stream and then a GOAWAY that
                // excludes it. The stream leaves the table here, and acks
                // for it fail as acks for an unknown stream, so its credit
                // comes back now or never.
                try self.restorePendingConnectionCredit(writer, index);
                return self.failStreamAt(index, error.Http2StreamNotProcessed);
            }
        }
        return null;
    }

    /// Returns `flow_credit` bytes of the stream's body credit, taken from
    /// its `.body_chunk` events, and reopens the receive windows by that
    /// much: the connection window always, the stream window when
    /// `update_stream` is set. One ack may carry the summed credit of several
    /// chunks: a consumer may sum a stream's chunks that have
    /// `update_stream_window` set into one ack, and acks the last chunk,
    /// which has it clear, on its own. Returns the stream's `.end` once its
    /// last credit is back.
    ///
    /// Fails with `error.Http2AckExceedsPendingCredit` when `flow_credit` is
    /// more than the stream holds, before any window moves, so the peer is
    /// never granted room for bytes no consumer released and the connection
    /// stays as it was.
    pub fn ackReceivedData(
        self: *Connection,
        writer: *std.Io.Writer,
        stream_id: u32,
        flow_credit: usize,
        update_stream: bool,
    ) !?Event {
        const index = self.findStreamIndex(stream_id) orelse return error.Http2UnknownStream;
        try self.releasePendingBodyCredit(index, flow_credit);
        try self.writeReceiveWindowUpdates(writer, index, flow_credit, update_stream);
        if (update_stream)
            try self.maybeGrowStreamReceiveWindow(writer, index);
        // The acked stream goes first when it is ready, so each stream's
        // last ack surfaces its own deferred `.end`. Returning another
        // stream's end here would leave the acked one with no ack left to
        // complete it.
        const acked = &self.active_streams.items[index];
        if (acked.head_reported and acked.response.complete and acked.pending_body_credit == 0)
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
            if (!stream.response.complete)
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

    fn applyInitialWindowChange(self: *Connection, previous: u32, next: u32) !void {
        for (self.active_streams.items) |*stream|
            try stream.upload.applyInitialWindowChange(previous, next);
    }

    fn writeAvailableUploads(self: *Connection, writer: *std.Io.Writer) !void {
        for (self.active_streams.items) |*stream|
            try stream.upload.writeAvailable(writer, stream.id);
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

    /// Hands an active stream's DATA payload to its consumer as a
    /// `.body_chunk` that holds the payload's flow credit. DATA before the
    /// stream's final head, past its size cap or past its content-length
    /// fails the stream alone; its bytes still count against the connection
    /// window, which is reopened at once. DATA for a stream the client reset
    /// is counted and dropped.
    fn receiveDataFrame(self: *Connection, writer: *std.Io.Writer, frame: *Frame) !?Event {
        try frame.header.validateStream();
        const data_payload = try dataPayload(frame);
        const end_stream = frame.header.flags.end_stream;
        const index = self.findStreamIndex(frame.header.stream_id) orelse {
            if (self.hasLocalResetStream(frame.header.stream_id)) {
                try self.discardResetData(writer, frame.header.stream_id, frame.payload, end_stream);
                return null;
            }
            return error.Http2ProtocolError;
        };
        try self.receiveDataFlowControl(index, frame.payload.len);
        self.active_streams.items[index].response.receiveData(data_payload.len, end_stream) catch |err| {
            if (!isStreamResponseFailure(err))
                return err;
            try self.reopenConnectionWindow(writer, frame.payload.len);
            return try self.cancelFailedStreamAt(writer, index, err, end_stream);
        };
        const flow_credit = frame.payload.len;
        // A padded frame copies its stripped payload before any credit is
        // registered, so a failed copy leaves none.
        const padded_copy: ?[]u8 = if (frame.header.flags.padded)
            try frame.allocator.dupe(u8, data_payload)
        else
            null;
        self.addPendingBodyCredit(index, flow_credit) catch |err| {
            if (padded_copy) |copy|
                frame.allocator.free(copy);
            try self.reopenConnectionWindow(writer, flow_credit);
            return try self.cancelFailedStreamAt(writer, index, err, end_stream);
        };
        // Unpadded DATA hands the frame's payload buffer to the event without
        // a copy, leaving the frame nothing to free.
        const bytes = padded_copy orelse blk: {
            const owned = frame.payload;
            frame.payload = &.{};
            break :blk owned;
        };
        return .{ .body_chunk = .{
            .allocator = frame.allocator,
            .stream_id = frame.header.stream_id,
            .bytes = bytes,
            .end_stream = end_stream,
            .flow_credit = flow_credit,
            .update_stream_window = !end_stream,
        } };
    }

    /// Returns `payload_len` bytes of connection window to the peer for DATA
    /// no consumer will hold.
    fn reopenConnectionWindow(self: *Connection, writer: *std.Io.Writer, payload_len: usize) !void {
        if (payload_len == 0)
            return;
        if (try self.writeConnectionReceiveWindowUpdate(writer, payload_len))
            try writer.flush();
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

    /// What one finished header block was for its stream.
    const HeaderBlock = union(enum) {
        /// An interim (1xx) head, decoded and dropped.
        interim,
        /// The final head; the caller owns `block`, which `head` slices.
        final: struct {
            block: hpack.DecodedBlock,
            head: response.ResponseHead,
        },
        /// The trailer block, validated and dropped; it ended the stream.
        trailers,
    };

    /// Decodes the pending block for the stream at `index` with the
    /// connection's allocator and the shard's scratch, and clears it. Only a
    /// final head's decode outlives the call.
    fn finishPendingHeaderBlock(self: *Connection, index: usize) !HeaderBlock {
        defer self.clearPendingHeaderBlock();
        const block = self.pending_header_block.items;
        const end_stream = self.pending_headers_end_stream;
        if (block.len > collo_limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX)
            return error.Http2HeaderBlockTooLarge;
        var decoded = try self.session.decoder.decodeBlock(
            self.allocator,
            self.session.scratch.decode,
            block,
            response.max_response_header_count,
            collo_limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX,
        );
        var decoded_owned = true;
        defer if (decoded_owned)
            decoded.deinit(self.allocator);
        const state = &self.active_streams.items[index].response;
        if (state.status_code != null) {
            if (!end_stream)
                return error.Http2ProtocolError;
            try response.validateTrailers(decoded.headers);
            try state.finish();
            return .trailers;
        }
        const head = try response.parseResponseHead(decoded.headers, end_stream);
        switch (try state.receiveHead(head)) {
            .interim => return .interim,
            .final => {
                decoded_owned = false;
                return .{ .final = .{ .block = decoded, .head = head } };
            },
        }
    }

    fn finishHeadersOrFailStream(self: *Connection, writer: *std.Io.Writer, index: usize) !?Event {
        const remote_complete = self.pending_headers_end_stream;
        const outcome = self.finishPendingHeaderBlock(index) catch |err| {
            if (isStreamResponseFailure(err))
                return try self.cancelFailedStreamAt(writer, index, err, remote_complete);
            return err;
        };
        const stream = &self.active_streams.items[index];
        switch (outcome) {
            // An interim block surfaces as progress so the driver sees the
            // origin is alive; 101 and a 1xx with END_STREAM have already
            // failed.
            .interim => return .{ .progress = .{ .stream_id = stream.id } },
            .final => |final| {
                stream.head_reported = true;
                return .{ .head = .{
                    .allocator = self.allocator,
                    .stream_id = stream.id,
                    .status_code = final.head.status_code,
                    .block = final.block,
                    .headers = final.head.regular_headers,
                    .end_stream = remote_complete,
                } };
            },
            .trailers => {
                // Trailers can end a stream whose consumer still holds
                // unacked flow credit. Removing the stream now would orphan
                // those acks, which fail the connection as acks for an
                // unknown stream, and would leak the connection's
                // pending-credit budget. The `.end` waits for the last credit
                // ack, as it does for a stream ending in DATA with
                // END_STREAM.
                if (stream.pending_body_credit == 0)
                    return try self.completeStreamAt(index);
                return null;
            },
        }
    }

    /// `frame_ended_remote` is the END_STREAM flag of the frame that failed
    /// the stream, which its response state may not have recorded.
    fn cancelFailedStreamAt(self: *Connection, writer: *std.Io.Writer, index: usize, err: anyerror, frame_ended_remote: bool) !Event {
        try self.resetStreamAt(writer, index, frame_ended_remote);
        return self.failStreamAt(index, err);
    }

    /// Ends the stream at `index` on the wire as its RFC 9113 §5.1 state
    /// requires, before the caller drops it from the table, and returns the
    /// body credit its consumer still held to the connection window. A
    /// stream stays in the table after the peer's END_STREAM until its last
    /// credit is acked, so being in the table does not mean being open. The
    /// remote side has ended once END_STREAM arrived: on `frame_ended_remote`,
    /// in the response state, or on the header block still pending for the
    /// stream. The local side has ended once the upload's last DATA, or the
    /// HEADERS of a request without a body, carried END_STREAM. RST_STREAM
    /// goes out while either side is open; reset tracking is kept only while
    /// the remote side is open, since a peer that ended the stream may still
    /// send WINDOW_UPDATE, RST_STREAM or PRIORITY for it, which the codec
    /// accepts for streams it no longer tracks, but never DATA or HEADERS.
    fn resetStreamAt(self: *Connection, writer: *std.Io.Writer, index: usize, frame_ended_remote: bool) !void {
        const stream = &self.active_streams.items[index];
        const stream_id = stream.id;
        const remote_ended = frame_ended_remote or stream.response.complete or
            (self.pending_header_stream_id == stream_id and self.pending_headers_end_stream);
        const local_ended = stream.upload.offset == stream.upload.body.len;
        try self.restorePendingConnectionCredit(writer, index);
        if (remote_ended) {
            if (local_ended) {
                // Closed on both sides: nothing to tell the peer, and nothing
                // of it can arrive any more but what RFC 9113 §5.1 allows
                // above.
                try writer.flush();
                return;
            }
        } else {
            self.rememberLocalResetStream(stream_id);
        }
        try self.sendCancel(writer, stream_id);
    }

    /// Decodes a reset stream's header block only to keep the HPACK dynamic
    /// table in step with the peer's encoder, then drops it. Nothing is kept,
    /// so no header cap applies: a block over the caps of a kept response
    /// still leaves the table in step, and only an error that leaves it out
    /// of step fails the connection. Returns whether the block ended the
    /// stream.
    fn discardPendingHeaderBlock(self: *Connection) !bool {
        defer self.clearPendingHeaderBlock();
        const end_stream = self.pending_headers_end_stream;
        try self.session.decoder.skipBlock(self.session.scratch.decode, self.pending_header_block.items);
        return end_stream;
    }

    fn discardResetData(self: *Connection, writer: *std.Io.Writer, stream_id: u32, payload: []const u8, end_stream: bool) !void {
        try self.recv_connection_window.receive(payload.len);
        try self.reopenConnectionWindow(writer, payload.len);
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
        const stream = self.active_streams.orderedRemove(index);
        _ = stream.response.status_code orelse return error.Http2ResponseIncomplete;
        return .{ .end = .{ .stream_id = stream.id } };
    }

    fn failStreamAt(self: *Connection, index: usize, err: anyerror) Event {
        const stream = self.active_streams.orderedRemove(index);
        return .{ .failure = .{ .stream_id = stream.id, .err = err } };
    }

    fn firstReportedCompleteStream(self: *Connection) ?usize {
        for (self.active_streams.items, 0..) |stream, index| {
            if (stream.head_reported and stream.response.complete and stream.pending_body_credit == 0)
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
        if (!stream.head_reported or stream.response.complete)
            return;
        if (stream.pending_body_credit != 0)
            return;
        const target = stream.recv_window.target;
        if (stream.response.received_body_bytes < target)
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
        try writeWindowUpdate(writer, stream.id, delta);
        try stream.recv_window.grow(delta);
        stream.pending_credit_cap += delta;
    }

    fn writeReceiveWindowUpdates(
        self: *Connection,
        writer: *std.Io.Writer,
        stream_index: usize,
        payload_len: usize,
        update_stream: bool,
    ) !void {
        _ = try self.writeConnectionReceiveWindowUpdate(writer, payload_len);
        if (!update_stream)
            return;
        if (try self.active_streams.items[stream_index].recv_window.record(payload_len)) |increment|
            try writeWindowUpdate(writer, self.active_streams.items[stream_index].id, increment);
    }

    fn receiveDataFlowControl(self: *Connection, stream_index: usize, payload_len: usize) !void {
        try self.recv_connection_window.receive(payload_len);
        try self.active_streams.items[stream_index].recv_window.receive(payload_len);
    }

    /// Returns whether the connection's WINDOW_UPDATE went to the writer.
    fn writeConnectionReceiveWindowUpdate(
        self: *Connection,
        writer: *std.Io.Writer,
        payload_len: usize,
    ) !bool {
        if (try self.recv_connection_window.record(payload_len)) |increment| {
            try writeWindowUpdate(writer, 0, increment);
            return true;
        }
        return false;
    }

    /// Takes back all the body credit the stream's consumer still holds and
    /// returns it to the connection window, for a stream about to leave the
    /// table, whose acks will never come.
    fn restorePendingConnectionCredit(self: *Connection, writer: *std.Io.Writer, stream_index: usize) !void {
        const pending = self.active_streams.items[stream_index].pending_body_credit;
        if (pending == 0)
            return;
        try self.releasePendingBodyCredit(stream_index, pending);
        _ = try self.writeConnectionReceiveWindowUpdate(writer, pending);
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

    /// Changes nothing when it fails with `error.Http2AckExceedsPendingCredit`.
    fn releasePendingBodyCredit(self: *Connection, stream_index: usize, bytes: usize) !void {
        const stream = &self.active_streams.items[stream_index];
        if (bytes > stream.pending_body_credit)
            return error.Http2AckExceedsPendingCredit;
        // The total is the sum of what every active stream holds: credit
        // enters it only with a stream's own, and every stream leaves the
        // table holding none, by completing at zero or through
        // `restorePendingConnectionCredit`.
        std.debug.assert(stream.pending_body_credit <= self.pending_body_credit_total);
        stream.pending_body_credit -= bytes;
        self.pending_body_credit_total -= bytes;
    }
};

fn isStreamResponseFailure(err: anyerror) bool {
    return switch (err) {
        error.FetchResponseTooLarge,
        error.Http2ResponseBodyForbidden,
        error.Http2ContentLengthMismatch,
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

/// Answers a PING that is not itself an acknowledgement.
fn answerPing(writer: *std.Io.Writer, frame: *const Frame) !void {
    try frame.header.validateControlStream();
    if (frame.payload.len != 8)
        return error.Http2FrameSizeError;
    // `end_stream` is flag bit 0x1, the ACK flag on PING.
    if (frame.header.flags.end_stream)
        return;
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
    try writer.flush();
}

const ActiveStream = struct {
    id: u32,
    response: response.ResponseState,
    upload: UploadState,
    recv_window: ReceiveWindow,
    head_reported: bool = false,
    pending_body_credit: usize = 0,
    /// Most body credit the consumer may hold unacked on this stream. It
    /// starts at the per-stream budget and grows with the stream's receive
    /// window; the connection-level cap stays the memory bound.
    pending_credit_cap: usize = 0,

    fn addPendingBodyCredit(self: *ActiveStream, bytes: usize, limit: usize) !void {
        const next = try std.math.add(usize, self.pending_body_credit, bytes);
        if (next > limit)
            return error.Http2BodyBackpressureExceeded;
        self.pending_body_credit = next;
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

    /// Writes as much of the body as both send windows and the peer's frame
    /// size allow, as DATA frames; the last carries END_STREAM.
    fn writeAvailable(
        self: *UploadState,
        writer: *std.Io.Writer,
        stream_id: u32,
    ) !void {
        while (self.offset < self.body.len and self.connection.send_connection_window > 0 and self.stream_window > 0) {
            const window_budget: usize = @intCast(@min(self.connection.send_connection_window, self.stream_window));
            const frame_budget: usize = @intCast(self.connection.session.peer_settings.max_frame_size);
            const chunk_len = @min(@min(window_budget, frame_budget), self.body.len - self.offset);
            const is_last = self.offset + chunk_len == self.body.len;
            try writeDataFrame(
                writer,
                stream_id,
                self.body[self.offset..][0..chunk_len],
                is_last,
            );
            self.offset += chunk_len;
            self.connection.send_connection_window -= @intCast(chunk_len);
            self.stream_window -= @intCast(chunk_len);
        }
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

fn writeWindowUpdate(writer: *std.Io.Writer, stream_id: u32, increment: u32) !void {
    var update: [h2.frame_header_len + 4]u8 = undefined;
    try h2.encodeWindowUpdateFrame(&update, stream_id, increment);
    try writer.writeAll(&update);
}

fn writeDataFrame(writer: *std.Io.Writer, stream_id: u32, payload: []const u8, end_stream: bool) !void {
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
