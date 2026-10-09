//! The reading half of the HTTP/2 connection driver (`connection.zig`), on
//! the lane thread that owns the connection slot: the socket read into the
//! lane's one read buffer, the events the connection's frame reader
//! (`frame_reader.zig`) makes of its bytes, the checks each frame header
//! passes and the switch over frame types, the batch path for a run of whole
//! DATA frames on one stream, header blocks with the HPACK decoding of
//! request heads and trailers, and the receive windows each frame consumes.
//! A request head goes to the lane's `startDynamicH2`, body bytes to
//! `handleH2DataFrame` or `handleH2DataFrameBatch`, and a client's RST_STREAM
//! to `handleH2ResetFrame`; whatever answers the client is queued through
//! `writing.zig`.
//!
//! An error a frame causes returns to `drive`, which closes the connection,
//! unless it concerns one stream: a request head that fails its checks is
//! answered on its stream, and a stream error resets the stream.
//!
//! Invariants:
//! - Every byte a read returns is handled before the read returns, since the
//!   lane's read buffer serves its next connection next: what a frame cut by
//!   the read boundary needs waits in the frame reader. A DATA frame reaches
//!   its stream in pieces as its bytes arrive, its whole length taken from
//!   the receive windows with its first piece.
//! - Every header block is decompressed, on a stream that takes no more
//!   headers too, so the two ends' HPACK tables stay in step. A block past
//!   `limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES` is not
//!   decompressed and closes the connection with COMPRESSION_ERROR, and a
//!   block the lane's header block budget cannot hold closes it with
//!   ENHANCE_YOUR_CALM.
//! - Receive credit goes back to the client only for bytes the server no
//!   longer holds (`DataFrameHandling`). DATA the lane drops on a stream that
//!   takes no body gives the connection's share back at once.
//! - Within one read, every frame other than HEADERS and DATA counts against
//!   `limits.ingress.budgeted_frames_per_read_max`, and so does a DATA frame
//!   that is empty or all padding. A client that floods such frames gets
//!   GOAWAY ENHANCE_YOUR_CALM.

const std = @import("std");

const connection = @import("connection.zig");
const connection_slot = @import("../runner/connection_slot.zig");
const fault = @import("../fault.zig");
const frame_reader = @import("frame_reader.zig");
const h2_request = @import("request_head.zig");
const server_responses = @import("../server_responses.zig");
const writing = @import("writing.zig");
const process = @import("collo_os").process;
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const ipc = @import("collo_ipc");
const ktls = @import("collo_ktls");
const limits = @import("collo_limits");

const Http2Failure = connection.Http2Failure;
const DataFrameChunk = connection.DataFrameChunk;
const Slot = connection_slot.Slot;

pub const max_h2_budgeted_frames_per_read: usize = limits.ingress.budgeted_frames_per_read_max;

/// The interim status for a request that waits to send its body (RFC 9110
/// §15.2.1).
const continue_status: u16 = 100;

const DataFrameBatchResult = struct {
    wire_bytes: usize,
    budgeted_frames: usize,
};

/// The frames of one read that count against
/// `max_h2_budgeted_frames_per_read`.
const FrameBudget = struct {
    used: usize = 0,

    fn count(self: *FrameBudget, frames: usize) Http2Failure!void {
        self.used += frames;
        if (self.used > max_h2_budgeted_frames_per_read)
            return error.Http2EnhanceYourCalm;
    }
};

/// Reads the socket once into the lane's read buffer and handles every byte
/// that arrived. Returns false when the socket would block, which ends the
/// drive's reads.
pub fn readAndProcess(comptime Worker: type, worker: *Worker, runtime: *Slot) Http2Failure!bool {
    const buffer = worker.h2_lane.read_buffer;
    const read_len = readH2Bytes(runtime, buffer) catch |err|
        return connection.actOnClientIo(Worker, worker, runtime, .read, err);
    if (read_len == 0) {
        // The client closed its side of the socket.
        _ = try connection.actOnClientIo(Worker, worker, runtime, .read, error.PeerClosed);
        return true;
    }
    runtime.noteProgress(process.monotonicNowNsOrZero());
    try processInput(Worker, worker, runtime, buffer[0..read_len]);
    return true;
}

fn readH2Bytes(runtime: *Slot, buffer: []u8) !usize {
    if (runtime.ktls_rekey_state.enabled())
        return ktls.readApplicationData(runtime.fd, buffer, &runtime.ktls_rekey_state);
    return std.posix.read(runtime.fd, buffer);
}

/// Handles every event the bytes of one read make, until they are used up
/// or the connection closes. Whole DATA frames on one stream at a frame
/// boundary go to the batch path.
pub fn processInput(comptime Worker: type, worker: *Worker, runtime: *Slot, bytes: []const u8) Http2Failure!void {
    var input = bytes;
    var budget: FrameBudget = .{};
    while (runtime.isOpen()) {
        if (runtime.frame_reader.atFrameBoundary() and runtime.h2_received_initial_client_settings) {
            if (try tryHandleDataFrameBatch(Worker, worker, runtime, input)) |batch| {
                try budget.count(batch.budgeted_frames);
                input = input[batch.wire_bytes..];
                continue;
            }
        }
        const event = (try runtime.frame_reader.next(&input)) orelse return;
        switch (event) {
            .preface => {
                try runtime.h2_hpack_decoder.setMaxCapacity(h2.default_header_table_size);
                _ = try writing.queueServerSettingsAndAck(Worker, worker, runtime, false);
            },
            .header => |header| try runtime.frame_reader.accept(try frameDisposition(runtime, header, &budget)),
            .control => |payload| try handleControlFrame(Worker, worker, runtime, runtime.frame_reader.header, payload),
            .data => |piece| try handleDataPiece(Worker, worker, runtime, piece, &budget),
            .fragment => |piece| try handleFragment(Worker, worker, runtime, piece),
        }
    }
}

/// Checks a frame header against the connection's state and says how the
/// frame reader reads its payload, in the order RFC 9113 asks of each frame
/// type: the client preface ends with SETTINGS (RFC 9113 §3.4), an open
/// header block admits only its CONTINUATION frames (RFC 9113 §6.10), then
/// each type's stream and length rules.
fn frameDisposition(runtime: *Slot, header: h2.FrameHeader, budget: *FrameBudget) Http2Failure!frame_reader.Disposition {
    if (!runtime.h2_received_initial_client_settings and
        (header.frame_type != .settings or isAckFlagSet(header)))
    {
        return error.Http2ProtocolError;
    }
    if (isBudgetedFrameType(header.frame_type))
        try budget.count(1);
    if (runtime.h2HasPendingHeaderBlock()) {
        if (header.frame_type != .continuation)
            return error.Http2ProtocolError;
    } else if (header.frame_type == .continuation) {
        return error.Http2ProtocolError;
    }
    switch (header.frame_type) {
        .data => {
            try header.validateStream();
            if (header.length == 0)
                try budget.count(1);
            return .data;
        },
        .headers => {
            try header.validateStream();
            return .fragment;
        },
        .continuation => {
            try header.validateStream();
            if (header.stream_id != runtime.h2_header_block_stream_id)
                return error.Http2ProtocolError;
            try runtime.h2CountHeaderBlockFrame();
            return .fragment;
        },
        .settings => {
            try header.validateControlStream();
            if (isAckFlagSet(header)) {
                // An acknowledgement carries no payload (RFC 9113 §6.5).
                if (header.length != 0)
                    return error.Http2FrameSizeError;
                return .buffer;
            }
            if (header.length % h2.setting_wire_len != 0)
                return error.Http2FrameSizeError;
            if (header.length > frame_reader.control_payload_bytes_max)
                return error.TooManyHttp2Settings;
            return .buffer;
        },
        .rst_stream => {
            try header.validateStream();
            if (header.length != 4)
                return error.Http2FrameSizeError;
            return .buffer;
        },
        .ping => {
            try header.validateControlStream();
            if (header.length != 8)
                return error.Http2FrameSizeError;
            return .buffer;
        },
        .window_update => {
            if (header.length != 4)
                return error.Http2FrameSizeError;
            return .buffer;
        },
        .priority => {
            try header.validateStream();
            if (header.length != 5)
                return error.Http2FrameSizeError;
            return .skip;
        },
        .goaway => {
            try header.validateControlStream();
            if (header.length < 8)
                return error.Http2FrameSizeError;
            return .skip;
        },
        // A client never pushes (RFC 9113 §8.4).
        .push_promise => return error.Http2ProtocolError,
        // A frame of a type the server does not know is ignored (RFC 9113
        // §4.1).
        .unknown => return .skip,
    }
}

/// Hands a run of at least two unpadded DATA frames, whole in `available`,
/// for one preparing or active stream to the lane in one call. Returns null,
/// consuming nothing, when the frames at the front of `available` do not
/// form such a run.
fn tryHandleDataFrameBatch(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    available: []const u8,
) Http2Failure!?DataFrameBatchResult {
    if (runtime.h2HasPendingHeaderBlock() or available.len < h2.frame_header_len)
        return null;
    const first_header = h2.FrameHeader.parse(available[0..h2.frame_header_len]) catch return null;
    if (first_header.frame_type != .data or first_header.flags.padded or first_header.stream_id == 0)
        return null;
    const stream_id = first_header.stream_id;
    switch (runtime.h2StreamState(stream_id) orelse return null) {
        .preparing, .active => {},
        .vacant, .draining_response => return null,
    }

    var chunks: [ipc.ingress_channel.max_batch_descriptors]DataFrameChunk = undefined;
    var frame_count: usize = 0;
    var budgeted_frames: usize = 0;
    var total_payload_len: usize = 0;
    var end_stream = false;
    var cursor: usize = 0;
    while (frame_count < chunks.len and cursor + h2.frame_header_len <= available.len) {
        // A header that does not parse ends the run; the frame reader meets
        // it on its own.
        const header = h2.FrameHeader.parse(available[cursor..][0..h2.frame_header_len]) catch break;
        if (header.frame_type != .data or header.stream_id != stream_id or header.flags.padded)
            break;
        if (header.length > limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES)
            break;
        const total = h2.frame_header_len + @as(usize, header.length);
        if (available.len - cursor < total)
            break;
        const payload = available[cursor + h2.frame_header_len .. cursor + total];
        chunks[frame_count] = .{
            .payload = payload,
            .end_stream = header.flags.end_stream,
            .window_credit_len = payload.len,
        };
        frame_count += 1;
        if (payload.len == 0)
            budgeted_frames += 1;
        total_payload_len = std.math.add(usize, total_payload_len, payload.len) catch return error.RequestTooLarge;
        cursor += total;
        if (header.flags.end_stream) {
            end_stream = true;
            break;
        }
    }
    if (frame_count < 2)
        return null;

    try runtime.h2ConsumeInboundWindow(stream_id, total_payload_len);
    const handling = try worker.handleH2DataFrameBatch(runtime, stream_id, chunks[0..frame_count]);
    if (runtime.isOpen()) {
        if (total_payload_len != 0 and handling == .consumed)
            try runtime.h2BufferInboundWindowUpdate(stream_id, total_payload_len);
        if (end_stream)
            _ = runtime.h2CloseStreamIfDone(worker.service.allocator, stream_id);
    }
    return .{
        .wire_bytes = cursor,
        .budgeted_frames = budgeted_frames,
    };
}

/// Handles the whole payload of a frame the reader buffered, whose header
/// `frameDisposition` checked.
fn handleControlFrame(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    header: h2.FrameHeader,
    payload: []const u8,
) Http2Failure!void {
    switch (header.frame_type) {
        .settings => try handleSettingsFrame(Worker, worker, runtime, header, payload),
        .rst_stream => try handleRstStreamFrame(Worker, worker, runtime, header, payload),
        .ping => try handlePingFrame(Worker, worker, runtime, header, payload),
        .window_update => try handleWindowUpdateFrame(Worker, worker, runtime, header, payload),
        .data, .headers, .continuation, .priority, .goaway, .push_promise, .unknown => unreachable,
    }
}

fn handleSettingsFrame(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    header: h2.FrameHeader,
    payload: []const u8,
) Http2Failure!void {
    if (isAckFlagSet(header))
        return;
    runtime.h2_received_initial_client_settings = true;
    const settings_change = try runtime.h2_peer_settings.applyPayload(payload);
    if (settings_change.headerTableSizeChanged(runtime.h2_peer_settings))
        try runtime.h2_hpack_encoder.setMaxCapacity(runtime.h2_peer_settings.header_table_size);
    if (settings_change.initialWindowSizeChanged(runtime.h2_peer_settings))
        try runtime.h2ApplyPeerInitialStreamWindow(settings_change.old_initial_window_size, runtime.h2_peer_settings.initial_window_size);
    _ = try writing.queueServerSettingsAndAck(Worker, worker, runtime, true);
    _ = try writing.flushPendingResponseData(Worker, worker, runtime, null);
}

fn handleRstStreamFrame(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    header: h2.FrameHeader,
    payload: []const u8,
) Http2Failure!void {
    // A stream id the client has not used yet names an idle stream, and a
    // frame on it is a connection error (RFC 9113 §5.1). On a stream that
    // has since closed, RST_STREAM is ignored. WINDOW_UPDATE and DATA check
    // for idle streams the same way.
    if (runtime.h2StreamState(header.stream_id) == null) {
        if (!runtime.h2HasSeenClientStreamId(header.stream_id))
            return error.Http2ProtocolError;
        return;
    }
    if (!try worker.handleH2ResetFrame(runtime, header.stream_id, readU32(payload)))
        return error.Http2ProtocolError;
}

fn handlePingFrame(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    header: h2.FrameHeader,
    payload: []const u8,
) Http2Failure!void {
    if (isAckFlagSet(header))
        return;
    _ = try writing.queuePingAck(Worker, worker, runtime, payload);
}

fn handleWindowUpdateFrame(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    header: h2.FrameHeader,
    payload: []const u8,
) Http2Failure!void {
    const stream_known = header.stream_id == 0 or runtime.h2StreamState(header.stream_id) != null;
    if (!stream_known) {
        if (!runtime.h2HasSeenClientStreamId(header.stream_id))
            return error.Http2ProtocolError;
        return;
    }
    const increment = h2.parseWindowUpdateIncrement(payload) catch |err| switch (err) {
        // A zero increment is a stream error on a stream and a connection
        // error on stream 0 (RFC 9113 §6.9).
        error.Http2ProtocolError => {
            if (header.stream_id == 0)
                return error.Http2ProtocolError;
            return resetStreamWithError(Worker, worker, runtime, header.stream_id, .protocol_error);
        },
        error.Http2FrameSizeError => return error.Http2FrameSizeError,
    };
    if (header.stream_id == 0) {
        try runtime.h2IncreaseConnectionSendWindow(increment);
        _ = try writing.flushPendingResponseData(Worker, worker, runtime, null);
        return;
    }
    runtime.h2IncreaseStreamSendWindow(header.stream_id, increment) catch |err| switch (err) {
        // A stream window past its maximum is a stream error (RFC 9113
        // §6.9.1).
        error.Http2FlowControlError => return resetStreamWithError(Worker, worker, runtime, header.stream_id, .flow_control_error),
        error.Http2ProtocolError => return error.Http2ProtocolError,
    };
    _ = try writing.flushPendingResponseData(Worker, worker, runtime, header.stream_id);
}

/// Handles a piece of a DATA frame. The first piece decides where the frame
/// goes by its stream: a stream the client never opened is a connection
/// error, a closed stream or one draining a response drops the whole frame
/// and gives the connection its credit back at once, and an open stream
/// takes the frame's whole length from the receive windows. A stream that
/// goes away before the frame's last piece drops the rest the same way.
fn handleDataPiece(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    piece: frame_reader.Piece,
    budget: *FrameBudget,
) Http2Failure!void {
    const header = runtime.frame_reader.header;
    const stream_id = header.stream_id;
    if (piece.last and header.length != 0 and runtime.frame_reader.region_len == 0)
        try budget.count(1);
    if (piece.first) {
        const state = runtime.h2StreamState(stream_id) orelse {
            if (!runtime.h2HasSeenClientStreamId(stream_id))
                return error.Http2ProtocolError;
            try runtime.h2DiscardInboundData(header.length);
            _ = runtime.frame_reader.skipRest();
            return writing.queueRstStream(Worker, worker, runtime, stream_id, .stream_closed);
        };
        switch (state) {
            .preparing, .active => {},
            // The stream drains a response its request left behind, and the
            // body goes nowhere. Only the connection's credit returns, so the
            // client's stream window closes on what is left of it, and no
            // reset cuts the response short.
            .draining_response => {
                try runtime.h2DiscardInboundData(header.length);
                _ = runtime.frame_reader.skipRest();
                return;
            },
            .vacant => unreachable,
        }
        try runtime.h2ConsumeInboundWindow(stream_id, header.length);
    } else switch (runtime.h2StreamState(stream_id) orelse .vacant) {
        .preparing, .active => {},
        .vacant, .draining_response => return dropRestOfData(runtime, piece),
    }
    const end_stream = piece.last and header.flags.end_stream;
    const handling = try worker.handleH2DataFrame(runtime, stream_id, piece.bytes, end_stream, piece.credit);
    if (!runtime.isOpen())
        return;
    if (piece.credit != 0 and handling == .consumed)
        try runtime.h2BufferInboundWindowUpdate(stream_id, piece.credit);
    if (end_stream)
        _ = runtime.h2CloseStreamIfDone(worker.service.allocator, stream_id);
}

/// Drops the rest of a DATA frame whose stream went away after its first
/// piece: the stream's window went with it, so only the connection's credit
/// for this piece and the bytes still to come returns.
fn dropRestOfData(runtime: *Slot, piece: frame_reader.Piece) Http2Failure!void {
    const credit = @as(usize, piece.credit) + runtime.frame_reader.skipRest();
    try runtime.h2BufferInboundWindowUpdate(null, credit);
}

/// Handles a piece of a HEADERS or CONTINUATION frame's header block
/// fragment. A whole block in one piece of one frame is decoded where it
/// lies; any other block is assembled on the connection first.
fn handleFragment(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    piece: frame_reader.Piece,
) Http2Failure!void {
    const header = runtime.frame_reader.header;
    const allocator = worker.service.allocator;
    const end_headers = header.flags.end_headers_or_ack;
    if (header.frame_type == .headers and piece.first) {
        const kind = try headerBlockKind(runtime, header.stream_id);
        if (kind == .request_headers)
            try runtime.h2AcceptClientStreamId(header.stream_id);
        if (piece.last and end_headers)
            return processHeaderBlock(Worker, worker, runtime, header.stream_id, kind, piece.bytes, header.flags.end_stream);
        try runtime.h2BeginHeaderBlock(header.stream_id, header.flags.end_stream, kind);
    }
    try runtime.h2AppendHeaderBlock(allocator, &worker.h2_lane.header_blocks, piece.bytes);
    if (!piece.last or !end_headers)
        return;
    var block = runtime.h2TakeHeaderBlock(&worker.h2_lane.header_blocks);
    defer block.deinit(allocator);
    try processHeaderBlock(Worker, worker, runtime, block.stream_id, block.kind, block.bytes, block.end_stream);
}

fn isAckFlagSet(header: h2.FrameHeader) bool {
    return header.flags.toByte() & 0x1 != 0;
}

/// Whether a frame of `frame_type` counts against the read's frame budget by
/// its type alone. HEADERS carries a request and DATA a body, so neither
/// does; an empty or all-padding DATA frame counts on its own.
fn isBudgetedFrameType(frame_type: h2.FrameType) bool {
    return switch (frame_type) {
        .data, .headers => false,
        .continuation,
        .settings,
        .ping,
        .window_update,
        .priority,
        .rst_stream,
        .goaway,
        .push_promise,
        .unknown,
        => true,
    };
}

/// What a HEADERS frame on `stream_id` opens: a request on a stream the
/// client has not used, trailers on a stream whose request a worker or the
/// lane still takes, and otherwise a block that is decompressed and dropped.
/// A stream the client opened that the table no longer holds is closed, and
/// a frame that crossed its reset on the wire is ignored (RFC 9113 §5.1),
/// its block decompressed all the same. A lower stream id the client never
/// opened cannot start a stream, since new ids only grow, and is a
/// connection error (RFC 9113 §5.1.1).
fn headerBlockKind(runtime: *const Slot, stream_id: u32) Http2Failure!connection_slot.H2HeaderBlockKind {
    if (runtime.h2StreamState(stream_id)) |state| {
        return switch (state) {
            .preparing, .active => .trailers,
            .draining_response => .discarded,
            .vacant => unreachable,
        };
    }
    if (runtime.h2HasSeenClientStreamId(stream_id)) {
        if (!runtime.h2ClientOpenedStreamId(stream_id))
            return error.Http2ProtocolError;
        return .discarded;
    }
    return .request_headers;
}

fn processHeaderBlock(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    kind: connection_slot.H2HeaderBlockKind,
    block: []const u8,
    end_stream: bool,
) Http2Failure!void {
    switch (kind) {
        .request_headers => try processRequestHead(Worker, worker, runtime, stream_id, block, end_stream),
        .trailers => if (takesTrailers(runtime, stream_id))
            try processTrailers(Worker, worker, runtime, stream_id, block, end_stream)
        else
            try discardHeaderBlock(Worker, worker, runtime, block),
        .discarded => try discardHeaderBlock(Worker, worker, runtime, block),
    }
}

/// Whether the stream of a trailer block still takes it once the block is
/// whole. The block's kind was fixed by its HEADERS frame, and a block that
/// spans reads can outlive its stream: the lane may reset the stream or
/// answer it alone meanwhile, at its request's deadline or on a response the
/// stream cannot take. Frames on a stream the server closed are ignored
/// (RFC 9113 §5.1), so such a block is dropped with the END_STREAM it
/// carries, while a stream the client never opened still fails at its
/// HEADERS frame (`headerBlockKind`).
fn takesTrailers(runtime: *const Slot, stream_id: u32) bool {
    const state = runtime.h2StreamState(stream_id) orelse return false;
    return switch (state) {
        .preparing, .active => true,
        .draining_response => false,
        .vacant => unreachable,
    };
}

/// Decompresses a request's header block within the bounds of a request
/// head, in the lane's decode scratch. Every block arrives here whole, from
/// one HEADERS frame or assembled from CONTINUATION frames, and one past
/// `INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES` fails undecoded with
/// `error.Http2HeaderBlockTooLarge`, which closes the connection
/// (`fault.classifyConnectionError`). Huffman coding expands a string at
/// most 8/5 times, so no field of a block within that bound outgrows the
/// scratch (`hpack.max_single_header_decode_bytes`), whose overflow would
/// abort the block midway. The decoder refuses a block with more fields or
/// bytes than it keeps (`error.HpackHeaderListTooLarge`) only once it has
/// decompressed all of it, so both header tables stay in step and only the
/// block's stream fails.
fn decodeHeaderBlock(comptime Worker: type, worker: *Worker, runtime: *Slot, block: []const u8) Http2Failure!hpack.DecodedBlock {
    if (block.len > limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES)
        return error.Http2HeaderBlockTooLarge;
    return runtime.h2_hpack_decoder.decodeBlockScratch(
        worker.service.allocator,
        worker.h2_lane.decode_scratch,
        block,
        h2_request.max_header_count,
        limits.headers.INGRESS_H2_REQUEST_DECODED_HEADER_BYTES,
    );
}

/// Decompresses and checks a request head and hands it to the lane's
/// stream handler. A head over the bounds or malformed fails only its
/// stream (`refuseRequestHead`). A head that waits to send its body gets 100
/// (Continue) before the handler runs, so the interim response precedes
/// anything the handler answers. The stream counts as opened for the
/// connection's deadlines whatever becomes of it, since a stream the lane
/// answers within this drive leaves no other trace for the drive's end.
fn processRequestHead(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    block: []const u8,
    end_stream: bool,
) Http2Failure!void {
    runtime.noteStreamOpened();
    const allocator = worker.service.allocator;
    var decoded = decodeHeaderBlock(Worker, worker, runtime, block) catch |err| switch (err) {
        // More fields or bytes than a head may hold, answered 431 either way.
        error.HpackHeaderListTooLarge => return refuseRequestHead(Worker, worker, runtime, stream_id, end_stream, error.TooManyRequestHeaders),
        else => |other| return other,
    };
    defer decoded.deinit(allocator);
    const head = h2_request.parse(decoded.headers, end_stream) catch |err|
        return refuseRequestHead(Worker, worker, runtime, stream_id, end_stream, err);
    if (head.expects_continue)
        _ = try writing.queueResponseHead(Worker, worker, runtime, stream_id, continue_status, &.{}, false);
    if (!try worker.startDynamicH2(runtime, stream_id, &head))
        return error.Http2ProtocolError;
    // A handler that answered at once may have ended the stream.
    _ = runtime.h2CloseStreamIfDone(allocator, stream_id);
}

/// Answers a request whose head failed its checks. The block was
/// decompressed, so the connection goes on: 431 for more fields or bytes
/// than a head may hold, 413 for a declared body over the limit, and
/// RST_STREAM PROTOCOL_ERROR for a malformed head.
fn refuseRequestHead(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    request_ended: bool,
    err: (fault.LaneFault || fault.RequestHeadError),
) Http2Failure!void {
    switch (try fault.classifyConnectionError(.{ .request_head = err })) {
        .keep => {},
        .close => |close| return worker.closeRuntimeConnection(runtime, close),
    }
    const response_id: server_responses.Id = switch (err) {
        error.TooManyRequestHeaders => .request_header_fields_too_large,
        error.RequestTooLarge => .payload_too_large,
        else => return writing.queueRstStream(Worker, worker, runtime, stream_id, .protocol_error),
    };
    try answerStreamAlone(Worker, worker, runtime, stream_id, server_responses.get(response_id), request_ended);
}

/// Answers a new stream with `server_response` before any request takes it.
/// The stream enters the table, or is refused with REFUSED_STREAM past the
/// connection's or the lane's bound; the response is queued whole; and a
/// client still sending its request is asked to stop with RST_STREAM
/// NO_ERROR once the response's END_STREAM is queued (RFC 9113 §8.1).
fn answerStreamAlone(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    server_response: server_responses.Response,
    request_ended: bool,
) Http2Failure!void {
    runtime.h2ReserveStream(stream_id) catch |err| switch (err) {
        error.Http2TooManyConcurrentStreams,
        error.Http2StreamSlabFull,
        => return writing.queueRstStream(Worker, worker, runtime, stream_id, .refused_stream),
        error.Http2StreamAlreadyOpen => return error.Http2StreamAlreadyOpen,
    };
    if (!try writing.queueServerResponse(Worker, worker, runtime, stream_id, server_response))
        return;
    const tail_pending = runtime.h2HasPendingResponse(stream_id);
    _ = runtime.h2FinishLocalResponse(worker.service.allocator, stream_id);
    if (!tail_pending and !request_ended)
        try writing.queueRstStream(Worker, worker, runtime, stream_id, .no_error);
}

/// Checks a trailer block and drops it: a worker never sees request
/// trailers, only the end of stream they carry. Trailers without
/// END_STREAM, a malformed block, or one over the bounds of a head reset the
/// stream (RFC 9113 §8.1).
fn processTrailers(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    block: []const u8,
    end_stream: bool,
) Http2Failure!void {
    const allocator = worker.service.allocator;
    var decoded = decodeHeaderBlock(Worker, worker, runtime, block) catch |err| switch (err) {
        error.HpackHeaderListTooLarge => return resetStreamWithError(Worker, worker, runtime, stream_id, .protocol_error),
        else => |other| return other,
    };
    defer decoded.deinit(allocator);
    h2_request.validateTrailers(decoded.headers) catch |err| switch (try fault.classifyConnectionError(.{ .request_head = err })) {
        .keep => return resetStreamWithError(Worker, worker, runtime, stream_id, .protocol_error),
        .close => |close| return worker.closeRuntimeConnection(runtime, close),
    };
    if (!end_stream)
        return resetStreamWithError(Worker, worker, runtime, stream_id, .protocol_error);
    _ = try worker.handleH2DataFrame(runtime, stream_id, "", true, 0);
    _ = runtime.h2CloseStreamIfDone(allocator, stream_id);
}

/// Decompresses a block on a stream that takes no more headers, so both
/// ends' header tables stay in step, and drops it.
fn discardHeaderBlock(comptime Worker: type, worker: *Worker, runtime: *Slot, block: []const u8) Http2Failure!void {
    var decoded = decodeHeaderBlock(Worker, worker, runtime, block) catch |err| switch (err) {
        // Refused after it was decompressed in full, and nothing is kept.
        error.HpackHeaderListTooLarge => return,
        else => |other| return other,
    };
    decoded.deinit(worker.service.allocator);
}

/// Resets a stream the table holds on an error the stream alone caused. The
/// lane's handler for a client's RST_STREAM resets its request toward the
/// worker or out of its wait, the stream leaves the table whatever the
/// handler did with it, and the client gets RST_STREAM with `error_code`.
fn resetStreamWithError(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    error_code: h2.ErrorCode,
) Http2Failure!void {
    if (!try worker.handleH2ResetFrame(runtime, stream_id, @intFromEnum(error_code)))
        return error.Http2ProtocolError;
    _ = runtime.h2MarkStreamReset(worker.service.allocator, stream_id);
    try writing.queueRstStream(Worker, worker, runtime, stream_id, error_code);
}

fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}
