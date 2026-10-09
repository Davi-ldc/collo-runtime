//! Timeouts, buffer sizes, OOM scores and resource limits for the lifecycle
//! of the runtime's processes: the host, the zygote, the worker and the egress
//! gateway. It must import nothing; `root.zig` says why.

/// Bound on a pidfd wait during teardown, after the process was sent SIGKILL
/// or told to exit. The wait covers only the exit itself, so a wedged process
/// cannot stall teardown past this bound.
pub const PROCESS_EXIT_WAIT_MS: i32 = 1_000;

/// Size of the fixed buffer a trace line is formatted into, so tracing never
/// allocates, even on the zygote's paths and a dying worker's. A line that
/// does not fit is dropped, not split.
pub const TRACE_EVENT_BUFFER_BYTES: usize = 192;

/// Length of a worker's init window. A freshly forked child waits this long
/// for WorkerInit (`recvWorkerInitBeforeTimeout` in `zygote/child_boot.zig`),
/// and the host gives the child this long from sending WorkerInit to its
/// outcome; the host's deadline arithmetic is in `host/launch.zig`.
pub const WORKER_INIT_TIMEOUT_MS: i32 = 3_000;

/// Time the child keeps before the init deadline
/// (`WorkerInit.init_deadline_mono_ns`) to stop the VM, report init_failed
/// and exit before the host kills it: the boot evaluation's watchdog fires
/// this long before the deadline. It should cover the 99th percentile of the
/// report-and-exit time that the boot-phase timestamps show; the current
/// value is an initial floor, not a measurement.
pub const WORKER_INIT_CLEANUP_RESERVE_NS: u64 = 100_000_000;

// The kernel's OOM victim order puts workers first and the zygote next, ahead
// of the server for as long as the score the server started with stays below
// the zygote's; nothing in the runtime sets the server's own score.
// oom_score_adj is inherited across fork and exec, so each spawn path writes
// its child's score explicitly (`writeOomScoreAdj` in `common/os.zig`);
// otherwise every descendant would keep the server's score. The order backs
// up the worker cgroups' memory limits and never replaces them. The gateway's
// score is the only one below the default 0, and lowering a score below the
// `oom_score_adj_min` the gateway inherits from the server takes
// CAP_SYS_RESOURCE, so the write succeeds only when the server holds that
// capability or that minimum is at or below the gateway's score. The gateway
// then goes after any server whose score is higher. Otherwise the write fails
// with EACCES and the gateway keeps the server's score, which leaves the
// kernel to pick whichever of the two uses more memory first.
pub const OOM_SCORE_ADJ_WORKER: i16 = 500;
pub const OOM_SCORE_ADJ_ZYGOTE: i16 = 200;
pub const OOM_SCORE_ADJ_EGRESS_GATEWAY: i16 = -500;

// Resource limits the egress gateway sets on itself before its first thread
// starts (`sandbox.zig` in `egress/gateway`). Each sets both the soft
// and the hard limit, and only ever lowers them: a hard limit the gateway
// inherited below one of these values stays as inherited, because raising it
// would need CAP_SYS_RESOURCE in the initial user namespace.

/// Open files of the gateway. Worker endpoints, shard rings and outbound
/// sockets all count against it, and `sizing.zig` in `egress/gateway`
/// sizes shards and the worker cap from it.
pub const EGRESS_GATEWAY_OPEN_FILES_MAX: u64 = 65_536;
/// Tasks of the gateway's user. The gateway sets it after entering its own
/// user namespace, where kernels from 5.14 on count tasks per namespace, so
/// it bounds the gateway's threads rather than every process of the user
/// running the server.
pub const EGRESS_GATEWAY_TASKS_MAX: u64 = 1_024;
/// Address space of the gateway, a backstop above the shards' memory budgets.
pub const EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX: u64 = 4 * 1024 * 1024 * 1024;

/// Size of the tmpfs the gateway mounts as its root. It holds only the
/// directories and empty files its read-only binds cover, so one page would
/// do; this leaves room for a few more.
pub const EGRESS_GATEWAY_ROOT_TMPFS_BYTES: u64 = 64 * 1024;
/// Inodes of that tmpfs: its root, the directories under it and one mount
/// point per bind.
pub const EGRESS_GATEWAY_ROOT_TMPFS_INODES: u32 = 16;
