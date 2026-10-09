//! The delegated cgroup v2 subtree that holds one leaf per worker.
//!
//! Workers are born directly inside a pre-created, pre-configured cgroup via
//! `clone3(CLONE_INTO_CGROUP)`, so the host must own a process-free
//! delegated directory it can create leaves under. cgroup v2's
//! no-internal-process rule forbids enabling controllers on a cgroup that
//! still holds processes, which is what the two placements are about: a
//! delegated host moves itself into `<own>/main` and enables controllers on
//! `<own>` before creating `<own>/workers`; an env-root host is handed a
//! process-free directory that already sits under delegation.
//!
//! An env-root host never creates leaves directly in the directory it was
//! handed: it claims `host-<pid>-<start>-<n>/` under it and keeps every
//! `worker-<id>` in there, so a `collo serve` server, a test binary and a
//! bench can share one delegated parent without reaching each other's
//! workers. Boot reclaims only the directories of hosts that are provably
//! gone: the pid in the name is not running, or its start time (field 22 of
//! `/proc/<pid>/stat`, ticks since boot) differs, which tells a reused pid
//! apart from the host that created the directory. cgroupfs does not survive
//! a reboot, so every `host-*` present was made in this boot, where a
//! (pid, start) pair names one process; `<n>` only separates several roots
//! held by that one process, which the test harness does when it claims one
//! root per launched worker. The proof reads `/proc` of this pid namespace,
//! so hosts that share a parent must share the pid namespace: a live host in
//! another one would have no visible pid and be judged gone. A `worker-*`
//! sitting directly under the parent has no owner the host can identify and
//! is left alone.

const std = @import("std");
const common = @import("collo_cgroup");
const fd_mod = @import("collo_os").fd;
const process = @import("collo_os").process;

const worker_dir_prefix = "worker-";
// "worker-" + u64 in decimal (max 20 digits) + null margin.
const worker_dir_name_max = worker_dir_prefix.len + 20;
const host_dir_prefix = "host-";
// "host-" + u32 pid + "-" + u64 start ticks + "-" + u32 claim number, all decimal.
const host_dir_name_max = host_dir_prefix.len + 10 + 1 + 20 + 1 + 10;
/// Upper bound on the roots one process can hold under one parent; the
/// claim tries `<n>` = 1, 2, ... until the filesystem accepts the name.
const host_dir_claim_max_attempts: u32 = 4096;
const controller_enable = "+memory +cpu +pids";
const rmdir_max_attempts: u32 = 50;
const rmdir_retry_interval_ns: u64 = 10 * std.time.ns_per_ms;
const cgroup_kill_file = "cgroup.kill";

pub const Mode = enum { delegated, env_root };

pub const Placement = union(enum) {
    /// Carve `<own>/main` and `<own>/workers` out of the process's current
    /// cgroup. Requires that cgroup to be delegated to the caller and to hold
    /// no other process, which is the production shape under systemd.
    delegated,
    /// An existing delegated, process-free cgroup directory under which this
    /// host claims its own `host-*` directory for its `worker-<id>` leaves;
    /// controllers are enabled on both here. The development shape: the WSL
    /// runner exports one, and a test process shares its own cgroup with
    /// the build that spawned it.
    env_root: []const u8,
};

pub const WorkerCgroupRoot = struct {
    mode: Mode,
    /// Absolute path of the directory that holds every `worker-<id>` leaf:
    /// `<own>/workers` when delegated, this host's `host-*` directory under
    /// the env root otherwise.
    workers_dir_path: []u8,
    /// O_DIRECTORY handle to `workers_dir_path` for fd-relative create/remove.
    workers_dir_fd: std.posix.fd_t,

    /// `error.WorkerCgroupDelegationUnavailable` names every way the
    /// placement can be unusable (no cgroup2 mount, a non-delegated parent,
    /// controllers that refuse to enable); a host that cannot bound worker
    /// memory must not serve, so nothing here degrades.
    pub fn init(allocator: std.mem.Allocator, placement: Placement) !WorkerCgroupRoot {
        return switch (placement) {
            .delegated => initDelegated(allocator),
            .env_root => |root| initEnvRoot(allocator, root),
        };
    }

    fn initEnvRoot(allocator: std.mem.Allocator, env_root: []const u8) !WorkerCgroupRoot {
        common.path.validateRoot(common.path.CGROUP2_MOUNT_PATH) catch
            return error.WorkerCgroupDelegationUnavailable;
        const parent_fd = common.path.openDir(env_root) catch
            return error.WorkerCgroupDelegationUnavailable;
        defer std.posix.close(parent_fd);
        try validateCgroup2DirFd(parent_fd);
        // Enabled on the parent so the host directory below can enable them
        // in turn for its leaves.
        enableSubtreeControllersAt(parent_fd) catch
            return error.WorkerCgroupDelegationUnavailable;

        var root = claimHostDir(allocator, parent_fd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("failed to claim a host cgroup dir under {s}: {s}", .{
                    env_root,
                    @errorName(err),
                });
                return error.WorkerCgroupDelegationUnavailable;
            },
        };
        errdefer root.deinit(allocator);
        enableSubtreeControllersAt(root.workers_dir_fd) catch
            return error.WorkerCgroupDelegationUnavailable;
        return root;
    }

    fn initDelegated(allocator: std.mem.Allocator) !WorkerCgroupRoot {
        common.path.validateRoot(common.path.CGROUP2_MOUNT_PATH) catch
            return error.WorkerCgroupDelegationUnavailable;

        const own_relative = common.path.currentUnified(allocator) catch
            return error.WorkerCgroupDelegationUnavailable;
        defer allocator.free(own_relative);
        const own_dir = try joinAbsolute(allocator, own_relative);
        defer allocator.free(own_dir);

        const main_dir = try std.fmt.allocPrint(allocator, "{s}/main", .{own_dir});
        defer allocator.free(main_dir);
        const workers_dir_path = try std.fmt.allocPrint(allocator, "{s}/workers", .{own_dir});
        errdefer allocator.free(workers_dir_path);

        prepareDelegatedSubtree(own_dir, main_dir, workers_dir_path) catch
            return error.WorkerCgroupDelegationUnavailable;

        const workers_dir_fd = common.path.openDir(workers_dir_path) catch
            return error.WorkerCgroupDelegationUnavailable;
        errdefer std.posix.close(workers_dir_fd);

        // Fork job ids restart at 1 each boot, so a leaf left by a crash
        // would collide with a fresh id; `<own>/workers` is this process's
        // alone, which is what makes clearing it safe.
        removeWorkerDirsUnder(workers_dir_fd);
        return .{
            .mode = .delegated,
            .workers_dir_path = workers_dir_path,
            .workers_dir_fd = workers_dir_fd,
        };
    }

    /// The directory half of an env-root boot: reclaims the directories of
    /// dead hosts under `parent_fd`, then creates and opens this host's own
    /// `host-<pid>-<start>-<n>` there. It uses directory syscalls only, so
    /// it holds over any directory; cgroupfs specifics (the controllers)
    /// belong to `initEnvRoot`.
    pub fn claimHostDir(allocator: std.mem.Allocator, parent_fd: std.posix.fd_t) !WorkerCgroupRoot {
        sweepDeadHostDirs(parent_fd);

        const owner = HostIdentity{
            .pid = @intCast(std.os.linux.getpid()),
            .start_ticks = try process.selfStartTicks(),
        };
        var claim: u32 = 1;
        while (claim <= host_dir_claim_max_attempts) : (claim += 1) {
            var name_buffer: [host_dir_name_max + 1]u8 = undefined;
            const name = hostDirName(&name_buffer, owner, claim);
            std.posix.mkdirat(parent_fd, name, 0o755) catch |err| switch (err) {
                // The sweep above reclaimed every dead host's directory, so
                // only another root of this very process can be in the way.
                error.PathAlreadyExists => continue,
                else => return err,
            };
            errdefer removeDirWithRetry(.{ .at = .{ .parent_fd = parent_fd, .name = name } });
            // The sweep must read back exactly the identity written here.
            const parsed = parseHostDirName(name) orelse unreachable;
            std.debug.assert(parsed.pid == owner.pid and parsed.start_ticks == owner.start_ticks);

            const workers_dir_fd = try openDirAt(parent_fd, name);
            errdefer std.posix.close(workers_dir_fd);
            // The path comes from the fd, canonical, so it agrees with the
            // leaf paths the launch resolves the same way even when the env
            // root was named with a trailing slash or through a symlink.
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const workers_dir_path = try allocator.dupe(
                u8,
                try fd_mod.procFdTarget(workers_dir_fd, &path_buffer),
            );
            return .{
                .mode = .env_root,
                .workers_dir_path = workers_dir_path,
                .workers_dir_fd = workers_dir_fd,
            };
        }
        return error.HostDirClaimExhausted;
    }

    pub fn deinit(self: *WorkerCgroupRoot, allocator: std.mem.Allocator) void {
        switch (self.mode) {
            .delegated => std.posix.close(self.workers_dir_fd),
            // The host directory is this process's alone, so a leaf still
            // inside belongs to a worker nobody else will ever reap, and the
            // directory itself goes now rather than waiting for a later host
            // to prove this one dead.
            .env_root => {
                removeWorkerDirsUnder(self.workers_dir_fd);
                std.posix.close(self.workers_dir_fd);
                removeDirWithRetry(.{ .path = self.workers_dir_path });
            },
        }
        allocator.free(self.workers_dir_path);
        self.* = undefined;
    }

    /// Creates and configures `worker-<fork_job_id>/` under the subtree and
    /// returns an owned O_DIRECTORY fd. The fd is later passed to the fork
    /// request (CLONE_INTO_CGROUP) and reused for the limit rewrite at adoption.
    pub fn createWorkerDir(
        self: *WorkerCgroupRoot,
        fork_job_id: u64,
        limits: common.worker.Limits,
    ) !std.posix.fd_t {
        try common.worker.validateLimitsConfig(limits);
        var name_buffer: [worker_dir_name_max + 1]u8 = undefined;
        const name = workerDirName(&name_buffer, fork_job_id);

        std.posix.mkdirat(self.workers_dir_fd, name, 0o755) catch |err| switch (err) {
            // A leftover under this host's own directory: a job id reused
            // after a cleanup that raced or failed. Reclaim it and retry once
            // so a fresh job id is not lost.
            error.PathAlreadyExists => {
                removeWorkerDirAt(self.workers_dir_fd, name);
                try std.posix.mkdirat(self.workers_dir_fd, name, 0o755);
            },
            else => return err,
        };
        errdefer removeWorkerDirAt(self.workers_dir_fd, name);

        const dir_fd = try openDirAt(self.workers_dir_fd, name);
        errdefer std.posix.close(dir_fd);

        try common.worker.configureLimitsAt(dir_fd, limits);
        return dir_fd;
    }

    pub fn removeWorkerDir(self: *WorkerCgroupRoot, fork_job_id: u64) void {
        var name_buffer: [worker_dir_name_max + 1]u8 = undefined;
        const name = workerDirName(&name_buffer, fork_job_id);
        removeWorkerDirAt(self.workers_dir_fd, name);
    }
};

const HostIdentity = struct {
    pid: u32,
    start_ticks: u64,
};

/// Reclaims, under `parent_fd`, every `host-*` directory whose owner is
/// provably gone, worker leaves included. Directories of live hosts, names
/// this host cannot attribute, and ownerless `worker-*` entries stay.
pub fn sweepDeadHostDirs(parent_fd: std.posix.fd_t) void {
    const iterator_fd = openIterable(parent_fd) catch |err| {
        std.log.warn("failed to reopen cgroup parent dir for host sweep: {s}", .{
            @errorName(err),
        });
        return;
    };
    defer std.posix.close(iterator_fd);

    var dir = std.fs.Dir{ .fd = iterator_fd };
    var iterator = dir.iterate();
    while (iterator.next() catch null) |entry| {
        if (entry.kind != .directory)
            continue;
        if (!std.mem.startsWith(u8, entry.name, host_dir_prefix))
            continue;
        const owner = parseHostDirName(entry.name) orelse {
            std.log.debug("leaving unattributable host cgroup dir {s}", .{entry.name});
            continue;
        };
        if (hostIsGone(owner))
            reapHostDirAt(parent_fd, entry.name);
    }
}

/// True only when the process that created a host directory is certainly
/// gone: no process has its pid, or the pid belongs to a later incarnation.
/// A pid that cannot be inspected counts as alive, since it may still be
/// serving workers.
fn hostIsGone(owner: HostIdentity) bool {
    const start_ticks = process.processStartTicks(owner.pid) catch |err| switch (err) {
        error.ProcessNotFound => return true,
        else => {
            std.log.debug("cannot inspect host pid {d} for the cgroup sweep: {s}", .{
                owner.pid,
                @errorName(err),
            });
            return false;
        },
    };
    return start_ticks != owner.start_ticks;
}

fn reapHostDirAt(parent_fd: std.posix.fd_t, name: []const u8) void {
    if (openDirAt(parent_fd, name)) |host_dir_fd| {
        defer std.posix.close(host_dir_fd);
        removeWorkerDirsUnder(host_dir_fd);
    } else |err| {
        std.log.warn("failed to open dead host cgroup dir {s}: {s}", .{ name, @errorName(err) });
    }
    removeDirWithRetry(.{ .at = .{ .parent_fd = parent_fd, .name = name } });
}

/// Kills and removes every `worker-*` leaf directly under `dir_fd`, with no
/// ownership check: the caller must hold the directory exclusively, as a
/// delegated `<own>/workers`, this host's own `host-*` directory, or one
/// whose owner the sweep has proven dead.
pub fn removeWorkerDirsUnder(dir_fd: std.posix.fd_t) void {
    const iterator_fd = openIterable(dir_fd) catch |err| {
        std.log.warn("failed to reopen worker cgroup dir for sweep: {s}", .{
            @errorName(err),
        });
        return;
    };
    defer std.posix.close(iterator_fd);

    var dir = std.fs.Dir{ .fd = iterator_fd };
    var iterator = dir.iterate();
    while (iterator.next() catch null) |entry| {
        if (entry.kind != .directory)
            continue;
        if (!std.mem.startsWith(u8, entry.name, worker_dir_prefix))
            continue;
        removeWorkerDirAt(dir_fd, entry.name);
    }
}

/// Best-effort: a still-populated cgroup blocks rmdir until its lone member
/// is reaped, so residents are killed first and the rmdir retried.
fn removeWorkerDirAt(parent_fd: std.posix.fd_t, name: []const u8) void {
    killWorkerCgroupAt(parent_fd, name);
    removeDirWithRetry(.{ .at = .{ .parent_fd = parent_fd, .name = name } });
}

/// A directory to remove, named relative to an open parent (the sweeps and
/// the leaf helpers) or by absolute path (a handle that only kept the path).
const DirTarget = union(enum) {
    at: struct { parent_fd: std.posix.fd_t, name: []const u8 },
    path: []const u8,

    fn rmdir(self: DirTarget) !void {
        switch (self) {
            .at => |at| try std.posix.unlinkat(at.parent_fd, at.name, std.posix.AT.REMOVEDIR),
            .path => |path| try std.posix.rmdir(path),
        }
    }

    /// The target for a log line. Only a diagnostic, so an unreadable fd link
    /// degrades to a placeholder instead of an error.
    fn describe(self: DirTarget, buffer: []u8) []const u8 {
        switch (self) {
            .at => |at| {
                var parent_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const parent = fd_mod.procFdTarget(at.parent_fd, &parent_buffer) catch
                    "<unresolved>";
                return std.fmt.bufPrint(buffer, "{s}/{s}", .{ parent, at.name }) catch
                    "<unresolved>";
            },
            .path => |path| return path,
        }
    }
};

/// The one rmdir policy: a still-populated cgroup refuses rmdir until its
/// residents are reaped, so busy and non-empty are retried a bounded number
/// of times; any other failure is logged and left for the next sweep.
fn removeDirWithRetry(target: DirTarget) void {
    var attempt: u32 = 0;
    while (attempt < rmdir_max_attempts) : (attempt += 1) {
        target.rmdir() catch |err| switch (err) {
            error.FileNotFound => return,
            error.DirNotEmpty, error.FileBusy => {
                std.Thread.sleep(rmdir_retry_interval_ns);
                continue;
            },
            else => {
                var buffer: [std.fs.max_path_bytes + 1 + std.fs.max_name_bytes]u8 = undefined;
                std.log.warn("failed to remove cgroup dir {s}: {s}", .{
                    target.describe(&buffer),
                    @errorName(err),
                });
                return;
            },
        };
        return;
    }
    var buffer: [std.fs.max_path_bytes + 1 + std.fs.max_name_bytes]u8 = undefined;
    std.log.warn("cgroup dir {s} busy after {d} rmdir attempts; left for the next sweep", .{
        target.describe(&buffer),
        rmdir_max_attempts,
    });
}

/// Kill plus a single rmdir for a leaf the host holds only as an fd: `.busy`
/// sends a non-blocking caller to its own retry timer instead of the
/// `rmdir_max_attempts` loop below. The fd stays the caller's to close.
pub fn reapWorkerCgroupOnceByFd(dir_fd: std.posix.fd_t) enum { done, busy } {
    killWorkerCgroupByFd(dir_fd);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buffer, "/proc/self/fd/{d}", .{dir_fd}) catch return .done;
    const dir_path = std.posix.readlink(link, &path_buffer) catch return .done;
    std.posix.rmdir(dir_path) catch |err| switch (err) {
        error.FileNotFound => return .done,
        error.DirNotEmpty, error.FileBusy => return .busy,
        else => {
            std.log.warn("failed to remove worker cgroup {s}: {s}", .{ dir_path, @errorName(err) });
            return .done;
        },
    };
    return .done;
}

/// Blocking cleanup for a leaf the host holds only as an fd (a fork that
/// never reached WorkerInit): kills residents, resolves the path from the
/// fd, removes the directory with bounded retry. The fd stays the caller's
/// to close.
pub fn reapWorkerCgroupByFd(dir_fd: std.posix.fd_t) void {
    killWorkerCgroupByFd(dir_fd);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buffer, "/proc/self/fd/{d}", .{dir_fd}) catch return;
    const dir_path = std.posix.readlink(link, &path_buffer) catch return;
    removeDirWithRetry(.{ .path = dir_path });
}

/// Blocking cleanup for a leaf the host holds as a path (a live worker's
/// handle): kills residents, then removes the directory with bounded retry.
pub fn reapWorkerCgroupByPath(dir_path: []const u8) void {
    killWorkerCgroupByPath(dir_path);
    removeDirWithRetry(.{ .path = dir_path });
}

fn killWorkerCgroupByFd(dir_fd: std.posix.fd_t) void {
    const fd = common.openWriteOnlyAt(dir_fd, cgroup_kill_file) catch return;
    defer std.posix.close(fd);
    // Best-effort: the rmdir retry still reclaims the dir once the worker
    // exits on its own, so a failed kill only slows cleanup, never corrupts it.
    writeAll(fd, "1") catch |err|
        std.log.debug("cgroup.kill write failed: {s}", .{@errorName(err)});
}

fn killWorkerCgroupByPath(dir_path: []const u8) void {
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const kill_path = std.fmt.bufPrint(&name_buffer, "{s}/{s}", .{ dir_path, cgroup_kill_file }) catch return;
    const fd = std.posix.open(kill_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch return;
    defer std.posix.close(fd);
    writeAll(fd, "1") catch |err|
        std.log.debug("cgroup.kill write failed: {s}", .{@errorName(err)});
}

fn killWorkerCgroupAt(parent_dir_fd: std.posix.fd_t, name: []const u8) void {
    const dir_fd = openDirAt(parent_dir_fd, name) catch return;
    defer std.posix.close(dir_fd);
    killWorkerCgroupByFd(dir_fd);
}

/// A directory fd that `std.fs.Dir.iterate` accepts. The caller's fd may be
/// `O_PATH` (std.fs opens non-iterating directories that way), and an
/// `O_PATH` fd cannot be read or seeked, so the directory is reopened
/// through it instead of duplicated.
fn openIterable(dir_fd: std.posix.fd_t) !std.posix.fd_t {
    return openDirAt(dir_fd, ".");
}

fn openDirAt(parent_fd: std.posix.fd_t, name: []const u8) !std.posix.fd_t {
    return std.posix.openat(parent_fd, name, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    }, 0);
}

fn prepareDelegatedSubtree(own_dir: []const u8, main_dir: []const u8, workers_dir: []const u8) !void {
    // Move self into <own>/main so <own> becomes process-free. This runs once
    // at boot, before any child process exists: a child left in <own> would
    // keep its controllers from being enabled, while every thread of this
    // process moves with it.
    makeDirAbsolute(main_dir);
    try moveSelfInto(main_dir);
    try enableSubtreeControllers(own_dir);
    makeDirAbsolute(workers_dir);
    try enableSubtreeControllers(workers_dir);
}

fn moveSelfInto(dir: []const u8) !void {
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const procs_path = std.fmt.bufPrint(&name_buffer, "{s}/cgroup.procs", .{dir}) catch
        return error.WorkerCgroupDelegationUnavailable;
    const fd = std.posix.open(procs_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch
        return error.WorkerCgroupDelegationUnavailable;
    defer std.posix.close(fd);
    // "0" migrates the calling process (all of its threads) into the cgroup.
    writeAll(fd, "0") catch return error.WorkerCgroupDelegationUnavailable;
}

fn enableSubtreeControllers(dir: []const u8) !void {
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const control_path = std.fmt.bufPrint(&name_buffer, "{s}/cgroup.subtree_control", .{dir}) catch
        return error.WorkerCgroupDelegationUnavailable;
    const fd = std.posix.open(control_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch
        return error.WorkerCgroupDelegationUnavailable;
    defer std.posix.close(fd);
    writeAll(fd, controller_enable) catch return error.WorkerCgroupDelegationUnavailable;
}

fn enableSubtreeControllersAt(dir_fd: std.posix.fd_t) !void {
    const fd = common.openWriteOnlyAt(dir_fd, "cgroup.subtree_control") catch
        return error.WorkerCgroupDelegationUnavailable;
    defer std.posix.close(fd);
    writeAll(fd, controller_enable) catch return error.WorkerCgroupDelegationUnavailable;
}

fn makeDirAbsolute(dir: []const u8) void {
    std.posix.mkdir(dir, 0o755) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => std.log.warn("failed to create cgroup dir {s}: {s}", .{ dir, @errorName(err) }),
    };
}

fn joinAbsolute(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const trimmed = std.mem.trimLeft(u8, relative, "/");
    if (trimmed.len == 0)
        return allocator.dupe(u8, common.path.CGROUP2_MOUNT_PATH);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ common.path.CGROUP2_MOUNT_PATH, trimmed });
}

fn validateCgroup2DirFd(dir_fd: std.posix.fd_t) !void {
    const stat = std.posix.fstat(dir_fd) catch return error.WorkerCgroupDelegationUnavailable;
    if ((stat.mode & std.os.linux.S.IFMT) != std.os.linux.S.IFDIR)
        return error.WorkerCgroupDelegationUnavailable;
}

fn workerDirName(buffer: []u8, fork_job_id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}{d}", .{ worker_dir_prefix, fork_job_id }) catch unreachable;
}

fn hostDirName(buffer: []u8, owner: HostIdentity, claim: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}{d}-{d}-{d}", .{
        host_dir_prefix,
        owner.pid,
        owner.start_ticks,
        claim,
    }) catch unreachable;
}

/// The owner named by a `host-<pid>-<start>-<n>` entry; null for any other
/// shape, which the sweep leaves in place.
fn parseHostDirName(name: []const u8) ?HostIdentity {
    if (!std.mem.startsWith(u8, name, host_dir_prefix))
        return null;
    var fields = std.mem.splitScalar(u8, name[host_dir_prefix.len..], '-');
    const pid_field = fields.next() orelse return null;
    const start_field = fields.next() orelse return null;
    const claim_field = fields.next() orelse return null;
    if (fields.next() != null)
        return null;
    const pid = std.fmt.parseUnsigned(u32, pid_field, 10) catch return null;
    const start_ticks = std.fmt.parseUnsigned(u64, start_field, 10) catch return null;
    _ = std.fmt.parseUnsigned(u32, claim_field, 10) catch return null;
    return .{ .pid = pid, .start_ticks = start_ticks };
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = try std.posix.write(fd, remaining);
        if (written == 0)
            return error.ShortWrite;
        remaining = remaining[written..];
    }
}
