//! The reaper's memory policy as pure functions (`memory.zig` and
//! `reaping.zig` in `server/supervisor/reaper/`): the pressure band a usage
//! reading falls in, the reap plan each band gets and the window soft
//! pressure must hold before it gets one, the budget a plan allows, and the
//! victim score that weighs a worker's reclaimable bytes by its idle age. The
//! retirements that act on them are covered in `retirement.zig`. Lane
//! `server-supervisor-test`.

const std = @import("std");
const supervision = @import("collo_server_supervisor");

const reaping = supervision.reaper.reaping;
const memory = supervision.reaper.memory;
const memory_limits = supervision.scheduler_limits.memory;

test "memory pressure falls into soft, hard and critical bands, with the low water below soft" {
    try std.testing.expectEqual(memory.MemoryPressureMode.none, memory.memoryPressureFromUsedPercent(69).mode);
    try std.testing.expectEqual(memory.MemoryPressureMode.soft, memory.memoryPressureFromUsedPercent(70).mode);
    try std.testing.expectEqual(memory.MemoryPressureMode.hard, memory.memoryPressureFromUsedPercent(85).mode);
    try std.testing.expectEqual(memory.MemoryPressureMode.critical, memory.memoryPressureFromUsedPercent(92).mode);
    try std.testing.expect(
        memory.memoryPressureFromUsedPercent(65).used_percent <= memory.memory_pressure_low_water_percent,
    );
}

test "a victim score weighs reclaimable bytes by idle age, and an unreadable size still ranks by age" {
    const ttl = 10 * 60 * std.time.ns_per_s;
    const large_idle_500s = memory.workerMemoryVictimScore(1024 * 1024 * 1024, 500 * std.time.ns_per_s, ttl);
    const tiny_idle_600s = memory.workerMemoryVictimScore(100 * 1024, 600 * std.time.ns_per_s, ttl);
    const unknown_idle_500s = memory.workerMemoryVictimScoreWithUnknownFallback(0, 500 * std.time.ns_per_s, ttl);
    const unknown_idle_600s = memory.workerMemoryVictimScoreWithUnknownFallback(0, 600 * std.time.ns_per_s, ttl);
    try std.testing.expect(large_idle_500s > tiny_idle_600s);
    try std.testing.expect(unknown_idle_600s > unknown_idle_500s);
    try std.testing.expect(unknown_idle_500s > 0);
    // Idle age weighs from a twentieth up to one, in thousandths of the TTL.
    try std.testing.expectEqual(@as(u128, 50), memory.idleWeightScaled(1, ttl));
    try std.testing.expectEqual(@as(u128, 1000), memory.idleWeightScaled(ttl * 2, ttl));
}

test "soft pressure plans nothing until it has held unbroken for the sustain window" {
    var state = reaping.MemoryPressureState{};
    const start_ns = 100 * std.time.ns_per_s;
    const soft = memory.memoryPressureFromUsedPercent(70);

    // The first soft reading only starts the clock: reaping on it would let a
    // momentary spike cost a tenant its warm worker.
    try std.testing.expectEqual(
        @as(?reaping.MemoryPressurePlan, null),
        reaping.memoryPressurePlan(&state, start_ns, soft),
    );
    try std.testing.expectEqual(start_ns, state.started_mono_ns);

    const ready = reaping.memoryPressurePlan(
        &state,
        start_ns + memory_limits.soft_sustain_ns + std.time.ns_per_s,
        soft,
    ) orelse return error.ExpectedMemoryPressurePlan;
    try std.testing.expectEqual(@as(u8, 5), ready.percent);
    try std.testing.expectEqual(memory_limits.soft_stage_0_idle_ns, ready.min_idle_ns);

    // A calm reading breaks the window, and the next soft period starts over.
    try std.testing.expectEqual(
        @as(?reaping.MemoryPressurePlan, null),
        reaping.memoryPressurePlan(
            &state,
            start_ns + 32 * std.time.ns_per_s,
            memory.memoryPressureFromUsedPercent(69),
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), state.started_mono_ns);
    try std.testing.expectEqual(
        @as(?reaping.MemoryPressurePlan, null),
        reaping.memoryPressurePlan(&state, start_ns + 33 * std.time.ns_per_s, soft),
    );
    try std.testing.expectEqual(
        @as(?reaping.MemoryPressurePlan, null),
        reaping.memoryPressurePlan(&state, start_ns + 62 * std.time.ns_per_s, soft),
    );
}

test "calm plans nothing and restarts the window, while hard and critical pressure plan at once" {
    var state = reaping.MemoryPressureState{ .started_mono_ns = 5_000 };

    // An idle worker is warm capacity, and reclaiming it without pressure
    // costs a cold start nobody asked for. The window restarts, or the next
    // soft period would inherit credit from a calm one.
    try std.testing.expectEqual(
        @as(?reaping.MemoryPressurePlan, null),
        reaping.memoryPressurePlan(&state, 10_000, .{ .mode = .none, .used_percent = 40 }),
    );
    try std.testing.expectEqual(@as(u64, 0), state.started_mono_ns);

    // Hard pressure skips the window and reaps workers idle past the last
    // soft stage.
    const hard = reaping.memoryPressurePlan(&state, 10_000, .{ .mode = .hard, .used_percent = 88 }) orelse
        return error.ExpectedMemoryPressurePlan;
    try std.testing.expectEqual(memory_limits.soft_stage_2_idle_ns, hard.min_idle_ns);
    try std.testing.expectEqual(@as(u8, 25), hard.percent);
    try std.testing.expectEqual(@as(usize, 8), hard.cap);

    // Critical pressure takes any idle worker, since at this level the reading
    // itself is the evidence. The window opened on the first reading at or
    // above soft even though no plan waited for it, so a spike that settles
    // into a soft period keeps the clock the soft plan waits on.
    state.reset();
    const critical = reaping.memoryPressurePlan(&state, 10_000, .{ .mode = .critical, .used_percent = 95 }) orelse
        return error.ExpectedMemoryPressurePlan;
    try std.testing.expectEqual(@as(u64, 0), critical.min_idle_ns);
    try std.testing.expectEqual(@as(u8, 50), critical.percent);
    try std.testing.expectEqual(@as(usize, 16), critical.cap);
    try std.testing.expectEqual(@as(u64, 10_000), state.started_mono_ns);
}

test "the reap budget scales by percent and is bounded by the plan cap" {
    // At least one, so a pass under pressure always makes progress.
    try std.testing.expectEqual(@as(usize, 1), reaping.memoryPressureReapBudget(1, 5, 4));
    try std.testing.expectEqual(@as(usize, 1), reaping.memoryPressureReapBudget(10, 5, 4));
    // Rounds up: 25% of 10 is 2.5 candidates, and half a worker is one worker.
    try std.testing.expectEqual(@as(usize, 3), reaping.memoryPressureReapBudget(10, 25, 8));
    // The cap is the ceiling even when the percentage asks for more.
    try std.testing.expectEqual(@as(usize, 8), reaping.memoryPressureReapBudget(100, 25, 8));
    // Nothing to reap, nothing budgeted.
    try std.testing.expectEqual(@as(usize, 0), reaping.memoryPressureReapBudget(0, 50, 16));
}
