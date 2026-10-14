//! The worker's sandbox, which the forked child applies in three steps on its
//! one thread (`child_boot.zig` orders them): user, mount and network
//! namespaces first, while the child is single-threaded; then resource
//! limits, no-new-privileges, the root and the capability drop; and last,
//! once every thread exists, the seccomp allowlist on all threads. A syscall
//! outside the allowlist fails with EPERM, and a syscall from a foreign
//! architecture kills the process. The child keeps no route to the network,
//! the machine's filesystem or new threads.
//!
//! The root is a tmpfs of `WorkerInit`'s size, mounted over `/tmp` in the
//! child's private mount namespace, so the host never sees it. Inside it,
//! `tmp/` is bound onto itself and stays writable, while the rest of the
//! root, `var/task/` (`task_root`, the working directory) included, is
//! read-only, because the root's mount carries `MS_RDONLY` and the bind does
//! not. The kernel enforces both for every caller, `node:fs` and code that
//! escapes the engine alike, and nothing in the worker can lift them: the
//! capabilities a remount needs go with the drop, and the filter denies
//! `mount`, `umount2`, `chroot`, `pivot_root`, `unshare` and `setns`, so the
//! worker can neither remount nor reach a namespace where it would hold them.

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("collo_ipc");
const linux_helpers = @import("collo_os").linux;
const linux = std.os.linux;

/// The worker's working directory, read-only and empty: the directory the
/// keys of a definition's modules name (`module_pack.zig:task_root`), where a
/// route's files would sit.
pub const task_root = ipc.module_pack.task_root;

pub const Config = struct {
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
/// tmpfs mount, the bind, the read-only remount and the chroot;
/// dropCapabilities then gives them up.
pub fn applyPreThread(config: Config) !void {
    try limits.apply(config);
    try privileges.disableNewPrivs();
    try mounts.makePrivate();
    try rootfs.build(config.tmpfs_size_bytes);
    try privileges.dropCapabilities();
}

/// Installs the worker's filter (`security.instructions`) on every thread.
pub fn applySeccomp() !void {
    try security.apply();
}

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
    /// routes; there is no host-network mode.
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

/// The worker's one seccomp filter: `allowed_syscalls` plus the calls the
/// argument policies of `buildTemplate` admit, everything else failing with
/// EPERM, so worker code cannot gain new authority. The program is built at
/// compile time, and each argument policy fails the build on a target that
/// lacks its syscall, so every policy is in the program on every target.
pub const security = struct {
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
        // Descriptor I/O on fds handed in before seccomp. The engine reads
        // its leaf's `memory.current` with pread64
        // (`bindings/root.zig:setMemoryStatusOverride`).
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

        // Filesystem operations inside the worker's root, which the chroot
        // confines and whose read-only mount refuses every write outside
        // `/tmp`; the open and create calls are also filtered by argument
        // before this list is checked. Nothing in a worker resizes a file
        // after the filter (`node:fs` truncates with O_TRUNC), so ftruncate
        // stays out.
        "openat",
        "getdents64",
        "mkdirat",
        "unlinkat",
        "renameat2",
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

        // Signals. Every thread exists before this filter is installed, so
        // clone and fork are denied.
        "rt_sigreturn",
        "rt_sigprocmask",
        "rt_sigaction",

        // A thread's own start. A thread created before this filter runs its
        // start code only when the scheduler first picks it, which under CPU
        // contention can come after the filter, so the calls a thread makes
        // at its own start must pass. glibc registers the thread's rseq area,
        // aborting the whole process when it cannot, and its robust-futex
        // list, which the thread otherwise lacks; WTF names the thread with
        // prctl(PR_SET_NAME), which `appendPrctlPolicy` admits. Each call
        // touches only the calling thread.
        "rseq",
        "set_robust_list",

        // Waits. The event loop and the sentinel wait in ppoll, whose timeout
        // is their earliest deadline; `std.posix.poll` issues poll on x86-64.
        "poll",
        "ppoll",
        "ppoll_time64",

        // Kernel restart after an interrupted allowed syscall.
        "restart_syscall",

        // Thread and process exit.
        "exit",
        "exit_group",
    };

    /// The worker's filter program, which `apply` hands the kernel as it is;
    /// tests evaluate it instruction by instruction.
    pub const instructions: []const FilterInstruction = template.program[0..template.len];

    comptime {
        // The kernel's BPF_MAXINSNS, and `sock_fprog.len` is a u16.
        std.debug.assert(instructions.len <= 4096);
    }

    /// Installs `instructions` on every thread of the process (`TSYNC`). The
    /// process must have set no-new-privileges, or hold CAP_SYS_ADMIN.
    fn apply() !void {
        const filter = sock_fprog{
            .len = @intCast(instructions.len),
            .filter = instructions.ptr,
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

    const Template = struct {
        program: [template_capacity]sock_filter,
        len: usize,
    };

    const template: Template = buildTemplate();

    fn buildTemplate() Template {
        var built = Template{ .program = undefined, .len = 0 };
        append(&built.program, &built.len, stmt(bpf.LD | bpf.W | bpf.ABS, @intCast(@offsetOf(linux.SECCOMP.data, "arch"))));
        append(&built.program, &built.len, jump(bpf.JMP | bpf.JEQ | bpf.K, auditArchCurrent(), 1, 0));
        append(&built.program, &built.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.KILL_PROCESS));
        append(&built.program, &built.len, stmt(bpf.LD | bpf.W | bpf.ABS, @intCast(@offsetOf(linux.SECCOMP.data, "nr"))));
        appendX86_64CompatGuards(&built.program, &built.len);
        appendNewFstatAtPolicy(&built.program, &built.len);
        appendStatxPolicy(&built.program, &built.len);
        appendOpenAtPolicy(&built.program, &built.len);
        appendMkdirAtPolicy(&built.program, &built.len);
        appendUnlinkAtPolicy(&built.program, &built.len);
        appendRenameAt2Policy(&built.program, &built.len);
        appendFcntlPolicy(&built.program, &built.len);
        appendPrctlPolicy(&built.program, &built.len);

        // A name the target does not have, such as `poll` on aarch64 or the
        // `*_time64` calls on a 64-bit target, has no number to allow.
        inline for (allowed_syscalls) |name| {
            if (comptime hasSyscall(name)) {
                append(&built.program, &built.len, jump(bpf.JMP | bpf.JEQ | bpf.K, syscallNumber(name), 0, 1));
                append(&built.program, &built.len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
            }
        }

        append(&built.program, &built.len, denyPerm());
        return built;
    }

    // BPF compares 32-bit words, so every argument policy below that compares
    // a value requires its high word to be zero: the filter then sees exactly
    // the value the kernel uses. A dirfd is the exception, matched on its low
    // word alone as the kernel reads it (`appendAtFdcwdPolicy`).

    fn appendOpenAtPolicy(program: []sock_filter, len: *usize) void {
        const jump_index = beginSyscallPolicy(program, len, "openat");
        appendAtFdcwdPolicy(program, len, arg0LowOffset());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg2HighOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg2LowOffset()));
        append(program, len, jump(bpf.JMP | bpf.JSET | bpf.K, openat_forbidden_flags, 0, 1));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(program, len.*, jump_index);
    }

    fn appendNewFstatAtPolicy(program: []sock_filter, len: *usize) void {
        const jump_index = beginSyscallNumberPolicy(program, len, newFstatAtSyscallNumber());
        appendFstatOnFdPolicy(program, len);
        appendAtFdcwdPolicy(program, len, arg0LowOffset());
        appendFlagsAllowMaskPolicy(program, len, arg3LowOffset(), arg3HighOffset(), newfstatat_allowed_flags);
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(program, len.*, jump_index);
    }

    fn appendStatxPolicy(program: []sock_filter, len: *usize) void {
        const jump_index = beginSyscallPolicy(program, len, "statx");
        appendAtFdcwdPolicy(program, len, arg0LowOffset());
        appendFlagsAllowMaskPolicy(program, len, arg2LowOffset(), arg2HighOffset(), statx_allowed_flags);
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(program, len.*, jump_index);
    }

    fn appendMkdirAtPolicy(program: []sock_filter, len: *usize) void {
        const jump_index = beginSyscallPolicy(program, len, "mkdirat");
        appendAtFdcwdPolicy(program, len, arg0LowOffset());
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(program, len.*, jump_index);
    }

    // The runtime calls unlinkat and renameat2 only with flags 0
    // (`bindings/host_functions/node/fs.cpp`), so any other flag, such as
    // AT_REMOVEDIR or RENAME_EXCHANGE, is denied.
    fn appendUnlinkAtPolicy(program: []sock_filter, len: *usize) void {
        const jump_index = beginSyscallPolicy(program, len, "unlinkat");
        appendAtFdcwdPolicy(program, len, arg0LowOffset());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg2HighOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg2LowOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(program, len.*, jump_index);
    }

    fn appendRenameAt2Policy(program: []sock_filter, len: *usize) void {
        const jump_index = beginSyscallPolicy(program, len, "renameat2");
        appendAtFdcwdPolicy(program, len, arg0LowOffset());
        appendAtFdcwdPolicy(program, len, arg2LowOffset());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg4HighOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg4LowOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(program, len.*, jump_index);
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
        const jump_index = beginSyscallPolicy(program, len, "fcntl");
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

    // prctl takes only PR_SET_NAME, which a thread may call at its own start
    // (see "rseq" in `allowed_syscalls`). It copies at most 16 bytes into
    // the calling thread's name and reaches no other task, capability or
    // resource, so a worker that runs native code gains only the power to
    // rename its own threads. Every other option stays denied, among them
    // PR_GET_NAME, PR_SET_DUMPABLE, PR_SET_SECCOMP, PR_SET_MM, PR_SET_PTRACER
    // and PR_CAP_AMBIENT.
    fn appendPrctlPolicy(program: []sock_filter, len: *usize) void {
        const jump_index = beginSyscallPolicy(program, len, "prctl");
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0HighOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0LowOffset()));
        append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, pr_set_name, 1, 0));
        append(program, len, denyPerm());
        append(program, len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));
        endSyscallPolicy(program, len.*, jump_index);
    }

    const pr_set_name: u32 = @intCast(@intFromEnum(linux.PR.SET_NAME));

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

    /// Opens the block of an argument policy. A target without the syscall
    /// fails the build, so no policy is ever left out of the program.
    fn beginSyscallPolicy(
        program: []sock_filter,
        len: *usize,
        comptime name: []const u8,
    ) usize {
        if (comptime !hasSyscall(name))
            @compileError("the worker filter's argument policy needs syscall " ++ name ++ " on this target");
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

    /// The number of `newfstatat`, which each target's table names its own
    /// way.
    fn newFstatAtSyscallNumber() u32 {
        if (comptime @hasField(linux.SYS, "newfstatat"))
            return @intFromEnum(@field(linux.SYS, "newfstatat"));
        if (comptime @hasField(linux.SYS, "fstatat"))
            return @intFromEnum(@field(linux.SYS, "fstatat"));
        if (comptime @hasField(linux.SYS, "fstatat64"))
            return @intFromEnum(@field(linux.SYS, "fstatat64"));
        @compileError("the worker filter's stat policy needs newfstatat on this target");
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

/// The worker's root, as the file header describes it.
pub const rootfs = struct {
    /// Where the tmpfs is mounted before the chroot. The mount lives in the
    /// child's private mount namespace and the host never sees it, so any
    /// directory every host has will do.
    const mount_point = "/tmp";
    /// The root's only writable directory.
    const writable_dir = "tmp";
    /// `task_root` relative to the root, and its parent.
    const task_dir = task_root[1..];
    const task_parent_dir = std.fmt.comptimePrint("{s}", .{std.fs.path.dirname(task_dir).?});
    const root_mode: u32 = 0o700;
    const writable_dir_mode: u32 = 0o700;
    const read_only_dir_mode: u32 = 0o755;
    /// The tmpfs mount's flags. The read-only remount repeats them, since a
    /// remount replaces every flag of the mount.
    const mount_flags: u32 = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC;
    const tmpfs_mount_data_buffer_bytes: usize = 128;

    comptime {
        // `layout` creates `task_root` as two directories under the root.
        std.debug.assert(task_root[0] == '/');
        std.debug.assert(std.mem.indexOfScalar(u8, task_parent_dir, '/') == null);
    }

    /// Mounts the tmpfs, lays the root out, makes all of it but `tmp/`
    /// read-only, chroots into it and enters `task_root`. Every step after
    /// the mount names paths relative to the root, which it makes the working
    /// directory first.
    fn build(size_bytes: u64) !void {
        if (size_bytes == 0)
            return error.InvalidTmpfsSize;
        const owner_uid: u32 = @intCast(linux.getuid());
        const owner_gid: u32 = @intCast(linux.getgid());
        try mountTmpfs(size_bytes, owner_uid, owner_gid);

        const root_fd = try openMountedRoot(owner_uid, owner_gid);
        defer std.posix.close(root_fd);
        try std.posix.fchdir(root_fd);
        try layout(root_fd);
        // The bind gives `tmp/` a mount of its own, on the same tmpfs and so
        // under the same size, which keeps write access when the root's mount
        // turns read-only: `MS_REMOUNT | MS_BIND` changes one mount's flags,
        // never the superblock's.
        try mountRelative(writable_dir, writable_dir, linux.MS.BIND);
        try mountRelative(null, ".", linux.MS.REMOUNT | linux.MS.BIND | linux.MS.RDONLY | mount_flags);
        try chrootIntoWorkingDirectory();
        try std.posix.chdir(task_root);
    }

    fn mountTmpfs(size_bytes: u64, owner_uid: u32, owner_gid: u32) !void {
        var mount_data_buffer: [tmpfs_mount_data_buffer_bytes]u8 = undefined;
        const mount_data = std.fmt.bufPrintZ(
            &mount_data_buffer,
            "size={d},mode={o},uid={d},gid={d}",
            .{ size_bytes, root_mode, owner_uid, owner_gid },
        ) catch return error.InvalidTmpfsSize;
        const rc = linux.mount("tmpfs", mount_point, "tmpfs", mount_flags, @intFromPtr(mount_data.ptr));
        return switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .ACCES, .PERM => error.PermissionDenied,
            .INVAL => error.UnsupportedKernel,
            .NOMEM => error.SystemResources,
            else => error.WorkerSandboxOperationFailed,
        };
    }

    /// Opens the root of the tmpfs just mounted over `mount_point` and checks
    /// it carries the mode and owner the mount set. The mount's own return
    /// code is what proves the tmpfs is there; this check only catches a
    /// directory that plainly is not it, since a machine's own `/tmp` of mode
    /// 0700 owned by the zygote's user and group reads the same inside the
    /// child's user namespace.
    fn openMountedRoot(owner_uid: u32, owner_gid: u32) !std.posix.fd_t {
        const fd = try std.posix.openZ(mount_point, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        errdefer std.posix.close(fd);
        var stat: linux.Stat = undefined;
        switch (linux_helpers.syscallErrno(linux.fstat(fd, &stat))) {
            .SUCCESS => {},
            else => return error.InvalidWorkerRoot,
        }
        if ((stat.mode & linux.S.IFMT) != linux.S.IFDIR)
            return error.InvalidWorkerRoot;
        if ((stat.mode & 0o7777) != root_mode)
            return error.InvalidWorkerRoot;
        if (stat.uid != owner_uid)
            return error.InvalidWorkerRoot;
        if (stat.gid != owner_gid)
            return error.InvalidWorkerRoot;
        return fd;
    }

    /// Creates `tmp/` and `task_root` under the root with their exact modes,
    /// whatever umask the zygote inherited; the umask is restored after, so
    /// files the worker creates later keep the process's.
    fn layout(root_fd: std.posix.fd_t) !void {
        const inherited_umask = std.c.umask(0);
        defer _ = std.c.umask(inherited_umask);
        try makeDir(root_fd, writable_dir, writable_dir_mode);
        try makeDir(root_fd, task_parent_dir, read_only_dir_mode);
        try makeDir(root_fd, task_dir, read_only_dir_mode);
    }

    fn makeDir(root_fd: std.posix.fd_t, path: [*:0]const u8, mode: u32) !void {
        return switch (linux_helpers.syscallErrno(linux.mkdirat(root_fd, path, mode))) {
            .SUCCESS => {},
            .NOSPC, .NOMEM => error.SystemResources,
            else => error.WorkerSandboxOperationFailed,
        };
    }

    fn mountRelative(source: ?[*:0]const u8, target: [*:0]const u8, flags: u32) !void {
        return switch (linux_helpers.syscallErrno(linux.mount(source, target, null, flags, 0))) {
            .SUCCESS => {},
            .ACCES, .PERM => error.PermissionDenied,
            .INVAL => error.UnsupportedKernel,
            .NOMEM => error.SystemResources,
            else => error.WorkerSandboxOperationFailed,
        };
    }

    fn chrootIntoWorkingDirectory() !void {
        return switch (linux_helpers.syscallErrno(linux.chroot("."))) {
            .SUCCESS => {},
            .ACCES, .PERM => error.PermissionDenied,
            .NOMEM => error.SystemResources,
            else => error.WorkerSandboxOperationFailed,
        };
    }
};
