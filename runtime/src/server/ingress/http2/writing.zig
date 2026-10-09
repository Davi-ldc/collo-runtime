//! The writing half of the HTTP/2 connection driver (`connection.zig`), on
//! the lane thread that owns the connection slot: everything bound for the
//! client, encoded into frames and written to the socket, through the
//! connection's write queue (`runner/write_queue.zig`) or straight from the
//! caller's bytes. That covers the answers the lane writes alone
//! (`queueServerResponse`), a worker's response descriptors, response heads
//! encoded with the connection's HPACK encoder, DATA within the send
//! windows, and the control frames: SETTINGS, PING acknowledgements, the
//! WINDOW_UPDATE frames that return receive credit to the client,
//! RST_STREAM and GOAWAY. Worker response heads are decoded within the caps
//! below and forwarded as the worker wrote them, once `response.zig` has
//! checked every header.
//!
//! Invariants:
//! - A response head is encoded when it is queued, and the client decodes
//!   header blocks in the order they reach it, so they must go out in the
//!   order they were encoded: a frame goes straight to the socket only while
//!   nothing is queued.
//! - Body bytes go out only as far as the stream's and the connection's send
//!   windows allow; the rest waits on its stream, and bytes queued after them
//!   append behind them.

const std = @import("std");

const connection = @import("connection.zig");
const connection_slot = @import("../runner/connection_slot.zig");
const fault = @import("../fault.zig");
const response = @import("response.zig");
const server_responses = @import("../server_responses.zig");
const stream_table = @import("../runner/stream_table.zig");
const process = @import("collo_os").process;
const h2 = @import("collo_http").http2;
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const lifecycle = @import("collo_server_lifecycle");

const LaneFault = fault.LaneFault;
const Http2Failure = connection.Http2Failure;
const Slot = connection_slot.Slot;

/// Queued segments one writev covers; `flushPendingWrite` loops for the rest.
const max_writev_segments: usize = 16;
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

    const sent = try queueResponseDataAvailableWindow(Worker, worker, runtime, stream_id, payload, end_stream);
    if (sent == payload.len)
        return sent != 0 or end_stream;
    if (!runtime.isOpen())
        return true;
    try runtime.h2AppendPendingResponse(worker.service.allocator, stream_id, payload[sent..], end_stream);
    return true;
}

/// `queueResponseHead` and `queueResponseChunk` in one write: the head and
/// as much of `payload` as the send windows allow, with the rest left
/// waiting on the stream.
pub fn queueResponseHeadAndChunk(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    status: u16,
    headers: []const ipc.ingress_channel.ResponseHeader,
    payload: []const u8,
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

    const send_len = if (payload.len == 0) 0 else try runtime.h2AvailableOutboundWindow(stream_id, payload.len);
    const final = end_stream and send_len == payload.len;
    const headers_end_stream = payload.len == 0 and end_stream;

    const combined = try h2.encodeHeadersAndDataFrames(
        worker.service.allocator,
        runtime.h2_peer_settings.max_frame_size,
        stream_id,
        encoded_headers,
        headers_end_stream,
        payload[0..send_len],
        final,
    );
    const queued = try queueOwnedWrite(Worker, worker, runtime, combined);
    if (send_len != 0)
        try runtime.h2ConsumeOutboundWindow(stream_id, send_len);
    if (final)
        runtime.h2NoteResponseEndQueued(stream_id);
    if (send_len < payload.len)
        try runtime.h2AppendPendingResponse(worker.service.allocator, stream_id, payload[send_len..], end_stream);
    return queued or send_len != 0 or headers_end_stream;
}

/// How many of a worker's descriptors a queue call consumed, and the body
/// bytes they carried.
pub const QueuedWorkerResponse = struct {
    consumed_descriptors: usize = 1,
    body_bytes: usize = 0,
};

/// Queues a worker's response head and first body chunk as one write when
/// `items` starts with an inline head without END_STREAM followed by an
/// inline chunk of the same request. Returns null, consuming nothing, when
/// it does not, leaving both to `queueWorkerResponseDescriptor`. The caller
/// sorts an error with `fault.classifyResponseQueueError`. On a closing
/// connection both descriptors are consumed and dropped.
pub fn tryQueueWorkerResponseHeadChunkPair(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    items: []ipc.ingress_channel.Received,
) !?QueuedWorkerResponse {
    if (items.len < 2)
        return null;
    const head_received = &items[0];
    const chunk_received = &items[1];
    const head_descriptor = head_received.descriptor;
    const chunk_descriptor = chunk_received.descriptor;
    if (head_descriptor.op != @intFromEnum(ipc.ingress_channel.Op.response_head) or
        chunk_descriptor.op != @intFromEnum(ipc.ingress_channel.Op.response_chunk))
    {
        return null;
    }
    if (!head_descriptor.hasFlag(ipc.ingress_channel.flags.inline_bytes) or
        !chunk_descriptor.hasFlag(ipc.ingress_channel.flags.inline_bytes) or
        head_descriptor.hasFlag(ipc.ingress_channel.flags.end_stream) or
        !sameWorkerResponseIdentity(head_descriptor, chunk_descriptor))
    {
        return null;
    }
    if (!runtime.isOpen())
        return .{ .consumed_descriptors = 2 };
    try runtime.h2ValidateWorkerResponseHeadDescriptor(head_descriptor);
    try runtime.h2ValidateWorkerResponseDescriptor(chunk_descriptor);

    var head = try ipc.ingress_channel.decodeResponseHeadBounded(
        worker.service.allocator,
        head_received.payload,
        max_worker_response_header_count,
        max_worker_response_header_bytes,
    );
    defer head.deinit();
    const end_stream = chunk_descriptor.hasFlag(ipc.ingress_channel.flags.end_stream);
    _ = try queueResponseHeadAndChunk(
        Worker,
        worker,
        runtime,
        head_descriptor.stream_id,
        head.status,
        head.headers,
        chunk_received.payload,
        end_stream,
    );
    try runtime.h2MarkWorkerResponseHeadChunkPairQueued(head_descriptor.stream_id, end_stream);
    _ = runtime.h2CloseStreamIfDone(worker.service.allocator, head_descriptor.stream_id);
    return .{
        .consumed_descriptors = 2,
        .body_bytes = chunk_received.payload.len,
    };
}

/// Queues one worker response descriptor on its stream. The caller has
/// already matched the descriptor to an active request of the sending worker
/// (`resolveDescriptor` in `runner/h2_worker_ipc.zig`). A
/// descriptor the stream's response state does not admit, an unknown op or a
/// malformed payload fails, and the caller sorts the error with
/// `fault.classifyResponseQueueError`. On a closing connection the
/// descriptor is dropped.
pub fn queueWorkerResponseDescriptor(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    received: *ipc.ingress_channel.Received,
) !QueuedWorkerResponse {
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
            return .{};
        },
        @intFromEnum(ipc.ingress_channel.Op.response_chunk) => {
            try runtime.h2ValidateWorkerResponseBodyDescriptor(descriptor);
            if (!descriptor.hasFlag(ipc.ingress_channel.flags.inline_bytes))
                return error.IngressSharedPayloadUnavailable;
            _ = try queueResponseChunk(
                Worker,
                worker,
                runtime,
                descriptor.stream_id,
                received.payload,
                end_stream,
            );
            try runtime.h2MarkWorkerResponseBodyQueued(descriptor.stream_id, end_stream);
            _ = runtime.h2CloseStreamIfDone(worker.service.allocator, descriptor.stream_id);
            return .{ .body_bytes = received.payload.len };
        },
        @intFromEnum(ipc.ingress_channel.Op.response_end) => {
            try runtime.h2ValidateWorkerResponseBodyDescriptor(descriptor);
            if (received.payload.len != 0)
                return error.InvalidPacket;
            _ = try queueResponseChunk(
                Worker,
                worker,
                runtime,
                descriptor.stream_id,
                "",
                true,
            );
            try runtime.h2MarkWorkerResponseBodyQueued(descriptor.stream_id, true);
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

/// True when two descriptors name the same request: lane, slot, generation,
/// stream and request id.
pub fn sameWorkerResponseIdentity(a: ipc.ingress_channel.Descriptor, b: ipc.ingress_channel.Descriptor) bool {
    return a.request_lane_id == b.request_lane_id and
        a.request_slot == b.request_slot and
        a.stream_id == b.stream_id and
        a.request_id == b.request_id and
        a.request_generation == b.request_generation;
}

/// Writes queued bytes until the queue drains or the socket would block, and
/// returns whether anything happened. A socket that would block arms the
/// connection's write poll, and one that failed asks the lane to close the
/// connection. A closing connection writes only while its close flushes the
/// queue.
pub fn flushPendingWrite(comptime Worker: type, worker: *Worker, runtime: *Slot) LaneFault!bool {
    if (!runtime.isLive())
        return false;
    if (runtime.closing) |closing| {
        if (!closing.flush)
            return false;
    }
    var did_work = false;
    while (runtime.h2WritesPending()) {
        const written = writeQueuedSegments(runtime) catch |err|
            return (try connection.actOnClientIo(Worker, worker, runtime, .write, err)) or did_work;
        if (written == 0) {
            // A socket that takes no byte of a write has closed.
            _ = try connection.actOnClientIo(Worker, worker, runtime, .write, error.PeerClosed);
            return true;
        }
        runtime.h2ConsumeQueuedWrite(worker.service.allocator, written);
        runtime.noteProgress(process.monotonicNowNsOrZero());
        did_work = true;
    }
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

/// Sends the window updates buffered for consumed request bytes in one
/// write: one frame for the connection and one for each stream with credit
/// to return. Does nothing while other writes are queued. A connection that
/// cannot take the frames is asked to close, and only lane faults return.
pub fn flushPendingWindowUpdates(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
) LaneFault!bool {
    return queuePendingWindowUpdates(Worker, worker, runtime) catch |err| {
        try connection.closeForError(Worker, worker, runtime, err);
        return true;
    };
}

fn queuePendingWindowUpdates(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
) Http2Failure!bool {
    if (!runtime.isOpen() or runtime.h2WritesPending())
        return false;

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
        if (entry.pending_recv_window_update == 0)
            continue;
        try h2.encodeWindowUpdateFrame(scratch[cursor..][0..frame_len], stream_id, entry.pending_recv_window_update);
        cursor += frame_len;
    }
    if (cursor == 0)
        return false;
    const queued = try queueWriteCopy(Worker, worker, runtime, scratch[0..cursor]);
    runtime.h2_pending_connection_window_update = 0;
    for (runtime.stream_ids, 0..) |stream_id, position| {
        if (stream_id != 0)
            stream_table.streamAt(runtime, position).pending_recv_window_update = 0;
    }
    return queued;
}

/// Sends waiting response bytes that the send windows now admit, for
/// `stream_filter` alone or, with null, for every stream in turn. The turn
/// starts after the last stream that made progress, so the streams share the
/// connection window. Stops as soon as a write stays queued.
pub fn flushPendingResponseData(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_filter: ?u32,
) !bool {
    if (!runtime.isOpen() or runtime.h2WritesPending())
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
            if (!runtime.isOpen() or runtime.h2WritesPending())
                return did_work;
        }
        index = (index + 1) % positions;
    }
    return did_work;
}

/// Sends what the windows admit of one stream's waiting response. Once its
/// END_STREAM is queued the stream drains out of the table, or closes when
/// its request is done too (`Slot.h2CloseStreamIfDone`).
fn flushPendingResponseStream(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
) !bool {
    const allocator = worker.service.allocator;
    const pending = runtime.h2PendingResponseSlice(stream_id) orelse return false;
    const end_stream = runtime.h2PendingResponseEndsStream(stream_id);
    if (pending.len == 0) {
        if (!end_stream)
            return false;
        const queued = try queueDataFramesNoWindowAccounting(Worker, worker, runtime, stream_id, "", true);
        try runtime.h2ClearPendingResponseEnd(stream_id);
        _ = runtime.h2MaybeRemoveDrainedResponseStream(allocator, stream_id);
        _ = runtime.h2CloseStreamIfDone(allocator, stream_id);
        return queued;
    }

    const sent = try queueResponseDataAvailableWindow(Worker, worker, runtime, stream_id, pending, end_stream);
    if (sent == 0)
        return false;
    try runtime.h2DropPendingResponsePrefix(allocator, stream_id, sent);
    _ = runtime.h2MaybeRemoveDrainedResponseStream(allocator, stream_id);
    _ = runtime.h2CloseStreamIfDone(allocator, stream_id);
    return true;
}

/// Sends as much of `payload` as the send windows allow and returns how much
/// it took; the caller keeps the rest waiting. With nothing queued, frames go
/// to the socket straight from `payload`, and a frame the socket took in part
/// has its tail queued. When writes are already queued, or the socket would
/// block before taking a byte, the admitted bytes are copied into the queue
/// as frames. The stream records END_STREAM once its frame is queued.
fn queueResponseDataAvailableWindow(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
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

    if (!runtime.h2WritesPending()) {
        const direct = try writeDataFramesDirectNoWindowAccounting(Worker, worker, runtime, stream_id, payload[0..send_len], final);
        if (direct.committed_payload_len != 0) {
            try runtime.h2ConsumeOutboundWindow(stream_id, direct.committed_payload_len);
            if (final and direct.committed_payload_len == send_len)
                runtime.h2NoteResponseEndQueued(stream_id);
            return direct.committed_payload_len;
        }
        if (direct.did_work or runtime.h2WritesPending())
            return 0;
    }

    _ = try queueDataFramesNoWindowAccounting(Worker, worker, runtime, stream_id, payload[0..send_len], final);
    try runtime.h2ConsumeOutboundWindow(stream_id, send_len);
    return send_len;
}

const DirectDataWriteResult = struct {
    committed_payload_len: usize = 0,
    did_work: bool = false,
};

/// Writes DATA frames for `payload` straight from it until the socket would
/// block. A frame the socket took in part has its tail queued and counts as
/// committed, since the client will receive it whole. The caller charges the
/// send windows for `committed_payload_len`.
fn writeDataFramesDirectNoWindowAccounting(
    comptime Worker: type,
    worker: *Worker,
    runtime: *Slot,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
) !DirectDataWriteResult {
    const budget: usize = @intCast(runtime.h2_peer_settings.max_frame_size);
    if (budget == 0)
        return error.Http2FrameTooLarge;

    var result = DirectDataWriteResult{};
    var offset: usize = 0;
    while (offset < payload.len) {
        const remaining = payload.len - offset;
        const chunk_len = @min(remaining, budget);
        const chunk = payload[offset..][0..chunk_len];
        const is_last = offset + chunk_len == payload.len;
        var header: [h2.frame_header_len]u8 = undefined;
        try encodeFrameHeader(&header, chunk_len, .data, if (is_last and end_stream) 0x1 else 0, stream_id);

        const written = writeDataFrameVectored(runtime.fd, &header, chunk) catch |err| {
            if (try connection.actOnClientIo(Worker, worker, runtime, .write, err))
                result.did_work = true;
            return result;
        };
        if (written == 0) {
            _ = try connection.actOnClientIo(Worker, worker, runtime, .write, error.PeerClosed);
            result.did_work = true;
            return result;
        }
        result.did_work = true;
        runtime.noteProgress(process.monotonicNowNsOrZero());

        const total_len = h2.frame_header_len + chunk.len;
        if (written < total_len) {
            const remaining_wire = try copyRemainingDataFrameWire(worker.service.allocator, &header, chunk, written);
            _ = try queueOwnedWrite(Worker, worker, runtime, remaining_wire);
            result.committed_payload_len += chunk.len;
            return result;
        }

        result.committed_payload_len += chunk.len;
        offset += chunk.len;
    }

    return result;
}

fn writeDataFrameVectored(fd: std.posix.fd_t, header: *const [h2.frame_header_len]u8, payload: []const u8) !usize {
    var iovecs: [2]std.posix.iovec_const = undefined;
    iovecs[0] = .{ .base = header.ptr, .len = header.len };
    iovecs[1] = .{ .base = payload.ptr, .len = payload.len };
    return std.posix.writev(fd, &iovecs);
}

fn copyRemainingDataFrameWire(
    allocator: std.mem.Allocator,
    header: *const [h2.frame_header_len]u8,
    payload: []const u8,
    written: usize,
) ![]u8 {
    const total_len = h2.frame_header_len + payload.len;
    if (written >= total_len)
        return &.{};
    const out = try allocator.alloc(u8, total_len - written);
    var cursor: usize = 0;
    if (written < h2.frame_header_len) {
        const header_remaining = header[written..];
        @memcpy(out[cursor..][0..header_remaining.len], header_remaining);
        cursor += header_remaining.len;
        @memcpy(out[cursor..][0..payload.len], payload);
        return out;
    }
    const payload_offset = written - h2.frame_header_len;
    const payload_remaining = payload[payload_offset..];
    @memcpy(out[cursor..][0..payload_remaining.len], payload_remaining);
    return out;
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

/// Copies `bytes` to the end of the write queue and writes what the socket
/// takes.
fn queueWriteCopy(comptime Worker: type, worker: *Worker, runtime: *Slot, bytes: []const u8) !bool {
    try runtime.h2AppendWriteCopy(worker.service.allocator, bytes);
    return flushPendingWrite(Worker, worker, runtime);
}

/// Moves `owned`, which the queue frees once written, to the end of the
/// write queue and writes what the socket takes. On failure `owned` is
/// freed.
fn queueOwnedWrite(comptime Worker: type, worker: *Worker, runtime: *Slot, owned: []u8) !bool {
    if (owned.len == 0)
        return false;
    try runtime.h2AppendOwnedWrite(worker.service.allocator, owned);
    return flushPendingWrite(Worker, worker, runtime);
}

/// Writes the oldest queued segments, at most `max_writev_segments` of them,
/// in one writev, and returns the bytes the socket took.
fn writeQueuedSegments(runtime: *Slot) !usize {
    var iovecs: [max_writev_segments]std.posix.iovec_const = undefined;
    const vectors = runtime.h2QueuedWriteVectors(&iovecs);
    if (vectors.len == 0)
        return 0;
    return std.posix.writev(runtime.fd, vectors);
}
