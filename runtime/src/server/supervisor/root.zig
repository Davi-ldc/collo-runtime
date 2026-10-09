//! Worker supervision in the server process. `supervisor.zig` is the
//! supervisor itself: one pool and the worker records of every worker
//! definition. `worker_registry.zig` builds a worker's record for a launch's
//! publish and tears it down for a retirement, and `worker_factory.zig`
//! prepares the egress side of a launch and ends a launch that produced no
//! worker. `usage_drain.zig` with `usage_log.zig` records usage, and each
//! worker's request table is in `request_table.zig`. `pool.zig` is one
//! definition's pool, `launcher.zig` the launcher thread that turns a pool's
//! claim into a published worker, with the launch inputs it reads from the
//! environment once at boot, and `reaper/` the reaper thread that retires
//! workers and reclaims memory. The data they share sits beside them: a
//! worker record (`worker_table.zig`), the usage identity (`accounting/`) and
//! the scheduler's limits (`scheduler_limits.zig`).

const supervisor = @import("supervisor.zig");

pub const request_table = @import("request_table.zig");
pub const usage_drain = @import("usage_drain.zig");
pub const usage_log = @import("usage_log.zig");
pub const worker_factory = @import("worker_factory.zig");
pub const worker_registry = @import("worker_registry.zig");
pub const pool = @import("pool.zig");
pub const launcher = @import("launcher.zig");
pub const reaper = @import("reaper/root.zig");
pub const accounting = @import("accounting/root.zig");
pub const scheduler_limits = @import("scheduler_limits.zig");
pub const worker_table = @import("worker_table.zig");

pub const Supervisor = supervisor.Supervisor;
pub const Config = supervisor.Config;
pub const WorkerPool = supervisor.WorkerPool;
pub const SettleOutcome = supervisor.SettleOutcome;
