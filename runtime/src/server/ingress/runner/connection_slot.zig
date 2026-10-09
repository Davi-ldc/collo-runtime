//! One client connection of an ingress lane in the server, as the lane's
//! runner holds it (`Slot`), on the lane's io_uring thread, which alone
//! touches it and takes no lock. A slot sits at its connection's index in
//! the lane's connection slab (`state.zig`) under the same key, and borrows
//! the socket the slab owns. This file holds the slot's own state: the
//! socket with its TLS session, peer address and kTLS rekey state, its phase
//! from the TLS handshake to HTTP/2, its read buffer, its polls and its
//! place on the ready queue, the lane's decision to close it, its
//! pre-request deadline, and the connection-level HTTP/2 state, which is the
//! preface and SETTINGS exchange, the HPACK coders and the header block
//! being reassembled. The stream table is in `stream_table.zig`, flow
//! control and the buffered request bodies in `flow_control.zig`, and the
//! write queue and the buffered responses in `write_queue.zig`. `Slot`
//! declares as its methods the functions of those files that the rest of
//! the lane calls on a connection; the helpers the four files share, such as
//! `stream_table.removeEntry`, stay off it.
//!
//! Invariants:
//! - A connection the lane decided to close (`closing`) reads and queues no
//!   more frames; `connection_flow.zig` finishes the close.
//! - The slot is in the lane's pre-request deadline heap exactly while
//!   `pre_request_deadline_active` is set (`deadline_driver.zig`).
//! - One header block at a time is reassembled, on one stream, within
//!   `limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES` and
//!   `max_h2_header_block_frames` frames.
//! - `deinitProtocolState` frees whatever the connection's HTTP/2 state
//!   allocated, and the teardown (`connection_flow.zig`) runs it before it
//!   resets the slot, so a field that allocates is freed there.

const std = @import("std");

const common_io = @import("collo_common_io");
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const tls_mod = @import("../../tls/root.zig");
const ktls = @import("collo_ktls");
const limits = @import("collo_limits");
const fault = @import("../fault.zig");
const ingress_state = @import("../state.zig");
const PeerAddress = @import("../peer_address.zig").PeerAddress;
const flow_control = @import("flow_control.zig");
const stream_table = @import("stream_table.zig");
const write_queue = @import("write_queue.zig");

const H2StreamEntry = stream_table.H2StreamEntry;
const H2WriteSegment = write_queue.H2WriteSegment;
const max_h2_concurrent_streams = stream_table.max_h2_concurrent_streams;

pub const max_h2_header_block_frames: usize = 128;

pub const Phase = enum {
    vacant,
    tls_handshake,
    http2_connection,
};

pub fn connectionGenerationTag(key: ingress_state.ConnectionKey) u32 {
    return @truncate(key.generation);
}

pub const Slot = struct {
    active: bool = false,
    key: ingress_state.ConnectionKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    fd: std.posix.fd_t = -1,
    /// Read once at accept; the access log records it as the client IP.
    peer_address: PeerAddress = .{},
    state: Phase = .vacant,
    buffer_index: u32 = ingress_state.invalid_slot,
    queued: bool = false,
    wait_events: i16 = 0,
    registered_wait_events: i16 = 0,
    read_len: usize = 0,
    scan_start: usize = 0,
    tls_connection: ?tls_mod.BoringSslConnection = null,
    h2_preface_complete: bool = false,
    h2_sent_initial_settings: bool = false,
    h2_received_initial_client_settings: bool = false,
    h2_last_client_stream_id: u32 = 0,
    /// Which of the client's last `opened_client_streams_window` stream ids
    /// it opened: bit `i` stands for `h2_last_client_stream_id - 2 * i`. A
    /// HEADERS frame on a lower id the client never opened is a protocol
    /// error (RFC 9113 §5.1.1), while one on a stream it opened, which has
    /// closed since, may have crossed the stream's reset and is ignored.
    h2_opened_client_streams: u64 = 0,
    h2_peer_settings: h2.SettingsState = .{},
    h2_hpack_decoder: hpack.Decoder = .{},
    h2_hpack_encoder: hpack.Encoder = .{},
    h2_header_block_stream_id: u32 = 0,
    h2_header_block_kind: H2HeaderBlockKind = .request_headers,
    h2_header_block_end_stream: bool = false,
    h2_header_block: []u8 = &.{},
    h2_header_block_len: usize = 0,
    h2_header_block_frame_count: usize = 0,
    ingress_channels: [max_h2_concurrent_streams]H2StreamEntry = [_]H2StreamEntry{.{}} ** max_h2_concurrent_streams,
    ingress_channel_count: usize = 0,
    h2_pending_body_bytes: usize = 0,
    h2_pending_response_bytes: usize = 0,
    h2_response_rr_cursor: usize = 0,
    h2_connection_send_window: i64 = h2.default_initial_window_size,
    h2_connection_recv_window: i64 = limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES,
    h2_pending_connection_window_update: u32 = 0,
    h2_write_buffer: [h2.frame_header_len * 2]u8 = undefined,
    h2_write_inline_segment: H2WriteSegment = .{},
    h2_write_inline_active: bool = false,
    h2_write_queue: std.ArrayListUnmanaged(H2WriteSegment) = .empty,
    h2_write_queue_start: usize = 0,
    h2_write_len: usize = 0,
    h2_write_offset: usize = 0,
    /// Set once the lane decided to close the connection, and kept until
    /// `connection_flow.zig` tears it down.
    closing: ?Closing = null,
    pre_request_deadline_active: bool = false,
    pre_request_deadline_ns: u64 = 0,
    pre_request_deadline_heap: common_io.heap.IntrusiveHeapField(Slot) = .{},
    ktls_rekey_state: ktls.RekeyState = ktls.RekeyState.disabled(),

    /// The connection is live and the lane has not decided to close it: it
    /// reads frames and takes new ones to queue.
    pub fn isOpen(self: *const Slot) bool {
        return self.active and self.closing == null;
    }

    pub fn deinitProtocolState(self: *Slot, allocator: std.mem.Allocator) void {
        self.h2_hpack_decoder.deinit();
        self.h2_hpack_encoder.deinit();
        self.h2ClearHeaderBlock(allocator);
        write_queue.h2DeinitWriteQueue(self, allocator);
        self.h2_received_initial_client_settings = false;
        self.h2_last_client_stream_id = 0;
        self.h2_opened_client_streams = 0;
        self.h2_header_block_stream_id = 0;
        self.h2_header_block_kind = .request_headers;
        self.h2_header_block_end_stream = false;
        self.h2_header_block_len = 0;
        self.h2_header_block_frame_count = 0;
        for (&self.ingress_channels) |*entry|
            entry.deinit(allocator);
        self.ingress_channels = [_]H2StreamEntry{.{}} ** max_h2_concurrent_streams;
        self.ingress_channel_count = 0;
        self.h2_pending_body_bytes = 0;
        self.h2_pending_response_bytes = 0;
        self.h2_response_rr_cursor = 0;
        self.h2_connection_send_window = h2.default_initial_window_size;
        self.h2_connection_recv_window = limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES;
        self.h2_pending_connection_window_update = 0;
    }

    pub fn h2HasPendingHeaderBlock(self: *const Slot) bool {
        return self.h2_header_block_stream_id != 0;
    }

    pub fn h2BeginHeaderBlock(
        self: *Slot,
        allocator: std.mem.Allocator,
        stream_id: u32,
        payload: []const u8,
        end_stream: bool,
        kind: H2HeaderBlockKind,
    ) !void {
        if (self.h2HasPendingHeaderBlock())
            return error.Http2ProtocolError;
        if (payload.len > limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES)
            return error.Http2HeaderBlockTooLarge;
        if (payload.len != 0) {
            self.h2_header_block = try allocator.alloc(u8, payload.len);
            @memcpy(self.h2_header_block, payload);
            self.h2_header_block_len = payload.len;
        } else {
            self.h2_header_block = &.{};
            self.h2_header_block_len = 0;
        }
        self.h2_header_block_stream_id = stream_id;
        self.h2_header_block_kind = kind;
        self.h2_header_block_end_stream = end_stream;
        self.h2_header_block_frame_count = 1;
    }

    pub fn h2AppendHeaderBlock(
        self: *Slot,
        allocator: std.mem.Allocator,
        stream_id: u32,
        payload: []const u8,
    ) !void {
        if (self.h2_header_block_stream_id == 0 or self.h2_header_block_stream_id != stream_id)
            return error.Http2ProtocolError;
        if (self.h2_header_block_frame_count >= max_h2_header_block_frames)
            return error.Http2EnhanceYourCalm;
        const new_frame_count = self.h2_header_block_frame_count + 1;
        const new_len = std.math.add(usize, self.h2_header_block_len, payload.len) catch return error.Http2HeaderBlockTooLarge;
        if (new_len > limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES)
            return error.Http2HeaderBlockTooLarge;
        if (payload.len == 0) {
            self.h2_header_block_frame_count = new_frame_count;
            return;
        }
        const old_len = self.h2_header_block_len;
        try self.h2EnsureHeaderBlockCapacity(allocator, new_len);
        @memcpy(self.h2_header_block[old_len..new_len], payload);
        self.h2_header_block_len = new_len;
        self.h2_header_block_frame_count = new_frame_count;
    }

    pub fn h2TakeHeaderBlock(self: *Slot) PendingH2HeaderBlock {
        const block = PendingH2HeaderBlock{
            .stream_id = self.h2_header_block_stream_id,
            .kind = self.h2_header_block_kind,
            .bytes = self.h2_header_block[0..self.h2_header_block_len],
            .allocation = self.h2_header_block,
            .end_stream = self.h2_header_block_end_stream,
        };
        self.h2_header_block_stream_id = 0;
        self.h2_header_block_kind = .request_headers;
        self.h2_header_block_end_stream = false;
        self.h2_header_block = &.{};
        self.h2_header_block_len = 0;
        self.h2_header_block_frame_count = 0;
        return block;
    }

    pub fn h2ClearHeaderBlock(self: *Slot, allocator: std.mem.Allocator) void {
        if (self.h2_header_block.len != 0)
            allocator.free(self.h2_header_block);
        self.h2_header_block_stream_id = 0;
        self.h2_header_block_kind = .request_headers;
        self.h2_header_block_end_stream = false;
        self.h2_header_block = &.{};
        self.h2_header_block_len = 0;
        self.h2_header_block_frame_count = 0;
    }

    fn h2EnsureHeaderBlockCapacity(self: *Slot, allocator: std.mem.Allocator, needed_len: usize) !void {
        if (needed_len <= self.h2_header_block.len)
            return;
        var new_capacity = @max(self.h2_header_block.len * 2, needed_len);
        if (new_capacity < 256)
            new_capacity = 256;
        if (new_capacity > limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES)
            new_capacity = limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES;
        if (new_capacity < needed_len)
            return error.Http2HeaderBlockTooLarge;
        self.h2_header_block = try allocator.realloc(self.h2_header_block, new_capacity);
    }

    // What the lane calls on a connection whose state the stream table,
    // flow control and the write queue own.
    pub const h2AcceptClientStreamId = stream_table.h2AcceptClientStreamId;
    pub const h2ClientOpenedStreamId = stream_table.h2ClientOpenedStreamId;
    pub const h2ReserveStream = stream_table.h2ReserveStream;
    pub const h2SetRequestBodyExpectation = stream_table.h2SetRequestBodyExpectation;
    pub const h2RecordRequestBodyChunk = stream_table.h2RecordRequestBodyChunk;
    pub const h2BindRequest = stream_table.h2BindRequest;
    pub const h2ActivateStream = stream_table.h2ActivateStream;
    pub const h2MarkStreamReset = stream_table.h2MarkStreamReset;
    pub const h2ActiveRequestKey = stream_table.h2ActiveRequestKey;
    pub const h2ValidateWorkerResponseDescriptor = stream_table.h2ValidateWorkerResponseDescriptor;
    pub const h2ValidateWorkerResponseHeadDescriptor = stream_table.h2ValidateWorkerResponseHeadDescriptor;
    pub const h2ValidateWorkerResponseBodyDescriptor = stream_table.h2ValidateWorkerResponseBodyDescriptor;
    pub const h2MarkWorkerResponseHeadQueued = stream_table.h2MarkWorkerResponseHeadQueued;
    pub const h2MarkWorkerResponseBodyQueued = stream_table.h2MarkWorkerResponseBodyQueued;
    pub const h2MarkWorkerResponseHeadChunkPairQueued = stream_table.h2MarkWorkerResponseHeadChunkPairQueued;
    pub const h2WorkerResponseEnded = stream_table.h2WorkerResponseEnded;
    pub const responseHeadQueued = stream_table.responseHeadQueued;
    pub const h2NoteResponseEndQueued = stream_table.h2NoteResponseEndQueued;
    pub const h2CloseStreamIfDone = stream_table.h2CloseStreamIfDone;
    pub const h2StreamState = stream_table.h2StreamState;
    pub const h2HasSeenClientStreamId = stream_table.h2HasSeenClientStreamId;
    pub const h2RemoveStream = stream_table.h2RemoveStream;
    pub const h2StreamWillDeliverResponseTail = stream_table.h2StreamWillDeliverResponseTail;
    pub const h2RemoveRequest = stream_table.h2RemoveRequest;
    pub const h2FinishLocalResponse = stream_table.h2FinishLocalResponse;
    pub const h2DetachActiveRequestForLocalResponse = stream_table.h2DetachActiveRequestForLocalResponse;

    pub const h2AppendPreparingBody = flow_control.h2AppendPreparingBody;
    pub const h2AppendActivePendingBody = flow_control.h2AppendActivePendingBody;
    pub const h2EnsureActivePendingBodyCapacity = flow_control.h2EnsureActivePendingBodyCapacity;
    pub const h2HasPendingBody = flow_control.h2HasPendingBody;
    pub const h2PendingBodyView = flow_control.h2PendingBodyView;
    pub const h2TakePendingBody = flow_control.h2TakePendingBody;
    pub const h2ApplyPeerInitialStreamWindow = flow_control.h2ApplyPeerInitialStreamWindow;
    pub const h2IncreaseConnectionSendWindow = flow_control.h2IncreaseConnectionSendWindow;
    pub const h2IncreaseStreamSendWindow = flow_control.h2IncreaseStreamSendWindow;
    pub const h2AvailableOutboundWindow = flow_control.h2AvailableOutboundWindow;
    pub const h2ConsumeOutboundWindow = flow_control.h2ConsumeOutboundWindow;
    pub const h2ConsumeInboundWindow = flow_control.h2ConsumeInboundWindow;
    pub const h2DiscardInboundData = flow_control.h2DiscardInboundData;
    pub const h2BufferInboundWindowUpdate = flow_control.h2BufferInboundWindowUpdate;
    pub const h2RestoreTakenPendingBodyConnectionCredit = flow_control.h2RestoreTakenPendingBodyConnectionCredit;

    pub const h2WritesPending = write_queue.h2WritesPending;
    pub const h2AppendWriteCopy = write_queue.h2AppendWriteCopy;
    pub const h2AppendOwnedWrite = write_queue.h2AppendOwnedWrite;
    pub const h2QueuedWriteVectors = write_queue.h2QueuedWriteVectors;
    pub const h2ConsumeQueuedWrite = write_queue.h2ConsumeQueuedWrite;
    pub const h2HasPendingResponse = write_queue.h2HasPendingResponse;
    pub const h2AppendPendingResponse = write_queue.h2AppendPendingResponse;
    pub const h2PendingResponseSlice = write_queue.h2PendingResponseSlice;
    pub const h2PendingResponseEndsStream = write_queue.h2PendingResponseEndsStream;
    pub const h2DropPendingResponsePrefix = write_queue.h2DropPendingResponsePrefix;
    pub const h2ClearPendingResponseEnd = write_queue.h2ClearPendingResponseEnd;
    pub const h2PendingResponseStreamId = write_queue.h2PendingResponseStreamId;
    pub const h2PendingResponseStreamIdAt = write_queue.h2PendingResponseStreamIdAt;
    pub const h2MaybeRemoveDrainedResponseStream = write_queue.h2MaybeRemoveDrainedResponseStream;
};

/// The lane's decision to close a connection, from the moment it is taken
/// until `connection_flow.zig` tears the connection down.
pub const Closing = struct {
    reason: fault.ConnectionCloseReason,
    /// The write queue, a GOAWAY at its end, goes out before the teardown.
    /// False when no GOAWAY could be queued or the socket failed.
    flush: bool,
    /// The connection's streams were reset toward their workers.
    streams_reset: bool = false,
};

pub const H2HeaderBlockKind = enum {
    request_headers,
    trailers,
    /// A block on a stream that takes no more headers, because it closed or
    /// its request left it: decompressed so both ends' header tables stay in
    /// step (RFC 9113 §4.3), then dropped.
    discarded,
};

pub const PendingH2HeaderBlock = struct {
    stream_id: u32 = 0,
    kind: H2HeaderBlockKind = .request_headers,
    bytes: []u8 = &.{},
    allocation: []u8 = &.{},
    end_stream: bool = false,

    pub fn deinit(self: *PendingH2HeaderBlock, allocator: std.mem.Allocator) void {
        if (self.allocation.len != 0)
            allocator.free(self.allocation);
        self.* = .{};
    }
};

fn preRequestDeadlineLess(_: void, a: *const Slot, b: *const Slot) bool {
    if (a.pre_request_deadline_ns != b.pre_request_deadline_ns)
        return a.pre_request_deadline_ns < b.pre_request_deadline_ns;
    if (a.key.generation != b.key.generation)
        return a.key.generation < b.key.generation;
    return a.key.slot < b.key.slot;
}

pub const PreRequestDeadlineHeap = common_io.heap.IntrusiveHeapWithField(
    Slot,
    "pre_request_deadline_heap",
    void,
    preRequestDeadlineLess,
);
