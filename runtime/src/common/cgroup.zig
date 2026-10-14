//! cgroup v2 primitives for a worker's cgroup: writing and checking its
//! memory, swap, CPU and pids limits, reading the figures the server takes
//! off its leaf (`LeafFigure`), the CPU use and the cpuset of the cgroups
//! above the workers, and finding a process's cgroup. A leaf is
//! written and checked through its directory fd, and neither the writers,
//! the checks nor the figure reads allocate, so the zygote's child can check
//! its own leaf before it has a heap of its own and the server reads a
//! figure into a stack buffer; only the lookups in `path` allocate. Every
//! read takes one `read` into a buffer sized for its file, and a read that
//! fills the buffer fails with `error.CgroupFileTooLarge`. The worker's
//! memory limit is its `memory.high`, and `memory.max` and the threshold at
//! which the engine requests a collection are derived from it here;
//! `memory.swap.max` is 0, so `memory.max` bounds the worker's memory on a
//! node with swap too. Stateless, so any thread may call it.

const std = @import("std");

pub const memory = struct {
    /// The engine's collection trigger as a fraction of the memory limit
    /// (`gcHeapLimitBytes`): the worker sets it as the engine's
    /// `gcMaxHeapSize` override (`zygote/child_boot.zig`), and the engine
    /// requests a collection once the bytes allocated since the last one pass
    /// it (`runtime/patches/webkit/0002-embedder-memory-budget.patch`). It
    /// caps no heap and fails no allocation.
    pub const GC_HEAP_RATIO_NUM: u64 = 9;
    pub const GC_HEAP_RATIO_DEN: u64 = 10;
    /// `memory.max`, where the kernel OOM-kills the cgroup, as a fraction of
    /// the memory limit (`maxBytes`).
    pub const MAX_RATIO_NUM: u64 = 115;
    pub const MAX_RATIO_DEN: u64 = 100;
    /// `memory.swap.max` of a worker leaf: none of its memory may go to swap,
    /// so `memory.max` is the hard bound whether or not the node has swap.
    /// A swap charge the limit refuses also keeps the page from zswap, so
    /// `memory.zswap.max` needs nothing.
    pub const SWAP_MAX_BYTES: u64 = 0;

    pub const Events = struct {
        low: u64 = 0,
        high: u64 = 0,
        max: u64 = 0,
        oom: u64 = 0,
        oom_kill: u64 = 0,

        pub fn highPressureFieldSince(self: Events, baseline: Events) ?[]const u8 {
            if (self.high > baseline.high)
                return "high";
            return null;
        }
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

    /// Room for one read of a `memory.events` or `memory.events.local` file:
    /// six `<key> <count>` lines since Linux 5.17 added `oom_group_kill`,
    /// which take at most 167 bytes with 20-digit counts.
    pub const events_bytes_max: usize = 256;

    /// The events of the open `memory.events` file `fd`, read from its start
    /// into a stack buffer, so a caller polling the file reads it again
    /// without seeking.
    pub fn readEvents(fd: std.posix.fd_t) !Events {
        var buffer: [events_bytes_max]u8 = undefined;
        const read_len = try std.posix.pread(fd, &buffer, 0);
        if (read_len == buffer.len)
            return error.CgroupFileTooLarge;
        return parseEvents(buffer[0..read_len]);
    }

    /// Writes `memory.max`, `memory.swap.max` (`SWAP_MAX_BYTES`),
    /// `memory.high` and `memory.oom.group=1` in the leaf `cgroup_dir_fd`.
    /// With `memory.oom.group` set, a kernel OOM in the cgroup kills every
    /// task in it together instead of choosing one. `memory.oom.group` has
    /// existed next to `memory.max` since Linux 4.19, so its `FileNotFound`
    /// is tolerated only for test fixtures that are plain directories;
    /// `memory.swap.max` is missing on a kernel booted without swap
    /// accounting too, where no worker memory can be charged to swap.
    pub fn configureWorkerLimitsAt(
        cgroup_dir_fd: std.posix.fd_t,
        memory_limit_bytes: u64,
    ) !void {
        try writeScalarLimitFileAt(cgroup_dir_fd, "memory.max", maxBytes(memory_limit_bytes));
        writeScalarLimitFileAt(cgroup_dir_fd, "memory.swap.max", SWAP_MAX_BYTES) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try writeScalarLimitFileAt(cgroup_dir_fd, "memory.high", memory_limit_bytes);
        writeScalarLimitFileAt(cgroup_dir_fd, "memory.oom.group", 1) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Fails unless the leaf holds the limits `configureWorkerLimitsAt`
    /// writes for `memory_limit_bytes`: `memory.high` and `memory.max`, and
    /// `memory.swap.max` at `SWAP_MAX_BYTES` wherever the file exists.
    pub fn validateWorkerLimitsAt(cgroup_dir_fd: std.posix.fd_t, memory_limit_bytes: u64) !void {
        try validateLimitBytes(memory_limit_bytes);
        const high = try readScalarLimitAt(cgroup_dir_fd, "memory.high");
        const max = try readScalarLimitAt(cgroup_dir_fd, "memory.max");
        if (high == null or max == null)
            return error.WorkerCgroupMemoryLimitNotConfigured;
        if (high.? != memory_limit_bytes)
            return error.WorkerCgroupMemoryHighMismatch;
        if (max.? != maxBytes(memory_limit_bytes))
            return error.WorkerCgroupMemoryMaxMismatch;
        const swap_max = readScalarLimitAt(cgroup_dir_fd, "memory.swap.max") catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (swap_max == null)
            return error.WorkerCgroupSwapMismatch;
        if (swap_max.? != SWAP_MAX_BYTES)
            return error.WorkerCgroupSwapMismatch;
    }

    /// Parses the text of a `memory.events` or `memory.events.local` file
    /// the caller read. A line without a key and a value fails with
    /// `error.InvalidMemoryEventsFile`, and a value that is not decimal with
    /// `std.fmt.parseUnsigned`'s error.
    pub fn parseEvents(contents: []const u8) !Events {
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

    /// The leaf's `cpu.max`, read without allocating.
    pub fn readMaxAt(cgroup_dir_fd: std.posix.fd_t) !Max {
        var buffer: [64]u8 = undefined;
        return parseMax(try readLimitFileAtBounded(cgroup_dir_fd, "cpu.max", &buffer));
    }

    /// Fails unless the leaf's `cpu.max` is `max_cores` over `period_us`.
    pub fn validateWorkerLimitAt(
        cgroup_dir_fd: std.posix.fd_t,
        max_cores: u32,
        period_us: u64,
    ) !void {
        try validateConfig(max_cores, period_us);
        const configured = try readMaxAt(cgroup_dir_fd);
        const quota_us = configured.quota_us orelse return error.WorkerCgroupCpuLimitNotConfigured;
        if (quota_us != quotaForCores(max_cores, period_us))
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

    /// `usage_usec` in the text of a `cpu.stat` file the caller read. A file
    /// without it, or without its value, fails with
    /// `error.InvalidCpuStatFile`, and a value that is not decimal with
    /// `std.fmt.parseUnsigned`'s error.
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

    /// `usage_usec` of the `cpu.stat` of the cgroup `cgroup_dir_fd` names,
    /// read without allocating. Fails as the read and `parseStatUsageUsec`
    /// do.
    pub fn readStatUsageUsecAt(cgroup_dir_fd: std.posix.fd_t) !u64 {
        var buffer: [LeafFigure.bytesMax(.cpu_usage_usec)]u8 = undefined;
        return parseStatUsageUsec(try readLimitFileAtBounded(cgroup_dir_fd, "cpu.stat", &buffer));
    }

    /// The `total` of the `some` line of a `cpu.pressure` file the caller
    /// read: the microseconds during which at least one task of the cgroup
    /// was runnable and not running. A file without that line or its total
    /// fails with `error.InvalidCpuPressureFile`, and a total that is not
    /// decimal with `std.fmt.parseUnsigned`'s error.
    pub fn parsePressureSomeTotalUsec(contents: []const u8) !u64 {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const kind = fields.next() orelse continue;
            if (!std.mem.eql(u8, kind, "some"))
                continue;
            while (fields.next()) |field| {
                if (std.mem.startsWith(u8, field, "total="))
                    return std.fmt.parseUnsigned(u64, field["total=".len..], 10);
            }
            return error.InvalidCpuPressureFile;
        }
        return error.InvalidCpuPressureFile;
    }
};

pub const cpuset = struct {
    /// Room for `cpuset.cpus.effective`: a list of CPU ranges, such as
    /// `0-3,8,10-11`, which on the largest machines stays far below this.
    pub const effective_cpus_bytes_max: usize = 4096;

    /// Sets in `cpus` each CPU that the `cpuset.cpus.effective` of the
    /// cgroup `cgroup_dir_fd` names, read without allocating; `cpus` is a
    /// `std.bit_set` whose `bit_length` bounds the CPU numbers taken. The
    /// file exists only where the cpuset controller is enabled, so a cgroup
    /// without it fails with `error.FileNotFound`; a list the parser refuses
    /// fails with `error.InvalidCpusetList`.
    pub fn readEffectiveCpusAt(cgroup_dir_fd: std.posix.fd_t, cpus: anytype) !void {
        var buffer: [effective_cpus_bytes_max]u8 = undefined;
        try parseList(try readLimitFileAtBounded(cgroup_dir_fd, "cpuset.cpus.effective", &buffer), cpus);
    }

    /// Sets in `cpus` each CPU of a cpuset list, comma-separated numbers and
    /// inclusive ranges with a trailing newline allowed; CPUs at or past
    /// `cpus`'s `bit_length` are left out.
    pub fn parseList(contents: []const u8, cpus: anytype) !void {
        const trimmed = std.mem.trim(u8, contents, &std.ascii.whitespace);
        var items = std.mem.tokenizeScalar(u8, trimmed, ',');
        while (items.next()) |item| {
            const dash = std.mem.indexOfScalar(u8, item, '-');
            const first_text = if (dash) |index| item[0..index] else item;
            const last_text = if (dash) |index| item[index + 1 ..] else item;
            const first = std.fmt.parseUnsigned(usize, first_text, 10) catch return error.InvalidCpusetList;
            const last = std.fmt.parseUnsigned(usize, last_text, 10) catch return error.InvalidCpusetList;
            if (last < first)
                return error.InvalidCpusetList;
            const bit_length = @TypeOf(cpus.*).bit_length;
            var cpu_index = first;
            while (cpu_index <= last and cpu_index < bit_length) : (cpu_index += 1)
                cpus.set(cpu_index);
        }
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

    pub fn configureWorkerLimitAt(cgroup_dir_fd: std.posix.fd_t, max_pids: u64) !void {
        try validateLimit(max_pids);
        try writeScalarLimitFileAt(cgroup_dir_fd, "pids.max", max_pids);
    }

    /// Fails unless the leaf's `pids.max` is `max_pids`.
    pub fn validateWorkerLimitAt(cgroup_dir_fd: std.posix.fd_t, max_pids: u64) !void {
        try validateLimit(max_pids);
        const configured = try readScalarLimitAt(cgroup_dir_fd, "pids.max") orelse
            return error.WorkerCgroupPidsLimitNotConfigured;
        if (configured != max_pids)
            return error.WorkerCgroupPidsMaxMismatch;
    }
};

/// A figure the server reads off a worker's leaf, while the worker runs or
/// after it exited and before the leaf goes. The kernel keeps every one of
/// them, so the worker cannot forge them.
pub const LeafFigure = enum {
    /// `memory.events.local`, the events of the leaf alone. With
    /// `memory.oom.group` set, `oom_kill` counts every task one OOM kill
    /// took, so a single group kill reads as at least 1.
    memory_events,
    /// `memory.current`, the bytes charged to the leaf now.
    memory_current,
    /// `memory.peak`, the most bytes ever charged to the leaf; Linux 5.19
    /// and later.
    memory_peak,
    /// `usage_usec` of `cpu.stat`, the CPU every task of the leaf used, in
    /// microseconds.
    cpu_usage_usec,
    /// The `some` total of `cpu.pressure`, the microseconds during which at
    /// least one task of the leaf was runnable and not running. The file
    /// exists only on a kernel with PSI.
    cpu_pressure_some_usec,

    pub fn Value(comptime figure: LeafFigure) type {
        return switch (figure) {
            .memory_events => memory.Events,
            .memory_current, .memory_peak, .cpu_usage_usec, .cpu_pressure_some_usec => u64,
        };
    }

    pub fn fileName(figure: LeafFigure) []const u8 {
        return switch (figure) {
            .memory_events => "memory.events.local",
            .memory_current => "memory.current",
            .memory_peak => "memory.peak",
            .cpu_usage_usec => "cpu.stat",
            .cpu_pressure_some_usec => "cpu.pressure",
        };
    }

    /// Room for one read of the figure's file. A file outgrowing it fails
    /// the read (`readLeafFigure`), never parses a truncated count.
    pub fn bytesMax(figure: LeafFigure) usize {
        return switch (figure) {
            .memory_events => memory.events_bytes_max,
            // One count of at most 20 digits and its newline.
            .memory_current, .memory_peak => 64,
            // The kernel's cgroup v2 documentation lists nine `<key> <count>`
            // lines, the longest key `core_sched.force_idle_usec`; with
            // 20-digit counts they take under 450 bytes.
            .cpu_usage_usec => 1024,
            // Two lines of three averages and a 20-digit total each, about
            // 130 bytes.
            .cpu_pressure_some_usec => 256,
        };
    }
};

/// Reads `figure` off `leaf` without allocating: one read of its file into a
/// stack buffer of `LeafFigure.bytesMax`, then the parse. `leaf` is anything
/// with `readFile(file_name, buffer) ![]const u8` that reads the leaf's file
/// once into `buffer` and fails with `error.CgroupFileTooLarge` for a read
/// that fills it: `host/cgroup_root.zig:WorkerLeaf`, which opens the file
/// relative to the server's workers directory. This module sits below the
/// host, so it takes the leaf by that method alone. Fails with the read's
/// error, `error.FileNotFound` once the leaf is gone among them, or with the
/// parser's.
pub fn readLeafFigure(leaf: anytype, comptime figure: LeafFigure) !figure.Value() {
    var buffer: [figure.bytesMax()]u8 = undefined;
    const contents = try leaf.readFile(figure.fileName(), &buffer);
    switch (figure) {
        .memory_events => return memory.parseEvents(contents),
        .memory_current, .memory_peak => return parseCount(contents),
        .cpu_usage_usec => return cpu.parseStatUsageUsec(contents),
        .cpu_pressure_some_usec => return cpu.parsePressureSomeTotalUsec(contents),
    }
}

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

    pub fn validateLimitsConfig(limits: Limits) !void {
        try memory.validateLimitBytes(limits.memory_limit_bytes);
        try cpu.validateConfig(limits.cpu_max_cores, limits.cpu_period_us);
        try pids.validateLimit(limits.pids_max);
    }

    /// Writes every limit of `limits` in the leaf `cgroup_dir_fd`. The host
    /// calls it on a leaf it just created, before any process is born in it.
    pub fn configureLimitsAt(cgroup_dir_fd: std.posix.fd_t, limits: Limits) !void {
        try validateLimitsConfig(limits);
        try memory.configureWorkerLimitsAt(cgroup_dir_fd, limits.memory_limit_bytes);
        try cpu.configureWorkerLimitAt(cgroup_dir_fd, limits.cpu_max_cores, limits.cpu_period_us);
        try pids.configureWorkerLimitAt(cgroup_dir_fd, limits.pids_max);
    }

    /// Fails unless the leaf holds every limit `configureLimitsAt` writes for
    /// `limits`, naming the first that differs.
    pub fn validateLimitsAt(cgroup_dir_fd: std.posix.fd_t, limits: Limits) !void {
        try validateLimitsConfig(limits);
        try memory.validateWorkerLimitsAt(cgroup_dir_fd, limits.memory_limit_bytes);
        try cpu.validateWorkerLimitAt(cgroup_dir_fd, limits.cpu_max_cores, limits.cpu_period_us);
        try pids.validateWorkerLimitAt(cgroup_dir_fd, limits.pids_max);
    }
};

pub const membership = struct {
    pub const Result = struct {
        /// How many processes the leaf holds.
        member_count: usize,
        contains_expected: bool,
        only_expected: bool,
    };

    /// Reads the leaf's `cgroup.procs` without allocating; a list longer than
    /// the buffer fails with `error.CgroupFileTooLarge`.
    pub fn readAt(cgroup_dir_fd: std.posix.fd_t, expected_pid: u32) !Result {
        var buffer: [4096]u8 = undefined;
        const contents = try readLimitFileAtBounded(cgroup_dir_fd, "cgroup.procs", &buffer);
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
            .member_count = non_empty_count,
            .contains_expected = contains_expected,
            .only_expected = contains_expected and non_empty_count == 1,
        };
    }
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

/// A limit file holding one decimal or `max`, which reads as null.
fn readScalarLimitAt(cgroup_dir_fd: std.posix.fd_t, file_name: []const u8) !?u64 {
    var buffer: [64]u8 = undefined;
    const contents = try readLimitFileAtBounded(cgroup_dir_fd, file_name, &buffer);
    const trimmed = std.mem.trim(u8, contents, &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "max"))
        return null;
    return try std.fmt.parseUnsigned(u64, trimmed, 10);
}

/// One read of a cgroup file into `buffer`. Every file read here is a few
/// bytes, and the kernel fills a cgroup file's read in one call, so a read
/// that fills the buffer means a file this module does not know and fails
/// with `error.CgroupFileTooLarge`.
fn readLimitFileAtBounded(
    cgroup_dir_fd: std.posix.fd_t,
    file_name: []const u8,
    buffer: []u8,
) ![]const u8 {
    const fd = try openReadOnlyAt(cgroup_dir_fd, file_name);
    defer std.posix.close(fd);
    const read_len = try std.posix.read(fd, buffer);
    if (read_len == buffer.len)
        return error.CgroupFileTooLarge;
    return buffer[0..read_len];
}

/// One count of a `memory.current` or `memory.peak` file, its trailing
/// newline allowed.
fn parseCount(contents: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, std.mem.trim(u8, contents, &std.ascii.whitespace), 10);
}
