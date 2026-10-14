//! A worker's cgroup leaf as the zygote and the child check it. The kernel
//! places the child: the fork loop clones it straight into the leaf its
//! request carries (`CLONE_INTO_CGROUP`), so the limits the launcher wrote
//! there hold from its first instruction. These checks catch a host that sent
//! the wrong leaf or wrote the wrong limits, and both run without allocating.
//!
//! - Before the clone the zygote checks that the leaf is an empty cgroup2
//!   directory (`validateEmptyWorkerCgroupDirFd`), so a child is never born
//!   among the runtime's own processes.
//! - After it the child makes one pass over the leaf it was born in
//!   (`validateAndOpenWorkerLeafAt`): it must be the leaf's only member, and
//!   the leaf must hold the memory, swap, CPU and pids limits
//!   `common/cgroup.zig:worker.configureLimitsAt` writes for its
//!   `WorkerInit`, so no engine or tenant code runs under limits nobody set.
//!   Then it opens the two files the worker reads for the rest of its life,
//!   before the chroot hides the cgroup filesystem.

const std = @import("std");
const common = @import("collo_cgroup");
const linux_helpers = @import("collo_os").linux;
const linux = std.os.linux;

const cgroup2_super_magic: c_long = 0x63677270;

/// The kernel's `struct statfs` on the 64-bit targets, for the raw `fstatfs`.
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

pub const memory = common.memory;
pub const worker = common.worker;

/// The leaf files a worker keeps open for its life, each read-only and
/// close-on-exec, opened while the child still sees the cgroup filesystem.
pub const OpenedWorkerLeaf = struct {
    /// `memory.events.local`, which the sentinel watches for `high`.
    memory_events_fd: std.posix.fd_t,
    /// `memory.current`, which the engine reads as its footprint
    /// (`bindings/root.zig:setMemoryStatusOverride`).
    memory_current_fd: std.posix.fd_t,
};

/// Fails unless `cgroup_dir_fd` is a directory on the cgroup2 filesystem.
pub fn validateWorkerCgroupDirFd(cgroup_dir_fd: std.posix.fd_t) !void {
    if (cgroup_dir_fd < 0)
        return error.InvalidWorkerCgroupDir;
    const stat = std.posix.fstat(cgroup_dir_fd) catch return error.InvalidWorkerCgroupDir;
    if ((stat.mode & linux.S.IFMT) != linux.S.IFDIR)
        return error.InvalidWorkerCgroupDir;
    var fs: Statfs = undefined;
    const rc = linux.syscall2(.fstatfs, @as(usize, @intCast(cgroup_dir_fd)), @intFromPtr(&fs));
    if (linux_helpers.syscallErrno(rc) != .SUCCESS)
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

/// The child's one pass over the leaf it was born in, then the opens of
/// `OpenedWorkerLeaf`. The leaf must hold the child alone under the limits
/// of `limits`. Runs before the chroot, which hides the cgroup filesystem,
/// and without allocating. The caller owns both descriptors.
pub fn validateAndOpenWorkerLeafAt(
    cgroup_dir_fd: std.posix.fd_t,
    pid: u32,
    limits: common.worker.Limits,
) !OpenedWorkerLeaf {
    try validateWorkerCgroupDirFd(cgroup_dir_fd);
    const membership = try common.membership.readAt(cgroup_dir_fd, pid);
    if (!membership.contains_expected)
        return error.ExpectedPidMissingFromCgroup;
    if (!membership.only_expected)
        return error.WorkerCgroupNotDedicated;
    try common.worker.validateLimitsAt(cgroup_dir_fd, limits);

    const memory_events_fd = try common.openReadOnlyAt(cgroup_dir_fd, "memory.events.local");
    errdefer std.posix.close(memory_events_fd);
    const memory_current_fd = try common.openReadOnlyAt(cgroup_dir_fd, "memory.current");
    return .{
        .memory_events_fd = memory_events_fd,
        .memory_current_fd = memory_current_fd,
    };
}

/// The `memory.events.local` of the cgroup `pid` is in, opened read-only, and
/// that cgroup's path, which the caller frees. Only tests call it: a worker
/// opens its leaf's file through `validateAndOpenWorkerLeafAt`.
pub const CurrentWorkerMemoryEvents = struct {
    fd: std.posix.fd_t,
    cgroup_dir: []u8,
};

pub fn openCurrentWorkerMemoryEvents(
    allocator: std.mem.Allocator,
    pid: u32,
) !CurrentWorkerMemoryEvents {
    const cgroup_dir = try common.path.workerDirForPid(allocator, pid);
    errdefer allocator.free(cgroup_dir);

    const cgroup_dir_fd = try common.path.openDir(cgroup_dir);
    defer std.posix.close(cgroup_dir_fd);

    try validateWorkerCgroupDirFd(cgroup_dir_fd);
    const fd = try common.openReadOnlyAt(cgroup_dir_fd, "memory.events.local");
    return .{
        .fd = fd,
        .cgroup_dir = cgroup_dir,
    };
}
