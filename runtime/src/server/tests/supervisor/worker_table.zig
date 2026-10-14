//! What a worker record reads off its worker
//! (`server/supervisor/worker_table.zig`): how a death classifies from the
//! termination reason on the worker's page and the memory events of its
//! cgroup leaf, and the figures the server reads off a leaf
//! (`cgroup.readLeafFigure` in `common/cgroup.zig`), each through a real
//! `host.cgroup_root.WorkerLeaf` over files the test writes
//! (`supervisor_fixture.LeafDir`): every figure parsed, and a missing file
//! and one that fills its read refused. The usage floor is covered in
//! `usage.zig`, and the death of a worker on a real delegated cgroup in the
//! `local-e2e` lane (`runtime/tests/integration/local_server/limits.zig`).
//! Lane `server-supervisor-test`.

const std = @import("std");
const cgroup = @import("collo_cgroup");
const host = @import("collo_host");
const page = @import("collo_worker_state").page;
const supervision = @import("collo_server_supervisor");
const fixture = @import("supervisor_fixture");

const worker_table = supervision.worker_table;
const Death = worker_table.Death;
const ErrorCode = @import("collo_server_analytics").access.ErrorCode;
const File = fixture.LeafDir.File;

/// A worker record outside any pool whose cgroup leaf holds the files a test
/// writes, its page stamped `crash` as a launch leaves it, and the worker's
/// own mapping of that page, through which the test writes what a worker
/// would.
const LeafWorker = struct {
    leaves: fixture.LeafDir,
    leaf: host.cgroup_root.WorkerLeaf,
    record: *worker_table.Record,
    page: fixture.WorkerPage,

    fn init(target: *LeafWorker, files: []const File) !void {
        target.leaves = fixture.LeafDir.init();
        errdefer target.leaves.deinit();
        target.leaf = try target.leaves.leaf(files);
        target.record = try fixture.newWorker(std.testing.allocator, .{ .leaf = target.leaf });
        errdefer {
            target.leaves.emptyLeaf(target.leaf) catch |err|
                std.log.err("worker table test could not empty its fixture leaf: {s}", .{@errorName(err)});
            fixture.destroyWorker(std.testing.allocator, target.record);
        }
        target.page = try fixture.WorkerPage.attach(target.record);
    }

    /// Empties the leaf, so that the record's teardown removes it with one
    /// rmdir, then takes the record apart, the worker's mapping and the
    /// directory.
    fn deinit(self: *LeafWorker) void {
        self.leaves.emptyLeaf(self.leaf) catch |err|
            std.log.err("worker table test could not empty its fixture leaf: {s}", .{@errorName(err)});
        fixture.destroyWorker(std.testing.allocator, self.record);
        self.page.deinit();
        self.leaves.deinit();
    }
};

/// The memory events of a leaf in which the kernel's OOM killer ended the
/// worker: with `memory.oom.group` set it counts every task the kill took.
const oom_killed_events: File = .{
    .name = "memory.events.local",
    .data = "low 0\nhigh 3\nmax 9\noom 1\noom_kill 2\noom_group_kill 1\n",
};

test "a worker's death is memory_max when the kernel counted an oom_kill in its leaf, and a crash when the leaf counted no memory event" {
    var scene: LeafWorker = undefined;
    try scene.init(&.{fixture.LeafDir.quiet_memory_events});
    defer scene.deinit();

    // The page still says what the launch stamped, so the leaf decides.
    try std.testing.expectEqual(Death.crash, scene.record.classifyDeath());
    try scene.leaves.writeFile(scene.leaf, oom_killed_events);
    try std.testing.expectEqual(Death.memory_max, scene.record.classifyDeath());
}

test "the sentinel's memory stamp on a worker's page makes its death memory_high, whatever the leaf counts or the state beside the stamp" {
    var scene: LeafWorker = undefined;
    try scene.init(&.{oom_killed_events});
    defer scene.deinit();
    const header = scene.page.writer.header;

    @atomicStore(u32, &header.state, 77, .release);
    @atomicStore(u32, &header.termination_reason, @intFromEnum(page.TerminationReason.memory), .release);
    try std.testing.expectEqual(Death.memory_high, scene.record.classifyDeath());

    // A reason `TerminationReason` does not name says nothing, and the leaf
    // decides as it does for a crash.
    @atomicStore(u32, &header.termination_reason, 99, .release);
    try std.testing.expectEqual(Death.memory_max, scene.record.classifyDeath());
    try scene.leaves.writeFile(scene.leaf, fixture.LeafDir.quiet_memory_events);
    try std.testing.expectEqual(Death.crash, scene.record.classifyDeath());
}

test "a leaf that cannot say leaves a death a crash: its memory events missing, or past the room one read of them has" {
    var scene: LeafWorker = undefined;
    try scene.init(&.{});
    defer scene.deinit();

    try std.testing.expectError(error.FileNotFound, cgroup.readLeafFigure(scene.leaf, .memory_events));
    try std.testing.expectEqual(Death.crash, scene.record.classifyDeath());

    // Padding a real file could never hold, so the one read fills its buffer
    // and the count past it, an `oom_kill`, is never parsed truncated.
    const oversized = "low 0" ++ (" " ** cgroup.memory.events_bytes_max) ++ "\noom_kill 1\n";
    try scene.leaves.writeFile(scene.leaf, .{ .name = "memory.events.local", .data = oversized });
    try std.testing.expectError(error.CgroupFileTooLarge, cgroup.readLeafFigure(scene.leaf, .memory_events));
    try std.testing.expectEqual(Death.crash, scene.record.classifyDeath());
}

test "every figure the server reads off a worker's leaf parses from its file, and a file that is not the figure's fails" {
    var leaves = fixture.LeafDir.init();
    defer leaves.deinit();
    const leaf = try leaves.leaf(&.{
        oom_killed_events,
        .{ .name = "memory.current", .data = "4096\n" },
        .{ .name = "memory.peak", .data = "8192\n" },
        .{ .name = "cpu.stat", .data = "usage_usec 1500\nuser_usec 1000\nsystem_usec 500\nnr_periods 0\n" },
    });

    const events = try cgroup.readLeafFigure(leaf, .memory_events);
    try std.testing.expectEqual(@as(u64, 2), events.oom_kill);
    try std.testing.expectEqual(@as(u64, 3), events.high);
    try std.testing.expectEqual(@as(u64, 4096), try cgroup.readLeafFigure(leaf, .memory_current));
    try std.testing.expectEqual(@as(u64, 8192), try cgroup.readLeafFigure(leaf, .memory_peak));
    try std.testing.expectEqual(@as(u64, 1500), try cgroup.readLeafFigure(leaf, .cpu_usage_usec));

    try leaves.writeFile(leaf, .{ .name = "memory.peak", .data = "max\n" });
    try std.testing.expectError(error.InvalidCharacter, cgroup.readLeafFigure(leaf, .memory_peak));
    try leaves.writeFile(leaf, .{ .name = "cpu.stat", .data = "user_usec 1000\n" });
    try std.testing.expectError(error.InvalidCpuStatFile, cgroup.readLeafFigure(leaf, .cpu_usage_usec));
}

test "both memory deaths give their requests' records the one error code memory, and the worker's line the ending that names who stopped it" {
    try std.testing.expectEqual(ErrorCode.memory, Death.memory_high.errorCode());
    try std.testing.expectEqual(ErrorCode.memory, Death.memory_max.errorCode());
    try std.testing.expectEqual(ErrorCode.crash, Death.crash.errorCode());
    try std.testing.expectEqualStrings("memory_high", @tagName(Death.memory_high.ending()));
    try std.testing.expectEqualStrings("memory_max", @tagName(Death.memory_max.ending()));
    try std.testing.expectEqualStrings("crash", @tagName(Death.crash.ending()));
}
