//! The reaper's policy over idle workers: the idle TTL, the memory-pressure
//! plans and demand reclaim. Each pass lists every pool's idle workers
//! (`Pool.idleWorkers`) and retires the ones its policy picks through
//! `Reaper.retireIdleWorker`, which asks the pool again (`Pool.retireIdle`),
//! since a listed worker may take a request in between. A worker no lane
//! reads is torn down at once on the reaper thread, and one a lane reads
//! leaves when that lane lets it go, so a pressure reap re-reads memory only
//! after the retirements it could see.
//!
//! The passes run on the reaper thread (`root.zig`), which also serves the
//! retire queue, the pidfds it watches and stop, so each is bounded: the TTL
//! pass by `sweep_budget_ns` and `sweep_cap_max`, a reap by its plan's cap.
//! The plans and the budget are pure functions of their arguments.

const std = @import("std");
const process = @import("collo_os").process;
const config = @import("collo_server_config");

const memory = @import("memory.zig");
const limits = @import("../scheduler_limits.zig");
const worker_table = @import("../worker_table.zig");
const supervisor_mod = @import("../supervisor.zig");
const Reaper = @import("root.zig").Reaper;

const WorkerPool = supervisor_mod.WorkerPool;
const WorkerRecord = worker_table.Record;

/// The default delay between two periodic passes
/// (`Supervisor.reaper_interval_ns`).
pub const default_interval_ns: u64 = 5 * std.time.ns_per_s;

const soft_memory_pressure_sustain_ns: u64 = limits.memory.soft_sustain_ns;
const soft_memory_pressure_stage_ns: u64 = limits.memory.soft_stage_ns;
const soft_stage_0_idle_ns: u64 = limits.memory.soft_stage_0_idle_ns;
const soft_stage_1_idle_ns: u64 = limits.memory.soft_stage_1_idle_ns;
const soft_stage_2_idle_ns: u64 = limits.memory.soft_stage_2_idle_ns;
const memory_pressure_reap_cap_max: usize = limits.memory.reap_cap_max;
const sweep_cap_max: usize = limits.memory.sweep_cap_max;
const sweep_budget_ns: u64 = limits.memory.sweep_budget_ns;
const pool_workers_max = limits.capacity.pool_workers_max;

/// The soft plan's clock, kept across passes in the supervisor
/// (`Supervisor.memory_pressure_state`) and touched by the reaper thread
/// only.
pub const MemoryPressureState = struct {
    /// Start of the current unbroken period at or above soft pressure, 0
    /// when pressure is below it.
    started_mono_ns: u64 = 0,

    pub fn reset(self: *MemoryPressureState) void {
        self.* = .{};
    }
};

/// One pressure reap: workers idle for at least `min_idle_ns` are
/// candidates, and the reap retires the best-scoring `percent` of them,
/// rounded up, at least one and at most `cap` (`memoryPressureReapBudget`),
/// stopping early once usage falls to `memory_pressure_low_water_percent`.
pub const MemoryPressurePlan = struct {
    min_idle_ns: u64,
    percent: u8,
    cap: usize,
};

/// Demand reclaim (`Reaper.demandPass`): a claimed launch is the signal, so
/// the plan skips the soft sustain and takes a small batch of workers idle
/// for any time at all, so memory comes back at the pace of launches.
pub const demand_plan: MemoryPressurePlan = .{
    .min_idle_ns = 1,
    .percent = 25,
    .cap = 4,
};

comptime {
    std.debug.assert(demand_plan.cap <= memory_pressure_reap_cap_max);
}

/// The plan `pressure` calls for at `now`, or null for none, advancing the
/// soft plan's clock in `state`: soft pressure plans nothing until it has
/// lasted `soft_sustain_ns`, then lowers its idle floor stage by stage; hard
/// and critical pressure plan at once, and critical takes workers idle for
/// any time. Pressure below soft resets the clock.
pub fn memoryPressurePlan(
    state: *MemoryPressureState,
    now: u64,
    pressure: memory.MemoryPressure,
) ?MemoryPressurePlan {
    if (pressure.mode == .none) {
        state.reset();
        return null;
    }
    if (state.started_mono_ns == 0)
        state.started_mono_ns = now;
    return switch (pressure.mode) {
        .none => null,
        .soft => softMemoryPressurePlan(state, now),
        .hard => .{
            .min_idle_ns = soft_stage_2_idle_ns,
            .percent = 25,
            .cap = 8,
        },
        .critical => .{
            .min_idle_ns = 0,
            .percent = 50,
            .cap = 16,
        },
    };
}

fn softMemoryPressurePlan(state: *MemoryPressureState, now: u64) ?MemoryPressurePlan {
    const elapsed_ns = now -| state.started_mono_ns;
    if (elapsed_ns < soft_memory_pressure_sustain_ns)
        return null;

    const stage_elapsed_ns = elapsed_ns - soft_memory_pressure_sustain_ns;
    if (stage_elapsed_ns < soft_memory_pressure_stage_ns) {
        return .{
            .min_idle_ns = soft_stage_0_idle_ns,
            .percent = 5,
            .cap = 4,
        };
    }
    if (stage_elapsed_ns < soft_memory_pressure_stage_ns * 2) {
        return .{
            .min_idle_ns = soft_stage_1_idle_ns,
            .percent = 5,
            .cap = 4,
        };
    }
    return .{
        .min_idle_ns = soft_stage_2_idle_ns,
        .percent = 10,
        .cap = 8,
    };
}

pub fn memoryPressureReapBudget(candidate_count: usize, percent: u8, cap: usize) usize {
    if (candidate_count == 0)
        return 0;
    const by_percent = std.math.divCeil(usize, candidate_count * @as(usize, percent), 100) catch 1;
    return @min(cap, @max(@as(usize, 1), by_percent));
}

/// Retires the idle workers past `Supervisor.worker_idle_ttl_ns`, longest
/// idle first in each pool, and returns how many. A TTL of 0 turns the pass
/// off: an idle worker is the warm capacity the pool keeps on purpose.
pub fn idleTtlPass(reaper: *Reaper, now_ns: u64) usize {
    const ttl_ns = reaper.supervisor.worker_idle_ttl_ns;
    if (ttl_ns == 0)
        return 0;
    var budget = SweepBudget.start();
    var retired: usize = 0;
    for (reaper.supervisor.pools, 0..) |*definition_pool, index| {
        const definition: config.DefinitionIndex = @intCast(index);
        var buffer: [pool_workers_max]WorkerPool.IdleWorker = undefined;
        for (definition_pool.idleWorkers(&buffer)) |idle| {
            if (budget.spent()) {
                std.log.info("idle worker sweep out of budget after {d}; the rest wait for the next pass", .{retired});
                reaper.count("idle_ttl_retirements", retired);
                return retired;
            }
            if (now_ns -| idle.idle_since_ns < ttl_ns) continue;
            if (!reaper.retireIdleWorker(definition, idle.worker)) continue;
            retired += 1;
            budget.retired += 1;
        }
    }
    reaper.count("idle_ttl_retirements", retired);
    return retired;
}

/// Retires idle workers under `plan`, best victim first, and returns how
/// many it retired. Candidates are every pool's workers idle at least
/// `plan.min_idle_ns`, scored by their private memory weighted by idle age
/// (`memory.workerMemoryVictimScoreWithUnknownFallback`); the reap stops
/// early once the node's memory is at the low water or calm.
pub fn reapWithPlan(reaper: *Reaper, now_ns: u64, plan: MemoryPressurePlan) usize {
    std.debug.assert(plan.cap <= memory_pressure_reap_cap_max);
    var victims: VictimSet = .{};
    var candidate_count: usize = 0;
    for (reaper.supervisor.pools, 0..) |*definition_pool, index| {
        var buffer: [pool_workers_max]WorkerPool.IdleWorker = undefined;
        for (definition_pool.idleWorkers(&buffer)) |idle| {
            const idle_ns = now_ns -| idle.idle_since_ns;
            if (idle_ns < plan.min_idle_ns) continue;
            candidate_count += 1;
            victims.insert(.{
                .definition = @intCast(index),
                .worker = idle.worker,
                .score = victimScore(reaper, idle.worker, idle_ns),
            }, plan.cap);
        }
    }

    const budget = memoryPressureReapBudget(candidate_count, plan.percent, plan.cap);
    var retired: usize = 0;
    while (retired < budget) {
        const victim = victims.takeBest() orelse break;
        if (!reaper.retireIdleWorker(victim.definition, victim.worker)) continue;
        retired += 1;
        const updated = memory.readMemoryPressure(reaper.gpa) catch break;
        if (updated.used_percent <= memory.memory_pressure_low_water_percent or updated.mode == .none)
            break;
    }
    return retired;
}

/// A worker's victim score from its private resident bytes, or from its
/// cgroup's `memory.current` when those cannot be read. The record is idle
/// in its pool, and only the reaper empties a record, so its handle stays
/// valid for the read.
fn victimScore(reaper: *Reaper, worker: *WorkerRecord, idle_ns: u64) u128 {
    const ttl_ns = reaper.supervisor.worker_idle_ttl_ns;
    const bytes = memory.readWorkerPrivateRssBytes(reaper.gpa, worker.handle.pid) catch
        (memory.readWorkerMemoryCurrent(reaper.gpa, worker.handle.cgroup_dir) catch 0);
    return memory.workerMemoryVictimScoreWithUnknownFallback(bytes, idle_ns, ttl_ns);
}

/// The bound of one sweep: `sweep_budget_ns` of wall time, with
/// `sweep_cap_max` retirements as the backstop.
const SweepBudget = struct {
    started_ns: u64,
    retired: usize = 0,

    fn start() SweepBudget {
        return .{ .started_ns = process.monotonicNowNsOrZero() };
    }

    fn spent(self: *const SweepBudget) bool {
        if (self.retired >= sweep_cap_max)
            return true;
        const now = process.monotonicNowNsOrZero();
        return now -| self.started_ns >= sweep_budget_ns;
    }
};

const Victim = struct {
    definition: config.DefinitionIndex,
    worker: *WorkerRecord,
    score: u128,
};

/// The best-scoring candidates of a reap, at most a plan's cap.
const VictimSet = struct {
    items: [memory_pressure_reap_cap_max]Victim = undefined,
    len: usize = 0,

    fn insert(self: *VictimSet, candidate: Victim, cap: usize) void {
        std.debug.assert(cap <= self.items.len);
        // `workerMemoryVictimScoreWithUnknownFallback` scores every worker
        // at least one byte at the lowest idle weight.
        std.debug.assert(candidate.score > 0);
        if (cap == 0)
            return;
        if (self.len < cap) {
            self.items[self.len] = candidate;
            self.len += 1;
            return;
        }
        const worst = self.worstIndex();
        if (candidate.score > self.items[worst].score)
            self.items[worst] = candidate;
    }

    fn takeBest(self: *VictimSet) ?Victim {
        if (self.len == 0)
            return null;
        var best: usize = 0;
        for (self.items[1..self.len], 1..) |candidate, index| {
            if (candidate.score > self.items[best].score)
                best = index;
        }
        const victim = self.items[best];
        self.len -= 1;
        self.items[best] = self.items[self.len];
        return victim;
    }

    fn worstIndex(self: *const VictimSet) usize {
        std.debug.assert(self.len != 0);
        var worst: usize = 0;
        for (self.items[1..self.len], 1..) |candidate, index| {
            if (candidate.score < self.items[worst].score)
                worst = index;
        }
        return worst;
    }
};
