//! One client connection of an ingress lane in the server (`Slot`), in the
//! lane's connection slab, on the lane's io_uring thread, which alone touches
//! it and takes no lock. The slot owns the socket, from the accept that gave
//! it the slot until the close that gives the slot back
//! (`connection_flow.zig`). This file holds the slot's own state: the socket
//! with its TLS session, peer address and kTLS rekey state, its phase from
//! the TLS handshake to HTTP/2, its polls and its place on the ready queue
//! (its slab link), the lane's decision to close it, its one deadline, and
//! the connection-level HTTP/2 state: the frame reader, the SETTINGS
//! exchange, the HPACK coders and the header block being assembled. Its
//! streams live in the lane's stream slab, which `stream_table.zig` keeps;
//! flow control and the buffered request bodies are in `flow_control.zig`,
//! and the write queue and the buffered responses in `write_queue.zig`.
//! `Slot` declares as its methods the functions of those files that the rest
//! of the lane calls on a connection; the helpers the four files share, such
//! as `stream_table.removeEntry`, stay off it.
//!
//! Invariants:
//! - A connection the lane decided to close (`closing`) reads and queues no
//!   more frames; `connection_flow.zig` finishes the close.
//! - The slot is in the lane's deadline heap exactly while `deadline` is set
//!   (`deadline_driver.zig`), and leaves it before the slot goes back to the
//!   slab.
//! - One header block at a time is assembled, on one stream, within
//!   `limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES` and
//!   `limits.ingress.header_block_frames_max` frames, and the bytes it
//!   holds are charged to the lane's header block budget
//!   (`lane_resources.HeaderBlockBudget`) until it is taken or dropped.
//! - `deinitProtocolState` frees whatever the connection's HTTP/2 state
//!   allocated and gives its streams and its header block's charge back, and
//!   the teardown (`connection_flow.zig`) runs it before it releases the
//!   slot, so a field that allocates is freed there.

const std = @import("std");

const common_io = @import("collo_common_io");
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const tls_mod = @import("../../tls/root.zig");
const ktls = @import("collo_ktls");
const limits = @import("collo_limits");
const lifecycle = @import("collo_server_lifecycle");
const fault = @import("../fault.zig");
const slab = @import("../slab.zig");
const PeerAddress = @import("../peer_address.zig").PeerAddress;
const frame_reader = @import("../http2/frame_reader.zig");
const lane_resources = @import("../http2/lane_resources.zig");
const flow_control = @import("flow_control.zig");
const stream_table = @import("stream_table.zig");
const write_queue = @import("write_queue.zig");

const H2WriteSegment = write_queue.H2WriteSegment;
const HeaderBlockBudget = lane_resources.HeaderBlockBudget;
const max_h2_concurrent_streams = stream_table.max_h2_concurrent_streams;

pub const max_h2_header_block_frames: usize = limits.ingress.header_block_frames_max;

/// The lane's connections.
pub const ConnectionSlab = slab.FaultInSlab(Slot);
/// The connections that wait for a turn of the lane's loop.
pub const ReadyQueue = slab.Fifo(Slot);

pub const Phase = enum {
    tls_handshake,
    http2_connection,
};

pub fn connectionGenerationTag(key: lifecycle.ConnectionKey) u32 {
    return @truncate(key.generation);
}

/// Which of a connection's deadlines its one heap entry stands for
/// (`deadline_driver.zig`).
pub const DeadlineKind = enum {
    /// From the accept until the client opens its first stream.
    pre_request,
    /// While no stream of the connection serves a request and nothing
    /// stalls.
    idle,
    /// While a header block is open, while no stream of the connection
    /// serves a request and the lane holds something of it that only the
    /// client can move, or while a close flushes its GOAWAY, and no byte
    /// moves.
    stall,
};

pub const Deadline = struct {
    kind: DeadlineKind,
    at_ns: u64,
};

pub const Slot = struct {
    slab_link: slab.Link = .{},
    key: lifecycle.ConnectionKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    /// The socket, owned by the slot while it is live.
    fd: std.posix.fd_t = -1,
    /// Read once at accept; the access log records it as the client IP.
    peer_address: PeerAddress = .{},
    state: Phase = .tls_handshake,
    wait_events: i16 = 0,
    registered_wait_events: i16 = 0,
    tls_connection: ?tls_mod.BoringSslConnection = null,
    ktls_rekey_state: ktls.RekeyState = ktls.RekeyState.disabled(),
    /// The lane's slab of streams, which this connection's positions index.
    streams: *stream_table.StreamSlab = undefined,
    frame_reader: frame_reader.State = .{},
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
    /// The id of the stream at each position, 0 where none is
    /// (`stream_table.zig`).
    stream_ids: [max_h2_concurrent_streams]u32 = @splat(0),
    /// The slab index of the entry of the stream at each position.
    stream_refs: [max_h2_concurrent_streams]stream_table.StreamRef = undefined,
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
    /// The connection's entry in the lane's deadline heap, while it has one.
    deadline: ?Deadline = null,
    deadline_heap: common_io.heap.IntrusiveHeapField(Slot) = .{},
    /// When the lane accepted the connection (CLOCK_MONOTONIC).
    accepted_ns: u64 = 0,
    /// Set from the accept until the client opens its first stream
    /// (`noteStreamOpened`).
    awaiting_first_request: bool = true,
    /// When the connection last came to serve no request, while it serves
    /// none and no stream opened since; null otherwise
    /// (`deadline_driver.syncConnectionDeadline`).
    idle_since_ns: ?u64 = null,
    /// When a byte of the connection was last read or written.
    last_progress_ns: u64 = 0,

    /// The connection is live and the lane has not decided to close it: it
    /// reads frames and takes new ones to queue.
    pub fn isOpen(self: *const Slot) bool {
        return self.slab_link.live and self.closing == null;
    }

    pub fn isLive(self: *const Slot) bool {
        return self.slab_link.live;
    }

    /// Records that a byte of the connection moved at `now_ns`, which
    /// restarts its stall deadline.
    pub fn noteProgress(self: *Slot, now_ns: u64) void {
        self.last_progress_ns = now_ns;
    }

    /// Records that the client opened a new stream, whatever the lane then
    /// does with it, a local answer or a refusal included. A new stream is
    /// the one thing that ends the pre-request deadline and restarts the
    /// idle one; the end of the drive files the next deadline.
    pub fn noteStreamOpened(self: *Slot) void {
        self.awaiting_first_request = false;
        self.idle_since_ns = null;
    }

    /// Whether a stream of the connection is bound to a lane request,
    /// waiting for a worker or dispatched. That request's own deadline then
    /// bounds everything the connection holds for it.
    pub fn servesRequest(self: *const Slot) bool {
        if (self.ingress_channel_count == 0)
            return false;
        for (self.stream_ids, 0..) |stream_id, position| {
            if (stream_id == 0)
                continue;
            if (stream_table.streamAt(self, position).request != null)
                return true;
        }
        return false;
    }

    /// Whether the lane holds something of the connection that only the
    /// client can move: part of a frame or of a header block, writes the
    /// socket has not taken, or response bytes flow control holds back.
    pub fn stalled(self: *const Slot) bool {
        return self.frame_reader.midFrame() or
            self.h2HasPendingHeaderBlock() or
            self.h2WritesPending() or
            self.h2_pending_response_bytes != 0;
    }

    /// Frees what the connection's HTTP/2 state holds: its HPACK coders, its
    /// header block, with its charge back to `header_blocks`, its write
    /// queue, and every stream, back to the lane's slab.
    pub fn deinitProtocolState(self: *Slot, allocator: std.mem.Allocator, header_blocks: *HeaderBlockBudget) void {
        self.h2_hpack_decoder.deinit();
        self.h2_hpack_encoder.deinit();
        self.h2ClearHeaderBlock(allocator, header_blocks);
        write_queue.h2DeinitWriteQueue(self, allocator);
        stream_table.releaseAll(self, allocator);
        self.h2_pending_body_bytes = 0;
        self.h2_pending_response_bytes = 0;
    }

    pub fn h2HasPendingHeaderBlock(self: *const Slot) bool {
        return self.h2_header_block_stream_id != 0;
    }

    /// Opens the header block of a HEADERS frame on `stream_id`, empty; its
    /// fragments follow (`h2AppendHeaderBlock`).
    pub fn h2BeginHeaderBlock(
        self: *Slot,
        stream_id: u32,
        end_stream: bool,
        kind: H2HeaderBlockKind,
    ) !void {
        if (self.h2HasPendingHeaderBlock())
            return error.Http2ProtocolError;
        self.h2_header_block_stream_id = stream_id;
        self.h2_header_block_kind = kind;
        self.h2_header_block_end_stream = end_stream;
        self.h2_header_block_len = 0;
        self.h2_header_block_frame_count = 1;
    }

    /// Counts a CONTINUATION frame of the open header block, past
    /// `max_h2_header_block_frames` a flood (ENHANCE_YOUR_CALM).
    pub fn h2CountHeaderBlockFrame(self: *Slot) !void {
        if (self.h2_header_block_frame_count >= max_h2_header_block_frames)
            return error.Http2EnhanceYourCalm;
        self.h2_header_block_frame_count += 1;
    }

    /// Appends a fragment of the open header block. A block past
    /// `INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES` fails with
    /// `error.Http2HeaderBlockTooLarge`, and growth the lane's budget cannot
    /// take with `error.Http2HeaderBlockBudgetExceeded`; either closes the
    /// connection.
    pub fn h2AppendHeaderBlock(
        self: *Slot,
        allocator: std.mem.Allocator,
        header_blocks: *HeaderBlockBudget,
        fragment: []const u8,
    ) !void {
        if (self.h2_header_block_stream_id == 0)
            return error.Http2ProtocolError;
        const new_len = std.math.add(usize, self.h2_header_block_len, fragment.len) catch return error.Http2HeaderBlockTooLarge;
        if (new_len > limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES)
            return error.Http2HeaderBlockTooLarge;
        if (fragment.len == 0)
            return;
        const old_len = self.h2_header_block_len;
        try self.h2EnsureHeaderBlockCapacity(allocator, header_blocks, new_len);
        @memcpy(self.h2_header_block[old_len..new_len], fragment);
        self.h2_header_block_len = new_len;
    }

    /// Takes the assembled header block, which the caller decodes and frees,
    /// and gives its charge back to `header_blocks`.
    pub fn h2TakeHeaderBlock(self: *Slot, header_blocks: *HeaderBlockBudget) PendingH2HeaderBlock {
        header_blocks.release(self.h2_header_block.len);
        const block = PendingH2HeaderBlock{
            .stream_id = self.h2_header_block_stream_id,
            .kind = self.h2_header_block_kind,
            .bytes = self.h2_header_block[0..self.h2_header_block_len],
            .allocation = self.h2_header_block,
            .end_stream = self.h2_header_block_end_stream,
        };
        self.resetHeaderBlock();
        return block;
    }

    pub fn h2ClearHeaderBlock(self: *Slot, allocator: std.mem.Allocator, header_blocks: *HeaderBlockBudget) void {
        if (self.h2_header_block.len != 0) {
            header_blocks.release(self.h2_header_block.len);
            allocator.free(self.h2_header_block);
        }
        self.resetHeaderBlock();
    }

    fn resetHeaderBlock(self: *Slot) void {
        self.h2_header_block_stream_id = 0;
        self.h2_header_block_kind = .request_headers;
        self.h2_header_block_end_stream = false;
        self.h2_header_block = &.{};
        self.h2_header_block_len = 0;
        self.h2_header_block_frame_count = 0;
    }

    fn h2EnsureHeaderBlockCapacity(
        self: *Slot,
        allocator: std.mem.Allocator,
        header_blocks: *HeaderBlockBudget,
        needed_len: usize,
    ) !void {
        if (needed_len <= self.h2_header_block.len)
            return;
        var new_capacity = @max(self.h2_header_block.len * 2, needed_len);
        if (new_capacity < 256)
            new_capacity = 256;
        if (new_capacity > limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES)
            new_capacity = limits.headers.INGRESS_H2_REQUEST_HEADER_BLOCK_BYTES;
        if (new_capacity < needed_len)
            return error.Http2HeaderBlockTooLarge;
        const growth = new_capacity - self.h2_header_block.len;
        try header_blocks.charge(growth);
        errdefer header_blocks.release(growth);
        self.h2_header_block = try allocator.realloc(self.h2_header_block, new_capacity);
    }

    // What the lane calls on a connection whose state the stream table,
    // flow control and the write queue own.
    pub const h2AcceptClientStreamId = stream_table.h2AcceptClientStreamId;
    pub const h2ClientOpenedStreamId = stream_table.h2ClientOpenedStreamId;
    pub const h2ReserveStream = stream_table.h2ReserveStream;
    pub const h2StreamEntry = stream_table.h2StreamEntry;
    pub const h2StreamIndex = stream_table.h2StreamIndex;
    pub const streamAt = stream_table.streamAt;
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
    /// When the lane decided the close (CLOCK_MONOTONIC). A flush gets a
    /// whole stall period from here even when the client stopped reading
    /// long before, as the client of an idle connection may have. Zero
    /// counts the flush from the last byte alone.
    decided_ns: u64 = 0,
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

fn deadlineLess(_: void, a: *const Slot, b: *const Slot) bool {
    const a_at = a.deadline.?.at_ns;
    const b_at = b.deadline.?.at_ns;
    if (a_at != b_at)
        return a_at < b_at;
    if (a.key.generation != b.key.generation)
        return a.key.generation < b.key.generation;
    return a.key.slot < b.key.slot;
}

/// The lane's connection deadlines, one entry per connection at most.
pub const DeadlineHeap = common_io.heap.IntrusiveHeapWithField(
    Slot,
    "deadline_heap",
    void,
    deadlineLess,
);
