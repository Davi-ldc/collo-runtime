//! The HTTP/2 stream table of one client connection (`Slot` in
//! `connection_slot.zig`), on the lane thread that owns the connection: the
//! client stream ids the connection has seen and opened, an entry per stream
//! with its state, the lane request that owns it, its request body's length
//! and END_STREAM and the lane's record of the worker's response on it, and
//! the removal of a stream that closes, is reset or loses its request. An
//! entry's windows and buffered request body belong to `flow_control.zig`,
//! and its buffered response to `write_queue.zig`.
//!
//! Invariants:
//! - A stream keeps its entry while it is open in the protocol (RFC 9113
//!   §5.1) or still holds request bytes for its worker, and
//!   `ingress_channel_count`, which `max_h2_concurrent_streams` bounds,
//!   counts the entries. A stream leaves the table, and stops counting
//!   against the bound, once its response's END_STREAM is queued and its
//!   request's END_STREAM has arrived (`h2CloseStreamIfDone`), or once either
//!   end resets it (`h2MarkStreamReset`). The lane request that served the
//!   stream may still be finishing then.
//! - An entry is `preparing` from its HEADERS until a worker takes its
//!   request, then `active`. A lane request may own a `preparing` entry while
//!   it waits for a worker, and always owns an `active` one.
//! - An entry whose request left before the response's END_STREAM was queued
//!   stays `draining_response` while its buffered tail goes out, and only a
//!   tail that carries END_STREAM is kept. A tail without it is dropped and
//!   the stream reset, since nothing else would end the stream and the client
//!   would wait for the rest of the response until its own timeout.
//!   `h2StreamWillDeliverResponseTail` answers by the same rule.
//! - The lane's record of the worker's response admits one head, then the
//!   body, and nothing after END_STREAM, and it is the one source for whether
//!   a head went out (`responseHeadQueued`).

const std = @import("std");

const http = @import("collo_http");
const h2 = http.http2;
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const ingress_state = @import("../state.zig");
const connection_slot = @import("connection_slot.zig");
const flow_control = @import("flow_control.zig");
const write_queue = @import("write_queue.zig");

const Slot = connection_slot.Slot;

pub const max_h2_concurrent_streams: usize = 64;
/// Client stream ids, the last one and those below it, whose opening a
/// connection remembers (`Slot.h2_opened_client_streams`, one bit each).
pub const opened_client_streams_window: u32 = @bitSizeOf(u64);

pub fn h2AcceptClientStreamId(self: *Slot, stream_id: u32) !void {
    if (stream_id == 0 or (stream_id & 1) == 0)
        return error.Http2ProtocolError;
    if (stream_id <= self.h2_last_client_stream_id)
        return error.Http2ProtocolError;
    // Both ids are odd, or the last is 0 with no stream opened, so the
    // step is a whole number of client ids.
    const step = (stream_id - self.h2_last_client_stream_id) / 2;
    self.h2_opened_client_streams = if (step < opened_client_streams_window)
        (self.h2_opened_client_streams << @intCast(step)) | 1
    else
        1;
    self.h2_last_client_stream_id = stream_id;
}

/// Whether the client opened `stream_id`, an id it has used
/// (`h2HasSeenClientStreamId`). An id older than the window the
/// connection remembers counts as opened, so its frames are ignored as a
/// closed stream's.
pub fn h2ClientOpenedStreamId(self: *const Slot, stream_id: u32) bool {
    std.debug.assert(self.h2HasSeenClientStreamId(stream_id));
    const distance = (self.h2_last_client_stream_id - stream_id) / 2;
    if (distance >= opened_client_streams_window)
        return true;
    return (self.h2_opened_client_streams >> @intCast(distance)) & 1 == 1;
}

pub fn h2ReserveStream(self: *Slot, stream_id: u32) !void {
    if (h2StreamIndex(self, stream_id) != null)
        return error.Http2StreamAlreadyOpen;
    if (self.ingress_channel_count == self.ingress_channels.len)
        return error.Http2TooManyConcurrentStreams;
    for (&self.ingress_channels) |*entry| {
        if (entry.state != .vacant)
            continue;
        entry.* = .{
            .state = .preparing,
            .stream_id = stream_id,
            .send_window = self.h2_peer_settings.initial_window_size,
            .recv_window = limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES,
        };
        self.ingress_channel_count += 1;
        return;
    }
    unreachable;
}

pub fn h2SetRequestBodyExpectation(
    self: *Slot,
    stream_id: u32,
    framing: ipc.RequestBodyFraming,
    content_length: ?usize,
    end_stream: bool,
) !void {
    const index = h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (entry.state != .preparing)
        return error.Http2ProtocolError;
    switch (framing) {
        .none => {
            if (!end_stream)
                return error.Http2ProtocolError;
            if (content_length) |length| {
                try http.framing.validateContentLength(length, limits.http_body.MATERIALIZED_BODY_BYTES_MAX);
                if (length != 0)
                    return error.Http2ContentLengthMismatch;
            }
        },
        .ingress_channel => {
            if (end_stream)
                return error.Http2ProtocolError;
            if (content_length) |length|
                try http.framing.validateContentLength(length, limits.http_body.MATERIALIZED_BODY_BYTES_MAX);
        },
    }
    entry.request_body_expected_len = content_length;
    entry.request_body_received_len = 0;
    entry.request_body_complete = end_stream;
}

pub fn h2RecordRequestBodyChunk(self: *Slot, stream_id: u32, byte_len: usize, end_stream: bool) !void {
    const index = h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    switch (entry.state) {
        .preparing, .active => {},
        .vacant, .draining_response => return error.Http2ProtocolError,
    }
    if (entry.request_body_complete)
        return error.Http2ProtocolError;
    const received_len = std.math.add(usize, entry.request_body_received_len, byte_len) catch return error.Http2ContentLengthMismatch;
    if (entry.request_body_expected_len) |expected_len| {
        if (received_len > expected_len)
            return error.Http2ContentLengthMismatch;
    } else if (received_len > limits.http_body.MATERIALIZED_BODY_BYTES_MAX) {
        return error.RequestTooLarge;
    }
    entry.request_body_received_len = received_len;
    if (end_stream) {
        if (entry.request_body_expected_len) |expected_len| {
            if (received_len != expected_len)
                return error.Http2ContentLengthMismatch;
        }
        entry.request_body_complete = true;
    }
}

/// Records the lane request that took a `preparing` stream at admission
/// and waits for a worker, so a reset of the stream reaches the request
/// (`h2MarkStreamReset`). Fails with `error.Http2UnknownStream` for a
/// stream the table does not hold, and `error.Http2StreamStateMismatch`
/// for one that is not `preparing` or already has a request.
pub fn h2BindRequest(self: *Slot, stream_id: u32, request_key: ingress_state.RequestKey, request_id: u64) !void {
    const index = h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (entry.state != .preparing)
        return error.Http2StreamStateMismatch;
    if (entry.request != null)
        return error.Http2StreamStateMismatch;
    entry.request = .{ .key = request_key, .id = request_id };
}

/// Hands a `preparing` stream to the worker that took its request. Fails
/// with `error.Http2UnknownStream` for a stream the table no longer
/// holds, since it was reset or closed, and with
/// `error.Http2StreamStateMismatch` for one that is not `preparing` or
/// is bound to another request.
pub fn h2ActivateStream(self: *Slot, stream_id: u32, request_key: ingress_state.RequestKey, request_id: u64) !void {
    const index = h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (entry.state != .preparing)
        return error.Http2StreamStateMismatch;
    if (entry.request) |bound| {
        if (!bound.key.eql(request_key) or bound.id != request_id)
            return error.Http2StreamStateMismatch;
    }
    entry.state = .active;
    entry.request = .{ .key = request_key, .id = request_id };
}

/// Ends a stream that either end reset. Its buffered request body and
/// response are dropped and it leaves the table, so it no longer counts
/// against the concurrency cap and a late frame on it reads as one on a
/// closed stream. Returns the lane request that owned the stream, which
/// the caller resets toward its worker or takes out of its wait; null
/// when the table does not hold the stream or no request owns it.
pub fn h2MarkStreamReset(self: *Slot, allocator: std.mem.Allocator, stream_id: u32) ?ingress_state.RequestKey {
    const index = h2StreamIndex(self, stream_id) orelse return null;
    const entry = &self.ingress_channels[index];
    const request = entry.request;
    removeEntry(self, allocator, entry);
    return if (request) |owner| owner.key else null;
}

/// The request a worker serves on `stream_id`, or null when the stream
/// is not `active`: a request still waiting for a worker buffers its body
/// on the stream instead.
pub fn h2ActiveRequestKey(self: *Slot, stream_id: u32) ?ingress_state.RequestKey {
    const index = h2StreamIndex(self, stream_id) orelse return null;
    const entry = &self.ingress_channels[index];
    if (entry.state != .active)
        return null;
    const request = entry.request orelse return null;
    return request.key;
}

pub fn h2ValidateWorkerResponseDescriptor(self: *const Slot, descriptor: ipc.ingress_channel.Descriptor) !void {
    const index = h2StreamIndex(self, descriptor.stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (entry.state != .active)
        return error.InvalidH2WorkerOutboundDescriptor;
    const request = entry.request orelse return error.InvalidH2WorkerOutboundDescriptor;
    if (request.id != descriptor.request_id or
        request.key.lane_id != descriptor.request_lane_id or
        request.key.slot != descriptor.request_slot or
        request.key.generation != descriptor.request_generation)
    {
        return error.InvalidH2StreamIdentity;
    }
}

pub fn h2ValidateWorkerResponseHeadDescriptor(self: *const Slot, descriptor: ipc.ingress_channel.Descriptor) !void {
    try self.h2ValidateWorkerResponseDescriptor(descriptor);
    const index = h2StreamIndex(self, descriptor.stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (entry.worker_response_head_sent or entry.worker_response_ended)
        return error.InvalidH2WorkerOutboundDescriptor;
}

pub fn h2ValidateWorkerResponseBodyDescriptor(self: *const Slot, descriptor: ipc.ingress_channel.Descriptor) !void {
    try self.h2ValidateWorkerResponseDescriptor(descriptor);
    const index = h2StreamIndex(self, descriptor.stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (!entry.worker_response_head_sent or entry.worker_response_ended)
        return error.InvalidH2WorkerOutboundDescriptor;
}

pub fn h2MarkWorkerResponseHeadQueued(self: *Slot, stream_id: u32, end_stream: bool) !void {
    const index = h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (entry.state != .active or entry.worker_response_head_sent or entry.worker_response_ended)
        return error.InvalidH2WorkerOutboundDescriptor;
    entry.worker_response_head_sent = true;
    if (end_stream)
        entry.worker_response_ended = true;
}

pub fn h2MarkWorkerResponseBodyQueued(self: *Slot, stream_id: u32, end_stream: bool) !void {
    const index = h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (entry.state != .active or !entry.worker_response_head_sent or entry.worker_response_ended)
        return error.InvalidH2WorkerOutboundDescriptor;
    if (end_stream)
        entry.worker_response_ended = true;
}

pub fn h2MarkWorkerResponseHeadChunkPairQueued(self: *Slot, stream_id: u32, end_stream: bool) !void {
    const index = h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (entry.state != .active or entry.worker_response_head_sent or entry.worker_response_ended)
        return error.InvalidH2WorkerOutboundDescriptor;
    entry.worker_response_head_sent = true;
    if (end_stream)
        entry.worker_response_ended = true;
}

pub fn h2WorkerResponseEnded(self: *const Slot, stream_id: u32) bool {
    const index = h2StreamIndex(self, stream_id) orelse return false;
    return self.ingress_channels[index].worker_response_ended;
}

/// Whether the worker's response head for `stream_id` is queued toward
/// the client, by the lane's own record (`worker_response_head_sent`),
/// which is the one source for that fact: a request that fails after it
/// is answered with RST_STREAM, never with a second head. False for a
/// stream the table no longer holds, which has nothing left to answer.
pub fn responseHeadQueued(self: *const Slot, stream_id: u32) bool {
    const index = h2StreamIndex(self, stream_id) orelse return false;
    return self.ingress_channels[index].worker_response_head_sent;
}

/// Records that the response's END_STREAM for `stream_id` is in the
/// write queue. Nothing for a stream the table does not hold.
pub fn h2NoteResponseEndQueued(self: *Slot, stream_id: u32) void {
    const index = h2StreamIndex(self, stream_id) orelse return;
    self.ingress_channels[index].response_end_queued = true;
}

/// Closes an `active` stream both ends are done with: its response's
/// END_STREAM is queued, its request's END_STREAM arrived, and every
/// request byte the lane held reached the worker. The stream leaves the
/// table and stops counting against the concurrency cap at once, while
/// its request finishes on its own when the worker's completion comes.
/// Returns whether the stream closed.
pub fn h2CloseStreamIfDone(self: *Slot, allocator: std.mem.Allocator, stream_id: u32) bool {
    const index = h2StreamIndex(self, stream_id) orelse return false;
    const entry = &self.ingress_channels[index];
    if (entry.state != .active)
        return false;
    if (!entry.response_end_queued)
        return false;
    if (!entry.request_body_complete)
        return false;
    if (entry.pending_body_len != 0 or entry.pending_body_complete)
        return false;
    removeEntry(self, allocator, entry);
    return true;
}

pub fn h2StreamState(self: *const Slot, stream_id: u32) ?H2StreamState {
    const index = h2StreamIndex(self, stream_id) orelse return null;
    return self.ingress_channels[index].state;
}

pub fn h2HasSeenClientStreamId(self: *const Slot, stream_id: u32) bool {
    return stream_id != 0 and (stream_id & 1) == 1 and stream_id <= self.h2_last_client_stream_id;
}

pub fn h2RemoveStream(self: *Slot, allocator: std.mem.Allocator, stream_id: u32) bool {
    const index = h2StreamIndex(self, stream_id) orelse return false;
    removeEntry(self, allocator, &self.ingress_channels[index]);
    return true;
}

/// Whether the response on the stream of the request `request_key` ends
/// on its own once the request leaves it (`h2RemoveRequest` answering
/// `closed` or `draining`): its END_STREAM is queued, or the buffered
/// tail carries it. A dead worker's stream where this is false needs
/// RST_STREAM, or its client waits for the rest of the response until
/// its own timeout.
pub fn h2StreamWillDeliverResponseTail(self: *Slot, request_key: ingress_state.RequestKey) bool {
    for (&self.ingress_channels) |*entry| {
        if (entry.state != .active)
            continue;
        const request = entry.request orelse continue;
        if (request.key.eql(request_key))
            return entry.response_end_queued or entry.pending_response_end_stream;
    }
    return false;
}

/// Takes the request `request_key` off its stream when the lane is done
/// with the request, dropping the request body it still held, and says
/// how the stream ends (`StreamRelease`). On `unfinished` the caller
/// resets the stream (RST_STREAM).
pub fn h2RemoveRequest(self: *Slot, allocator: std.mem.Allocator, request_key: ingress_state.RequestKey) StreamRelease {
    for (&self.ingress_channels) |*entry| {
        const request = entry.request orelse continue;
        if (request.key.eql(request_key))
            return settleRequestless(self, allocator, entry);
    }
    return .none;
}

/// Ends a `preparing` or `draining_response` stream the lane answered on
/// its own: it drains a tail that carries END_STREAM and otherwise leaves
/// the table. Returns false when the stream is in another state or the
/// table does not hold it.
pub fn h2FinishLocalResponse(self: *Slot, allocator: std.mem.Allocator, stream_id: u32) bool {
    const index = h2StreamIndex(self, stream_id) orelse return false;
    const entry = &self.ingress_channels[index];
    switch (entry.state) {
        .preparing, .draining_response => {
            _ = settleRequestless(self, allocator, entry);
            return true;
        },
        .active, .vacant => return false,
    }
}

/// Takes the request off an `active` stream the lane has just answered
/// on its own, and returns it so the caller can cancel it toward its
/// worker; the stream ends as `h2FinishLocalResponse` says.
pub fn h2DetachActiveRequestForLocalResponse(self: *Slot, allocator: std.mem.Allocator, stream_id: u32) ?ingress_state.RequestKey {
    const index = h2StreamIndex(self, stream_id) orelse return null;
    const entry = &self.ingress_channels[index];
    if (entry.state != .active)
        return null;
    const request = entry.request orelse return null;
    _ = settleRequestless(self, allocator, entry);
    return request.key;
}

/// Ends `entry`'s tie to a request: the body it held for the request is
/// dropped, and the stream drains a tail that carries END_STREAM or
/// leaves the table, a tail without END_STREAM dropped with it.
fn settleRequestless(self: *Slot, allocator: std.mem.Allocator, entry: *H2StreamEntry) StreamRelease {
    flow_control.releasePendingBody(self, allocator, entry);
    entry.request = null;
    if (entry.response_end_queued) {
        removeEntry(self, allocator, entry);
        return .closed;
    }
    if (entry.pending_response_end_stream) {
        entry.state = .draining_response;
        return .draining;
    }
    removeEntry(self, allocator, entry);
    return .unfinished;
}

/// Takes `entry` out of the table, freeing what it buffered.
pub fn removeEntry(self: *Slot, allocator: std.mem.Allocator, entry: *H2StreamEntry) void {
    flow_control.releasePendingBody(self, allocator, entry);
    write_queue.releasePendingResponse(self, allocator, entry);
    entry.* = .{};
    if (self.ingress_channel_count != 0)
        self.ingress_channel_count -= 1;
}

pub fn h2StreamIndex(self: *const Slot, stream_id: u32) ?usize {
    for (self.ingress_channels, 0..) |entry, index| {
        if (entry.state != .vacant and entry.stream_id == stream_id)
            return index;
    }
    return null;
}

pub const H2StreamState = enum {
    vacant,
    preparing,
    active,
    draining_response,
};

/// The lane request that owns a stream.
pub const StreamRequest = struct {
    key: ingress_state.RequestKey,
    /// The request id a worker's descriptors for the stream must carry.
    id: u64,
};

/// How a stream ends when its request leaves it (`Slot.h2RemoveRequest`).
pub const StreamRelease = enum {
    /// No stream holds the request: it closed, was reset, or never had one.
    none,
    /// The response's END_STREAM was queued, and the stream left the table.
    closed,
    /// The buffered tail, END_STREAM included, waits on the stream, which
    /// stays in the table until it goes out.
    draining,
    /// The response never ended. The stream left the table with its
    /// buffered bytes dropped, and the caller resets it (RST_STREAM), since
    /// nothing else ends it and its client would wait until its own timeout.
    unfinished,
};

pub const H2StreamEntry = struct {
    state: H2StreamState = .vacant,
    stream_id: u32 = 0,
    /// Set by `h2BindRequest` or `h2ActivateStream`: always for an `active`
    /// entry, and for a `preparing` one whose request waits for a worker.
    request: ?StreamRequest = null,
    send_window: i64 = h2.default_initial_window_size,
    recv_window: i64 = limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES,
    pending_recv_window_update: u32 = 0,
    request_body_expected_len: ?usize = 0,
    request_body_received_len: usize = 0,
    /// The request's END_STREAM arrived.
    request_body_complete: bool = false,
    pending_body: []u8 = &.{},
    pending_body_len: usize = 0,
    pending_body_complete: bool = false,
    pending_body_window_credit: usize = 0,
    pending_response: []u8 = &.{},
    pending_response_start: usize = 0,
    pending_response_end_stream: bool = false,
    /// The response's END_STREAM is in the connection's write queue.
    response_end_queued: bool = false,
    worker_response_head_sent: bool = false,
    worker_response_ended: bool = false,

    pub fn deinit(self: *H2StreamEntry, allocator: std.mem.Allocator) void {
        if (self.pending_body.len != 0)
            allocator.free(self.pending_body);
        if (self.pending_response.len != 0)
            allocator.free(self.pending_response);
        self.* = .{};
    }
};
