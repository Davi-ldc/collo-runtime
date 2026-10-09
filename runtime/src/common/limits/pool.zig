//! Bounds of a worker definition's pool (`server/supervisor/pool.zig`). The
//! pool's other two caps, its worker table and its launches in flight, are
//! scheduler policy and live in `server/supervisor/scheduler_limits.zig`. It
//! must import nothing; `root.zig` says why.

/// Requests one definition's pool queues for a worker slot before it answers
/// 503: a burst arriving while the pool grows waits here, and the bound caps
/// the FIFO scan a deadline's cancel makes under the pool mutex.
pub const pool_waiters_max: u32 = 256;
