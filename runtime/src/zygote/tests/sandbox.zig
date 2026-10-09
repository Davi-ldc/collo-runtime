//! The worker sandbox without a full worker: the environment allowlist and
//! clearing, tmp root validation, and the seccomp policy, checked both in the
//! emitted program and by installing it in forked children that probe what it
//! allows, denies and filters by argument, and whether a thread created before
//! it can still start under it. The `zygote-integration` lane covers a real
//! worker booting into the sandbox.

const std = @import("std");
const builtin = @import("builtin");
const zygote = @import("collo_zygote");
const support = @import("zygote_support");

const sandbox = zygote.worker_boot.sandbox;

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn pthread_attr_setaffinity_np(
    attr: *std.c.pthread_attr_t,
    cpuset_size: usize,
    cpuset: *const std.os.linux.cpu_set_t,
) c_int;

test "worker environment allowlist excludes server secrets and trace controls" {
    const retained = zygote.child_boot.worker_environment_retained_names;
    try std.testing.expectEqual(@as(usize, 2), retained.len);
    try std.testing.expect(containsRetainedEnv(&retained, "TZ"));
    try std.testing.expect(containsRetainedEnv(&retained, "LANG"));
    try std.testing.expect(!containsRetainedEnv(&retained, "COLLO_ORACLE_TOKEN"));
    try std.testing.expect(!containsRetainedEnv(&retained, "COLLO_BENCH_TRACE_REQUEST"));
    try std.testing.expect(!containsRetainedEnv(&retained, "SSL_CERT_FILE"));
}

test "worker environment policy clears inherited secrets in child" {
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);
        if (setenv("COLLO_ORACLE_TOKEN", "secret", 1) != 0)
            childExit(111);
        if (setenv("SSL_CERT_FILE", "/tmp/evil-ca.pem", 1) != 0)
            childExit(112);
        if (setenv("COLLO_BENCH_TRACE_REQUEST", "1", 1) != 0)
            childExit(113);

        zygote.child_boot.applyWorkerEnvironmentPolicy() catch childExit(114);

        const tz = std.posix.getenv("TZ") orelse childExit(115);
        const lang = std.posix.getenv("LANG") orelse childExit(116);
        const ok = std.mem.eql(u8, tz, "UTC") and
            std.mem.eql(u8, lang, "C.UTF-8") and
            std.posix.getenv("COLLO_ORACLE_TOKEN") == null and
            std.posix.getenv("SSL_CERT_FILE") == null and
            std.posix.getenv("COLLO_BENCH_TRACE_REQUEST") == null;
        const byte: [1]u8 = .{if (ok) 1 else 0};
        _ = std.posix.write(pipe_pair[1], &byte) catch childExit(117);
        childExit(if (ok) 0 else 118);
    }

    std.posix.close(pipe_pair[1]);
    var result: [1]u8 = undefined;
    const read_len = try std.posix.read(pipe_pair[0], &result);
    try std.testing.expectEqual(@as(usize, 1), read_len);
    try std.testing.expectEqual(@as(u8, 1), result[0]);

    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
}

test "worker sandbox validates tmp root directory fd" {
    const root_path = try support.makeTempPath(std.testing.allocator, "collo-sandbox-root");
    defer std.testing.allocator.free(root_path);
    defer support.cleanupTmpRoot(root_path);

    try std.posix.mkdir(root_path, 0o700);
    var root = try std.fs.openDirAbsolute(root_path, .{
        .iterate = true,
        .no_follow = true,
    });
    defer root.close();

    try sandbox.tmp_root.validateFd(root.fd);
    try std.posix.fchmod(root.fd, 0o750);
    try std.testing.expectError(error.PermissionDenied, sandbox.tmp_root.validateFd(root.fd));
    try std.posix.fchmod(root.fd, 0o1700);
    try std.testing.expectError(error.PermissionDenied, sandbox.tmp_root.validateFd(root.fd));
    try std.posix.fchmod(root.fd, 0o2700);
    try std.testing.expectError(error.PermissionDenied, sandbox.tmp_root.validateFd(root.fd));
    try std.posix.fchmod(root.fd, 0o4700);
    try std.testing.expectError(error.PermissionDenied, sandbox.tmp_root.validateFd(root.fd));
    try std.posix.fchmod(root.fd, sandbox.tmp_root.required_mode);
    try std.testing.expectError(error.InvalidWorkerTmpRoot, sandbox.tmp_root.validateFd(-1));

    var not_dir = try root.createFile("not-dir", .{});
    defer not_dir.close();
    try std.testing.expectError(
        error.InvalidWorkerTmpRoot,
        sandbox.tmp_root.validateFd(not_dir.handle),
    );
}

test "worker direct-egress seccomp policy denies unexpected syscalls with narrow runtime allowlist" {
    const security = sandbox.security;

    try std.testing.expect(!security.denyDirectEgressUsesLearningMode());
    try std.testing.expect(security.denyDirectEgressUsesPrecomputedTemplate());
    try std.testing.expect(security.denyDirectEgressTemplateHasFdPatch());

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
    };
    inline for (authority_creating_or_escape_syscalls) |name|
        try std.testing.expect(security.denyDirectEgressDeniesUnexpectedSyscall(name));

    try std.testing.expect(security.denyDirectEgressFiltersFcntlDup());
    try std.testing.expect(security.denyDirectEgressFiltersFcntlCommands());
    try std.testing.expect(security.denyDirectEgressFiltersOpenAtFlags());
    try std.testing.expect(security.denyDirectEgressFiltersNewFstatAtArgs());
    try std.testing.expect(security.denyDirectEgressFiltersStatxArgs());
    try std.testing.expect(security.denyDirectEgressFiltersMkdirAtArgs());
    try std.testing.expect(security.denyDirectEgressFiltersUnlinkAtArgs());
    try std.testing.expect(security.denyDirectEgressFiltersRenameAt2Args());
    try std.testing.expect(!security.denyDirectEgressFiltersCloseRingFds());

    const expected_runtime_syscalls = [_][]const u8{
        "read",
        "write",
        "close",
        "sendmsg",
        "recvmsg",
        "sendto",
        "recvfrom",
        "fstat",
        "newfstatat",
        "statx",
        "pread64",
        "lseek",
        "openat",
        "getdents64",
        "mkdirat",
        "unlinkat",
        "renameat2",
        "ftruncate",
        "fsync",
        "fdatasync",
        "mmap",
        "munmap",
        "mprotect",
        "futex",
        "clock_gettime",
        "clock_nanosleep",
        "timerfd_settime",
        "getrandom",
        "poll",
        "ppoll",
        "rseq",
        "set_robust_list",
        "exit",
        "exit_group",
    };
    inline for (expected_runtime_syscalls) |name|
        try std.testing.expect(security.denyDirectEgressAllowsSyscall(name));

    const argument_filtered_syscalls = [_][]const u8{
        "fcntl",
    };
    inline for (argument_filtered_syscalls) |name|
        try std.testing.expect(!security.denyDirectEgressAllowsSyscall(name));
}

test "worker direct-egress emitted seccomp filters AT_FDCWD by its low int word" {
    // Evaluate the emitted classic-BPF program so every representation and
    // negative case is deterministic even when the host cannot install seccomp.
    const canonical: u64 = 0xffff_ffff_ffff_ff9c;
    const variadic_cpp: u64 = 0x0000_0000_ffff_ff9c;
    const arbitrary_high: u64 = 0x1234_5678_ffff_ff9c;
    const wrong_low: u64 = 0xffff_ffff_ffff_ff9d;
    const program = sandbox.security.denyDirectEgressFilterInstructions();
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

test "worker direct-egress seccomp only opens io_uring_enter for an explicit worker ring fd" {
    const security = sandbox.security;

    try std.testing.expect(!security.denyDirectEgressFiltersIoUringEnterByFd(.{
        .mode = .disabled,
        .allowed_io_uring_enter_fd = 42,
    }));
    try std.testing.expect(!security.denyDirectEgressFiltersIoUringEnterByFd(.{
        .mode = .deny_direct_egress,
        .allowed_io_uring_enter_fd = -1,
    }));
    try std.testing.expect(security.denyDirectEgressFiltersIoUringEnterByFd(.{
        .mode = .deny_direct_egress,
        .allowed_io_uring_enter_fd = 42,
        .allowed_timer_fd = 43,
    }));
}

test "worker direct-egress seccomp enforces runtime authority denies" {
    const skip_result: u8 = 0xff;
    const expected_result: u8 = 0b0111_1111;
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);

        const ring_fd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch childExit(121);
        const timer_fd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch childExit(122);

        if (!enableNoNewPrivsForSeccompTest()) {
            writeSeccompSmokeResult(pipe_pair[1], skip_result) catch childExit(123);
            childExit(0);
        }
        sandbox.applySeccomp(.{
            .mode = .deny_direct_egress,
            .allowed_io_uring_enter_fd = ring_fd,
            .allowed_timer_fd = timer_fd,
        }) catch |err| switch (err) {
            error.PermissionDenied,
            error.UnsupportedKernel,
            => {
                writeSeccompSmokeResult(pipe_pair[1], skip_result) catch childExit(124);
                childExit(0);
            },
            else => childExit(124),
        };

        var result: u8 = 0;
        if (socketDeniedBySeccomp())
            result |= @as(u8, 1) << 0;
        if (fcntlDupDeniedBySeccomp(ring_fd))
            result |= @as(u8, 1) << 1;
        if (fcntlGetFdAllowedBySeccomp(ring_fd))
            result |= @as(u8, 1) << 2;
        if (ioUringEnterDeniedBySeccomp(timer_fd))
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

    std.posix.close(pipe_pair[1]);
    var result: [1]u8 = undefined;
    const read_len = try std.posix.read(pipe_pair[0], &result);

    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
    try std.testing.expectEqual(@as(usize, 1), read_len);
    if (result[0] == skip_result)
        return error.SkipZigTest;
    try std.testing.expectEqual(expected_result, result[0]);
}

test "worker direct-egress seccomp only arms the explicit worker timer fd" {
    const skip_result: u8 = 0xff;
    const expected_result: u8 = 0b0000_0011;
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);

        const ring_fd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch childExit(126);
        const timer_fd_allowed = std.posix.timerfd_create(.MONOTONIC, .{
            .CLOEXEC = true,
            .NONBLOCK = true,
        }) catch childExit(127);
        const timer_fd_denied = std.posix.timerfd_create(.MONOTONIC, .{
            .CLOEXEC = true,
            .NONBLOCK = true,
        }) catch childExit(128);

        if (!enableNoNewPrivsForSeccompTest()) {
            writeSeccompSmokeResult(pipe_pair[1], skip_result) catch childExit(129);
            childExit(0);
        }
        sandbox.applySeccomp(.{
            .mode = .deny_direct_egress,
            .allowed_io_uring_enter_fd = ring_fd,
            .allowed_timer_fd = timer_fd_allowed,
        }) catch |err| switch (err) {
            error.PermissionDenied,
            error.UnsupportedKernel,
            => {
                writeSeccompSmokeResult(pipe_pair[1], skip_result) catch childExit(130);
                childExit(0);
            },
            else => childExit(130),
        };

        var result: u8 = 0;
        if (timerFdSetTimeAllowedBySeccomp(timer_fd_allowed)) {
            result |= @as(u8, 1) << 0;
        }
        if (timerFdSetTimeDeniedBySeccomp(timer_fd_denied)) {
            result |= @as(u8, 1) << 1;
        }

        writeSeccompSmokeResult(pipe_pair[1], result) catch childExit(131);
        childExit(0);
    }

    std.posix.close(pipe_pair[1]);
    var result: [1]u8 = undefined;
    const read_len = try std.posix.read(pipe_pair[0], &result);

    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
    try std.testing.expectEqual(@as(usize, 1), read_len);
    if (result[0] == skip_result)
        return error.SkipZigTest;
    try std.testing.expectEqual(expected_result, result[0]);
}

test "worker direct-egress seccomp pins stat-at syscalls to safe cwd paths" {
    const skip_result: u8 = 0xff;
    const expected_result: u8 = 0b0011_1111;
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe_pair[0]);

        const ring_fd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch childExit(131);
        const timer_fd = std.posix.eventfd(
            0,
            std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK,
        ) catch childExit(132);

        if (!enableNoNewPrivsForSeccompTest()) {
            writeSeccompSmokeResult(pipe_pair[1], skip_result) catch childExit(133);
            childExit(0);
        }
        sandbox.applySeccomp(.{
            .mode = .deny_direct_egress,
            .allowed_io_uring_enter_fd = ring_fd,
            .allowed_timer_fd = timer_fd,
        }) catch |err| switch (err) {
            error.PermissionDenied,
            error.UnsupportedKernel,
            => {
                writeSeccompSmokeResult(pipe_pair[1], skip_result) catch childExit(134);
                childExit(0);
            },
            else => childExit(134),
        };

        var result: u8 = 0;
        if (newFstatAtAllowedBySeccomp())
            result |= @as(u8, 1) << 0;
        if (newFstatAtDirfdDeniedBySeccomp(ring_fd))
            result |= @as(u8, 1) << 1;
        if (newFstatAtEmptyPathDeniedBySeccomp())
            result |= @as(u8, 1) << 2;
        if (statxAllowedBySeccomp())
            result |= @as(u8, 1) << 3;
        if (statxDirfdDeniedBySeccomp(ring_fd))
            result |= @as(u8, 1) << 4;
        if (statxEmptyPathDeniedBySeccomp())
            result |= @as(u8, 1) << 5;

        writeSeccompSmokeResult(pipe_pair[1], result) catch childExit(135);
        childExit(0);
    }

    std.posix.close(pipe_pair[1]);
    var result: [1]u8 = undefined;
    const read_len = try std.posix.read(pipe_pair[0], &result);

    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
    try std.testing.expectEqual(@as(usize, 1), read_len);
    if (result[0] == skip_result)
        return error.SkipZigTest;
    try std.testing.expectEqual(expected_result, result[0]);
}

test "worker seccomp lets a thread created before the filter start after it" {
    // Creating a thread does not run it. glibc registers a new thread's rseq
    // area when the thread first runs and aborts the whole process if that
    // fails, so a thread a worker creates before its filter but the scheduler
    // first picks after it must still be able to start.
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
    // never parked and the test proved nothing.
    try std.testing.expectEqual(@as(u8, 1), result[0]);
}

/// Bounds the supervisor's wait for the creator's affinity call, so a glibc
/// that stops setting affinity after the clone fails the test instead of
/// hanging it.
const affinity_notification_timeout_ms: i32 = 5_000;

const WorkerFilterInstaller = struct {
    go_fd: std.posix.fd_t,
    installed_fd: std.posix.fd_t,
    ring_fd: std.posix.fd_t,
    timer_fd: std.posix.fd_t,
    installed: std.atomic.Value(bool) = .init(false),
    outcome: Outcome = .not_signaled,

    const Outcome = enum { not_signaled, installed, unsupported };

    fn run(self: *WorkerFilterInstaller) void {
        var go: [1]u8 = undefined;
        const read_len = std.posix.read(self.go_fd, &go) catch childExit(171);
        if (read_len != 1)
            return;
        sandbox.applySeccomp(.{
            .mode = .deny_direct_egress,
            .allowed_io_uring_enter_fd = self.ring_fd,
            .allowed_timer_fd = self.timer_fd,
        }) catch |err| switch (err) {
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
};

fn lateStartThreadMain(context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *LateStartThread = @ptrCast(@alignCast(context.?));
    state.started_under_filter = state.installer.installed.load(.acquire);
    return null;
}

fn startThreadUnderWorkerFilterChild(result_fd: std.posix.fd_t, skip_result: u8) noreturn {
    const linux = std.os.linux;
    const ring_fd = std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK) catch childExit(141);
    const timer_fd = std.posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK) catch childExit(142);
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
        .ring_fd = ring_fd,
        .timer_fd = timer_fd,
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
        .installed => if (state.started_under_filter) 1 else 0,
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

fn containsRetainedEnv(retained: []const []const u8, name: []const u8) bool {
    for (retained) |entry|
        if (std.mem.eql(u8, entry, name))
            return true;
    return false;
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

fn timerFdSetTimeAllowedBySeccomp(fd: std.posix.fd_t) bool {
    var spec = std.os.linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 1 },
    };
    const rc = std.os.linux.timerfd_settime(fd, .{}, &spec, null);
    return std.os.linux.E.init(rc) == .SUCCESS;
}

fn timerFdSetTimeDeniedBySeccomp(fd: std.posix.fd_t) bool {
    var spec = std.os.linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 1 },
    };
    const rc = std.os.linux.timerfd_settime(fd, .{}, &spec, null);
    return std.os.linux.E.init(rc) == .PERM;
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
