//! A lane's accept boundary: the multishot accept's registration and
//! completion handling, re-exported from `uring.zig`, and the close of an
//! accepted socket the lane refuses before any TLS byte is read. Runs on the
//! lane thread that owns the listener's accept.

const std = @import("std");
const lane = @import("lane.zig");

pub const AcceptRegistration = @import("uring.zig").AcceptRegistration;
pub const AcceptState = @import("uring.zig").AcceptState;
pub const AcceptCompletion = @import("uring.zig").AcceptCompletion;
pub const AcceptAction = @import("uring.zig").AcceptAction;
pub const Counters = @import("uring.zig").Counters;
pub const handleAcceptCompletion = @import("uring.zig").handleAcceptCompletion;
pub const packAcceptUserData = @import("uring.zig").packAcceptUserData;
pub const unpackAcceptUserData = @import("uring.zig").unpackAcceptUserData;

pub fn shouldRearmMultishot(action: AcceptAction) bool {
    return action == .rearm;
}

/// Why a lane closed a socket it accepted instead of setting up a connection.
pub const RejectReason = enum {
    connection_slab_exhaustion,
    shutting_down,
};

/// Closes `fd`, which the caller owns until this call, and counts the
/// refusal under `reason`.
pub fn closeRejectedAcceptedFd(fd: std.posix.fd_t, counters: *lane.CounterSnapshot, reason: RejectReason) void {
    switch (reason) {
        .connection_slab_exhaustion => counters.accepted_connection_slab_exhaustion += 1,
        // Expected while a graceful shutdown drains: the lane refuses new
        // connections once `shouldStop()` trips (`runner/accept_flow.zig`).
        // Its own counter keeps a shutdown from reading as slab exhaustion.
        .shutting_down => counters.accepted_during_shutdown += 1,
    }
    counters.silent_queue_overflows += 1;
    std.posix.close(fd);
}
