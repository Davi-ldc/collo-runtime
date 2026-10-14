//! Worker supervision in the server process. `supervisor.zig` is the
//! supervisor itself: one pool and the worker records of every worker
//! definition. `worker_registry.zig` builds a worker's record for a launch's
//! publish and tears it down for a retirement, and `worker_factory.zig`
//! prepares the egress side of a launch and ends a launch that produced no
//! worker. `pool.zig` is one definition's pool, `launcher.zig` the launcher
//! thread that turns a pool's claim into a published worker, with the launch
//! inputs it reads from the environment once at boot, `scale_out.zig` the
//! verdict, from the node's CPU, on when a definition gets a worker more
//! beside its live ones, and `reaper/` the
//! reaper thread that retires workers and reclaims memory. The data they
//! share sits beside them: a worker record with what the server reads off
//! its page (`worker_table.zig`), each worker's request table
//! (`request_table.zig`) and the scheduler's limits (`scheduler_limits.zig`).

const supervisor = @import("supervisor.zig");

pub const request_table = @import("request_table.zig");
pub const worker_factory = @import("worker_factory.zig");
pub const worker_registry = @import("worker_registry.zig");
pub const pool = @import("pool.zig");
pub const launcher = @import("launcher.zig");
pub const reaper = @import("reaper/root.zig");
pub const scale_out = @import("scale_out.zig");
pub const scheduler_limits = @import("scheduler_limits.zig");
pub const worker_table = @import("worker_table.zig");

pub const Supervisor = supervisor.Supervisor;
pub const Config = supervisor.Config;
pub const WorkerPool = supervisor.WorkerPool;
