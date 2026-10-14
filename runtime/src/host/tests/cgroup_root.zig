//! Worker cgroup subtree directory management, exercised against a plain
//! temp directory standing in for the delegated env root: the host claims
//! its `host-<pid>-<start>-<n>` directory under it and keeps its
//! `worker-<id>` leaves inside, each named by the root and its job id
//! (`WorkerLeaf`), whose files open only beneath the host directory with no
//! link followed. The limit-file writes, controller enabling, the kill
//! through `cgroup.kill` and the real boot path need a cgroup2 mount and are
//! covered by the integration lane.

const std = @import("std");
const host = @import("collo_host");
const os = @import("collo_os");

const WorkerCgroupRoot = host.cgroup_root.WorkerCgroupRoot;

/// Claims a host directory under the temp dir exactly as an env-root boot
/// does, minus cgroupfs.
fn rootOverTempDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !WorkerCgroupRoot {
    return WorkerCgroupRoot.claimHostDir(allocator, tmp.dir.fd);
}

fn dirExists(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

fn leafExists(root: *const WorkerCgroupRoot, name: []const u8) bool {
    return dirExists(.{ .fd = root.workers_dir_fd }, name);
}

fn makeLeaf(root: *const WorkerCgroupRoot, name: []const u8) !void {
    const dir = std.fs.Dir{ .fd = root.workers_dir_fd };
    try dir.makeDir(name);
}

fn hostDirBasename(root: *const WorkerCgroupRoot) []const u8 {
    return std.fs.path.basename(root.workers_dir_path);
}

test "claimHostDir names the directory after this process and deinit removes it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root = try rootOverTempDir(std.testing.allocator, &tmp);
    var root_alive = true;
    defer if (root_alive) root.deinit(std.testing.allocator);

    // The name carries the identity the sweep checks: this pid and its
    // start time, then the number that tells this process's roots apart.
    var expected_buffer: [64]u8 = undefined;
    const expected_prefix = try std.fmt.bufPrint(&expected_buffer, "host-{d}-{d}-", .{
        @as(u32, @intCast(std.os.linux.getpid())),
        try os.process.selfStartTicks(),
    });
    const name = hostDirBasename(&root);
    try std.testing.expect(std.mem.startsWith(u8, name, expected_prefix));
    try std.testing.expect(dirExists(tmp.dir, name));

    // A leaf the host never removed goes with the directory: nobody else
    // could ever attribute it.
    try makeLeaf(&root, "worker-4");
    const name_copy = try std.testing.allocator.dupe(u8, name);
    defer std.testing.allocator.free(name_copy);
    root_alive = false;
    root.deinit(std.testing.allocator);
    try std.testing.expect(!dirExists(tmp.dir, name_copy));
}

test "two roots of one process coexist under one parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_a = try rootOverTempDir(std.testing.allocator, &tmp);
    defer root_a.deinit(std.testing.allocator);
    try makeLeaf(&root_a, "worker-1");

    // Claiming the second root sweeps the parent; the first root's owner is
    // alive, so its leaf survives, and the second gets a name of its own.
    var root_b = try rootOverTempDir(std.testing.allocator, &tmp);
    var root_b_alive = true;
    defer if (root_b_alive) root_b.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, root_a.workers_dir_path, root_b.workers_dir_path));
    try std.testing.expect(leafExists(&root_a, "worker-1"));

    root_b_alive = false;
    root_b.deinit(std.testing.allocator);
    try std.testing.expect(leafExists(&root_a, "worker-1"));
}

test "sweepDeadHostDirs reclaims dead hosts and leaves everything else" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const self_pid: u32 = @intCast(std.os.linux.getpid());
    const self_start = try os.process.selfStartTicks();
    var live_buffer: [64]u8 = undefined;
    const live = try std.fmt.bufPrint(&live_buffer, "host-{d}-{d}-5", .{ self_pid, self_start });
    var reused_pid_buffer: [64]u8 = undefined;
    const reused_pid = try std.fmt.bufPrint(&reused_pid_buffer, "host-{d}-{d}-0", .{
        self_pid,
        self_start + 1,
    });
    var no_sequence_buffer: [64]u8 = undefined;
    const no_sequence = try std.fmt.bufPrint(&no_sequence_buffer, "host-{d}-{d}", .{
        self_pid,
        self_start,
    });
    // pid_max never exceeds 2^22, so this owner cannot be running.
    const absent_pid = "host-4294967295-1-0";

    try tmp.dir.makePath(absent_pid ++ "/worker-7");
    var live_leaf_buffer: [80]u8 = undefined;
    try tmp.dir.makePath(try std.fmt.bufPrint(&live_leaf_buffer, "{s}/worker-3", .{live}));
    try tmp.dir.makeDir(reused_pid);
    try tmp.dir.makeDir(no_sequence);
    try tmp.dir.makeDir("host-garbage");
    try tmp.dir.makeDir("worker-9");
    try tmp.dir.writeFile(.{ .sub_path = "host-1-1-1", .data = "x" });

    host.cgroup_root.sweepDeadHostDirs(tmp.dir.fd);

    // Gone: an owner with no process, and a name whose start time belongs
    // to an earlier incarnation of a pid that is now ours.
    try std.testing.expect(!dirExists(tmp.dir, absent_pid));
    try std.testing.expect(!dirExists(tmp.dir, reused_pid));
    // Kept: a live owner with its leaf, names the host cannot attribute, an
    // ownerless leaf and a non-directory entry.
    try std.testing.expect(dirExists(tmp.dir, live));
    var live_leaf_check_buffer: [80]u8 = undefined;
    try std.testing.expect(dirExists(
        tmp.dir,
        try std.fmt.bufPrint(&live_leaf_check_buffer, "{s}/worker-3", .{live}),
    ));
    try std.testing.expect(dirExists(tmp.dir, no_sequence));
    try std.testing.expect(dirExists(tmp.dir, "host-garbage"));
    try std.testing.expect(dirExists(tmp.dir, "worker-9"));
    try std.testing.expect(dirExists(tmp.dir, "host-1-1-1"));
}

test "a leaf named by its job id is removed by that name, and removing it again is no error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root = try rootOverTempDir(std.testing.allocator, &tmp);
    defer root.deinit(std.testing.allocator);
    try makeLeaf(&root, "worker-7");
    try makeLeaf(&root, "worker-8");

    const leaf = root.leaf(7);
    var name_buffer: [host.WorkerLeaf.name_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("worker-7", leaf.name(&name_buffer));
    try std.testing.expect(leafExists(&root, "worker-7"));
    leaf.remove();
    try std.testing.expect(!leafExists(&root, "worker-7"));
    // Its neighbour keeps its own name.
    try std.testing.expect(leafExists(&root, "worker-8"));

    leaf.remove();
}

test "a leaf's files are read by name without a path or an allocation, and fail once the leaf is gone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root = try rootOverTempDir(std.testing.allocator, &tmp);
    defer root.deinit(std.testing.allocator);
    try makeLeaf(&root, "worker-12");
    const host_dir = std.fs.Dir{ .fd = root.workers_dir_fd };
    try host_dir.writeFile(.{ .sub_path = "worker-12/memory.current", .data = "4096\n" });

    const leaf = root.leaf(12);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("4096\n", try leaf.readFile("memory.current", &buffer));
    // One read fills a cgroup file's whole contents, so a buffer it fills
    // cannot tell a longer file from this one.
    var short: [5]u8 = undefined;
    try std.testing.expectError(error.CgroupFileTooLarge, leaf.readFile("memory.current", &short));

    try host_dir.deleteFile("worker-12/memory.current");
    leaf.remove();
    try std.testing.expectError(error.FileNotFound, leaf.openFile("memory.current"));
}

test "a leaf's files open only beneath the workers directory: a leaf name that is a link is neither read nor killed through, and a path that climbs out is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root = try rootOverTempDir(std.testing.allocator, &tmp);
    defer root.deinit(std.testing.allocator);
    // A directory beside the host directory, standing in for a cgroup the
    // host must never touch, such as its own.
    try tmp.dir.makeDir("elsewhere");
    try tmp.dir.writeFile(.{ .sub_path = "elsewhere/memory.current", .data = "4096\n" });
    try tmp.dir.writeFile(.{ .sub_path = "elsewhere/cgroup.kill", .data = "" });
    try std.posix.symlinkat("../elsewhere", root.workers_dir_fd, "worker-6");

    const linked = root.leaf(6);
    try std.testing.expectError(error.SymLinkLoop, linked.openFile("memory.current"));
    // The kill finds no leaf to write through, and the rmdir of the link
    // fails and is logged.
    linked.remove();
    var kill_buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", try tmp.dir.readFile("elsewhere/cgroup.kill", &kill_buffer));

    try makeLeaf(&root, "worker-7");
    try std.testing.expectError(error.PathEscapesDirectory, root.leaf(7).openFile("../../elsewhere/memory.current"));

    // The root's teardown removes only directories, so the link goes here.
    try std.posix.unlinkat(root.workers_dir_fd, "worker-6", 0);
}

test "removeWorkerDirsUnder removes every worker leaf and leaves other entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root = try rootOverTempDir(std.testing.allocator, &tmp);
    defer root.deinit(std.testing.allocator);
    try makeLeaf(&root, "worker-1");
    try makeLeaf(&root, "worker-42");
    try makeLeaf(&root, "keep-me");
    const host_dir = std.fs.Dir{ .fd = root.workers_dir_fd };
    try host_dir.writeFile(.{ .sub_path = "worker-not-a-dir", .data = "x" });

    host.cgroup_root.removeWorkerDirsUnder(root.workers_dir_fd);

    try std.testing.expect(!leafExists(&root, "worker-1"));
    try std.testing.expect(!leafExists(&root, "worker-42"));
    try std.testing.expect(leafExists(&root, "keep-me"));
    // A non-directory entry sharing the prefix is left untouched.
    try std.testing.expect(leafExists(&root, "worker-not-a-dir"));

    // deinit only removes leaves, so the foreign entries block the rmdir of
    // the host directory; clear them here rather than wait out the retry.
    try host_dir.deleteDir("keep-me");
    try host_dir.deleteFile("worker-not-a-dir");
}

test "createWorkerDir fails cleanly when limit files are absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root = try rootOverTempDir(std.testing.allocator, &tmp);
    defer root.deinit(std.testing.allocator);

    // A plain temp dir has no memory.high/cpu.max/etc., so configuring limits
    // fails; the errdefer must remove the half-created directory.
    try std.testing.expectError(
        error.FileNotFound,
        root.createWorkerDir(5, .{ .memory_limit_bytes = 1024 }),
    );
    try std.testing.expect(!leafExists(&root, "worker-5"));
}

test "createWorkerDir rejects a zero memory limit before touching the filesystem" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root = try rootOverTempDir(std.testing.allocator, &tmp);
    defer root.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.ZeroMemoryLimit,
        root.createWorkerDir(9, .{ .memory_limit_bytes = 0 }),
    );
    try std.testing.expect(!leafExists(&root, "worker-9"));
}
