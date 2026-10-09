//! The resource limits every worker gets, whatever its worker definition
//! says. It must import nothing; `root.zig` says why.

/// The `cpu.max` quota of a worker's cgroup leaf, in cores over the period
/// (`cpu.DEFAULT_PERIOD_US` in `common/cgroup.zig`): the CPU time all of the
/// worker's threads may take together in each period. A worker runs one
/// JavaScript turn at a time on its VM thread, so its JavaScript can use at
/// most one core, and the quota holds the worker as a whole, the engine's
/// compiler and collector threads, the crypto pool and the sentinel
/// included, to one core's time; a node runs requests in parallel on more
/// workers. The launch writes it to the leaf and sends it in `WorkerInit`,
/// and the child refuses a leaf whose `cpu.max` differs
/// (`zygote/worker_boot/cgroup.zig`).
pub const cpu_max_cores: u32 = 1;
