//! The scale-out verdict (`server/supervisor/scale_out.zig`): which watched
//! definitions get a worker more from their workers' CPU, their wait for a
//! CPU and the node's idle CPU, with the idle cores shared out among the
//! definitions of one sample; and the sampler that measures those figures,
//! over a fixture tree of cgroup files and a `/proc/stat` of its own: the
//! workers' CPUs narrowed by their cpuset, the room under an ancestor's
//! quota, and figures only against the sample just before. The launcher's
//! watch and the pool's half of a scale-out are covered in `launcher.zig`
//! and `pool.zig`. Lane `server-supervisor-test`.

const std = @import("std");
const host = @import("collo_host");
const supervision = @import("collo_server_supervisor");

const scale_out = supervision.scale_out;
const Candidate = scale_out.Candidate;

fn expectGranted(candidates: []const Candidate, node_idle_permille: u32, start: usize, expected: []const bool) !void {
    var granted: [8]bool = undefined;
    scale_out.decide(candidates, node_idle_permille, start, .{}, granted[0..candidates.len]);
    try std.testing.expectEqualSlices(bool, expected, granted[0..candidates.len]);
}

test "on a CPU-saturated node a definition of CPU-bound workers gets no worker while one of I/O-bound workers grows (#157)" {
    const candidates = [_]Candidate{
        // One worker using most of a core, and waiting for one a third of
        // the time beside the lanes that share it.
        .{ .definition = 0, .figures = .{ .workers = 1, .cpu_permille = 600, .stall_permille = 350 } },
        // The same workers on a node with half a core idle: they do not wait
        // for a CPU, but no idle core is whole.
        .{ .definition = 1, .figures = .{ .workers = 1, .cpu_permille = 950, .stall_permille = 20 } },
        // Workers parked on fetches, using a sliver of a core each.
        .{ .definition = 2, .figures = .{ .workers = 3, .cpu_permille = 40, .stall_permille = 10 } },
    };
    try expectGranted(&candidates, 0, 0, &.{ false, false, true });
    try expectGranted(&candidates, 500, 0, &.{ false, false, true });
}

test "CPU-bound workers grow one worker per whole idle core, and definitions sharing the node never count one core twice" {
    const candidates = [_]Candidate{
        .{ .definition = 3, .figures = .{ .workers = 2, .cpu_permille = 900, .stall_permille = 0 } },
        .{ .definition = 7, .figures = .{ .workers = 1, .cpu_permille = 800, .stall_permille = 0 } },
    };
    try expectGranted(&candidates, 2100, 0, &.{ true, true });
    // One idle core and a half: the first weighed takes it.
    try expectGranted(&candidates, 1500, 0, &.{ true, false });
    // The start that moves each sample lets the other come first.
    try expectGranted(&candidates, 1500, 1, &.{ false, true });
    try expectGranted(&candidates, 999, 0, &.{ false, false });
}

test "workers that wait for a CPU get no company however idle the node is, and a definition with no figure is not weighed" {
    const candidates = [_]Candidate{
        .{ .definition = 0, .figures = .{ .workers = 2, .cpu_permille = 50, .stall_permille = 100 } },
        .{ .definition = 1, .figures = .{ .workers = 2, .cpu_permille = 900, .stall_permille = 150 } },
        .{ .definition = 2, .figures = .{} },
    };
    try expectGranted(&candidates, 8000, 0, &.{ false, false, false });
}

test "/proc/stat idle time sums idle and iowait of the workers' CPUs alone and stops at the first other line or a cut one" {
    var cpus = scale_out.CpuSet.initEmpty();
    cpus.set(1);
    cpus.set(3);
    const contents =
        "cpu  100 0 100 9000 40 0 0 0 0 0\n" ++
        "cpu0 10 0 10 1000 1 0 0 0 0 0\n" ++
        "cpu1 10 0 10 2000 7 0 0 0 0 0\n" ++
        "cpu2 10 0 10 3000 3 0 0 0 0 0\n" ++
        "cpu3 10 0 10 3000 5 0 0 0 0 0\n" ++
        "intr 1 2 3\n" ++
        "cpu4 10 0 10 7777 7 0 0 0 0 0\n";
    try std.testing.expectEqual(@as(u64, 2007 + 3005), try scale_out.parseProcStatIdleTicks(contents, &cpus));
    // A buffer that cut the last CPU line keeps only the whole lines.
    try std.testing.expectEqual(@as(u64, 2007), try scale_out.parseProcStatIdleTicks(contents[0.."cpu  100 0 100 9000 40 0 0 0 0 0\ncpu0 10 0 10 1000 1 0 0 0 0 0\ncpu1 10 0 10 2000 7 0 0 0 0 0\ncpu2 10 0 10 3000 3 0 0 0 0 0\ncpu3 10 0 10".len], &cpus));
    try std.testing.expectError(error.InvalidProcStat, scale_out.parseProcStatIdleTicks("cpu1 10 0 10\n", &cpus));
}

/// A fixture tree: `own` with a quota of 1.2 cores and its `cpu.stat`,
/// `own/workers` with a cpuset of CPUs 1 and 2, one worker leaf there, and a
/// `/proc/stat` of four CPUs.
const Tree = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8,
    root: []const u8,
    workers_buffer: [std.fs.max_path_bytes]u8,
    workers: []const u8,
    proc_stat_buffer: [std.fs.max_path_bytes]u8,
    proc_stat: []const u8,
    workers_dir: std.fs.Dir,

    fn init(target: *Tree) !void {
        target.tmp = std.testing.tmpDir(.{});
        errdefer target.tmp.cleanup();
        const dir = target.tmp.dir;
        try dir.makePath("own/workers/worker-1");
        try dir.writeFile(.{ .sub_path = "own/cpu.max", .data = "120000 100000\n" });
        try dir.writeFile(.{ .sub_path = "own/workers/cpu.max", .data = "max 100000\n" });
        try dir.writeFile(.{ .sub_path = "own/workers/cpuset.cpus.effective", .data = "1-2\n" });
        target.root = try dir.realpath(".", &target.root_buffer);
        target.workers = try std.fmt.bufPrint(&target.workers_buffer, "{s}/own/workers", .{target.root});
        target.proc_stat = try std.fmt.bufPrint(&target.proc_stat_buffer, "{s}/proc_stat", .{target.root});
        target.workers_dir = try dir.openDir("own/workers", .{});
    }

    fn deinit(self: *Tree) void {
        self.workers_dir.close();
        self.tmp.cleanup();
    }

    /// Writes the figures of one moment: the quota cgroup's CPU, the worker's
    /// CPU and wait, and the idle ticks of CPUs 0 to 3.
    fn write(self: *Tree, quota_usage_usec: u64, worker_usage_usec: u64, worker_stall_usec: u64, idle_ticks: [4]u64) !void {
        const dir = self.tmp.dir;
        var buffer: [512]u8 = undefined;
        try dir.writeFile(.{
            .sub_path = "own/cpu.stat",
            .data = try std.fmt.bufPrint(&buffer, "usage_usec {d}\nuser_usec 0\nsystem_usec 0\n", .{quota_usage_usec}),
        });
        try dir.writeFile(.{
            .sub_path = "own/workers/worker-1/cpu.stat",
            .data = try std.fmt.bufPrint(&buffer, "usage_usec {d}\nuser_usec 0\nsystem_usec 0\n", .{worker_usage_usec}),
        });
        try dir.writeFile(.{
            .sub_path = "own/workers/worker-1/cpu.pressure",
            .data = try std.fmt.bufPrint(&buffer, "some avg10=0.00 avg60=0.00 avg300=0.00 total={d}\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n", .{worker_stall_usec}),
        });
        try dir.writeFile(.{
            .sub_path = "proc_stat",
            .data = try std.fmt.bufPrint(&buffer, "cpu  0 0 0 0 0 0 0 0 0 0\ncpu0 1 0 1 {d} 0 0 0 0 0 0\ncpu1 1 0 1 {d} 0 0 0 0 0 0\ncpu2 1 0 1 {d} 0 0 0 0 0 0\ncpu3 1 0 1 {d} 0 0 0 0 0 0\nintr 0\n", .{ idle_ticks[0], idle_ticks[1], idle_ticks[2], idle_ticks[3] }),
        });
    }
};

fn allCpus(count: usize) scale_out.CpuSet {
    var cpus = scale_out.CpuSet.initEmpty();
    for (0..count) |cpu| cpus.set(cpu);
    return cpus;
}

test "the sampler reads a worker's CPU and wait and the node's idle CPU, within the cpuset and under the quota, against the sample just before" {
    var tree: Tree = undefined;
    try tree.init();
    defer tree.deinit();

    var sampler: scale_out.Sampler = undefined;
    try sampler.init(std.testing.allocator, .{
        .definition_count = 2,
        .workers_dir_path = tree.workers,
        .mount_root = tree.root,
        .proc_stat_path = tree.proc_stat,
        .cpus = allCpus(4),
    });
    defer sampler.deinit();
    try std.testing.expectEqual(@as(usize, 2), sampler.cpuCount());

    const worker: scale_out.LiveWorker = .{
        .key = .{ .worker_id = 4, .worker_generation = 1 },
        .leaf = .{ .workers_dir_fd = tree.workers_dir.fd, .job_id = 1 },
    };
    const interval_ns = 100 * std.time.ns_per_ms;
    const first_ns: u64 = 5 * std.time.ns_per_s;

    // The first sample only reads.
    try tree.write(1_000_000, 2_000_000, 300_000, .{ 0, 100, 200, 0 });
    sampler.begin(first_ns);
    try std.testing.expectEqual(scale_out.DefinitionFigures{}, sampler.readDefinition(1, &.{worker}));
    try std.testing.expectEqual(@as(u32, 0), sampler.readNodeIdle());

    // 100 ms later: the worker used half a core and waited 5% of the time;
    // CPUs 1 and 2 idled 70 ms and 80 ms, 1.5 cores, CPUs 0 and 3 do not
    // count; the quota of 1.2 cores had a whole core used.
    try tree.write(1_100_000, 2_050_000, 305_000, .{ 10, 107, 208, 10 });
    sampler.begin(first_ns + interval_ns);
    try std.testing.expectEqual(
        scale_out.DefinitionFigures{ .workers = 1, .cpu_permille = 500, .stall_permille = 50 },
        sampler.readDefinition(1, &.{worker}),
    );
    try std.testing.expectEqual(@as(u32, 200), sampler.readNodeIdle());

    // A worker published since the sample before has no figure yet.
    const newcomer: scale_out.LiveWorker = .{
        .key = .{ .worker_id = 5, .worker_generation = 1 },
        .leaf = .{ .workers_dir_fd = tree.workers_dir.fd, .job_id = 1 },
    };
    try tree.write(1_150_000, 2_100_000, 305_000, .{ 20, 117, 218, 20 });
    sampler.begin(first_ns + 2 * interval_ns);
    try std.testing.expectEqual(
        scale_out.DefinitionFigures{ .workers = 1, .cpu_permille = 500, .stall_permille = 0 },
        sampler.readDefinition(1, &.{ worker, newcomer }),
    );

    // A sample further from the one before than `window_ns_max` only reads.
    sampler.begin(first_ns + 2 * interval_ns + scale_out.window_ns_max + 1);
    try std.testing.expectEqual(scale_out.DefinitionFigures{}, sampler.readDefinition(1, &.{ worker, newcomer }));
    try std.testing.expectEqual(@as(u32, 0), sampler.readNodeIdle());
}

test "a worker leaf without cpu.pressure gives a wait of none, and one torn down gives no figure" {
    var tree: Tree = undefined;
    try tree.init();
    defer tree.deinit();
    var sampler: scale_out.Sampler = undefined;
    try sampler.init(std.testing.allocator, .{
        .definition_count = 1,
        .workers_dir_path = null,
        .proc_stat_path = tree.proc_stat,
        .cpus = allCpus(4),
    });
    defer sampler.deinit();
    const worker: scale_out.LiveWorker = .{
        .key = .{ .worker_id = 1, .worker_generation = 1 },
        .leaf = .{ .workers_dir_fd = tree.workers_dir.fd, .job_id = 1 },
    };
    const gone: scale_out.LiveWorker = .{
        .key = .{ .worker_id = 2, .worker_generation = 1 },
        .leaf = .{ .workers_dir_fd = tree.workers_dir.fd, .job_id = 2 },
    };

    try tree.write(0, 1_000, 0, .{ 0, 0, 0, 0 });
    try tree.tmp.dir.deleteFile("own/workers/worker-1/cpu.pressure");
    sampler.begin(std.time.ns_per_s);
    _ = sampler.readDefinition(0, &.{ worker, gone });
    try tree.write(0, 21_000, 0, .{ 0, 0, 0, 0 });
    try tree.tmp.dir.deleteFile("own/workers/worker-1/cpu.pressure");
    sampler.begin(std.time.ns_per_s + 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(
        scale_out.DefinitionFigures{ .workers = 1, .cpu_permille = 200, .stall_permille = 0 },
        sampler.readDefinition(0, &.{ worker, gone }),
    );
}
