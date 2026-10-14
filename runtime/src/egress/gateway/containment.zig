//! How the gateway contains one tenant's damage to its own fetches: how often a shard may restart
//! in place before its failure ends the gateway process, the memory budget of each shard, and the
//! budget of the request bodies the gateway assembles for pooled uploads. The shard supervision
//! (`runtime/shard_flow.zig`), the shards, the upload assembler (`runtime/upload_flow.zig`) and
//! their tests read these constants, so the containment limits have one place to audit.

const std = @import("std");
const ipc = @import("collo_ipc");

/// Restart backstop: a shard may restart at most `max_restarts_in_window` times inside a trailing
/// `window_ns`, and the next failure inside the window propagates out of the run loop and ends
/// the gateway process. Every restart has already failed the shard's fetches, so a shard that
/// keeps dying on a fault restarting cannot clear, such as corrupted shared state, would only
/// burn work.
pub const shard_restart = struct {
    pub const max_restarts_in_window: usize = 3;
    pub const window_ns: u64 = 5 * 60 * std.time.ns_per_s;
};

/// Memory budget of the counting allocator of each shard, set when the shard is built. It turns a
/// runaway shard into a shard-local `error.OutOfMemory`, which fails the fetch that allocated or
/// restarts the shard, instead of a node-wide out-of-memory kill. It is not a throttle: it sits
/// far above what a shard holds under steady load.
pub const shard_memory = struct {
    pub const budget_bytes: u64 = 256 * 1024 * 1024;
};

/// Memory budget of the counting allocator every pooled upload's assembly buffer comes from and
/// goes back to, wherever the task that holds it ends (`runtime/upload_flow.zig`,
/// `egress/client/task.zig:OwnedBody`). Every session shares it, so a full budget refuses the
/// next pooled start with a fetch error instead of letting uploads grow the gateway until the
/// kernel kills it; each session's own cap,
/// `ipc.fetch_limits.request_body_pooled_in_flight_bytes_max`, keeps one session to an eighth of
/// it. It is not a shard's allocator, because a shard over its budget restarts, which would fail
/// every fetch of the shard for one upload.
pub const upload_memory = struct {
    pub const budget_bytes: u64 = 8 * ipc.fetch_limits.request_body_pooled_in_flight_bytes_max;
};

comptime {
    // One session at its cap fits the budget with room for seven more.
    std.debug.assert(upload_memory.budget_bytes == 512 * 1024 * 1024);
    std.debug.assert(ipc.fetch_limits.request_body_pooled_in_flight_bytes_max * 8 <= upload_memory.budget_bytes);
}
