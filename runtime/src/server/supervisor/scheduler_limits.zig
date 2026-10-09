//! The scheduler's policy numbers: the memory levels that gate pool growth
//! and drive the reaper, and the capacity of each worker definition's pool.
//! Consumers import them from here instead of repeating them.
//!
//! Each number is a policy choice tied to a metric that says which way to
//! move it (`skills/runtime/references/internals/scheduler.md`), so a
//! change starts from a measurement of that metric. The ties between these
//! numbers and the pool's own bounds are asserted where the pools are built
//! (`Supervisor.init` in `supervisor.zig`).

const std = @import("std");

/// Memory levels, in percent of the memory `readMemoryPressure` in
/// `reaper/memory.zig` reads: the server's own cgroup against its
/// `memory.max`, or the machine's `/proc/meminfo` when that cgroup has no
/// limit. In the delegated placement the server's cgroup is `<own>/main`,
/// which it creates without a limit, so the levels are of the machine's
/// memory.
///
/// The high water does not cap pool growth. Launches continue above it, and
/// the room up to `fork_deny_percent` absorbs load while more nodes come up;
/// only `fork_deny_percent` closes the memory gate.
pub const memory = struct {
    /// At or above it, a claimed launch also wakes demand reclaim
    /// (`Supervisor.claimLaunch` in `supervisor.zig`) and soft pressure
    /// starts its sustain. Below it, idle workers are a latency cache and
    /// nothing is reaped for memory.
    pub const autoscale_high_water_percent: u8 = 70;
    /// A memory-pressure pass stops killing once usage is at or below this,
    /// or once pressure ends below `autoscale_high_water_percent`
    /// (`reapWithPlan` in `reaper/reaping.zig`).
    /// FIXME: usage falling from above crosses the high water first, so a
    /// pass always stops there and this level never decides anything.
    pub const reclaim_low_water_percent: u8 = 65;
    /// At or above, pressure is hard: the reaper skips the soft sustain and
    /// its stages, and reaps workers idle at least `soft_stage_2_idle_ns`
    /// (`memoryPressurePlan` in `reaper/reaping.zig`).
    /// FIXME: the name promises an eviction before each fork, which no code
    /// performs; a launch at this level only wakes demand reclaim, as it does
    /// from the high water up.
    pub const evict_before_fork_percent: u8 = 85;
    /// At or above, the memory gate refuses pool growth
    /// (`Supervisor.memoryGate`): a request waits for a slot that frees, or,
    /// when no worker is live and no launch is in flight, gets 503 at once
    /// (`Pool.takeStranded` in `pool.zig`). That keeps the node clear of the
    /// kernel's OOM killer. The reaper's critical plan starts at the same
    /// level.
    pub const fork_deny_percent: u8 = 92;

    /// The PSI trigger the reaper arms on `/proc/pressure/memory`
    /// (`MemoryPressureWake` in `reaper/memory.zig`) fires when the time
    /// during which at least one task stalled on memory adds up to
    /// `psi_stall_us` within a window of `psi_window_us`, 15% of it.
    pub const psi_stall_us: u32 = 300 * std.time.us_per_ms;
    /// The kernel takes a window from 500 ms to 10 s, and from a process
    /// without `CAP_SYS_RESOURCE` only a multiple of 2 s
    /// (`Documentation/accounting/psi.rst`); kernels before Linux 6.4 give
    /// such a process no trigger at all. The server refuses to run as root,
    /// so it holds that capability only when whatever starts it grants it,
    /// and the window is one it may arm without.
    pub const psi_window_us: u32 = 2 * std.time.us_per_s;
    /// The trigger in the kernel's syntax, threshold and window in
    /// microseconds.
    pub const psi_some_trigger = std.fmt.comptimePrint("some {d} {d}", .{ psi_stall_us, psi_window_us });

    comptime {
        std.debug.assert(psi_stall_us > 0);
        std.debug.assert(psi_stall_us <= psi_window_us);
        std.debug.assert(psi_window_us >= 500 * std.time.us_per_ms);
        std.debug.assert(psi_window_us <= 10 * std.time.us_per_s);
        std.debug.assert(psi_window_us % (2 * std.time.us_per_s) == 0);
    }

    /// Soft pressure must last this long before staged reaping begins.
    /// Demand reclaim, which a launch wakes from the high water up, skips the
    /// sustain.
    pub const soft_sustain_ns: u64 = 30 * std.time.ns_per_s;
    /// Time between soft reap stages.
    pub const soft_stage_ns: u64 = 10 * std.time.ns_per_s;
    /// Idle floor per soft stage: only workers idle at least this long are
    /// eligible, and the floor drops as pressure lasts. Hard pressure uses
    /// the last stage's floor from the start.
    pub const soft_stage_0_idle_ns: u64 = 10 * 60 * std.time.ns_per_s;
    pub const soft_stage_1_idle_ns: u64 = 5 * 60 * std.time.ns_per_s;
    pub const soft_stage_2_idle_ns: u64 = 3 * 60 * std.time.ns_per_s;
    /// The most workers one memory-pressure pass retires. It sizes the
    /// pass's victim list (`VictimSet` in `reaper/reaping.zig`), so every
    /// plan's cap must stay at or below it, which `reapWithPlan` asserts.
    pub const reap_cap_max: usize = 16;
    /// Time budget of the idle-TTL sweep. The sweep makes no policy choice,
    /// since every worker it retires is already past its TTL, so it has no
    /// victim budget. It still needs a bound: a retirement of a worker no
    /// lane reads pays the full teardown on the reaper thread, and that
    /// thread also serves the pressure trigger, demand reclaim, the retire
    /// queue and stop.
    ///
    /// The budget is time rather than a count because teardowns cost unequal
    /// amounts: one waits for the worker's exit up to `PROCESS_EXIT_WAIT_MS`
    /// (`common/limits/process.zig`) and retries the cgroup removal while the
    /// kernel tears the address space down, so a count large enough to matter
    /// for cheap teardowns stalls for seconds on expensive ones. What the
    /// budget defers, the next pass takes.
    pub const sweep_budget_ns: u64 = 500 * std.time.ns_per_ms;
    /// A count bound under the time budget, so that a clock that does not
    /// advance cannot leave a sweep unbounded.
    pub const sweep_cap_max: usize = 256;
};

/// The capacity of one worker definition's pool (`pool.zig`).
pub const capacity = struct {
    /// Table entries of one pool: the workers of one definition that are
    /// live, retiring, dead or launching at once. A safety belt so a single
    /// definition cannot swallow the machine; the real ceiling is the memory
    /// gate.
    pub const pool_workers_max: u32 = 16;
    /// Launches one pool may have in flight at once. The launcher and the
    /// zygote serve one fork at a time for the whole node, so the cap keeps
    /// a burst on one definition from queueing every other definition's
    /// launches behind its own, and keeps a pool from launching for waiters
    /// that a slot freeing moments later would serve.
    pub const pool_cold_starts_in_flight_max: u32 = 2;
};
