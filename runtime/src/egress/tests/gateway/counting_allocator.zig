//! The budgeted allocator every shard engine and the pooled-upload assembler allocate through
//! (`egress/gateway/counting_allocator.zig`): its live bytes across alloc, resize, remap and free,
//! a budget that refuses growth past it but never a shrink or a free, a reservation that backs out
//! when the child fails, no cap at a budget of zero, and a budget that holds under concurrent
//! allocation. A shard's engine allocating through it is covered in `shard.zig`. Lane:
//! egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");

const CountingAllocator = gateway.counting_allocator.CountingAllocator;

test "the counting allocator tracks live bytes across alloc, resize, and free" {
    var counting = CountingAllocator{ .child = std.testing.allocator };
    const allocator = counting.allocator();

    const first = try allocator.alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 100), counting.liveBytes());
    const second = try allocator.alloc(u8, 28);
    try std.testing.expectEqual(@as(u64, 128), counting.liveBytes());

    allocator.free(first);
    try std.testing.expectEqual(@as(u64, 28), counting.liveBytes());
    // The list grows by resize, remap or a copy, and whichever it takes, the gauge must count
    // exactly the list's new capacity.
    var list = std.array_list.Aligned(u8, null).empty;
    defer {
        list.deinit(allocator);
        allocator.free(second);
    }
    try list.appendNTimes(allocator, 7, 300);
    try std.testing.expectEqual(@as(u64, 28 + list.capacity), counting.liveBytes());
}

test "the counting allocator's budget caps alloc and growth but never a shrink or a free" {
    // FixedBufferAllocator grows its last allocation in place, so every growth refused below is
    // refused by the budget, not by the child.
    var backing: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var counting = CountingAllocator{
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

    // A growing resize within the budget passes through to the child, and one past it is refused
    // although the child's buffer still has room.
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
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize) - 64));
    try std.testing.expectEqual(@as(u64, 0), counting.liveBytes());
}

test "the counting allocator backs out its reservation when the child fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var counting = CountingAllocator{
        .child = failing.allocator(),
        .budget_bytes = std.atomic.Value(u64).init(1024),
    };
    const allocator = counting.allocator();

    // The request is well under the budget, so the failure is the child's, and the reservation
    // must back out so later allocations see the full budget.
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 64));
    try std.testing.expectEqual(@as(u64, 0), counting.liveBytes());
}

test "the counting allocator with a budget of zero stays uncapped" {
    var counting = CountingAllocator{ .child = std.testing.allocator };
    const allocator = counting.allocator();
    try std.testing.expectEqual(@as(u64, 0), counting.budgetBytes());

    const block = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(block);
    try std.testing.expectEqual(@as(u64, 1 << 20), counting.liveBytes());
}

test "the counting allocator's budget holds under concurrent allocation pressure" {
    const chunk: usize = 32 * 1024;
    const chunk_budget: usize = 32;
    const budget: u64 = @intCast(chunk_budget * chunk);
    const thread_count = 4;
    const attempts_per_thread = 32;

    var counting = CountingAllocator{
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

    // The budget is a whole number of equal requests, so a request is refused only once admitted
    // ones fill it, and admitted ones never back out. The `thread_count * attempts_per_thread`
    // attempts therefore fill the room for `chunk_budget` exactly, never past it, however the
    // threads interleave.
    var admitted_total: usize = 0;
    for (&hammers) |*hammer|
        admitted_total += hammer.admitted;
    try std.testing.expectEqual(chunk_budget, admitted_total);
    try std.testing.expectEqual(budget, counting.liveBytes());

    for (&hammers) |*hammer| {
        for (hammer.blocks[0..hammer.admitted]) |block|
            counting.allocator().free(block);
    }
    // Every back-out subtracted exactly its own reservation, so the gauge lands on zero without
    // underflowing and the whole budget is available again.
    try std.testing.expectEqual(@as(u64, 0), counting.liveBytes());
    const proof = try counting.allocator().alloc(u8, chunk);
    counting.allocator().free(proof);
}
