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

/// How long a worker thread that holds a libpas allocator cache stays idle
/// before it stops its own allocators: the VM thread between turns, the
/// engine's helper threads in their idle wait, and the crypto pool's threads
/// between jobs. libpas stops an idle thread's allocators by suspending the
/// thread after `pas_local_allocator_should_stop_count_for_suspend` (5)
/// scavenger passes, one every `pas_scavenger_period_in_milliseconds` (100 on
/// Linux), and a worker's seccomp filter denies the signals that suspension
/// needs. A thread that stops its own allocators after the same 500 ms keeps
/// the memory behavior libpas has where it can suspend threads, and lets the
/// scavenger reach its deep sleep instead of polling for the worker's life.
pub const thread_cache_idle_release_ns: u64 = 500 * ns_per_ms;

/// Stack of each crypto pool thread (`worker/js/crypto/jobs.zig`), a property
/// of the binary rather than of a deployment. It must hold twice the deepest
/// stack any WebCrypto job uses at its largest parameters, plus what glibc
/// keeps inside a thread's stack (static TLS, the thread descriptor and the
/// guard), and never less than the target's `PTHREAD_STACK_MIN`, below which
/// thread creation fails. A worker test runs every job kind on pool threads
/// with half of it.
pub const crypto_thread_stack_bytes: u64 = 4 * 1024 * 1024;

/// glibc's `PTHREAD_STACK_MIN` on the larger of the two targets, aarch64;
/// x86_64's is 16 KiB.
const pthread_stack_min_bytes_max: u64 = 128 * 1024;

const ns_per_ms: u64 = 1_000_000;

comptime {
    if (crypto_thread_stack_bytes < pthread_stack_min_bytes_max)
        @compileError("a crypto pool thread's stack must be at least PTHREAD_STACK_MIN on every target");
    if (thread_cache_idle_release_ns == 0)
        @compileError("a thread must stay idle some time before it releases its cache");
}
