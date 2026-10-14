//! The low-level helpers in `collo_os`, run against the live kernel: the
//! cmsghdr layout, fd ownership, the seal check of a file that cannot carry
//! seals, openat2 confined beneath a directory, close-on-exec socket pairs,
//! socket options, start ticks from `/proc/<pid>/stat`, spawning with mapped
//! fds into a new session with the child's pidfd, closing every fd outside an
//! allowlist, thread CPU clocks read from another thread, and the two fork
//! primitives the zygote depends on, `makeAddressSpaceForkInheritable` and
//! `cloneForkWithPidFd` with the thread identity it gives the child and the
//! errors a failed clone reports. The fork tests fork the test binary itself;
//! the zygote's own fork loop is covered by the `zygote-integration` lane.

const std = @import("std");
const os = @import("collo_os");

test "cmsghdr layout matches Linux ABI" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(os.cmsg.Cmsghdr));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(os.cmsg.Cmsghdr, "len"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(os.cmsg.Cmsghdr, "level"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(os.cmsg.Cmsghdr, "type"));
}

test "OwnedFd closes unless released" {
    const fds = try std.posix.pipe();
    var owned = os.fd.OwnedFd.fromRaw(fds[0]);
    const released = owned.release();
    defer std.posix.close(released);
    try std.testing.expect(!owned.isValid());
    std.posix.close(fds[1]);
}

test "FdRef borrows without taking ownership" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    const borrowed = os.fd.FdRef.fromRaw(fds[0]);
    try std.testing.expectEqual(fds[0], borrowed.fd());
}

test "a descriptor that cannot carry seals reads as missing them" {
    const fds = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    try std.testing.expectError(error.MissingFdSeals, os.fd.requireSeals(fds[0], os.fd.memfd_size_seals));
}

test "openat2 beneath a directory opens what lies inside and refuses a path or a link that leaves it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("inner");
    try tmp.dir.writeFile(.{ .sub_path = "inner/file", .data = "inside" });
    try tmp.dir.writeFile(.{ .sub_path = "outside", .data = "outside" });
    try tmp.dir.symLink("file", "inner/near", .{});
    try tmp.dir.symLink("../outside", "inner/far", .{});
    var inner = try tmp.dir.openDir("inner", .{});
    defer inner.close();
    const flags: std.posix.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };

    var file = try os.fd.openat2(inner.fd, "file", flags, os.fd.resolve_beneath);
    file.deinit();
    var near = try os.fd.openat2(inner.fd, "near", flags, os.fd.resolve_beneath);
    near.deinit();
    try std.testing.expectError(error.PathEscapesDirectory, os.fd.openat2(inner.fd, "../outside", flags, os.fd.resolve_beneath));
    try std.testing.expectError(error.PathEscapesDirectory, os.fd.openat2(inner.fd, "far", flags, os.fd.resolve_beneath));
    try std.testing.expectError(
        error.SymLinkLoop,
        os.fd.openat2(inner.fd, "near", flags, os.fd.resolve_beneath | os.fd.resolve_no_symlinks),
    );
    try std.testing.expectError(error.FileNotFound, os.fd.openat2(inner.fd, "missing", flags, os.fd.resolve_beneath));
}

test "fork inherits a MADV_DONTFORK mapping once the address space is made inheritable" {
    const page = try std.posix.mmap(
        null,
        std.heap.page_size_min,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(page);
    page[0] = fork_probe_value;
    try std.posix.madvise(page.ptr, page.len, std.os.linux.MADV.DONTFORK);

    // Until `makeAddressSpaceForkInheritable` runs, the child is born without
    // the page, so its read faults.
    try expectForkChildReadsProbe(page, .killed_by_segv);
    _ = try os.process.makeAddressSpaceForkInheritable();
    try expectForkChildReadsProbe(page, .exits_zero);
}

const fork_probe_value: u8 = 0x5a;

fn expectForkChildReadsProbe(
    page: []align(std.heap.page_size_min) u8,
    expected: enum { exits_zero, killed_by_segv },
) !void {
    const pid = try std.posix.fork();
    if (pid == 0) {
        // Restore the default SIGSEGV disposition: the test binary's handler
        // prints a stack trace and aborts, so an unreadable page would report
        // SIGABRT instead of SIGSEGV. The child leaves through exit_group,
        // never libc exit, because it inherits the parent's atexit handlers
        // and must not run them.
        std.posix.sigaction(std.posix.SIG.SEGV, &.{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        const value = @as(*volatile u8, &page[0]).*;
        std.os.linux.exit_group(if (value == fork_probe_value) 0 else 1);
    }
    const result = std.posix.waitpid(pid, 0);
    switch (expected) {
        .exits_zero => {
            try std.testing.expect(std.os.linux.W.IFEXITED(result.status));
            try std.testing.expectEqual(@as(u32, 0), std.os.linux.W.EXITSTATUS(result.status));
        },
        .killed_by_segv => {
            try std.testing.expect(std.os.linux.W.IFSIGNALED(result.status));
            try std.testing.expectEqual(std.posix.SIG.SEGV, std.os.linux.W.TERMSIG(result.status));
        },
    }
}

test "socketPairType creates a cloexec unix socket pair" {
    const fds = try os.fd.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    try os.fd.writeAllRaw(fds[0], "ok");
    var buffer: [2]u8 = undefined;
    const read_len = try std.posix.read(fds[1], &buffer);
    try std.testing.expectEqualStrings("ok", buffer[0..read_len]);
}

test "socket helper sets receive and send timeouts" {
    const pair = try os.fd.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    try os.socket.setReadWriteTimeouts(pair[0], 1234);
}

test "socket helper disables Nagle on TCP sockets" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    var client = try std.net.tcpConnectToAddress(server.listen_address);
    defer client.close();

    var accepted = try server.accept();
    defer accepted.stream.close();

    try os.socket.setTcpNoDelay(client.handle);
    try os.socket.setTcpNoDelay(accepted.stream.handle);

    try std.testing.expect(try tcpNoDelayEnabled(client.handle));
    try std.testing.expect(try tcpNoDelayEnabled(accepted.stream.handle));
}

test "socket helper sets TCP not-sent low watermark on TCP sockets" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    var client = try std.net.tcpConnectToAddress(server.listen_address);
    defer client.close();

    var accepted = try server.accept();
    defer accepted.stream.close();

    const byte_count: u32 = 64 * 1024;
    os.socket.setTcpNotSentLowAt(accepted.stream.handle, byte_count) catch |err| switch (err) {
        error.InvalidProtocolOption,
        error.OperationNotSupported,
        => return,
        else => |unexpected| return unexpected,
    };
    try std.testing.expectEqual(byte_count, try tcpNotSentLowAtBytes(accepted.stream.handle));
}

test "socket helpers set address reuse, port reuse and the incoming CPU on a listener socket" {
    const fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        std.posix.IPPROTO.TCP,
    );
    defer std.posix.close(fd);

    try os.socket.setReuseAddress(fd);
    try os.socket.setReusePort(fd);
    try os.socket.setIncomingCpu(fd, 0);
    try std.testing.expectEqual(@as(c_int, 1), try socketOptionValue(fd, std.posix.SO.REUSEADDR));
    try std.testing.expectEqual(@as(c_int, 1), try socketOptionValue(fd, std.posix.SO.REUSEPORT));
    try std.testing.expectEqual(@as(c_int, 0), try socketOptionValue(fd, std.posix.SO.INCOMING_CPU));

    // The option holds a C `int`, so a larger CPU id is refused before the kernel sees it.
    const unrepresentable_cpu_id = @as(usize, std.math.maxInt(c_int)) + 1;
    try std.testing.expectError(error.CpuIdOutOfRange, os.socket.setIncomingCpu(fd, unrepresentable_cpu_id));
}

test "common process helpers expose monotonic time and task count" {
    const before = try os.process.monotonicNowNs();
    const after = try os.process.monotonicNowNs();
    try std.testing.expect(after >= before);
    try std.testing.expect(try os.process.countSelfTasks() >= 1);
}

test "process start ticks come from field 22 of /proc/<pid>/stat" {
    // The synthetic comm holds the two characters that break naive
    // splitting, a space and a closing parenthesis. Fields 3 to 21 are the
    // nineteen tokens after comm, and field 22 is the start time.
    const synthetic =
        "4242 (my (odd) name) S 1 4242 4242 0 -1 4194560 100 0 0 0 " ++
        "7 3 0 0 20 0 1 0 987654321 12345 678 18446744073709551615";
    try std.testing.expectEqual(
        @as(u64, 987654321),
        try os.process.parseProcStatStartTicks(synthetic),
    );
    try std.testing.expectError(
        error.InvalidProcStat,
        os.process.parseProcStatStartTicks("4242 (short) S 1"),
    );
    try std.testing.expectError(
        error.InvalidProcStat,
        os.process.parseProcStatStartTicks("no comm here"),
    );

    // The live reads, by self and by pid, agree with the field parsed from
    // the raw file.
    var file = try std.fs.openFileAbsolute("/proc/self/stat", .{});
    defer file.close();
    var buffer: [1024]u8 = undefined;
    const stat_len = try file.readAll(&buffer);
    const expected = try os.process.parseProcStatStartTicks(buffer[0..stat_len]);
    try std.testing.expect(expected != 0);
    try std.testing.expectEqual(expected, try os.process.selfStartTicks());
    const self_pid: u32 = @intCast(std.os.linux.getpid());
    try std.testing.expectEqual(expected, try os.process.processStartTicks(self_pid));

    // The kernel caps pid_max at PID_MAX_LIMIT, 2^22 on 64-bit systems, so
    // no process has this pid.
    try std.testing.expectError(
        error.ProcessNotFound,
        os.process.processStartTicks(std.math.maxInt(u32)),
    );
}

test "internal spawn maps explicit fd and closes the source side on exec" {
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    var read_fd = os.fd.OwnedFd.fromRaw(pipe_pair[0]);
    defer read_fd.deinit();
    var write_fd = os.fd.OwnedFd.fromRaw(pipe_pair[1]);
    defer write_fd.deinit();

    const exe_path_z: [*:0]const u8 = "/bin/sh";
    const arg0: [*:0]const u8 = "sh";
    const arg1: [*:0]const u8 = "-c";
    const arg2: [*:0]const u8 = "printf ok >&3";
    const argv = [_:null]?[*:0]const u8{ arg0, arg1, arg2 };
    const envp = [_:null]?[*:0]const u8{};
    const fd_map = [_]os.process.SpawnFdMap{.{
        .source_fd = write_fd.fd(),
        .target_fd = 3,
    }};

    var spawned = try os.process.spawnInternal(.{
        .exe_path_z = exe_path_z,
        .argv = &argv,
        .envp = &envp,
        .fd_map = &fd_map,
    });
    defer spawned.pidfd.deinit();
    write_fd.deinit();

    var buffer: [2]u8 = undefined;
    const read_len = try std.posix.read(read_fd.fd(), &buffer);
    try std.testing.expectEqualStrings("ok", buffer[0..read_len]);

    const wait = std.posix.waitpid(@intCast(spawned.pid), 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
}

test "a spawned process comes with a pidfd that reports its exit" {
    const exe_path_z: [*:0]const u8 = "/bin/sh";
    const arg0: [*:0]const u8 = "sh";
    const arg1: [*:0]const u8 = "-c";
    const arg2: [*:0]const u8 = "exit 7";
    const argv = [_:null]?[*:0]const u8{ arg0, arg1, arg2 };
    const envp = [_:null]?[*:0]const u8{};
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);
    defer std.posix.close(pipe_pair[1]);
    const fd_map = [_]os.process.SpawnFdMap{.{ .source_fd = pipe_pair[1], .target_fd = pipe_pair[1] + 64 }};

    var spawned = try os.process.spawnInternal(.{
        .exe_path_z = exe_path_z,
        .argv = &argv,
        .envp = &envp,
        .fd_map = &fd_map,
    });
    defer spawned.pidfd.deinit();

    // The pidfd names the child the spawn created, with no window in which
    // the child existed without it.
    try std.testing.expect(try os.process.waitForPidFdExit(spawned.pidfd.fd(), 5_000));
    const wait = std.posix.waitpid(@intCast(spawned.pid), 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 7), std.c.W.EXITSTATUS(wait.status));
}

test "a spawn whose exec fails reports the exec's error" {
    const exe_path_z: [*:0]const u8 = "/nonexistent/collo-spawn-probe";
    const arg0: [*:0]const u8 = "collo-spawn-probe";
    const argv = [_:null]?[*:0]const u8{arg0};
    const envp = [_:null]?[*:0]const u8{};
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);
    defer std.posix.close(pipe_pair[1]);
    const fd_map = [_]os.process.SpawnFdMap{.{ .source_fd = pipe_pair[1], .target_fd = pipe_pair[1] + 64 }};

    try std.testing.expectError(error.FileNotFound, os.process.spawnInternal(.{
        .exe_path_z = exe_path_z,
        .argv = &argv,
        .envp = &envp,
        .fd_map = &fd_map,
    }));
}

test "a spawned child gets no descriptor below its highest target but its targets, close-on-exec or not" {
    // Sources sit above both targets, which `spawnInternal` requires, and the
    // leak candidate sits between the two targets without close-on-exec.
    const source_fd_min: std.posix.fd_t = 96;
    const ready_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    var ready_read = os.fd.OwnedFd.fromRaw(ready_pair[0]);
    defer ready_read.deinit();
    var ready_write = try os.fd.OwnedFd.dupCloexecAtLeast(ready_pair[1], source_fd_min);
    defer ready_write.deinit();
    std.posix.close(ready_pair[1]);
    const leak_min: std.posix.fd_t = 48;
    const leak_fd: std.posix.fd_t = @intCast(try std.posix.fcntl(ready_read.fd(), std.posix.F.DUPFD, @intCast(leak_min)));
    defer std.posix.close(leak_fd);
    try std.testing.expect(leak_fd < source_fd_min - 1);
    var far_source = try os.fd.OwnedFd.dupCloexecAtLeast(ready_read.fd(), source_fd_min);
    defer far_source.deinit();
    const far_target: std.posix.fd_t = leak_fd + 1;

    var script_buffer: [128]u8 = undefined;
    const script = try std.fmt.bufPrintZ(
        &script_buffer,
        "if [ -e /proc/self/fd/{d} ]; then printf leak >&3; else printf ok >&3; fi",
        .{leak_fd},
    );
    const exe_path_z: [*:0]const u8 = "/bin/sh";
    const arg0: [*:0]const u8 = "sh";
    const arg1: [*:0]const u8 = "-c";
    const argv = [_:null]?[*:0]const u8{ arg0, arg1, script.ptr };
    const envp = [_:null]?[*:0]const u8{};
    const fd_map = [_]os.process.SpawnFdMap{
        .{ .source_fd = ready_write.fd(), .target_fd = 3 },
        .{ .source_fd = far_source.fd(), .target_fd = far_target },
    };
    var spawned = try os.process.spawnInternal(.{
        .exe_path_z = exe_path_z,
        .argv = &argv,
        .envp = &envp,
        .fd_map = &fd_map,
    });
    defer spawned.pidfd.deinit();
    ready_write.deinit();

    var buffer: [4]u8 = undefined;
    const read_len = try std.posix.read(ready_read.fd(), &buffer);
    const wait = std.posix.waitpid(@intCast(spawned.pid), 0);
    try std.testing.expectEqualStrings("ok", buffer[0..read_len]);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
}

test "internal spawn starts the child as the leader of a new session and process group" {
    // Sources sit above both targets, which `spawnInternal` requires.
    const source_fd_min: std.posix.fd_t = 16;
    const ready_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    var ready_read = os.fd.OwnedFd.fromRaw(ready_pair[0]);
    defer ready_read.deinit();
    var ready_write = try os.fd.OwnedFd.dupCloexecAtLeast(ready_pair[1], source_fd_min);
    defer ready_write.deinit();
    std.posix.close(ready_pair[1]);
    const release_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    var release_write = os.fd.OwnedFd.fromRaw(release_pair[1]);
    defer release_write.deinit();
    var release_read = try os.fd.OwnedFd.dupCloexecAtLeast(release_pair[0], source_fd_min);
    defer release_read.deinit();
    std.posix.close(release_pair[0]);

    // The child says it runs, then stays alive until fd 4 reaches EOF, so
    // its session and group can be read while it exists.
    const exe_path_z: [*:0]const u8 = "/bin/sh";
    const arg0: [*:0]const u8 = "sh";
    const arg1: [*:0]const u8 = "-c";
    const arg2: [*:0]const u8 = "printf ok >&3; exec 3>&-; read line <&4; exit 0";
    const argv = [_:null]?[*:0]const u8{ arg0, arg1, arg2 };
    const envp = [_:null]?[*:0]const u8{};
    const fd_map = [_]os.process.SpawnFdMap{
        .{ .source_fd = ready_write.fd(), .target_fd = 3 },
        .{ .source_fd = release_read.fd(), .target_fd = 4 },
    };
    var spawned = try os.process.spawnInternal(.{
        .exe_path_z = exe_path_z,
        .argv = &argv,
        .envp = &envp,
        .fd_map = &fd_map,
    });
    defer spawned.pidfd.deinit();
    const pid = spawned.pid;
    ready_write.deinit();
    release_read.deinit();

    var buffer: [2]u8 = undefined;
    const read_len = try std.posix.read(ready_read.fd(), &buffer);
    const session = std.os.linux.syscall1(.getsid, pid);
    const group = std.os.linux.syscall1(.getpgid, pid);
    release_write.deinit();
    const wait = std.posix.waitpid(@intCast(pid), 0);

    try std.testing.expectEqualStrings("ok", buffer[0..read_len]);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.E.init(session));
    try std.testing.expectEqual(@as(usize, pid), session);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.E.init(group));
    try std.testing.expectEqual(@as(usize, pid), group);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
}

test "close all except leaves no descriptor outside allowlist" {
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);

    const pid = try std.posix.fork();
    if (pid == 0) {
        const allowed_pipe = pipe_pair[1];
        std.posix.close(pipe_pair[0]);

        const keep_pair = std.posix.pipe2(.{ .CLOEXEC = true }) catch childExit(111);
        const drop_pair = std.posix.pipe2(.{ .CLOEXEC = true }) catch childExit(112);
        const extra = std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK) catch childExit(113);
        var allow = [_]std.posix.fd_t{
            allowed_pipe,
            keep_pair[0],
            keep_pair[1],
        };
        os.fd.closeAllExceptFrom(3, &allow) catch childExit(114);

        const unexpected = countUnexpectedOpenFds(3, &allow) catch childExit(115);
        const drop_closed =
            fdIsClosed(drop_pair[0]) and
            fdIsClosed(drop_pair[1]) and
            fdIsClosed(extra);
        const ok = unexpected == 0 and drop_closed;
        const byte: [1]u8 = .{if (ok) 1 else 0};
        os.fd.writeAllRaw(allowed_pipe, &byte) catch childExit(116);
        childExit(if (ok) 0 else 117);
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

test "cloneForkWithPidFd returns an owned pidfd that observes child exit" {
    var pidfd: std.posix.fd_t = -1;
    const pid = try os.process.cloneForkWithPidFd(try cloneOptions(null), &pidfd);
    if (pid == 0)
        childExit(7);
    defer std.posix.close(pidfd);

    try std.testing.expect(pid > 0);
    try std.testing.expect(pidfd >= 0);
    try std.testing.expect(try os.process.waitForPidFdExit(pidfd, 5_000));

    const wait = std.posix.waitpid(@intCast(pid), 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 7), std.c.W.EXITSTATUS(wait.status));
}

test "cloneForkWithPidFd rejects a non-cgroup target fd" {
    const not_a_cgroup_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(not_a_cgroup_fd);

    var pidfd: std.posix.fd_t = -1;
    // CLONE_INTO_CGROUP with a descriptor that is not a cgroup directory
    // fails with EBADF.
    try std.testing.expectError(
        error.InvalidHandle,
        os.process.cloneForkWithPidFd(try cloneOptions(not_a_cgroup_fd), &pidfd),
    );
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), pidfd);
}

test "a cloned child's glibc names its own thread, so its thread CPU clock reads" {
    // glibc computes the clock id from the thread id it caches in the thread's
    // descriptor. A clone that left the caller's id there would name a thread
    // of another process, which the kernel refuses with EINVAL.
    var pidfd: std.posix.fd_t = -1;
    const pid = try os.process.cloneForkWithPidFd(try cloneOptions(null), &pidfd);
    if (pid == 0)
        childExit(childReadsOwnThreadClock());
    defer std.posix.close(pidfd);

    try std.testing.expect(try os.process.waitForPidFdExit(pidfd, 5_000));
    const wait = std.posix.waitpid(@intCast(pid), 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, own_thread_clock_read), std.c.W.EXITSTATUS(wait.status));
}

/// The exit statuses of `childReadsOwnThreadClock`.
const own_thread_clock_read: u8 = 0;
const own_thread_clock_libc_failed: u8 = 1;
const own_thread_clock_mismatch: u8 = 2;
const own_thread_clock_refused: u8 = 3;

/// Runs in a cloned child: glibc's clock id for the calling thread must be
/// the one built from the kernel's thread id, and the kernel must read it.
fn childReadsOwnThreadClock() u8 {
    const libc_clock = os.process.libcThreadCpuClockId() catch return own_thread_clock_libc_failed;
    if (libc_clock != os.process.threadCpuClockId(std.os.linux.gettid()))
        return own_thread_clock_mismatch;
    _ = os.process.threadCpuNs(libc_clock) catch return own_thread_clock_refused;
    return own_thread_clock_read;
}

fn cloneOptions(cgroup_dir_fd: ?std.posix.fd_t) !os.process.CloneForkOptions {
    return .{
        .cgroup_dir_fd = cgroup_dir_fd,
        .thread_id_word = try os.process.callingThreadIdWord(),
    };
}

test "the calling thread's thread-id word holds its own thread id" {
    const word = try os.process.callingThreadIdWord();
    try std.testing.expectEqual(std.os.linux.gettid(), word.*);
}

test "another thread's CPU clock advances while it spins and stays still while it sleeps" {
    var probe: SpinningThread = .{};
    const thread = try std.Thread.spawn(.{}, SpinningThread.run, .{&probe});
    defer thread.join();
    defer probe.release.set();
    probe.spun.wait();

    const clock = os.process.threadCpuClockId(probe.tid.load(.acquire));
    // The thread measured its own spin on its own clock before it parked, so
    // the read from this thread sees at least that much.
    const parked_ns = try os.process.threadCpuNs(clock);
    try std.testing.expect(parked_ns >= spin_cpu_ns);
    std.Thread.sleep(parked_wall_ns);
    const later_ns = try os.process.threadCpuNs(clock);
    try std.testing.expect(later_ns - parked_ns < parked_cpu_ns_max);
}

test "a CPU clock of a thread in another process is refused" {
    // A forked child parks on a pipe read until the test closes the write
    // end, so its thread exists while the clock is read.
    const pipe_pair = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe_pair[0]);
    var release_write = os.fd.OwnedFd.fromRaw(pipe_pair[1]);
    defer release_write.deinit();
    const pid = try std.posix.fork();
    if (pid == 0) {
        // Only raw system calls: fork cloned only the calling thread. The
        // child drops its copy of the write end, so the read ends once the
        // test closes its own.
        if (os.linux.syscallErrno(std.os.linux.close(pipe_pair[1])) != .SUCCESS)
            childExit(1);
        var byte: [1]u8 = undefined;
        switch (os.linux.syscallErrno(std.os.linux.read(pipe_pair[0], &byte, byte.len))) {
            .SUCCESS => childExit(0),
            else => childExit(1),
        }
    }
    const refused = os.process.threadCpuNs(os.process.threadCpuClockId(pid));
    release_write.deinit();
    _ = std.posix.waitpid(pid, 0);
    try std.testing.expectError(error.InvalidClock, refused);
}

/// The CPU the probe thread spends before it parks, the wall time the test
/// lets it sleep, and the CPU it may show over that sleep: waking and
/// parking on a futex costs microseconds.
const spin_cpu_ns: u64 = 20 * std.time.ns_per_ms;
const parked_wall_ns: u64 = 20 * std.time.ns_per_ms;
const parked_cpu_ns_max: u64 = 1 * std.time.ns_per_ms;

const SpinningThread = struct {
    tid: std.atomic.Value(std.os.linux.pid_t) = .init(0),
    spun: std.Thread.ResetEvent = .{},
    release: std.Thread.ResetEvent = .{},

    fn run(self: *SpinningThread) void {
        self.tid.store(std.os.linux.gettid(), .release);
        const own_clock = os.process.threadCpuClockId(std.os.linux.gettid());
        while ((os.process.threadCpuNs(own_clock) catch spin_cpu_ns) < spin_cpu_ns)
            std.atomic.spinLoopHint();
        self.spun.set();
        self.release.wait();
    }
};

test "socket helpers read a socket's type and domain and refuse a descriptor that is not a socket" {
    const pair = try os.fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    try std.testing.expectEqual(@as(u32, std.posix.SOCK.SEQPACKET), try os.socket.socketType(pair[0]));
    try std.testing.expectEqual(@as(u32, std.posix.AF.UNIX), try os.socket.socketDomain(pair[0]));

    const not_a_socket = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(not_a_socket);
    try std.testing.expectError(error.InvalidHandle, os.socket.socketType(not_a_socket));
    try std.testing.expectError(error.InvalidHandle, os.socket.socketDomain(not_a_socket));
}

test "socket helpers find no upper-layer protocol on a fresh TCP socket and refuse TLS on a unix socket" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    var client = try std.net.tcpConnectToAddress(server.listen_address);
    defer client.close();
    try os.socket.connectResult(client.handle);
    try std.testing.expect(!os.socket.tlsUlpAttached(client.handle));
    // A kernel without the `tls` module refuses the attach; one with it
    // reports the protocol attached afterwards.
    if (os.socket.attachTlsUlp(client.handle)) {
        try std.testing.expect(os.socket.tlsUlpAttached(client.handle));
    } else |err| switch (err) {
        error.OperationNotSupported => try std.testing.expect(!os.socket.tlsUlpAttached(client.handle)),
        else => return err,
    }

    const pair = try os.fd.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    try std.testing.expectError(error.OperationNotSupported, os.socket.attachTlsUlp(pair[0]));
}

test "a failed clone3 reports descriptor pressure as the descriptor quotas, and each cgroup refusal by its cause" {
    // The zygote refuses one fork and keeps serving on exactly these errors
    // (`isTransientForkError` in `zygote/fork_loop.zig`), so the pidfd's descriptor slot must
    // come back as the quota errors the init socket pair also reports.
    const cases = [_]struct { errno: std.posix.E, err: os.process.CloneForkError }{
        .{ .errno = .MFILE, .err = error.ProcessFdQuotaExceeded },
        .{ .errno = .NFILE, .err = error.SystemFdQuotaExceeded },
        .{ .errno = .AGAIN, .err = error.SystemResources },
        .{ .errno = .NOMEM, .err = error.SystemResources },
        .{ .errno = .ACCES, .err = error.PermissionDenied },
        .{ .errno = .PERM, .err = error.PermissionDenied },
        .{ .errno = .BUSY, .err = error.CgroupBusy },
        .{ .errno = .NOSPC, .err = error.CgroupLimitReached },
        .{ .errno = .OPNOTSUPP, .err = error.CgroupThreaded },
        .{ .errno = .BADF, .err = error.InvalidHandle },
    };
    for (cases) |case|
        try std.testing.expectEqual(case.err, os.process.cloneForkError(case.errno));
}

test "cloneForkWithPidFd reports a descriptor table with no room for the pidfd as the per-process quota" {
    // The table is filled in a forked child, whose descriptors and limit the test may spend, and
    // the child's exit status carries the outcome.
    const pid = try std.posix.fork();
    if (pid == 0)
        childExit(cloneIntoFullDescriptorTable());

    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, full_table_quota_reported), std.c.W.EXITSTATUS(wait.status));
}

/// The exit statuses of `cloneIntoFullDescriptorTable`.
const full_table_quota_reported: u8 = 0;
const full_table_other_error: u8 = 1;
const full_table_clone_succeeded: u8 = 2;
const full_table_setup_failed: u8 = 3;
/// The descriptor limit the child lowers itself to before it fills its table.
const full_table_descriptors_max: u64 = 64;

/// Runs in a forked child: lowers the descriptor limit, takes every free slot below it, and
/// clones with `CLONE_PIDFD`, which needs one more slot for the pidfd.
fn cloneIntoFullDescriptorTable() u8 {
    const pipe_pair = std.posix.pipe() catch return full_table_setup_failed;
    const limits = std.posix.getrlimit(.NOFILE) catch return full_table_setup_failed;
    std.posix.setrlimit(.NOFILE, .{
        .cur = @min(limits.cur, full_table_descriptors_max),
        .max = limits.max,
    }) catch return full_table_setup_failed;
    // Each dup takes the lowest free slot below the limit, so the loop ends within that many.
    for (0..full_table_descriptors_max + 1) |_| {
        _ = std.posix.dup(pipe_pair[0]) catch |err| switch (err) {
            error.ProcessFdQuotaExceeded => break,
            else => return full_table_setup_failed,
        };
    } else return full_table_setup_failed;

    var pidfd: std.posix.fd_t = -1;
    const options = cloneOptions(null) catch return full_table_setup_failed;
    const child_pid = os.process.cloneForkWithPidFd(options, &pidfd) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded => return full_table_quota_reported,
        else => return full_table_other_error,
    };
    if (child_pid == 0)
        childExit(0);
    return full_table_clone_succeeded;
}

fn childExit(status: u8) noreturn {
    std.c._exit(status);
}

fn fdIsClosed(fd: std.posix.fd_t) bool {
    const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    return switch (std.os.linux.E.init(rc)) {
        .SUCCESS => false,
        .BADF => true,
        else => true,
    };
}

fn countUnexpectedOpenFds(min_fd: std.posix.fd_t, allow: []const std.posix.fd_t) !usize {
    var dir = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer dir.close();

    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const fd = std.fmt.parseInt(std.posix.fd_t, entry.name, 10) catch continue;
        if (fd < min_fd)
            continue;
        if (fd == dir.fd)
            continue;
        if (fdAllowed(fd, allow))
            continue;
        count += 1;
    }
    return count;
}

fn fdAllowed(fd: std.posix.fd_t, allow: []const std.posix.fd_t) bool {
    for (allow) |allowed|
        if (allowed == fd)
            return true;
    return false;
}

fn tcpNoDelayEnabled(raw_fd: std.posix.fd_t) !bool {
    var enabled: c_int = 0;
    try std.posix.getsockopt(
        raw_fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&enabled),
    );
    return enabled != 0;
}

fn socketOptionValue(raw_fd: std.posix.fd_t, option: u32) !c_int {
    var value: c_int = -1;
    try std.posix.getsockopt(raw_fd, std.posix.SOL.SOCKET, option, std.mem.asBytes(&value));
    return value;
}

fn tcpNotSentLowAtBytes(raw_fd: std.posix.fd_t) !u32 {
    var byte_count: c_int = 0;
    try std.posix.getsockopt(
        raw_fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NOTSENT_LOWAT,
        std.mem.asBytes(&byte_count),
    );
    if (byte_count < 0)
        return error.InvalidSocketOptionValue;
    return @intCast(byte_count);
}
