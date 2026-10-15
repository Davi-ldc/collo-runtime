//! What one client connection (`Slot` in `connection_slot.zig`) holds for
//! the client before the socket takes it, on the lane thread that owns the
//! connection: the write queue of encoded frames, kept as segments, and each
//! stream's buffered response, which is the body bytes the send windows hold
//! back and the END_STREAM that ends them. A worker's body chunk keeps its
//! bytes in one allocation (`ResponseChunk`) until the socket accepts its
//! last byte, and queued DATA segments point into it. A server response is
//! copied into the stream's byte buffer. `http2/writing.zig` encodes the
//! frames it appends, writes the queue to the socket, and moves a buffered
//! response into the queue as the windows open.
//!
//! Invariants:
//! - The queue holds at most `max_queued_write_bytes`. An append past it
//!   fails with `error.Http2WriteBackpressure` and leaves the queue as it
//!   was.
//! - Queued and blocked are two states. Bytes wait in the queue for the
//!   connection's next write (`http2/writing.zig`), and the queue is blocked
//!   (`Slot.h2_write_blocked`) only from a write the socket took in part
//!   until a write empties it; every backpressure decision reads blocked.
//!   An unblocked queue therefore holds only bytes no write offered yet:
//!   less than `cork_bytes_max`, plus the one append that reaches it and
//!   writes them all.
//! - Small frames are copied into the slot's arena (`Slot.h2_write_arena`),
//!   which queued segments point into, so its room comes back only when the
//!   queue empties.
//! - Buffered responses stay within
//!   `max_h2_pending_response_bytes_per_stream` on a stream and
//!   `max_h2_pending_response_bytes_per_connection` across the connection,
//!   where `h2_pending_response_bytes` counts them: every append, drop and
//!   release keeps it in step. A server response's append checks the caps;
//!   a worker's chunks stay within them because the request's credit window
//!   (`RequestSlot.response_credit`) and `INGRESS_RESPONSE_CHUNK_BYTES` bound
//!   them.

const std = @import("std");

const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const lifecycle = @import("collo_server_lifecycle");
const connection_slot = @import("connection_slot.zig");
const stream_table = @import("stream_table.zig");

const Slot = connection_slot.Slot;
const H2StreamEntry = stream_table.H2StreamEntry;

/// A worker's response body chunk, from the moment the lane takes its bytes
/// until the client socket accepted the last of them. The stream's pending
/// storage and each queued DATA segment that points into `bytes` hold one
/// reference. The last release frees `bytes`. When every holder released it
/// after delivery, the chunk waits on the connection's retired list until
/// its credit returns (`writing.zig:retireResponseChunks`); otherwise it is
/// destroyed with no credit.
pub const ResponseChunk = struct {
    owner: lifecycle.RequestKey,
    bytes: []u8,
    offset: usize = 0,
    refs: usize = 1,
    abandoned: bool = false,
    next_retired: ?*ResponseChunk = null,

    pub fn remaining(self: *const ResponseChunk) []u8 {
        return self.bytes[self.offset..];
    }
};

/// A stream's chunks that wait for its send windows, oldest first: at most
/// `INGRESS_RESPONSE_CHUNKS_IN_FLIGHT_MAX`, which the request's credit
/// window bounds.
pub const ResponseChunks = struct {
    items: [limits.http_body.INGRESS_RESPONSE_CHUNKS_IN_FLIGHT_MAX]?*ResponseChunk = @splat(null),
    len: usize = 0,

    pub fn first(self: *const ResponseChunks) ?*ResponseChunk {
        return if (self.len == 0) null else self.items[0];
    }

    fn pop(self: *ResponseChunks) *ResponseChunk {
        std.debug.assert(self.len != 0);
        const chunk = self.items[0].?;
        self.len -= 1;
        std.mem.copyForwards(?*ResponseChunk, self.items[0..self.len], self.items[1 .. self.len + 1]);
        self.items[self.len] = null;
        return chunk;
    }

    pub fn deinit(self: *ResponseChunks, allocator: std.mem.Allocator) void {
        while (self.len != 0)
            releaseChunk(null, allocator, self.pop(), false);
    }
};

fn releaseChunk(slot: ?*Slot, allocator: std.mem.Allocator, chunk: *ResponseChunk, delivered: bool) void {
    std.debug.assert(chunk.refs != 0);
    chunk.abandoned = chunk.abandoned or !delivered;
    chunk.refs -= 1;
    if (chunk.refs != 0)
        return;
    allocator.free(chunk.bytes);
    chunk.bytes = &.{};
    if (chunk.abandoned) {
        allocator.destroy(chunk);
        return;
    }
    chunk.next_retired = slot.?.h2_retired_response_chunks;
    slot.?.h2_retired_response_chunks = chunk;
}

/// Takes a chunk off the retired list, its bytes already freed. The caller
/// returns its credit to `owner` and destroys it.
pub fn h2TakeRetiredResponseChunk(self: *Slot) ?*ResponseChunk {
    const chunk = self.h2_retired_response_chunks orelse return null;
    self.h2_retired_response_chunks = chunk.next_retired;
    chunk.next_retired = null;
    return chunk;
}

/// Takes every chunk off the retired list at once, linked through
/// `next_retired`, their bytes already freed. The caller returns their
/// credit and destroys each.
pub fn h2TakeRetiredResponseChunks(self: *Slot) ?*ResponseChunk {
    const chunks = self.h2_retired_response_chunks;
    self.h2_retired_response_chunks = null;
    return chunks;
}

/// Appends a worker's body chunk to its stream. The chunk frees its bytes
/// with `allocator`, so a payload `received` owns in `allocator` moves into
/// it, and any other payload, borrowed ring bytes among them, is copied;
/// `received` keeps whatever it still owns.
pub fn h2AppendResponseChunk(self: *Slot, allocator: std.mem.Allocator, received: *ipc.ingress_channel.Received) !void {
    const descriptor = received.descriptor;
    const entry = stream_table.h2StreamEntry(self, descriptor.stream_id) orelse return error.Http2UnknownStream;
    const request = entry.request orelse return error.InvalidH2WorkerOutboundDescriptor;
    if (received.payload.len == 0 or received.payload.len > limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES or
        entry.response_chunks.len == entry.response_chunks.items.len)
        return error.InvalidH2WorkerOutboundDescriptor;
    const chunk = try allocator.create(ResponseChunk);
    errdefer allocator.destroy(chunk);
    const movable = received.payload_owned and
        received.allocator.ptr == allocator.ptr and
        received.allocator.vtable == allocator.vtable;
    const bytes = if (movable) received.payload else try allocator.dupe(u8, received.payload);
    chunk.* = .{
        .owner = request.key,
        .bytes = bytes,
    };
    if (movable)
        received.payload_owned = false;
    entry.response_chunks.items[entry.response_chunks.len] = chunk;
    entry.response_chunks.len += 1;
    self.h2_pending_response_bytes += bytes.len;
    if (descriptor.hasFlag(ipc.ingress_channel.flags.end_stream))
        entry.pending_response_end_stream = true;
}

pub fn h2PendingResponseChunk(self: *Slot, stream_id: u32) ?*ResponseChunk {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return null;
    return entry.response_chunks.first();
}

/// Bytes a connection may hold queued toward the client.
pub const max_queued_write_bytes: usize = 1024 * 1024;
/// Bytes an unblocked queue holds before the append that reaches them writes
/// the queue at once instead of at the connection's next flush: four TLS
/// records of the largest size, so the frames of a pass share records while
/// a large or streamed body still leaves as it arrives.
pub const cork_bytes_max: usize = 64 * 1024;
/// The slot's room for small frames: frame headers, control frames and the
/// WINDOW_UPDATE frames of a few streams.
pub const write_arena_bytes: usize = 128;

comptime {
    // An unblocked queue holds less than the cork plus one append, the
    // largest of which is a worker's chunk with its frame headers or a
    // response head, so it stays far from the bound that closes the
    // connection.
    std.debug.assert(cork_bytes_max + 2 * limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES < max_queued_write_bytes);
}

/// What a stream holds when its worker's response fills its credit window.
/// A stream holds a worker's response or a server response, never both, and
/// the server's (`server_responses.zig`) are a few KiB.
pub const max_h2_pending_response_bytes_per_stream: usize =
    limits.http_body.INGRESS_RESPONSE_CHUNKS_IN_FLIGHT_MAX * limits.http_body.INGRESS_RESPONSE_CHUNK_BYTES;
pub const max_h2_pending_response_bytes_per_connection: usize =
    limits.ingress.streams_per_connection_max * max_h2_pending_response_bytes_per_stream;

/// Bytes wait in the write queue for the connection's next write.
pub fn h2WritesPending(self: *const Slot) bool {
    return self.h2_write_offset < self.h2_write_len;
}

/// The socket took part of the queue it was offered last, so its write poll
/// decides when the queue moves again, and reading, more response DATA and
/// the drain of a worker's output wait for it (the file header).
pub fn h2WritesBlocked(self: *const Slot) bool {
    if (self.h2_write_blocked)
        std.debug.assert(self.h2WritesPending());
    return self.h2_write_blocked;
}

/// Bytes queued and not yet written.
pub fn h2QueuedWriteBytes(self: *const Slot) usize {
    return self.h2_write_len - self.h2_write_offset;
}

/// Copies `bytes` to the end of the write queue without writing them.
pub fn h2AppendWriteCopy(self: *Slot, allocator: std.mem.Allocator, bytes: []const u8) !void {
    // A small frame takes room in the slot's arena instead of an allocation;
    // the room comes back once the queue empties.
    if (bytes.len <= self.h2_write_arena.len - self.h2_write_arena_len) {
        const copy = self.h2_write_arena[self.h2_write_arena_len..][0..bytes.len];
        @memcpy(copy, bytes);
        try appendSegment(self, allocator, copy, false, null);
        self.h2_write_arena_len += bytes.len;
        return;
    }
    const owned = try allocator.dupe(u8, bytes);
    errdefer allocator.free(owned);
    try appendSegment(self, allocator, owned, true, null);
}

/// Moves `owned` to the end of the write queue, which frees it once written,
/// without writing it. On failure `owned` is freed.
pub fn h2AppendOwnedWrite(self: *Slot, allocator: std.mem.Allocator, owned: []u8) !void {
    errdefer allocator.free(owned);
    try appendSegment(self, allocator, owned, true, null);
}

/// Takes room for `segments` more segments holding `bytes` more bytes, so
/// appends within it fail only for an allocation of their own, such as a
/// small frame the arena has no room for. Fails with
/// `error.Http2WriteBackpressure` when the bytes would pass
/// `max_queued_write_bytes`, or with `error.OutOfMemory`, leaving the queue
/// as it was.
pub fn h2ReserveWriteSegments(self: *Slot, allocator: std.mem.Allocator, segments: usize, bytes: usize) !void {
    const queued_len = self.h2_write_len - self.h2_write_offset;
    const next_len = std.math.add(usize, queued_len, bytes) catch return error.MessageTooLarge;
    if (next_len > max_queued_write_bytes)
        return error.Http2WriteBackpressure;
    try self.h2_write_queue.ensureUnusedCapacity(allocator, segments);
}

/// Queues `bytes`, a view into `chunk`, which keeps them alive until the
/// segment is written whole or the connection discards the queue.
pub fn h2AppendChunkWrite(self: *Slot, allocator: std.mem.Allocator, bytes: []u8, chunk: *ResponseChunk) !void {
    if (bytes.len == 0)
        return;
    try appendSegment(self, allocator, bytes, false, chunk);
    chunk.refs += 1;
}

fn appendSegment(
    self: *Slot,
    allocator: std.mem.Allocator,
    bytes: []u8,
    owned: bool,
    chunk: ?*ResponseChunk,
) !void {
    if (bytes.len == 0)
        return;
    const queued_len = self.h2_write_len - self.h2_write_offset;
    const next_len = std.math.add(usize, queued_len, bytes.len) catch return error.MessageTooLarge;
    if (next_len > max_queued_write_bytes)
        return error.Http2WriteBackpressure;
    const next_total_len = std.math.add(usize, self.h2_write_len, bytes.len) catch return error.MessageTooLarge;
    // The first segment of an empty queue sits in the inline slot, so a lone
    // write never grows the segment list.
    if (!self.h2_write_inline_active and self.h2_write_queue.items.len == 0 and self.h2_write_offset == self.h2_write_len) {
        self.h2_write_inline_segment = .{
            .bytes = bytes,
            .owned = owned,
            .chunk = chunk,
        };
        self.h2_write_inline_active = true;
        self.h2_write_len = bytes.len;
        self.h2_write_offset = 0;
        return;
    }
    try self.h2_write_queue.append(allocator, .{
        .bytes = bytes,
        .owned = owned,
        .chunk = chunk,
    });
    self.h2_write_len = next_total_len;
}

/// Points `iovecs` at the queued bytes, oldest first, and returns the part
/// of it filled: one vector per segment, up to `iovecs.len` segments. The
/// vectors borrow the segments until the queue next changes.
pub fn h2QueuedWriteVectors(
    self: *const Slot,
    iovecs: []std.posix.iovec_const,
) []const std.posix.iovec_const {
    std.debug.assert(iovecs.len != 0);
    var count: usize = 0;
    if (self.h2_write_inline_active) {
        const remaining = self.h2_write_inline_segment.remaining();
        if (remaining.len != 0) {
            iovecs[count] = .{ .base = remaining.ptr, .len = remaining.len };
            count += 1;
        }
    }
    var index = self.h2_write_queue_start;
    while (index < self.h2_write_queue.items.len and count < iovecs.len) : (index += 1) {
        const remaining = self.h2_write_queue.items[index].remaining();
        if (remaining.len == 0)
            continue;
        iovecs[count] = .{ .base = remaining.ptr, .len = remaining.len };
        count += 1;
    }
    return iovecs[0..count];
}

/// Takes `written` bytes, which the socket accepted, off the front of the
/// queue, freeing each segment it took whole.
pub fn h2ConsumeQueuedWrite(self: *Slot, allocator: std.mem.Allocator, written: usize) void {
    std.debug.assert(written <= self.h2_write_len - self.h2_write_offset);
    self.h2_write_offset += written;
    var remaining = written;
    if (self.h2_write_inline_active) {
        const segment_remaining = self.h2_write_inline_segment.bytes.len -
            self.h2_write_inline_segment.offset;
        if (remaining < segment_remaining) {
            self.h2_write_inline_segment.offset += remaining;
            return;
        }
        remaining -= segment_remaining;
        completeSegment(self, allocator, &self.h2_write_inline_segment);
        self.h2_write_inline_active = false;
    }
    while (remaining != 0) {
        std.debug.assert(self.h2_write_queue_start < self.h2_write_queue.items.len);
        const segment = &self.h2_write_queue.items[self.h2_write_queue_start];
        const segment_remaining = segment.bytes.len - segment.offset;
        if (remaining < segment_remaining) {
            segment.offset += remaining;
            return;
        }
        remaining -= segment_remaining;
        completeSegment(self, allocator, segment);
        self.h2_write_queue_start += 1;
    }

    if (!self.h2_write_inline_active and self.h2_write_queue_start == self.h2_write_queue.items.len) {
        self.h2_write_queue.clearRetainingCapacity();
        self.h2_write_queue_start = 0;
        self.h2_write_len = 0;
        self.h2_write_offset = 0;
        // No segment points into the arena any more.
        self.h2_write_arena_len = 0;
        return;
    }

    // The written segments stay at the front of the list until the queue
    // empties. Once they are past a few dozen and outnumber the queued ones,
    // the queued ones move to the front, so a queue that never empties does
    // not grow its list without bound.
    if (self.h2_write_queue_start > 32 and
        self.h2_write_queue_start * 2 > self.h2_write_queue.items.len)
    {
        const queued = self.h2_write_queue.items[self.h2_write_queue_start..];
        std.mem.copyForwards(
            H2WriteSegment,
            self.h2_write_queue.items[0..queued.len],
            queued,
        );
        self.h2_write_queue.items.len = queued.len;
        self.h2_write_queue_start = 0;
    }
}

fn completeSegment(self: *Slot, allocator: std.mem.Allocator, segment: *H2WriteSegment) void {
    if (segment.chunk) |chunk| {
        segment.chunk = null;
        releaseChunk(self, allocator, chunk, true);
    }
    segment.deinit(allocator);
}

/// Frees every queued segment and the segment list.
pub fn h2DeinitWriteQueue(self: *Slot, allocator: std.mem.Allocator) void {
    h2ClearWriteQueueRetainingCapacity(self, allocator);
    self.h2_write_queue.deinit(allocator);
    while (h2TakeRetiredResponseChunk(self)) |chunk|
        allocator.destroy(chunk);
}

fn h2ClearWriteQueueRetainingCapacity(self: *Slot, allocator: std.mem.Allocator) void {
    if (self.h2_write_inline_active) {
        self.h2_write_inline_segment.deinit(allocator);
        self.h2_write_inline_active = false;
    }
    for (self.h2_write_queue.items) |*segment|
        segment.deinit(allocator);
    self.h2_write_queue.clearRetainingCapacity();
    self.h2_write_queue_start = 0;
    self.h2_write_len = 0;
    self.h2_write_offset = 0;
    self.h2_write_arena_len = 0;
    self.h2_write_blocked = false;
}

pub fn h2HasPendingResponse(self: *Slot, stream_id: u32) bool {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return false;
    return hasUndeliveredResponse(entry);
}

pub fn h2AppendPendingResponse(
    self: *Slot,
    allocator: std.mem.Allocator,
    stream_id: u32,
    bytes: []const u8,
    end_stream: bool,
) !void {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return error.Http2UnknownStream;
    switch (entry.state) {
        .preparing, .active, .draining_response => {},
        .vacant => return error.Http2UnknownStream,
    }
    if (entry.pending_response_end_stream)
        return error.Http2ProtocolError;

    const current_len = pendingResponseLen(entry);
    const new_pending_len = std.math.add(usize, current_len, bytes.len) catch return error.Http2PendingResponseTooLarge;
    if (new_pending_len > max_h2_pending_response_bytes_per_stream)
        return error.Http2PendingResponseTooLarge;
    if (self.h2_pending_response_bytes > max_h2_pending_response_bytes_per_connection or
        bytes.len > max_h2_pending_response_bytes_per_connection - self.h2_pending_response_bytes)
    {
        return error.Http2PendingResponseTooLarge;
    }
    if (bytes.len != 0) {
        if (entry.pending_response_start != 0) {
            const allocated_len = std.math.add(usize, entry.pending_response.len, bytes.len) catch return error.Http2PendingResponseTooLarge;
            if (allocated_len > max_h2_pending_response_bytes_per_stream or entry.pending_response_start >= entry.pending_response.len / 2)
                try compactPendingResponse(allocator, entry);
        }
        const old_len = entry.pending_response.len;
        const new_allocated_len = std.math.add(usize, old_len, bytes.len) catch return error.Http2PendingResponseTooLarge;
        if (new_allocated_len > max_h2_pending_response_bytes_per_stream)
            return error.Http2PendingResponseTooLarge;
        entry.pending_response = try allocator.realloc(entry.pending_response, new_allocated_len);
        @memcpy(entry.pending_response[old_len..new_allocated_len], bytes);
        self.h2_pending_response_bytes += bytes.len;
    }
    if (end_stream)
        entry.pending_response_end_stream = true;
}

pub fn h2PendingResponseSlice(self: *Slot, stream_id: u32) ?[]const u8 {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return null;
    return pendingResponseSlice(entry);
}

pub fn h2PendingResponseEndsStream(self: *Slot, stream_id: u32) bool {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return false;
    return entry.pending_response_end_stream and entry.response_chunks.len <= 1;
}

pub fn h2DropPendingResponsePrefix(self: *Slot, allocator: std.mem.Allocator, stream_id: u32, count: usize) !void {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return error.Http2UnknownStream;
    const available = pendingResponseLen(entry);
    if (count > available)
        return error.Http2ProtocolError;
    if (count == 0)
        return;
    if (entry.response_chunks.first()) |chunk| {
        if (count > chunk.remaining().len)
            return error.Http2ProtocolError;
        self.h2_pending_response_bytes -= count;
        chunk.offset += count;
        if (chunk.offset == chunk.bytes.len) {
            _ = entry.response_chunks.pop();
            releaseChunk(self, allocator, chunk, true);
            if (entry.response_chunks.len == 0)
                entry.pending_response_end_stream = false;
        }
        return;
    }
    if (count <= self.h2_pending_response_bytes)
        self.h2_pending_response_bytes -= count
    else
        self.h2_pending_response_bytes = 0;
    entry.pending_response_start += count;
    if (entry.pending_response_start == entry.pending_response.len) {
        allocator.free(entry.pending_response);
        entry.pending_response = &.{};
        entry.pending_response_start = 0;
        entry.pending_response_end_stream = false;
        return;
    }
}

pub fn h2ClearPendingResponseEnd(self: *Slot, stream_id: u32) !void {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return error.Http2UnknownStream;
    if (pendingResponseLen(entry) != 0)
        return error.Http2ProtocolError;
    entry.pending_response_end_stream = false;
}

/// The id of the first stream from position `start_index.*` on that still
/// owes the client buffered response bytes or END_STREAM, with
/// `start_index.*` moved past it; null when none does.
pub fn h2PendingResponseStreamId(self: *const Slot, start_index: *usize) ?u32 {
    while (start_index.* < self.stream_ids.len) : (start_index.* += 1) {
        if (h2PendingResponseStreamIdAt(self, start_index.*)) |stream_id| {
            start_index.* += 1;
            return stream_id;
        }
    }
    return null;
}

/// The id of the stream at `position` when it owes the client buffered
/// response bytes or END_STREAM.
pub fn h2PendingResponseStreamIdAt(self: *const Slot, position: usize) ?u32 {
    const stream_id = self.stream_ids[position];
    if (stream_id == 0)
        return null;
    if (hasUndeliveredResponse(stream_table.streamAt(self, position)))
        return stream_id;
    return null;
}

pub fn h2MaybeRemoveDrainedResponseStream(self: *Slot, allocator: std.mem.Allocator, stream_id: u32) bool {
    const position = stream_table.h2StreamIndex(self, stream_id) orelse return false;
    const entry = stream_table.streamAt(self, position);
    if (entry.state != .draining_response or hasUndeliveredResponse(entry))
        return false;
    stream_table.removeEntry(self, allocator, position);
    return true;
}

pub fn releasePendingResponse(self: *Slot, allocator: std.mem.Allocator, entry: *H2StreamEntry) void {
    const byte_len = pendingResponseLen(entry);
    entry.response_chunks.deinit(allocator);
    self.h2_pending_response_bytes -|= byte_len;
    if (entry.pending_response.len == 0) {
        entry.pending_response_end_stream = false;
        entry.pending_response_start = 0;
        return;
    }
    allocator.free(entry.pending_response);
    entry.pending_response = &.{};
    entry.pending_response_start = 0;
    entry.pending_response_end_stream = false;
}

pub const H2WriteSegment = struct {
    bytes: []u8 = &.{},
    offset: usize = 0,
    owned: bool = false,
    chunk: ?*ResponseChunk = null,

    pub fn remaining(self: *const H2WriteSegment) []const u8 {
        std.debug.assert(self.offset <= self.bytes.len);
        return self.bytes[self.offset..];
    }

    pub fn deinit(self: *H2WriteSegment, allocator: std.mem.Allocator) void {
        if (self.chunk) |chunk|
            releaseChunk(null, allocator, chunk, false);
        if (self.owned and self.bytes.len != 0)
            allocator.free(self.bytes);
        self.* = .{};
    }
};

fn pendingResponseLen(entry: *const H2StreamEntry) usize {
    std.debug.assert(entry.pending_response_start <= entry.pending_response.len);
    var len = entry.pending_response.len - entry.pending_response_start;
    for (entry.response_chunks.items[0..entry.response_chunks.len]) |chunk|
        len += chunk.?.remaining().len;
    return len;
}

/// Whether the stream still owes the client buffered response bytes or a
/// buffered END_STREAM. Every drain and teardown decision uses this one test,
/// so removing a stream never drops bytes still owed and the flush scan never
/// skips them.
fn hasUndeliveredResponse(entry: *const H2StreamEntry) bool {
    return pendingResponseLen(entry) != 0 or
        entry.pending_response_end_stream;
}

fn pendingResponseSlice(entry: *const H2StreamEntry) []const u8 {
    if (entry.response_chunks.first()) |chunk|
        return chunk.remaining();
    std.debug.assert(entry.pending_response_start <= entry.pending_response.len);
    return entry.pending_response[entry.pending_response_start..];
}

fn compactPendingResponse(allocator: std.mem.Allocator, entry: *H2StreamEntry) !void {
    if (entry.pending_response_start == 0)
        return;
    const remaining = pendingResponseLen(entry);
    if (remaining == 0) {
        allocator.free(entry.pending_response);
        entry.pending_response = &.{};
        entry.pending_response_start = 0;
        return;
    }
    std.mem.copyForwards(u8, entry.pending_response[0..remaining], pendingResponseSlice(entry));
    entry.pending_response = try allocator.realloc(entry.pending_response, remaining);
    entry.pending_response_start = 0;
}
