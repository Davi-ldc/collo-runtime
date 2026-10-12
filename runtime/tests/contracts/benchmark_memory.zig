//! The sandbox benchmark's memory sampler (`runtime/bench/sandbox/memory.zig`):
//! text fixtures pin how its parsers read units and where they fail, ordinary
//! files in a temporary directory exercise its bounded reads and the
//! descriptor `PeakCounter` keeps, and this process's own `/proc` files
//! exercise the region and task readers against the kernel's real formats.
//! Runs in `microbench-test` and `meta-test`. What the kernel charges to a
//! cgroup, how a `memory.peak` write resets and the `map_files` allocation
//! read, which needs CAP_SYS_ADMIN, are exercised only by a benchmark run
//! against a delegated cgroup.

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

test "benchmark cpu and task parsers read the counters the idle window compares" {
    const cpu = try memory.parseCpuStat(
        "usage_usec 17500\nuser_usec 12000\nsystem_usec 5500\nnr_periods 0\n" ++
            "core_sched.force_idle_usec 0\n",
    );
    try testing.expectEqualDeep(memory.CpuStat{
        .usage_usec = 17500,
        .user_usec = 12000,
        .system_usec = 5500,
    }, cpu);
    try testing.expectError(error.MissingField, memory.parseCpuStat("usage_usec 1\nuser_usec 1\n"));
    const status = try memory.parseTaskStatus(
        "Name:\tvoluntary_ctxt_switches:\nState:\tS (sleeping)\nThreads:\t9\n" ++
            "Cpus_allowed_list:\t0-7\nvoluntary_ctxt_switches:\t300\nnonvoluntary_ctxt_switches:\t4\n",
    );
    try testing.expectEqualDeep(memory.TaskSwitches{ .voluntary = 300, .nonvoluntary = 4 }, status);
    try testing.expectError(error.DuplicateField, memory.parseTaskStatus(
        "voluntary_ctxt_switches:\t1\nnonvoluntary_ctxt_switches:\t1\nvoluntary_ctxt_switches:\t2\n",
    ));
    try testing.expectError(error.InvalidFormat, memory.parseTaskStatus(
        "voluntary_ctxt_switches:\t1 2\nnonvoluntary_ctxt_switches:\t1\n",
    ));
    const switches = memory.ProcessSwitches{ .tasks = 2, .voluntary = 7, .nonvoluntary = 3 };
    try testing.expectEqual(@as(u64, 10), try switches.total());
    const saturated = memory.ProcessSwitches{
        .tasks = 1,
        .voluntary = std.math.maxInt(u64),
        .nonvoluntary = 1,
    };
    try testing.expectError(error.Overflow, saturated.total());
}

test "benchmark cpu reader takes a cgroup directory and this process's tasks all report switches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);
    try testing.expectError(error.FileNotFound, memory.readCpuStat(path));
    try tmp.dir.writeFile(.{ .sub_path = "cpu.stat", .data = "usage_usec 9\nuser_usec 5\nsystem_usec 4\n" });
    try testing.expectEqual(@as(u64, 9), (try memory.readCpuStat(path)).usage_usec);

    const own = try memory.readProcessSwitches(@intCast(std.os.linux.getpid()));
    try testing.expect(own.tasks >= 1);
    try testing.expect(own.tasks <= memory.tasks_max);
    try testing.expectError(error.InvalidProcessId, memory.readProcessSwitches(0));
}

/// The kB counters of one `smaps` mapping, with the fields the reader
/// ignores around the five it keeps.
inline fn smapsFields(
    comptime size: u64,
    comptime rss: u64,
    comptime pss: u64,
    comptime shared_dirty: u64,
    comptime private_dirty: u64,
) []const u8 {
    return std.fmt.comptimePrint(
        "Size:           {d} kB\nKernelPageSize:        4 kB\nMMUPageSize:           4 kB\n" ++
            "Rss:            {d} kB\nPss:            {d} kB\nPss_Dirty:      {d} kB\n" ++
            "Shared_Clean:          0 kB\nShared_Dirty:   {d} kB\nPrivate_Clean:         0 kB\n" ++
            "Private_Dirty:  {d} kB\nReferenced:     {d} kB\nAnonymous:             0 kB\n" ++
            "Swap:                  0 kB\nTHPeligible:    0\nVmFlags: rd wr sh mr mw me ms sd\n",
        .{ size, rss, pss, pss, shared_dirty, private_dirty, rss },
    );
}

const smaps_text =
    "55d0c0a00000-55d0c0a21000 r-xp 00000000 08:20 1234        /usr/bin/sandbox-bench\n" ++
    smapsFields(132, 128, 64, 0, 0) ++
    "7f2a1c000000-7f2a1c039000 rw-s 00000000 00:01 2049        /memfd:collo-shared-metrics (deleted)\n" ++
    smapsFields(228, 40, 20, 40, 0) ++
    "7f2a1d000000-7f2a1d100000 rw-s 00000000 00:01 3001        /memfd:collo-ingress-payload-ring (deleted)\n" ++
    smapsFields(1024, 64, 32, 64, 0) ++
    "7f2a1e000000-7f2a1e100000 r--s 00000000 00:01 3001        /memfd:collo-ingress-payload-ring (deleted)\n" ++
    smapsFields(1024, 16, 8, 0, 16) ++
    "7f2a1f000000-7f2a1f001000 rw-s 00000000 00:01 4000        /memfd:jit-cache (deleted)\n" ++
    "Size: not a number\nRss: either\n" ++
    "7f2a20000000-7f2a20004000 rw-p 00000000 00:00 0 \n" ++
    smapsFields(16, 16, 16, 0, 16) ++
    "7ffd00000000-7ffd00021000 rw-p 00000000 00:00 0           [stack]\n" ++
    smapsFields(132, 12, 12, 0, 12);

fn parseRegionText(text: []const u8, out: []memory.RegionMapping) ![]memory.RegionMapping {
    var reader: std.Io.Reader = .fixed(text);
    return memory.parseRegionMappings(&reader, out);
}

test "benchmark region parser keeps every collo memfd mapping and skips the rest unread" {
    var out: [8]memory.RegionMapping = undefined;
    const mappings = try parseRegionText(smaps_text, &out);
    try testing.expectEqual(@as(usize, 3), mappings.len);
    try testing.expectEqualStrings("collo-shared-metrics", mappings[0].name.slice());
    try testing.expectEqual(@as(u64, 0x7f2a1c000000), mappings[0].start);
    try testing.expectEqual(@as(u64, 0x7f2a1c039000), mappings[0].end);
    try testing.expectEqual(@as(u32, 0), mappings[0].device_major);
    try testing.expectEqual(@as(u32, 1), mappings[0].device_minor);
    try testing.expectEqual(@as(u64, 2049), mappings[0].inode);
    try testing.expectEqual(@as(u64, 228 * 1024), mappings[0].size_bytes);
    try testing.expectEqual(@as(u64, 40 * 1024), mappings[0].rss_bytes);
    try testing.expectEqual(@as(u64, 20 * 1024), mappings[0].pss_bytes);
    try testing.expectEqual(@as(u64, 40 * 1024), mappings[0].shared_dirty_bytes);
    try testing.expectEqual(@as(u64, 0), mappings[0].private_dirty_bytes);
    try testing.expectEqualStrings("collo-ingress-payload-ring", mappings[1].name.slice());
    try testing.expectEqualStrings("collo-ingress-payload-ring", mappings[2].name.slice());
    try testing.expect(mappings[1].sameFile(mappings[2]));
    try testing.expect(!mappings[0].sameFile(mappings[1]));
    try testing.expectEqual(@as(u64, 16 * 1024), mappings[2].private_dirty_bytes);

    // A region the process maps last ends at the end of the file.
    const last = "7f2a1c000000-7f2a1c001000 rw-s 00000000 00:01 7 /memfd:collo-x\n" ++
        smapsFields(4, 4, 4, 0, 4);
    const single = try parseRegionText(last[0 .. last.len - 1], &out);
    try testing.expectEqual(@as(usize, 1), single.len);
    try testing.expectEqualStrings("collo-x", single[0].name.slice());
}

test "benchmark region parser rejects a region whose counters or header it cannot trust" {
    var out: [2]memory.RegionMapping = undefined;
    const header = "7f2a1c000000-7f2a1c039000 rw-s 00000000 00:01 2049 /memfd:collo-shared-metrics (deleted)\n";
    const cases = [_]struct { text: []const u8, expected: anyerror }{
        .{ .text = header ++ "Size: 4 kB\nRss: 4 kB\nShared_Dirty: 4 kB\nPrivate_Dirty: 0 kB\n", .expected = error.MissingField },
        .{ .text = header ++ smapsFields(4, 4, 4, 4, 0) ++ "Rss: 4 kB\n", .expected = error.DuplicateField },
        .{ .text = header ++ "Size: 4 MB\n", .expected = error.InvalidUnit },
        .{ .text = header ++ "Size: 4 kB extra\n", .expected = error.InvalidFormat },
        .{ .text = "7f2a1c000000 rw-s 00000000 00:01 2049 /memfd:collo-a\n", .expected = error.InvalidFormat },
        .{ .text = "7f2a1c00000g-7f2a1c039000 rw-s 00000000 00:01 2049 /memfd:collo-a\n", .expected = error.InvalidValue },
        .{ .text = "7f2a1c039000-7f2a1c000000 rw-s 00000000 00:01 2049 /memfd:collo-a\n", .expected = error.InvalidFormat },
        .{ .text = "7f2a1c000000-7f2a1c039000 rw-s 00000000 00:01\n", .expected = error.InvalidFormat },
        .{ .text = "7f2a1c000000-7f2a1c039000 rw-s 00000000 0001 2049 /memfd:collo-a\n", .expected = error.InvalidFormat },
        .{ .text = "7f2a1c000000-7f2a1c039000 rw-s 00000000 00:01 -1 /memfd:collo-a\n", .expected = error.InvalidValue },
        .{
            .text = "7f2a1c000000-7f2a1c039000 rw-s 00000000 00:01 9 /memfd:collo-" ++ "r" ** 64 ++ "\n",
            .expected = error.RegionNameTooLong,
        },
    };
    for (cases) |case| {
        errdefer std.debug.print("smaps text that did not fail as expected:\n{s}\n", .{case.text});
        try testing.expectError(case.expected, parseRegionText(case.text, &out));
    }
    var one: [1]memory.RegionMapping = undefined;
    try testing.expectError(error.TooManyRegionMappings, parseRegionText(smaps_text, &one));
}

test "benchmark region table sums each counter per name and counts a memfd's allocation once" {
    var out: [8]memory.RegionMapping = undefined;
    const mappings = try parseRegionText(smaps_text, &out);
    const allocated = [_]u64{ 8192, 16384, 16384 };
    var table: memory.RegionTable = .empty;
    try table.tabulate(mappings, &allocated, null);
    try testing.expectEqual(@as(usize, 2), table.items().len);
    const metrics = table.items()[0];
    try testing.expectEqualStrings("collo-shared-metrics", metrics.name.slice());
    try testing.expectEqual(@as(u32, 1), metrics.mappings);
    try testing.expectEqual(@as(u32, 1), metrics.files);
    try testing.expectEqual(@as(u64, 8192), metrics.allocated_bytes);
    const ring = table.items()[1];
    try testing.expectEqualStrings("collo-ingress-payload-ring", ring.name.slice());
    try testing.expectEqual(@as(u32, 2), ring.mappings);
    try testing.expectEqual(@as(u32, 1), ring.files);
    try testing.expectEqual(@as(u64, 2048 * 1024), ring.size_bytes);
    try testing.expectEqual(@as(u64, 80 * 1024), ring.rss_bytes);
    try testing.expectEqual(@as(u64, 40 * 1024), ring.pss_bytes);
    try testing.expectEqual(@as(u64, 64 * 1024), ring.shared_dirty_bytes);
    try testing.expectEqual(@as(u64, 16 * 1024), ring.private_dirty_bytes);
    try testing.expectEqual(@as(u64, 16384), ring.allocated_bytes);

    // The server's share of one worker's regions: only the memfds the
    // worker maps too.
    try table.tabulate(mappings, &allocated, mappings[1..2]);
    try testing.expectEqual(@as(usize, 1), table.items().len);
    try testing.expectEqualStrings("collo-ingress-payload-ring", table.items()[0].name.slice());
    try testing.expectEqual(@as(u32, 2), table.items()[0].mappings);
    try table.tabulate(mappings, &allocated, &.{});
    try testing.expectEqual(@as(usize, 0), table.items().len);
}

test "benchmark region JSON names each region by its memfd name" {
    var out: [8]memory.RegionMapping = undefined;
    const mappings = try parseRegionText(smaps_text, &out);
    var table: memory.RegionTable = .empty;
    try table.tabulate(mappings[0..1], &.{4096}, null);
    const json = try std.fmt.allocPrint(testing.allocator, "{f}", .{std.json.fmt(table.items(), .{})});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "[{\"name\":\"collo-shared-metrics\",\"mappings\":1,\"files\":1,\"size_bytes\":233472," ++
            "\"rss_bytes\":40960,\"pss_bytes\":20480,\"shared_dirty_bytes\":40960," ++
            "\"private_dirty_bytes\":0,\"allocated_bytes\":4096}]",
        json,
    );
}

test "benchmark region reader finds this process's memfd mapped twice and its pages held once" {
    const page = std.heap.pageSize();
    const fd = try std.posix.memfd_create("collo-contract-region", std.os.linux.MFD.CLOEXEC);
    defer std.posix.close(fd);
    try std.posix.ftruncate(fd, 3 * page);
    const writable = try std.posix.mmap(
        null,
        3 * page,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(writable);
    const readable = try std.posix.mmap(null, 3 * page, std.posix.PROT.READ, .{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(readable);
    // Two of the three pages are touched, through the writable mapping only.
    writable[0] = 1;
    writable[page] = 2;

    const out = try testing.allocator.alloc(memory.RegionMapping, memory.region_mappings_max);
    defer testing.allocator.free(out);
    const mappings = try memory.readRegionMappings(@intCast(std.os.linux.getpid()), out);
    var ours: [2]memory.RegionMapping = undefined;
    var count: usize = 0;
    for (mappings) |mapping| {
        if (!std.mem.eql(u8, mapping.name.slice(), "collo-contract-region")) continue;
        if (count == ours.len) return error.TestUnexpectedResult;
        ours[count] = mapping;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(ours[0].sameFile(ours[1]));
    for (ours) |mapping| try testing.expectEqual(@as(u64, 3 * page), mapping.size_bytes);
    // Only the mapping that touched the pages holds them in its page table.
    try testing.expectEqual(@as(u64, 2 * page), ours[0].rss_bytes + ours[1].rss_bytes);
    try testing.expectEqual(@as(u64, 2 * page), ours[0].shared_dirty_bytes + ours[0].private_dirty_bytes +
        ours[1].shared_dirty_bytes + ours[1].private_dirty_bytes);
    // The memfd holds the two pages whichever mapping touched them, which is
    // what `readRegionAllocation` reads as `st_blocks` × 512.
    const stat = try std.posix.fstat(fd);
    try testing.expectEqual(@as(u64, 2 * page), @as(u64, @intCast(stat.blocks)) * 512);
    try testing.expectEqual(ours[0].inode, @as(u64, stat.ino));
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
