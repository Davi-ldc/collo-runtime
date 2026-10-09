//! The egress gateway's sandbox, which the gateway process applies to itself on its main thread.
//! The server has no part in it: the gateway builds its root inside its own mount namespace, so
//! nothing of the root is visible in the server's, and nothing is left there when the gateway
//! dies however it ends. There is no relaxed mode: every gateway runs the whole sandbox.
//!
//! `applyProcessBaseline` runs first, while the process is single-threaded, because
//! `unshare(CLONE_NEWUSER)` refuses a multithreaded caller. It enters a user and a mount namespace
//! and lowers the resource limits. It then opens the machine's trust store and resolver files and
//! mounts a tmpfs over `staging_path`, which hides what the machine keeps below that path in this
//! namespace only; binds the opened files into the tmpfs read-only, makes the tmpfs read-only too
//! and chroots into it; and finally drops every capability, sets no-new-privileges and installs a
//! Landlock ruleset that denies every write. `applySeccompAfterThreadsStarted` runs last, once the
//! engine threads exist, and installs the syscall filter on all of them.
//!
//! The gateway keeps the network namespace it inherits from the server, since it is the process
//! that dials out; what else of the machine it could reach is cut here. Its root holds only
//! `etc/ssl/cert.pem`, the trust store BoringSSL loads by default, and the `resolver_files`
//! glibc's resolver reads. Each is a read-only bind of the machine's file as it was at boot, so a
//! file replaced later stays the old one for this gateway. The root has no `/proc`, no `/dev` and
//! no shared library, and nothing in it is writable. A library first opened inside the root is
//! therefore missing, so the gateway loads every library it uses before `applyProcessBaseline`
//! (`runtime/root.zig`). The gateway's user namespace maps only the uid and gid it was started
//! with, so under a server run by root the gateway keeps uid 0 outside its namespace while
//! holding no capability in the initial one. Abstract Unix sockets, which belong to the network
//! namespace the gateway shares with the server, would still see that identity, so the filter
//! denies creating Unix sockets.

const std = @import("std");
const builtin = @import("builtin");
const fd_mod = @import("collo_os").fd;
const linux_helpers = @import("collo_os").linux;
const os_process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const linux = std.os.linux;

const sizing = @import("sizing.zig");

/// Mode of the tmpfs root.
pub const root_mode: u32 = 0o700;

/// The directory the tmpfs root is mounted over. Only the gateway's mount namespace sees the
/// mount, so the directory only has to exist, and every Linux machine has this one.
pub const staging_path: [:0]const u8 = "/tmp";

/// The machine's locations of the CA bundle, tried in order: BoringSSL's default file first, then
/// the bundles of the common distributions. The first regular file becomes `/etc/ssl/cert.pem` in
/// the gateway's root, where the verified client context loads it at boot.
pub const trust_store_sources = [_][:0]const u8{
    "/etc/ssl/cert.pem",
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
};
const trust_store_target: [:0]const u8 = "etc/ssl/cert.pem";

/// Files glibc's resolver reads, bound at the same path when the machine has them. Without one the
/// resolver falls back to its built-in default. Of the services `nsswitch.conf` names, only
/// `files` and `dns` are built into the glibc this binary needs (2.34 and later); any other
/// `hosts` service, such as `resolve` or `mdns4_minimal`, is a library the root does not hold, so
/// the resolver skips it as unavailable.
pub const resolver_files = [_][:0]const u8{
    "/etc/resolv.conf",
    "/etc/hosts",
    "/etc/nsswitch.conf",
    "/etc/host.conf",
    "/etc/gai.conf",
};

/// Directories created in the tmpfs to hold the mount points, parents first.
const root_directories = [_][:0]const u8{ "etc", "etc/ssl" };

comptime {
    // The tmpfs root, its directories and one mount point per bind.
    std.debug.assert(1 + root_directories.len + 1 + resolver_files.len <=
        process_limits.EGRESS_GATEWAY_ROOT_TMPFS_INODES);
    for (resolver_files) |path| std.debug.assert(std.mem.startsWith(u8, path, "/etc/"));
}

/// Applies every step that must come before the gateway's first thread, in the order the header
/// gives. The calling process must be single-threaded and must hold no descriptor of a directory,
/// which would let `fchdir` walk back out of the chroot. Fails with
/// `error.EgressGatewayTrustStoreMissing` when the machine has no CA bundle at any of
/// `trust_store_sources`.
pub fn applyProcessBaseline() !void {
    try os_process.assertSingleThreadedSelf();
    try namespaces.enter();
    // After the user namespace, so the task limit counts this namespace's tasks.
    try resource_limits.apply();
    try root.mountAndEnter();
    try privileges.dropCapabilities();
    try privileges.disableNewPrivs();
    try landlock.apply();
}

/// Installs the syscall filter on every thread of the process (`SECCOMP_FILTER_FLAG_TSYNC`).
/// Call it once the shard engines have started their threads and the readiness ring exists,
/// since the filter denies creating either.
pub fn applySeccompAfterThreadsStarted() !void {
    try installGatewayFilter();
}

const namespaces = struct {
    fn enter() !void {
        const uid: u32 = @intCast(linux.getuid());
        const gid: u32 = @intCast(linux.getgid());
        try unshare(linux.CLONE.NEWUSER);
        try writeUserNamespaceMaps(uid, gid);
        try unshare(linux.CLONE.NEWNS);
        // Mounts made from here on stay in this namespace instead of propagating to the server's.
        const rc = linux.mount(null, "/", null, linux.MS.PRIVATE | linux.MS.REC, 0);
        try checkMount(rc);
    }

    fn unshare(flags: usize) !void {
        const rc = linux.unshare(flags);
        return switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .INVAL => error.UnsupportedKernel,
            .PERM => error.PermissionDenied,
            .NOMEM, .NOSPC, .USERS => error.SystemResources,
            else => error.EgressGatewaySandboxOperationFailed,
        };
    }

    /// Maps uid and gid 0 of the new namespace to the gateway's own ids, the only mapping an
    /// unprivileged process may write.
    fn writeUserNamespaceMaps(uid: u32, gid: u32) !void {
        try writeProcSelfFile("/proc/self/setgroups", "deny\n");

        var uid_map_buffer: [64]u8 = undefined;
        const uid_map = std.fmt.bufPrint(&uid_map_buffer, "0 {d} 1\n", .{uid}) catch unreachable;
        try writeProcSelfFile("/proc/self/uid_map", uid_map);

        var gid_map_buffer: [64]u8 = undefined;
        const gid_map = std.fmt.bufPrint(&gid_map_buffer, "0 {d} 1\n", .{gid}) catch unreachable;
        try writeProcSelfFile("/proc/self/gid_map", gid_map);
    }

    fn writeProcSelfFile(path: []const u8, bytes: []const u8) !void {
        var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| return mapMapError(err);
        defer file.close();
        file.writeAll(bytes) catch |err| return mapMapError(err);
    }

    fn mapMapError(err: anyerror) anyerror {
        return switch (err) {
            error.AccessDenied => error.PermissionDenied,
            error.FileNotFound => error.UnsupportedKernel,
            error.SystemResources => error.SystemResources,
            else => error.EgressGatewaySandboxOperationFailed,
        };
    }
};

const resource_limits = struct {
    fn apply() !void {
        try lower(.CORE, 0);
        try lower(.NOFILE, try sizing.openFilesLimit());
        try lower(.NPROC, process_limits.EGRESS_GATEWAY_TASKS_MAX);
        try lower(.AS, process_limits.EGRESS_GATEWAY_ADDRESS_SPACE_BYTES_MAX);
    }

    /// Sets the soft and hard limit of `resource` to `ceiling`, or to the inherited hard limit
    /// when that is lower, so the call never needs a privilege.
    fn lower(resource: std.posix.rlimit_resource, ceiling: u64) !void {
        const inherited = std.posix.getrlimit(resource) catch return error.EgressGatewaySandboxOperationFailed;
        const value = @min(ceiling, inherited.max);
        std.posix.setrlimit(resource, .{ .cur = value, .max = value }) catch |err| switch (err) {
            error.PermissionDenied => return error.PermissionDenied,
            error.LimitTooBig => return error.EgressGatewaySandboxOperationFailed,
            else => return error.EgressGatewaySandboxOperationFailed,
        };
    }
};

const root = struct {
    /// The machine's files bound into the root, opened as `O_PATH` descriptors before the tmpfs
    /// covers `staging_path`, so a file reached through that path is still found, and a bind from
    /// `/proc/self/fd/<n>` mounts exactly the file that was checked. They are opened after
    /// `namespaces.enter`, because a bind source must belong to the caller's mount namespace.
    const Sources = struct {
        trust_store: fd_mod.OwnedFd,
        /// One per `resolver_files` entry; invalid when the machine has no such file.
        resolver: [resolver_files.len]fd_mod.OwnedFd,

        /// Fails with `error.EgressGatewayTrustStoreMissing` when no `trust_store_sources` entry
        /// is a regular file, and leaves nothing open on any failure.
        fn open(target: *Sources) !void {
            target.* = .{ .trust_store = .{}, .resolver = @splat(.{}) };
            errdefer target.close();
            for (trust_store_sources) |path| {
                if (try openRegularFile(path)) |opened| {
                    target.trust_store = opened;
                    break;
                }
            }
            if (!target.trust_store.isValid())
                return error.EgressGatewayTrustStoreMissing;
            for (resolver_files, &target.resolver) |path, *source| {
                if (try openRegularFile(path)) |opened|
                    source.* = opened;
            }
        }

        fn close(self: *Sources) void {
            self.trust_store.deinit();
            for (&self.resolver) |*source| source.deinit();
        }
    };

    fn mountAndEnter() !void {
        var sources: Sources = undefined;
        try sources.open();
        defer sources.close();

        try mountTmpfs();
        const mounted = std.posix.open(staging_path, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0) catch return error.InvalidEgressGatewayRoot;
        defer std.posix.close(mounted);
        try validateMounted(mounted);

        for (root_directories) |path| {
            std.posix.mkdirat(mounted, path, 0o755) catch return error.EgressGatewaySandboxOperationFailed;
        }
        try bindReadOnly(mounted, trust_store_target, sources.trust_store.fd());
        for (resolver_files, sources.resolver) |path, source| {
            if (source.isValid())
                try bindReadOnly(mounted, path[1..], source.fd());
        }
        // The binds are mounts of their own and stay read-only; this makes the tmpfs itself
        // read-only, so nothing in the root can be created or changed.
        try remountReadOnly(staging_path);
        try chrootInto(mounted);
    }

    fn mountTmpfs() !void {
        var data_buffer: [128]u8 = undefined;
        const data = std.fmt.bufPrintZ(&data_buffer, "size={d},nr_inodes={d},mode={o},uid={d},gid={d}", .{
            process_limits.EGRESS_GATEWAY_ROOT_TMPFS_BYTES,
            process_limits.EGRESS_GATEWAY_ROOT_TMPFS_INODES,
            root_mode,
            linux.getuid(),
            linux.getgid(),
        }) catch unreachable;
        const rc = linux.mount(
            "tmpfs",
            staging_path,
            "tmpfs",
            linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC,
            @intFromPtr(data.ptr),
        );
        try checkMount(rc);
    }

    /// The mode and owner tell the new tmpfs apart from the machine's directory below it.
    fn validateMounted(fd: std.posix.fd_t) !void {
        var stat: linux.Stat = undefined;
        switch (linux_helpers.syscallErrno(linux.fstat(fd, &stat))) {
            .SUCCESS => {},
            else => return error.InvalidEgressGatewayRoot,
        }
        if ((stat.mode & linux.S.IFMT) != linux.S.IFDIR)
            return error.InvalidEgressGatewayRoot;
        if ((stat.mode & 0o7777) != root_mode)
            return error.InvalidEgressGatewayRoot;
        if (stat.uid != linux.getuid())
            return error.InvalidEgressGatewayRoot;
        if (stat.gid != linux.getgid())
            return error.InvalidEgressGatewayRoot;
    }

    /// `path` as an `O_PATH` descriptor when it names a regular file, following symlinks as the
    /// bind will; null when it names nothing the gateway can reach, or something else.
    fn openRegularFile(path: [:0]const u8) !?fd_mod.OwnedFd {
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .PATH = true, .CLOEXEC = true }, 0);
        switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .NOENT, .NOTDIR, .ACCES, .LOOP, .NAMETOOLONG => return null,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => return error.EgressGatewaySandboxOperationFailed,
        }
        var opened = fd_mod.OwnedFd.fromRaw(@intCast(rc));
        errdefer opened.deinit();
        var stat: linux.Stat = undefined;
        switch (linux_helpers.syscallErrno(linux.fstat(opened.fd(), &stat))) {
            .SUCCESS => {},
            else => return error.EgressGatewaySandboxOperationFailed,
        }
        if ((stat.mode & linux.S.IFMT) != linux.S.IFREG) {
            opened.deinit();
            return null;
        }
        return opened;
    }

    /// Binds the file open at `source` over a new empty file at `target` below the root, then
    /// makes the bind read-only. A read-only remount in a user namespace keeps the source mount's
    /// locked flags as long as it names no atime option, so this never asks for more than the
    /// source mount allows.
    fn bindReadOnly(mounted: std.posix.fd_t, target: [:0]const u8, source: std.posix.fd_t) !void {
        const mount_point = std.posix.openat(mounted, target, .{
            .ACCMODE = .RDONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0o444) catch return error.EgressGatewaySandboxOperationFailed;
        std.posix.close(mount_point);

        var source_buffer: [32]u8 = undefined;
        const source_path = std.fmt.bufPrintZ(&source_buffer, "/proc/self/fd/{d}", .{source}) catch unreachable;
        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target_path = std.fmt.bufPrintZ(&target_buffer, "{s}/{s}", .{ staging_path, target }) catch
            return error.InvalidEgressGatewayRoot;
        try checkMount(linux.mount(source_path, target_path, null, linux.MS.BIND, 0));
        try remountReadOnly(target_path);
    }

    fn remountReadOnly(path: [:0]const u8) !void {
        const flags = linux.MS.REMOUNT | linux.MS.BIND | linux.MS.RDONLY |
            linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC;
        try checkMount(linux.mount(null, path, null, flags, 0));
    }

    fn chrootInto(mounted: std.posix.fd_t) !void {
        try std.posix.fchdir(mounted);
        const rc = linux.chroot(".");
        switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .ACCES, .PERM => return error.PermissionDenied,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .IO => return error.InputOutput,
            else => return error.EgressGatewaySandboxOperationFailed,
        }
        try std.posix.chdir("/");
    }
};

fn checkMount(rc: usize) !void {
    return switch (linux_helpers.syscallErrno(rc)) {
        .SUCCESS => {},
        .ACCES, .PERM => error.PermissionDenied,
        .NOENT, .NOTDIR => error.InvalidEgressGatewayRoot,
        .INVAL => error.UnsupportedKernel,
        .NOMEM => error.SystemResources,
        else => error.EgressGatewaySandboxOperationFailed,
    };
}

const privileges = struct {
    /// Capabilities belong to a thread, so this runs before any other thread exists.
    fn dropCapabilities() !void {
        linux_helpers.dropAllCapabilities() catch |err| switch (err) {
            error.UnsupportedKernel => return error.UnsupportedKernel,
            error.PermissionDenied => return error.PermissionDenied,
            else => return error.EgressGatewaySandboxOperationFailed,
        };
    }

    fn disableNewPrivs() !void {
        const rc = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
        return switch (linux_helpers.syscallErrno(rc)) {
            .SUCCESS => {},
            .INVAL, .BADF => error.UnsupportedKernel,
            .PERM => error.PermissionDenied,
            else => error.EgressGatewaySandboxOperationFailed,
        };
    }
};

const landlock = struct {
    const create_ruleset_version: usize = 1 << 0;

    const access_fs_write_file: u64 = 1 << 1;
    const access_fs_remove_dir: u64 = 1 << 4;
    const access_fs_remove_file: u64 = 1 << 5;
    const access_fs_make_char: u64 = 1 << 6;
    const access_fs_make_dir: u64 = 1 << 7;
    const access_fs_make_reg: u64 = 1 << 8;
    const access_fs_make_sock: u64 = 1 << 9;
    const access_fs_make_fifo: u64 = 1 << 10;
    const access_fs_make_block: u64 = 1 << 11;
    const access_fs_make_sym: u64 = 1 << 12;
    const access_fs_refer: u64 = 1 << 13;
    const access_fs_truncate: u64 = 1 << 14;

    const RulesetAttrV1 = extern struct {
        handled_access_fs: u64,
    };

    /// The read-only root already denies every write, so a kernel without Landlock loses only
    /// this second layer: the gateway logs it and boots. Any other failure ends the boot.
    fn apply() !void {
        installReadOnly() catch |err| switch (err) {
            error.UnsupportedKernel => std.log.warn(
                "egress gateway: the kernel has no Landlock; only the read-only root denies writes",
                .{},
            ),
            else => return err,
        };
    }

    /// Handles every write right the kernel's Landlock version knows and grants none of them, so
    /// the process cannot write anywhere while reads stay open.
    fn installReadOnly() !void {
        const abi_rc = linux.syscall3(.landlock_create_ruleset, 0, 0, create_ruleset_version);
        const abi_version: u32 = switch (linux_helpers.syscallErrno(abi_rc)) {
            .SUCCESS => @intCast(abi_rc),
            .NOSYS, .OPNOTSUPP, .INVAL => return error.UnsupportedKernel,
            else => return error.EgressGatewaySandboxOperationFailed,
        };
        const handled_access_fs = readOnlyLandlockAccessMaskForAbi(abi_version);
        if (handled_access_fs == 0)
            return error.UnsupportedKernel;

        var attr = RulesetAttrV1{ .handled_access_fs = handled_access_fs };
        const ruleset_rc = linux.syscall3(
            .landlock_create_ruleset,
            @intFromPtr(&attr),
            @sizeOf(RulesetAttrV1),
            0,
        );
        const ruleset_fd: std.posix.fd_t = switch (linux_helpers.syscallErrno(ruleset_rc)) {
            .SUCCESS => @intCast(ruleset_rc),
            .NOSYS, .OPNOTSUPP, .INVAL => return error.UnsupportedKernel,
            .NOMEM => return error.SystemResources,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.EgressGatewaySandboxOperationFailed,
        };
        defer std.posix.close(ruleset_fd);

        const restrict_rc = linux.syscall2(.landlock_restrict_self, @intCast(ruleset_fd), 0);
        return switch (linux_helpers.syscallErrno(restrict_rc)) {
            .SUCCESS => {},
            .NOSYS, .OPNOTSUPP, .INVAL => error.UnsupportedKernel,
            .PERM => error.PermissionDenied,
            .NOMEM => error.SystemResources,
            else => error.EgressGatewaySandboxOperationFailed,
        };
    }
};

pub fn readOnlyLandlockAccessMaskForAbi(abi_version: u32) u64 {
    if (abi_version == 0)
        return 0;
    var mask: u64 =
        landlock.access_fs_write_file |
        landlock.access_fs_remove_dir |
        landlock.access_fs_remove_file |
        landlock.access_fs_make_char |
        landlock.access_fs_make_dir |
        landlock.access_fs_make_reg |
        landlock.access_fs_make_sock |
        landlock.access_fs_make_fifo |
        landlock.access_fs_make_block |
        landlock.access_fs_make_sym;
    if (abi_version >= 2)
        mask |= landlock.access_fs_refer;
    if (abi_version >= 3)
        mask |= landlock.access_fs_truncate;
    return mask;
}

const sock_filter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

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

/// Syscalls the filter fails with EPERM. A name the target's syscall table lacks is skipped
/// (`hasSyscall`).
const blocked_syscalls = [_][]const u8{
    "io_uring_setup",
    "io_uring_register",
    "bind",
    "listen",
    "accept",
    "accept4",
    "memfd_create",
    "creat",
    "dup",
    "dup2",
    "dup3",
    "pidfd_getfd",
    "pidfd_open",
    "pidfd_send_signal",
    "kill",
    "tkill",
    "tgkill",
    "rt_sigqueueinfo",
    "rt_tgsigqueueinfo",
    "clone",
    "clone3",
    "fork",
    "vfork",
    "execve",
    "execveat",
    "unshare",
    "setns",
    "mount",
    "umount2",
    "open_tree",
    "move_mount",
    "fsopen",
    "fsconfig",
    "fsmount",
    "fspick",
    "mount_setattr",
    "pivot_root",
    "chroot",
    "ptrace",
    "process_vm_readv",
    "process_vm_writev",
    "bpf",
    "perf_event_open",
    "userfaultfd",
    "keyctl",
    "add_key",
    "request_key",
    "open_by_handle_at",
    "init_module",
    "finit_module",
    "delete_module",
    "kexec_load",
    "kexec_file_load",
    "reboot",
    "swapon",
    "swapoff",
};

/// Room for the architecture check and the argument policies ahead of the blocklist, plus two
/// instructions per blocked syscall.
const filter_capacity = 40 + blocked_syscalls.len * 2;

fn installGatewayFilter() !void {
    var program: [filter_capacity]sock_filter = undefined;
    var len: usize = 0;

    append(&program, &len, stmt(bpf.LD | bpf.W | bpf.ABS, @intCast(@offsetOf(linux.SECCOMP.data, "arch"))));
    append(&program, &len, jump(bpf.JMP | bpf.JEQ | bpf.K, auditArchCurrent(), 1, 0));
    append(&program, &len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.KILL_PROCESS));
    append(&program, &len, stmt(bpf.LD | bpf.W | bpf.ABS, @intCast(@offsetOf(linux.SECCOMP.data, "nr"))));
    appendX86_64CompatGuards(&program, &len);
    appendFcntlDupPolicy(&program, &len);
    appendUnixSocketPolicy(&program, &len);

    inline for (blocked_syscalls) |name| {
        if (comptime hasSyscall(name)) {
            append(&program, &len, jump(bpf.JMP | bpf.JEQ | bpf.K, syscallNumber(name), 0, 1));
            append(&program, &len, denyPerm());
        }
    }

    append(&program, &len, stmt(bpf.RET | bpf.K, linux.SECCOMP.RET.ALLOW));

    const filter = sock_fprog{
        .len = @intCast(len),
        .filter = &program,
    };
    const rc = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, linux.SECCOMP.FILTER_FLAG.TSYNC, &filter);
    const seccomp_errno = linux_helpers.syscallErrno(rc);
    if (seccomp_errno == .SUCCESS and rc != 0)
        return error.EgressGatewaySandboxOperationFailed;
    return switch (seccomp_errno) {
        .SUCCESS => {},
        .INVAL => error.UnsupportedKernel,
        .PERM => error.PermissionDenied,
        .SRCH => error.EgressGatewaySandboxOperationFailed,
        .NOMEM => error.SystemResources,
        else => error.EgressGatewaySandboxOperationFailed,
    };
}

/// On x86-64, fails with EPERM every call that sets the x32 ABI bit and the numbers 512 through
/// 547 that the x32 ABI's own entries use. x32 calls pass the x86-64 architecture check, so
/// without this the blocklist, written in x86-64 numbers, could be reached under x32 numbers.
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

/// fcntl(F_DUPFD) and fcntl(F_DUPFD_CLOEXEC) fail with EPERM like dup, dup2 and dup3 in the
/// blocklist; a command with a nonzero high word is refused as well.
fn appendFcntlDupPolicy(program: []sock_filter, len: *usize) void {
    if (comptime !hasSyscall("fcntl"))
        return;
    append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, syscallNumber("fcntl"), 0, 7));
    append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg1HighOffset()));
    append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
    append(program, len, denyPerm());
    append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg1LowOffset()));
    append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, linux_f_dupfd, 1, 0));
    append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, linux_f_dupfd_cloexec, 0, 1));
    append(program, len, denyPerm());
    append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, @intCast(@offsetOf(linux.SECCOMP.data, "nr"))));
}

/// socket(AF_UNIX) fails with EPERM. Abstract Unix sockets belong to the network namespace, which
/// the gateway shares with the server, so the chroot does not hide them, and a new Unix socket
/// could reach a session bus or another local service as the gateway's user. The gateway needs none
/// after boot: glibc's resolver treats a refused nscd socket as no nscd. The domain is a kernel
/// `int`, so a nonzero high word is refused as well.
fn appendUnixSocketPolicy(program: []sock_filter, len: *usize) void {
    if (comptime !hasSyscall("socket"))
        return;
    append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, syscallNumber("socket"), 0, 6));
    append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0HighOffset()));
    append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, 0, 1, 0));
    append(program, len, denyPerm());
    append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, arg0LowOffset()));
    append(program, len, jump(bpf.JMP | bpf.JEQ | bpf.K, linux.AF.UNIX, 0, 1));
    append(program, len, denyPerm());
    append(program, len, stmt(bpf.LD | bpf.W | bpf.ABS, @intCast(@offsetOf(linux.SECCOMP.data, "nr"))));
}

const linux_f_dupfd: u32 = 0;
const linux_f_dupfd_cloexec: u32 = 1030;

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
        else => @compileError("egress gateway seccomp audit arch is not defined for this target"),
    };
}

fn append(program: []sock_filter, len: *usize, instruction: sock_filter) void {
    std.debug.assert(len.* < program.len);
    program[len.*] = instruction;
    len.* += 1;
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
