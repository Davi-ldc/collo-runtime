//! The worker sandbox without a full worker: the root a forked child builds
//! inside fresh namespaces (its layout and modes, read-only but for `/tmp`,
//! its mounts' flags, which the capability drop alone keeps from any
//! remount, and its absence from the host's `/tmp`), and the seccomp filter,
//! checked in the emitted program and by installing it in forked children
//! that probe what it allows, denies and filters by argument, and whether a
//! thread created before it can still start, and name itself, under it. The
//! `zygote-integration` lane covers a real worker booting into the sandbox
//! and its root as `node:fs` sees it.

const std = @import("std");
const builtin = @import("builtin");
const zygote = @import("collo_zygote");
const support = @import("zygote_support");

const sandbox = zygote.worker_boot.sandbox;

extern fn pthread_attr_setaffinity_np(
    attr: *std.c.pthread_attr_t,
    cpuset_size: usize,
    cpuset: *const std.os.linux.cpu_set_t,
) c_int;

/// What the child of the root test found, one bit per probe.
const RootProbe = enum(u4) {
    working_directory_is_task_root,
    root_is_private_directory,
    task_root_is_read_only_directory,
    root_lists_tmp_and_var,
    create_in_root_is_erofs,
    mkdir_in_var_is_erofs,
    unlink_in_task_root_is_erofs,
    tmp_is_writable,
    rename_out_of_tmp_is_exdev,
    host_file_is_absent,
    marker_written,
    root_mount_is_read_only_nosuid_nodev_noexec,
    tmp_mount_is_writable_nosuid_nodev_noexec,
    root_remount_is_eperm,
    tmp_remount_is_eperm,
};

comptime {
    // The probes report through a u16 whose all-ones value means a skip.
    std.debug.assert(@typeInfo(RootProbe).@"enum".fields.len < 16);
}

/// The kernel's `struct statfs` on the 64-bit targets, for the raw `statfs`.
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

/// The mount flags `statfs` reports in `f_flags` (the kernel's `ST_*`).
const st_rdonly: c_long = 0x1;
const st_nosuid: c_long = 0x2;
const st_nodev: c_long = 0x4;
const st_noexec: c_long = 0x8;

test "a sandboxed child's root holds tmp and var/task, is read-only but for /tmp, keeps nosuid, nodev and noexec on both, cannot be remounted without capabilities, and leaves the host's /tmp alone" {
    const skip_result: u16 = 0xffff;
    const expected_result: u16 = (1 << @typeInfo(RootProbe).@"enum".fields.len) - 1;
    // The child writes this name into its /tmp, which must stay out of the
    // host's.
    const marker_path = try support.makeTempPath(std.testing.allocator, "collo-sandbox-marker");
    defer std.testing.allocator.free(marker_path);
    const marker_path_z = try std.testing.allocator.dupeZ(u8, marker_path);
    defer std.testing.allocator.free(marker_path_z);
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);
        rootProbeChild(pipe_pair[1], marker_path_z, skip_result);
    }

    std.posix.close(pipe_pair[1]);
    var result_bytes: [2]u8 = undefined;
    const read_len = try std.posix.read(pipe_pair[0], &result_bytes);
    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
    try std.testing.expectEqual(@as(usize, 2), read_len);
    const result = std.mem.readInt(u16, &result_bytes, .little);
    if (result == skip_result)
        return error.SkipZigTest;
    inline for (@typeInfo(RootProbe).@"enum".fields) |field| {
        if (result & (@as(u16, 1) << field.value) == 0)
            std.debug.print("the sandboxed root failed the probe {s}\n", .{field.name});
    }
    try std.testing.expectEqual(expected_result, result);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(marker_path, .{}));
}

/// Enters fresh namespaces, builds the worker's root as a worker child does
/// (`applyPreThread`) and reports what it finds there, its mounts' flags
/// and whether it can remount them included.
fn rootProbeChild(result_fd: std.posix.fd_t, marker_path: [*:0]const u8, skip_result: u16) noreturn {
    const linux = std.os.linux;
    sandbox.applyPostForkNamespaces() catch |err| switch (err) {
        // No unprivileged user namespaces on this host.
        error.PermissionDenied, error.UnsupportedKernel => writeRootProbeResult(result_fd, skip_result),
        else => childExit(191),
    };
    sandbox.applyPreThread(.{ .tmpfs_size_bytes = 1024 * 1024 }) catch childExit(192);

    var result: u16 = 0;
    var cwd_buffer: [64]u8 = undefined;
    // A failed read leaves the probe's bit clear.
    const cwd = std.posix.getcwd(&cwd_buffer) catch "";
    if (std.mem.eql(u8, cwd, sandbox.task_root))
        result |= rootProbeBit(.working_directory_is_task_root);
    if (directoryMode("/") == 0o700)
        result |= rootProbeBit(.root_is_private_directory);
    if (directoryMode(sandbox.task_root) == 0o755)
        result |= rootProbeBit(.task_root_is_read_only_directory);
    if (rootListsTmpAndVar())
        result |= rootProbeBit(.root_lists_tmp_and_var);
    const create_rc = linux.openat(linux.AT.FDCWD, "/created", .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (linux.E.init(create_rc) == .ROFS)
        result |= rootProbeBit(.create_in_root_is_erofs);
    if (linux.E.init(linux.mkdirat(linux.AT.FDCWD, "/var/made", 0o755)) == .ROFS)
        result |= rootProbeBit(.mkdir_in_var_is_erofs);
    if (linux.E.init(linux.unlinkat(linux.AT.FDCWD, "/var/task/missing", 0)) == .ROFS)
        result |= rootProbeBit(.unlink_in_task_root_is_erofs);
    if (writeFile("/tmp/probe"))
        result |= rootProbeBit(.tmp_is_writable);
    if (linux.E.init(linux.renameat(linux.AT.FDCWD, "/tmp/probe", linux.AT.FDCWD, "/var/task/probe")) == .XDEV)
        result |= rootProbeBit(.rename_out_of_tmp_is_exdev);
    var stat: linux.Stat = undefined;
    if (linux.E.init(linux.fstatat(linux.AT.FDCWD, "/etc/passwd", &stat, 0)) == .NOENT)
        result |= rootProbeBit(.host_file_is_absent);
    if (writeFile(marker_path))
        result |= rootProbeBit(.marker_written);
    // The bind gave `/tmp` the tmpfs mount's flags, and the remount kept
    // them on the root alongside read-only.
    if (mountFlagsAre("/", st_rdonly | st_nosuid | st_nodev | st_noexec))
        result |= rootProbeBit(.root_mount_is_read_only_nosuid_nodev_noexec);
    if (mountFlagsAre("/tmp", st_nosuid | st_nodev | st_noexec))
        result |= rootProbeBit(.tmp_mount_is_writable_nosuid_nodev_noexec);
    // No filter is installed here, so these probe the capability drop
    // alone: without CAP_SYS_ADMIN over its mount namespace the child can
    // turn neither the root writable nor `/tmp` read-only. They come last,
    // so a remount that wrongly succeeds changes no probe above.
    if (linux.E.init(linux.mount(null, "/", null, linux.MS.REMOUNT | linux.MS.BIND, 0)) == .PERM)
        result |= rootProbeBit(.root_remount_is_eperm);
    if (linux.E.init(linux.mount(null, "/tmp", null, linux.MS.REMOUNT | linux.MS.BIND | linux.MS.RDONLY, 0)) == .PERM)
        result |= rootProbeBit(.tmp_remount_is_eperm);
    writeRootProbeResult(result_fd, result);
}

/// Whether the mount at `path` reports exactly `expected` among read-only,
/// nosuid, nodev and noexec.
fn mountFlagsAre(path: [*:0]const u8, expected: c_long) bool {
    const linux = std.os.linux;
    var fs: Statfs = undefined;
    if (linux.E.init(linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&fs))) != .SUCCESS)
        return false;
    return (fs.f_flags & (st_rdonly | st_nosuid | st_nodev | st_noexec)) == expected;
}

fn rootProbeBit(probe: RootProbe) u16 {
    return @as(u16, 1) << @intFromEnum(probe);
}

fn writeRootProbeResult(fd: std.posix.fd_t, result: u16) noreturn {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, result, .little);
    const rc = std.os.linux.write(fd, &bytes, bytes.len);
    if (std.os.linux.E.init(rc) != .SUCCESS or rc != bytes.len)
        childExit(193);
    childExit(0);
}

/// The permission bits of the directory at `path`, or a value no directory
/// of the root has when it is missing or not a directory.
fn directoryMode(path: [*:0]const u8) u32 {
    const linux = std.os.linux;
    var stat: linux.Stat = undefined;
    if (linux.E.init(linux.fstatat(linux.AT.FDCWD, path, &stat, 0)) != .SUCCESS)
        return 0o10000;
    if ((stat.mode & linux.S.IFMT) != linux.S.IFDIR)
        return 0o10000;
    return stat.mode & 0o7777;
}

fn rootListsTmpAndVar() bool {
    var root = std.fs.openDirAbsolute("/", .{ .iterate = true }) catch return false;
    defer root.close();
    var saw_tmp = false;
    var saw_var = false;
    var entries = root.iterate();
    while (entries.next() catch return false) |entry| {
        if (std.mem.eql(u8, entry.name, "tmp")) {
            saw_tmp = true;
        } else if (std.mem.eql(u8, entry.name, "var")) {
            saw_var = true;
        } else {
            return false;
        }
    }
    return saw_tmp and saw_var;
}

fn writeFile(path: [*:0]const u8) bool {
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.E.init(rc) != .SUCCESS)
        return false;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const written = linux.write(fd, "probe", 5);
    return linux.E.init(written) == .SUCCESS and written == 5;
}

test "the worker filter denies every call that creates authority or escapes, io_uring and timerfd included, and allows the runtime's own" {
    // Evaluates the emitted program, so the verdict is the kernel's for every
    // call whether or not this host can install a filter. Arguments are zero,
    // so this list holds no call the filter narrows by argument.
    const authority_creating_or_escape_syscalls = [_][]const u8{
        "socket",
        "connect",
        "accept4",
        "sendmmsg",
        "recvmmsg",
        "getsockopt",
        "setsockopt",
        "io_uring_setup",
        "io_uring_register",
        "dup",
        "dup2",
        "dup3",
        "pidfd_getfd",
        "open",
        "creat",
        "open_by_handle_at",
        "name_to_handle_at",
        "clone",
        "fork",
        "execve",
        "chroot",
        "pivot_root",
        "mount",
        "umount2",
        "setns",
        "unshare",
        "fchdir",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait2",
        "bpf",
        "ptrace",
        "prlimit64",
        "io_uring_enter",
        "timerfd_create",
        "timerfd_settime",
        "ftruncate",
        "eventfd2",
        "memfd_create",
        "kill",
        "tgkill",
        "process_vm_readv",
        "seccomp",
        "fchmod",
        "fchmodat",
        "mount_setattr",
        "open_tree",
        "move_mount",
        "fsopen",
    };
    const denied = std.os.linux.SECCOMP.RET.ERRNO | @as(u32, @intFromEnum(std.os.linux.E.PERM));
    inline for (authority_creating_or_escape_syscalls) |name| {
        if (comptime @hasField(std.os.linux.SYS, name)) {
            const action = try evaluateZeroArgumentSyscall(name);
            if (action != denied)
                std.debug.print("the worker filter lets {s} through: action=0x{x}\n", .{ name, action });
            try std.testing.expectEqual(denied, action);
        }
    }

    const runtime_syscalls = [_][]const u8{
        "read",
        "write",
        "close",
        "sendmsg",
        "recvmsg",
        "sendto",
        "recvfrom",
        "fstat",
        "pread64",
        "lseek",
        "getdents64",
        "fsync",
        "fdatasync",
        "mmap",
        "munmap",
        "mprotect",
        "futex",
        "clock_gettime",
        "clock_nanosleep",
        "getrandom",
        "poll",
        "ppoll",
        "rseq",
        "set_robust_list",
        "exit",
        "exit_group",
    };
    inline for (runtime_syscalls) |name| {
        if (comptime @hasField(std.os.linux.SYS, name)) {
            const action = try evaluateZeroArgumentSyscall(name);
            if (action != std.os.linux.SECCOMP.RET.ALLOW)
                std.debug.print("the worker filter denies {s}: action=0x{x}\n", .{ name, action });
            try std.testing.expectEqual(std.os.linux.SECCOMP.RET.ALLOW, action);
        }
    }
}

test "worker filter admits path calls only relative to AT_FDCWD, matched on its low int word" {
    // Evaluate the emitted classic-BPF program so every representation and
    // negative case is deterministic even when the host cannot install seccomp.
    const canonical: u64 = 0xffff_ffff_ffff_ff9c;
    const variadic_cpp: u64 = 0x0000_0000_ffff_ff9c;
    const arbitrary_high: u64 = 0x1234_5678_ffff_ff9c;
    const wrong_low: u64 = 0xffff_ffff_ffff_ff9d;
    const program = sandbox.security.instructions;
    const filters = [_]AtFdcwdFilter{
        .init(program, "openat.arg0", syscallNumber("openat"), 0, null),
        .init(program, "newfstatat.arg0", @intCast(@intFromEnum(newFstatAtSyscall())), 0, null),
        .init(program, "statx.arg0", syscallNumber("statx"), 0, null),
        .init(program, "mkdirat.arg0", syscallNumber("mkdirat"), 0, null),
        .init(program, "unlinkat.arg0", syscallNumber("unlinkat"), 0, null),
        .init(program, "renameat2.arg0", syscallNumber("renameat2"), 0, 2),
        .init(program, "renameat2.arg2", syscallNumber("renameat2"), 2, 0),
    };

    for (filters) |filter| {
        try expectAtFdcwdAllowed(filter, canonical);
        try expectAtFdcwdAllowed(filter, variadic_cpp);
        try expectAtFdcwdAllowed(filter, arbitrary_high);
        try expectAtFdcwdDenied(filter, wrong_low);
    }
}

test "worker seccomp admits prctl only for PR_SET_NAME, with a zero high word" {
    // Evaluates the emitted program, so every option is checked even where
    // the host cannot install a filter.
    const linux = std.os.linux;
    const program = sandbox.security.instructions;
    const set_name = prctlOption(.SET_NAME);
    try std.testing.expectEqual(linux.SECCOMP.RET.ALLOW, try evaluatePrctl(program, set_name));

    const denied = linux.SECCOMP.RET.ERRNO | @as(u32, @intFromEnum(linux.E.PERM));
    try std.testing.expectEqual(denied, try evaluatePrctl(program, set_name | (1 << 32)));
    const denied_options = [_]linux.PR{
        .GET_NAME,
        .SET_DUMPABLE,
        .SET_SECCOMP,
        .SET_MM,
        .SET_NO_NEW_PRIVS,
        .CAP_AMBIENT,
    };
    for (denied_options) |option| {
        const action = try evaluatePrctl(program, prctlOption(option));
        if (action != denied)
            std.debug.print("prctl option {s} passed the worker filter: action=0x{x}\n", .{ @tagName(option), action });
        try std.testing.expectEqual(denied, action);
    }
}

test "worker filter enforces the runtime's authority denies in a filtered child" {
    const skip_result: u8 = 0xff;
    const expected_result: u8 = 0b0111_1111;
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);

        const probe_fd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch childExit(121);

        if (!installWorkerFilterForTest())
            writeSkipAndExit(pipe_pair[1], skip_result);

        var result: u8 = 0;
        if (socketDeniedBySeccomp())
            result |= @as(u8, 1) << 0;
        if (fcntlDupDeniedBySeccomp(probe_fd))
            result |= @as(u8, 1) << 1;
        if (fcntlGetFdAllowedBySeccomp(probe_fd))
            result |= @as(u8, 1) << 2;
        if (ioUringEnterDeniedBySeccomp(probe_fd))
            result |= @as(u8, 1) << 3;
        if (openByHandleAtDeniedBySeccomp())
            result |= @as(u8, 1) << 4;
        if (openAtAllowedBySeccomp())
            result |= @as(u8, 1) << 5;
        if (openAtPathFlagDeniedBySeccomp())
            result |= @as(u8, 1) << 6;

        writeSeccompSmokeResult(pipe_pair[1], result) catch childExit(125);
        childExit(0);
    }

    try expectSeccompChildResult(pid, pipe_pair[0], pipe_pair[1], skip_result, expected_result);
}

test "a filtered child gets EPERM from io_uring_setup, io_uring_enter and timerfd_settime on its own descriptors" {
    // The worker waits in ppoll, so no ring and no timerfd may be reached
    // after the filter, not even ones the worker made before it.
    const skip_result: u8 = 0xff;
    const expected_result: u8 = 0b0000_0111;
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);
        const linux = std.os.linux;

        const ring_fd = ringFdForTest() catch childExit(126);
        const timer_fd = std.posix.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }) catch childExit(127);

        if (!installWorkerFilterForTest())
            writeSkipAndExit(pipe_pair[1], skip_result);

        var result: u8 = 0;
        var params = std.mem.zeroes(linux.io_uring_params);
        if (linux.E.init(linux.io_uring_setup(4, &params)) == .PERM)
            result |= @as(u8, 1) << 0;
        if (ioUringEnterDeniedBySeccomp(ring_fd))
            result |= @as(u8, 1) << 1;
        if (timerFdSetTimeDeniedBySeccomp(timer_fd))
            result |= @as(u8, 1) << 2;

        writeSeccompSmokeResult(pipe_pair[1], result) catch childExit(128);
        childExit(0);
    }

    try expectSeccompChildResult(pid, pipe_pair[0], pipe_pair[1], skip_result, expected_result);
}

/// A real io_uring when this host lets the child make one, else an eventfd:
/// the filter must refuse `io_uring_enter` whatever the descriptor is.
fn ringFdForTest() !std.posix.fd_t {
    const linux = std.os.linux;
    var params = std.mem.zeroes(linux.io_uring_params);
    const rc = linux.io_uring_setup(4, &params);
    if (linux.E.init(rc) == .SUCCESS)
        return @intCast(rc);
    return std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
}

/// Sets no-new-privileges and installs the worker's filter in this forked
/// child; false when the host cannot install one, which the test turns into
/// a skip.
fn installWorkerFilterForTest() bool {
    if (!enableNoNewPrivsForSeccompTest())
        return false;
    sandbox.applySeccomp() catch |err| switch (err) {
        error.PermissionDenied, error.UnsupportedKernel => return false,
        else => childExit(124),
    };
    return true;
}

fn writeSkipAndExit(fd: std.posix.fd_t, skip_result: u8) noreturn {
    writeSeccompSmokeResult(fd, skip_result) catch childExit(123);
    childExit(0);
}

/// Reads the one result byte the filtered child `pid` writes, waits for it
/// and expects `expected_result`; a skip byte skips the test.
fn expectSeccompChildResult(
    pid: std.posix.pid_t,
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,
    skip_result: u8,
    expected_result: u8,
) !void {
    std.posix.close(write_fd);
    var result: [1]u8 = undefined;
    const read_len = try std.posix.read(read_fd, &result);

    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
    try std.testing.expectEqual(@as(usize, 1), read_len);
    if (result[0] == skip_result)
        return error.SkipZigTest;
    try std.testing.expectEqual(expected_result, result[0]);
}

test "worker filter pins stat-at calls to AT_FDCWD paths in a filtered child" {
    const skip_result: u8 = 0xff;
    const expected_result: u8 = 0b0011_1111;
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);

        const probe_fd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch childExit(131);

        if (!installWorkerFilterForTest())
            writeSkipAndExit(pipe_pair[1], skip_result);

        var result: u8 = 0;
        if (newFstatAtAllowedBySeccomp())
            result |= @as(u8, 1) << 0;
        if (newFstatAtDirfdDeniedBySeccomp(probe_fd))
            result |= @as(u8, 1) << 1;
        if (newFstatAtEmptyPathDeniedBySeccomp())
            result |= @as(u8, 1) << 2;
        if (statxAllowedBySeccomp())
            result |= @as(u8, 1) << 3;
        if (statxDirfdDeniedBySeccomp(probe_fd))
            result |= @as(u8, 1) << 4;
        if (statxEmptyPathDeniedBySeccomp())
            result |= @as(u8, 1) << 5;

        writeSeccompSmokeResult(pipe_pair[1], result) catch childExit(135);
        childExit(0);
    }

    try expectSeccompChildResult(pid, pipe_pair[0], pipe_pair[1], skip_result, expected_result);
}

test "worker filter lets a thread rename itself and denies every other prctl in a filtered child" {
    const skip_result: u8 = 0xff;
    const expected_result: u8 = 0b0000_0111;
    const thread_name = "collo-sandbox";
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);

        // Opened before the filter, as a worker has no /proc after its
        // chroot. The forked child has one thread, the one renamed below.
        const comm_fd = std.posix.openZ(
            "/proc/thread-self/comm",
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            0,
        ) catch childExit(183);

        if (!installWorkerFilterForTest())
            writeSkipAndExit(pipe_pair[1], skip_result);

        var result: u8 = 0;
        if (prctlSetNameAllowedBySeccomp(thread_name))
            result |= @as(u8, 1) << 0;
        if (threadCommReads(comm_fd, thread_name))
            result |= @as(u8, 1) << 1;
        if (prctlSetDumpableDeniedBySeccomp())
            result |= @as(u8, 1) << 2;

        writeSeccompSmokeResult(pipe_pair[1], result) catch childExit(186);
        childExit(0);
    }

    try expectSeccompChildResult(pid, pipe_pair[0], pipe_pair[1], skip_result, expected_result);
}

test "worker seccomp lets a thread created before the filter start after it" {
    // Creating a thread does not run it. glibc registers a new thread's rseq
    // area when the thread first runs and aborts the whole process if that
    // fails, and WTF names every thread it starts with prctl(PR_SET_NAME), so
    // a thread a worker creates before its filter but the scheduler first
    // picks after it must still be able to start and name itself.
    //
    // The child makes that order certain. glibc starts a thread whose
    // affinity it must set behind a lock it takes before the clone and drops
    // after the affinity call. A user-notification filter parks the creator
    // inside that call until a supervisor process has seen another thread
    // install the worker filter, so the new thread reaches its rseq
    // registration only under the worker filter.
    const skip_result: u8 = 0xff;
    const result_pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(result_pipe[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(result_pipe[0]);
        startThreadUnderWorkerFilterChild(result_pipe[1], skip_result);
    }

    std.posix.close(result_pipe[1]);
    var result: [1]u8 = undefined;
    const read_len = try std.posix.read(result_pipe[0], &result);

    const wait = std.posix.waitpid(pid, 0);
    if (std.c.W.IFSIGNALED(wait.status)) {
        std.debug.print(
            "seccomp child died by signal {d}: its new thread could not start under the worker filter\n",
            .{std.c.W.TERMSIG(wait.status)},
        );
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
    try std.testing.expectEqual(@as(usize, 1), read_len);
    if (result[0] == skip_result)
        return error.SkipZigTest;
    // 0 means the thread ran before the worker filter, so the creator was
    // never parked and the test proved nothing; 2 means it started under the
    // filter but could not name itself.
    try std.testing.expectEqual(@as(u8, 1), result[0]);
}

/// Bounds the supervisor's wait for the creator's affinity call, so a glibc
/// that stops setting affinity after the clone fails the test instead of
/// hanging it.
const affinity_notification_timeout_ms: i32 = 5_000;

const WorkerFilterInstaller = struct {
    go_fd: std.posix.fd_t,
    installed_fd: std.posix.fd_t,
    installed: std.atomic.Value(bool) = .init(false),
    outcome: Outcome = .not_signaled,

    const Outcome = enum { not_signaled, installed, unsupported };

    fn run(self: *WorkerFilterInstaller) void {
        var go: [1]u8 = undefined;
        const read_len = std.posix.read(self.go_fd, &go) catch childExit(171);
        if (read_len != 1)
            return;
        sandbox.applySeccomp() catch |err| switch (err) {
            error.PermissionDenied, error.UnsupportedKernel => {
                self.outcome = .unsupported;
                writeSeccompSmokeResult(self.installed_fd, 0) catch childExit(172);
                return;
            },
            else => childExit(173),
        };
        self.installed.store(true, .release);
        self.outcome = .installed;
        writeSeccompSmokeResult(self.installed_fd, 1) catch childExit(174);
    }
};

const LateStartThread = struct {
    installer: *const WorkerFilterInstaller,
    started_under_filter: bool = false,
    named: bool = false,
};

fn lateStartThreadMain(context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *LateStartThread = @ptrCast(@alignCast(context.?));
    state.started_under_filter = state.installer.installed.load(.acquire);
    state.named = prctlSetNameAllowedBySeccomp("collo-late");
    return null;
}

fn startThreadUnderWorkerFilterChild(result_fd: std.posix.fd_t, skip_result: u8) noreturn {
    const linux = std.os.linux;
    if (!enableNoNewPrivsForSeccompTest()) {
        writeSeccompSmokeResult(result_fd, skip_result) catch childExit(143);
        childExit(0);
    }
    const go_pipe = std.posix.pipe2(.{ .CLOEXEC = true }) catch childExit(144);
    const installed_pipe = std.posix.pipe2(.{ .CLOEXEC = true }) catch childExit(145);
    const listener = installAffinityNotificationFilter() catch |err| switch (err) {
        error.Unsupported => {
            writeSeccompSmokeResult(result_fd, skip_result) catch childExit(146);
            childExit(0);
        },
        else => childExit(146),
    };

    // The supervisor must sit outside this thread group, which the worker
    // filter covers whole and which may not answer the notification ioctl
    // once the filter is in. Ignoring SIGCHLD reaps it, since wait4 is denied
    // by then too.
    var ignore_children = linux.Sigaction{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    if (linux.E.init(linux.sigaction(linux.SIG.CHLD, &ignore_children, null)) != .SUCCESS)
        childExit(147);
    const supervisor = std.posix.fork() catch childExit(148);
    if (supervisor == 0) {
        std.posix.close(result_fd);
        std.posix.close(go_pipe[0]);
        std.posix.close(installed_pipe[1]);
        superviseAffinityCall(listener, go_pipe[1], installed_pipe[0]);
    }
    // Only the supervisor keeps the listener and these ends, so its death
    // fails the parked call and wakes the installer instead of hanging both.
    std.posix.close(listener);
    std.posix.close(go_pipe[1]);
    std.posix.close(installed_pipe[0]);

    var installer: WorkerFilterInstaller = .{
        .go_fd = go_pipe[0],
        .installed_fd = installed_pipe[1],
    };
    const installer_thread = std.Thread.spawn(.{}, WorkerFilterInstaller.run, .{&installer}) catch childExit(149);

    var allowed: linux.cpu_set_t = undefined;
    if (linux.E.init(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &allowed)) != .SUCCESS)
        childExit(150);
    var attr: std.c.pthread_attr_t = undefined;
    if (std.c.pthread_attr_init(&attr) != .SUCCESS)
        childExit(151);
    if (pthread_attr_setaffinity_np(&attr, @sizeOf(linux.cpu_set_t), &allowed) != 0)
        childExit(152);
    var state: LateStartThread = .{ .installer = &installer };
    var thread: std.c.pthread_t = undefined;
    if (std.c.pthread_create(&thread, &attr, lateStartThreadMain, &state) != .SUCCESS)
        childExit(153);
    installer_thread.join();
    if (std.c.pthread_join(thread, null) != .SUCCESS)
        childExit(154);

    const result: u8 = switch (installer.outcome) {
        .not_signaled => childExit(155),
        .unsupported => skip_result,
        .installed => if (!state.started_under_filter) 0 else if (state.named) 1 else 2,
    };
    writeSeccompSmokeResult(result_fd, result) catch childExit(156);
    childExit(0);
}

/// Installs a filter that hands every sched_setaffinity call to a supervisor
/// and allows everything else; returns the listener.
fn installAffinityNotificationFilter() !std.posix.fd_t {
    const linux = std.os.linux;
    const Instruction = sandbox.security.FilterInstruction;
    const bpf_ld_w_abs: u16 = 0x20;
    const bpf_jmp_jeq_k: u16 = 0x15;
    const bpf_ret_k: u16 = 0x06;
    const program = [_]Instruction{
        .{ .code = bpf_ld_w_abs, .jt = 0, .jf = 0, .k = @offsetOf(linux.SECCOMP.data, "nr") },
        .{ .code = bpf_jmp_jeq_k, .jt = 0, .jf = 1, .k = syscallNumber("sched_setaffinity") },
        .{ .code = bpf_ret_k, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.USER_NOTIF },
        .{ .code = bpf_ret_k, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.ALLOW },
    };
    const Program = extern struct { len: u16, filter: [*]const Instruction };
    const filter: Program = .{ .len = program.len, .filter = &program };
    const rc = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, linux.SECCOMP.FILTER_FLAG.NEW_LISTENER, &filter);
    return switch (linux.E.init(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL, .NOSYS, .ACCES, .PERM => error.Unsupported,
        else => error.NotificationFilterFailed,
    };
}

/// Holds the creator's affinity call until the installer reports the worker
/// filter, then lets the call run.
fn superviseAffinityCall(listener: std.posix.fd_t, go_fd: std.posix.fd_t, installed_fd: std.posix.fd_t) noreturn {
    const linux = std.os.linux;
    var pollfds = [_]std.posix.pollfd{.{ .fd = listener, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pollfds, affinity_notification_timeout_ms) catch childExit(161);
    if (ready == 0)
        childExit(162);
    var request = std.mem.zeroes(linux.SECCOMP.notif);
    if (linux.E.init(linux.ioctl(listener, linux.SECCOMP.IOCTL_NOTIF.RECV, @intFromPtr(&request))) != .SUCCESS)
        childExit(163);
    writeSeccompSmokeResult(go_fd, 1) catch childExit(164);
    var installed: [1]u8 = undefined;
    const read_len = std.posix.read(installed_fd, &installed) catch childExit(165);
    if (read_len != 1)
        childExit(166);
    var response: linux.SECCOMP.notif_resp = .{
        .id = request.id,
        .val = 0,
        .@"error" = 0,
        .flags = linux.SECCOMP.USER_NOTIF_FLAG_CONTINUE,
    };
    if (linux.E.init(linux.ioctl(listener, linux.SECCOMP.IOCTL_NOTIF.SEND, @intFromPtr(&response))) != .SUCCESS)
        childExit(167);
    childExit(0);
}

const AtFdcwdFilter = struct {
    program: []const sandbox.security.FilterInstruction,
    name: []const u8,
    syscall_number: u32,
    dirfd_argument_index: u3,
    peer_dirfd_argument_index: ?u3,

    fn init(
        program: []const sandbox.security.FilterInstruction,
        name: []const u8,
        syscall_number: u32,
        dirfd_argument_index: u3,
        peer_dirfd_argument_index: ?u3,
    ) AtFdcwdFilter {
        return .{
            .program = program,
            .name = name,
            .syscall_number = syscall_number,
            .dirfd_argument_index = dirfd_argument_index,
            .peer_dirfd_argument_index = peer_dirfd_argument_index,
        };
    }
};

fn expectAtFdcwdAllowed(filter: AtFdcwdFilter, argument: u64) !void {
    var data = atFdcwdSeccompData(filter, argument);
    const action = try evaluateSeccompFilter(filter.program, &data);
    if (action != std.os.linux.SECCOMP.RET.ALLOW) {
        std.debug.print(
            "AT_FDCWD seccomp case {s} denied argument 0x{x}: action=0x{x}\n",
            .{ filter.name, argument, action },
        );
    }
    try std.testing.expectEqual(std.os.linux.SECCOMP.RET.ALLOW, action);
}

fn expectAtFdcwdDenied(filter: AtFdcwdFilter, argument: u64) !void {
    const linux = std.os.linux;
    var data = atFdcwdSeccompData(filter, argument);
    const action = try evaluateSeccompFilter(filter.program, &data);
    const expected = linux.SECCOMP.RET.ERRNO | @as(u32, @intFromEnum(linux.E.PERM));
    if (action != expected) {
        std.debug.print(
            "AT_FDCWD seccomp case {s} allowed wrong low word 0x{x}: action=0x{x}\n",
            .{ filter.name, argument, action },
        );
    }
    try std.testing.expectEqual(expected, action);
}

fn atFdcwdSeccompData(filter: AtFdcwdFilter, argument: u64) std.os.linux.SECCOMP.data {
    var data = std.os.linux.SECCOMP.data{
        .nr = @intCast(filter.syscall_number),
        .arch = auditArchCurrent(),
        .instruction_pointer = 0,
        .arg0 = 0,
        .arg1 = 0,
        .arg2 = 0,
        .arg3 = 0,
        .arg4 = 0,
        .arg5 = 0,
    };
    setSeccompArgument(&data, filter.dirfd_argument_index, argument);
    if (filter.peer_dirfd_argument_index) |peer_index| {
        setSeccompArgument(&data, peer_index, 0xffff_ffff_ffff_ff9c);
    }
    return data;
}

fn evaluatePrctl(program: []const sandbox.security.FilterInstruction, option: u64) !u32 {
    const data = std.os.linux.SECCOMP.data{
        .nr = @intCast(syscallNumber("prctl")),
        .arch = auditArchCurrent(),
        .instruction_pointer = 0,
        .arg0 = option,
        .arg1 = 0,
        .arg2 = 0,
        .arg3 = 0,
        .arg4 = 0,
        .arg5 = 0,
    };
    return evaluateSeccompFilter(program, &data);
}

/// The worker filter's action for syscall `name` with every argument zero.
fn evaluateZeroArgumentSyscall(comptime name: []const u8) !u32 {
    const data = std.os.linux.SECCOMP.data{
        .nr = @intCast(syscallNumber(name)),
        .arch = auditArchCurrent(),
        .instruction_pointer = 0,
        .arg0 = 0,
        .arg1 = 0,
        .arg2 = 0,
        .arg3 = 0,
        .arg4 = 0,
        .arg5 = 0,
    };
    return evaluateSeccompFilter(sandbox.security.instructions, &data);
}

/// The option as glibc and Zig pass a positive `int`: zero-extended.
fn prctlOption(option: std.os.linux.PR) u64 {
    return @intCast(@intFromEnum(option));
}

fn setSeccompArgument(data: *std.os.linux.SECCOMP.data, index: u3, value: u64) void {
    switch (index) {
        0 => data.arg0 = value,
        1 => data.arg1 = value,
        2 => data.arg2 = value,
        3 => data.arg3 = value,
        4 => data.arg4 = value,
        5 => data.arg5 = value,
        6, 7 => unreachable,
    }
}

fn evaluateSeccompFilter(
    program: []const sandbox.security.FilterInstruction,
    data: *const std.os.linux.SECCOMP.data,
) !u32 {
    const bpf_ld_w_abs: u16 = 0x20;
    const bpf_jmp_jeq_k: u16 = 0x15;
    const bpf_jmp_jgt_k: u16 = 0x25;
    const bpf_jmp_jge_k: u16 = 0x35;
    const bpf_jmp_jset_k: u16 = 0x45;
    const bpf_ret_k: u16 = 0x06;
    const data_bytes = std.mem.asBytes(data);
    var accumulator: u32 = 0;
    var instruction_index: usize = 0;
    var step_count: usize = 0;

    while (step_count < program.len) : (step_count += 1) {
        if (instruction_index >= program.len)
            return error.InvalidSeccompFilterJump;
        const instruction = program[instruction_index];
        switch (instruction.code) {
            bpf_ld_w_abs => {
                const offset: usize = instruction.k;
                if (offset > data_bytes.len)
                    return error.InvalidSeccompFilterLoad;
                if (data_bytes.len - offset < @sizeOf(u32))
                    return error.InvalidSeccompFilterLoad;
                accumulator = std.mem.readInt(
                    u32,
                    data_bytes[offset..][0..@sizeOf(u32)],
                    builtin.cpu.arch.endian(),
                );
                instruction_index += 1;
            },
            bpf_jmp_jeq_k,
            bpf_jmp_jgt_k,
            bpf_jmp_jge_k,
            bpf_jmp_jset_k,
            => {
                const condition = switch (instruction.code) {
                    bpf_jmp_jeq_k => accumulator == instruction.k,
                    bpf_jmp_jgt_k => accumulator > instruction.k,
                    bpf_jmp_jge_k => accumulator >= instruction.k,
                    bpf_jmp_jset_k => accumulator & instruction.k != 0,
                    else => unreachable,
                };
                const jump_distance: usize = if (condition) instruction.jt else instruction.jf;
                instruction_index += 1 + jump_distance;
            },
            bpf_ret_k => return instruction.k,
            else => return error.UnsupportedSeccompFilterInstruction,
        }
    }
    return error.UnterminatedSeccompFilter;
}

fn syscallNumber(comptime name: []const u8) u32 {
    const linux = std.os.linux;
    if (comptime !@hasField(linux.SYS, name))
        @compileError("worker seccomp syscall is unavailable for this target: " ++ name);
    return @intFromEnum(@field(linux.SYS, name));
}

fn auditArchCurrent() u32 {
    return switch (builtin.cpu.arch) {
        .x86_64 => 0xc000003e,
        .aarch64 => 0xc00000b7,
        else => @compileError("worker seccomp audit arch is not defined for this target"),
    };
}

fn newFstatAtSyscall() std.os.linux.SYS {
    const linux = std.os.linux;
    if (comptime @hasField(linux.SYS, "newfstatat"))
        return @field(linux.SYS, "newfstatat");
    if (comptime @hasField(linux.SYS, "fstatat"))
        return @field(linux.SYS, "fstatat");
    if (comptime @hasField(linux.SYS, "fstatat64"))
        return @field(linux.SYS, "fstatat64");
    @compileError("worker seccomp fstatat syscall is unavailable for this target");
}

fn enableNoNewPrivsForSeccompTest() bool {
    const rc = std.os.linux.prctl(
        @intFromEnum(std.os.linux.PR.SET_NO_NEW_PRIVS),
        1,
        0,
        0,
        0,
    );
    return std.os.linux.E.init(rc) == .SUCCESS;
}

fn socketDeniedBySeccomp() bool {
    const rc = std.os.linux.socket(
        std.os.linux.AF.INET,
        std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC,
        0,
    );
    if (std.os.linux.E.init(rc) == .PERM)
        return true;
    if (std.os.linux.E.init(rc) == .SUCCESS)
        _ = std.os.linux.close(@intCast(rc));
    return false;
}

fn fcntlDupDeniedBySeccomp(fd: std.posix.fd_t) bool {
    const linux_f_dupfd: u32 = 0;
    const rc = std.os.linux.fcntl(fd, linux_f_dupfd, 0);
    if (std.os.linux.E.init(rc) == .PERM)
        return true;
    if (std.os.linux.E.init(rc) == .SUCCESS)
        _ = std.os.linux.close(@intCast(rc));
    return false;
}

fn fcntlGetFdAllowedBySeccomp(fd: std.posix.fd_t) bool {
    const rc = std.os.linux.fcntl(fd, 1, 0);
    return std.os.linux.E.init(rc) == .SUCCESS;
}

fn ioUringEnterDeniedBySeccomp(fd: std.posix.fd_t) bool {
    const rc = std.os.linux.io_uring_enter(fd, 0, 0, 0, null);
    return std.os.linux.E.init(rc) == .PERM;
}

fn timerFdSetTimeDeniedBySeccomp(fd: std.posix.fd_t) bool {
    var spec = std.os.linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 1 },
    };
    const rc = std.os.linux.timerfd_settime(fd, .{}, &spec, null);
    return std.os.linux.E.init(rc) == .PERM;
}

fn prctlSetNameAllowedBySeccomp(name: [*:0]const u8) bool {
    const linux = std.os.linux;
    const rc = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr(name), 0, 0, 0);
    return linux.E.init(rc) == .SUCCESS;
}

fn prctlSetDumpableDeniedBySeccomp() bool {
    const linux = std.os.linux;
    const rc = linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 1, 0, 0, 0);
    return linux.E.init(rc) == .PERM;
}

/// Whether the thread `comm_fd` names now reads as `expected`. The kernel
/// renders the name with a trailing newline.
fn threadCommReads(comm_fd: std.posix.fd_t, expected: []const u8) bool {
    var buffer: [32]u8 = undefined;
    const rc = std.os.linux.pread(comm_fd, &buffer, buffer.len, 0);
    if (std.os.linux.E.init(rc) != .SUCCESS)
        return false;
    const comm = std.mem.trimEnd(u8, buffer[0..rc], "\n");
    return std.mem.eql(u8, comm, expected);
}

fn openByHandleAtDeniedBySeccomp() bool {
    var handle = std.os.linux.file_handle{
        .handle_bytes = 0,
        .handle_type = 0,
        .f_handle = .{},
    };
    const mount_fd = @as(usize, @bitCast(@as(isize, std.os.linux.AT.FDCWD)));
    const rc = std.os.linux.syscall3(
        .open_by_handle_at,
        mount_fd,
        @intFromPtr(&handle),
        0,
    );
    return std.os.linux.E.init(rc) == .PERM;
}

fn openAtAllowedBySeccomp() bool {
    const rc = std.os.linux.openat(
        std.os.linux.AT.FDCWD,
        "/dev/null",
        .{ .CLOEXEC = true },
        0,
    );
    if (std.os.linux.E.init(rc) != .SUCCESS)
        return false;
    _ = std.os.linux.close(@intCast(rc));
    return true;
}

fn openAtPathFlagDeniedBySeccomp() bool {
    const rc = std.os.linux.openat(
        std.os.linux.AT.FDCWD,
        "/dev/null",
        .{ .PATH = true, .CLOEXEC = true },
        0,
    );
    return std.os.linux.E.init(rc) == .PERM;
}

fn newFstatAtAllowedBySeccomp() bool {
    var stat: std.os.linux.Stat = undefined;
    const rc = std.os.linux.fstatat(
        std.os.linux.AT.FDCWD,
        "/dev/null",
        &stat,
        0,
    );
    return std.os.linux.E.init(rc) == .SUCCESS;
}

fn newFstatAtDirfdDeniedBySeccomp(fd: std.posix.fd_t) bool {
    var stat: std.os.linux.Stat = undefined;
    const rc = std.os.linux.fstatat(
        fd,
        "/dev/null",
        &stat,
        0,
    );
    return std.os.linux.E.init(rc) == .PERM;
}

fn newFstatAtEmptyPathDeniedBySeccomp() bool {
    var stat: std.os.linux.Stat = undefined;
    const rc = std.os.linux.fstatat(
        std.os.linux.AT.FDCWD,
        "",
        &stat,
        std.os.linux.AT.EMPTY_PATH,
    );
    return std.os.linux.E.init(rc) == .PERM;
}

fn statxAllowedBySeccomp() bool {
    var stat: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        "/dev/null",
        0,
        std.os.linux.STATX_BASIC_STATS,
        &stat,
    );
    return std.os.linux.E.init(rc) == .SUCCESS;
}

fn statxDirfdDeniedBySeccomp(fd: std.posix.fd_t) bool {
    var stat: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(
        fd,
        "/dev/null",
        0,
        std.os.linux.STATX_BASIC_STATS,
        &stat,
    );
    return std.os.linux.E.init(rc) == .PERM;
}

fn statxEmptyPathDeniedBySeccomp() bool {
    var stat: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        "",
        std.os.linux.AT.EMPTY_PATH,
        std.os.linux.STATX_BASIC_STATS,
        &stat,
    );
    return std.os.linux.E.init(rc) == .PERM;
}

fn writeSeccompSmokeResult(fd: std.posix.fd_t, result: u8) !void {
    const byte: [1]u8 = .{result};
    const rc = std.os.linux.write(fd, &byte, byte.len);
    if (std.os.linux.E.init(rc) != .SUCCESS)
        return error.WriteFailed;
    if (rc != byte.len)
        return error.ShortWrite;
}

fn childExit(status: u8) noreturn {
    std.os.linux.exit_group(status);
}
