//! The reaper's readings in `server/supervisor/reaper/memory.zig`: node
//! memory as the highest share of any limit above the workers and the server,
//! the machine's included, over a fixture tree; what a failed read of node
//! memory stands on; and the PSI trigger on `/proc/pressure/memory`, its
//! bytes checked on a pipe and the trigger armed on the live kernel. The
//! pressure bands and the victim score are covered in `reaping.zig`. Lane
//! `server-supervisor-test`.

const std = @import("std");
const supervision = @import("collo_server_supervisor");

const memory = supervision.reaper.memory;
const memory_limits = supervision.scheduler_limits.memory;

/// A fixture tree shaped like the delegated placement: `<own>` with a limit,
/// `<own>/main` and `<own>/workers` without one, and a machine reading.
const DomainTree = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8,
    root: []const u8,

    fn init(target: *DomainTree, own_current: u64, own_max: u64, machine_total_kb: u64, machine_available_kb: u64) !void {
        target.tmp = std.testing.tmpDir(.{});
        errdefer target.tmp.cleanup();
        const dir = target.tmp.dir;
        try dir.makePath("own/main");
        try dir.makePath("own/workers");
        var number: [32]u8 = undefined;
        try dir.writeFile(.{ .sub_path = "own/memory.current", .data = try std.fmt.bufPrint(&number, "{d}\n", .{own_current}) });
        try dir.writeFile(.{ .sub_path = "own/memory.max", .data = try std.fmt.bufPrint(&number, "{d}\n", .{own_max}) });
        for ([_][]const u8{ "own/main", "own/workers" }) |child| {
            var path_buffer: [64]u8 = undefined;
            try dir.writeFile(.{ .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/memory.current", .{child}), .data = "4096\n" });
            try dir.writeFile(.{ .sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/memory.max", .{child}), .data = "max\n" });
        }
        var meminfo: [128]u8 = undefined;
        try dir.writeFile(.{
            .sub_path = "meminfo",
            .data = try std.fmt.bufPrint(&meminfo, "MemTotal:       {d} kB\nMemFree:        0 kB\nMemAvailable:   {d} kB\n", .{ machine_total_kb, machine_available_kb }),
        });
        target.root = try dir.realpath(".", &target.root_buffer);
    }

    fn deinit(self: *DomainTree) void {
        self.tmp.cleanup();
    }

    fn path(self: *const DomainTree, buffer: []u8, sub_path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.root, sub_path });
    }
};

test "node pressure is the highest share among the limits above the workers and the server, the machine's included" {
    var tree: DomainTree = undefined;
    // `<own>` at 90% of its limit; the machine at 40%.
    try tree.init(900, 1000, 1000, 600);
    defer tree.deinit();
    var workers_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var server_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var meminfo_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const paths = [_][]const u8{
        try tree.path(&workers_buffer, "own/workers"),
        try tree.path(&server_buffer, "own/main"),
    };

    var domains: memory.MemoryDomains = undefined;
    domains.init(.{
        .cgroup_paths = &paths,
        .mount_root = tree.root,
        .meminfo_path = try tree.path(&meminfo_buffer, "meminfo"),
    });
    defer domains.deinit();
    // `<own>/workers`, `<own>` and `<own>/main`, the shared ancestor once.
    try std.testing.expectEqual(@as(usize, 3), domains.len);

    const pressure = try memory.readMemoryPressure(std.testing.allocator, &domains);
    try std.testing.expectEqual(@as(u8, 90), pressure.used_percent);
    try std.testing.expectEqual(memory.MemoryPressureMode.hard, pressure.mode);
}

test "without a limited cgroup node pressure is the machine's, and with nothing readable the read fails" {
    var tree: DomainTree = undefined;
    // `<own>` at 10%, under the machine's 75%.
    try tree.init(100, 1000, 1000, 250);
    defer tree.deinit();
    var workers_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var meminfo_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const paths = [_][]const u8{try tree.path(&workers_buffer, "own/workers")};

    var domains: memory.MemoryDomains = undefined;
    domains.init(.{
        .cgroup_paths = &paths,
        .mount_root = tree.root,
        .meminfo_path = try tree.path(&meminfo_buffer, "meminfo"),
    });
    defer domains.deinit();
    const pressure = try memory.readMemoryPressure(std.testing.allocator, &domains);
    try std.testing.expectEqual(@as(u8, 75), pressure.used_percent);
    try std.testing.expectEqual(memory.MemoryPressureMode.soft, pressure.mode);

    var nothing: memory.MemoryDomains = undefined;
    nothing.init(.{ .cgroup_paths = &.{}, .meminfo_path = "/nonexistent/meminfo" });
    defer nothing.deinit();
    try std.testing.expectError(error.NoMemoryDomainReadable, memory.readMemoryPressure(std.testing.allocator, &nothing));
}

test "a failed read stands on the last reading, 0% included, and on critical before any reading or for want of memory" {
    var last: memory.LastReading = .{};

    // Nothing was read yet, so a failure cannot answer calm.
    try std.testing.expectEqual(memory.MemoryPressureMode.critical, last.settle(error.FileNotFound).mode);

    // A real reading of 0% is remembered like any other, and the next failure
    // acts on it.
    try std.testing.expectEqual(@as(u8, 0), last.settle(memory.memoryPressureFromUsedPercent(0)).used_percent);
    const after_calm = last.settle(error.FileNotFound);
    try std.testing.expectEqual(memory.MemoryPressureMode.none, after_calm.mode);
    try std.testing.expectEqual(@as(u8, 0), after_calm.used_percent);

    // A read that failed for want of memory is critical whatever came before,
    // and that stand-in is no reading: the next failure acts on 0% again.
    try std.testing.expectEqual(memory.MemoryPressureMode.critical, last.settle(error.OutOfMemory).mode);
    try std.testing.expectEqual(@as(u8, 0), last.settle(error.FileNotFound).used_percent);

    // A newer reading replaces the last.
    _ = last.settle(memory.memoryPressureFromUsedPercent(88));
    try std.testing.expectEqual(memory.MemoryPressureMode.hard, last.settle(error.FileNotFound).mode);
}

test "the PSI trigger goes out as the trigger text followed by the NUL the kernel's parser needs" {
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
    defer std.posix.close(pipe[0]);
    {
        defer std.posix.close(pipe[1]);
        try memory.armPsiTrigger(pipe[1]);
    }

    var buffer: [64]u8 = undefined;
    const length = try std.posix.read(pipe[0], &buffer);
    // The kernel overwrites the last byte of the write with its terminator,
    // so that byte must be a NUL of its own and not the window's last digit.
    try std.testing.expectEqualStrings(memory_limits.psi_some_trigger ++ "\x00", buffer[0..length]);
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(pipe[0], &buffer));
}

test "the PSI trigger arms on a kernel that offers PSI to a process without CAP_SYS_RESOURCE" {
    var wake = memory.MemoryPressureWake.init() catch |err| switch (err) {
        // The kernel was built or booted without PSI, so the pressure file does not exist.
        error.FileNotFound => return error.SkipZigTest,
        // Below Linux 6.4 the kernel refuses a trigger to a process without CAP_SYS_RESOURCE.
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer wake.deinit();
    try std.testing.expect(wake.fd >= 0);
}
