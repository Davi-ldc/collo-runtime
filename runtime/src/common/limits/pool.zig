//! Bounds of a worker definition's pool (`server/supervisor/pool.zig`). The
//! pool's launches in flight are scheduler policy and live in
//! `server/supervisor/scheduler_limits.zig`. It must import nothing;
//! `root.zig` says why.

/// Workers one definition's pool holds at once, live, retiring, dead or
/// launching: the entries of its table. A belt so that one definition cannot
/// swallow the machine; the memory gate is the real ceiling. Times
/// `worker_definitions_max` (`server.zig`) it is the most workers a server
/// can hold, which bounds the egress sessions a gateway may be asked to
/// attach, so the gateway reads it from here without importing the server.
pub const pool_workers_max: u32 = 16;

/// Requests one definition's pool queues for a worker slot before it answers
/// 503: a burst arriving while the pool grows waits here, and the bound caps
/// the FIFO scan a deadline's cancel makes under the pool mutex.
pub const pool_waiters_max: u32 = 256;
