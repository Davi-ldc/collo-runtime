//! cgroup v2 primitives for a worker's cgroup: writing and checking its
//! memory, CPU and pids limits, reading its events and CPU usage, and finding
//! a process's cgroup. Most operations take the directory either by path or
//! as an fd (the `At` forms); the `At` writers never allocate. The worker's
//! memory limit is its `memory.high`, and `memory.max` and the threshold at
//! which the engine requests a collection are derived from it here.
//! Stateless, so any thread may call it.

const std = @import("std");

pub const memory = struct {
    /// The engine's collection trigger as a fraction of the memory limit
    /// (`gcHeapLimitBytes`): the worker sets it as the engine's
    /// `gcMaxHeapSize` override (`zygote/child_boot.zig`), and the engine
    /// requests a collection once the bytes allocated since the last one pass
    /// it (`runtime/patches/webkit/0002-gc-max-heap-size-override.patch`). It
    /// caps no heap and fails no allocation.
    pub const GC_HEAP_RATIO_NUM: u64 = 9;
    pub const GC_HEAP_RATIO_DEN: u64 = 10;
    /// `memory.max`, where the kernel OOM-kills the cgroup, as a fraction of
    /// the memory limit (`maxBytes`).
    pub const MAX_RATIO_NUM: u64 = 115;
    pub const MAX_RATIO_DEN: u64 = 100;

    pub const Events = struct {
        low: u64 = 0,
        high: u64 = 0,
        max: u64 = 0,
        oom: u64 = 0,
        oom_kill: u64 = 0,

        pub fn highPressureField(self: Events) ?[]const u8 {
            if (self.high != 0)
                return "high";
            return null;
        }

        pub fn highPressureFieldSince(self: Events, baseline: Events) ?[]const u8 {
            if (self.high > baseline.high)
                return "high";
            return null;
        }
    };

    pub const LimitValidationMode = enum {
        require_configured,
        allow_unconfigured,
    };

    pub fn gcHeapLimitBytes(memory_limit_bytes: u64) u64 {
        return @intCast((@as(u128, memory_limit_bytes) * GC_HEAP_RATIO_NUM) / GC_HEAP_RATIO_DEN);
    }

    /// Rounded down to a whole page, as the kernel stores `memory.max`, so
    /// reading the file back yields exactly this value. A result below one
    /// page is returned unrounded.
    pub fn maxBytes(memory_limit_bytes: u64) u64 {
        const raw: u64 = @intCast(
            (@as(u128, memory_limit_bytes) * MAX_RATIO_NUM) / MAX_RATIO_DEN,
        );
        const page_size: u64 = @intCast(std.heap.pageSize());
        if (raw < page_size)
            return raw;
        return std.mem.alignBackward(u64, raw, page_size);
    }

    pub fn validateLimitBytes(memory_limit_bytes: u64) !void {
        if (memory_limit_bytes == 0)
            return error.ZeroMemoryLimit;
        _ = gcHeapLimitBytes(memory_limit_bytes);
        _ = maxBytes(memory_limit_bytes);
    }

    pub fn readEvents(fd: std.posix.fd_t) !Events {
        var buffer: [256]u8 = undefined;
        const read_len = try std.posix.pread(fd, &buffer, 0);
        return parseEvents(buffer[0..read_len]);
    }

    /// The events of this cgroup alone (`memory.events.local`), read by path.
    /// A worker's cgroup outlives the worker until the host removes it, so
    /// this still answers after the worker was killed. With
    /// `memory.oom.group` set, `oom_kill` counts every task one OOM kill
    /// took, so a single group kill reads as at least 1.
    pub fn readEventsLocal(allocator: std.mem.Allocator, cgroup_dir: []const u8) !Events {
        const contents = try readLimitFileAlloc(allocator, cgroup_dir, "memory.events.local", 256);
        defer allocator.free(contents);
        return parseEvents(contents);
    }

    /// Writes `memory.max`, `memory.high` and `memory.oom.group=1` under
    /// `cgroup_dir`. With `memory.oom.group` set, a kernel OOM in the cgroup
    /// kills every task in it together instead of choosing one. The file has
    /// existed next to `memory.max` since Linux 4.19, so `FileNotFound` is
    /// tolerated only for test fixtures that are plain directories.
    pub fn configureWorkerLimits(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        memory_limit_bytes: u64,
    ) !void {
        try writeScalarLimitFile(allocator, cgroup_dir, "memory.max", maxBytes(memory_limit_bytes));
        try writeScalarLimitFile(allocator, cgroup_dir, "memory.high", memory_limit_bytes);
        writeScalarLimitFile(allocator, cgroup_dir, "memory.oom.group", 1) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// `configureWorkerLimits` for a directory fd, without allocating.
    pub fn configureWorkerLimitsAt(
        cgroup_dir_fd: std.posix.fd_t,
        memory_limit_bytes: u64,
    ) !void {
        try writeScalarLimitFileAt(cgroup_dir_fd, "memory.max", maxBytes(memory_limit_bytes));
        try writeScalarLimitFileAt(cgroup_dir_fd, "memory.high", memory_limit_bytes);
        writeScalarLimitFileAt(cgroup_dir_fd, "memory.oom.group", 1) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    pub fn validateWorkerLimits(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        memory_limit_bytes: u64,
        mode: LimitValidationMode,
    ) !void {
        const high = try readScalarLimitFile(allocator, cgroup_dir, "memory.high");
        const max = try readScalarLimitFile(allocator, cgroup_dir, "memory.max");
        if (high == null or max == null) {
            if (mode == .allow_unconfigured)
                return;
            return error.WorkerCgroupMemoryLimitNotConfigured;
        }
        if (high.? != memory_limit_bytes)
            return error.WorkerCgroupMemoryHighMismatch;
        if (max.? != maxBytes(memory_limit_bytes))
            return error.WorkerCgroupMemoryMaxMismatch;
    }

    pub fn validateWorkerLimitsAt(
        allocator: std.mem.Allocator,
        cgroup_dir_fd: std.posix.fd_t,
        memory_limit_bytes: u64,
        mode: LimitValidationMode,
    ) !void {
        const high = try readScalarLimitFileAt(allocator, cgroup_dir_fd, "memory.high");
        const max = try readScalarLimitFileAt(allocator, cgroup_dir_fd, "memory.max");
        if (high == null or max == null) {
            if (mode == .allow_unconfigured)
                return;
            return error.WorkerCgroupMemoryLimitNotConfigured;
        }
        if (high.? != memory_limit_bytes)
            return error.WorkerCgroupMemoryHighMismatch;
        if (max.? != maxBytes(memory_limit_bytes))
            return error.WorkerCgroupMemoryMaxMismatch;
    }

    fn parseEvents(contents: []const u8) !Events {
        var events = Events{};
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0)
                continue;

            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            const key = parts.next() orelse return error.InvalidMemoryEventsFile;
            const value_text = parts.next() orelse return error.InvalidMemoryEventsFile;
            const value = try std.fmt.parseUnsigned(u64, value_text, 10);

            if (std.mem.eql(u8, key, "low"))
                events.low = value
            else if (std.mem.eql(u8, key, "high"))
                events.high = value
            else if (std.mem.eql(u8, key, "max"))
                events.max = value
            else if (std.mem.eql(u8, key, "oom"))
                events.oom = value
            else if (std.mem.eql(u8, key, "oom_kill"))
                events.oom_kill = value;
        }

        return events;
    }
};

pub const cpu = struct {
    /// CPU quota, in cores, of a leaf configured or checked without one
    /// (`worker.Limits`). It equals `cpu_max_cores` in
    /// `common/limits/worker.zig`, the quota every launch gives its worker,
    /// which `runtime/tests/contracts/limits.zig` checks.
    pub const DEFAULT_MAX_CORES: u32 = 1;
    /// The `cpu.max` period; the quota is the cores times this.
    pub const DEFAULT_PERIOD_US: u64 = 100_000;

    pub const Max = struct {
        quota_us: ?u64,
        period_us: u64,
    };

    pub fn quotaForCores(max_cores: u32, period_us: u64) u64 {
        return @as(u64, max_cores) * period_us;
    }

    pub fn validateConfig(max_cores: u32, period_us: u64) !void {
        if (max_cores == 0)
            return error.ZeroCpuMaxCores;
        if (period_us == 0)
            return error.ZeroCpuPeriod;
        if (period_us > std.math.maxInt(u64) / @as(u64, max_cores))
            return error.CpuQuotaOverflow;
    }

    pub fn configureWorkerLimit(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        max_cores: u32,
        period_us: u64,
    ) !void {
        try validateConfig(max_cores, period_us);
        var buffer: [64]u8 = undefined;
        const bytes = std.fmt.bufPrint(&buffer, "{d} {d}", .{ quotaForCores(max_cores, period_us), period_us }) catch unreachable;
        try writeTextLimitFile(allocator, cgroup_dir, "cpu.max", bytes);
    }

    pub fn configureWorkerLimitAt(
        cgroup_dir_fd: std.posix.fd_t,
        max_cores: u32,
        period_us: u64,
    ) !void {
        try validateConfig(max_cores, period_us);
        var buffer: [64]u8 = undefined;
        const bytes = std.fmt.bufPrint(&buffer, "{d} {d}", .{ quotaForCores(max_cores, period_us), period_us }) catch unreachable;
        try writeTextLimitFileAt(cgroup_dir_fd, "cpu.max", bytes);
    }

    pub fn validateWorkerLimit(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        max_cores: u32,
        period_us: u64,
        mode: memory.LimitValidationMode,
    ) !void {
        try validateConfig(max_cores, period_us);
        const configured = try readMax(allocator, cgroup_dir, "cpu.max");
        if (configured.quota_us == null) {
            if (mode == .allow_unconfigured)
                return;
            return error.WorkerCgroupCpuLimitNotConfigured;
        }
        if (configured.quota_us.? != quotaForCores(max_cores, period_us))
            return error.WorkerCgroupCpuQuotaMismatch;
        if (configured.period_us != period_us)
            return error.WorkerCgroupCpuPeriodMismatch;
    }

    pub fn readMax(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        file_name: []const u8,
    ) !Max {
        const contents = try readLimitFileAlloc(allocator, cgroup_dir, file_name, 64);
        defer allocator.free(contents);
        return parseMax(contents);
    }

    pub fn readMaxAt(
        allocator: std.mem.Allocator,
        cgroup_dir_fd: std.posix.fd_t,
        file_name: []const u8,
    ) !Max {
        const contents = try readLimitFileAtAlloc(allocator, cgroup_dir_fd, file_name, 64);
        defer allocator.free(contents);
        return parseMax(contents);
    }

    pub fn validateWorkerLimitAt(
        allocator: std.mem.Allocator,
        cgroup_dir_fd: std.posix.fd_t,
        max_cores: u32,
        period_us: u64,
        mode: memory.LimitValidationMode,
    ) !void {
        try validateConfig(max_cores, period_us);
        const configured = try readMaxAt(allocator, cgroup_dir_fd, "cpu.max");
        if (configured.quota_us == null) {
            if (mode == .allow_unconfigured)
                return;
            return error.WorkerCgroupCpuLimitNotConfigured;
        }
        if (configured.quota_us.? != quotaForCores(max_cores, period_us))
            return error.WorkerCgroupCpuQuotaMismatch;
        if (configured.period_us != period_us)
            return error.WorkerCgroupCpuPeriodMismatch;
    }

    pub fn parseMax(contents: []const u8) !Max {
        var parts = std.mem.tokenizeAny(u8, contents, &std.ascii.whitespace);
        const quota_text = parts.next() orelse return error.InvalidCpuMaxFile;
        const period_text = parts.next() orelse return error.InvalidCpuMaxFile;
        if (parts.next() != null)
            return error.InvalidCpuMaxFile;

        const quota_us = if (std.mem.eql(u8, quota_text, "max"))
            null
        else
            try std.fmt.parseUnsigned(u64, quota_text, 10);
        const period_us = try std.fmt.parseUnsigned(u64, period_text, 10);
        if (period_us == 0)
            return error.InvalidCpuMaxFile;
        return .{ .quota_us = quota_us, .period_us = period_us };
    }

    /// CPU time of every thread in the cgroup (`usage_usec` in `cpu.stat`).
    /// The kernel keeps it, so the worker cannot forge it, and it can still
    /// be read after the worker is killed.
    pub fn readStatUsageUsec(allocator: std.mem.Allocator, cgroup_dir: []const u8) !u64 {
        const contents = try readLimitFileAlloc(allocator, cgroup_dir, "cpu.stat", 1024);
        defer allocator.free(contents);
        return parseStatUsageUsec(contents);
    }

    pub fn parseStatUsageUsec(contents: []const u8) !u64 {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            const key = parts.next() orelse continue;
            if (!std.mem.eql(u8, key, "usage_usec"))
                continue;
            const value_text = parts.next() orelse return error.InvalidCpuStatFile;
            return std.fmt.parseUnsigned(u64, value_text, 10);
        }
        return error.InvalidCpuStatFile;
    }
};

pub const pids = struct {
    /// `pids.max` of a worker cgroup. The kernel counts every task, threads
    /// included, so it also bounds the worker's threads.
    pub const DEFAULT_MAX: u64 = 128;

    pub fn validateLimit(max_pids: u64) !void {
        if (max_pids == 0)
            return error.ZeroPidsMax;
    }

    pub fn configureWorkerLimit(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        max_pids: u64,
    ) !void {
        try validateLimit(max_pids);
        try writeScalarLimitFile(allocator, cgroup_dir, "pids.max", max_pids);
    }

    pub fn configureWorkerLimitAt(cgroup_dir_fd: std.posix.fd_t, max_pids: u64) !void {
        try validateLimit(max_pids);
        try writeScalarLimitFileAt(cgroup_dir_fd, "pids.max", max_pids);
    }

    pub fn validateWorkerLimit(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        max_pids: u64,
        mode: memory.LimitValidationMode,
    ) !void {
        try validateLimit(max_pids);
        const configured = try readScalarLimitFile(allocator, cgroup_dir, "pids.max");
        if (configured == null) {
            if (mode == .allow_unconfigured)
                return;
            return error.WorkerCgroupPidsLimitNotConfigured;
        }
        if (configured.? != max_pids)
            return error.WorkerCgroupPidsMaxMismatch;
    }

    pub fn validateWorkerLimitAt(
        allocator: std.mem.Allocator,
        cgroup_dir_fd: std.posix.fd_t,
        max_pids: u64,
        mode: memory.LimitValidationMode,
    ) !void {
        try validateLimit(max_pids);
        const configured = try readScalarLimitFileAt(allocator, cgroup_dir_fd, "pids.max");
        if (configured == null) {
            if (mode == .allow_unconfigured)
                return;
            return error.WorkerCgroupPidsLimitNotConfigured;
        }
        if (configured.? != max_pids)
            return error.WorkerCgroupPidsMaxMismatch;
    }
};

pub const path = struct {
    pub const CGROUP2_MOUNT_PATH = "/sys/fs/cgroup";

    pub fn currentUnified(allocator: std.mem.Allocator) ![]u8 {
        return unifiedForPid(allocator, @intCast(std.c.getpid()));
    }

    pub fn unifiedForPid(allocator: std.mem.Allocator, pid: u32) ![]u8 {
        const proc_path = try std.fmt.allocPrint(allocator, "/proc/{d}/cgroup", .{pid});
        defer allocator.free(proc_path);

        var file_handle = try std.fs.openFileAbsolute(proc_path, .{});
        defer file_handle.close();

        const contents = try file_handle.readToEndAlloc(allocator, 4096);
        defer allocator.free(contents);

        const relative = try parseUnified(contents);
        return allocator.dupe(u8, relative);
    }

    /// The cgroup v2 path in `/proc/<pid>/cgroup` contents, from its `0::`
    /// line; the result borrows `contents`.
    pub fn parseUnified(contents: []const u8) ![]const u8 {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0)
                continue;
            const first = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const second_rel = std.mem.indexOfScalar(u8, line[first + 1 ..], ':') orelse continue;
            const second = first + 1 + second_rel;
            if (!std.mem.eql(u8, line[0..first], "0"))
                continue;
            if (!std.mem.eql(u8, line[first + 1 .. second], ""))
                continue;
            return line[second + 1 ..];
        }

        return error.MissingUnifiedCgroupPath;
    }

    pub fn workerDirForPid(
        allocator: std.mem.Allocator,
        pid: u32,
    ) ![]u8 {
        try validateRoot(CGROUP2_MOUNT_PATH);
        const current_relative = try unifiedForPid(allocator, pid);
        defer allocator.free(current_relative);

        return join(allocator, CGROUP2_MOUNT_PATH, current_relative, null);
    }

    pub fn file(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        file_name: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cgroup_dir, file_name });
    }

    pub fn openDir(cgroup_dir: []const u8) !std.posix.fd_t {
        return std.posix.open(cgroup_dir, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .DIRECTORY = true,
            .NOFOLLOW = true,
        }, 0);
    }

    /// Fails with `error.RealCgroupRootUnavailable` when `root` is missing or
    /// not a directory, and with `error.MissingCgroupV2Mount` when it lacks
    /// `cgroup.controllers`, as a cgroup v1 or non-cgroup mount does.
    pub fn validateRoot(root: []const u8) !void {
        var dir = std.fs.openDirAbsolute(root, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.RealCgroupRootUnavailable,
            else => return err,
        };
        defer dir.close();

        var controllers_buffer: [4096]u8 = undefined;
        const controllers_path = std.fmt.bufPrint(&controllers_buffer, "{s}/cgroup.controllers", .{root}) catch
            return error.NameTooLong;
        std.fs.accessAbsolute(controllers_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.MissingCgroupV2Mount,
            else => return err,
        };
    }

    fn join(
        allocator: std.mem.Allocator,
        root: []const u8,
        relative_path: []const u8,
        child: ?[]const u8,
    ) ![]u8 {
        const trimmed = std.mem.trimLeft(u8, relative_path, "/");
        return if (child) |suffix|
            if (trimmed.len == 0)
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, suffix })
            else
                std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ root, trimmed, suffix })
        else if (trimmed.len == 0)
            allocator.dupe(u8, root)
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, trimmed });
    }
};

pub const worker = struct {
    pub const Limits = struct {
        memory_limit_bytes: u64,
        cpu_max_cores: u32 = cpu.DEFAULT_MAX_CORES,
        cpu_period_us: u64 = cpu.DEFAULT_PERIOD_US,
        pids_max: u64 = pids.DEFAULT_MAX,
    };

    /// Fails unless every file the worker's limits and events use exists. A
    /// limit file exists only when its controller is enabled in the parent's
    /// `cgroup.subtree_control`, so this catches a missing controller.
    pub fn ensureSurface(allocator: std.mem.Allocator, cgroup_dir: []const u8) !void {
        const cgroup_procs_path = try path.file(allocator, cgroup_dir, "cgroup.procs");
        defer allocator.free(cgroup_procs_path);
        try std.fs.accessAbsolute(cgroup_procs_path, .{});

        const memory_high_path = try path.file(allocator, cgroup_dir, "memory.high");
        defer allocator.free(memory_high_path);
        try std.fs.accessAbsolute(memory_high_path, .{});

        const memory_max_path = try path.file(allocator, cgroup_dir, "memory.max");
        defer allocator.free(memory_max_path);
        try std.fs.accessAbsolute(memory_max_path, .{});

        const memory_events_path = try path.file(allocator, cgroup_dir, "memory.events.local");
        defer allocator.free(memory_events_path);
        try std.fs.accessAbsolute(memory_events_path, .{});

        const cpu_max_path = try path.file(allocator, cgroup_dir, "cpu.max");
        defer allocator.free(cpu_max_path);
        try std.fs.accessAbsolute(cpu_max_path, .{});

        const pids_max_path = try path.file(allocator, cgroup_dir, "pids.max");
        defer allocator.free(pids_max_path);
        try std.fs.accessAbsolute(pids_max_path, .{});
    }

    pub fn ensureSurfaceAt(cgroup_dir_fd: std.posix.fd_t) !void {
        inline for (surface_file_names) |file_name| {
            const fd = try openReadOnlyAt(cgroup_dir_fd, file_name);
            std.posix.close(fd);
        }
    }

    pub fn validateLimitsConfig(limits: Limits) !void {
        try memory.validateLimitBytes(limits.memory_limit_bytes);
        try cpu.validateConfig(limits.cpu_max_cores, limits.cpu_period_us);
        try pids.validateLimit(limits.pids_max);
    }

    pub fn configureLimits(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        limits: Limits,
    ) !void {
        try validateLimitsConfig(limits);
        try memory.configureWorkerLimits(allocator, cgroup_dir, limits.memory_limit_bytes);
        try cpu.configureWorkerLimit(allocator, cgroup_dir, limits.cpu_max_cores, limits.cpu_period_us);
        try pids.configureWorkerLimit(allocator, cgroup_dir, limits.pids_max);
    }

    pub fn validateLimits(
        allocator: std.mem.Allocator,
        cgroup_dir: []const u8,
        limits: Limits,
        mode: memory.LimitValidationMode,
    ) !void {
        try validateLimitsConfig(limits);
        if (mode == .allow_unconfigured)
            return;
        try memory.validateWorkerLimits(allocator, cgroup_dir, limits.memory_limit_bytes, mode);
        try cpu.validateWorkerLimit(allocator, cgroup_dir, limits.cpu_max_cores, limits.cpu_period_us, mode);
        try pids.validateWorkerLimit(allocator, cgroup_dir, limits.pids_max, mode);
    }

    pub fn configureLimitsAt(cgroup_dir_fd: std.posix.fd_t, limits: Limits) !void {
        try validateLimitsConfig(limits);
        try memory.configureWorkerLimitsAt(cgroup_dir_fd, limits.memory_limit_bytes);
        try cpu.configureWorkerLimitAt(cgroup_dir_fd, limits.cpu_max_cores, limits.cpu_period_us);
        try pids.configureWorkerLimitAt(cgroup_dir_fd, limits.pids_max);
    }

    pub fn validateLimitsAt(
        allocator: std.mem.Allocator,
        cgroup_dir_fd: std.posix.fd_t,
        limits: Limits,
        mode: memory.LimitValidationMode,
    ) !void {
        try validateLimitsConfig(limits);
        if (mode == .allow_unconfigured)
            return;
        try memory.validateWorkerLimitsAt(
            allocator,
            cgroup_dir_fd,
            limits.memory_limit_bytes,
            mode,
        );
        try cpu.validateWorkerLimitAt(
            allocator,
            cgroup_dir_fd,
            limits.cpu_max_cores,
            limits.cpu_period_us,
            mode,
        );
        try pids.validateWorkerLimitAt(allocator, cgroup_dir_fd, limits.pids_max, mode);
    }
};

pub const membership = struct {
    pub const Result = struct {
        contains_expected: bool,
        only_expected: bool,
    };

    pub fn read(allocator: std.mem.Allocator, file_path: []const u8, expected_pid: u32) !Result {
        var file_handle = try std.fs.openFileAbsolute(file_path, .{});
        defer file_handle.close();

        const contents = try file_handle.readToEndAlloc(allocator, 4096);
        defer allocator.free(contents);

        return parse(contents, expected_pid);
    }

    pub fn readAt(
        allocator: std.mem.Allocator,
        cgroup_dir_fd: std.posix.fd_t,
        expected_pid: u32,
    ) !Result {
        const contents = try readLimitFileAtAlloc(allocator, cgroup_dir_fd, "cgroup.procs", 4096);
        defer allocator.free(contents);

        return parse(contents, expected_pid);
    }

    fn parse(contents: []const u8, expected_pid: u32) !Result {
        var non_empty_count: usize = 0;
        var contains_expected = false;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0)
                continue;
            non_empty_count += 1;
            const parsed = try std.fmt.parseUnsigned(u32, trimmed, 10);
            if (parsed == expected_pid)
                contains_expected = true;
        }

        return .{
            .contains_expected = contains_expected,
            .only_expected = contains_expected and non_empty_count == 1,
        };
    }
};

const surface_file_names = [_][]const u8{
    "cgroup.procs",
    "memory.high",
    "memory.max",
    "memory.events.local",
    "cpu.max",
    "pids.max",
};

pub fn openReadOnlyAt(cgroup_dir_fd: std.posix.fd_t, file_name: []const u8) !std.posix.fd_t {
    return std.posix.openat(cgroup_dir_fd, file_name, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0);
}

pub fn openWriteOnlyAt(cgroup_dir_fd: std.posix.fd_t, file_name: []const u8) !std.posix.fd_t {
    return std.posix.openat(cgroup_dir_fd, file_name, .{
        .ACCMODE = .WRONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0);
}

fn writeAllRaw(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = try std.posix.write(fd, remaining);
        if (written == 0)
            return error.ShortWrite;
        remaining = remaining[written..];
    }
}

fn writeScalarLimitFile(
    allocator: std.mem.Allocator,
    cgroup_dir: []const u8,
    file_name: []const u8,
    value: u64,
) !void {
    var buffer: [32]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try writeTextLimitFile(allocator, cgroup_dir, file_name, bytes);
}

fn writeTextLimitFile(
    allocator: std.mem.Allocator,
    cgroup_dir: []const u8,
    file_name: []const u8,
    bytes: []const u8,
) !void {
    const file_path = try path.file(allocator, cgroup_dir, file_name);
    defer allocator.free(file_path);

    const fd = try std.posix.open(file_path, .{
        .ACCMODE = .WRONLY,
        .CLOEXEC = true,
    }, 0);
    defer std.posix.close(fd);

    try writeAllRaw(fd, bytes);
}

// The fd-relative writers do not allocate, so the fork path can configure a
// worker cgroup without a heap.
fn writeScalarLimitFileAt(
    cgroup_dir_fd: std.posix.fd_t,
    file_name: []const u8,
    value: u64,
) !void {
    var buffer: [32]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try writeTextLimitFileAt(cgroup_dir_fd, file_name, bytes);
}

fn writeTextLimitFileAt(
    cgroup_dir_fd: std.posix.fd_t,
    file_name: []const u8,
    bytes: []const u8,
) !void {
    const fd = try openWriteOnlyAt(cgroup_dir_fd, file_name);
    defer std.posix.close(fd);
    try writeAllRaw(fd, bytes);
}

fn readScalarLimitFile(
    allocator: std.mem.Allocator,
    cgroup_dir: []const u8,
    file_name: []const u8,
) !?u64 {
    const contents = try readLimitFileAlloc(allocator, cgroup_dir, file_name, 64);
    defer allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "max"))
        return null;
    return try std.fmt.parseUnsigned(u64, trimmed, 10);
}

fn readScalarLimitFileAt(
    allocator: std.mem.Allocator,
    cgroup_dir_fd: std.posix.fd_t,
    file_name: []const u8,
) !?u64 {
    const contents = try readLimitFileAtAlloc(allocator, cgroup_dir_fd, file_name, 64);
    defer allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "max"))
        return null;
    return try std.fmt.parseUnsigned(u64, trimmed, 10);
}

fn readLimitFileAlloc(
    allocator: std.mem.Allocator,
    cgroup_dir: []const u8,
    file_name: []const u8,
    max_bytes: usize,
) ![]u8 {
    const file_path = try path.file(allocator, cgroup_dir, file_name);
    defer allocator.free(file_path);

    var file_handle = try std.fs.openFileAbsolute(file_path, .{});
    defer file_handle.close();

    return file_handle.readToEndAlloc(allocator, max_bytes);
}

fn readLimitFileAtAlloc(
    allocator: std.mem.Allocator,
    cgroup_dir_fd: std.posix.fd_t,
    file_name: []const u8,
    max_bytes: usize,
) ![]u8 {
    const fd = try openReadOnlyAt(cgroup_dir_fd, file_name);
    var file_handle = std.fs.File{ .handle = fd };
    defer file_handle.close();

    return file_handle.readToEndAlloc(allocator, max_bytes);
}
