//! A lane's multishot accept on its io_uring: the user_data that tags an
//! accept completion, the registration's arm, backoff and re-arm states, and
//! the classification of each completion. Runs on the lane thread.
//!
//! Invariants:
//! - An accept completion carries `tags.server_ingress_high_byte` in its top
//!   byte. The lane's other completions carry an `EventKind` there
//!   (`runner/event_sources.zig`), which never equals that tag, so the ring
//!   handler can try the accept decode first.
//! - Arming an inactive registration takes a new generation. A completion
//!   whose generation is not the current one, or that arrives while the
//!   registration is not active, only counts as stale; the lane closes any
//!   socket it carries.
//! - EMFILE or ENFILE on a terminal completion parks the registration in
//!   backoff instead of re-arming at once, since a re-arm would fail again
//!   while the descriptor table stays full.

const std = @import("std");
const ingress_state = @import("state.zig");
const tags = @import("collo_io_uring_tags");

/// IORING_CQE_F_MORE: the multishot request stays armed after this
/// completion.
pub const cqe_f_more: u32 = 1 << 1;
// The generation fills the bits between the lane id and the top tag byte.
const accept_generation_shift: u6 = 24;
const accept_lane_mask: u64 = (1 << accept_generation_shift) - 1;
const accept_generation_mask: u64 = (1 << 32) - 1;

pub const AcceptUserData = struct {
    lane_id: u16,
    generation: u64,
};

/// Fails with `error.AcceptGenerationTooLarge` when `generation` does not
/// fit its field.
pub fn packAcceptUserData(lane_id: u16, generation: u64) !u64 {
    if (generation > accept_generation_mask)
        return error.AcceptGenerationTooLarge;
    return (tags.server_ingress_high_byte << tags.high_byte_shift) |
        (generation << accept_generation_shift) |
        @as(u64, lane_id);
}

/// Fails with `error.InvalidUserDataTag` for a completion that is not an
/// accept, and with `error.InvalidLaneId` when the lane field exceeds u16.
pub fn unpackAcceptUserData(value: u64) !AcceptUserData {
    if ((value >> tags.high_byte_shift) != tags.server_ingress_high_byte)
        return error.InvalidUserDataTag;
    const lane_bits = value & accept_lane_mask;
    if (lane_bits > std.math.maxInt(u16))
        return error.InvalidLaneId;
    return .{
        .lane_id = @intCast(lane_bits),
        .generation = (value >> accept_generation_shift) & accept_generation_mask,
    };
}

pub const AcceptState = enum {
    inactive,
    active,
    backoff,
};

pub const AcceptRegistration = struct {
    state: AcceptState = .inactive,
    generation: u64 = 1,
    backoff_until_ns: u64 = 0,

    /// Returns the generation to submit under: a new one, or the current one
    /// while the registration is still active.
    pub fn arm(self: *AcceptRegistration) u64 {
        if (self.state == .active)
            return self.generation;
        self.generation = ingress_state.nextGeneration(self.generation);
        self.state = .active;
        return self.generation;
    }

    pub fn markBackoff(self: *AcceptRegistration, now_ns: u64, backoff_ns: u64) void {
        self.state = .backoff;
        self.backoff_until_ns = now_ns +| backoff_ns;
    }

    /// True once the backoff has elapsed, leaving the registration inactive
    /// for the caller to re-arm.
    pub fn finishBackoff(self: *AcceptRegistration, now_ns: u64) bool {
        if (self.state != .backoff or now_ns < self.backoff_until_ns)
            return false;
        self.state = .inactive;
        return true;
    }
};

pub const AcceptCompletion = struct {
    generation: u64,
    res: i32,
    flags: u32,
};

pub const AcceptAction = union(enum) {
    accepted: std.posix.fd_t,
    rearm,
    backoff,
    fatal,
    ignored_stale,
    transient,
};

pub const Counters = struct {
    multishot_accepted: u64 = 0,
    multishot_terminal_rearms: u64 = 0,
    multishot_stale_cqes: u64 = 0,
    accept_backoffs: u64 = 0,
    accept_transient_errors: u64 = 0,
    accept_fatal_errors: u64 = 0,
};

/// Classifies one accept completion and updates `registration`: a completion
/// without IORING_CQE_F_MORE ends the multishot and leaves the registration
/// inactive, or in backoff for `backoff_ns` on EMFILE and ENFILE. An
/// `.accepted` socket belongs to the caller.
pub fn handleAcceptCompletion(
    registration: *AcceptRegistration,
    completion: AcceptCompletion,
    now_ns: u64,
    backoff_ns: u64,
    counters: *Counters,
) AcceptAction {
    if (completion.generation != registration.generation or registration.state != .active) {
        counters.multishot_stale_cqes += 1;
        return .ignored_stale;
    }
    const more = (completion.flags & cqe_f_more) != 0;
    if (completion.res >= 0) {
        counters.multishot_accepted += 1;
        if (!more) {
            registration.state = .inactive;
            counters.multishot_terminal_rearms += 1;
        }
        return .{ .accepted = @intCast(completion.res) };
    }
    const err = linuxError(completion.res);
    if (!more)
        registration.state = .inactive;
    switch (err) {
        .MFILE, .NFILE => {
            if (more) {
                counters.accept_transient_errors += 1;
                return .transient;
            }
            registration.markBackoff(now_ns, backoff_ns);
            counters.accept_backoffs += 1;
            return .backoff;
        },
        .AGAIN, .INTR, .CONNABORTED => {
            counters.accept_transient_errors += 1;
            if (!more) {
                counters.multishot_terminal_rearms += 1;
                return .rearm;
            }
            return .transient;
        },
        else => {
            counters.accept_fatal_errors += 1;
            return .fatal;
        },
    }
}

fn linuxError(res: i32) std.os.linux.E {
    return @enumFromInt(-res);
}
