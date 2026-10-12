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

/// How long a pending module evaluation may stay pending, from the end of
/// its synchronous part; it matches the cap AWS Lambda puts on a function's
/// init phase. A hung await outlives every request that waits on it, so past
/// this budget its route is pinned failed (`expireEvaluation` in
/// `worker/modules/routes.zig`) and the requests parked on it get their 500.
/// The host adds it to the init deadline for the boot token's deadline
/// (`bootEgressDeadline` in `host/launch.zig`), so a worker that never
/// reports its startup evaluations ended still loses the token.
pub const MODULE_EVAL_BUDGET_NS: u64 = 10_000_000_000;

/// Time the child keeps before the init deadline
/// (`WorkerInit.init_deadline_mono_ns`) to stop the VM, report init_failed
/// and exit before the host kills it: the boot evaluation's watchdog fires
/// this long before the deadline. It should cover the 99th percentile of the
/// report-and-exit time that the boot-phase timestamps show; the current
/// value is an initial floor, not a measurement.
pub const WORKER_INIT_CLEANUP_RESERVE_NS: u64 = 100_000_000;

// The kernel's OOM victim order: workers first, then the egress gateway, then
// the zygote, and the server last. A worker's death ends only its own
// requests; the gateway's costs the fetches in flight and a respawn, and it
// is where the pooled uploads sit; the zygote's stops every launch and with
// it the server. oom_score_adj is inherited across fork and exec, so each
// spawn path writes its child's score (`writeOomScoreAdj` in
// `common/os.zig`); otherwise every descendant would keep the server's. Each
// score is at or above 0, and the runtime never writes the server's own:
// lowering a score below the `oom_score_adj_min` a process inherited takes
// CAP_SYS_RESOURCE, while raising one takes no privilege, so every write
// succeeds unprivileged. The server keeps the score it started with, 0 by
// default, and the order holds while that score stays below the zygote's. It
// backs up the worker cgroups' memory limits and never replaces them.
pub const OOM_SCORE_ADJ_WORKER: i16 = 500;
pub const OOM_SCORE_ADJ_EGRESS_GATEWAY: i16 = 300;
pub const OOM_SCORE_ADJ_ZYGOTE: i16 = 200;

comptime {
    if (OOM_SCORE_ADJ_WORKER <= OOM_SCORE_ADJ_EGRESS_GATEWAY)
        @compileError("the kernel must pick a worker before the egress gateway");
    if (OOM_SCORE_ADJ_EGRESS_GATEWAY <= OOM_SCORE_ADJ_ZYGOTE)
        @compileError("the kernel must pick the egress gateway before the zygote");
    if (OOM_SCORE_ADJ_ZYGOTE < 0)
        @compileError("a score below 0 needs a privilege the runtime does not require");
    // The kernel's range for oom_score_adj.
    if (OOM_SCORE_ADJ_WORKER > 1000)
        @compileError("oom_score_adj is at most 1000");
}

// Resource limits the egress gateway sets on itself before its first thread
// starts (`sandbox.zig` in `egress/gateway`). Each sets both the soft
// and the hard limit, and only ever lowers them: a hard limit the gateway
// inherited below one of these values stays as inherited, because raising it
// would need CAP_SYS_RESOURCE in the initial user namespace.

/// Open files of the gateway. Worker endpoints, shard rings and outbound
/// sockets all count against it, and `sizing.zig` in `egress/gateway`
/// sizes shards and the session cap from it.
pub const EGRESS_GATEWAY_OPEN_FILES_MAX: u64 = 65_536;
/// Tasks of the gateway's user. The gateway sets it after entering its own
/// user namespace, where kernels from 5.14 on count tasks per namespace, so
/// it bounds the gateway's threads rather than every process of the user
/// running the server.
pub const EGRESS_GATEWAY_TASKS_MAX: u64 = 1_024;
/// The most address space the gateway's sizing plan may give it
/// (`egress/gateway/sizing.zig:addressSpaceBytes`, which the gateway
/// applies). The plan's own sum is the backstop, above the sessions'
/// mappings, the shards' and uploads' budgets and the thread stacks; this
/// bounds the sum, and `sizing.zig` checks that the largest plan fits under
/// it. Address space costs nothing physical: the budgets bound what a
/// gateway spends.
pub const EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX: u64 = 128 * 1024 * 1024 * 1024;

/// Size of the tmpfs the gateway mounts as its root. It holds only the
/// directories and empty files its read-only binds cover, so one page would
/// do; this leaves room for a few more.
pub const EGRESS_GATEWAY_ROOT_TMPFS_BYTES: u64 = 64 * 1024;
/// Inodes of that tmpfs: its root, the directories under it and one mount
/// point per bind.
pub const EGRESS_GATEWAY_ROOT_TMPFS_INODES: u32 = 16;
