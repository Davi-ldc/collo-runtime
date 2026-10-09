//! The sandbox benchmark's memory sampler (`runtime/bench/sandbox/memory.zig`):
//! text fixtures pin how its parsers read units and where they fail, and
//! ordinary files in a temporary directory exercise its bounded reads and the
//! descriptor `PeakCounter` keeps. Runs in `microbench-test` and `meta-test`.
//! What the kernel charges to a cgroup and how a `memory.peak` write resets
//! are exercised only by a `bench-memory` run against a delegated cgroup.

const std = @import("std");
const memory = @import("benchmark_memory");
const testing = std.testing;

const process_text =
    "Rss: 46 kB\n" ++
    "Pss: 32 kB\n" ++
    "Shared_Clean: 10 kB\n" ++
    "Shared_Dirty: 11 kB\n" ++
    "Private_Clean: 12 kB\n" ++
    "Private_Dirty: 13 kB\n" ++
    "Swap: 3 kB\n";
const stat_text =
    "anon 4096\nfile 8192\nkernel 16384\nshmem 2048\n" ++
    "pagetables 4096\nkernel_stack 4096\nslab 4096\n";
const events_text = "low 0\nhigh 1\nmax 2\noom 3\noom_kill 4\n";

const expected_process = memory.ProcessMemory{
    .rss_bytes = 46 * 1024,
    .pss_bytes = 32 * 1024,
    .shared_clean_bytes = 10 * 1024,
    .shared_dirty_bytes = 11 * 1024,
    .private_clean_bytes = 12 * 1024,
    .private_dirty_bytes = 13 * 1024,
    .swap_bytes = 3 * 1024,
};
const expected_stat = memory.MemoryStat{
    .anon_bytes = 4096,
    .file_bytes = 8192,
    .kernel_bytes = 16384,
    .shmem_bytes = 2048,
    .pagetables_bytes = 4096,
    .kernel_stack_bytes = 4096,
    .slab_bytes = 4096,
};
const expected_events = memory.MemoryEvents{
    .low = 0,
    .high = 1,
    .max = 2,
    .oom = 3,
    .oom_kill = 4,
};

test "benchmark memory rollup converts exact keys to bytes and sums both page classes" {
    const parsed = try memory.parseProcessRollup(
        "00400000-00800000 ---p 00000000 00:00 0 [rollup]\n" ++
            "Pss_Anon: 999 kB\nShared_Hugetlb: 0 kB\n" ++ process_text ++
            "SwapPss: 2 kB\nUnknown_Future_Field: 7 kB\n",
    );
    try testing.expectEqualDeep(expected_process, parsed);
    try testing.expectEqual(@as(u64, 21 * 1024), try parsed.sharedBytes());
    try testing.expectEqual(@as(u64, 25 * 1024), try parsed.ussBytes());
    try testing.expectEqualDeep(expected_stat, try memory.parseMemoryStat(stat_text));
    try testing.expectEqualDeep(expected_events, try memory.parseMemoryEvents(
        "oom_group_kill 9\n" ++ events_text,
    ));
}

test "benchmark memory parsers require every named field" {
    var buffer: [1024]u8 = undefined;
    for (0..7) |index| {
        try testing.expectError(error.MissingField, memory.parseProcessRollup(
            try withoutLine(process_text, index, &buffer),
        ));
        try testing.expectError(error.MissingField, memory.parseMemoryStat(
            try withoutLine(stat_text, index, &buffer),
        ));
    }
    for (0..5) |index| {
        try testing.expectError(error.MissingField, memory.parseMemoryEvents(
            try withoutLine(events_text, index, &buffer),
        ));
    }
    try testing.expectError(error.MissingField, memory.parseProcessRollup("Pss_Anon: 3 kB\n"));
    try testing.expectError(error.MissingField, memory.parseMemoryStat("kernel_extra 3\n"));
}

test "benchmark memory parsers reject duplicate known keys" {
    try testing.expectError(error.DuplicateField, memory.parseProcessRollup(
        process_text ++ "Pss: 32 kB\n",
    ));
    try testing.expectError(error.DuplicateField, memory.parseMemoryStat(stat_text ++ "anon 1\n"));
    try testing.expectError(error.DuplicateField, memory.parseMemoryEvents(
        events_text ++ "low 0\n",
    ));
}

test "benchmark memory rollup rejects malformed values units and overflowing bytes" {
    const cases = [_]struct { text: []const u8, expected: anyerror }{
        .{ .text = "Rss:\n", .expected = error.InvalidFormat },
        .{ .text = "Rss: 1\n", .expected = error.InvalidUnit },
        .{ .text = "Rss: 1 MB\n", .expected = error.InvalidUnit },
        .{ .text = "Rss: 1 KiB\n", .expected = error.InvalidUnit },
        .{ .text = "Rss: -1 kB\n", .expected = error.InvalidValue },
        .{ .text = "Rss: +1 kB\n", .expected = error.InvalidValue },
        .{ .text = "Rss: 1_000 kB\n", .expected = error.InvalidValue },
        .{ .text = "Rss: 1.5 kB\n", .expected = error.InvalidValue },
        .{ .text = "Rss: 1 kB extra\n", .expected = error.InvalidFormat },
        .{ .text = "Rss: 18446744073709551616 kB\n", .expected = error.Overflow },
        .{ .text = "Rss: 18014398509481984 kB\n", .expected = error.Overflow },
    };
    for (cases) |case|
        try testing.expectError(case.expected, memory.parseProcessRollup(case.text));
    try testing.expectError(error.InvalidFormat, memory.parseMemoryStat("anon 1 kB\n"));
    try testing.expectError(error.InvalidFormat, memory.parseMemoryEvents("oom\n"));
    try testing.expectError(error.InvalidValue, memory.parseMemoryStat("anon -1\n"));
    try testing.expectError(error.Overflow, memory.parseMemoryEvents("oom 18446744073709551616\n"));
}

test "benchmark memory parsers accept reordering whitespace and the full counter range" {
    try testing.expectEqualDeep(expected_process, try memory.parseProcessRollup(
        "\tSwap:\t3\tkB\r\nPrivate_Dirty: 13 kB\nPrivate_Clean: 12 kB\n" ++
            "Shared_Dirty: 11 kB\nShared_Clean: 10 kB\nPss: 32 kB\nRss: 46 kB",
    ));
    const events = try memory.parseMemoryEvents(
        "oom_kill 18446744073709551615\nmax 0\nlow 0\noom 0\nhigh 0",
    );
    try testing.expectEqual(std.math.maxInt(u64), events.oom_kill);
    try testing.expectEqual(@as(u64, 0), events.high);
}

test "benchmark memory parsers enforce the input cap without truncating a valid prefix" {
    var buffer: [memory.snapshot_file_bytes_max + 1]u8 = @splat(' ');
    @memcpy(buffer[0..process_text.len], process_text);
    try testing.expectEqualDeep(expected_process, try memory.parseProcessRollup(
        buffer[0..memory.snapshot_file_bytes_max],
    ));
    try testing.expectError(error.InputTooLarge, memory.parseProcessRollup(&buffer));
    try testing.expectError(error.InputTooLarge, memory.parseMemoryStat(&buffer));
    try testing.expectError(error.InputTooLarge, memory.parseMemoryEvents(&buffer));
}

test "benchmark memory group reader uses hierarchical byte counters and propagates absence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeGroupFixture(tmp.dir);
    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);
    const expected = memory.GroupMemory{
        .current_bytes = 28672,
        .swap_bytes = 0,
        .stat = expected_stat,
        .events = expected_events,
    };
    try testing.expectEqualDeep(expected, try memory.readGroup(path));
    try tmp.dir.deleteFile("memory.swap.current");
    try testing.expectError(error.FileNotFound, memory.readGroup(path));
    try tmp.dir.writeFile(.{ .sub_path = "memory.swap.current", .data = "0\n" });
    try tmp.dir.writeFile(.{ .sub_path = "memory.current", .data = "max\n" });
    try testing.expectError(error.InvalidValue, memory.readGroup(path));
    try tmp.dir.writeFile(.{ .sub_path = "memory.current", .data = "12 kB\n" });
    try testing.expectError(error.InvalidFormat, memory.readGroup(path));
}

test "benchmark memory group reader rejects oversized files after a valid prefix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeGroupFixture(tmp.dir);
    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);
    var buffer: [memory.snapshot_file_bytes_max + 1]u8 = @splat(' ');
    @memcpy(buffer[0..stat_text.len], stat_text);
    try tmp.dir.writeFile(.{ .sub_path = "memory.stat", .data = &buffer });
    try testing.expectError(error.InputTooLarge, memory.readGroup(path));
    try tmp.dir.writeFile(.{ .sub_path = "memory.stat", .data = stat_text });
    var scalar: [65]u8 = @splat(' ');
    scalar[0] = '1';
    try tmp.dir.writeFile(.{ .sub_path = "memory.current", .data = &scalar });
    try testing.expectError(error.InputTooLarge, memory.readGroup(path));
}

test "benchmark memory peak reader retains one descriptor across reset and repeated reads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);
    try testing.expectError(error.FileNotFound, memory.PeakCounter.init(path));
    try tmp.dir.writeFile(.{ .sub_path = "memory.peak", .data = "7\n" });
    var peak = try memory.PeakCounter.init(path);
    defer peak.deinit();
    try testing.expectEqual(@as(u64, 7), try peak.read());
    try testing.expectEqual(@as(u64, 7), try peak.read());
    try tmp.dir.rename("memory.peak", "original.peak");
    try tmp.dir.writeFile(.{ .sub_path = "memory.peak", .data = "9000\n" });
    try testing.expectEqual(@as(u64, 7), try peak.read());
    // On an ordinary file the reset overwrites the first byte, so the retained
    // descriptor reads 0. A real `memory.peak` would report current usage, and
    // only through that descriptor.
    try peak.reset();
    try testing.expectEqual(@as(u64, 0), try peak.read());
    var replacement = try memory.PeakCounter.init(path);
    defer replacement.deinit();
    try testing.expectEqual(@as(u64, 9000), try replacement.read());
    try tmp.dir.writeFile(.{ .sub_path = "memory.peak", .data = "9000 kB\n" });
    try testing.expectError(error.InvalidFormat, replacement.read());
    const oversized: [65]u8 = @splat('1');
    try tmp.dir.writeFile(.{ .sub_path = "memory.peak", .data = &oversized });
    try testing.expectError(error.InputTooLarge, replacement.read());
}

test "benchmark memory arithmetic preserves signed deltas and distinguishes amortization" {
    try testing.expectEqual(@as(i64, 40), try memory.signedDelta(200, 160));
    try testing.expectEqual(@as(i64, 25), try memory.amortizedDelta(200, 100, 4));
    try testing.expectEqual(@as(i64, -3), try memory.amortizedDelta(0, 10, 3));
    try testing.expectEqual(@as(i64, 0), try memory.signedDelta(100, 100));
    const maximum = std.math.maxInt(u64);
    const signed_maximum: u64 = std.math.maxInt(i64);
    try testing.expectEqual(@as(i64, 1), try memory.signedDelta(maximum, maximum - 1));
    try testing.expectEqual(std.math.minInt(i64), try memory.signedDelta(0, signed_maximum + 1));
    try testing.expectError(error.Overflow, memory.signedDelta(signed_maximum + 1, 0));
    try testing.expectError(error.Overflow, memory.signedDelta(0, signed_maximum + 2));
    try testing.expectEqual(std.math.maxInt(i64), try memory.amortizedDelta(maximum, 0, 2));
    try testing.expectEqual(@as(i64, 0), try memory.amortizedDelta(1, 0, maximum));
    try testing.expectError(error.Overflow, memory.amortizedDelta(maximum, 0, 1));
    try testing.expectError(error.InvalidCount, memory.amortizedDelta(200, 100, 0));
    var process = expected_process;
    process.shared_clean_bytes = maximum;
    process.private_clean_bytes = maximum;
    try testing.expectError(error.Overflow, process.sharedBytes());
    try testing.expectError(error.Overflow, process.ussBytes());
    try testing.expectError(error.InvalidProcessId, memory.readProcess(0));
}

fn withoutLine(text: []const u8, excluded: usize, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index != excluded) try writer.print("{s}\n", .{line});
    }
    return writer.buffered();
}

fn writeGroupFixture(dir: std.fs.Dir) !void {
    try dir.writeFile(.{ .sub_path = "memory.current", .data = "28672\n" });
    try dir.writeFile(.{ .sub_path = "memory.swap.current", .data = "0\n" });
    try dir.writeFile(.{ .sub_path = "memory.stat", .data = stat_text });
    try dir.writeFile(.{ .sub_path = "memory.events", .data = events_text });
}
