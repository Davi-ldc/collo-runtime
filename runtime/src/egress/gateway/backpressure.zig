//! How full a worker's completion ring and body pool may get before the gateway shrinks, pauses
//! or stops what it publishes to that worker, and the worker pressure each level imposes on the
//! body drain. Pure functions, called from the gateway's loop thread.
//!
//! `reduced_chunks` and `paused` each have a lower threshold for leaving than for entering, so a
//! worker whose usage hovers near one of their thresholds does not change level on every loop
//! pass. Only the completion ring reaches `hard`, and the worker leaves it as soon as the ring
//! falls below `hard_percent`. At `hard` the gateway cancels the worker's fetches and, once the
//! worker has stayed there for `hard_drop_grace_ns`, drops its session (`runtime/worker_flow.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");

const policy_mod = @import("policy.zig");

const reduce_percent: u8 = 60;
const reduce_recover_percent: u8 = 50;
const pause_percent: u8 = 75;
const pause_recover_percent: u8 = 60;
const hard_percent: u8 = 95;
const body_chunk_bytes_max: usize = 16 * 1024;

/// How long a worker may stay at `hard` before the gateway drops its session.
pub const hard_drop_grace_ns: u64 = std.time.ns_per_s;

pub const Level = enum {
    normal,
    reduced_chunks,
    paused,
    hard,
};

pub fn computeForTest(
    current: Level,
    completion_usage: ipc.egress_shared.Usage,
    body_pool_usage: ipc.egress_shared.Usage,
) Level {
    return compute(current, completion_usage, body_pool_usage);
}

pub fn compute(
    current: Level,
    completion_usage: ipc.egress_shared.Usage,
    body_pool_usage: ipc.egress_shared.Usage,
) Level {
    // Only the completion ring escalates to hard, because a worker that
    // stops draining completions is breaking the protocol. A full body pool
    // only means a slow body consumer: the drain preflight pauses
    // publication and flow control holds the origin back, so a full pool
    // must never cost the worker its session.
    if (completion_usage.atLeastPercent(hard_percent))
        return .hard;

    if (completion_usage.atLeastPercent(pause_percent) or
        body_pool_usage.atLeastPercent(pause_percent))
    {
        return .paused;
    }

    if (current == .paused and
        (completion_usage.atLeastPercent(pause_recover_percent) or
            body_pool_usage.atLeastPercent(pause_recover_percent)))
    {
        return .paused;
    }

    if (body_pool_usage.atLeastPercent(reduce_percent))
        return .reduced_chunks;

    if (current == .reduced_chunks and
        body_pool_usage.atLeastPercent(reduce_recover_percent))
    {
        return .reduced_chunks;
    }

    return .normal;
}

/// The pressure the body drain obeys at `level`: chunks of at most `body_chunk_bytes_max` from
/// `reduced_chunks` on, and no new body pulls at `paused` and `hard`.
pub fn pressureForLevel(level: Level) policy_mod.WorkerPressure {
    return switch (level) {
        .normal => .{},
        .reduced_chunks => .{
            .max_body_chunk_bytes = body_chunk_bytes_max,
        },
        .paused, .hard => .{
            .pause_pulls = true,
            .max_body_chunk_bytes = body_chunk_bytes_max,
        },
    };
}
