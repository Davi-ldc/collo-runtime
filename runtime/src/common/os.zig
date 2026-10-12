//! Linux descriptor, process and memory primitives shared by every process of
//! the runtime, grouped as `fd`, `process`, `socket`, `cmsg`, `linux` and
//! `memory`, and the libc calls the standard library lacks. Nothing here
//! keeps state. The calls the zygote's fork loop makes (`cloneForkWithPidFd`,
//! `writeOomScoreAdj`, `assertSingleThreadedSelf`) do not allocate. Every
//! socket option the runtime sets or reads goes through `socket`, one helper
//! per option.

const std = @import("std");
const c = @cImport({
    @cInclude("fcntl.h");
});

extern "c" fn pthread_getcpuclockid(thread: std.c.pthread_t, clock_id: *c_int) c_int;

pub const fd = struct {
    const f_dupfd_cloexec = if (@hasDecl(std.posix.F, "DUPFD_CLOEXEC"))
        std.posix.F.DUPFD_CLOEXEC
    else
        c.F_DUPFD_CLOEXEC;
    pub const memfd_seal_seal: usize = 0x0001;
    pub const memfd_seal_shrink: usize = 0x0002;
    pub const memfd_seal_grow: usize = 0x0004;
    pub const memfd_seal_write: usize = 0x0008;
    /// A memfd of fixed size whose content can still change.
    pub const memfd_size_seals: usize = memfd_seal_shrink | memfd_seal_grow | memfd_seal_seal;
    /// A memfd that no one can write, resize or seal further.
    pub const memfd_readonly_seals: usize = memfd_seal_write | memfd_seal_shrink | memfd_seal_grow | memfd_seal_seal;
    const f_add_seals: i32 = 1033;
    const f_get_seals: i32 = 1034;

    /// A borrowed fd; the holder must not close it.
    pub const FdRef = struct {
        raw_fd: std.posix.fd_t,

        pub fn fromRaw(raw_fd: std.posix.fd_t) FdRef {
            std.debug.assert(raw_fd >= 0);
            return .{ .raw_fd = raw_fd };
        }

        pub fn fd(self: FdRef) std.posix.fd_t {
            return self.raw_fd;
        }
    };

    /// An fd that `deinit` closes unless `release` handed it off; -1 means
    /// empty.
    pub const OwnedFd = struct {
        raw_fd: std.posix.fd_t = -1,

        pub fn fromRaw(raw_fd: std.posix.fd_t) OwnedFd {
            std.debug.assert(raw_fd >= 0);
            return .{ .raw_fd = raw_fd };
        }

        pub fn dupCloexec(source_fd: std.posix.fd_t) !OwnedFd {
            const duped: std.posix.fd_t = @intCast(try std.posix.fcntl(source_fd, f_dupfd_cloexec, 0));
            return .{ .raw_fd = duped };
        }

        pub fn dupCloexecAtLeast(source_fd: std.posix.fd_t, min_fd: std.posix.fd_t) !OwnedFd {
            std.debug.assert(min_fd >= 0);
            const duped: std.posix.fd_t = @intCast(try std.posix.fcntl(
                source_fd,
                f_dupfd_cloexec,
                @as(usize, @intCast(min_fd)),
            ));
            return .{ .raw_fd = duped };
        }

        pub fn fd(self: OwnedFd) std.posix.fd_t {
            std.debug.assert(self.raw_fd >= 0);
            return self.raw_fd;
        }

        pub fn isValid(self: OwnedFd) bool {
            return self.raw_fd >= 0;
        }

        pub fn borrow(self: OwnedFd) FdRef {
            return FdRef.fromRaw(self.raw_fd);
        }

        pub fn deinit(self: *OwnedFd) void {
            if (self.raw_fd >= 0) {
                std.posix.close(self.raw_fd);
                self.raw_fd = -1;
            }
        }

        pub fn release(self: *OwnedFd) std.posix.fd_t {
            std.debug.assert(self.raw_fd >= 0);
            const raw_fd = self.raw_fd;
            self.raw_fd = -1;
            return raw_fd;
        }
    };

    pub fn writeAllRaw(raw_fd: std.posix.fd_t, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const amount = try std.posix.write(raw_fd, bytes[written..]);
            if (amount == 0)
                return error.WriteZero;
            written += amount;
        }
    }

    pub fn addSeals(raw_fd: std.posix.fd_t, seals: usize) !void {
        _ = try std.posix.fcntl(raw_fd, f_add_seals, seals);
    }

    pub fn getSeals(raw_fd: std.posix.fd_t) !usize {
        return try std.posix.fcntl(raw_fd, f_get_seals, 0);
    }

    /// Fails with `error.MissingFdSeals` unless every seal in `expected` is
    /// set; extra seals are fine.
    pub fn requireSeals(raw_fd: std.posix.fd_t, expected: usize) !void {
        const actual = try getSeals(raw_fd);
        if ((actual & expected) != expected)
            return error.MissingFdSeals;
    }

    /// Checks through the fd's /proc/self/fd link, so it needs /proc and
    /// fails with `error.InvalidFdType` after the worker's chroot.
    pub fn requireEventFd(raw_fd: std.posix.fd_t) !void {
        try requireProcFdTarget(raw_fd, "anon_inode:[eventfd]");
    }

    pub fn procFdTarget(raw_fd: std.posix.fd_t, out: []u8) ![]const u8 {
        std.debug.assert(raw_fd >= 0);
        var path_buffer: [64]u8 = undefined;
        const proc_fd_path = try std.fmt.bufPrintZ(&path_buffer, "/proc/self/fd/{d}", .{
            raw_fd,
        });
        return std.posix.readlinkZ(proc_fd_path.ptr, out);
    }

    fn requireProcFdTarget(raw_fd: std.posix.fd_t, expected: []const u8) !void {
        var target_buffer: [128]u8 = undefined;
        const target = procFdTarget(raw_fd, &target_buffer) catch return error.InvalidFdType;
        if (!std.mem.eql(u8, target, expected))
            return error.InvalidFdType;
    }

    /// fsync for a directory handle. std.fs opens non-iterating directories
    /// with O_PATH, and fsync on an O_PATH fd is EBADF by kernel rule, so the
    /// durable-directory sync reopens `.` as a plain O_RDONLY fd first.
    pub fn fsyncDirectory(dir: std.fs.Dir) !void {
        const sync_fd = try std.posix.openat(dir.fd, ".", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
        defer std.posix.close(sync_fd);
        const rc = std.os.linux.fsync(sync_fd);
        return switch (std.os.linux.E.init(rc)) {
            .SUCCESS => {},
            // A filesystem that cannot fsync a directory returns EINVAL. That
            // says nothing about the caller's write, so it is not an error.
            .INVAL => {},
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .DQUOT => error.DiskQuota,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    pub fn socketPairType(socket_type: u32) ![2]std.posix.fd_t {
        var fds: [2]std.posix.fd_t = undefined;
        const rc = std.c.socketpair(std.posix.AF.UNIX, socket_type, 0, &fds);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => fds,
            .NFILE => error.SystemFdQuotaExceeded,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NOMEM => error.SystemResources,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    pub fn setNonblocking(raw_fd: std.posix.fd_t, enabled: bool) !void {
        const flags = try std.posix.fcntl(raw_fd, std.posix.F.GETFL, 0);
        const nonblock_flag: usize = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        const next_flags = if (enabled)
            flags | nonblock_flag
        else
            flags & ~nonblock_flag;
        _ = try std.posix.fcntl(raw_fd, std.posix.F.SETFL, next_flags);
    }

    /// Closes every fd from `min_fd` up except those in `allow`, which it
    /// sorts in place. Without close_range it closes them one by one, up to
    /// the RLIMIT_NOFILE soft limit.
    pub fn closeAllExceptFrom(min_fd: std.posix.fd_t, allow: []std.posix.fd_t) !void {
        insertionSortFds(allow);
        var next = min_fd;
        for (allow) |allowed| {
            if (allowed < next)
                continue;
            if (allowed > next and allowed > 0)
                try closeRangeOrLoop(next, @intCast(allowed - 1), allow);
            next = allowed + 1;
        }
        try closeRangeOrLoop(next, std.math.maxInt(u32), allow);
    }

    /// Opens /dev/null on stdin, stdout and stderr unless `allow` keeps them,
    /// so those numbers are never free for the next open to reuse.
    pub fn redirectUnallowedStandardFdsToDevNull(allow: []const std.posix.fd_t) !void {
        const standard_fds = [_]std.posix.fd_t{ std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO };
        for (standard_fds) |target_fd| {
            if (containsFd(allow, target_fd))
                continue;
            const access: std.posix.ACCMODE = if (target_fd == std.posix.STDIN_FILENO) .RDONLY else .WRONLY;
            const null_fd = try std.posix.openZ("/dev/null", .{ .ACCMODE = access, .CLOEXEC = true }, 0);
            if (null_fd == target_fd)
                continue;
            errdefer std.posix.close(null_fd);
            try std.posix.dup2(null_fd, target_fd);
            std.posix.close(null_fd);
        }
    }

    fn containsFd(fds: []const std.posix.fd_t, target: std.posix.fd_t) bool {
        for (fds) |fd_value| {
            if (fd_value == target)
                return true;
        }
        return false;
    }

    fn closeRangeOrLoop(first: std.posix.fd_t, last: u32, allow: []const std.posix.fd_t) !void {
        if (first < 0)
            return;
        const first_u32: u32 = @intCast(first);
        if (first_u32 > last)
            return;
        const rc = std.os.linux.syscall3(.close_range, first_u32, last, 0);
        return switch (std.os.linux.E.init(rc)) {
            .SUCCESS => {},
            .NOSYS, .INVAL => closeRangeFallback(first_u32, last, allow),
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    fn closeRangeFallback(first: u32, last: u32, allow: []const std.posix.fd_t) !void {
        const limit = std.posix.getrlimit(.NOFILE) catch std.posix.rlimit{
            .cur = 4096,
            .max = 4096,
        };
        const capped_last = @min(last, std.math.cast(u32, limit.cur) orelse std.math.maxInt(u32));
        var fd_value = first;
        while (fd_value <= capped_last) : (fd_value += 1) {
            const raw_fd: std.posix.fd_t = @intCast(fd_value);
            if (fdAllowed(raw_fd, allow))
                continue;
            closeIgnoreBadFd(raw_fd);
            if (fd_value == std.math.maxInt(u32))
                break;
        }
    }

    fn closeIgnoreBadFd(raw_fd: std.posix.fd_t) void {
        const rc = std.os.linux.close(raw_fd);
        switch (std.os.linux.E.init(rc)) {
            .SUCCESS, .BADF => {},
            else => {},
        }
    }

    fn fdAllowed(raw_fd: std.posix.fd_t, allow: []const std.posix.fd_t) bool {
        for (allow) |allowed|
            if (allowed == raw_fd)
                return true;
        return false;
    }

    fn insertionSortFds(values: []std.posix.fd_t) void {
        var index: usize = 1;
        while (index < values.len) : (index += 1) {
            const value = values[index];
            var cursor = index;
            while (cursor > 0 and values[cursor - 1] > value) : (cursor -= 1)
                values[cursor] = values[cursor - 1];
            values[cursor] = value;
        }
    }
};

pub const process = struct {
    pub const SpawnFdMap = struct {
        source_fd: std.posix.fd_t,
        target_fd: std.posix.fd_t,
    };

    pub const SpawnInternalOptions = struct {
        exe_path_z: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
        fd_map: []const SpawnFdMap,
    };

    /// A process `spawnInternal` started.
    pub const SpawnedProcess = struct {
        pid: u32,
        /// Created by the clone that created the child (CLONE_PIDFD), so the
        /// child never exists without a handle that can signal it and wait
        /// for it, and a pid the kernel reuses after its exit is never
        /// mistaken for it.
        pidfd: fd.OwnedFd,
    };

    /// The stack the spawned child runs on until its exec. The child calls
    /// only raw system calls, each a frame of a few hundred bytes, so this is
    /// far more than it uses.
    const spawn_child_stack_bytes: usize = 64 * 1024;
    /// The exit status of a spawned child whose setup or exec failed. The
    /// parent reports the failure from the errno the child leaves in
    /// `SpawnChild.errno`, never from this status.
    const spawn_child_failure_status: u8 = 127;
    /// The kernel's `SIG_DFL` and `SIG_IGN` handler values.
    const signal_handler_default: usize = 0;
    const signal_handler_ignore: usize = 1;

    /// What the parent hands its spawned child: both live in memory the two
    /// share until the child's exec (CLONE_VM).
    const SpawnChild = struct {
        options: *const SpawnInternalOptions,
        /// The errno of the step that failed, written by the child before it
        /// exits; 0 while every step succeeded.
        errno: u16 = 0,
    };

    /// Starts a runtime binary and returns it with its pidfd. Each `fd_map`
    /// source is dup2'd onto its target and every other descriptor from 3 up
    /// is closed, close-on-exec or not; the child starts with an empty signal
    /// mask in a session of its own, with the standard descriptors of the
    /// caller. Targets must be 3 or above, and no source may equal any
    /// mapping's target. A child whose setup or exec fails is reaped before
    /// this returns that failure's error.
    ///
    /// The child is a vfork-style clone (CLONE_VM | CLONE_VFORK) on a stack
    /// of its own, as glibc's posix_spawn makes it: no page table is copied
    /// and nothing is charged against overcommit, whatever the caller's size,
    /// and the calling thread waits until the child has exec'd or exited.
    /// Until then the child shares the caller's memory, so it runs only raw
    /// system calls and touches nothing but its stack and `SpawnChild`.
    pub fn spawnInternal(options: SpawnInternalOptions) !SpawnedProcess {
        std.debug.assert(options.fd_map.len != 0);
        for (options.fd_map) |mapping| {
            std.debug.assert(mapping.source_fd >= 0);
            std.debug.assert(mapping.target_fd >= 3);
            for (options.fd_map) |reserved| {
                std.debug.assert(mapping.source_fd != reserved.target_fd);
            }
        }
        const sys = std.os.linux;

        const stack = try std.posix.mmap(
            null,
            spawn_child_stack_bytes,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .STACK = true },
            -1,
            0,
        );
        defer std.posix.munmap(stack);

        // Every signal stays blocked from the clone until the child has
        // replaced each handler of the caller's with the default: a handler
        // that ran in the child before that would run on memory the child
        // shares with the caller.
        const all_signals = sys.sigfillset();
        var previous_mask: sys.sigset_t = undefined;
        switch (linux.syscallErrno(sys.sigprocmask(sys.SIG.SETMASK, &all_signals, &previous_mask))) {
            .SUCCESS => {},
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
        defer {
            const rc = sys.sigprocmask(sys.SIG.SETMASK, &previous_mask, null);
            // Restoring a mask the kernel just returned cannot fail.
            std.debug.assert(linux.syscallErrno(rc) == .SUCCESS);
        }

        var child: SpawnChild = .{ .options = &options };
        var pidfd: i32 = -1;
        const rc = sys.clone(
            spawnChildMain,
            @intFromPtr(stack.ptr) + stack.len,
            sys.CLONE.VM | sys.CLONE.VFORK | sys.CLONE.PIDFD | sys.SIG.CHLD,
            @intFromPtr(&child),
            &pidfd,
            0,
            null,
        );
        switch (linux.syscallErrno(rc)) {
            .SUCCESS => {},
            else => |errno| return spawnCloneError(errno),
        }
        // CLONE_VFORK resumed this thread only once the child exec'd or
        // exited, so its errno is final.
        var owned_pidfd = fd.OwnedFd.fromRaw(pidfd);
        const child_errno = @atomicLoad(u16, &child.errno, .acquire);
        if (child_errno != 0) {
            reapExitedChild(owned_pidfd.fd());
            owned_pidfd.deinit();
            return spawnChildError(@enumFromInt(child_errno));
        }
        return .{ .pid = @intCast(rc), .pidfd = owned_pidfd };
    }

    /// The spawned child's entry, on its own stack (`spawnInternal`). It
    /// returns only when a step failed, and its return value is its exit
    /// status.
    fn spawnChildMain(arg: usize) callconv(.c) u8 {
        const child: *SpawnChild = @ptrFromInt(arg);
        const errno = spawnChildExec(child.options);
        @atomicStore(u16, &child.errno, @intFromEnum(errno), .release);
        return spawn_child_failure_status;
    }

    /// The child's steps up to its exec, each a raw system call. Returns the
    /// errno of the step that failed; on success the exec never returns.
    fn spawnChildExec(options: *const SpawnInternalOptions) std.posix.E {
        const sys = std.os.linux;
        var signal: u8 = 1;
        while (signal < sys.NSIG) : (signal += 1) {
            if (signal == sys.SIG.KILL or signal == sys.SIG.STOP)
                continue;
            var current: sys.Sigaction = undefined;
            const read_errno = linux.syscallErrno(sys.sigaction(signal, null, &current));
            if (read_errno != .SUCCESS)
                return read_errno;
            const handler: usize = if (current.handler.handler) |function|
                @intFromPtr(function)
            else
                signal_handler_default;
            if (handler == signal_handler_default or handler == signal_handler_ignore)
                continue;
            const default_action: sys.Sigaction = .{
                .handler = .{ .handler = sys.SIG.DFL },
                .mask = sys.sigemptyset(),
                .flags = 0,
            };
            const reset_errno = linux.syscallErrno(sys.sigaction(signal, &default_action, null));
            if (reset_errno != .SUCCESS)
                return reset_errno;
        }

        // The child leads a new session with no controlling terminal. A
        // terminal sends Ctrl-C, Ctrl-Z and hangup to its whole foreground
        // process group, and a child left in the caller's group would die
        // alongside the caller instead of being stopped by it once the
        // requests in flight drain. Outside the terminal's session, the child
        // and everything it forks cannot be stopped by job control either, nor
        // push input into the terminal with TIOCSTI, which requires the
        // terminal to be the caller's controlling one.
        const session_errno = linux.syscallErrno(sys.syscall0(.setsid));
        if (session_errno != .SUCCESS)
            return session_errno;

        for (options.fd_map) |mapping| {
            // dup2 leaves the target without close-on-exec, so it survives
            // the exec; the source closes below or at the exec.
            const dup_errno = linux.syscallErrno(sys.dup2(mapping.source_fd, mapping.target_fd));
            if (dup_errno != .SUCCESS)
                return dup_errno;
        }
        const close_errno = closeEveryDescriptorButTargets(options.fd_map);
        if (close_errno != .SUCCESS)
            return close_errno;

        // A blocked signal mask survives exec, so a child spawned by a thread
        // that blocks SIGINT or SIGTERM, as a thread reading them from a
        // signalfd does, would ignore direct termination signals. The child
        // therefore starts with an empty mask whatever the caller's is.
        const empty_signals = sys.sigemptyset();
        const mask_errno = linux.syscallErrno(sys.sigprocmask(sys.SIG.SETMASK, &empty_signals, null));
        if (mask_errno != .SUCCESS)
            return mask_errno;

        return linux.syscallErrno(sys.execve(options.exe_path_z, options.argv, options.envp));
    }

    /// Closes every descriptor from 3 up that is not one of `fd_map`'s
    /// targets, in at most one close_range per gap between targets.
    fn closeEveryDescriptorButTargets(fd_map: []const SpawnFdMap) std.posix.E {
        const sys = std.os.linux;
        var first: u32 = 3;
        // Each pass finds the lowest target at or above `first`, so the loop
        // ends after one pass per target and a last one.
        var passes: usize = 0;
        while (passes <= fd_map.len) : (passes += 1) {
            var next_target: ?u32 = null;
            for (fd_map) |mapping| {
                const target: u32 = @intCast(mapping.target_fd);
                if (target < first)
                    continue;
                if (next_target == null or target < next_target.?)
                    next_target = target;
            }
            const gap_end: u32 = if (next_target) |target| target else std.math.maxInt(u32);
            if (next_target == null or gap_end > first) {
                const last: u32 = if (next_target != null) gap_end - 1 else gap_end;
                const errno = linux.syscallErrno(sys.syscall3(.close_range, first, last, 0));
                if (errno != .SUCCESS)
                    return errno;
            }
            const target = next_target orelse return .SUCCESS;
            first = target + 1;
        }
        return .SUCCESS;
    }

    /// Collects a spawned child that exited before its exec, through its
    /// pidfd. It has exited already (CLONE_VFORK), so the wait returns at
    /// once.
    fn reapExitedChild(pidfd: std.posix.fd_t) void {
        const sys = std.os.linux;
        var info: sys.siginfo_t = undefined;
        while (true) {
            const rc = sys.waitid(.PIDFD, pidfd, &info, sys.W.EXITED);
            switch (linux.syscallErrno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                // Only a caller that reaps every child behind its back, which
                // no runtime process does, leaves nothing to collect.
                else => |errno| {
                    std.log.warn("a spawned child that failed before its exec could not be reaped: {s}", .{
                        @tagName(errno),
                    });
                    return;
                },
            }
        }
    }

    fn spawnCloneError(errno: std.posix.E) error{
        SystemResources,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        PermissionDenied,
        Unexpected,
    } {
        return switch (errno) {
            .AGAIN, .NOMEM => error.SystemResources,
            // CLONE_PIDFD takes a descriptor slot in the caller.
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .PERM => error.PermissionDenied,
            else => std.posix.unexpectedErrno(errno),
        };
    }

    fn spawnChildError(errno: std.posix.E) error{
        FileNotFound,
        PermissionDenied,
        InvalidExe,
        NotDir,
        NameTooLong,
        SymLinkLoop,
        SystemResources,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        InvalidHandle,
        Unexpected,
    } {
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES, .PERM => error.PermissionDenied,
            .NOEXEC, .ISDIR, .LIBBAD => error.InvalidExe,
            .NOTDIR => error.NotDir,
            .NAMETOOLONG => error.NameTooLong,
            .LOOP => error.SymLinkLoop,
            .@"2BIG", .NOMEM, .AGAIN => error.SystemResources,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .BADF => error.InvalidHandle,
            else => std.posix.unexpectedErrno(errno),
        };
    }

    pub fn monotonicNowNs() !u64 {
        const ts = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    pub fn monotonicNowNsOrZero() u64 {
        return monotonicNowNs() catch 0;
    }

    pub fn countSelfTasks() !usize {
        var dir = try std.fs.openDirAbsolute("/proc/self/task", .{ .iterate = true });
        defer dir.close();

        var iterator = dir.iterate();
        var count: usize = 0;
        while (try iterator.next()) |_| {
            count += 1;
        }
        return count;
    }

    pub fn waitForSingleThreadedSelf(max_checks: u32, check_interval_ns: u64) !void {
        var checks: u32 = 0;
        while (checks < max_checks) {
            checks += 1;
            if (try countSelfTasks() <= 1)
                return;
            if (checks < max_checks)
                std.Thread.sleep(check_interval_ns);
        }
        return error.Timeout;
    }

    pub fn assertSingleThreadedSelf() !void {
        if (try countSelfTasks() != 1)
            return error.ProcessNotSingleThreaded;
    }

    /// The id the kernel gives a thread's CPU clock: what glibc's
    /// `pthread_getcpuclockid` builds from the thread id it caches, and what
    /// the kernel's `MAKE_THREAD_CPUCLOCK` names, `~tid << 3` with the
    /// per-thread bit and `CPUCLOCK_SCHED`. A clock of another thread of the
    /// caller's own thread group reads that thread's CPU time; the kernel
    /// refuses one of another process with EINVAL.
    pub fn threadCpuClockId(tid: std.os.linux.pid_t) std.os.linux.clockid_t {
        std.debug.assert(tid > 0);
        const cpuclock_perthread_mask: u32 = 4;
        const cpuclock_sched: u32 = 2;
        const negated_tid: u32 = ~@as(u32, @bitCast(tid));
        return @enumFromInt((negated_tid << 3) | cpuclock_perthread_mask | cpuclock_sched);
    }

    /// The CPU time `clock_id` reads, in nanoseconds. A clock the kernel
    /// refuses, such as the clock of a thread that is gone or of another
    /// process's thread, fails with `error.InvalidClock`. A thread CPU clock
    /// is not served by the vDSO, so each read is a system call.
    pub fn threadCpuNs(clock_id: std.os.linux.clockid_t) error{ InvalidClock, Unexpected }!u64 {
        var now: std.os.linux.timespec = undefined;
        const rc = std.os.linux.clock_gettime(clock_id, &now);
        return switch (linux.syscallErrno(rc)) {
            .SUCCESS => @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec)),
            .INVAL => error.InvalidClock,
            else => |errno| std.posix.unexpectedErrno(errno),
        };
    }

    /// The CPU clock id glibc gives the calling thread
    /// (`pthread_getcpuclockid(pthread_self())`), computed from the thread id
    /// glibc keeps in the thread's descriptor; no system call. It equals
    /// `threadCpuClockId(std.os.linux.gettid())` exactly when that cached id
    /// is the thread's own, which a raw clone keeps only by setting it
    /// (`CloneForkOptions.thread_id_word`).
    pub fn libcThreadCpuClockId() error{Unexpected}!std.os.linux.clockid_t {
        var clock_id: c_int = 0;
        const rc = pthread_getcpuclockid(std.c.pthread_self(), &clock_id);
        if (rc != 0)
            return std.posix.unexpectedErrno(@enumFromInt(@as(u16, @intCast(rc))));
        return @enumFromInt(@as(u32, @bitCast(clock_id)));
    }

    /// The calling thread's thread-id word: where glibc keeps the thread's id
    /// in the thread's descriptor, which it registers as the thread's
    /// `clear_child_tid` (`set_tid_address` at startup, CLONE_CHILD_CLEARTID
    /// for a thread it creates), so `PR_GET_TID_ADDRESS` returns it. The word
    /// is checked to hold the thread's id from the raw `gettid`, so a libc
    /// that keeps something else there fails here. The kernel answers
    /// `PR_GET_TID_ADDRESS` only when built with CONFIG_CHECKPOINT_RESTORE,
    /// and fails with `error.CheckpointRestoreUnavailable` otherwise.
    pub fn callingThreadIdWord() error{
        CheckpointRestoreUnavailable,
        ThreadIdWordUnset,
        ThreadIdWordMismatch,
        Unexpected,
    }!*std.os.linux.pid_t {
        const sys = std.os.linux;
        var address: usize = 0;
        const rc = sys.prctl(@intFromEnum(sys.PR.GET_TID_ADDRESS), @intFromPtr(&address), 0, 0, 0);
        switch (linux.syscallErrno(rc)) {
            .SUCCESS => {},
            .INVAL => return error.CheckpointRestoreUnavailable,
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
        if (address == 0)
            return error.ThreadIdWordUnset;
        if (address % @alignOf(sys.pid_t) != 0)
            return error.ThreadIdWordMismatch;
        const word: *sys.pid_t = @ptrFromInt(address);
        const volatile_word: *const volatile sys.pid_t = word;
        if (volatile_word.* != sys.gettid())
            return error.ThreadIdWordMismatch;
        return word;
    }

    /// Undoes `MADV_DONTFORK` on every mapping of the calling process so a
    /// fork child inherits the whole address space. JSC reserves its heaps
    /// (Structure heap, gigacage, JIT pool) with `MADV_DONTFORK`, which suits
    /// a fork followed by exec but breaks the zygote: a worker born without
    /// those mappings faults on the first cell it touches. Call it while
    /// single-threaded, after the last reservation and before the first fork;
    /// the kernel's own pages (vdso, vvar, vsyscall) are skipped. Returns how
    /// many mappings were advised.
    pub fn makeAddressSpaceForkInheritable() !usize {
        var file = try std.fs.openFileAbsolute("/proc/self/maps", .{});
        defer file.close();

        var buffer: [16 * 1024]u8 = undefined;
        var filled: usize = 0;
        var advised: usize = 0;
        while (true) {
            const read_len = try file.read(buffer[filled..]);
            if (read_len == 0) {
                if (filled != 0)
                    try adviseMappingForkInheritable(buffer[0..filled], &advised);
                return advised;
            }
            filled += read_len;
            var consumed: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buffer[0..filled], consumed, '\n')) |newline| {
                try adviseMappingForkInheritable(buffer[consumed..newline], &advised);
                consumed = newline + 1;
            }
            std.mem.copyForwards(u8, buffer[0..], buffer[consumed..filled]);
            filled -= consumed;
            if (filled == buffer.len)
                return error.MappingLineTooLong;
        }
    }

    /// One `/proc/self/maps` line: `start-end perms offset dev inode [path]`.
    fn adviseMappingForkInheritable(line: []const u8, advised: *usize) !void {
        if (line.len == 0)
            return;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const range = fields.next() orelse return error.InvalidMappingLine;
        _ = fields.next() orelse return error.InvalidMappingLine;
        _ = fields.next() orelse return error.InvalidMappingLine;
        _ = fields.next() orelse return error.InvalidMappingLine;
        _ = fields.next() orelse return error.InvalidMappingLine;
        const path = fields.next() orelse "";
        if (std.mem.startsWith(u8, path, "[v"))
            return;
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse return error.InvalidMappingLine;
        const start = std.fmt.parseUnsigned(usize, range[0..dash], 16) catch return error.InvalidMappingLine;
        const end = std.fmt.parseUnsigned(usize, range[dash + 1 ..], 16) catch return error.InvalidMappingLine;
        if (end <= start)
            return error.InvalidMappingLine;
        const rc = std.os.linux.madvise(@ptrFromInt(start), end - start, std.os.linux.MADV.DOFORK);
        switch (std.os.linux.E.init(rc)) {
            .SUCCESS => advised.* += 1,
            else => return error.MappingAdviseFailed,
        }
    }

    /// Start time of `pid` in clock ticks since boot: field 22 of
    /// `/proc/<pid>/stat`. Within one boot a (pid, start) pair names exactly
    /// one process incarnation, because a reused pid starts later, so a pair
    /// recorded by a process that is since gone never matches a live one.
    /// `error.ProcessNotFound` when no process has that pid.
    pub fn processStartTicks(pid: u32) !u64 {
        var path_buffer: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid}) catch unreachable;
        var file = std.fs.openFileAbsolute(proc_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ProcessNotFound,
            else => return err,
        };
        defer file.close();

        // comm is capped at 16 bytes and the remaining fields are integers,
        // so a stat line is a few hundred bytes; one that does not fit is a
        // format this parser does not know.
        var buffer: [1024]u8 = undefined;
        const stat_len = try file.readAll(&buffer);
        if (stat_len == buffer.len)
            return error.ProcStatTooLong;
        return parseProcStatStartTicks(buffer[0..stat_len]);
    }

    pub fn selfStartTicks() !u64 {
        return processStartTicks(@intCast(std.os.linux.getpid()));
    }

    /// Field 22 of a `/proc/<pid>/stat` line. comm (field 2) is printed in
    /// parentheses and may itself contain spaces and parentheses, so the
    /// fields are counted from the last `)`, after which field 3 comes first
    /// and field 22 is the twentieth.
    pub fn parseProcStatStartTicks(stat: []const u8) !u64 {
        const comm_end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse
            return error.InvalidProcStat;
        var fields = std.mem.tokenizeScalar(u8, stat[comm_end + 1 ..], ' ');
        var skipped: u32 = 0;
        while (skipped < 19) : (skipped += 1) {
            _ = fields.next() orelse return error.InvalidProcStat;
        }
        const start_field = fields.next() orelse return error.InvalidProcStat;
        return std.fmt.parseUnsigned(u64, start_field, 10) catch error.InvalidProcStat;
    }

    pub fn openPidFd(pid: u32) !std.posix.fd_t {
        const rc = std.os.linux.pidfd_open(@intCast(pid), 0);
        return switch (linux.syscallErrno(rc)) {
            .SUCCESS => @intCast(rc),
            .SRCH => error.ProcessNotFound,
            .INVAL => error.InvalidArgument,
            .PERM => error.PermissionDenied,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOMEM => error.SystemResources,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    /// Writes `/proc/<pid>/oom_score_adj` through the caller's procfs. A
    /// parent writes its fresh child's score: the child inherits the
    /// parent's across fork and exec, and a worker cannot write its own
    /// because its chroot has no /proc. Raising the value needs no
    /// capability; lowering it below the task's `oom_score_adj_min` fails
    /// with EACCES unless the writer has CAP_SYS_RESOURCE. That minimum is
    /// inherited with the score and stays 0 until a writer with
    /// CAP_SYS_RESOURCE sets a score. It does not allocate, so the zygote's
    /// fork loop can call it.
    pub fn writeOomScoreAdj(pid: u32, oom_score_adj: i16) !void {
        var path_buffer: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(
            &path_buffer,
            "/proc/{d}/oom_score_adj",
            .{pid},
        ) catch unreachable;
        const proc_fd = try std.posix.open(proc_path, .{
            .ACCMODE = .WRONLY,
            .CLOEXEC = true,
        }, 0);
        defer std.posix.close(proc_fd);

        var value_buffer: [8]u8 = undefined;
        const bytes = std.fmt.bufPrint(&value_buffer, "{d}", .{oom_score_adj}) catch unreachable;
        var remaining: []const u8 = bytes;
        while (remaining.len != 0) {
            const written = try std.posix.write(proc_fd, remaining);
            if (written == 0)
                return error.ShortWrite;
            remaining = remaining[written..];
        }
    }

    /// Linux clone_args (CLONE_ARGS_SIZE_VER2). Field order and widths are
    /// kernel ABI; the cgroup field requires kernel >= 5.7 (Collo requires
    /// >= 6.1).
    pub const CloneArgs = extern struct {
        flags: u64 = 0,
        pidfd: u64 = 0,
        child_tid: u64 = 0,
        parent_tid: u64 = 0,
        exit_signal: u64 = 0,
        stack: u64 = 0,
        stack_size: u64 = 0,
        tls: u64 = 0,
        set_tid: u64 = 0,
        set_tid_size: u64 = 0,
        cgroup: u64 = 0,
    };

    comptime {
        // The kernel validates the clone_args size it is handed; a drifted
        // layout must fail the build, not the syscall.
        std.debug.assert(@sizeOf(CloneArgs) == 88);
    }

    pub const CloneForkError = error{
        SystemResources,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        PermissionDenied,
        CgroupBusy,
        CgroupLimitReached,
        CgroupThreaded,
        InvalidHandle,
        Unexpected,
    };

    pub const CloneForkOptions = struct {
        /// The cgroup v2 directory the child is born inside
        /// (CLONE_INTO_CGROUP); null keeps the caller's cgroup.
        cgroup_dir_fd: ?std.posix.fd_t,
        /// The calling thread's thread-id word (`callingThreadIdWord`). The
        /// kernel writes the child's id into the child's copy of it before
        /// the child runs (CLONE_CHILD_SETTID) and clears it at the child's
        /// exit (CLONE_CHILD_CLEARTID), the two flags glibc's fork passes;
        /// the rest of what glibc's fork redoes in its child, such as
        /// registering the robust-futex list again, this clone does not.
        /// Without the word the child's glibc would keep the caller's id:
        /// `pthread_getcpuclockid`
        /// would name a thread of another process, and the owner of an
        /// error-checking, recursive or robust mutex the child locks would be
        /// the caller.
        thread_id_word: *std.os.linux.pid_t,
    };

    /// fork()-like clone3: returns 0 in the child and the child pid in the
    /// parent. The parent also receives an owned pidfd through `pidfd_out`
    /// (CLONE_PIDFD), so no racy post-fork pidfd_open is needed; in the child
    /// `pidfd_out` is left untouched and no pidfd exists in its fd table.
    /// The child gets its own thread id in glibc
    /// (`CloneForkOptions.thread_id_word`) and is born inside
    /// `options.cgroup_dir_fd` when it is set. Fails as `cloneForkError`
    /// says.
    ///
    /// Unlike libc fork(), raw clone3 runs no pthread_atfork handlers. That
    /// is safe only because the caller, the zygote's fork loop, checks that
    /// it is single-threaded and leaves the allocator and the VM untouched
    /// before forking.
    pub fn cloneForkWithPidFd(
        options: CloneForkOptions,
        pidfd_out: *std.posix.fd_t,
    ) CloneForkError!std.posix.pid_t {
        var pidfd_result: std.posix.fd_t = -1;
        var args = CloneArgs{
            .flags = std.os.linux.CLONE.PIDFD |
                std.os.linux.CLONE.CHILD_SETTID |
                std.os.linux.CLONE.CHILD_CLEARTID,
            .pidfd = @intFromPtr(&pidfd_result),
            .child_tid = @intFromPtr(options.thread_id_word),
            .exit_signal = std.posix.SIG.CHLD,
        };
        if (options.cgroup_dir_fd) |dir_fd| {
            std.debug.assert(dir_fd >= 0);
            args.flags |= std.os.linux.CLONE.INTO_CGROUP;
            args.cgroup = @intCast(dir_fd);
        }
        const rc = std.os.linux.syscall2(.clone3, @intFromPtr(&args), @sizeOf(CloneArgs));
        switch (linux.syscallErrno(rc)) {
            .SUCCESS => {},
            else => |errno| return cloneForkError(errno),
        }
        if (rc == 0)
            return 0;
        pidfd_out.* = pidfd_result;
        return @intCast(rc);
    }

    /// The error `cloneForkWithPidFd` returns for the errno of a failed
    /// clone3, which created no child.
    pub fn cloneForkError(errno: std.posix.E) CloneForkError {
        std.debug.assert(errno != .SUCCESS);
        return switch (errno) {
            .AGAIN, .NOMEM => error.SystemResources,
            // CLONE_PIDFD takes a descriptor slot in the parent for the pidfd,
            // so a full descriptor table, the process's or the system's, fails
            // the clone as it fails any other descriptor the parent creates.
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .ACCES, .PERM => error.PermissionDenied,
            // Target cgroup cannot accept the child: domain state, controller
            // constraint, or descendant limit.
            .BUSY => error.CgroupBusy,
            .NOSPC => error.CgroupLimitReached,
            .OPNOTSUPP => error.CgroupThreaded,
            .BADF => error.InvalidHandle,
            else => std.posix.unexpectedErrno(errno),
        };
    }

    pub fn pidFdSendSignal(pidfd: std.posix.fd_t, signal: u8) !void {
        const rc = std.os.linux.pidfd_send_signal(pidfd, signal, null, 0);
        return switch (linux.syscallErrno(rc)) {
            .SUCCESS => {},
            .SRCH => error.ProcessNotFound,
            .INVAL => error.InvalidArgument,
            .PERM => error.PermissionDenied,
            .BADF => error.InvalidHandle,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    pub fn pidFdHasExited(pidfd: std.posix.fd_t) bool {
        var pollfds = [1]std.posix.pollfd{
            .{
                .fd = pidfd,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            },
        };
        const ready = std.posix.poll(&pollfds, 0) catch return false;
        return ready > 0 and (pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
    }

    /// True once the process has exited, false when `timeout_ms` passes
    /// first.
    pub fn waitForPidFdExit(pidfd: std.posix.fd_t, timeout_ms: i32) !bool {
        var pollfds = [1]std.posix.pollfd{
            .{
                .fd = pidfd,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            },
        };
        const ready = try std.posix.poll(&pollfds, timeout_ms);
        return ready > 0 and (pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
    }
};

pub const socket = struct {
    pub fn setTcpNoDelay(raw_fd: std.posix.fd_t) !void {
        const enabled: c_int = 1;
        try std.posix.setsockopt(
            raw_fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&enabled),
        );
    }

    pub fn setTcpNotSentLowAt(raw_fd: std.posix.fd_t, byte_count: u32) !void {
        if (byte_count == 0)
            return;
        if (byte_count > std.math.maxInt(c_int))
            return error.TcpNotSentLowAtTooLarge;
        const low_watermark: c_int = @intCast(byte_count);
        try std.posix.setsockopt(
            raw_fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NOTSENT_LOWAT,
            std.mem.asBytes(&low_watermark),
        );
    }

    pub fn setReadWriteTimeouts(raw_fd: std.posix.fd_t, timeout_ms: u32) !void {
        const timeout = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        const bytes = std.mem.asBytes(&timeout);
        try std.posix.setsockopt(raw_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes);
        try std.posix.setsockopt(raw_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes);
    }

    /// SO_REUSEADDR, so a listener binds an address that connections of an earlier socket
    /// still hold in TIME_WAIT. Set it before `bind`.
    pub fn setReuseAddress(raw_fd: std.posix.fd_t) !void {
        try enableSocketOption(raw_fd, std.posix.SO.REUSEADDR);
    }

    /// SO_REUSEPORT: sockets of one user that all set it before `bind` share the address, and
    /// the kernel spreads incoming connections among them.
    pub fn setReusePort(raw_fd: std.posix.fd_t) !void {
        try enableSocketOption(raw_fd, std.posix.SO.REUSEPORT);
    }

    /// SO_INCOMING_CPU: the CPU whose received connections a reuseport listener prefers. Fails
    /// with `error.CpuIdOutOfRange` for an id the option's `int` cannot hold.
    pub fn setIncomingCpu(raw_fd: std.posix.fd_t, cpu_id: usize) !void {
        const cpu_id_c = std.math.cast(c_int, cpu_id) orelse return error.CpuIdOutOfRange;
        try std.posix.setsockopt(
            raw_fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.INCOMING_CPU,
            std.mem.asBytes(&cpu_id_c),
        );
    }

    /// SO_ATTACH_REUSEPORT_EBPF: the eBPF program behind `program_fd` picks
    /// which socket of the listener's reuseport group takes each new
    /// connection. Fails with `error.ReusePortBpfUnavailable` on a target
    /// whose headers lack the option.
    pub fn attachReuseportProgram(listener_fd: std.posix.fd_t, program_fd: std.posix.fd_t) !void {
        if (!@hasDecl(std.posix.SO, "ATTACH_REUSEPORT_EBPF"))
            return error.ReusePortBpfUnavailable;
        const program_fd_c: c_int = program_fd;
        try std.posix.setsockopt(
            listener_fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.ATTACH_REUSEPORT_EBPF,
            std.mem.asBytes(&program_fd_c),
        );
    }

    /// TCP_ULP "tls": attaches the kernel's TLS upper-layer protocol to a
    /// connected TCP socket, which `setTlsCryptoInfo` then keys. A kernel
    /// without the `tls` module, or a socket that cannot take it, fails with
    /// `error.OperationNotSupported`.
    pub fn attachTlsUlp(raw_fd: std.posix.fd_t) error{
        InvalidHandle,
        OperationNotSupported,
        InvalidProtocolOption,
        Unexpected,
    }!void {
        const value = "tls";
        while (true) {
            const rc = std.os.linux.setsockopt(
                raw_fd,
                std.posix.IPPROTO.TCP,
                std.os.linux.TCP.ULP,
                value.ptr,
                value.len,
            );
            switch (linux.syscallErrno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .BADF, .NOTSOCK => return error.InvalidHandle,
                .NOENT, .NOPROTOOPT, .NODEV, .OPNOTSUPP => return error.OperationNotSupported,
                .INVAL => return error.InvalidProtocolOption,
                else => |errno| return std.posix.unexpectedErrno(errno),
            }
        }
    }

    /// Whether a TCP socket already carries an upper-layer protocol
    /// (TCP_ULP). A socket whose option cannot be read answers false, and
    /// `attachTlsUlp` then reports what is wrong with it.
    pub fn tlsUlpAttached(raw_fd: std.posix.fd_t) bool {
        var name: [32]u8 = @splat(0);
        var name_len: std.os.linux.socklen_t = name.len;
        const rc = std.os.linux.getsockopt(
            raw_fd,
            std.posix.IPPROTO.TCP,
            std.os.linux.TCP.ULP,
            &name,
            &name_len,
        );
        return switch (linux.syscallErrno(rc)) {
            .SUCCESS => name_len != 0 and name[0] != 0,
            else => false,
        };
    }

    /// The direction a kTLS key serves: the kernel's TLS_TX and TLS_RX.
    pub const TlsDirection = enum(u32) {
        tx = 1,
        rx = 2,
    };

    /// SOL_TLS TLS_TX or TLS_RX: hands the kernel the key material of one
    /// direction. `crypto_info` is the kernel's `tls12_crypto_info_*` struct
    /// for the cipher, whose layout belongs to the caller. A cipher the
    /// kernel lacks fails with `error.OperationNotSupported`.
    pub fn setTlsCryptoInfo(raw_fd: std.posix.fd_t, direction: TlsDirection, crypto_info: []const u8) error{
        InvalidHandle,
        OperationNotSupported,
        InvalidKernelCryptoInfo,
        SystemResources,
        Unexpected,
    }!void {
        while (true) {
            const rc = std.os.linux.setsockopt(
                raw_fd,
                std.os.linux.SOL.TLS,
                @intFromEnum(direction),
                crypto_info.ptr,
                @intCast(crypto_info.len),
            );
            switch (linux.syscallErrno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .BADF, .NOTSOCK => return error.InvalidHandle,
                // Linux reports ENOENT when the requested cipher or its
                // provider is missing even though the TLS ULP itself exists.
                .NOENT, .NOPROTOOPT, .NODEV, .OPNOTSUPP => return error.OperationNotSupported,
                .INVAL => return error.InvalidKernelCryptoInfo,
                .NOMEM, .NOBUFS => return error.SystemResources,
                else => |errno| return std.posix.unexpectedErrno(errno),
            }
        }
    }

    /// SO_TYPE: the socket's type, such as `SOCK.SEQPACKET`.
    pub fn socketType(raw_fd: std.posix.fd_t) SocketIntError!u32 {
        return @bitCast(try readSocketInt(raw_fd, std.os.linux.SO.TYPE));
    }

    /// SO_DOMAIN: the socket's address family, such as `AF.UNIX`.
    pub fn socketDomain(raw_fd: std.posix.fd_t) SocketIntError!u32 {
        return @bitCast(try readSocketInt(raw_fd, std.os.linux.SO.DOMAIN));
    }

    /// SO_ERROR: the outcome of a nonblocking connect once the socket polls
    /// writable. Reading it clears it.
    pub fn connectResult(raw_fd: std.posix.fd_t) std.posix.ConnectError!void {
        return std.posix.getsockoptError(raw_fd);
    }

    pub const SocketIntError = error{ InvalidHandle, InvalidSocketOption, Unexpected };

    /// A socket-level option that holds a C `int`. Reads only, so it works in
    /// a worker after its filter, which admits getsockopt.
    fn readSocketInt(raw_fd: std.posix.fd_t, option: u32) SocketIntError!c_int {
        var value: c_int = 0;
        var value_len: std.os.linux.socklen_t = @sizeOf(c_int);
        const rc = std.os.linux.getsockopt(
            raw_fd,
            std.posix.SOL.SOCKET,
            option,
            std.mem.asBytes(&value).ptr,
            &value_len,
        );
        switch (linux.syscallErrno(rc)) {
            .SUCCESS => {},
            .BADF, .NOTSOCK => return error.InvalidHandle,
            .NOPROTOOPT, .INVAL => return error.InvalidSocketOption,
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
        if (value_len != @sizeOf(c_int))
            return error.InvalidSocketOption;
        return value;
    }

    fn enableSocketOption(raw_fd: std.posix.fd_t, option: u32) !void {
        const enabled: c_int = 1;
        try std.posix.setsockopt(raw_fd, std.posix.SOL.SOCKET, option, std.mem.asBytes(&enabled));
    }
};

/// Control-message layout for SCM_RIGHTS and kTLS record types: `len`,
/// `space` and `dataOffset` are CMSG_LEN, CMSG_SPACE and the offset of
/// CMSG_DATA.
pub const cmsg = struct {
    /// glibc's `struct cmsghdr`.
    pub const Cmsghdr = extern struct {
        len: usize,
        level: c_int,
        type: c_int,
    };

    pub const header_align = @alignOf(Cmsghdr);
    pub const scm_rights: c_int = 1;
    pub const scm_credentials: c_int = 2;

    pub fn alignLen(length: usize) usize {
        return std.mem.alignForward(usize, length, @alignOf(usize));
    }

    pub fn len(payload_len: usize) usize {
        return alignLen(@sizeOf(Cmsghdr)) + payload_len;
    }

    pub fn space(payload_len: usize) usize {
        return alignLen(@sizeOf(Cmsghdr)) + alignLen(payload_len);
    }

    pub fn dataOffset() usize {
        return alignLen(@sizeOf(Cmsghdr));
    }
};

pub const linux = struct {
    const linux_capability_version_3: u32 = 0x20080522;

    pub fn syscallErrno(rc: usize) std.posix.E {
        const signed: isize = @bitCast(rc);
        const code = if (signed > -4096 and signed < 0) -signed else 0;
        return @enumFromInt(code);
    }

    pub fn clearAmbientCapabilities() !void {
        const rc = std.os.linux.prctl(
            @intFromEnum(std.os.linux.PR.CAP_AMBIENT),
            std.os.linux.PR.CAP_AMBIENT_CLEAR_ALL,
            0,
            0,
            0,
        );
        return switch (syscallErrno(rc)) {
            .SUCCESS => {},
            .INVAL, .BADF => error.UnsupportedKernel,
            .PERM => error.PermissionDenied,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    pub fn clearCapabilitySets() !void {
        var header = std.os.linux.cap_user_header_t{
            .version = linux_capability_version_3,
            .pid = 0,
        };
        const empty = [_]std.os.linux.cap_user_data_t{
            .{ .effective = 0, .permitted = 0, .inheritable = 0 },
            .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        };
        const rc = std.os.linux.capset(&header, &empty[0]);
        return switch (syscallErrno(rc)) {
            .SUCCESS => {},
            .INVAL => error.UnsupportedKernel,
            .PERM => error.PermissionDenied,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    /// Clears the ambient, effective, permitted and inheritable sets; the
    /// bounding set is left alone. Capabilities belong to a thread, so call
    /// it before any other thread exists.
    pub fn dropAllCapabilities() !void {
        try clearAmbientCapabilities();
        try clearCapabilitySets();
    }
};

pub const memory = struct {
    pub const ReserveError = std.posix.MMapError || error{SystemResources};

    /// Reserves `byte_count` bytes of anonymous, private address space that
    /// costs memory a page at a time, on first touch, and writes none of it.
    /// The caller unmaps it with `std.posix.munmap`.
    ///
    /// The mapping is MAP_NORESERVE, so its size is not charged against
    /// overcommit, and refuses transparent huge pages: with THP `always`, the
    /// first touch inside a 2 MiB-aligned range could fault in the whole huge
    /// page, and khugepaged could later collapse a few touched pages into one,
    /// so a table would hold up to 2 MiB per entry it used. Adjacent mappings
    /// with the same flags merge, so even a mapping smaller than a huge page
    /// can end up inside one. A kernel without THP rejects the advice with
    /// EINVAL, and then has no huge page to refuse. Fails with the mapping's
    /// error, or with `error.SystemResources` when the kernel cannot record
    /// the advice.
    pub fn reserveFaultIn(byte_count: usize) ReserveError![]align(std.heap.page_size_min) u8 {
        const mapping = try std.posix.mmap(
            null,
            byte_count,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
            -1,
            0,
        );
        errdefer std.posix.munmap(mapping);
        const sys = std.os.linux;
        switch (sys.E.init(sys.madvise(mapping.ptr, mapping.len, sys.MADV.NOHUGEPAGE))) {
            .SUCCESS, .INVAL => return mapping,
            .AGAIN => return error.SystemResources,
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
    }
};
