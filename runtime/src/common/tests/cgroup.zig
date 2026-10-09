//! The cgroup v2 primitives in `collo_cgroup`, run on fixture strings and on a
//! plain temporary directory standing in for a worker cgroup: parsing
//! `/proc/<pid>/cgroup`, `cpu.max`, `cpu.stat` and `memory.events.local`,
//! rejecting a missing cgroup root, deriving `memory.max`, and writing and
//! validating worker limits by path and by directory fd. The writers open
//! limit files without O_CREAT, so a fixture creates every file it expects
//! written; fixtures leave out `memory.oom.group`, which the writers skip when
//! it is missing. Limits on a real delegated cgroup are covered by the
//! `zygote-integration` lane.

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

test "worker cgroup memory limits are validated against the project limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "1024\n" });
    // The value is `memory.maxBytes(1024)`, the limit times
    // `memory.MAX_RATIO_NUM` over `memory.MAX_RATIO_DEN`, which stays
    // unaligned because it is under one page.
    try tmp.dir.writeFile(.{ .sub_path = "memory.max", .data = "1177\n" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try cgroup.memory.validateWorkerLimits(std.testing.allocator, root, 1024, .require_configured);

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "max\n" });
    try std.testing.expectError(
        error.WorkerCgroupMemoryLimitNotConfigured,
        cgroup.memory.validateWorkerLimits(std.testing.allocator, root, 1024, .require_configured),
    );
    try cgroup.memory.validateWorkerLimits(std.testing.allocator, root, 1024, .allow_unconfigured);

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "2048\n" });
    try std.testing.expectError(
        error.WorkerCgroupMemoryHighMismatch,
        cgroup.memory.validateWorkerLimits(std.testing.allocator, root, 1024, .require_configured),
    );
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

test "worker cgroup memory.events.local reader classifies kernel oom_kill" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "memory.events.local",
        .data = "low 0\nhigh 4\nmax 2\noom 1\noom_kill 1\n",
    });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const events = try cgroup.memory.readEventsLocal(std.testing.allocator, root);
    try std.testing.expectEqual(@as(u64, 1), events.oom_kill);
    try std.testing.expectEqual(@as(u64, 4), events.high);
}

test "worker cgroup base limits configure memory cpu and pids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "max\n" });
    try tmp.dir.writeFile(.{ .sub_path = "memory.max", .data = "max\n" });
    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "max 100000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "pids.max", .data = "max\n" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try cgroup.worker.configureLimits(std.testing.allocator, root, limits);
    try cgroup.worker.validateLimits(std.testing.allocator, root, limits, .require_configured);

    // `Limits` defaults to `cpu.DEFAULT_MAX_CORES`, one core, so the quota
    // written equals the period, `cpu.DEFAULT_PERIOD_US`.
    const cpu_max = try cgroup.cpu.readMax(std.testing.allocator, root, "cpu.max");
    try std.testing.expectEqual(@as(?u64, 100_000), cpu_max.quota_us);
    try std.testing.expectEqual(@as(u64, 100_000), cpu_max.period_us);
}

test "worker cgroup base limits configure memory cpu and pids through a dir fd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "max\n" });
    try tmp.dir.writeFile(.{ .sub_path = "memory.max", .data = "max\n" });
    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "max 100000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "pids.max", .data = "max\n" });

    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try cgroup.worker.configureLimitsAt(tmp.dir.fd, limits);
    try cgroup.worker.validateLimitsAt(
        std.testing.allocator,
        tmp.dir.fd,
        limits,
        .require_configured,
    );

    const cpu_max = try cgroup.cpu.readMaxAt(std.testing.allocator, tmp.dir.fd, "cpu.max");
    try std.testing.expectEqual(@as(?u64, 100_000), cpu_max.quota_us);
    try std.testing.expectEqual(@as(u64, 100_000), cpu_max.period_us);

    try std.testing.expectError(
        error.ZeroMemoryLimit,
        cgroup.worker.configureLimitsAt(tmp.dir.fd, .{ .memory_limit_bytes = 0 }),
    );
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

test "worker cgroup aggregate validation can tolerate non-dedicated test cgroups" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "memory.high", .data = "max\n" });
    try tmp.dir.writeFile(.{ .sub_path = "memory.max", .data = "max\n" });
    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "max 100000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "pids.max", .data = "4915\n" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const limits = cgroup.worker.Limits{ .memory_limit_bytes = 1024 };
    try cgroup.worker.validateLimits(std.testing.allocator, root, limits, .allow_unconfigured);
    try std.testing.expectError(
        error.WorkerCgroupMemoryLimitNotConfigured,
        cgroup.worker.validateLimits(std.testing.allocator, root, limits, .require_configured),
    );
}
