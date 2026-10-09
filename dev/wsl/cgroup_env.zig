//! `wsl-config` provisions and enters the delegated cgroup v2 subtree that the
//! kernel test lanes, `collo serve` and the benchmarks need on a development
//! machine, since WSL2 does not delegate controllers to the user by default.
//! Production never runs it: there systemd delegates, and `WorkerCgroupRoot`
//! in `runtime/src/host/cgroup_root.zig` carves the worker subtree.
//!
//! Every command is a short-lived, single-threaded process. The runner cgroup
//! is `COLLO_TEST_CGROUP`, or `default_runner_root` when that is unset, and its
//! parent is the dev root. `prepare` needs root once per boot: it creates both
//! directories, enables cpu, memory and pids at the cgroup2 root and in the dev
//! root, and delegates both to the sudo caller: each directory and the control
//! files the kernel lists in `/sys/kernel/cgroup/delegate`. `run` moves itself
//! into the runner, drops back to the sudo caller and execs the command with
//! `COLLO_TEST_WORKER_CGROUP_ROOT` set to the dev root, under which kernel
//! tests create worker cgroups. From a shell outside the subtree, only that
//! first move needs root.
//!
//! The move comes before exec because cgroup v2 never migrates memory charges.
//! Pages faulted before it, including shared pages inherited across fork, stay
//! charged to the cgroup that faulted them, normally the caller's; exec frees
//! this process's private pages but leaves shared pages and the file cache
//! charged where they were. New charges from the command, and from this
//! process's own work after the move, go to the runner.
//!
//! The scope commands give a benchmark trial its own accounting and need no
//! root once `prepare` has run. `scope-create <path>` makes an empty direct
//! child of the dev root with a `main` leaf and a process-free `workers`
//! branch, enables cpu, memory and pids for the children of the scope and of
//! `workers`, and sets the scope's `memory.swap.max` to zero, which binds every
//! cgroup below it. The caller keeps its own processes in the runner and starts
//! only the benchmark daemon through `COLLO_TEST_CGROUP=<trial>/main wsl-config
//! run`. That run exports `<trial>`, the runner's parent, as
//! `COLLO_TEST_WORKER_CGROUP_ROOT`, so the caller names `<trial>/workers` to
//! the daemon itself through `COLLO_BENCH_CGROUP_ROOT` (`Session.start` in
//! `runtime/bench/sandbox/controller.zig`). The daemon, its zygote, its gateway
//! and its workers then share the trial's accounting. `scope-remove`
//! removes a scope only once no process is left in it and never kills;
//! `scope-kill` empties a `collo-bench-*` scope through `cgroup.kill`. Scope
//! commands never move a process and reach the scope only through directories
//! opened without following symlinks.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/vfs.h");
});

const cgroup_mount = "/sys/fs/cgroup";
const default_runner_root = "/sys/fs/cgroup/collo-dev/runner";
const runner_env = "COLLO_TEST_CGROUP";
const worker_root_env = "COLLO_TEST_WORKER_CGROUP_ROOT";

const controllers = [_][]const u8{ "cpu", "memory", "pids" };

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const paths = try resolvePaths(allocator);
    defer paths.deinit(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const command = if (args.len >= 2) args[1] else "check";
    if (std.mem.eql(u8, command, "check")) {
        try check(paths);
        return;
    }
    if (std.mem.eql(u8, command, "prepare")) {
        try prepare(paths);
        try check(paths);
        return;
    }
    if (std.mem.eql(u8, command, "scope-create") or
        std.mem.eql(u8, command, "scope-remove") or
        std.mem.eql(u8, command, "scope-kill"))
    {
        if (args.len != 3) usageAndExit();
        // Scope operations need only the delegation `prepare` set up. Under
        // sudo, root is dropped first: the kernel gives a new cgroup and its
        // control files the creator's fsuid and fsgid, so the scope then
        // belongs to the sudo caller, like the dev root.
        _ = try dropSudoPrivileges();
        var parent = try openScopeParent(paths, args[2]);
        defer parent.close();
        const name = std.fs.path.basename(args[2]);
        if (std.mem.eql(u8, command, "scope-create")) {
            try createScope(parent, name);
        } else if (std.mem.eql(u8, command, "scope-kill")) {
            // A failed benchmark daemon can leave descendants behind. Only the
            // `collo-bench-*` scopes the benchmark controller creates, one per
            // trial, may be killed, so a wrong path cannot kill the processes
            // of a runner or of another tool's scope.
            if (!std.mem.startsWith(u8, name, "collo-bench-"))
                return error.InvalidBenchmarkScope;
            var scope = try parent.openDir(name, .{ .no_follow = true });
            defer scope.close();
            try validateScopeDirectory(scope);
            try writeScopeControl(scope, "cgroup.kill", "1");
        } else {
            var remaining: u32 = scope_entry_limit;
            try removeScopeTree(parent, name, 0, &remaining);
        }
        return;
    }
    if (std.mem.eql(u8, command, "run")) {
        const command_start: usize = if (args.len >= 3 and std.mem.eql(u8, args[2], "--")) 3 else 2;
        if (command_start >= args.len) {
            usageAndExit();
        }
        healRunnerLeaf(paths);
        try enterRunner(paths);
        const sudo_home = try dropSudoPrivileges();
        try execWithWorkerCgroupEnv(allocator, paths, sudo_home, args[command_start..]);
        return;
    }

    usageAndExit();
}

const Paths = struct {
    /// Leaf cgroup the runner process enters (COLLO_TEST_CGROUP).
    runner_root: []const u8,
    /// Parent of the runner; exported as COLLO_TEST_WORKER_CGROUP_ROOT.
    dev_root: []const u8,
    /// Runner path relative to the cgroup2 mount, with a leading slash, for
    /// exact matching against /proc/self/cgroup.
    runner_relative: []const u8,
    owned: bool,

    fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        if (!self.owned)
            return;
        allocator.free(self.runner_root);
    }
};

fn resolvePaths(allocator: std.mem.Allocator) !Paths {
    const env_value = std.posix.getenv(runner_env);
    const runner_root = if (env_value) |value|
        try allocator.dupe(u8, std.mem.trimRight(u8, value, "/"))
    else
        default_runner_root;
    if (!std.mem.startsWith(u8, runner_root, cgroup_mount ++ "/")) {
        std.debug.print(
            "{s}='{s}' must live under {s}/\n",
            .{ runner_env, runner_root, cgroup_mount },
        );
        std.process.exit(64);
    }
    return .{
        .runner_root = runner_root,
        .dev_root = std.fs.path.dirname(runner_root) orelse unreachable,
        .runner_relative = runner_root[cgroup_mount.len..],
        .owned = env_value != null,
    };
}

fn usageAndExit() noreturn {
    std.debug.print(
        \\usage:
        \\  zig build wsl-config                 (check)
        \\  zig build wsl-config -- check
        \\  zig build wsl-config -- run -- <command> [args...]
        \\  sudo --preserve-env=PATH ./zig-out/bin/wsl-config run -- <command> [args...]
        \\  ./zig-out/bin/wsl-config scope-create <absolute-child-path>
        \\  ./zig-out/bin/wsl-config scope-remove <absolute-child-path>
        \\  ./zig-out/bin/wsl-config scope-kill <absolute-collo-bench-child-path>
        \\
        \\prepare needs root, but never run `sudo zig build` (it leaves a
        \\root-owned zig cache behind). Build once, then:
        \\  zig build wsl-config
        \\  sudo ./zig-out/bin/wsl-config prepare
        \\
        \\The run command enters the runner cgroup (COLLO_TEST_CGROUP, default
        \\/sys/fs/cgroup/collo-dev/runner) and exports
        \\COLLO_TEST_WORKER_CGROUP_ROOT=<its parent> for kernel tests. From a
        \\shell already inside collo-dev it needs no root; the first hop from
        \\outside does (cgroup2 common-ancestor rule) — use the sudo form, which
        \\drops back to the invoking user before exec'ing the command.
        \\
        \\Scopes are exclusive direct children of that runner's parent under
        \\/sys/fs/cgroup/collo-dev. Prepare delegation first; scope operations
        \\need no root and never move processes. Create produces <trial>/main
        \\and <trial>/workers with cpu, memory, pids and memory.swap.max=0.
        \\Keep the controller/client/sampler in the runner and launch only the
        \\server via COLLO_TEST_CGROUP=<trial>/main wsl-config run -- <server>.
        \\That run exports COLLO_TEST_WORKER_CGROUP_ROOT=<trial>; explicitly
        \\configure worker placement as <trial>/workers. Remove only after all
        \\trial processes exit; populated scopes are refused, never killed.
        \\
    , .{});
    std.process.exit(64);
}

fn check(paths: Paths) !void {
    const uts = std.posix.uname();
    const release = std.mem.sliceTo(&uts.release, 0);
    const is_wsl = std.ascii.indexOfIgnoreCase(release, "microsoft") != null;
    std.debug.print("kernel={s}\n", .{release});
    std.debug.print("wsl={s}\n", .{if (is_wsl) "yes" else "no"});

    const cgroup_ready = cgroupRootUsable(paths.dev_root);
    std.debug.print("cgroup_root={s} usable={s}\n", .{
        paths.dev_root,
        if (cgroup_ready) "yes" else "no",
    });

    const in_runner = currentProcessInRunner(paths.runner_relative);
    std.debug.print("current_cgroup_runner={s}\n", .{if (in_runner) "yes" else "no"});
    std.debug.print("export {s}={s}\n", .{ worker_root_env, paths.dev_root });

    if (!cgroup_ready) {
        std.debug.print(
            "hint: run `sudo ./zig-out/bin/wsl-config prepare` after a WSL restart.\n",
            .{},
        );
    }
    if (!in_runner) {
        std.debug.print(
            "hint: run kernel targets via `zig build wsl-config -- run -- zig build <target> ...`.\n",
            .{},
        );
    }
}

const scope_depth_limit = 8;
const scope_entry_limit = 1 << 20;

/// Opens the parent of `target`, which must be an absolute path naming a direct
/// child of the dev root other than the runner, with the dev root at or under
/// `/sys/fs/cgroup/collo-dev`. Every component is opened without following
/// symlinks and the result must be a cgroup2 directory; the caller keeps all
/// scope I/O relative to it, so no scope command touches a directory outside
/// cgroupfs. Fails with `error.InvalidScopeParent`, `error.InvalidScopePath`,
/// `error.InvalidCgroupDirectory` or the error of an open.
fn openScopeParent(paths: Paths, target: []const u8) !std.fs.Dir {
    const delegated_root = cgroup_mount ++ "/collo-dev";
    if (!std.mem.eql(u8, paths.dev_root, delegated_root) and
        !std.mem.startsWith(u8, paths.dev_root, delegated_root ++ "/"))
        return error.InvalidScopeParent;
    if (target.len == 0 or target.len >= std.fs.max_path_bytes or target[0] != '/')
        return error.InvalidScopePath;
    if (std.mem.indexOfScalar(u8, target, 0) != null) return error.InvalidScopePath;
    var parts = std.mem.splitScalar(u8, target[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.InvalidScopePath;
    }
    const parent = std.fs.path.dirname(target) orelse return error.InvalidScopePath;
    if (!std.mem.eql(u8, parent, paths.dev_root)) return error.InvalidScopePath;
    if (std.mem.eql(u8, target, paths.runner_root)) return error.InvalidScopePath;

    var directory = try std.fs.openDirAbsolute("/", .{ .no_follow = true });
    errdefer directory.close();
    var components = std.mem.splitScalar(u8, parent[1..], '/');
    while (components.next()) |component| {
        const child = try directory.openDir(component, .{ .no_follow = true });
        directory.close();
        directory = child;
    }
    try validateScopeDirectory(directory);
    return directory;
}

fn validateScopeDirectory(directory: std.fs.Dir) !void {
    var stats: c.struct_statfs = undefined;
    if (c.fstatfs(directory.fd, &stats) != 0) return error.InvalidCgroupDirectory;
    if (stats.f_type != 0x63677270) return error.InvalidCgroupDirectory; // CGROUP2_SUPER_MAGIC
}

fn createScope(parent: std.fs.Dir, name: []const u8) !void {
    // Delegation belongs to `prepare`, so ancestors keep their controller
    // settings: a dev root without cpu, memory and pids enabled fails the scope
    // instead of being changed.
    var buffer: [4096]u8 = undefined;
    const enabled = try parent.readFile("cgroup.subtree_control", &buffer);
    for (controllers) |controller| {
        var fields = std.mem.tokenizeAny(u8, enabled, " \n\t");
        var found = false;
        while (fields.next()) |field| {
            if (std.mem.eql(u8, field, controller)) found = true;
        }
        if (!found) return error.CgroupControllerUnavailable;
    }
    try parent.makeDir(name);
    errdefer {
        var remaining: u32 = scope_entry_limit;
        removeScopeTree(parent, name, 0, &remaining) catch |err| {
            std.debug.print("cannot roll back scope {s}: {s}\n", .{ name, @errorName(err) });
        };
    }
    var scope = try parent.openDir(name, .{ .no_follow = true });
    defer scope.close();
    try validateScopeDirectory(scope);
    // A cgroup v2 limit bounds every descendant, so no worker cgroup created
    // later under the scope can swap.
    try writeScopeControl(scope, "memory.swap.max", "0");
    try enableScopeControllers(scope);
    try scope.makeDir("main");
    try scope.makeDir("workers");
    var workers = try scope.openDir("workers", .{ .no_follow = true });
    defer workers.close();
    try validateScopeDirectory(workers);
    try enableScopeControllers(workers);
}

fn enableScopeControllers(directory: std.fs.Dir) !void {
    for (controllers) |controller| {
        var buffer: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "+{s}", .{controller}) catch unreachable;
        try writeScopeControl(directory, "cgroup.subtree_control", text);
    }
}

fn writeScopeControl(directory: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    const fd = try std.posix.openat(directory.fd, name, .{
        .ACCMODE = .WRONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0);
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    try file.writeAll(bytes);
}

/// Fails with `error.ScopePopulated` while the cgroup or any descendant holds a
/// process, since `populated` in cgroup.events counts descendants, and with
/// `error.InvalidCgroupEvents` when the file has no populated line. A process
/// can still join after the check, so callers serialize teardown against
/// launches.
fn requireScopeEmpty(directory: std.fs.Dir) !void {
    var buffer: [256]u8 = undefined;
    const events = try directory.readFile("cgroup.events", &buffer);
    var lines = std.mem.tokenizeScalar(u8, events, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "populated 0")) return;
        if (std.mem.eql(u8, line, "populated 1")) return error.ScopePopulated;
    }
    return error.InvalidCgroupEvents;
}

fn removeScopeTree(
    parent: std.fs.Dir,
    name: []const u8,
    depth: u8,
    remaining: *u32,
) anyerror!void {
    if (depth >= scope_depth_limit) return error.ScopeTooDeep;
    var directory = try parent.openDir(name, .{ .iterate = true, .no_follow = true });
    defer directory.close();
    try validateScopeDirectory(directory);
    try requireScopeEmpty(directory);
    var entries = directory.iterate();
    while (try entries.next()) |entry| {
        if (remaining.* == 0) return error.ScopeTooLarge;
        remaining.* -= 1;
        switch (entry.kind) {
            .directory => try removeScopeTree(directory, entry.name, depth + 1, remaining),
            .file => {},
            else => return error.InvalidCgroupDirectory,
        }
    }
    try requireScopeEmpty(directory);
    // rmdir fails with EBUSY on a cgroup that a process joined after the
    // checks, so a racing launch makes the removal fail and keeps its cgroup.
    // Removal never kills or unlinks control files: a scope still in use is
    // the caller's error to resolve, and `scope-kill` is the explicit way to
    // empty one.
    try parent.deleteDir(name);
}

/// The dev root is created with a single mkdir, so its parent must already
/// exist. A controller the kernel does not offer is skipped, and the `check`
/// that follows reports the dev root unusable.
fn prepare(paths: Paths) !void {
    try ensureDirectory(paths.dev_root);
    try ensureDirectory(paths.runner_root);
    try enableControllers(cgroup_mount);
    try enableControllers(paths.dev_root);
    // Enabling a controller creates its files as the writer, so delegation
    // comes last to also hand over the controller files root just created.
    try delegateIfRoot(paths.dev_root);
    try delegateIfRoot(paths.runner_root);
}

/// A prepared dev root can lose its empty runner leaf between uses, so `run`
/// recreates it. That needs no root under the delegated dev root, and as root
/// the leaf is given back to the sudo caller. Any failure is left for
/// `enterRunner` to report.
fn healRunnerLeaf(paths: Paths) void {
    std.posix.mkdir(paths.runner_root, 0o755) catch return;
    delegateIfRoot(paths.runner_root) catch {};
}

fn enterRunner(paths: Paths) !void {
    if (currentProcessInRunner(paths.runner_relative))
        return;
    const pid = std.os.linux.getpid();
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{pid}) catch unreachable;
    writeCgroupControl(paths.runner_root, "cgroup.procs", text) catch |err| switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        => {
            // cgroup v2 moves a process only for a writer with write access to
            // the cgroup.procs of the common ancestor of the source and
            // destination cgroups. From outside the delegated subtree that
            // ancestor is root-owned, so the first move needs root however
            // the subtree itself is owned.
            std.debug.print(
                "cannot enter {s}: {s}; entering from outside the collo-dev subtree needs root for the first hop.\n" ++
                    "rerun as `sudo --preserve-env=PATH ./zig-out/bin/wsl-config run -- <cmd>` (the command still runs as your user),\n" ++
                    "or `sudo ./zig-out/bin/wsl-config prepare` if the subtree was never provisioned.\n",
                .{ paths.runner_root, @errorName(err) },
            );
            return err;
        },
        error.FileNotFound => {
            std.debug.print(
                "cannot enter {s}: {s}; run `sudo ./zig-out/bin/wsl-config prepare` first.\n",
                .{ paths.runner_root, @errorName(err) },
            );
            return err;
        },
        else => return err,
    };
}

/// Drops root to the sudo caller's uid and gid, with that gid as the only
/// supplementary group. Under `sudo wsl-config run`, root is needed only to
/// enter the runner; the command must run as the caller, since a root
/// `zig build` leaves a root-owned cache behind. Returns the caller's home
/// directory from the password database, because sudo resets HOME to /root
/// and user caches downstream would land there. Returns null when nothing is
/// dropped, because the process is not root or the caller is root too, and
/// when the database has no entry for the caller.
fn dropSudoPrivileges() !?[*:0]const u8 {
    if (std.posix.getuid() != 0) return null;
    const uid = targetUid();
    const gid = targetGid();
    if (uid == 0) return null; // genuinely root, nothing to drop to
    const home: ?[*:0]const u8 = if (getpwuid(uid)) |entry| entry.pw_dir else null;
    const groups = [1]std.posix.gid_t{gid};
    switch (std.posix.errno(std.os.linux.setgroups(groups.len, &groups))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    try std.posix.setgid(gid);
    try std.posix.setuid(uid);
    return home;
}

const Passwd = extern struct {
    pw_name: ?[*:0]u8,
    pw_passwd: ?[*:0]u8,
    pw_uid: std.c.uid_t,
    pw_gid: std.c.gid_t,
    pw_gecos: ?[*:0]u8,
    pw_dir: ?[*:0]u8,
    pw_shell: ?[*:0]u8,
};

extern "c" fn getpwuid(uid: std.c.uid_t) ?*Passwd;

fn execWithWorkerCgroupEnv(
    allocator: std.mem.Allocator,
    paths: Paths,
    home_override: ?[*:0]const u8,
    command: []const [:0]u8,
) !void {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put(worker_root_env, paths.dev_root);
    if (home_override) |home|
        try env.put("HOME", std.mem.sliceTo(home, 0));
    return std.process.execve(allocator, command, &env);
}

fn ensureDirectory(path: []const u8) !void {
    std.posix.mkdir(path, 0o755) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.AccessDenied,
        error.PermissionDenied,
        => {
            std.debug.print(
                "cannot create {s}: {s}; rerun prepare under sudo.\n",
                .{ path, @errorName(err) },
            );
            return err;
        },
        else => return err,
    };
}

/// Files the kernel requires a delegatee to own when it cannot read
/// `delegate_list_path`, which kernels since 4.15 provide.
const delegate_files_fallback = [_][]const u8{
    "cgroup.procs",
    "cgroup.threads",
    "cgroup.subtree_control",
};
const delegate_list_path = "/sys/kernel/cgroup/delegate";

/// Delegates a cgroup to the sudo caller the way cgroup v2 defines it: the
/// directory and every file the kernel lists in `delegate_list_path`. Owning
/// the directory alone lets the caller create children but not move processes
/// into it or enable controllers below it, because a root-created cgroup's
/// control files stay root-owned. The kernel gives a cgroup and its files to
/// the process that creates them, so cgroups the caller creates below are
/// already its own and only the cgroups root creates need this.
fn delegateIfRoot(directory: []const u8) !void {
    if (std.posix.getuid() != 0) {
        return;
    }
    const uid = targetUid();
    const gid = targetGid();
    try chownPath(directory, uid, gid);

    var list_buffer: [1024]u8 = undefined;
    const listed = readDelegateList(&list_buffer);
    var names = std.mem.tokenizeAny(u8, listed orelse "", " \n\t");
    var any_listed = false;
    while (names.next()) |name| {
        any_listed = true;
        try chownCgroupFile(directory, name, uid, gid);
    }
    if (any_listed) return;
    for (delegate_files_fallback) |name|
        try chownCgroupFile(directory, name, uid, gid);
}

fn readDelegateList(buffer: []u8) ?[]const u8 {
    var file = std.fs.openFileAbsolute(delegate_list_path, .{}) catch return null;
    defer file.close();
    const len = file.readAll(buffer) catch return null;
    return buffer[0..len];
}

/// A listed file absent from this cgroup belongs to a controller its parent
/// does not enable, such as `memory.reclaim` on a kernel without the memory
/// controller, so it is skipped.
fn chownCgroupFile(
    directory: []const u8,
    file_name: []const u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
) !void {
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, file_name }) catch
        return error.NameTooLong;
    chownPath(path, uid, gid) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

extern "c" fn chown(path: [*:0]const u8, owner: std.c.uid_t, group: std.c.gid_t) c_int;

fn chownPath(path: []const u8, uid: std.posix.uid_t, gid: std.posix.gid_t) !void {
    if (path.len >= std.fs.max_path_bytes)
        return error.NameTooLong;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;

    while (true) {
        const result = chown(
            @ptrCast(path_buffer[0..path.len :0].ptr),
            @intCast(uid),
            @intCast(gid),
        );
        switch (std.posix.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .NOENT => return error.FileNotFound,
            .NAMETOOLONG => return error.NameTooLong,
            .NOTDIR => return error.NotDir,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn enableControllers(root: []const u8) !void {
    if (!fileExists(root, "cgroup.controllers")) {
        return;
    }
    if (!fileExists(root, "cgroup.subtree_control")) {
        return;
    }
    for (controllers) |controller| {
        if (!controllerAvailable(root, controller)) {
            continue;
        }
        if (controllerEnabled(root, controller)) {
            continue;
        }
        var buffer: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "+{s}", .{controller}) catch unreachable;
        writeCgroupControl(root, "cgroup.subtree_control", text) catch |err| switch (err) {
            error.AccessDenied,
            error.PermissionDenied,
            => {
                std.debug.print(
                    "cannot enable {s} under {s}: {s}; rerun prepare under sudo.\n",
                    .{ controller, root, @errorName(err) },
                );
                return err;
            },
            else => return err,
        };
    }
}

fn cgroupRootUsable(dev_root: []const u8) bool {
    if (!fileExists(dev_root, "cgroup.procs")) {
        return false;
    }
    if (!fileExists(dev_root, "cgroup.subtree_control")) {
        return false;
    }
    for (controllers) |controller| {
        if (!controllerEnabled(dev_root, controller)) {
            return false;
        }
    }
    return true;
}

/// Matches the cgroup2 line "0::<runner_relative>" exactly, so a sibling such
/// as runner2 never counts as the runner.
fn currentProcessInRunner(runner_relative: []const u8) bool {
    var file = std.fs.openFileAbsolute("/proc/self/cgroup", .{}) catch return false;
    defer file.close();
    var buffer: [4096]u8 = undefined;
    const len = file.readAll(&buffer) catch return false;
    var lines = std.mem.tokenizeScalar(u8, buffer[0..len], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::"))
            continue;
        return std.mem.eql(u8, line["0::".len..], runner_relative);
    }
    return false;
}

fn controllerAvailable(root: []const u8, controller: []const u8) bool {
    return controllerListed(root, "cgroup.controllers", controller);
}

fn controllerEnabled(root: []const u8, controller: []const u8) bool {
    return controllerListed(root, "cgroup.subtree_control", controller);
}

fn controllerListed(root: []const u8, file_name: []const u8, controller: []const u8) bool {
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, file_name }) catch return false;
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    var buffer: [4096]u8 = undefined;
    const len = file.readAll(&buffer) catch return false;
    var fields = std.mem.tokenizeAny(u8, buffer[0..len], " \n\t");
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field, controller)) {
            return true;
        }
    }
    return false;
}

fn fileExists(root: []const u8, file_name: []const u8) bool {
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, file_name }) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn writeCgroupControl(root: []const u8, file_name: []const u8, bytes: []const u8) !void {
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, file_name }) catch
        return error.NameTooLong;
    try writeTextFile(path, bytes);
}

fn writeTextFile(path: []const u8, bytes: []const u8) !void {
    const fd = try std.posix.open(path, .{
        .ACCMODE = .WRONLY,
        .CLOEXEC = true,
    }, 0);
    defer std.posix.close(fd);
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = try std.posix.write(fd, remaining);
        remaining = remaining[written..];
    }
}

fn targetUid() std.posix.uid_t {
    if (std.posix.getenv("SUDO_UID")) |value| {
        return std.fmt.parseInt(std.posix.uid_t, value, 10) catch std.posix.getuid();
    }
    return std.posix.getuid();
}

fn targetGid() std.posix.gid_t {
    if (std.posix.getenv("SUDO_GID")) |value| {
        return std.fmt.parseInt(std.posix.gid_t, value, 10) catch std.os.linux.getgid();
    }
    return std.os.linux.getgid();
}
