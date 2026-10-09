//! The flow-control credit a fetch body chunk carries from the transport
//! engine until the consumer has taken the chunk, when it goes back to the
//! engine. A `Body` stores a handle beside its chunk and hands it out on drain
//! or release without interpreting it; the engine decides what a credit
//! reopens (`Engine.tryReleaseFetchBodyCredit` in
//! `egress/client/engine/root.zig`).
//!
//! Only the gateway's bodies carry credits. A worker's chunks carry `.none`,
//! because returning a body-pool extent to the gateway is the worker's
//! flow-control signal, and the gateway turns that release into the credit.

const std = @import("std");

/// HTTP/2 receive-window credit for one DATA frame. `source_id` and
/// `stream_id` name the stream's pending in the engine.
pub const H2Data = struct {
    source_id: u64,
    stream_id: u32,
    /// Encoded DATA frame payload bytes held back from HTTP/2 WINDOW_UPDATE.
    encoded_bytes: usize,
    /// False on the stream's last DATA frame, whose stream window needs no
    /// update; only the connection window reopens then.
    update_stream_window: bool,
};

/// Wakes the HTTP/1 body continuation with this resume source id when it is
/// parked on consumer backpressure; the engine drops a resume that finds the
/// continuation not parked.
pub const H1Resume = struct {
    source_id: u64,
};

pub const Handle = union(enum) {
    none,
    h2_data: H2Data,
    h1_resume: H1Resume,

    pub fn isNone(self: Handle) bool {
        return self == .none;
    }
};

pub fn h2Data(
    source_id: u64,
    stream_id: u32,
    encoded_bytes: usize,
    update_stream_window: bool,
) Handle {
    return .{ .h2_data = .{
        .source_id = source_id,
        .stream_id = stream_id,
        .encoded_bytes = encoded_bytes,
        .update_stream_window = update_stream_window,
    } };
}

pub fn h1Resume(source_id: u64) Handle {
    return .{ .h1_resume = .{
        .source_id = source_id,
    } };
}
