//! The cgroup v2 primitives in `collo_cgroup`, run on fixture strings and on a
//! plain temporary directory standing in for a worker cgroup: parsing
//! `/proc/<pid>/cgroup`, `cpu.max`, `cpu.stat` and `memory.events`,
//! rejecting a missing cgroup root, deriving `memory.max`, and writing and
//! validating a worker leaf's limits, swap included, through its directory
//! fd. The writers open limit files without O_CREAT, so a fixture creates
//! every file it expects written; fixtures leave out `memory.oom.group`,
//! which the writers skip when it is missing, and leave out
//! `memory.swap.max` unless the test is about swap. The figures the server
//! reads off a worker's leaf (`readLeafFigure`) run through a real
//! `WorkerLeaf` in `server/tests/supervisor/worker_table.zig`, and limits on
//! a real delegated cgroup in the `zygote-integration` lane. Lane
//! `common-test`.

const std = @import("std");
const cgroup = @import("collo_cgroup");

test "cgroup unified path parser ignores unrelated controllers" {
    const parsed = try cgroup.path.parseUnified(
        "11:memory:/controller-only\n10:cpuset:/controller-only\n0::/user.slice/collo\n",
    );
    try std.testing.expectEqualStrings("/user.slice/collo", parsed);
}

test "cgroup unified path parser handles real fixture strings" {
    try std.testing.expectEqualStrings("/", try cgroup.path.parseUnified("0::/\n"));
    try std.testing.expectEqualStrings(
        "/user.slice/user-1000.slice/session-2.scope",
        try cgroup.path.parseUnified(
            "9:memory:/controller-only\n0::/user.slice/user-1000.slice/session-2.scope\n",
        ),
    );
    try std.testing.expectError(error.MissingUnifiedCgroupPath, cgroup.path.parseUnified("9:memory:/controller-only\n"));
}

test "cgroup memory pressure detection uses initial event baseline" {
    const baseline = cgroup.memory.Events{ .high = 7 };
    try std.testing.expectEqual(@as(?[]const u8, null), (cgroup.memory.Events{ .high = 7 }).highPressureFieldSince(baseline));
    try std.testing.expectEqualStrings("high", (cgroup.memory.Events{ .high = 8 }).highPressureFieldSince(baseline).?);
}

test "cgroup backend rejects missing real cgroup root with typed error" {
    var path_buffer: [128]u8 = undefined;
    const missing_root = try std.fmt.bufPrint(
        &path_buffer,
        "/tmp/collo-missing-cgroup-root-{d}",
        .{std.c.getpid()},
    );
    std.fs.deleteTreeAbsolute(missing_root) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.testing.expectError(error.RealCgroupRootUnavailable, cgroup.path.validateRoot(missing_root));
}

test "worker cgroup memory limits are validated against the worker's memory limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "1024\n" });
    // The value is `memory.maxBytes(1024)`, the limit times
    // `memory.MAX_RATIO_NUM` over `memory.MAX_RATIO_DEN`, which stays
    // unaligned because it is under one page.
    try tmp.dir.writeFile(.{ .sub_path = "memory.max", .data = "1177\n" });

    try cgroup.memory.validateWorkerLimitsAt(tmp.dir.fd, 1024);

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "max\n" });
    try std.testing.expectError(
        error.WorkerCgroupMemoryLimitNotConfigured,
        cgroup.memory.validateWorkerLimitsAt(tmp.dir.fd, 1024),
    );

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "2048\n" });
    try std.testing.expectError(
        error.WorkerCgroupMemoryHighMismatch,
        cgroup.memory.validateWorkerLimitsAt(tmp.dir.fd, 1024),
    );
}

test "worker cgroup base limits write memory.swap.max 0 where the file exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLimitFixture(tmp.dir);
    // Empty, since the writers do not truncate as a cgroup file needs none,
    // and a plain file would keep the tail of a longer value.
    try tmp.dir.writeFile(.{ .sub_path = "memory.swap.max", .data = "" });

    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try cgroup.worker.configureLimitsAt(tmp.dir.fd, limits);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", try tmp.dir.readFile("memory.swap.max", &buffer));
    try cgroup.worker.validateLimitsAt(tmp.dir.fd, limits);
}

test "worker cgroup base limits skip memory.swap.max on a kernel without swap accounting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No `memory.swap.max`: the kernel has no swap accounting, so no worker
    // memory can go to swap and both the write and the check pass it by.
    try writeLimitFixture(tmp.dir);
    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try cgroup.worker.configureLimitsAt(tmp.dir.fd, limits);
    try cgroup.worker.validateLimitsAt(tmp.dir.fd, limits);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("memory.swap.max", .{}));
}

test "a worker leaf's checks refuse a memory.swap.max other than 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLimitFixture(tmp.dir);
    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try cgroup.worker.configureLimitsAt(tmp.dir.fd, limits);

    for ([_][]const u8{ "max\n", "4096\n" }) |swap_max| {
        try tmp.dir.writeFile(.{ .sub_path = "memory.swap.max", .data = swap_max });
        try std.testing.expectError(error.WorkerCgroupSwapMismatch, cgroup.worker.validateLimitsAt(tmp.dir.fd, limits));
    }
    try tmp.dir.writeFile(.{ .sub_path = "memory.swap.max", .data = "0\n" });
    try cgroup.worker.validateLimitsAt(tmp.dir.fd, limits);
}

/// The limit files a worker leaf has whatever the kernel's options, each
/// holding the value a fresh cgroup holds.
fn writeLimitFixture(dir: std.fs.Dir) !void {
    try dir.writeFile(.{ .sub_path = "memory.high", .data = "max\n" });
    try dir.writeFile(.{ .sub_path = "memory.max", .data = "max\n" });
    try dir.writeFile(.{ .sub_path = "cpu.max", .data = "max 100000\n" });
    try dir.writeFile(.{ .sub_path = "pids.max", .data = "max\n" });
}

test "worker cgroup memory max is page aligned for kernel validation" {
    const memory_limit_bytes: u64 = 1024 * 1024 * 1024;
    const raw_max: u64 = @intCast(
        (@as(u128, memory_limit_bytes) *
            cgroup.memory.MAX_RATIO_NUM) / cgroup.memory.MAX_RATIO_DEN,
    );
    const page_size: u64 = @intCast(std.heap.pageSize());
    try std.testing.expectEqual(
        std.mem.alignBackward(u64, raw_max, page_size),
        cgroup.memory.maxBytes(memory_limit_bytes),
    );
}

test "worker cgroup cpu.max parser accepts bounded and unbounded forms" {
    try std.testing.expectEqualDeep(
        cgroup.cpu.Max{ .quota_us = 300_000, .period_us = 100_000 },
        try cgroup.cpu.parseMax("300000 100000\n"),
    );
    try std.testing.expectEqualDeep(
        cgroup.cpu.Max{ .quota_us = null, .period_us = 100_000 },
        try cgroup.cpu.parseMax("max 100000\n"),
    );
    try std.testing.expectError(error.InvalidCpuMaxFile, cgroup.cpu.parseMax("max\n"));
}

test "worker cgroup cpu.stat parser extracts usage_usec" {
    try std.testing.expectEqual(
        @as(u64, 123_456_789),
        try cgroup.cpu.parseStatUsageUsec(
            "usage_usec 123456789\nuser_usec 100000000\nsystem_usec 23456789\nnr_periods 42\nnr_throttled 3\nthrottled_usec 9000\n",
        ),
    );
    try std.testing.expectError(
        error.InvalidCpuStatFile,
        cgroup.cpu.parseStatUsageUsec("user_usec 1\nsystem_usec 2\n"),
    );
    try std.testing.expectError(
        error.InvalidCpuStatFile,
        cgroup.cpu.parseStatUsageUsec("usage_usec\n"),
    );
}

test "worker cgroup memory.events parser reads every count it knows and passes keys newer kernels add" {
    // Linux 5.17 and later print `oom_group_kill` too.
    const events = try cgroup.memory.parseEvents("low 0\nhigh 4\nmax 2\noom 1\noom_kill 1\noom_group_kill 1\n");
    try std.testing.expectEqualDeep(cgroup.memory.Events{ .low = 0, .high = 4, .max = 2, .oom = 1, .oom_kill = 1 }, events);
    try std.testing.expectError(error.InvalidMemoryEventsFile, cgroup.memory.parseEvents("oom_kill\n"));
}

test "worker cgroup base limits configure memory cpu and pids through a dir fd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLimitFixture(tmp.dir);

    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try cgroup.worker.configureLimitsAt(tmp.dir.fd, limits);
    try cgroup.worker.validateLimitsAt(tmp.dir.fd, limits);

    // `Limits` defaults to `cpu.DEFAULT_MAX_CORES`, one core, so the quota
    // written equals the period, `cpu.DEFAULT_PERIOD_US`.
    const cpu_max = try cgroup.cpu.readMaxAt(tmp.dir.fd);
    try std.testing.expectEqual(@as(?u64, 100_000), cpu_max.quota_us);
    try std.testing.expectEqual(@as(u64, 100_000), cpu_max.period_us);

    try std.testing.expectError(
        error.ZeroMemoryLimit,
        cgroup.worker.configureLimitsAt(tmp.dir.fd, .{ .memory_limit_bytes = 0 }),
    );
}

test "a worker leaf's checks name the first limit that differs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLimitFixture(tmp.dir);
    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try std.testing.expectError(error.WorkerCgroupMemoryLimitNotConfigured, cgroup.worker.validateLimitsAt(tmp.dir.fd, limits));
    try cgroup.worker.configureLimitsAt(tmp.dir.fd, limits);

    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "200000 100000\n" });
    try std.testing.expectError(error.WorkerCgroupCpuQuotaMismatch, cgroup.worker.validateLimitsAt(tmp.dir.fd, limits));
    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "max 100000\n" });
    try std.testing.expectError(error.WorkerCgroupCpuLimitNotConfigured, cgroup.worker.validateLimitsAt(tmp.dir.fd, limits));
    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "100000 100000\n" });

    try tmp.dir.writeFile(.{ .sub_path = "pids.max", .data = "64\n" });
    try std.testing.expectError(error.WorkerCgroupPidsMaxMismatch, cgroup.worker.validateLimitsAt(tmp.dir.fd, limits));
}

test "worker cgroup at-writers reject missing limit files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try std.testing.expectError(
        error.FileNotFound,
        cgroup.worker.configureLimitsAt(tmp.dir.fd, limits),
    );
}
