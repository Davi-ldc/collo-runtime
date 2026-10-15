//! The writing half of the HTTP/2 connection driver (`connection.zig`), on
//! the lane thread that owns the connection slot: everything bound for the
//! client, encoded into frames, queued on the connection's write queue
//! (`runner/write_queue.zig`) and written to the socket. That covers the
//! answers the lane writes alone (`queueServerResponse`), a worker's
//! response descriptors, response heads encoded with the connection's HPACK
//! encoder, DATA within the send windows, and the control frames: SETTINGS,
//! PING acknowledgements, the WINDOW_UPDATE frames that return receive
//! credit to the client, RST_STREAM and GOAWAY. Worker response heads are
//! decoded within the caps below and forwarded as the worker wrote them,
//! once `response.zig` has checked every header.
//!
//! Invariants:
//! - Every frame goes through the queue and only `flushPendingWrite` writes
//!   it, so frames reach the client in the order they were queued, which
//!   keeps header blocks in the order the HPACK encoder encoded them.
//! - A queue function only appends, and the connection's next flush writes
//!   what it appended (`noteQueued`): a drive that runs now flushes after
//!   each read and before it ends (`connection.zig`), and an append outside
//!   a drive gives the connection a turn of the lane's loop, which the pass
//!   that queued it runs (`queueConnectionTurn` on `Worker`). So the frames a
//!   pass queues for a connection, a worker's head, DATA and END_STREAM
//!   among them, leave in one write. An append that brings an unblocked
//!   queue to `write_queue.cork_bytes_max` writes it at once.
//! - A write the socket takes in part marks the queue blocked and arms the
//!   write poll without a retry that would take nothing, and no write is
//!   tried while that poll is in flight.
//! - Body bytes go out only as far as the stream's and the connection's send
//!   windows allow; the rest waits on its stream, and bytes queued after them
//!   append behind them. What waits on a stream stays there while the queue
//!   is blocked.
//! - Receive credit the connection owes rides at the tail of the next write
//!   the connection makes, and once it is due (`Slot.h2WindowUpdateDue`) the
//!   connection gets a write for it alone (`scheduleDueWindowUpdates`).

const std = @import("std");

const connection = @import("connection.zig");
const connection_slot = @import("../runner/connection_slot.zig");
const event_sources = @import("../runner/event_sources.zig");
const fault = @import("../fault.zig");
const response = @import("response.zig");
const server_responses = @import("../server_responses.zig");
const stream_table = @import("../runner/stream_table.zig");
const write_queue = @import("../runner/write_queue.zig");
const process = @import("collo_os").process;
const h2 = @import("collo_http").http2;
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const lifecycle = @import("collo_server_lifecycle");

const LaneFault = fault.LaneFault;
const Http2Failure = connection.Http2Failure;
const Slot = connection_slot.Slot;

/// An answer the lane writes alone (`server_responses.zig`), as
/// `queueServerResponse` and `answerStreamAlone` take it.
pub const ServerResponse = server_responses.Response;

/// Queued segments one writev covers; `flushPendingWrite` loops for the rest.
/// A worker's chunk queues two segments per DATA frame (`queueChunkFrames`),
/// so the head, DATA and END_STREAM of several streams' responses with their
/// control frames fit in one.
const max_writev_segments: usize = 64;
// Caps on decoding a worker's response head. They must admit every head the
// worker's validator accepts (`max_response_header_count` and
// `max_response_header_bytes` in `worker/request/response_model.zig`), or a
// response the worker validated fails here. Public so
// `tests/contracts/limits.zig` can assert that at compile time.
pub const max_worker_response_header_count: usize = 256;
pub const max_worker_response_header_bytes: usize = 16 * 1024;

/// Queues RST_STREAM with `error_code` for `stream_id`, a stream the table
/// does not hold or whose state the caller has settled
/// (`Slot.h2MarkStreamReset`, `resetStream`). A connection that cannot take
/// the frame is asked to close; a closing one queues nothing.
pub fn queueRstStream(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    error_code: h2.ErrorCode,
) LaneFault!void {
    if (!runtime.isOpen())
        return;
    var scratch: [h2.frame_header_len + 4]u8 = undefined;
    h2.encodeRstStreamFrame(&scratch, stream_id, error_code) catch |err|
        return connection.closeForError(Worker, worker, runtime, err);
    _ = queueWriteCopy(Worker, worker, runtime, &scratch) catch |err|
        return connection.closeForError(Worker, worker, runtime, err);
}

/// Resets a stream the table holds: it leaves the table with its buffered
/// body and response dropped (`Slot.h2MarkStreamReset`), and the client gets
/// RST_STREAM with `error_code`. Returns the lane request that owned the
/// stream, which the caller resets toward its worker or takes out of its
/// wait. Null, queueing nothing, when the table does not hold the stream,
/// which has ended already. A connection that cannot take the frame is
/// asked to close.
pub fn resetStream(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    error_code: h2.ErrorCode,
) LaneFault!?lifecycle.RequestKey {
    if (runtime.h2StreamState(stream_id) == null)
        return null;
    const request_key = runtime.h2MarkStreamReset(worker.service.allocator, stream_id);
    try queueRstStream(Worker, worker, runtime, stream_id, error_code);
    return request_key;
}

/// Puts GOAWAY with `error_code` and the last stream the client opened at
/// the end of the write queue, as the last frame before a close, and writes
/// nothing. False, queueing nothing, when the connection does not speak
/// HTTP/2 yet or its queue cannot take the frame: the close then goes ahead
/// without it.
pub fn queueCloseGoaway(allocator: std.mem.Allocator, runtime: *Slot, error_code: h2.ErrorCode) bool {
    if (runtime.state != .http2_connection or !runtime.frame_reader.prefaceComplete())
        return false;
    var scratch: [h2.frame_header_len + 8]u8 = undefined;
    h2.encodeGoawayFrame(&scratch, runtime.h2_last_client_stream_id, error_code) catch return false;
    runtime.h2AppendWriteCopy(allocator, &scratch) catch return false;
    return true;
}

/// The graceful-shutdown GOAWAY, which the lane queues on every open
/// connection once `shouldStop()` trips. It names the last stream the client
/// has opened and, unlike a close, leaves the connection open, so the
/// streams already opened keep draining through the shutdown loop. A client
/// that honors it opens new streams on another connection instead of
/// meeting a 503 on each one. The `shouldStop()` check in `startDynamicH2`
/// (`runner/admission.zig`) still answers a stream opened before the frame
/// reached the client with a 503 instead of dropping it. A GOAWAY the write
/// queue cannot take is dropped and the connection goes on serving.
pub fn queueGoawayNoNewStreams(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
) LaneFault!void {
    if (!runtime.isOpen() or runtime.state != .http2_connection or !runtime.frame_reader.prefaceComplete())
        return;
    var scratch: [h2.frame_header_len + 8]u8 = undefined;
    h2.encodeGoawayFrame(&scratch, runtime.h2_last_client_stream_id, .no_error) catch |err|
        return connection.closeForError(Worker, worker, runtime, err);
    _ = queueWriteCopy(Worker, worker, runtime, &scratch) catch |err| switch (err) {
        error.Http2WriteBackpressure, error.OutOfMemory => return,
        else => |other| return connection.closeForError(Worker, worker, runtime, other),
    };
}

/// Queues `server_response`, an answer the lane writes itself, whole on
/// `stream_id`: its head, then its body as far as the send windows allow,
/// the rest waiting on the stream. Returns false, queueing nothing, when the
/// connection is closing, the table no longer holds the stream, the stream
/// drains an answer already, or the worker's response head went out on it,
/// since such a stream takes no other response. A connection that cannot
/// take the frames is asked to close, and only lane faults return.
pub fn queueServerResponse(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    server_response: server_responses.Response,
) LaneFault!bool {
    if (!runtime.isOpen())
        return false;
    switch (runtime.h2StreamState(stream_id) orelse return false) {
        .preparing, .active => {},
        .draining_response, .vacant => return false,
    }
    if (runtime.responseHeadQueued(stream_id))
        return false;
    queueServerResponseFrames(Worker, worker, runtime, stream_id, server_response) catch |err| {
        try connection.closeForError(Worker, worker, runtime, err);
        return false;
    };
    _ = runtime.h2CloseStreamIfDone(worker.service.allocator, stream_id);
    return true;
}

/// Answers `stream_id`, a stream the table holds that no request took, with
/// `server_response` and ends the stream there: the response is queued whole
/// (`queueServerResponse`), the stream drains its tail or leaves the table,
/// and a client still sending its request, `request_ended` false, is asked
/// to stop with RST_STREAM NO_ERROR once the response's END_STREAM is queued
/// (RFC 9113 §8.1). Returns whether the response was queued; a stream that
/// took none leaves the table all the same. Only lane faults return.
pub fn answerStreamAlone(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    server_response: server_responses.Response,
    request_ended: bool,
) LaneFault!bool {
    const queued = try queueServerResponse(Worker, worker, runtime, stream_id, server_response);
    // A tail the send windows hold back carries the END_STREAM, which the
    // reset must not overtake.
    const tail_pending = runtime.h2HasPendingResponse(stream_id);
    _ = runtime.h2FinishLocalResponse(worker.service.allocator, stream_id);
    if (queued and !tail_pending and !request_ended)
        try queueRstStream(Worker, worker, runtime, stream_id, .no_error);
    return queued;
}

fn queueServerResponseFrames(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    server_response: server_responses.Response,
) !void {
    var content_length_buffer: [20]u8 = undefined;
    const content_length = try std.fmt.bufPrint(&content_length_buffer, "{d}", .{server_response.body.len});
    const headers = [_]ipc.ingress_channel.ResponseHeader{
        .{ .name = "content-type", .value = server_response.content_type },
        .{ .name = "content-length", .value = content_length },
    };
    _ = try queueResponseHead(
        Worker,
        worker,
        runtime,
        stream_id,
        server_response.status,
        &headers,
        server_response.body.len == 0,
    );
    if (server_response.body.len != 0)
        _ = try queueResponseChunk(Worker, worker, runtime, stream_id, server_response.body, true);
}

/// Queues a response head on `stream_id`, with END_STREAM when `end_stream`
/// says, which the stream then records. A status below 200 is an interim
/// response, which a final one follows on the stream. Fails with
/// `error.InvalidHttp2ResponseStatus` for a status that is not three digits,
/// with the header errors of `response.encodeResponseHeadersScratch`, and
/// with `error.HpackEncoderPoisoned` once the connection's HPACK encoder has
/// lost its state. Queues nothing on a closing connection.
pub fn queueResponseHead(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    status: u16,
    headers: []const ipc.ingress_channel.ResponseHeader,
    end_stream: bool,
) !bool {
    if (!runtime.isOpen())
        return false;
    if (status < 100 or status > 999)
        return error.InvalidHttp2ResponseStatus;

    var status_buf: [3]u8 = undefined;
    const status_value = try std.fmt.bufPrint(&status_buf, "{d}", .{status});
    const encoded_headers = try response.encodeResponseHeadersScratch(
        worker.service.allocator,
        &runtime.h2_hpack_encoder,
        worker.h2_lane.encode_scratch,
        status_value,
        headers,
    );
    const frame_bytes = try h2.encodeHeadersFrames(
        worker.service.allocator,
        runtime.h2_peer_settings.max_frame_size,
        stream_id,
        encoded_headers,
        end_stream,
    );
    const queued = try queueOwnedWrite(Worker, worker, runtime, frame_bytes);
    if (end_stream)
        runtime.h2NoteResponseEndQueued(stream_id);
    return queued;
}

/// Queues body bytes on `stream_id` as far as the stream's and the
/// connection's send windows allow. The rest waits on the stream for a
/// WINDOW_UPDATE, and bytes queued after it append behind it, so the body
/// keeps its order. Queues nothing on a closing connection.
pub fn queueResponseChunk(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
) !bool {
    if (!runtime.isOpen())
        return false;
    if (payload.len == 0 and end_stream and !runtime.h2HasPendingResponse(stream_id))
        return queueDataFramesNoWindowAccounting(Worker, worker, runtime, stream_id, "", true);

    if (runtime.h2HasPendingResponse(stream_id)) {
        try runtime.h2AppendPendingResponse(worker.service.allocator, stream_id, payload, end_stream);
        return flushPendingResponseData(Worker, worker, runtime, stream_id);
    }

    const sent = try queueResponseDataAvailableWindow(Worker, worker, runtime, stream_id, payload, end_stream, null);
    if (sent == payload.len)
        return sent != 0 or end_stream;
    if (!runtime.isOpen())
        return true;
    try runtime.h2AppendPendingResponse(worker.service.allocator, stream_id, payload[sent..], end_stream);
    return true;
}

/// What one worker response descriptor queued on its stream.
pub const QueuedResponse = struct {
    /// Body bytes the descriptor queued.
    body_bytes: usize = 0,
    /// The status of the response head the descriptor queued, which the
    /// client receives as `:status`; null for every other descriptor and for
    /// a head a closing connection dropped.
    head_status: ?u16 = null,
};

/// Queues one worker response descriptor on its stream and says what it
/// queued. The caller has already matched the descriptor to an active
/// request of the sending worker (`resolveDescriptor` in
/// `runner/h2_worker_ipc.zig`). A descriptor the stream's response state
/// does not admit, an unknown op or a malformed payload fails, and the
/// caller sorts the error with `fault.classifyResponseQueueError`. On a
/// closing connection the descriptor is dropped.
pub fn queueWorkerResponseDescriptor(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    received: *ipc.ingress_channel.Received,
) !QueuedResponse {
    if (!runtime.isOpen())
        return .{};
    const descriptor = received.descriptor;
    const end_stream = descriptor.hasFlag(ipc.ingress_channel.flags.end_stream);
    switch (descriptor.op) {
        @intFromEnum(ipc.ingress_channel.Op.response_head) => {
            try runtime.h2ValidateWorkerResponseHeadDescriptor(descriptor);
            if (!descriptor.hasFlag(ipc.ingress_channel.flags.inline_bytes))
                return error.IngressSharedPayloadUnavailable;
            var head = try ipc.ingress_channel.decodeResponseHeadBounded(
                worker.service.allocator,
                received.payload,
                max_worker_response_header_count,
                max_worker_response_header_bytes,
            );
            defer head.deinit();
            _ = try queueResponseHead(
                Worker,
                worker,
                runtime,
                descriptor.stream_id,
                head.status,
                head.headers,
                end_stream,
            );
            try runtime.h2MarkWorkerResponseHeadQueued(descriptor.stream_id, end_stream);
            _ = runtime.h2CloseStreamIfDone(worker.service.allocator, descriptor.stream_id);
            return .{ .head_status = head.status };
        },
        @intFromEnum(ipc.ingress_channel.Op.response_chunk) => {
            try runtime.h2ValidateWorkerResponseBodyDescriptor(descriptor);
            if (!descriptor.hasFlag(ipc.ingress_channel.flags.inline_bytes))
                return error.IngressSharedPayloadUnavailable;
            const body_bytes = received.payload.len;
            try runtime.h2AppendResponseChunk(worker.service.allocator, received);
            try runtime.h2MarkWorkerResponseBodyQueued(descriptor.stream_id, end_stream);
            _ = try flushPendingResponseData(Worker, worker, runtime, descriptor.stream_id);
            _ = runtime.h2CloseStreamIfDone(worker.service.allocator, descriptor.stream_id);
            return .{ .body_bytes = body_bytes };
        },
        @intFromEnum(ipc.ingress_channel.Op.response_end) => {
            try runtime.h2ValidateWorkerResponseBodyDescriptor(descriptor);
            if (received.payload.len != 0)
                return error.InvalidPacket;
            try runtime.h2MarkWorkerResponseBodyQueued(descriptor.stream_id, true);
            _ = try queueResponseChunk(
                Worker,
                worker,
                runtime,
                descriptor.stream_id,
                "",
                true,
            );
            _ = runtime.h2CloseStreamIfDone(worker.service.allocator, descriptor.stream_id);
            return .{};
        },
        @intFromEnum(ipc.ingress_channel.Op.response_reset) => {
            try runtime.h2ValidateWorkerResponseBodyDescriptor(descriptor);
            if (received.payload.len != 0)
                return error.InvalidPacket;
            const reset_code = decodeWorkerResponseResetCode(descriptor.aux) orelse
                return error.InvalidH2WorkerOutboundDescriptor;
            // The worker ended its own response, so its request needs no
            // reset toward it.
            _ = try resetStream(Worker, worker, runtime, descriptor.stream_id, reset_code);
            return .{};
        },
        else => return error.InvalidH2WorkerOutboundDescriptor,
    }
}

/// A worker's reset code, admitted only when it is one of the codes that
/// RFC 9113 §7 defines.
fn decodeWorkerResponseResetCode(raw: u32) ?h2.ErrorCode {
    return switch (raw) {
        @intFromEnum(h2.ErrorCode.no_error) => .no_error,
        @intFromEnum(h2.ErrorCode.protocol_error) => .protocol_error,
        @intFromEnum(h2.ErrorCode.internal_error) => .internal_error,
        @intFromEnum(h2.ErrorCode.flow_control_error) => .flow_control_error,
        @intFromEnum(h2.ErrorCode.settings_timeout) => .settings_timeout,
        @intFromEnum(h2.ErrorCode.stream_closed) => .stream_closed,
        @intFromEnum(h2.ErrorCode.frame_size_error) => .frame_size_error,
        @intFromEnum(h2.ErrorCode.refused_stream) => .refused_stream,
        @intFromEnum(h2.ErrorCode.cancel) => .cancel,
        @intFromEnum(h2.ErrorCode.compression_error) => .compression_error,
        @intFromEnum(h2.ErrorCode.connect_error) => .connect_error,
        @intFromEnum(h2.ErrorCode.enhance_your_calm) => .enhance_your_calm,
        @intFromEnum(h2.ErrorCode.inadequate_security) => .inadequate_security,
        @intFromEnum(h2.ErrorCode.http_1_1_required) => .http_1_1_required,
        else => null,
    };
}

/// Writes the queue, with the receive credit the connection owes at its
/// tail (`appendOwedCredit`), until it drains or the socket takes less than
/// it was offered, and returns whether anything happened. A socket that took
/// part of a write, or would block, marks the queue blocked and arms the
/// connection's write poll; one that failed asks the lane to close the
/// connection. Nothing is tried while the queue is blocked and its write poll
/// is in flight, since the poll reports when the socket takes bytes again. A
/// closing connection writes only while its close flushes the queue. Each
/// write that moves bytes counts in the lane's `client_socket_writes`.
pub fn flushPendingWrite(comptime Worker: type, worker: *Worker, runtime: *Slot) LaneFault!bool {
    if (!runtime.isLive())
        return false;
    if (runtime.closing) |closing| {
        if (!closing.flush)
            return false;
    }
    if (runtime.h2WritesBlocked() and runtime.registered_wait_events & event_sources.write_interest != 0)
        return false;
    try appendOwedCredit(Worker, worker, runtime);
    var did_work = false;
    while (runtime.h2WritesPending()) {
        var iovecs: [max_writev_segments]std.posix.iovec_const = undefined;
        const vectors = runtime.h2QueuedWriteVectors(&iovecs);
        var offered: usize = 0;
        for (vectors) |vector|
            offered += vector.len;
        const written = std.posix.writev(runtime.fd, vectors) catch |err| {
            runtime.h2_write_blocked = true;
            return (try connection.actOnClientIo(Worker, worker, runtime, .write, err)) or did_work;
        };
        if (written == 0) {
            // A socket that takes no byte of a write has closed.
            _ = try connection.actOnClientIo(Worker, worker, runtime, .write, error.PeerClosed);
            return true;
        }
        worker.lane.counters.client_socket_writes += 1;
        runtime.h2ConsumeQueuedWrite(worker.service.allocator, written);
        runtime.noteProgress(process.monotonicNowNsOrZero());
        did_work = true;
        if (written < offered) {
            // The socket's buffer is full, so a write now would take
            // nothing; the write poll brings the connection back once it
            // has room.
            runtime.h2_write_blocked = true;
            runtime.wait_events = event_sources.write_events;
            try worker.updateConnectionInterest(runtime);
            try retireResponseChunks(Worker, worker, runtime);
            return true;
        }
        try retireResponseChunks(Worker, worker, runtime);
    }
    runtime.h2_write_blocked = false;
    return did_work;
}

pub fn queueServerSettingsAndAck(comptime Worker: type, worker: *Worker, runtime: *Slot, ack_client_settings: bool) Http2Failure!bool {
    const initial_settings_payload_len = h2.setting_wire_len * 4;
    const initial_connection_window_increment = limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES - h2.default_initial_window_size;
    var scratch: [h2.frame_header_len + initial_settings_payload_len + h2.frame_header_len + 4 + h2.frame_header_len]u8 = undefined;
    var cursor: usize = 0;
    if (!runtime.h2_sent_initial_settings) {
        var settings = h2.FrameHeader{
            .length = initial_settings_payload_len,
            .frame_type_raw = @intFromEnum(h2.FrameType.settings),
            .frame_type = .settings,
            .flags = h2.Flags.fromByte(0),
            .stream_id = 0,
        };
        try settings.encode(scratch[cursor..][0..h2.frame_header_len]);
        cursor += h2.frame_header_len;
        try h2.encodeSetting(
            scratch[cursor..][0..h2.setting_wire_len],
            .max_concurrent_streams,
            @intCast(stream_table.max_h2_concurrent_streams),
        );
        cursor += h2.setting_wire_len;
        try h2.encodeSetting(
            scratch[cursor..][0..h2.setting_wire_len],
            .max_frame_size,
            limits.h2.INGRESS_MAX_FRAME_SIZE_BYTES,
        );
        cursor += h2.setting_wire_len;
        try h2.encodeSetting(
            scratch[cursor..][0..h2.setting_wire_len],
            .initial_window_size,
            limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES,
        );
        cursor += h2.setting_wire_len;
        try h2.encodeSetting(
            scratch[cursor..][0..h2.setting_wire_len],
            .max_header_list_size,
            @intCast(limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES),
        );
        cursor += h2.setting_wire_len;
        // SETTINGS cannot change the connection window, only WINDOW_UPDATE
        // can (RFC 9113 §6.9.2), so this raises it from the protocol default.
        try h2.encodeWindowUpdateFrame(
            scratch[cursor..][0 .. h2.frame_header_len + 4],
            0,
            initial_connection_window_increment,
        );
        cursor += h2.frame_header_len + 4;
        runtime.h2_sent_initial_settings = true;
    }
    if (ack_client_settings) {
        try encodeSettingsAck(scratch[cursor..][0..h2.frame_header_len]);
        cursor += h2.frame_header_len;
    }
    if (cursor == 0)
        return false;
    return queueWriteCopy(Worker, worker, runtime, scratch[0..cursor]);
}

fn encodeSettingsAck(out: []u8) !void {
    var ack = h2.FrameHeader{
        .length = 0,
        .frame_type_raw = @intFromEnum(h2.FrameType.settings),
        .frame_type = .settings,
        .flags = h2.Flags.fromByte(0x1),
        .stream_id = 0,
    };
    try ack.encode(out);
}

pub fn queuePingAck(comptime Worker: type, worker: *Worker, runtime: *Slot, payload: []const u8) Http2Failure!bool {
    var scratch: [h2.frame_header_len + 8]u8 = undefined;
    try encodeFrameHeader(scratch[0..h2.frame_header_len], 8, .ping, 0x1, 0);
    @memcpy(scratch[h2.frame_header_len..], payload[0..8]);
    return queueWriteCopy(Worker, worker, runtime, &scratch);
}

/// Gives the connection the write that carries the receive credit it owes
/// outside a drive, once that credit is due (`Slot.h2WindowUpdateDue`): a
/// turn of the lane's loop, whose flush appends the credit
/// (`appendOwedCredit`). A drive that runs now flushes it itself, credit
/// that is not due waits for the next write the connection makes anyway, and
/// a blocked queue's write poll brings the connection back before any write.
pub fn scheduleDueWindowUpdates(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
) LaneFault!void {
    if (!runtime.isOpen() or runtime.h2WritesBlocked() or runtime.h2_driving)
        return;
    if (!runtime.h2WindowUpdateDue())
        return;
    try worker.queueConnectionTurn(runtime);
}

/// Appends a WINDOW_UPDATE for every credit the connection owes to the end
/// of the write queue, the connection's first, then one per stream, and
/// clears what they carry. A stream whose request's END_STREAM arrived drops
/// its own credit instead of sending it (`flow_control.zig`). Returns
/// whether a frame was queued. A queue without room for the frames fails
/// with `error.Http2WriteBackpressure`, and a failed allocation with
/// `error.OutOfMemory`; either keeps the credit owed.
fn appendWindowUpdates(allocator: std.mem.Allocator, runtime: *Slot) !bool {
    const frame_len = h2.frame_header_len + 4;
    var scratch: [frame_len * (stream_table.max_h2_concurrent_streams + 1)]u8 = undefined;
    var cursor: usize = 0;
    if (runtime.h2_pending_connection_window_update != 0) {
        try h2.encodeWindowUpdateFrame(scratch[cursor..][0..frame_len], 0, runtime.h2_pending_connection_window_update);
        cursor += frame_len;
    }
    for (runtime.stream_ids, 0..) |stream_id, position| {
        if (stream_id == 0)
            continue;
        const entry = stream_table.streamAt(runtime, position);
        if (entry.pending_recv_window_update == 0 or entry.request_body_complete)
            continue;
        try h2.encodeWindowUpdateFrame(scratch[cursor..][0..frame_len], stream_id, entry.pending_recv_window_update);
        cursor += frame_len;
    }
    if (cursor != 0)
        try runtime.h2AppendWriteCopy(allocator, scratch[0..cursor]);
    runtime.h2_pending_connection_window_update = 0;
    for (runtime.stream_ids, 0..) |stream_id, position| {
        if (stream_id != 0)
            stream_table.streamAt(runtime, position).pending_recv_window_update = 0;
    }
    return cursor != 0;
}

/// Appends the credit an open connection owes behind the frames about to be
/// written, so it rides their write, or alone once it is due. The queue
/// holds whole frames only, a header block's HEADERS and CONTINUATION frames
/// as one segment, so the frames never land inside a header block; a closing
/// connection appends nothing behind its GOAWAY. A queue without room leaves
/// the credit owed for the write that drains it, and so does a failed
/// allocation while the credit is not due. Due credit no frame can carry asks
/// the lane to close the connection: a client at half its window or below may
/// send nothing more, so no later write would come to carry it.
fn appendOwedCredit(comptime Worker: type, worker: *Worker, runtime: *Slot) LaneFault!void {
    if (!runtime.isOpen() or !runtime.h2HasPendingWindowUpdate())
        return;
    const due = runtime.h2WindowUpdateDue();
    if (!runtime.h2WritesPending() and !due)
        return;
    _ = appendWindowUpdates(worker.service.allocator, runtime) catch |err| switch (err) {
        error.Http2WriteBackpressure => return,
        error.OutOfMemory => {
            if (due)
                return connection.closeForError(Worker, worker, runtime, err);
            return;
        },
        else => |other| return connection.closeForError(Worker, worker, runtime, other),
    };
}

/// Queues waiting response bytes that the send windows now admit, for
/// `stream_filter` alone or, with null, for every stream in turn. The turn
/// starts after the last stream that made progress, so the streams share the
/// connection window. Stops as soon as the queue is blocked.
pub fn flushPendingResponseData(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_filter: ?u32,
) !bool {
    if (!runtime.isOpen() or runtime.h2WritesBlocked())
        return false;

    if (stream_filter) |stream_id|
        return flushPendingResponseStream(Worker, worker, runtime, stream_id);

    var did_work = false;
    var visited: usize = 0;
    const positions = runtime.stream_ids.len;
    var index = runtime.h2_response_rr_cursor % positions;
    while (visited < positions) : (visited += 1) {
        if (runtime.h2PendingResponseStreamIdAt(index)) |stream_id| {
            const stream_work = try flushPendingResponseStream(Worker, worker, runtime, stream_id);
            if (stream_work) {
                runtime.h2_response_rr_cursor = (index + 1) % positions;
                did_work = true;
            }
            if (!runtime.isOpen() or runtime.h2WritesBlocked())
                return did_work;
        }
        index = (index + 1) % positions;
    }
    return did_work;
}

/// Queues what the windows admit of one stream's waiting response. Once its
/// END_STREAM is queued the stream drains out of the table, or closes when
/// its request is done too (`Slot.h2CloseStreamIfDone`).
fn flushPendingResponseStream(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
) !bool {
    const allocator = worker.service.allocator;
    var did_work = false;
    // Nothing appends to the stream during the flush. A pass queues what the
    // windows admit of one chunk, of which a worker's stream holds at most
    // its credit window, or of a server response's one buffer, or the
    // END_STREAM; a pass that queues less than its chunk found a window
    // closed, and the next one stops. The bound covers those passes with one
    // to spare.
    for (0..limits.http_body.INGRESS_RESPONSE_CHUNKS_IN_FLIGHT_MAX + 3) |_| {
        if (!runtime.isOpen() or runtime.h2WritesBlocked())
            break;
        const pending = runtime.h2PendingResponseSlice(stream_id) orelse break;
        const end_stream = runtime.h2PendingResponseEndsStream(stream_id);
        if (pending.len == 0) {
            if (!end_stream)
                break;
            const queued = try queueDataFramesNoWindowAccounting(Worker, worker, runtime, stream_id, "", true);
            try runtime.h2ClearPendingResponseEnd(stream_id);
            _ = runtime.h2MaybeRemoveDrainedResponseStream(allocator, stream_id);
            _ = runtime.h2CloseStreamIfDone(allocator, stream_id);
            return queued or did_work;
        }

        const sent = try queueResponseDataAvailableWindow(Worker, worker, runtime, stream_id, pending, end_stream, runtime.h2PendingResponseChunk(stream_id));
        if (sent == 0)
            break;
        try runtime.h2DropPendingResponsePrefix(allocator, stream_id, sent);
        try retireResponseChunks(Worker, worker, runtime);
        _ = runtime.h2MaybeRemoveDrainedResponseStream(allocator, stream_id);
        _ = runtime.h2CloseStreamIfDone(allocator, stream_id);
        did_work = true;
    }
    return did_work;
}

/// Queues as much of `payload` as the send windows allow and returns how
/// much it took; the caller keeps the rest waiting. `chunk` is the worker's
/// chunk that holds `payload`, whose frames point into it
/// (`queueChunkFrames`), or null for a server response, whose admitted bytes
/// are copied into the queue as frames. The stream records END_STREAM once
/// its frame is queued.
fn queueResponseDataAvailableWindow(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
    chunk: ?*write_queue.ResponseChunk,
) !usize {
    if (payload.len == 0) {
        if (end_stream)
            _ = try queueDataFramesNoWindowAccounting(Worker, worker, runtime, stream_id, "", true);
        return 0;
    }

    const send_len = try runtime.h2AvailableOutboundWindow(stream_id, payload.len);
    if (send_len == 0)
        return 0;
    const final = end_stream and send_len == payload.len;
    const max_frame_size: usize = runtime.h2_peer_settings.max_frame_size;
    if (max_frame_size == 0)
        return error.Http2FrameTooLarge;
    // Both paths cut the bytes into frames of the peer's largest size.
    const frame_count = std.math.divCeil(usize, send_len, max_frame_size) catch unreachable;
    if (chunk) |worker_chunk| {
        try queueChunkFrames(Worker, worker, runtime, stream_id, @constCast(payload[0..send_len]), final, worker_chunk);
        if (final)
            runtime.h2NoteResponseEndQueued(stream_id);
    } else {
        _ = try queueDataFramesNoWindowAccounting(Worker, worker, runtime, stream_id, payload[0..send_len], final);
    }
    try runtime.h2ConsumeOutboundWindow(stream_id, send_len, frame_count);
    return send_len;
}

/// Queues `payload`, which lies in the worker's `chunk`, as DATA frames of at
/// most the peer's frame size: each frame's header in the slot's arena or a
/// copy, then a segment that points into the chunk, so the body's bytes are
/// never copied. The segment list takes its room before the first append, so
/// a failure there leaves the queue as it was for the caller to sort. A
/// failure after it, an allocation for a header the arena has no room for,
/// leaves a header without its payload, which no frame may follow, so it
/// closes the connection without GOAWAY.
fn queueChunkFrames(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    payload: []u8,
    end_stream: bool,
    chunk: *write_queue.ResponseChunk,
) !void {
    std.debug.assert(payload.len != 0);
    const allocator = worker.service.allocator;
    const max_frame_size: usize = runtime.h2_peer_settings.max_frame_size;
    std.debug.assert(max_frame_size != 0);
    const frame_count = std.math.divCeil(usize, payload.len, max_frame_size) catch unreachable;
    try runtime.h2ReserveWriteSegments(allocator, 2 * frame_count, payload.len + frame_count * h2.frame_header_len);
    {
        var appended = false;
        errdefer if (appended) worker.closeRuntimeConnection(runtime, .{ .reason = .allocation_failed, .goaway = null });
        var offset: usize = 0;
        while (offset < payload.len) {
            const frame_len = @min(payload.len - offset, max_frame_size);
            const is_last = offset + frame_len == payload.len;
            var header: [h2.frame_header_len]u8 = undefined;
            try encodeFrameHeader(&header, frame_len, .data, if (is_last and end_stream) 0x1 else 0, stream_id);
            try runtime.h2AppendWriteCopy(allocator, &header);
            appended = true;
            try runtime.h2AppendChunkWrite(allocator, payload[offset..][0..frame_len], chunk);
            offset += frame_len;
        }
    }
    try noteQueued(Worker, worker, runtime);
}

/// Destroys each chunk whose last byte the client socket took
/// (`write_queue.zig:ResponseChunk`) and returns its credit to the request
/// that owned it: every chunk counts first (`responseChunkRetired`), then
/// each owner gets the grant it needs (`grantResponseCredit`), so the chunks
/// of one request that left in one write cost the worker one grant.
fn retireResponseChunks(comptime Worker: type, worker: *Worker, runtime: *Slot) LaneFault!void {
    var retired = runtime.h2TakeRetiredResponseChunks();
    errdefer while (retired) |chunk| {
        retired = chunk.next_retired;
        worker.service.allocator.destroy(chunk);
    };
    var counted = retired;
    while (counted) |chunk| : (counted = chunk.next_retired)
        try worker.responseChunkRetired(chunk.owner);
    while (retired) |chunk| {
        retired = chunk.next_retired;
        const owner = chunk.owner;
        worker.service.allocator.destroy(chunk);
        try worker.grantResponseCredit(owner);
    }
}

/// Queues DATA frames for `payload`, without charging the send windows, and
/// records END_STREAM on the stream when the last frame carries it.
fn queueDataFramesNoWindowAccounting(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
) !bool {
    const queued = if (payload.len == 0) blk: {
        var scratch: [h2.frame_header_len]u8 = undefined;
        try encodeFrameHeader(&scratch, 0, .data, if (end_stream) 0x1 else 0, stream_id);
        break :blk try queueWriteCopy(Worker, worker, runtime, &scratch);
    } else blk: {
        const frame_bytes = try h2.encodeDataFrames(
            worker.service.allocator,
            runtime.h2_peer_settings.max_frame_size,
            stream_id,
            payload,
            end_stream,
        );
        break :blk try queueOwnedWrite(Worker, worker, runtime, frame_bytes);
    };
    if (end_stream)
        runtime.h2NoteResponseEndQueued(stream_id);
    return queued;
}

fn encodeFrameHeader(out: []u8, payload_len: usize, frame_type: h2.FrameType, flags: u8, stream_id: u32) !void {
    if (payload_len > h2.max_frame_payload_len)
        return error.Http2FrameTooLarge;
    var header = h2.FrameHeader{
        .length = @intCast(payload_len),
        .frame_type_raw = @intFromEnum(frame_type),
        .frame_type = frame_type,
        .flags = h2.Flags.fromByte(flags),
        .stream_id = stream_id,
    };
    try header.encode(out);
}

/// Copies `bytes` to the end of the write queue, which the connection's next
/// flush writes (`noteQueued`), and returns true.
fn queueWriteCopy(comptime Worker: type, worker: *Worker, runtime: *Slot, bytes: []const u8) !bool {
    try runtime.h2AppendWriteCopy(worker.service.allocator, bytes);
    try noteQueued(Worker, worker, runtime);
    return true;
}

/// Moves `owned`, which the queue frees once written, to the end of the
/// write queue, which the connection's next flush writes (`noteQueued`), and
/// returns whether it held a byte. On failure `owned` is freed.
fn queueOwnedWrite(comptime Worker: type, worker: *Worker, runtime: *Slot, owned: []u8) !bool {
    if (owned.len == 0)
        return false;
    try runtime.h2AppendOwnedWrite(worker.service.allocator, owned);
    try noteQueued(Worker, worker, runtime);
    return true;
}

/// Makes sure the connection's next flush takes what was just appended. A
/// blocked queue waits for its write poll, a queue at
/// `write_queue.cork_bytes_max` is written now, a drive that runs now writes
/// it at its next flush, and otherwise the connection asks for a turn of the
/// lane's loop, which the pass runs once its completions are handled
/// (`queueConnectionTurn` on `Worker`).
fn noteQueued(comptime Worker: type, worker: *Worker, runtime: *Slot) LaneFault!void {
    if (runtime.h2WritesBlocked())
        return;
    if (runtime.h2QueuedWriteBytes() >= write_queue.cork_bytes_max) {
        _ = try flushPendingWrite(Worker, worker, runtime);
        return;
    }
    if (runtime.h2_driving)
        return;
    try worker.queueConnectionTurn(runtime);
}
