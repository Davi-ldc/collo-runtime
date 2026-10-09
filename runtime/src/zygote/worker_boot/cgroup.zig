//! Checks a worker's cgroup from the zygote's side. Before the clone, the
//! zygote verifies the target is an empty cgroup2 directory; after it, the
//! child verifies it is the cgroup's only member, that the memory and CPU
//! limits match the ones WorkerInit carries, and that the pids limit and CPU
//! period match the defaults. A mismatch fails the boot rather than letting
//! the worker serve under limits nobody set. The child's checks run without
//! allocating.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("collo_cgroup");

const cgroup2_super_magic: c_long = 0x63677270;

const Statfs = extern struct {
    f_type: c_long,
    f_bsize: c_long,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_files: c_ulong,
    f_ffree: c_ulong,
    f_fsid: [2]c_int,
    f_namelen: c_long,
    f_frsize: c_long,
    f_flags: c_long,
    f_spare: [4]c_long,
};

extern fn fstatfs(fd: c_int, buf: *Statfs) c_int;

pub const memory = common.memory;
pub const worker = common.worker;

pub const CurrentWorkerMemoryEvents = struct {
    fd: std.posix.fd_t,
    cgroup_dir: []u8,
};

pub const OpenedWorkerMemoryEvents = struct {
    fd: std.posix.fd_t,
};

const CurrentWorkerCgroup = struct {
    dir_fd: std.posix.fd_t,
    cgroup_dir: []u8,
};

pub fn validateCurrentWorkerCgroup(
    allocator: std.mem.Allocator,
    pid: u32,
    memory_limit_bytes: u64,
) ![]u8 {
    const limits = common.worker.Limits{ .memory_limit_bytes = memory_limit_bytes };
    const current = try openValidatedCurrentWorkerCgroup(allocator, pid, limits);
    std.posix.close(current.dir_fd);
    return current.cgroup_dir;
}

fn openValidatedCurrentWorkerCgroup(
    allocator: std.mem.Allocator,
    pid: u32,
    limits: common.worker.Limits,
) !CurrentWorkerCgroup {
    try common.worker.validateLimitsConfig(limits);
    const cgroup_dir = try common.path.workerDirForPid(allocator, pid);
    errdefer allocator.free(cgroup_dir);

    const dir_fd = try common.path.openDir(cgroup_dir);
    errdefer std.posix.close(dir_fd);

    try validateWorkerCgroupDirFd(dir_fd);
    try common.worker.ensureSurfaceAt(dir_fd);
    try validateCurrentWorkerCgroupAt(allocator, dir_fd, pid, limits);

    return .{
        .dir_fd = dir_fd,
        .cgroup_dir = cgroup_dir,
    };
}

fn validateCurrentWorkerCgroupAt(
    allocator: std.mem.Allocator,
    cgroup_dir_fd: std.posix.fd_t,
    pid: u32,
    limits: common.worker.Limits,
) !void {
    const membership = try common.membership.readAt(allocator, cgroup_dir_fd, pid);
    if (!membership.contains_expected)
        return error.ExpectedPidMissingFromCgroup;
    if (!membership.only_expected) {
        if (!builtin.is_test)
            return error.WorkerCgroupNotDedicated;
        try common.worker.validateLimitsAt(allocator, cgroup_dir_fd, limits, .allow_unconfigured);
        return;
    }
    try common.worker.validateLimitsAt(allocator, cgroup_dir_fd, limits, .require_configured);
}

pub fn validateWorkerCgroupDirFd(cgroup_dir_fd: std.posix.fd_t) !void {
    if (cgroup_dir_fd < 0)
        return error.InvalidWorkerCgroupDir;
    const stat = std.posix.fstat(cgroup_dir_fd) catch return error.InvalidWorkerCgroupDir;
    if ((stat.mode & std.os.linux.S.IFMT) != std.os.linux.S.IFDIR)
        return error.InvalidWorkerCgroupDir;
    var fs: Statfs = undefined;
    if (fstatfs(cgroup_dir_fd, &fs) != 0)
        return error.InvalidWorkerCgroupDir;
    if (fs.f_type != cgroup2_super_magic)
        return error.InvalidWorkerCgroupDir;
}

/// Checks, before the clone and without allocating, that the target is an
/// empty cgroup2 directory. A new worker cgroup has no members, so a populated
/// `cgroup.procs` means the host passed the wrong fd, such as its own `main`
/// cgroup. The worker would then be born among the runtime's own processes,
/// and killing the worker's cgroup would kill them too. Tenant code never
/// reaches this fd, so the check guards against host bugs.
pub fn validateEmptyWorkerCgroupDirFd(cgroup_dir_fd: std.posix.fd_t) !void {
    try validateWorkerCgroupDirFd(cgroup_dir_fd);
    var buffer: [4096]u8 = undefined;
    const contents = try readLimitFileAtBounded(cgroup_dir_fd, "cgroup.procs", &buffer);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len != 0)
            return error.WorkerCgroupNotEmpty;
    }
}

fn validateCurrentWorkerCgroupAtNoAlloc(
    cgroup_dir_fd: std.posix.fd_t,
    pid: u32,
    limits: common.worker.Limits,
) !void {
    try common.worker.validateLimitsConfig(limits);
    const membership = try readMembershipAtNoAlloc(cgroup_dir_fd, pid);
    if (!membership.contains_expected)
        return error.ExpectedPidMissingFromCgroup;
    if (!membership.only_expected) {
        if (!builtin.is_test)
            return error.WorkerCgroupNotDedicated;
        return;
    }
    try validateLimitsAtNoAlloc(cgroup_dir_fd, limits, .require_configured);
}

fn validateLimitsAtNoAlloc(
    cgroup_dir_fd: std.posix.fd_t,
    limits: common.worker.Limits,
    mode: common.memory.LimitValidationMode,
) !void {
    try common.worker.validateLimitsConfig(limits);
    if (mode == .allow_unconfigured)
        return;
    try validateMemoryLimitsAtNoAlloc(cgroup_dir_fd, limits.memory_limit_bytes, mode);
    try validateCpuLimitAtNoAlloc(
        cgroup_dir_fd,
        limits.cpu_max_cores,
        limits.cpu_period_us,
        mode,
    );
    try validatePidsLimitAtNoAlloc(cgroup_dir_fd, limits.pids_max, mode);
}

fn validateMemoryLimitsAtNoAlloc(
    cgroup_dir_fd: std.posix.fd_t,
    memory_limit_bytes: u64,
    mode: common.memory.LimitValidationMode,
) !void {
    try common.memory.validateLimitBytes(memory_limit_bytes);
    const high = try readScalarLimitAtNoAlloc(cgroup_dir_fd, "memory.high");
    const max = try readScalarLimitAtNoAlloc(cgroup_dir_fd, "memory.max");
    if (high == null or max == null) {
        if (mode == .allow_unconfigured)
            return;
        return error.WorkerCgroupMemoryLimitNotConfigured;
    }
    if (high.? != memory_limit_bytes)
        return error.WorkerCgroupMemoryHighMismatch;
    if (max.? != common.memory.maxBytes(memory_limit_bytes))
        return error.WorkerCgroupMemoryMaxMismatch;
}

fn validateCpuLimitAtNoAlloc(
    cgroup_dir_fd: std.posix.fd_t,
    max_cores: u32,
    period_us: u64,
    mode: common.memory.LimitValidationMode,
) !void {
    try common.cpu.validateConfig(max_cores, period_us);
    var buffer: [64]u8 = undefined;
    const contents = try readLimitFileAtBounded(cgroup_dir_fd, "cpu.max", &buffer);
    const configured = try common.cpu.parseMax(contents);
    if (configured.quota_us == null) {
        if (mode == .allow_unconfigured)
            return;
        return error.WorkerCgroupCpuLimitNotConfigured;
    }
    if (configured.quota_us.? != common.cpu.quotaForCores(max_cores, period_us))
        return error.WorkerCgroupCpuQuotaMismatch;
    if (configured.period_us != period_us)
        return error.WorkerCgroupCpuPeriodMismatch;
}

fn validatePidsLimitAtNoAlloc(
    cgroup_dir_fd: std.posix.fd_t,
    max_pids: u64,
    mode: common.memory.LimitValidationMode,
) !void {
    try common.pids.validateLimit(max_pids);
    const configured = try readScalarLimitAtNoAlloc(cgroup_dir_fd, "pids.max");
    if (configured == null) {
        if (mode == .allow_unconfigured)
            return;
        return error.WorkerCgroupPidsLimitNotConfigured;
    }
    if (configured.? != max_pids)
        return error.WorkerCgroupPidsMaxMismatch;
}

fn readMembershipAtNoAlloc(
    cgroup_dir_fd: std.posix.fd_t,
    expected_pid: u32,
) !common.membership.Result {
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
        .contains_expected = contains_expected,
        .only_expected = contains_expected and non_empty_count == 1,
    };
}

fn readScalarLimitAtNoAlloc(
    cgroup_dir_fd: std.posix.fd_t,
    comptime file_name: []const u8,
) !?u64 {
    var buffer: [64]u8 = undefined;
    const contents = try readLimitFileAtBounded(cgroup_dir_fd, file_name, &buffer);
    const trimmed = std.mem.trim(u8, contents, &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "max"))
        return null;
    return try std.fmt.parseUnsigned(u64, trimmed, 10);
}

fn readLimitFileAtBounded(
    cgroup_dir_fd: std.posix.fd_t,
    comptime file_name: []const u8,
    buffer: []u8,
) ![]const u8 {
    const fd = try common.openReadOnlyAt(cgroup_dir_fd, file_name);
    defer std.posix.close(fd);
    const read_len = try std.posix.read(fd, buffer);
    if (read_len == buffer.len)
        return error.CgroupFileTooLarge;
    return buffer[0..read_len];
}

pub fn validateAndOpenCurrentWorkerMemoryEvents(
    allocator: std.mem.Allocator,
    pid: u32,
    memory_limit_bytes: u64,
) !CurrentWorkerMemoryEvents {
    const limits = common.worker.Limits{ .memory_limit_bytes = memory_limit_bytes };
    const current = try openValidatedCurrentWorkerCgroup(allocator, pid, limits);
    defer std.posix.close(current.dir_fd);
    errdefer allocator.free(current.cgroup_dir);

    const fd = try openMemoryEventsFileAt(current.dir_fd);
    errdefer std.posix.close(fd);
    try validateCurrentWorkerCgroupAt(allocator, current.dir_fd, pid, limits);
    return .{
        .fd = fd,
        .cgroup_dir = current.cgroup_dir,
    };
}

pub fn validateAndOpenWorkerMemoryEventsAt(
    cgroup_dir_fd: std.posix.fd_t,
    pid: u32,
    memory_limit_bytes: u64,
    cpu_max_cores: u32,
) !OpenedWorkerMemoryEvents {
    try validateWorkerCgroupDirFd(cgroup_dir_fd);
    try common.worker.ensureSurfaceAt(cgroup_dir_fd);

    // CPU is checked next to memory, so a host that forgot to write either
    // limit fails the boot.
    const limits = common.worker.Limits{
        .memory_limit_bytes = memory_limit_bytes,
        .cpu_max_cores = cpu_max_cores,
    };
    try validateCurrentWorkerCgroupAtNoAlloc(cgroup_dir_fd, pid, limits);

    const fd = try openMemoryEventsFileAt(cgroup_dir_fd);
    errdefer std.posix.close(fd);
    try validateCurrentWorkerCgroupAtNoAlloc(cgroup_dir_fd, pid, limits);
    return .{
        .fd = fd,
    };
}

pub fn openCurrentWorkerMemoryEvents(
    allocator: std.mem.Allocator,
    pid: u32,
) !CurrentWorkerMemoryEvents {
    const cgroup_dir = try common.path.workerDirForPid(allocator, pid);
    errdefer allocator.free(cgroup_dir);

    const cgroup_dir_fd = try common.path.openDir(cgroup_dir);
    defer std.posix.close(cgroup_dir_fd);

    try validateWorkerCgroupDirFd(cgroup_dir_fd);
    try common.worker.ensureSurfaceAt(cgroup_dir_fd);
    const fd = try openMemoryEventsFileAt(cgroup_dir_fd);
    return .{
        .fd = fd,
        .cgroup_dir = cgroup_dir,
    };
}

fn openMemoryEventsFileAt(cgroup_dir_fd: std.posix.fd_t) !std.posix.fd_t {
    return common.openReadOnlyAt(cgroup_dir_fd, "memory.events.local");
}
