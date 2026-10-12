//! `wsl-config prepare` against a temporary directory shaped like a cgroup2
//! root, with plain files standing in for the control files: it fails,
//! naming the controller, when the root does not offer cpu, memory or pids or
//! the dev root does not list one as enabled after the writes, and it accepts
//! a root already provisioned. A real delegated subtree is exercised by every
//! kernel lane that runs under `wsl-config run`. Lane `wsl-config-test`.

const std = @import("std");
const wsl_config = @import("collo_wsl_config");

const every_controller = "cpu memory pids\n";

test "prepare fails naming memory when the cgroup root does not offer it, before creating anything" {
    var fixture = try Fixture.init(.{ .root_available = "cpu io pids\n", .root_enabled = "" });
    defer fixture.deinit();

    const missing = try wsl_config.firstMissingController(fixture.tmp.dir, .available);
    try std.testing.expectEqualStrings("memory", missing.?);
    try std.testing.expectError(error.CgroupControllerUnavailable, wsl_config.prepare(fixture.paths));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.access("collo-dev", .{}));
}

test "prepare fails naming the controller when the dev root takes the writes but enables nothing" {
    // A plain file takes each "+controller" write without enabling anything,
    // as a directory outside cgroupfs would.
    var fixture = try Fixture.init(.{
        .root_available = every_controller,
        .root_enabled = every_controller,
        .dev_root = .{ .available = every_controller, .enabled = "" },
    });
    defer fixture.deinit();

    try std.testing.expectError(error.CgroupControllerNotEnabled, wsl_config.prepare(fixture.paths));
    var dev_root = try fixture.tmp.dir.openDir("collo-dev", .{});
    defer dev_root.close();
    const missing = try wsl_config.firstMissingController(dev_root, .enabled);
    try std.testing.expectEqualStrings("cpu", missing.?);
}

test "prepare accepts a cgroup root that is already provisioned" {
    var fixture = try Fixture.init(.{
        .root_available = every_controller,
        .root_enabled = every_controller,
        .dev_root = .{ .available = every_controller, .enabled = every_controller },
    });
    defer fixture.deinit();

    try wsl_config.prepare(fixture.paths);
    try fixture.tmp.dir.access("collo-dev/runner", .{});
}

test "the runner cgroup must lie two levels below the mount, so the dev root is never the mount" {
    const mount = "/sys/fs/cgroup";
    const paths = try wsl_config.Paths.init(mount, mount ++ "/collo-dev/runner");
    try std.testing.expectEqualStrings(mount ++ "/collo-dev", paths.dev_root);
    try std.testing.expectEqualStrings("/collo-dev/runner", paths.runner_relative);

    const refused = [_][]const u8{
        mount ++ "/runner",
        mount ++ "/collo-dev/..",
        mount ++ "/collo-dev/./runner",
        mount ++ "//runner",
        mount ++ "-dev/collo-dev/runner",
        "/sys/fs/collo-dev/runner",
    };
    for (refused) |runner_root| {
        errdefer std.debug.print("runner cgroup '{s}' was accepted\n", .{runner_root});
        try std.testing.expectError(error.InvalidRunnerCgroup, wsl_config.Paths.init(mount, runner_root));
    }
}

/// The control lists of the temporary cgroup2 root and, when present, of a
/// dev root that already exists.
const Layout = struct {
    root_available: []const u8,
    root_enabled: []const u8,
    dev_root: ?Lists = null,

    const Lists = struct {
        available: []const u8,
        enabled: []const u8,
    };
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    mount: []u8,
    runner_root: []u8,
    paths: wsl_config.Paths,

    fn init(layout: Layout) !Fixture {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try writeControlLists(tmp.dir, layout.root_available, layout.root_enabled);
        if (layout.dev_root) |lists| {
            try tmp.dir.makeDir("collo-dev");
            var dev_root = try tmp.dir.openDir("collo-dev", .{});
            defer dev_root.close();
            try writeControlLists(dev_root, lists.available, lists.enabled);
        }
        const mount = try tmp.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(mount);
        const runner_root = try std.fs.path.join(allocator, &.{ mount, "collo-dev", "runner" });
        errdefer allocator.free(runner_root);
        return .{
            .tmp = tmp,
            .mount = mount,
            .runner_root = runner_root,
            .paths = try wsl_config.Paths.init(mount, runner_root),
        };
    }

    fn deinit(fixture: *Fixture) void {
        std.testing.allocator.free(fixture.runner_root);
        std.testing.allocator.free(fixture.mount);
        fixture.tmp.cleanup();
    }
};

fn writeControlLists(directory: std.fs.Dir, available: []const u8, enabled: []const u8) !void {
    try directory.writeFile(.{ .sub_path = "cgroup.controllers", .data = available });
    try directory.writeFile(.{ .sub_path = "cgroup.subtree_control", .data = enabled });
}
