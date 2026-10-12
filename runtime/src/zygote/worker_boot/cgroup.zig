//! Checks a worker's cgroup from the zygote's side. Before the clone, the
//! zygote verifies the target is an empty cgroup2 directory; after it, the
//! child verifies it is the cgroup's only member, that its memory, swap and
//! CPU limits match the ones WorkerInit carries, and that the pids limit and
//! CPU period match the defaults (`common/cgroup.zig:worker.validateLimitsAt`),
//! and opens the two files the worker reads for the rest of its life. A
//! mismatch fails the boot rather than letting the worker serve under limits
//! nobody set. The child's checks run without allocating.

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

/// The leaf files a worker keeps open for its life, each read-only and
/// close-on-exec, opened while the child still sees the cgroup filesystem.
pub const OpenedWorkerLeaf = struct {
    /// `memory.events.local`, which the sentinel watches for `high`.
    memory_events_fd: std.posix.fd_t,
    /// `memory.current`, which the engine reads as its footprint
    /// (`bindings/root.zig:setMemoryStatusOverride`).
    memory_current_fd: std.posix.fd_t,
};

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
    // Pid 0 names no process, so only the count matters.
    const members = try common.membership.readAt(cgroup_dir_fd, 0);
    if (members.member_count != 0)
        return error.WorkerCgroupNotEmpty;
}

/// The child's check of the leaf it was born in, then the opens of
/// `OpenedWorkerLeaf`, then the check again, so the descriptors belong to a
/// leaf that still holds the child alone under the limits of `limits`. Runs
/// before the chroot, which hides the cgroup filesystem, and without
/// allocating. The caller owns both descriptors.
pub fn validateAndOpenWorkerLeafAt(
    cgroup_dir_fd: std.posix.fd_t,
    pid: u32,
    limits: common.worker.Limits,
) !OpenedWorkerLeaf {
    try validateWorkerCgroupDirFd(cgroup_dir_fd);
    try common.worker.ensureSurfaceAt(cgroup_dir_fd);
    try validateCurrentWorkerCgroupAt(cgroup_dir_fd, pid, limits);

    const memory_events_fd = try common.openReadOnlyAt(cgroup_dir_fd, "memory.events.local");
    errdefer std.posix.close(memory_events_fd);
    const memory_current_fd = try common.openReadOnlyAt(cgroup_dir_fd, "memory.current");
    errdefer std.posix.close(memory_current_fd);
    try validateCurrentWorkerCgroupAt(cgroup_dir_fd, pid, limits);
    return .{
        .memory_events_fd = memory_events_fd,
        .memory_current_fd = memory_current_fd,
    };
}

fn validateCurrentWorkerCgroupAt(
    cgroup_dir_fd: std.posix.fd_t,
    pid: u32,
    limits: common.worker.Limits,
) !void {
    try common.worker.validateLimitsConfig(limits);
    const membership = try common.membership.readAt(cgroup_dir_fd, pid);
    if (!membership.contains_expected)
        return error.ExpectedPidMissingFromCgroup;
    if (!membership.only_expected) {
        // A test process shares its cgroup with the build that spawned it,
        // whose limits are not a worker's.
        if (!builtin.is_test)
            return error.WorkerCgroupNotDedicated;
        return;
    }
    try common.worker.validateLimitsAt(cgroup_dir_fd, limits);
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
    const fd = try common.openReadOnlyAt(cgroup_dir_fd, "memory.events.local");
    return .{
        .fd = fd,
        .cgroup_dir = cgroup_dir,
    };
}
