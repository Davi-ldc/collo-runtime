//! The host's tmpfs mount point (`host/tmp_mount.zig`) under a plain temp
//! directory standing in for /tmp: the claim's name, mode and owner, which
//! the child's check accepts, its removal at `deinit`, and the boot sweep
//! that removes the mount points of hosts that are provably gone and keeps
//! a live host's. The mounts themselves, two workers over one mount point,
//! are covered by the `zygote-integration` lane.

const std = @import("std");
const host = @import("collo_host");
const os = @import("collo_os");
const zygote = @import("collo_zygote");

const TmpMountPoint = host.TmpMountPoint;

fn dirExists(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

test "a mount point is named after this process, passes the child's check and goes at deinit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(parent);

    var mount_point: TmpMountPoint = undefined;
    try mount_point.init(parent);
    var released = false;
    defer if (!released) mount_point.deinit();
    var name_buffer: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}", .{mount_point.dirName()});
    const owner = host.host_identity.parseName("collo-mounts-", name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(std.os.linux.getpid())), owner.pid);
    try std.testing.expectEqual(try os.process.selfStartTicks(), owner.start_ticks);
    try zygote.worker_boot.sandbox.tmp_root.validateFd(mount_point.fd());
    try std.testing.expect(dirExists(tmp.dir, name));

    mount_point.deinit();
    released = true;
    try std.testing.expect(!dirExists(tmp.dir, name));
}

test "two mount points of one process coexist under one parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(parent);

    var first: TmpMountPoint = undefined;
    try first.init(parent);
    defer first.deinit();
    var second: TmpMountPoint = undefined;
    try second.init(parent);
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, first.dirName(), second.dirName()));
}

test "the boot sweep removes the mount point of a host whose pid is gone and keeps a live host's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(parent);

    const self_pid: u32 = @intCast(std.os.linux.getpid());
    const self_start = try os.process.selfStartTicks();
    var live_buffer: [96]u8 = undefined;
    const live = try std.fmt.bufPrint(&live_buffer, "collo-mounts-{d}-{d}-9", .{ self_pid, self_start });
    var reused_pid_buffer: [96]u8 = undefined;
    const reused_pid = try std.fmt.bufPrint(&reused_pid_buffer, "collo-mounts-{d}-{d}-1", .{
        self_pid,
        self_start + 1,
    });
    // pid_max never exceeds 2^22, so this owner cannot be running.
    const absent_pid = "collo-mounts-4294967295-1-1";
    const absent_pid_written = "collo-mounts-4294967295-1-2";
    try tmp.dir.makeDir(live);
    try tmp.dir.makeDir(reused_pid);
    try tmp.dir.makeDir(absent_pid);
    // A dead host's mount point that someone wrote into is left with a
    // warning: the host never writes there, so it removes nothing but an
    // empty directory.
    try tmp.dir.makePath(absent_pid_written ++ "/stray");
    try tmp.dir.makeDir("collo-mounts-garbage");

    var mount_point: TmpMountPoint = undefined;
    try mount_point.init(parent);
    defer mount_point.deinit();

    try std.testing.expect(!dirExists(tmp.dir, absent_pid));
    try std.testing.expect(!dirExists(tmp.dir, reused_pid));
    try std.testing.expect(dirExists(tmp.dir, absent_pid_written));
    try std.testing.expect(dirExists(tmp.dir, live));
    try std.testing.expect(dirExists(tmp.dir, "collo-mounts-garbage"));
    try std.testing.expect(dirExists(tmp.dir, mount_point.dirName()));
}
