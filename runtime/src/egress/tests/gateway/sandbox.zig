//! Tests of the gateway's sandbox (`egress/gateway/sandbox.zig`): the Landlock write mask
//! for each kernel version, the private root a forked child builds and enters, the syscall
//! filter's refusal of Unix sockets, and, in a real gateway spawned from the installed binary,
//! the decoder libraries its boot loads before that root hides every library. The children apply
//! the real sandbox. A host that lacks a CA bundle or zlib, or on which a separate probe child
//! cannot enter unprivileged user and mount namespaces or install a seccomp filter, skips them,
//! saying which; once the probe passes, any error the sandbox returns fails the test with its
//! name. The whole boot of a sandboxed gateway behind the server is covered by local-e2e. Lane:
//! egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const server_gateway = @import("collo_server_gateway");
const decompress = @import("collo_egress_client").decompress;
const process_options = @import("collo_process_options");
const sandbox = gateway.sandbox;
const linux = std.os.linux;

/// What a probe child exits with when the host capability it checks is there.
const probe_ok: u8 = 0;
const probe_missing: u8 = 1;

/// Bound on a `/proc/<pid>/maps` read; a gateway's maps are a few hundred lines.
const maps_bytes_max: usize = 4 * 1024 * 1024;

test "egress gateway Landlock mask tracks supported write-deny rights" {
    const v1 = sandbox.readOnlyLandlockAccessMaskForAbi(1);
    const v2 = sandbox.readOnlyLandlockAccessMaskForAbi(2);
    const v3 = sandbox.readOnlyLandlockAccessMaskForAbi(3);

    try std.testing.expect(v1 != 0);
    // Bit 13 is LANDLOCK_ACCESS_FS_REFER, which Landlock ABI 2 added, and bit 14
    // LANDLOCK_ACCESS_FS_TRUNCATE, which ABI 3 added.
    try std.testing.expect((v1 & (@as(u64, 1) << 13)) == 0);
    try std.testing.expect((v2 & (@as(u64, 1) << 13)) != 0);
    try std.testing.expect((v2 & (@as(u64, 1) << 14)) == 0);
    try std.testing.expect((v3 & (@as(u64, 1) << 14)) != 0);
}

test "a sandboxed gateway sees a read-only root holding the host's trust store and nothing else" {
    if (!hostHasTrustStore()) {
        std.debug.print("skipped: no CA bundle on this host\n", .{});
        return error.SkipZigTest;
    }
    if (try probeExit(probeUserAndMountNamespaces) != probe_ok) {
        std.debug.print("skipped: no unprivileged user and mount namespaces on this host\n", .{});
        return error.SkipZigTest;
    }

    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe[0]);
    const pid = std.posix.fork() catch |err| {
        std.posix.close(pipe[1]);
        return err;
    };
    if (pid == 0) {
        std.posix.close(pipe[0]);
        sandbox.applyProcessBaseline() catch |err| {
            writeReport(pipe[1], .{ .failed = @intFromError(err) });
            childExit(0);
        };
        var checks: u16 = 0;
        if (readableNonEmpty("/etc/ssl/cert.pem")) checks |= 1 << 0;
        if (createRefused("/collo-test-file")) checks |= 1 << 1;
        if (writeRefused("/etc/ssl/cert.pem")) checks |= 1 << 2;
        if (absent("/proc/self")) checks |= 1 << 3;
        if (rootHoldsOnlyEtc()) checks |= 1 << 4;
        writeReport(pipe[1], .{ .checks = checks });
        childExit(0);
    }
    std.posix.close(pipe[1]);

    const checks = try readReport(pipe[0], pid);
    try std.testing.expectEqual(@as(u16, 0b1_1111), checks);
}

test "a sandboxed gateway holds every decoder library the host provides when it reports ready" {
    const host_decoders = decompress.load();
    if (!host_decoders.zlib) {
        std.debug.print("skipped: zlib does not load on this host\n", .{});
        return error.SkipZigTest;
    }
    if (!hostHasTrustStore()) {
        std.debug.print("skipped: no CA bundle on this host\n", .{});
        return error.SkipZigTest;
    }
    if (try probeExit(probeUserAndMountNamespaces) != probe_ok) {
        std.debug.print("skipped: no unprivileged user and mount namespaces on this host\n", .{});
        return error.SkipZigTest;
    }
    if (try probeExit(probeSeccomp) != probe_ok) {
        std.debug.print("skipped: no seccomp filters for this process\n", .{});
        return error.SkipZigTest;
    }

    // An exec'd gateway, unlike a fork of this process, starts without the libraries this
    // process has loaded, so only its own boot can have mapped them.
    const table = gateway.policy.PolicyTable.single(gateway.policy.public_https);
    var spawned = try server_gateway.process.spawn(std.testing.allocator, .{
        .executable_path = process_options.collo_executable_path,
        .key = .{ .bytes = @splat(0x5a) },
        .table = &table,
    });
    defer spawned.deinit();

    // Ready comes after the sandbox, whose root holds no library, so what the gateway maps now is
    // every decoder it will ever have.
    var path_buffer: [32]u8 = undefined;
    const maps_path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/maps", .{spawned.pid});
    const maps = try std.fs.cwd().readFileAlloc(std.testing.allocator, maps_path, maps_bytes_max);
    defer std.testing.allocator.free(maps);
    try std.testing.expect(mapsFileStartingWith(maps, "libz.so"));
    try std.testing.expectEqual(host_decoders.brotli, mapsFileStartingWith(maps, "libbrotlidec.so"));
}

test "the gateway's syscall filter refuses Unix sockets and allows network sockets" {
    if (try probeExit(probeSeccomp) != probe_ok) {
        std.debug.print("skipped: no seccomp filters for this process\n", .{});
        return error.SkipZigTest;
    }

    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe[0]);
    const pid = std.posix.fork() catch |err| {
        std.posix.close(pipe[1]);
        return err;
    };
    if (pid == 0) {
        std.posix.close(pipe[0]);
        // The gateway sets no-new-privileges first, without which an unprivileged process may
        // not install a filter; the probe showed it can be set here.
        const prctl_rc = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
        if (linux.E.init(prctl_rc) != .SUCCESS)
            childExit(121);
        sandbox.applySeccompAfterThreadsStarted() catch |err| {
            writeReport(pipe[1], .{ .failed = @intFromError(err) });
            childExit(0);
        };
        var checks: u16 = 0;
        if (socketErrno(linux.AF.UNIX, linux.SOCK.STREAM) == .PERM) checks |= 1 << 0;
        if (socketErrno(linux.AF.UNIX, linux.SOCK.DGRAM) == .PERM) checks |= 1 << 1;
        if (socketErrno(linux.AF.INET, linux.SOCK.STREAM) == .SUCCESS) checks |= 1 << 2;
        if (socketErrno(linux.AF.INET, linux.SOCK.DGRAM) == .SUCCESS) checks |= 1 << 3;
        writeReport(pipe[1], .{ .checks = checks });
        childExit(0);
    }
    std.posix.close(pipe[1]);

    const checks = try readReport(pipe[0], pid);
    try std.testing.expectEqual(@as(u16, 0b1111), checks);
}

/// What a sandboxed child sends back: the bits of the checks that held, or the error the
/// sandbox returned. The child is a fork of this binary, so the error's integer names the same
/// error here.
const Report = union(enum) {
    checks: u16,
    failed: u16,

    const wire_bytes = 3;
    const tag_checks: u8 = 0;
    const tag_failed: u8 = 1;

    comptime {
        // `failed` holds any error's integer.
        std.debug.assert(@bitSizeOf(anyerror) <= 16);
    }
};

fn hostHasTrustStore() bool {
    for (sandbox.trust_store_sources) |path| {
        const stat = std.posix.fstatatZ(std.posix.AT.FDCWD, path, 0) catch continue;
        if ((stat.mode & linux.S.IFMT) == linux.S.IFREG)
            return true;
    }
    return false;
}

/// Runs `probe` in a forked child and returns its exit status, `probe_ok` when the host has the
/// capability. The probes use raw system calls written apart from the sandbox, so a defect in
/// the sandbox cannot make a capable host look incapable.
fn probeExit(probe: fn () u8) !u8 {
    const pid = try std.posix.fork();
    if (pid == 0)
        childExit(probe());
    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    return @intCast(std.c.W.EXITSTATUS(wait.status));
}

/// The namespaces and mounts the sandbox's root needs: a user namespace with this process's ids
/// mapped, a private mount namespace, and a tmpfs over `sandbox.staging_path`.
fn probeUserAndMountNamespaces() u8 {
    const uid = linux.getuid();
    const gid = linux.getgid();
    if (linux.E.init(linux.unshare(linux.CLONE.NEWUSER)) != .SUCCESS) return probe_missing;
    if (!writeProcFile("/proc/self/setgroups", "deny\n")) return probe_missing;
    var map_buffer: [64]u8 = undefined;
    const uid_map = std.fmt.bufPrint(&map_buffer, "0 {d} 1\n", .{uid}) catch unreachable;
    if (!writeProcFile("/proc/self/uid_map", uid_map)) return probe_missing;
    const gid_map = std.fmt.bufPrint(&map_buffer, "0 {d} 1\n", .{gid}) catch unreachable;
    if (!writeProcFile("/proc/self/gid_map", gid_map)) return probe_missing;
    if (linux.E.init(linux.unshare(linux.CLONE.NEWNS)) != .SUCCESS) return probe_missing;
    if (linux.E.init(linux.mount(null, "/", null, linux.MS.PRIVATE | linux.MS.REC, 0)) != .SUCCESS)
        return probe_missing;
    if (linux.E.init(linux.mount("tmpfs", sandbox.staging_path, "tmpfs", 0, 0)) != .SUCCESS)
        return probe_missing;
    return probe_ok;
}

/// A filter that allows everything, installed after no-new-privileges as the gateway does.
fn probeSeccomp() u8 {
    if (linux.E.init(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS)
        return probe_missing;
    const Instruction = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
    const Program = extern struct { len: u16, filter: [*]const Instruction };
    const bpf_ret_k: u16 = 0x06;
    const allow_all = [_]Instruction{.{ .code = bpf_ret_k, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.ALLOW }};
    const program: Program = .{ .len = allow_all.len, .filter = &allow_all };
    if (linux.E.init(linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &program)) != .SUCCESS)
        return probe_missing;
    return probe_ok;
}

fn writeProcFile(path: [:0]const u8, bytes: []const u8) bool {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.E.init(rc) != .SUCCESS)
        return false;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    return linux.write(fd, bytes.ptr, bytes.len) == bytes.len;
}

fn childExit(code: u8) noreturn {
    linux.exit_group(code);
}

fn writeReport(fd: std.posix.fd_t, report: Report) void {
    var bytes: [Report.wire_bytes]u8 = undefined;
    switch (report) {
        .checks => |checks| {
            bytes[0] = Report.tag_checks;
            std.mem.writeInt(u16, bytes[1..3], checks, .little);
        },
        .failed => |error_value| {
            bytes[0] = Report.tag_failed;
            std.mem.writeInt(u16, bytes[1..3], error_value, .little);
        },
    }
    const written = std.posix.write(fd, &bytes) catch childExit(122);
    if (written != bytes.len) childExit(123);
}

/// The checks a child reports, or the sandbox's error when the child reports one.
fn readReport(fd: std.posix.fd_t, pid: std.posix.pid_t) !u16 {
    var bytes: [Report.wire_bytes]u8 = undefined;
    const read_len = try std.posix.read(fd, &bytes);
    const wait = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.c.W.IFEXITED(wait.status));
    try std.testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(wait.status));
    try std.testing.expectEqual(bytes.len, read_len);
    const value = std.mem.readInt(u16, bytes[1..3], .little);
    switch (bytes[0]) {
        Report.tag_checks => return value,
        Report.tag_failed => {
            const err = @errorFromInt(value);
            std.debug.print("the sandbox failed: {s}\n", .{@errorName(err)});
            return err;
        },
        else => return error.UnexpectedChildReport,
    }
}

fn readableNonEmpty(path: [:0]const u8) bool {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.E.init(rc) != .SUCCESS)
        return false;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var byte: [1]u8 = undefined;
    return linux.read(fd, &byte, byte.len) == 1;
}

/// Whether opening `path` with `flags` fails; the raw syscall keeps an errno the standard
/// library does not expect, such as EROFS, from printing a trace.
fn openRefused(path: [:0]const u8, flags: linux.O) bool {
    const rc = linux.open(path, flags, 0o600);
    if (linux.E.init(rc) != .SUCCESS)
        return true;
    _ = linux.close(@intCast(rc));
    return false;
}

fn createRefused(path: [:0]const u8) bool {
    return openRefused(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
}

fn writeRefused(path: [:0]const u8) bool {
    return openRefused(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
}

fn absent(path: [:0]const u8) bool {
    _ = std.posix.fstatatZ(std.posix.AT.FDCWD, path, 0) catch |err| return err == error.FileNotFound;
    return false;
}

fn rootHoldsOnlyEtc() bool {
    var dir = std.fs.openDirAbsolute("/", .{ .iterate = true }) catch return false;
    defer dir.close();
    var iterator = dir.iterate();
    var saw_etc = false;
    while (iterator.next() catch return false) |entry| {
        if (!std.mem.eql(u8, entry.name, "etc"))
            return false;
        saw_etc = true;
    }
    return saw_etc;
}

/// Whether `maps`, the text of a `/proc/<pid>/maps` file, maps a file whose name starts with
/// `prefix`.
fn mapsFileStartingWith(maps: []const u8, prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        const slash = std.mem.lastIndexOfScalar(u8, line, '/') orelse continue;
        if (std.mem.startsWith(u8, line[slash + 1 ..], prefix))
            return true;
    }
    return false;
}

fn socketErrno(domain: u32, socket_type: u32) linux.E {
    const rc = linux.socket(domain, socket_type | linux.SOCK.CLOEXEC, 0);
    const errno = linux.E.init(rc);
    if (errno == .SUCCESS)
        _ = linux.close(@intCast(rc));
    return errno;
}
