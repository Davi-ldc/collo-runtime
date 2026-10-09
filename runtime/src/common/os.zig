//! Linux descriptor and process primitives shared by every process of the
//! runtime, grouped as `fd`, `process`, `socket`, `cmsg` and `linux`. Nothing
//! here keeps state. The calls the zygote's fork loop makes
//! (`cloneForkWithPidFd`, `writeOomScoreAdj`, `assertSingleThreadedSelf`)
//! do not allocate.

const std = @import("std");
const c = @cImport({
    // `posix_spawn_file_actions_addclosefrom_np` (and the rest of the _np
    // surface) sits behind `__USE_MISC` in glibc's spawn.h, which only turns
    // on with _GNU_SOURCE/_DEFAULT_SOURCE. Without this the @hasDecl below
    // silently answers false and every spawn fails with
    // SpawnCloseFromUnavailable when the toolchain does not define it.
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("spawn.h");
    @cInclude("sys/types.h");
});

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

    /// posix_spawn of a runtime binary. Each `fd_map` source is dup2'd onto
    /// its target, every fd above the highest target is closed, and the child
    /// starts with an empty signal mask in a session of its own. Targets must
    /// be 3 or above, and no source may equal any mapping's target.
    pub fn spawnInternal(options: SpawnInternalOptions) !u32 {
        std.debug.assert(options.fd_map.len != 0);
        for (options.fd_map) |mapping| {
            for (options.fd_map) |reserved| {
                std.debug.assert(mapping.source_fd != reserved.target_fd);
            }
        }

        var actions: c.posix_spawn_file_actions_t = undefined;
        try posixSpawnCheck(c.posix_spawn_file_actions_init(&actions));
        defer {
            const rc = c.posix_spawn_file_actions_destroy(&actions);
            std.debug.assert(rc == 0);
        }

        var close_from: std.posix.fd_t = 3;
        for (options.fd_map) |mapping| {
            std.debug.assert(mapping.source_fd >= 0);
            std.debug.assert(mapping.target_fd >= 3);
            try posixSpawnCheck(c.posix_spawn_file_actions_adddup2(
                &actions,
                mapping.source_fd,
                mapping.target_fd,
            ));
            if (mapping.source_fd != mapping.target_fd) {
                try posixSpawnCheck(c.posix_spawn_file_actions_addclose(
                    &actions,
                    mapping.source_fd,
                ));
            }
            close_from = @max(close_from, mapping.target_fd + 1);
        }

        if (@hasDecl(c, "posix_spawn_file_actions_addclosefrom_np")) {
            try posixSpawnCheck(c.posix_spawn_file_actions_addclosefrom_np(
                &actions,
                close_from,
            ));
        } else {
            return error.SpawnCloseFromUnavailable;
        }

        // A blocked signal mask survives exec, so a child spawned by a thread
        // that blocks SIGINT or SIGTERM, as a thread reading them from a
        // signalfd does, would ignore direct termination signals. The child
        // therefore starts with an empty mask whatever the caller's is.
        //
        // The child also leads a new session with no controlling terminal. A
        // terminal sends Ctrl-C, Ctrl-Z and hangup to its whole foreground
        // process group, and a child left in the caller's group would die
        // alongside the caller instead of being stopped by it once the
        // requests in flight drain. Outside the terminal's session, the child
        // and everything it forks cannot be stopped by job control either, nor
        // push input into the terminal with TIOCSTI, which requires the
        // terminal to be the caller's controlling one.
        var attributes: c.posix_spawnattr_t = undefined;
        try posixSpawnCheck(c.posix_spawnattr_init(&attributes));
        defer {
            const rc = c.posix_spawnattr_destroy(&attributes);
            std.debug.assert(rc == 0);
        }
        var empty_signal_set: c.sigset_t = undefined;
        if (c.sigemptyset(&empty_signal_set) != 0)
            return error.SpawnSignalMaskUnavailable;
        try posixSpawnCheck(c.posix_spawnattr_setsigmask(&attributes, &empty_signal_set));
        try posixSpawnCheck(c.posix_spawnattr_setflags(
            &attributes,
            c.POSIX_SPAWN_SETSIGMASK | c.POSIX_SPAWN_SETSID,
        ));

        var pid: c.pid_t = 0;
        try posixSpawnCheck(c.posix_spawn(
            &pid,
            options.exe_path_z,
            &actions,
            &attributes,
            @ptrCast(@constCast(options.argv)),
            @ptrCast(@constCast(options.envp)),
        ));
        return @intCast(pid);
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

    /// fork()-like clone3: returns 0 in the child and the child pid in the
    /// parent. The parent also receives an owned pidfd through `pidfd_out`
    /// (CLONE_PIDFD), so no racy post-fork pidfd_open is needed; in the child
    /// `pidfd_out` is left untouched and no pidfd exists in its fd table.
    /// When `cgroup_dir_fd` is non-null the child is born inside that cgroup
    /// v2 directory (CLONE_INTO_CGROUP). Fails as `cloneForkError` says.
    ///
    /// Unlike libc fork(), raw clone3 runs no pthread_atfork handlers. That
    /// is safe only because the caller, the zygote's fork loop, checks that
    /// it is single-threaded and leaves the allocator and the VM untouched
    /// before forking.
    pub fn cloneForkWithPidFd(
        cgroup_dir_fd: ?std.posix.fd_t,
        pidfd_out: *std.posix.fd_t,
    ) CloneForkError!std.posix.pid_t {
        var pidfd_result: std.posix.fd_t = -1;
        var args = CloneArgs{
            .flags = std.os.linux.CLONE.PIDFD,
            .pidfd = @intFromPtr(&pidfd_result),
            .exit_signal = std.posix.SIG.CHLD,
        };
        if (cgroup_dir_fd) |dir_fd| {
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

    fn posixSpawnCheck(code: c_int) !void {
        if (code == 0)
            return;
        const err: std.posix.E = @enumFromInt(@as(u16, @intCast(code)));
        return switch (err) {
            .SUCCESS => {},
            .PERM => error.PermissionDenied,
            .NOENT => error.FileNotFound,
            .ACCES => error.PermissionDenied,
            .@"2BIG" => error.SystemResources,
            .NOMEM => error.SystemResources,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .BADF => error.InvalidHandle,
            .INVAL => error.InvalidArgument,
            else => std.posix.unexpectedErrno(err),
        };
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
