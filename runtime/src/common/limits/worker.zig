//! The resource limits every worker gets, whatever its worker definition
//! says: constants both the server and the worker compile, so none travels
//! in `WorkerInit`. It imports only its siblings; `root.zig` says why.

const server = @import("server.zig");

/// The `cpu.max` quota of a worker's cgroup leaf, in cores over the period
/// (`cpu.DEFAULT_PERIOD_US` in `common/cgroup.zig`): the CPU time all of the
/// worker's threads may take together in each period. A worker runs one
/// JavaScript turn at a time on its VM thread, so its JavaScript can use at
/// most one core, and the quota holds the worker as a whole, the engine's
/// compiler and collector threads and the sentinel included, to one core's
/// time; a node runs requests in parallel on more workers. The launch writes
/// it to the leaf, and the child refuses a leaf whose `cpu.max` differs
/// (`zygote/worker_boot/cgroup.zig`).
pub const cpu_max_cores: u32 = 1;

/// Fetches one request may start, finished ones included.
pub const fetches_per_request_max: usize = 16;

/// Fetches the worker may have in flight at once, over all its requests.
pub const fetches_per_worker_max: usize = 64;

/// Fetch body views the worker holds at once, clones included: every fetch
/// the per-token caps let its requests and its startup evaluations start
/// keeps its body, and the rest is room for clones, past which a clone or a
/// fetch fails in the worker (`worker/egress/body/register.zig`). It bounds
/// the worker's `fetch_body_ready` items.
pub const fetch_bodies_per_worker_max: usize = 512;

/// `fetch_completion` and `fetch_body_ready` items the worker's ready queue
/// and its backlog hold at once, at most: a fetch task queues one completion
/// for its life, and the tasks with the completions still queued for tasks
/// already gone stay within `fetches_per_worker_max`
/// (`worker/egress/fetch_runtime.zig:schedule`); a body view has at most one
/// item queued, and the views with the items still queued for views already
/// gone stay within `fetch_bodies_per_worker_max`
/// (`worker/egress/body/register.zig:reserveSlot`). The backlog keeps this
/// many slots for them, so queueing one never fails
/// (`worker/runtime/scheduler.zig:queueReadyWork`).
pub const egress_ready_items_max: usize = fetches_per_worker_max + fetch_bodies_per_worker_max;

/// Timers the worker may have armed at once, over all its requests and
/// evaluations.
pub const timers_per_worker_max: usize = 256;

/// Items the worker's ready queue holds at once.
pub const ready_queue_capacity: usize = 256;

/// Requests the worker keeps a task for at once: one per pool slot, the
/// largest `concurrency` a definition may set, which is also the page's
/// `LIVE_SLOT_COUNT` (`runtime/tests/contracts/limits.zig`).
pub const request_task_capacity: usize = server.worker_concurrency_max;

/// How long a worker thread that holds a libpas allocator cache stays idle
/// before it stops its own allocators: the VM thread between turns and the
/// engine's helper threads in their idle wait. libpas stops an idle thread's
/// allocators by suspending the thread after
/// `pas_local_allocator_should_stop_count_for_suspend` (5) scavenger passes,
/// one every `pas_scavenger_period_in_milliseconds` (100 on Linux), and a
/// worker's seccomp filter denies the signals that suspension needs. A thread
/// that stops its own allocators after the same 500 ms keeps the memory
/// behavior libpas has where it can suspend threads, and lets the scavenger
/// reach its deep sleep instead of polling for the worker's life.
pub const thread_cache_idle_release_ns: u64 = 500 * ns_per_ms;

const ns_per_ms: u64 = 1_000_000;

comptime {
    if (thread_cache_idle_release_ns == 0)
        @compileError("a thread must stay idle some time before it releases its cache");
    if (fetches_per_request_max == 0 or fetches_per_request_max > fetches_per_worker_max)
        @compileError("a request's fetches must fit the worker's");
    if (fetch_bodies_per_worker_max < (request_task_capacity + 1) * fetches_per_request_max)
        @compileError("every fetch the per-token caps allow must be able to keep its body");
    if (timers_per_worker_max == 0 or ready_queue_capacity == 0 or request_task_capacity == 0)
        @compileError("every worker table must hold at least one item");
}
