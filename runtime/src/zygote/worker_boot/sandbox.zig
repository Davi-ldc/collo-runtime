//! The worker's sandbox, applied by the forked child in three steps: user,
//! mount and network namespaces first, while the child is single-threaded;
//! then resource limits, no-new-privileges, a private tmpfs root and
//! capability drop; and last, after every thread exists, a seccomp allowlist
//! installed on all threads. A syscall outside the allowlist fails with EPERM,
//! and a syscall from a foreign architecture kills the process. The child
//! keeps no route to the network, the machine's filesystem or new threads.

const std = @import("std");
const builtin = @import("builtin");
const linux_helpers = @import("collo_os").linux;
const linux = std.os.linux;

pub const Config = struct {
    tmp_root_fd: std.posix.fd_t,
    tmpfs_size_bytes: u64,
    max_open_files: u64 = limits.DEFAULT_MAX_OPEN_FILES,
};

/// Must be the forked child's first act, before any engine work:
/// unshare(CLONE_NEWUSER) requires a single-threaded caller, and postForkChild
/// restarts the libpas scavenger thread.
pub fn applyPostForkNamespaces() !void {
    try namespaces.enterWorker();
}

/// Runs inside the namespaces entered at birth, whose capabilities allow the
/// tmpfs mount and the chroot; dropCapabilities then gives them up.
pub fn applyPreThread(config: Config) !void {
    try tmp_root.validateFd(config.tmp_root_fd);
    try limits.apply(config);
    try privileges.disableNewPrivs();
    try mounts.makePrivate();
    try rootfs.mountTmpfsAndChrootIntoFd(config);
    try privileges.dropCapabilities();
}

pub fn applySeccomp(config: security.Config) !void {
    try security.apply(config);
}

pub const tmp_root = struct {
    pub const required_mode: u32 = 0o700;

    pub fn validateFd(fd: std.posix.fd_t) !void {
        if (fd < 0)
            return error.InvalidWorkerTmpRoot;
        var stat: linux.Stat = undefined;
        switch (linux_helpers.syscallErrno(linux.fstat(fd, &stat))) {
            .SUCCESS => {},
            .BADF => return error.InvalidWorkerTmpRoot,
            else => return error.InvalidWorkerTmpRoot,
        }
        if ((stat.mode & linux.S.IFMT) != linux.S.IFDIR)
            return error.InvalidWorkerTmpRoot;
        if ((stat.mode & 0o7777) != required_mode)
            return error.PermissionDenied;
        if (stat.uid != linux.getuid())
            return error.PermissionDenied;
    }
};

pub const limits = struct {
    pub const DEFAULT_MAX_OPEN_FILES: u64 = 1024;

    fn apply(config: Config) !void {
        try set(.NOFILE, config.max_open_files);
        try set(.CORE, 0);
    }

    fn set(resource: std.posix.rlimit_resource, value: u64) !void {
        const limit = std.posix.rlimit{
            .cur = @intCast(value),
            .max = @intCast(value),
        };
        std.posix.setrlimit(resource, limit) catch |err| switch (err) {
            error.PermissionDenied => return error.PermissionDenied,
            error.LimitTooBig => return error.WorkerSandboxOperationFailed,
            else => return error.WorkerSandboxOperationFailed,
        };
    }
};

pub const privileges = struct {
    fn disableNewPrivs() !void {
        const rc = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
        return switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .INVAL => error.UnsupportedKernel,
            .PERM => error.PermissionDenied,
            .BADF => error.UnsupportedKernel,
            else => error.WorkerSandboxOperationFailed,
        };
    }

    fn dropCapabilities() !void {
        linux_helpers.dropAllCapabilities() catch |err| switch (err) {
            error.UnsupportedKernel => return error.UnsupportedKernel,
            error.PermissionDenied => return error.PermissionDenied,
            else => return error.WorkerSandboxOperationFailed,
        };
    }
};

pub const namespaces = struct {
    /// Every worker gets a private network namespace with no devices or
    /// routes. `validateWorkerInit` only admits isolated-network workers, so
    /// there is no host-network mode.
    fn enterWorker() !void {
        const uid: u32 = @intCast(linux.getuid());
        const gid: u32 = @intCast(linux.getgid());
        try unshare(linux.CLONE.NEWUSER);
        try writeUserNamespaceMaps(uid, gid);
        try unshare(linux.CLONE.NEWNS);
        try unshare(linux.CLONE.NEWNET);
    }

    pub fn unshare(flags: usize) !void {
        const rc = linux.unshare(flags);
        return switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .INVAL => error.UnsupportedKernel,
            .PERM => error.PermissionDenied,
            .NOMEM => error.SystemResources,
            else => error.WorkerSandboxOperationFailed,
        };
    }

    fn writeUserNamespaceMaps(uid: u32, gid: u32) !void {
        try writeProcSelfFile("/proc/self/setgroups", "deny\n");

        var uid_map_buffer: [64]u8 = undefined;
        const uid_map = try std.fmt.bufPrint(&uid_map_buffer, "0 {d} 1\n", .{uid});
        try writeProcSelfFile("/proc/self/uid_map", uid_map);

        var gid_map_buffer: [64]u8 = undefined;
        const gid_map = try std.fmt.bufPrint(&gid_map_buffer, "0 {d} 1\n", .{gid});
        try writeProcSelfFile("/proc/self/gid_map", gid_map);
    }

    fn writeProcSelfFile(path: []const u8, bytes: []const u8) !void {
        var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| return mapNamespaceMapError(err);
        defer file.close();
        file.writeAll(bytes) catch |err| return mapNamespaceMapError(err);
    }

    fn mapNamespaceMapError(err: anyerror) anyerror {
        return switch (err) {
            error.AccessDenied => error.PermissionDenied,
            error.FileNotFound => error.UnsupportedKernel,
            error.SystemResources => error.SystemResources,
            else => error.WorkerSandboxOperationFailed,
        };
    }
};

pub const security = struct {
    pub const Mode = enum {
        disabled,
        /// The worker's policy after boot: `allowed_syscalls` plus the
        /// argument-filtered calls in `buildDenyDirectEgressTemplate`. Every
        /// other syscall fails with EPERM, so worker code cannot gain new
        /// authority.
        deny_direct_egress,
    };

    pub const Config = struct {
        mode: Mode,
        allowed_io_uring_enter_fd: ?std.posix.fd_t = null,
        allowed_timer_fd: ?std.posix.fd_t = null,
    };

    pub const FilterInstruction = extern struct {
        code: u16,
        jt: u8,
        jf: u8,
        k: u32,
    };

    const sock_filter = FilterInstruction;

    const sock_fprog = extern struct {
        len: u16,
        filter: [*]const sock_filter,
    };

    const bpf = struct {
        const LD: u16 = 0x00;
        const W: u16 = 0x00;
        const ABS: u16 = 0x20;
        const JMP: u16 = 0x05;
        const JEQ: u16 = 0x10;
        const K: u16 = 0x00;
        const RET: u16 = 0x06;
        const JGT: u16 = 0x20;
        const JGE: u16 = 0x30;
        const JSET: u16 = 0x40;
    };

    const allowed_syscalls = [_][]const u8{
        // Descriptor I/O on fds handed in before seccomp.
        "read",
        "write",
        "close",
        "recvmsg",
        "sendmsg",
        "recvfrom",
        "sendto",
        "fstat",
        "newfstatat",
        "statx",
        "pread64",
        "lseek",

        // Filesystem operations inside the chrooted tmpfs. The chroot and the
        // mount namespace confine paths; the open and create calls are also
        // filtered by argument before this list is checked.
        "openat",
        "getdents64",
        "mkdirat",
        "unlinkat",
        "renameat2",
        "ftruncate",
        "fsync",
        "fdatasync",

        // VM/JSC allocation and code memory management.
        "mmap",
        "munmap",
        "mprotect",
        "madvise",
        "mremap",
        "brk",

        // Thread synchronization, time, randomness, and process identity.
        "futex",
        "futex_time64",
        "clock_gettime",
        "clock_gettime64",
        "getrandom",
        "getpid",
        "gettid",
        "getrusage",
        "sched_yield",
        "nanosleep",
        "clock_nanosleep",
        "clock_nanosleep_time64",
        "timerfd_settime",
        "timerfd_settime64",

        // Signals. Every thread exists before this filter is installed, so
        // clone and fork are denied.
        "rt_sigreturn",
        "rt_sigprocmask",
        "rt_sigaction",

        // A thread's own start. A thread created before this filter runs
        // glibc's start code only when the scheduler first picks it, which
        // under CPU contention can come after the filter. glibc aborts the
        // whole process when that thread cannot register its rseq area. A
        // failed set_robust_list is ignored, but the thread would then lack
        // the robust-futex list glibc registers for every thread it starts.
        // Both calls only register memory of the calling thread with the
        // kernel.
        "rseq",
        "set_robust_list",

        // Bounded blocking waits outside the worker event loop. The sentinel
        // uses ppoll, and tests may still use poll around inherited control fds.
        "poll",
        "ppoll",
        "ppoll_time64",

        // Kernel restart after an interrupted allowed syscall.
        "restart_syscall",

        // Thread and process exit.
        "exit",
        "exit_group",
    };

    pub fn denyDirectEgressDeniesUnexpectedSyscall(comptime name: []const u8) bool {
        if (std.mem.eql(u8, name, "io_uring_enter"))
            return true;
        return !denyDirectEgressAllowsSyscall(name);
    }

    pub fn denyDirectEgressAllowsSyscall(comptime name: []const u8) bool {
        inline for (allowed_syscalls) |allowed| {
            if (std.mem.eql(u8, allowed, name))
                return true;
        }
        return false;
    }

    pub fn denyDirectEgressUsesLearningMode() bool {
        return false;
    }

    pub fn denyDirectEgressFiltersIoUringEnterByFd(config: security.Config) bool {
        return config.mode == .deny_direct_egress and
            config.allowed_io_uring_enter_fd != null and
            config.allowed_io_uring_enter_fd.? >= 0;
    }

    pub fn denyDirectEgressFiltersCloseRingFds() bool {
        return false;
    }

    pub fn denyDirectEgressFiltersFcntlDup() bool {
        return hasSyscall("fcntl");
    }

    pub fn denyDirectEgressFiltersFcntlCommands() bool {
        return hasSyscall("fcntl");
    }

    pub fn denyDirectEgressFiltersOpenAtFlags() bool {
        return deny_direct_egress_template.openat_flags_filter;
    }

    pub fn denyDirectEgressFiltersNewFstatAtArgs() bool {
        return deny_direct_egress_template.newfstatat_flags_filter;
    }

    pub fn denyDirectEgressFiltersStatxArgs() bool {
        return deny_direct_egress_template.statx_flags_filter;
    }

    pub fn denyDirectEgressFiltersMkdirAtArgs() bool {
        return deny_direct_egress_template.mkdirat_args_filter;
    }

    pub fn denyDirectEgressFiltersUnlinkAtArgs() bool {
        return deny_direct_egress_template.unlinkat_args_filter;
    }

    pub fn denyDirectEgressFiltersRenameAt2Args() bool {
        return deny_direct_egress_template.renameat2_args_filter;
    }

    pub fn denyDirectEgressFilterInstructions() []const FilterInstruction {
        return deny_direct_egress_template.program[0..deny_direct_egress_template.len];
    }

    pub fn denyDirectEgressUsesPrecomputedTemplate() bool {
        return deny_direct_egress_template.len > 0;
    }

    pub fn denyDirectEgressTemplateHasFdPatch() bool {
        return deny_direct_egress_template.io_uring_fd_patch_index != null and
            deny_direct_egress_template.timer_fd_patch_count > 0 and
            deny_direct_egress_template.openat_flags_filter;
    }

    fn apply(config: security.Config) !void {
        switch (config.mode) {
            .disabled => {},
            .deny_direct_egress => {
                const fd = config.allowed_io_uring_enter_fd orelse return error.InvalidWorkerRingFd;
                if (fd < 0)
                    return error.InvalidWorkerRingFd;
                const timer_fd = config.allowed_timer_fd orelse fd;
                if (timer_fd < 0)
                    return error.InvalidWorkerRingFd;
                try installDenyDirectEgress(fd, timer_fd);
            },
        }
    }

    fn installDenyDirectEgress(
        allowed_io_uring_enter_fd: std.posix.fd_t,
        allowed_timer_fd: std.posix.fd_t,
    ) !void {
        const template = deny_direct_egress_template;
        var program = template.program;
        if (template.io_uring_fd_patch_index == null or
            template.timer_fd_patch_count == 0 or
            !template.openat_flags_filter or
            !template.newfstatat_flags_filter or
            !template.statx_flags_filter or
            !template.mkdirat_args_filter or
            !template.unlinkat_args_filter or
            !template.renameat2_args_filter)
        {
            return error.UnsupportedKernel;
        }
        program[template.io_uring_fd_patch_index.?].k = @intCast(allowed_io_uring_enter_fd);
        for (template.timer_fd_patch_indices[0..template.timer_fd_patch_count]) |patch_index| {
            program[patch_index].k = @intCast(allowed_timer_fd);
        }

        const filter = sock_fprog{
            .len = @intCast(template.len),
            .filter = &program,
        };
        const rc = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, linux.SECCOMP.FILTER_FLAG.TSYNC, &filter);
        const seccomp_errno = linux_helpers.syscallErrno(rc);
        if (seccomp_errno == .SUCCESS and rc != 0)
            return error.WorkerSandboxOperationFailed;
        return switch (seccomp_errno) {
            .SUCCESS => {},
            .INVAL => error.UnsupportedKernel,
            .PERM => error.PermissionDenied,
            .SRCH => error.WorkerSandboxOperationFailed,
            .NOMEM => error.SystemResources,
            else => error.WorkerSandboxOperationFailed,
        };
    }

    // Room for the argument policies ahead of the allowlist plus two
    // instructions per allowlisted syscall. The template is built at compile
    // time, so a program that outgrows it fails the build.
    const template_capacity = 200 + allowed_syscalls.len * 2;

    const SeccompTemplate = struct {
        program: [template_capacity]sock_filter,
        len: usize,
        io_uring_fd_patch_index: ?usize = null,
        timer_fd_patch_indices: [2]usize = undefined,
        timer_fd_patch_count: usize = 0,
        openat_flags_filter: bool = false,
        newfstatat_flags_filter: bool = false,
        statx_flags_filter: bool = false,
        mkdirat_args_filter: bool = false,
        unlinkat_args_filter: bool = false,
        renameat2_args_filter: bool = false,
    };

    const deny_direct_egress_template = buildDenyDirectEgressTemplate();

    fn buildDenyDirectEgressTemplate() SeccompTemplate {
        var template = SeccompTemplate{
            .program = undefined,
            .len = 0,
            .io_uring_fd_patch_index = null,
            .timer_fd_patch_indices = undefined,
            .timer_fd_patch_count = 0,
            .openat_flags_filter = false,
            .newfstatat_flags_filter = false,
            .statx_flags_filter = false,
            .mkdirat_args_filter = false,
            .unlinkat_args_filter = false,
            .renameat2_args_filter = false,
        };
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, @intCast(@offsetOf(linux.SECCOMP.data, "arch"))));
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, auditArchCurrent(), 1, 0));
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.KILL_PROCESS));
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, @intCast(@offsetOf(linux.SECCOMP.data, "nr"))));
        appendX86_64CompatGuards(&template.program, &template.len);
        appendIoUringEnterPolicy(&template);
        appendTimerFdSetTimePolicy(&template);
        appendNewFstatAtPolicy(&template);
        appendStatxPolicy(&template);
        appendOpenAtPolicy(&template);
        appendMkdirAtPolicy(&template);
        appendUnlinkAtPolicy(&template);
        appendRenameAt2Policy(&template);
        appendFcntlPolicy(&template.program, &template.len);

        inline for (allowed_syscalls) |name| {
            if (comptime hasSyscall(name)) {
                append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, syscallNumber(name), 0, 1));
                append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
            }
        }

        append(&template.program, &template.len, denyPerm());
        return template;
    }

    // io_uring_enter may target only the worker's own ring, whose opcodes are
    // restricted when it is created (`restricted_uring`); an unrestricted ring
    // could run operations this filter denies, such as connect. The ring fd is
    // patched into the template at install time. BPF compares 32-bit words,
    // so this and every argument check below require a zero high word: the
    // filter then sees exactly the value the kernel uses.
    fn appendIoUringEnterPolicy(template: *SeccompTemplate) void {
        const jump_index = beginSyscallPolicy(
            &template.program,
            &template.len,
            "io_uring_enter",
        ) orelse return;
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0HighOffset()));
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0LowOffset()));
        template.io_uring_fd_patch_index = template.len;
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(&template.program, template.len, jump_index);
    }

    fn appendTimerFdSetTimePolicy(template: *SeccompTemplate) void {
        appendTimerFdSetTimePolicyForSyscall(template, "timerfd_settime");
        appendTimerFdSetTimePolicyForSyscall(template, "timerfd_settime64");
    }

    fn appendTimerFdSetTimePolicyForSyscall(
        template: *SeccompTemplate,
        comptime name: []const u8,
    ) void {
        const jump_index = beginSyscallPolicy(
            &template.program,
            &template.len,
            name,
        ) orelse return;
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0HighOffset()));
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0LowOffset()));
        std.debug.assert(template.timer_fd_patch_count < template.timer_fd_patch_indices.len);
        template.timer_fd_patch_indices[template.timer_fd_patch_count] = template.len;
        template.timer_fd_patch_count += 1;
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(&template.program, template.len, jump_index);
    }

    fn appendOpenAtPolicy(template: *SeccompTemplate) void {
        const jump_index = beginSyscallPolicy(
            &template.program,
            &template.len,
            "openat",
        ) orelse return;
        appendAtFdcwdPolicy(&template.program, &template.len, arg0LowOffset());
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg2HighOffset()));
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg2LowOffset()));
        append(
            &template.program,
            &template.len,
            jump(bpf.JMP | bpf.JSET | bpf.K, openat_forbidden_flags, 0, 1),
        );
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        template.openat_flags_filter = true;
        endSyscallPolicy(&template.program, template.len, jump_index);
    }

    fn appendNewFstatAtPolicy(template: *SeccompTemplate) void {
        const syscall_number = newFstatAtSyscallNumber() orelse return;
        const jump_index = beginSyscallNumberPolicy(
            &template.program,
            &template.len,
            syscall_number,
        );
        appendFstatOnFdPolicy(&template.program, &template.len);
        appendAtFdcwdPolicy(&template.program, &template.len, arg0LowOffset());
        appendFlagsAllowMaskPolicy(
            &template.program,
            &template.len,
            arg3LowOffset(),
            arg3HighOffset(),
            newfstatat_allowed_flags,
        );
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        template.newfstatat_flags_filter = true;
        endSyscallPolicy(&template.program, template.len, jump_index);
    }

    fn appendStatxPolicy(template: *SeccompTemplate) void {
        const jump_index = beginSyscallPolicy(
            &template.program,
            &template.len,
            "statx",
        ) orelse return;
        appendAtFdcwdPolicy(&template.program, &template.len, arg0LowOffset());
        appendFlagsAllowMaskPolicy(
            &template.program,
            &template.len,
            arg2LowOffset(),
            arg2HighOffset(),
            statx_allowed_flags,
        );
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        template.statx_flags_filter = true;
        endSyscallPolicy(&template.program, template.len, jump_index);
    }

    fn appendMkdirAtPolicy(template: *SeccompTemplate) void {
        const jump_index = beginSyscallPolicy(&template.program, &template.len, "mkdirat") orelse return;
        appendAtFdcwdPolicy(&template.program, &template.len, arg0LowOffset());
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        template.mkdirat_args_filter = true;
        endSyscallPolicy(&template.program, template.len, jump_index);
    }

    // The runtime calls unlinkat and renameat2 only with flags 0
    // (`node/fs.cpp`, `worker/fs/copies.zig`), so any other flag, such as
    // AT_REMOVEDIR or RENAME_EXCHANGE, is denied.
    fn appendUnlinkAtPolicy(template: *SeccompTemplate) void {
        const jump_index = beginSyscallPolicy(&template.program, &template.len, "unlinkat") orelse return;
        appendAtFdcwdPolicy(&template.program, &template.len, arg0LowOffset());
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg2HighOffset()));
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg2LowOffset()));
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        template.unlinkat_args_filter = true;
        endSyscallPolicy(&template.program, template.len, jump_index);
    }

    fn appendRenameAt2Policy(template: *SeccompTemplate) void {
        const jump_index = beginSyscallPolicy(&template.program, &template.len, "renameat2") orelse return;
        appendAtFdcwdPolicy(&template.program, &template.len, arg0LowOffset());
        appendAtFdcwdPolicy(&template.program, &template.len, arg2LowOffset());
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg4HighOffset()));
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.LD | bpf.W | bpf.ABS, arg4LowOffset()));
        append(&template.program, &template.len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(&template.program, &template.len, denyPerm());
        append(&template.program, &template.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        template.renameat2_args_filter = true;
        endSyscallPolicy(&template.program, template.len, jump_index);
    }

    /// x86_64 has an `fstat` syscall, allowed without argument checks, but
    /// aarch64 has none: libc and Zig spell `fstat(fd)` as
    /// `newfstatat(fd, "", AT_EMPTY_PATH)`. The dirfd policy below admits only
    /// AT_FDCWD, so without this exception the same operation would fail with
    /// EPERM on aarch64 alone, surfacing as `error.Unexpected` mid-request.
    ///
    /// The exception is narrow: the flags must be exactly AT_EMPTY_PATH, with
    /// a zero high word, and the dirfd must be a real fd. AT_FDCWD with an
    /// empty path would stat the working directory, which no spelling of
    /// `fstat` produces. A dirfd-relative stat with a real path stays denied.
    fn appendFstatOnFdPolicy(program: []sock_filter, len: *usize) void {
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg3HighOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 0, 5));
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg3LowOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, at_empty_path, 0, 3));
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0LowOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, at_fdcwd_low, 1, 0));
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
    }

    fn appendAtFdcwdPolicy(program: []sock_filter, len: *usize, low_offset: u32) void {
        // The dirfd argument is a kernel `int`, so the kernel reads only its
        // low 32 bits. Callers may leave the high word sign-extended
        // (0xffffffff, as `fs.cpp` passes it) or zero-extended (a 32-bit move,
        // as in libc's `*at` wrappers), and both mean AT_FDCWD. The filter
        // matches the low word alone, like the kernel. A real fd is a small
        // positive integer and never equals AT_FDCWD's low word (0xffffff9c),
        // so every other dirfd is still denied.
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, low_offset));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, at_fdcwd_low, 1, 0));
        append(program, len, denyPerm());
    }

    fn appendFlagsAllowMaskPolicy(
        program: []sock_filter,
        len: *usize,
        low_offset: u32,
        high_offset: u32,
        allowed_flags: u32,
    ) void {
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, high_offset));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, low_offset));
        append(program, len, jump(bpf.JMP | bpf.JSET | bpf.K, ~allowed_flags, 0, 1));
        append(program, len, denyPerm());
    }

    const at_fdcwd_low: u32 = @bitCast(@as(i32, linux.AT.FDCWD));
    const at_empty_path: u32 = linux.AT.EMPTY_PATH;
    const stat_at_common_allowed_flags: u32 = linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT;
    const newfstatat_allowed_flags: u32 = stat_at_common_allowed_flags;
    const statx_allowed_flags: u32 = stat_at_common_allowed_flags | linux.AT.STATX_SYNC_TYPE;
    const openat_access_mode_mask: u32 = 0x3;
    const openat_allowed_flags: u32 =
        openat_access_mode_mask |
        @as(u32, @bitCast(linux.O{ .CREAT = true })) |
        @as(u32, @bitCast(linux.O{ .TRUNC = true })) |
        @as(u32, @bitCast(linux.O{ .DIRECTORY = true })) |
        @as(u32, @bitCast(linux.O{ .CLOEXEC = true }));
    const openat_forbidden_flags: u32 = ~openat_allowed_flags;

    fn appendFcntlPolicy(program: []sock_filter, len: *usize) void {
        const jump_index = beginSyscallPolicy(program, len, "fcntl") orelse return;
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg1HighOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg1LowOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, linux_f_getfd, 3, 0));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, linux_f_getfl, 2, 0));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, linux_f_get_seals, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(program, len.*, jump_index);
    }

    const linux_f_getfd: u32 = 1;
    const linux_f_getfl: u32 = 3;
    const linux_f_get_seals: u32 = 1034;
    fn appendX86_64CompatGuards(program: []sock_filter, len: *usize) void {
        if (comptime builtin.target.cpu.arch != .x86_64)
            return;

        const x32_syscall_bit: u32 = 0x40000000;
        append(program, len, jump(bpf.JMP | bpf.JSET | bpf.K, x32_syscall_bit, 0, 1));
        append(program, len, denyPerm());

        append(program, len, jump(bpf.JMP | bpf.JGE | bpf.K, 512, 0, 2));
        append(program, len, jump(bpf.JMP | bpf.JGT | bpf.K, 547, 1, 0));
        append(program, len, denyPerm());
    }

    fn hasSyscall(comptime name: []const u8) bool {
        return @hasField(linux.SYS, name);
    }

    fn syscallNumber(comptime name: []const u8) u32 {
        return @intFromEnum(@field(linux.SYS, name));
    }

    fn auditArchCurrent() u32 {
        return switch (builtin.target.cpu.arch) {
            .x86_64 => 0xc000003e,
            .aarch64 => 0xc00000b7,
            else => @compileError("worker seccomp audit arch is not defined for this target"),
        };
    }

    fn append(program: []sock_filter, len: *usize, instruction: sock_filter) void {
        program[len.*] = instruction;
        len.* += 1;
    }

    fn beginSyscallPolicy(
        program: []sock_filter,
        len: *usize,
        comptime name: []const u8,
    ) ?usize {
        if (comptime !hasSyscall(name))
            return null;
        return beginSyscallNumberPolicy(program, len, syscallNumber(name));
    }

    fn beginSyscallNumberPolicy(program: []sock_filter, len: *usize, syscall_number: u32) usize {
        const jump_index = len.*;
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, syscall_number, 0, 0));
        return jump_index;
    }

    fn endSyscallPolicy(program: []sock_filter, len: usize, jump_index: usize) void {
        std.debug.assert(jump_index < len);
        const block_len = len - jump_index - 1;
        std.debug.assert(block_len <= std.math.maxInt(u8));
        program[jump_index].jf = @intCast(block_len);
    }

    fn stmt(code: u16, k: u32) sock_filter {
        return .{ .code = code, .jt = 0, .jf = 0, .k = k };
    }

    fn jump(code: u16, k: u32, jt: u8, jf: u8) sock_filter {
        return .{ .code = code, .jt = jt, .jf = jf, .k = k };
    }

    fn denyPerm() sock_filter {
        return stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ERRNO | @as(u32, @intFromEnum(linux.E.PERM)));
    }

    fn arg0LowOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg0"));
    }

    fn arg0HighOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg0") + @sizeOf(u32));
    }

    fn arg1LowOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg1"));
    }

    fn arg1HighOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg1") + @sizeOf(u32));
    }

    fn arg2LowOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg2"));
    }

    fn arg2HighOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg2") + @sizeOf(u32));
    }

    fn arg3LowOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg3"));
    }

    fn arg3HighOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg3") + @sizeOf(u32));
    }

    fn arg4LowOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg4"));
    }

    fn arg4HighOffset() u32 {
        return @intCast(@offsetOf(linux.SECCOMP.data, "arg4") + @sizeOf(u32));
    }

    fn newFstatAtSyscallNumber() ?u32 {
        if (comptime @hasField(linux.SYS, "newfstatat"))
            return @intFromEnum(@field(linux.SYS, "newfstatat"));
        if (comptime @hasField(linux.SYS, "fstatat"))
            return @intFromEnum(@field(linux.SYS, "fstatat"));
        if (comptime @hasField(linux.SYS, "fstatat64"))
            return @intFromEnum(@field(linux.SYS, "fstatat64"));
        return null;
    }
};

pub const mounts = struct {
    fn makePrivate() !void {
        const rc = linux.mount(null, "/", null, linux.MS.PRIVATE | linux.MS.REC, 0);
        return switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .PERM => error.PermissionDenied,
            .INVAL => error.UnsupportedKernel,
            .BADF => error.UnsupportedKernel,
            else => error.WorkerSandboxOperationFailed,
        };
    }
};

pub const rootfs = struct {
    const proc_fd_path_buffer_bytes: usize = 64;
    const tmpfs_mount_data_buffer_bytes: usize = 128;

    fn mountTmpfsAndChrootIntoFd(config: Config) !void {
        if (config.tmpfs_size_bytes == 0)
            return error.InvalidWorkerTmpRoot;

        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target_path = try tmpRootPathFromFd(config.tmp_root_fd, &path_buffer);
        const owner_uid: u32 = @intCast(linux.getuid());
        const owner_gid: u32 = @intCast(linux.getgid());

        try mountTmpfsAt(target_path, config.tmpfs_size_bytes, owner_uid, owner_gid);

        var mounted_root = try std.fs.openDirAbsolute(target_path, .{ .no_follow = true });
        defer mounted_root.close();
        try validateMountedRootFd(mounted_root.fd, owner_uid, owner_gid);
        try chrootIntoFd(mounted_root.fd);
    }

    fn tmpRootPathFromFd(tmp_root_fd: std.posix.fd_t, out_buffer: []u8) ![]const u8 {
        var proc_fd_path_buffer: [proc_fd_path_buffer_bytes]u8 = undefined;
        const proc_fd_path = std.fmt.bufPrintZ(
            &proc_fd_path_buffer,
            "/proc/self/fd/{d}",
            .{tmp_root_fd},
        ) catch return error.InvalidWorkerTmpRoot;
        const target_path = std.posix.readlinkZ(proc_fd_path.ptr, out_buffer) catch |err| switch (err) {
            error.AccessDenied => return error.PermissionDenied,
            error.FileNotFound => return error.InvalidWorkerTmpRoot,
            error.NameTooLong => return error.InvalidWorkerTmpRoot,
            else => return error.WorkerSandboxOperationFailed,
        };
        if (target_path.len == 0)
            return error.InvalidWorkerTmpRoot;
        if (target_path[0] != '/')
            return error.InvalidWorkerTmpRoot;
        return target_path;
    }

    fn mountTmpfsAt(target_path: []const u8, size_bytes: u64, owner_uid: u32, owner_gid: u32) !void {
        const target_path_z = std.posix.toPosixPath(target_path) catch return error.InvalidWorkerTmpRoot;
        var mount_data_buffer: [tmpfs_mount_data_buffer_bytes]u8 = undefined;
        const mount_data = std.fmt.bufPrintZ(
            &mount_data_buffer,
            "size={d},mode=0700,uid={d},gid={d}",
            .{ size_bytes, owner_uid, owner_gid },
        ) catch return error.InvalidWorkerTmpRoot;

        const flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC;
        const rc = linux.mount(
            "tmpfs",
            &target_path_z,
            "tmpfs",
            flags,
            @intFromPtr(mount_data.ptr),
        );
        return switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .ACCES => error.PermissionDenied,
            .BUSY => error.WorkerSandboxOperationFailed,
            .INVAL => error.UnsupportedKernel,
            .NOMEM => error.SystemResources,
            .NOTDIR => error.InvalidWorkerTmpRoot,
            .PERM => error.PermissionDenied,
            else => error.WorkerSandboxOperationFailed,
        };
    }

    fn validateMountedRootFd(fd: std.posix.fd_t, owner_uid: u32, owner_gid: u32) !void {
        var stat: linux.Stat = undefined;
        switch (linux_helpers.syscallErrno(linux.fstat(fd, &stat))) {
            .SUCCESS => {},
            .BADF => return error.InvalidWorkerTmpRoot,
            else => return error.InvalidWorkerTmpRoot,
        }
        if ((stat.mode & linux.S.IFMT) != linux.S.IFDIR)
            return error.InvalidWorkerTmpRoot;
        if ((stat.mode & 0o7777) != tmp_root.required_mode)
            return error.PermissionDenied;
        if (stat.uid != owner_uid)
            return error.PermissionDenied;
        if (stat.gid != owner_gid)
            return error.PermissionDenied;
    }

    fn chrootIntoFd(tmp_root_fd: std.posix.fd_t) !void {
        try std.posix.fchdir(tmp_root_fd);
        const rc = linux.chroot(".");
        switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .ACCES => return error.PermissionDenied,
            .FAULT => return error.InvalidWorkerTmpRoot,
            .IO => return error.InputOutput,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .BADF => return error.InvalidWorkerTmpRoot,
            else => return error.WorkerSandboxOperationFailed,
        }
        try std.posix.chdir("/");
    }
};
