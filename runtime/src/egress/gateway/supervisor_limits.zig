//! The shard supervisor's containment limits: how often a shard may restart in place before its
//! failure ends the gateway process, and the memory budget of each shard. The supervisor
//! (`runtime/shard_flow.zig`), the shards and their tests all read these constants, so the
//! containment limits have one place to audit.

const std = @import("std");

/// Restart backstop: a shard may restart at most `max_restarts_in_window` times inside a trailing
/// `window_ns`, and the next failure inside the window propagates out of the run loop and ends
/// the gateway process. Every restart has already demoted or redispatched the shard's fetches, so
/// a shard that keeps dying on a fault restarting cannot clear, such as corrupted shared state,
/// would only burn work.
pub const shard_restart = struct {
    pub const max_restarts_in_window: usize = 3;
    pub const window_ns: u64 = 5 * 60 * std.time.ns_per_s;
};

/// Memory budget of the counting allocator of each shard, set when the shard is built. It turns a
/// runaway shard into a shard-local `error.OutOfMemory`, which demotes the fetch that allocated
/// or restarts the shard, instead of a node-wide out-of-memory kill. It is not a throttle: it
/// sits far above what a shard holds under steady load.
pub const shard_memory = struct {
    pub const budget_bytes: u64 = 256 * 1024 * 1024;
};
