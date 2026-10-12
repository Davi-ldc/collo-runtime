//! The credit window of one response's body chunks, which the server's lane,
//! the host reader and the worker count the same way, and the server's
//! cumulative grant (`messages.ResponseCredit`) that the worker's control
//! socket carries. Each end keeps its `Window` on the thread that owns the
//! request, and `decode` validates a grant that comes from the other process.

const std = @import("std");
const limits = @import("collo_limits");
const messages = @import("messages.zig");
const packet = @import("packet.zig");

pub const window = limits.http_body.INGRESS_RESPONSE_CHUNKS_IN_FLIGHT_MAX;

/// The body chunks one response may hold that its client has not taken yet,
/// counted the same way on both ends. A chunk holds one credit from the
/// moment the worker publishes it until the client socket has accepted its
/// last byte; heads, ends and resets hold none. `spent` is the chunks the
/// worker published (worker) or the lane accepted (server and host);
/// `granted` is the cumulative total the server allowed: the window, plus
/// one per chunk whose credit came back.
pub const Window = struct {
    // A u64 chunk count cannot wrap within any request deadline.
    spent: u64 = 0,
    granted: u64 = window,

    pub fn available(self: Window) u64 {
        return self.granted - self.spent;
    }

    /// Worker: the caller already capped `count` by `available()`.
    pub fn spend(self: *Window, count: u64) void {
        std.debug.assert(count <= self.available());
        self.spent += count;
    }

    /// Server and host: false when the chunk passes the window, which is the
    /// worker fault `response_descriptor_invalid`.
    pub fn trySpend(self: *Window) bool {
        if (self.spent == self.granted) return false;
        self.spent += 1;
        return true;
    }

    /// Server and host: one chunk retired; returns the cumulative total to send.
    pub fn retire(self: *Window) u64 {
        std.debug.assert(self.granted - window < self.spent);
        self.granted += 1;
        return self.granted;
    }

    /// Worker: a cumulative grant. Totals at or below `granted` are ignored;
    /// a total more than `window` past `spent` is a server bug and fails.
    pub fn grant(self: *Window, total: u64) error{InvalidResponseCredit}!void {
        if (total <= self.granted) return;
        if (total - self.spent > window) return error.InvalidResponseCredit;
        self.granted = total;
    }
};

/// Sends one cumulative grant without allocating. A full socket returns
/// `error.WouldBlock`; its caller retains the newest grant for a later send.
pub fn send(fd: std.posix.fd_t, message: messages.ResponseCredit) !void {
    try packet.sendExactNonblocking(fd, std.mem.asBytes(&message));
}

/// Copies and validates the packet's scalars once. The packet stays with
/// the caller, whose `deinit` closes any descriptors a rejected packet held.
pub fn decode(received: *const packet.ReceivedPacket) !messages.ResponseCredit {
    if (received.fd_count != 0 or received.bytes.len != @sizeOf(messages.ResponseCredit))
        return error.InvalidPacket;
    const message = packet.readStruct(messages.ResponseCredit, received.bytes);
    if (message.kind != @intFromEnum(messages.MessageKind.response_credit))
        return error.InvalidMessageKind;
    if (message.reserved0 != 0 or message.grant_chunks_total < window)
        return error.InvalidPacket;
    return message;
}
