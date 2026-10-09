//! One shard's own pieces (`egress/gateway/shard.zig`, `counting_allocator.zig`): the default
//! shard count, the parse of cgroup v2 `cpu.max`, the counting allocator's live bytes and budget
//! under concurrent allocation, the engine allocating through it, and a restart at a full budget.
//! The steps of a restart are covered one at a time in `shard_lifecycle.zig`, and the shard
//! supervisor running them in `shard_chaos.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const shard = gateway.shard;

test "default shard count is half the cores with floor 2 and cap 8" {
    try std.testing.expectEqual(@as(usize, 1), shard.defaultShardCountForCpus(0));
    try std.testing.expectEqual(@as(usize, 1), shard.defaultShardCountForCpus(1));
    try std.testing.expectEqual(@as(usize, 2), shard.defaultShardCountForCpus(2));
    try std.testing.expectEqual(@as(usize, 2), shard.defaultShardCountForCpus(3));
    try std.testing.expectEqual(@as(usize, 2), shard.defaultShardCountForCpus(4));
    try std.testing.expectEqual(@as(usize, 4), shard.defaultShardCountForCpus(8));
    try std.testing.expectEqual(@as(usize, 8), shard.defaultShardCountForCpus(16));
    try std.testing.expectEqual(@as(usize, 8), shard.defaultShardCountForCpus(22));
    try std.testing.expectEqual(@as(usize, 8), shard.defaultShardCountForCpus(64));
}

test "cpu.max parses quota and period into whole cores rounding up" {
    try std.testing.expectEqual(@as(?usize, 4), shard.parseCpuMaxCores("400000 100000\n"));
    try std.testing.expectEqual(@as(?usize, 1), shard.parseCpuMaxCores("50000 100000\n"));
    try std.testing.expectEqual(@as(?usize, 3), shard.parseCpuMaxCores("250000 100000\n"));
    try std.testing.expectEqual(@as(?usize, 1), shard.parseCpuMaxCores("100000 100000"));
}

test "cpu.max unlimited or malformed yields no quota" {
    try std.testing.expectEqual(@as(?usize, null), shard.parseCpuMaxCores("max 100000\n"));
    try std.testing.expectEqual(@as(?usize, null), shard.parseCpuMaxCores(""));
    try std.testing.expectEqual(@as(?usize, null), shard.parseCpuMaxCores("garbage"));
    try std.testing.expectEqual(@as(?usize, null), shard.parseCpuMaxCores("100000"));
    try std.testing.expectEqual(@as(?usize, null), shard.parseCpuMaxCores("0 100000"));
    try std.testing.expectEqual(@as(?usize, null), shard.parseCpuMaxCores("100000 0"));
}

test "counting allocator tracks live bytes across alloc, resize, and free" {
    var counting = gateway.counting_allocator.CountingAllocator{ .child = std.testing.allocator };
    const allocator = counting.allocator();

    const first = try allocator.alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 100), counting.liveBytes());
    const second = try allocator.alloc(u8, 28);
    try std.testing.expectEqual(@as(u64, 128), counting.liveBytes());

    allocator.free(first);
    try std.testing.expectEqual(@as(u64, 28), counting.liveBytes());
    // The list grows by resize, remap or a copy, and whichever it takes, the
    // gauge must count exactly the list's new capacity.
    var list = std.array_list.Aligned(u8, null).empty;
    defer {
        list.deinit(allocator);
        allocator.free(second);
    }
    try list.appendNTimes(allocator, 7, 300);
    try std.testing.expectEqual(@as(u64, 28 + list.capacity), counting.liveBytes());
}

test "counting allocator budget caps alloc and growth but never shrinks or frees" {
    // FixedBufferAllocator grows its last allocation in place, so every
    // growth refused below is refused by the budget, not by the child.
    var backing: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var counting = gateway.counting_allocator.CountingAllocator{
        .child = fba.allocator(),
        .budget_bytes = std.atomic.Value(u64).init(256),
    };
    const allocator = counting.allocator();

    var block = try allocator.alloc(u8, 200);
    try std.testing.expectEqual(@as(u64, 200), counting.liveBytes());

    // An allocation past the budget fails and its reservation backs out exactly.
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 57));
    try std.testing.expectEqual(@as(u64, 200), counting.liveBytes());
    // Landing exactly on the budget is admitted: only a sum above it is refused.
    const filler = try allocator.alloc(u8, 56);
    allocator.free(filler);
    try std.testing.expectEqual(@as(u64, 200), counting.liveBytes());

    // A growing resize within the budget passes through to the child, and one
    // past it is refused although the child's buffer still has room.
    try std.testing.expect(allocator.resize(block, 240));
    block = block.ptr[0..240];
    try std.testing.expectEqual(@as(u64, 240), counting.liveBytes());
    try std.testing.expect(!allocator.resize(block, 257));
    try std.testing.expectEqual(@as(u64, 240), counting.liveBytes());
    // A growing remap takes the same budget check.
    try std.testing.expect(allocator.remap(block, 257) == null);
    try std.testing.expectEqual(@as(u64, 240), counting.liveBytes());
    const remapped = allocator.remap(block, 256) orelse return error.TestUnexpectedResult;
    block = remapped;
    try std.testing.expectEqual(@as(u64, 256), counting.liveBytes());

    // A shrink at the budget always succeeds, since it only returns headroom.
    try std.testing.expect(allocator.resize(block, 100));
    block = block.ptr[0..100];
    try std.testing.expectEqual(@as(u64, 100), counting.liveBytes());
    allocator.free(block);
    try std.testing.expectEqual(@as(u64, 0), counting.liveBytes());

    // A huge request cannot wrap the budget comparison, which saturates.
    try std.testing.expectError(
        error.OutOfMemory,
        allocator.alloc(u8, std.math.maxInt(usize) - 64),
    );
    try std.testing.expectEqual(@as(u64, 0), counting.liveBytes());
}

test "counting allocator backs out its reservation when the child fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var counting = gateway.counting_allocator.CountingAllocator{
        .child = failing.allocator(),
        .budget_bytes = std.atomic.Value(u64).init(1024),
    };
    const allocator = counting.allocator();

    // The request is well under the budget, so the failure is the child's, and
    // the reservation must back out so later allocations see the full budget.
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 64));
    try std.testing.expectEqual(@as(u64, 0), counting.liveBytes());
}

test "counting allocator budget zero stays uncapped" {
    var counting = gateway.counting_allocator.CountingAllocator{ .child = std.testing.allocator };
    const allocator = counting.allocator();
    try std.testing.expectEqual(@as(u64, 0), counting.budgetBytes());

    const block = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(block);
    try std.testing.expectEqual(@as(u64, 1 << 20), counting.liveBytes());
}

test "counting allocator budget holds under concurrent allocation pressure" {
    const chunk: usize = 32 * 1024;
    const chunk_budget: usize = 32;
    const budget: u64 = @intCast(chunk_budget * chunk);
    const thread_count = 4;
    const attempts_per_thread = 32;

    var counting = gateway.counting_allocator.CountingAllocator{
        .child = std.testing.allocator,
        .budget_bytes = std.atomic.Value(u64).init(budget),
    };

    const Hammer = struct {
        allocator: std.mem.Allocator,
        blocks: [attempts_per_thread][]u8 = undefined,
        admitted: usize = 0,

        fn run(self: *@This()) void {
            for (0..attempts_per_thread) |_| {
                const block = self.allocator.alloc(u8, chunk) catch continue;
                self.blocks[self.admitted] = block;
                self.admitted += 1;
            }
        }
    };

    var hammers: [thread_count]Hammer = undefined;
    for (&hammers) |*hammer|
        hammer.* = .{ .allocator = counting.allocator() };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &hammers) |*thread, *hammer|
        thread.* = try std.Thread.spawn(.{}, Hammer.run, .{hammer});
    for (&threads) |*thread|
        thread.join();

    // The budget is a whole number of equal requests, so a request is refused
    // only once admitted ones fill it, and admitted ones never back out. The
    // `thread_count * attempts_per_thread` attempts therefore fill the room for
    // `chunk_budget` exactly, never past it, however the threads interleave.
    var admitted_total: usize = 0;
    for (&hammers) |*hammer|
        admitted_total += hammer.admitted;
    try std.testing.expectEqual(chunk_budget, admitted_total);
    try std.testing.expectEqual(budget, counting.liveBytes());

    for (&hammers) |*hammer| {
        for (hammer.blocks[0..hammer.admitted]) |block|
            counting.allocator().free(block);
    }
    // Every back-out subtracted exactly its own reservation, so the gauge lands
    // on zero without underflowing and the whole budget is available again.
    try std.testing.expectEqual(@as(u64, 0), counting.liveBytes());
    const proof = try counting.allocator().alloc(u8, chunk);
    counting.allocator().free(proof);
}

test "shard restart at a full memory budget allocates nothing and runs again" {
    const budget = gateway.supervisor_limits.shard_memory.budget_bytes;
    var built = try shard.Shard.init(std.testing.allocator, .{
        .id = 0,
        .engine = .{ .h2_connector_count = 1 },
        .memory_budget_bytes = budget,
    });
    defer built.deinit();
    try built.engine.start();

    // Stands in for replay tasks, which stay counted against the shard's budget
    // across a restart.
    const carryover = try built.memory.allocator().alloc(u8, 4096);
    defer built.memory.allocator().free(carryover);

    // A shard usually restarts because it hit its budget, so the restart
    // gets no headroom at all: any allocation on its path would fail it.
    built.engine.stop();
    const live_before = built.memory.liveBytes();
    built.memory.setBudget(live_before);
    const restarted = built.restart();
    built.memory.setBudget(budget);
    try restarted;

    try std.testing.expectEqual(@as(u64, 1), built.restarts);
}

test "a shard's engine allocates through the shard's counting allocator" {
    var built = try shard.Shard.init(std.testing.allocator, .{
        .id = 3,
        .engine = .{
            .h2_connector_count = 0,
        },
    });
    defer built.deinit();

    // The engine allocated its queues and scratch through the counting
    // allocator when it was built, so the gauge is nonzero before any fetch.
    try std.testing.expect(built.memory.liveBytes() > 0);
}
