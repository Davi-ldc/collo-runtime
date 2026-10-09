//! What one client connection (`Slot` in `connection_slot.zig`) holds for
//! the client before the socket takes it, on the lane thread that owns the
//! connection: the write queue of encoded frames, kept as segments, and each
//! stream's buffered response, which is the body bytes the send windows hold
//! back and the END_STREAM that ends them. `http2/writing.zig` encodes the
//! frames it appends, writes the queue to the socket, and moves a buffered
//! response into the queue as the windows open.
//!
//! Invariants:
//! - The queue holds at most `max_queued_write_bytes`. An append past it
//!   fails with `error.Http2WriteBackpressure` and leaves the queue as it
//!   was.
//! - Buffered responses stay within
//!   `max_h2_pending_response_bytes_per_stream` on a stream and
//!   `max_h2_pending_response_bytes_per_connection` across the connection,
//!   where `h2_pending_response_bytes` counts them: every append, drop and
//!   release keeps it in step. A stream's bound holds a whole worker
//!   response of `limits.http_body.MATERIALIZED_BODY_BYTES_MAX`.

const std = @import("std");

const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const connection_slot = @import("connection_slot.zig");
const stream_table = @import("stream_table.zig");

const Slot = connection_slot.Slot;
const H2StreamEntry = stream_table.H2StreamEntry;

/// Bytes a connection may hold queued toward the client.
pub const max_queued_write_bytes: usize = 1024 * 1024;

/// Holds one whole worker response, up to
/// `limits.http_body.MATERIALIZED_BODY_BYTES_MAX`, while the client's
/// WINDOW_UPDATE frames are still in flight; a smaller buffer would wedge a
/// response of that size.
pub const max_h2_pending_response_bytes_per_stream: usize = ipc.max_message_bytes * 4;
pub const max_h2_pending_response_bytes_per_connection: usize = max_h2_pending_response_bytes_per_stream * 4;
comptime {
    std.debug.assert(max_h2_pending_response_bytes_per_stream >= limits.http_body.MATERIALIZED_BODY_BYTES_MAX);
}

/// Bytes wait in the write queue, so reading waits too.
pub fn h2WritesPending(self: *const Slot) bool {
    return self.h2_write_offset < self.h2_write_len;
}

/// Copies `bytes` to the end of the write queue without writing them.
pub fn h2AppendWriteCopy(self: *Slot, allocator: std.mem.Allocator, bytes: []const u8) !void {
    // A small control frame skips the allocation by using the slot's write
    // buffer, but only while nothing is queued: a queued segment may still
    // point into that buffer.
    if (!self.h2WritesPending() and bytes.len <= self.h2_write_buffer.len) {
        @memcpy(self.h2_write_buffer[0..bytes.len], bytes);
        return appendSegment(self, allocator, self.h2_write_buffer[0..bytes.len], false);
    }
    const owned = try allocator.dupe(u8, bytes);
    errdefer allocator.free(owned);
    try appendSegment(self, allocator, owned, true);
}

/// Moves `owned` to the end of the write queue, which frees it once written,
/// without writing it. On failure `owned` is freed.
pub fn h2AppendOwnedWrite(self: *Slot, allocator: std.mem.Allocator, owned: []u8) !void {
    errdefer allocator.free(owned);
    try appendSegment(self, allocator, owned, true);
}

fn appendSegment(
    self: *Slot,
    allocator: std.mem.Allocator,
    bytes: []u8,
    owned: bool,
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
        };
        self.h2_write_inline_active = true;
        self.h2_write_len = bytes.len;
        self.h2_write_offset = 0;
        return;
    }
    try self.h2_write_queue.append(allocator, .{
        .bytes = bytes,
        .owned = owned,
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
        self.h2_write_inline_segment.deinit(allocator);
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
        segment.deinit(allocator);
        self.h2_write_queue_start += 1;
    }

    if (!self.h2_write_inline_active and self.h2_write_queue_start == self.h2_write_queue.items.len) {
        self.h2_write_queue.clearRetainingCapacity();
        self.h2_write_queue_start = 0;
        self.h2_write_len = 0;
        self.h2_write_offset = 0;
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

/// Frees every queued segment and the segment list.
pub fn h2DeinitWriteQueue(self: *Slot, allocator: std.mem.Allocator) void {
    h2ClearWriteQueueRetainingCapacity(self, allocator);
    self.h2_write_queue.deinit(allocator);
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
}

pub fn h2HasPendingResponse(self: *const Slot, stream_id: u32) bool {
    const index = stream_table.h2StreamIndex(self, stream_id) orelse return false;
    const entry = &self.ingress_channels[index];
    return hasUndeliveredResponse(entry);
}

pub fn h2AppendPendingResponse(
    self: *Slot,
    allocator: std.mem.Allocator,
    stream_id: u32,
    bytes: []const u8,
    end_stream: bool,
) !void {
    const index = stream_table.h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
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
    const index = stream_table.h2StreamIndex(self, stream_id) orelse return null;
    return pendingResponseSlice(&self.ingress_channels[index]);
}

pub fn h2PendingResponseEndsStream(self: *Slot, stream_id: u32) bool {
    const index = stream_table.h2StreamIndex(self, stream_id) orelse return false;
    return self.ingress_channels[index].pending_response_end_stream;
}

pub fn h2DropPendingResponsePrefix(self: *Slot, allocator: std.mem.Allocator, stream_id: u32, count: usize) !void {
    const index = stream_table.h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    const available = pendingResponseLen(entry);
    if (count > available)
        return error.Http2ProtocolError;
    if (count == 0)
        return;
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
    const index = stream_table.h2StreamIndex(self, stream_id) orelse return error.Http2UnknownStream;
    const entry = &self.ingress_channels[index];
    if (pendingResponseLen(entry) != 0)
        return error.Http2ProtocolError;
    entry.pending_response_end_stream = false;
}

pub fn h2PendingResponseStreamId(self: *const Slot, start_index: *usize) ?u32 {
    while (start_index.* < self.ingress_channels.len) : (start_index.* += 1) {
        const entry = self.ingress_channels[start_index.*];
        if (entry.state != .vacant and hasUndeliveredResponse(&entry)) {
            start_index.* += 1;
            return entry.stream_id;
        }
    }
    return null;
}

pub fn h2PendingResponseStreamIdAt(self: *const Slot, index: usize) ?u32 {
    std.debug.assert(index < self.ingress_channels.len);
    const entry = self.ingress_channels[index];
    if (entry.state != .vacant and hasUndeliveredResponse(&entry))
        return entry.stream_id;
    return null;
}

pub fn h2MaybeRemoveDrainedResponseStream(self: *Slot, allocator: std.mem.Allocator, stream_id: u32) bool {
    const index = stream_table.h2StreamIndex(self, stream_id) orelse return false;
    const entry = &self.ingress_channels[index];
    if (entry.state != .draining_response or hasUndeliveredResponse(entry))
        return false;
    stream_table.removeEntry(self, allocator, entry);
    return true;
}

pub fn releasePendingResponse(self: *Slot, allocator: std.mem.Allocator, entry: *H2StreamEntry) void {
    const byte_len = pendingResponseLen(entry);
    if (entry.pending_response.len == 0) {
        entry.pending_response_end_stream = false;
        entry.pending_response_start = 0;
        return;
    }
    if (byte_len <= self.h2_pending_response_bytes)
        self.h2_pending_response_bytes -= byte_len
    else
        self.h2_pending_response_bytes = 0;
    allocator.free(entry.pending_response);
    entry.pending_response = &.{};
    entry.pending_response_start = 0;
    entry.pending_response_end_stream = false;
}

pub const H2WriteSegment = struct {
    bytes: []u8 = &.{},
    offset: usize = 0,
    owned: bool = false,

    pub fn remaining(self: *const H2WriteSegment) []const u8 {
        std.debug.assert(self.offset <= self.bytes.len);
        return self.bytes[self.offset..];
    }

    pub fn deinit(self: *H2WriteSegment, allocator: std.mem.Allocator) void {
        if (self.owned and self.bytes.len != 0)
            allocator.free(self.bytes);
        self.* = .{};
    }
};

fn pendingResponseLen(entry: *const H2StreamEntry) usize {
    std.debug.assert(entry.pending_response_start <= entry.pending_response.len);
    return entry.pending_response.len - entry.pending_response_start;
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
