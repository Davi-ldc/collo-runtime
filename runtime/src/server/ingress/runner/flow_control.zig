//! HTTP/2 flow control on one client connection (`Slot` in
//! `connection_slot.zig`), on the lane thread that owns the connection: the
//! send windows the client grants the connection and each of its streams,
//! the receive windows the lane advertises and the credit it owes the
//! client, and the request bodies buffered on streams until their worker
//! takes them, which hold back the credit of their bytes.
//! `http2/writing.zig` returns the credit owed in WINDOW_UPDATE frames.
//!
//! Invariants:
//! - Buffered request bodies stay within
//!   `max_h2_pending_body_bytes_per_stream` on a stream and
//!   `max_h2_pending_body_bytes_per_connection` across the connection, where
//!   `h2_pending_body_bytes` counts them: every append, take and release
//!   keeps it in step.
//! - A buffered request body keeps the flow-control credit of the frames it
//!   holds, and the client gets that credit back only when the bytes reach
//!   the worker or are released, so a worker that stops reading stalls the
//!   client's sender rather than growing the buffer.
//! - Credit owed waits until a window the client sees falls to half its
//!   advertised size (`h2WindowUpdateDue`, which proves the bound) or until
//!   the connection writes frames anyway, and a stream whose request ended
//!   is owed none of its own.
//! - No window grows past `h2.max_window_size`; an update that would is
//!   `error.Http2FlowControlError`.
//! - Each DATA frame the server sends earns the client two WINDOW_UPDATE
//!   frames outside the per-read frame budget, the most a client that
//!   returns every frame's credit sends for it (`h2_earned_window_updates`).

const std = @import("std");

const h2 = @import("collo_http").http2;
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const connection_slot = @import("connection_slot.zig");
const stream_table = @import("stream_table.zig");

const Slot = connection_slot.Slot;
const H2StreamEntry = stream_table.H2StreamEntry;
const H2StreamState = stream_table.H2StreamState;

pub const max_h2_pending_body_bytes_per_stream: usize = ipc.max_message_bytes - @sizeOf(ipc.ingress_channel.Packet);
pub const max_h2_pending_body_bytes_per_connection: usize = max_h2_pending_body_bytes_per_stream * 4;
comptime {
    // A client may send a whole receive window before the lane can forward a
    // byte, so the body buffers hold at least the windows the lane advertises.
    std.debug.assert(max_h2_pending_body_bytes_per_stream >= limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES);
    std.debug.assert(max_h2_pending_body_bytes_per_connection >= limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES);
}

pub fn h2AppendPreparingBody(
    self: *Slot,
    allocator: std.mem.Allocator,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
    window_credit_len: usize,
) !void {
    return h2AppendPendingBody(
        self,
        allocator,
        stream_id,
        payload,
        end_stream,
        window_credit_len,
        .preparing,
    );
}

pub fn h2AppendActivePendingBody(
    self: *Slot,
    allocator: std.mem.Allocator,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
    window_credit_len: usize,
) !void {
    return h2AppendPendingBody(
        self,
        allocator,
        stream_id,
        payload,
        end_stream,
        window_credit_len,
        .active,
    );
}

fn h2AppendPendingBody(
    self: *Slot,
    allocator: std.mem.Allocator,
    stream_id: u32,
    payload: []const u8,
    end_stream: bool,
    window_credit_len: usize,
    expected_state: H2StreamState,
) !void {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return error.Http2UnknownStream;
    if (entry.state != expected_state)
        return error.Http2StreamStateMismatch;
    try h2CheckPendingBodyAppend(self, entry, payload.len);
    const new_len = std.math.add(usize, entry.pending_body_len, payload.len) catch return error.Http2PendingBodyTooLarge;
    const should_record_credit = payload.len != 0 or end_stream;
    const new_window_credit = if (should_record_credit)
        std.math.add(
            usize,
            entry.pending_body_window_credit,
            window_credit_len,
        ) catch return error.Http2FlowControlError
    else
        entry.pending_body_window_credit;
    if (payload.len != 0) {
        const old_len = entry.pending_body_len;
        try ensurePendingBodyCapacity(allocator, entry, new_len);
        @memcpy(entry.pending_body[old_len..new_len], payload);
        entry.pending_body_len = new_len;
        self.h2_pending_body_bytes += payload.len;
    }
    if (end_stream)
        entry.pending_body_complete = true;
    entry.pending_body_window_credit = new_window_credit;
}

pub fn h2EnsureActivePendingBodyCapacity(
    self: *Slot,
    stream_id: u32,
    payload_len: usize,
) !void {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return error.Http2UnknownStream;
    if (entry.state != .active)
        return error.Http2StreamStateMismatch;
    try h2CheckPendingBodyAppend(self, entry, payload_len);
}

fn h2CheckPendingBodyAppend(
    self: *const Slot,
    entry: *const H2StreamEntry,
    payload_len: usize,
) !void {
    if (entry.pending_body_complete)
        return error.Http2ProtocolError;
    const new_len = std.math.add(usize, entry.pending_body_len, payload_len) catch return error.Http2PendingBodyTooLarge;
    if (new_len > max_h2_pending_body_bytes_per_stream)
        return error.Http2PendingBodyTooLarge;
    if (self.h2_pending_body_bytes > max_h2_pending_body_bytes_per_connection or
        payload_len > max_h2_pending_body_bytes_per_connection - self.h2_pending_body_bytes)
    {
        return error.Http2PendingBodyTooLarge;
    }
}

pub fn h2HasPendingBody(self: *Slot, stream_id: u32) bool {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return false;
    return entry.pending_body_len != 0 or entry.pending_body_complete;
}

pub fn h2PendingBodyView(self: *Slot, stream_id: u32) ?PendingH2BodyView {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return null;
    if (entry.pending_body_len == 0 and !entry.pending_body_complete)
        return null;
    return .{
        .bytes = entry.pending_body[0..entry.pending_body_len],
        .end_stream = entry.pending_body_complete,
        .window_credit_len = entry.pending_body_window_credit,
    };
}

pub fn h2TakePendingBody(self: *Slot, stream_id: u32) ?PendingH2Body {
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return null;
    if (entry.pending_body_len == 0 and !entry.pending_body_complete)
        return null;
    const body = PendingH2Body{
        .allocation = entry.pending_body,
        .bytes = entry.pending_body[0..entry.pending_body_len],
        .end_stream = entry.pending_body_complete,
        .window_credit_len = entry.pending_body_window_credit,
    };
    if (entry.pending_body_len <= self.h2_pending_body_bytes)
        self.h2_pending_body_bytes -= entry.pending_body_len
    else
        self.h2_pending_body_bytes = 0;
    entry.pending_body = &.{};
    entry.pending_body_len = 0;
    entry.pending_body_complete = false;
    entry.pending_body_window_credit = 0;
    return body;
}

pub fn h2ApplyPeerInitialStreamWindow(self: *Slot, old_value: u32, new_value: u32) !void {
    if (old_value == new_value)
        return;
    const delta = @as(i64, new_value) - @as(i64, old_value);
    for (self.stream_ids, 0..) |id, position| {
        if (id == 0)
            continue;
        const entry = stream_table.streamAt(self, position);
        switch (entry.state) {
            .preparing, .active, .draining_response => {
                const updated = entry.send_window + delta;
                if (updated > h2.max_window_size)
                    return error.Http2FlowControlError;
                entry.send_window = updated;
            },
            .vacant => {},
        }
    }
}

pub fn h2IncreaseConnectionSendWindow(self: *Slot, increment: u32) !void {
    if (increment == 0)
        return error.Http2ProtocolError;
    const updated = self.h2_connection_send_window + @as(i64, increment);
    if (updated > h2.max_window_size)
        return error.Http2FlowControlError;
    self.h2_connection_send_window = updated;
}

pub fn h2IncreaseStreamSendWindow(self: *Slot, stream_id: u32, increment: u32) !void {
    if (increment == 0)
        return error.Http2ProtocolError;
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return;
    switch (entry.state) {
        .preparing, .active, .draining_response => {
            const updated = entry.send_window + @as(i64, increment);
            if (updated > h2.max_window_size)
                return error.Http2FlowControlError;
            entry.send_window = updated;
        },
        .vacant => {},
    }
}

pub fn h2AvailableOutboundWindow(self: *Slot, stream_id: u32, byte_len: usize) !usize {
    if (byte_len == 0)
        return 0;
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return error.Http2UnknownStream;
    switch (entry.state) {
        .preparing, .active, .draining_response => {},
        .vacant => return 0,
    }
    if (self.h2_connection_send_window <= 0 or entry.send_window <= 0)
        return 0;
    const connection_available: usize = @intCast(@min(self.h2_connection_send_window, @as(i64, h2.max_window_size)));
    const stream_available: usize = @intCast(@min(entry.send_window, @as(i64, h2.max_window_size)));
    return @min(byte_len, @min(connection_available, stream_available));
}

/// Charges the send windows for `frame_count` DATA frames that carry
/// `byte_len` bytes on `stream_id`, and earns the client two WINDOW_UPDATE
/// frames for each of them (`h2SpendEarnedWindowUpdate`).
pub fn h2ConsumeOutboundWindow(self: *Slot, stream_id: u32, byte_len: usize, frame_count: usize) !void {
    if (byte_len == 0)
        return;
    std.debug.assert(frame_count != 0 and frame_count <= byte_len);
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return error.Http2UnknownStream;
    if (self.h2_connection_send_window < byte_len or entry.send_window < byte_len)
        return error.Http2FlowControlError;
    self.h2_connection_send_window -= @intCast(byte_len);
    entry.send_window -= @intCast(byte_len);
    self.h2_earned_window_updates +|= std.math.lossyCast(u32, frame_count *| 2);
}

/// Spends one of the WINDOW_UPDATE frames the server's DATA frames earned,
/// and returns whether one was left. A client may return the credit of
/// every DATA frame it reads, to the connection and to the stream, and a
/// lane that reads late finds all of those updates in one read, however
/// small the frames were; they answer frames the server sent, so only the
/// updates past them count against the per-read frame budget
/// (`reading.zig:frameDisposition`). A flood of updates thus costs the lane
/// at most two frames for each DATA frame it sent before the budget applies.
pub fn h2SpendEarnedWindowUpdate(self: *Slot) bool {
    if (self.h2_earned_window_updates == 0)
        return false;
    self.h2_earned_window_updates -= 1;
    return true;
}

pub fn h2ConsumeInboundWindow(self: *Slot, stream_id: u32, byte_len: usize) !void {
    if (byte_len == 0)
        return;
    const entry = stream_table.h2StreamEntry(self, stream_id) orelse return error.Http2UnknownStream;
    switch (entry.state) {
        .preparing, .active => {},
        .vacant, .draining_response => return error.Http2ProtocolError,
    }
    if (self.h2_connection_recv_window < byte_len or entry.recv_window < byte_len)
        return error.Http2FlowControlError;
    self.h2_connection_recv_window -= @intCast(byte_len);
    entry.recv_window -= @intCast(byte_len);
}

/// Accounts DATA the lane drops, on a stream that is closed or no longer
/// has a request to take its body. The frame still spent the connection's
/// window (RFC 9113 §6.9), so `byte_len` is taken from it and handed back
/// at once as a buffered WINDOW_UPDATE, and the client's connection never
/// shrinks on frames that crossed a close on the wire. The stream's own
/// window is not given back. Fails with `error.Http2FlowControlError` when
/// the frame overran the connection's window.
pub fn h2DiscardInboundData(self: *Slot, byte_len: usize) !void {
    if (byte_len == 0)
        return;
    if (self.h2_connection_recv_window < byte_len)
        return error.Http2FlowControlError;
    self.h2_connection_recv_window -= @intCast(byte_len);
    try self.h2BufferInboundWindowUpdate(null, byte_len);
}

/// Owes the client `byte_len` bytes of receive credit for bytes the server
/// no longer holds: the lane's own windows of the connection and of
/// `stream_id`, when the table holds that stream open, grow at once, and the
/// credit waits in the pending updates until a WINDOW_UPDATE carries it
/// (`h2WindowUpdateDue` says when one must). A stream whose request's
/// END_STREAM arrived owes no credit of its own: its client can send it no
/// more DATA (RFC 9113 §5.1, half-closed remote), so only the connection's
/// share is owed. Fails with `error.Http2FlowControlError` when a window or
/// an update would pass `h2.max_window_size`, changing nothing.
pub fn h2BufferInboundWindowUpdate(self: *Slot, stream_id: ?u32, byte_len: usize) !void {
    if (byte_len == 0)
        return;
    if (byte_len > h2.max_window_size)
        return error.Http2FlowControlError;
    const increment: u32 = @intCast(byte_len);
    const connection_updated = self.h2_connection_recv_window + @as(i64, increment);
    if (connection_updated > h2.max_window_size)
        return error.Http2FlowControlError;
    const pending_connection_update = std.math.add(
        u32,
        self.h2_pending_connection_window_update,
        increment,
    ) catch return error.Http2FlowControlError;

    var stream_entry: ?*H2StreamEntry = null;
    var stream_recv_window: i64 = 0;
    var pending_stream_update: u32 = 0;
    if (stream_id) |id| {
        if (stream_table.h2StreamEntry(self, id)) |entry| {
            switch (entry.state) {
                .preparing, .active => {
                    const stream_updated = entry.recv_window + @as(i64, increment);
                    if (stream_updated > h2.max_window_size)
                        return error.Http2FlowControlError;
                    const pending_update = if (entry.request_body_complete)
                        entry.pending_recv_window_update
                    else
                        std.math.add(
                            u32,
                            entry.pending_recv_window_update,
                            increment,
                        ) catch return error.Http2FlowControlError;
                    stream_entry = entry;
                    stream_recv_window = stream_updated;
                    pending_stream_update = pending_update;
                },
                .vacant, .draining_response => {},
            }
        }
    }

    self.h2_connection_recv_window = connection_updated;
    self.h2_pending_connection_window_update = pending_connection_update;
    if (stream_entry) |entry| {
        entry.recv_window = stream_recv_window;
        entry.pending_recv_window_update = pending_stream_update;
    }
}

/// Whether the connection owes the client receive credit that a
/// WINDOW_UPDATE has not carried yet.
pub fn h2HasPendingWindowUpdate(self: *const Slot) bool {
    if (self.h2_pending_connection_window_update != 0)
        return true;
    for (self.stream_ids, 0..) |stream_id, position| {
        if (stream_id == 0)
            continue;
        if (stream_table.streamAt(self, position).pending_recv_window_update != 0)
            return true;
    }
    return false;
}

/// Whether the credit the connection owes must go out in WINDOW_UPDATE
/// frames of their own now, rather than behind the next frames the
/// connection writes anyway (`http2/writing.zig`): the client's view of the
/// connection's window, or of an open stream's that is owed credit, is at or
/// below half the window the lane advertised.
///
/// The client's view of a window is the lane's own less the credit owed:
/// A = W - H - U, where W is the advertised window, H the bytes the server
/// still holds, whose credit it withholds, and U the credit owed and unsent.
/// While A > W/2 the credit may wait, and once A <= W/2 it goes out with the
/// connection's next flush: a drive flushes before its first read and after
/// each one, and credit owed outside a drive asks for the turn whose drive
/// flushes it in the same pass (`http2/connection.zig`,
/// `writing.scheduleDueWindowUpdates`), so waiting for a write the
/// connection makes anyway never keeps the client at W/2 or below past the
/// read that brought it there, and once H alone reaches W/2 every credit
/// goes out as it is owed. The client's sender stalls only when H reaches W,
/// as it would with every credit sent at once, and credit is still owed only
/// for bytes the server no longer holds; only the moment its frame leaves
/// moves. The one exception is a connection whose socket refuses its writes:
/// nothing of it moves until its write poll, the credit included, and it is
/// not read meanwhile either.
pub fn h2WindowUpdateDue(self: *const Slot) bool {
    const connection_half: i64 = limits.h2.INGRESS_CONNECTION_RECV_WINDOW_BYTES / 2;
    const stream_half: i64 = limits.h2.INGRESS_STREAM_RECV_WINDOW_BYTES / 2;
    const connection_owed = self.h2_pending_connection_window_update;
    if (connection_owed != 0 and self.h2_connection_recv_window - connection_owed <= connection_half)
        return true;
    for (self.stream_ids, 0..) |stream_id, position| {
        if (stream_id == 0)
            continue;
        const entry = stream_table.streamAt(self, position);
        const owed = entry.pending_recv_window_update;
        if (owed == 0 or entry.request_body_complete)
            continue;
        if (entry.recv_window - owed <= stream_half)
            return true;
    }
    return false;
}

pub fn h2RestoreTakenPendingBodyConnectionCredit(self: *Slot, body: *PendingH2Body) !void {
    const window_credit_len = body.window_credit_len;
    if (window_credit_len == 0)
        return;
    // A taken body is no longer attached to its stream entry, so a failed
    // transfer returns only the connection's credit; the stream is reset or
    // the connection closes.
    try self.h2BufferInboundWindowUpdate(null, window_credit_len);
    body.window_credit_len = 0;
}

pub fn releasePendingBody(self: *Slot, allocator: std.mem.Allocator, entry: *H2StreamEntry) void {
    if (entry.pending_body.len == 0 and !entry.pending_body_complete and entry.pending_body_window_credit == 0)
        return;
    const window_credit_len = entry.pending_body_window_credit;
    if (entry.pending_body_len <= self.h2_pending_body_bytes)
        self.h2_pending_body_bytes -= entry.pending_body_len
    else
        self.h2_pending_body_bytes = 0;
    if (entry.pending_body.len != 0)
        allocator.free(entry.pending_body);
    entry.pending_body = &.{};
    entry.pending_body_len = 0;
    entry.pending_body_complete = false;
    entry.pending_body_window_credit = 0;
    if (window_credit_len != 0) {
        self.h2BufferInboundWindowUpdate(null, window_credit_len) catch |err| {
            std.debug.panic("invalid http2 pending body connection credit release: {s}", .{
                @errorName(err),
            });
        };
    }
}

pub const PendingH2Body = struct {
    allocation: []u8 = &.{},
    bytes: []u8 = &.{},
    end_stream: bool = false,
    window_credit_len: usize = 0,

    pub fn deinit(self: *PendingH2Body, allocator: std.mem.Allocator) void {
        if (self.allocation.len != 0)
            allocator.free(self.allocation);
        self.* = .{};
    }
};

pub const PendingH2BodyView = struct {
    bytes: []const u8 = &.{},
    end_stream: bool = false,
    window_credit_len: usize = 0,
};

fn ensurePendingBodyCapacity(allocator: std.mem.Allocator, entry: *H2StreamEntry, needed_len: usize) !void {
    if (needed_len <= entry.pending_body.len)
        return;
    var new_capacity = @max(entry.pending_body.len * 2, needed_len);
    if (new_capacity < 256)
        new_capacity = 256;
    if (new_capacity > max_h2_pending_body_bytes_per_stream)
        new_capacity = max_h2_pending_body_bytes_per_stream;
    if (new_capacity < needed_len)
        return error.Http2PendingBodyTooLarge;
    entry.pending_body = try allocator.realloc(entry.pending_body, new_capacity);
}
