//! The scale-out verdict: whether a definition whose live workers hold every
//! slot while requests wait gets one worker more, from the CPU the node has
//! for it (`skills/runtime/references/internals/scheduler.md`, "Scale-out").
//! The launcher thread alone runs it, once per
//! `scheduler_limits.scale_out.sample_interval_ns` while it watches
//! a definition (`launcher.zig:Launcher.stepScaleOut`, through
//! `supervisor.zig:Supervisor.sampleScaleOut`).
//!
//! A sample reads the idle CPU of the node and, for each watched definition,
//! the CPU and the CPU wait of each live worker's cgroup leaf, and keeps the
//! readings for the next sample: every figure is a difference against the
//! sample before, no more than `window_ns_max` earlier, so a reading with no
//! such predecessor counts for nothing and only becomes one. `decide` turns
//! the figures into grants and reads nothing, so tests drive it with figures
//! alone. A sample allocates nothing: `/proc/stat` is read into a buffer
//! sized at `init`, and every cgroup file into a stack buffer.
//!
//! The CPUs the workers may run on are the affinity mask `init` finds,
//! narrowed by the workers directory's `cpuset.cpus.effective`: a worker
//! inherits the zygote's mask, which is the server's, and the kernel narrows
//! a task's mask to its cgroup's cpuset. Their CPU time is bounded too by the
//! tightest `cpu.max` quota of the workers directory and its ancestors up to
//! the cgroup2 mount. Both are read once, at `init`, so an operator who
//! changes them restarts the server.

const std = @import("std");
const linux = std.os.linux;
const cgroup = @import("collo_cgroup");
const host = @import("collo_host");
const lifecycle = @import("collo_server_lifecycle");
const config = @import("collo_server_config");
const pool_limits = @import("collo_limits").pool;
const scheduler_limits = @import("scheduler_limits.zig");

const DefinitionIndex = config.DefinitionIndex;
const WorkerKey = lifecycle.WorkerKey;
const WorkerLeaf = host.cgroup_root.WorkerLeaf;
const pool_workers_max = pool_limits.pool_workers_max;

/// Thousandths of a core, the unit of every CPU figure here.
pub const permille_per_core: u32 = 1000;

/// The longest gap between two samples whose readings still make a figure.
/// The launcher samples every `scale_out.sample_interval_ns` while it
/// watches a definition, but a turn that waits in a gateway call, or a watch
/// that emptied and filled again, spaces two samples further apart, and a
/// figure over such a gap would average a backlog with the quiet before it.
pub const window_ns_max: u64 = 4 * scheduler_limits.scale_out.sample_interval_ns;

/// The ticks `/proc/stat` counts CPU time in: `USER_HZ`, which the kernel
/// fixes at 100 on every architecture this runtime targets
/// (`include/asm-generic/param.h`).
const proc_stat_ticks_per_second: u64 = 100;
/// Room for one `cpu<N>` line of `/proc/stat`: the name and ten counts of at
/// most 20 digits each, with their spaces.
const proc_stat_cpu_line_bytes_max: usize = 256;

/// The CPUs an affinity mask can name (`CPU_SETSIZE`).
pub const CpuSet = std.bit_set.ArrayBitSet(usize, linux.CPU_SETSIZE);

/// The verdict's limits, `scheduler_limits.scale_out` outside tests.
pub const Thresholds = struct {
    /// The mean share of the interval a definition's workers may wait for a
    /// CPU and still grow, in thousandths.
    stall_permille_max: u32 = scheduler_limits.scale_out.stall_permille_max,
    /// The mean CPU per worker, in thousandths of a core, from which a
    /// definition's workers count as CPU-bound.
    cpu_bound_permille: u32 = scheduler_limits.scale_out.cpu_bound_permille,
};

/// What one sample measured of a definition's live workers: the means over
/// those it read against the sample before.
pub const DefinitionFigures = struct {
    /// The workers with a figure; with 0 the definition is not weighed.
    workers: u32 = 0,
    /// CPU per worker, in thousandths of a core.
    cpu_permille: u32 = 0,
    /// The share of the interval a worker waited for a CPU, in thousandths.
    stall_permille: u32 = 0,
};

/// A watched definition and its figures, as `decide` weighs them.
pub const Candidate = struct {
    definition: DefinitionIndex,
    figures: DefinitionFigures,
};

/// Grants at most one launch to each candidate, writing `granted[i]` for
/// `candidates[i]`. A candidate is weighed only with figures, and only while
/// its workers wait for a CPU less than `thresholds.stall_permille_max` of
/// the time. One whose workers use less than `thresholds.cpu_bound_permille`
/// of a core each is I/O-bound and is granted; one whose workers are
/// CPU-bound is granted only while a whole idle core is left of
/// `node_idle_permille`, and takes it. Candidates are weighed from `start`
/// on, wrapping, so a caller that moves `start` each sample lets each one
/// come first in turn.
pub fn decide(
    candidates: []const Candidate,
    node_idle_permille: u32,
    start: usize,
    thresholds: Thresholds,
    granted: []bool,
) void {
    std.debug.assert(granted.len == candidates.len);
    @memset(granted, false);
    var budget_permille = node_idle_permille;
    for (0..candidates.len) |step| {
        const index = (start + step) % candidates.len;
        const figures = candidates[index].figures;
        if (figures.workers == 0) continue;
        if (figures.stall_permille >= thresholds.stall_permille_max) continue;
        if (figures.cpu_permille < thresholds.cpu_bound_permille) {
            granted[index] = true;
            continue;
        }
        if (budget_permille < permille_per_core) continue;
        budget_permille -= permille_per_core;
        granted[index] = true;
    }
}

/// A live worker of a watched definition, as its pool lists it.
pub const LiveWorker = struct {
    key: WorkerKey,
    leaf: WorkerLeaf,
};

pub const Options = struct {
    /// The definitions of the server's configuration.
    definition_count: usize,
    /// The workers directory, whose cpuset and whose own and ancestors'
    /// `cpu.max` bound the workers; null where no cgroup root exists, as in
    /// fixtures that never launch, which leaves the affinity mask alone.
    workers_dir_path: ?[]const u8,
    mount_root: []const u8 = cgroup.path.CGROUP2_MOUNT_PATH,
    proc_stat_path: []const u8 = "/proc/stat",
    /// The CPUs before the cpuset narrows them; null reads the calling
    /// thread's affinity mask, which the server's boot thread holds for the
    /// whole process.
    cpus: ?CpuSet = null,
};

pub const Sampler = struct {
    gpa: std.mem.Allocator,
    cpus: CpuSet,
    /// The tightest `cpu.max` quota above the workers, or null for none.
    quota: ?Quota,
    /// Borrowed from `Options`.
    proc_stat_path: []const u8,
    proc_stat_buffer: []u8,
    /// `pool_workers_max` readings per definition, a definition's at
    /// `definition * pool_workers_max`.
    readings: []WorkerReading,
    node: NodeReading,
    /// Samples begun since `init`; a reading names the sample that took it.
    sequence: u64,
    sample_ns: u64,
    previous_sample_ns: u64,
    start: usize,
    pressure_warned: bool,
    node_warned: bool,

    const Quota = struct {
        /// Owned: the cgroup whose `cpu.max` holds the quota.
        dir: std.posix.fd_t,
        permille: u32,
    };

    const WorkerReading = struct {
        key: WorkerKey = .{ .worker_id = 0, .worker_generation = 0 },
        /// The sample that took it, 0 for none.
        sequence: u64 = 0,
        cpu_usec: u64 = 0,
        stall_usec: u64 = 0,
    };

    const NodeReading = struct {
        sequence: u64 = 0,
        idle_ticks: u64 = 0,
        quota_usage_usec: u64 = 0,
    };

    /// Resolves the workers' CPUs and quota and allocates the readings and
    /// the `/proc/stat` buffer. Fails with `error.OutOfMemory` alone: a
    /// cgroup file that cannot be read is left out with a warning, and a
    /// mask that names no CPU, which the kernel never hands out, counts as
    /// CPU 0.
    pub fn init(self: *Sampler, gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!void {
        var cpus = options.cpus orelse affinityCpus();
        if (cpus.count() == 0) cpus.set(0);
        var quota: ?Quota = null;
        if (options.workers_dir_path) |workers_dir_path| {
            narrowToCpuset(&cpus, workers_dir_path);
            quota = findQuota(workers_dir_path, options.mount_root);
        }
        errdefer if (quota) |held| std.posix.close(held.dir);
        // `cpus` holds a CPU, and `narrowToCpuset` never leaves it empty.
        const highest_cpu = lastSet(&cpus).?;
        // The `cpu` line of the whole machine and every line up to the
        // highest CPU the workers may use.
        const proc_stat_buffer = try gpa.alloc(u8, (highest_cpu + 2) * proc_stat_cpu_line_bytes_max);
        errdefer gpa.free(proc_stat_buffer);
        const readings = try gpa.alloc(WorkerReading, options.definition_count * pool_workers_max);
        @memset(readings, .{});
        self.* = .{
            .gpa = gpa,
            .cpus = cpus,
            .quota = quota,
            .proc_stat_path = options.proc_stat_path,
            .proc_stat_buffer = proc_stat_buffer,
            .readings = readings,
            .node = .{},
            .sequence = 0,
            .sample_ns = 0,
            .previous_sample_ns = 0,
            .start = 0,
            .pressure_warned = false,
            .node_warned = false,
        };
    }

    pub fn deinit(self: *Sampler) void {
        if (self.quota) |quota| std.posix.close(quota.dir);
        self.gpa.free(self.readings);
        self.gpa.free(self.proc_stat_buffer);
        self.* = undefined;
    }

    /// The CPUs the workers may run on, as `init` resolved them.
    pub fn cpuCount(self: *const Sampler) usize {
        return self.cpus.count();
    }

    /// Starts a sample at `now_ns`, CLOCK_MONOTONIC. The figures of
    /// `readDefinition` and `readNodeIdle` until the next `begin` are
    /// differences against the sample before.
    pub fn begin(self: *Sampler, now_ns: u64) void {
        self.sequence += 1;
        self.previous_sample_ns = self.sample_ns;
        self.sample_ns = now_ns;
    }

    /// The candidate the next verdict weighs first; moves by one each call.
    pub fn nextStart(self: *Sampler) usize {
        const start = self.start;
        self.start +%= 1;
        return start;
    }

    /// The figures of `definition`'s live workers `live`, read now; each
    /// worker's reading is kept for the next sample. A worker whose leaf
    /// cannot be read, as one torn down since its pool listed it, gives no
    /// figure, and a kernel without `cpu.pressure` gives no wait.
    pub fn readDefinition(self: *Sampler, definition: DefinitionIndex, live: []const LiveWorker) DefinitionFigures {
        std.debug.assert(live.len <= pool_workers_max);
        const first = @as(usize, definition) * pool_workers_max;
        const readings = self.readings[first..][0..pool_workers_max];
        const window_us = self.windowUs();
        var cpu_permille_sum: u64 = 0;
        var stall_permille_sum: u64 = 0;
        var workers: u32 = 0;
        for (live) |worker| {
            const reading = readingFor(readings, live, worker.key);
            const cpu_usec = cgroup.readLeafFigure(worker.leaf, .cpu_usage_usec) catch {
                reading.* = .{};
                continue;
            };
            const stall_usec = cgroup.readLeafFigure(worker.leaf, .cpu_pressure_some_usec) catch |err| blk: {
                if (!self.pressure_warned) {
                    self.pressure_warned = true;
                    std.log.warn("scale-out: a worker's cpu.pressure cannot be read: {s}; its wait for a CPU counts as none", .{@errorName(err)});
                }
                break :blk reading.stall_usec;
            };
            const previous = reading.*;
            reading.* = .{ .key = worker.key, .sequence = self.sequence, .cpu_usec = cpu_usec, .stall_usec = stall_usec };
            const span_us = window_us orelse continue;
            if (previous.sequence + 1 != self.sequence) continue;
            if (!previous.key.eql(worker.key)) continue;
            cpu_permille_sum += permilleOf(cpu_usec -| previous.cpu_usec, span_us, permille_per_core);
            stall_permille_sum += permilleOf(stall_usec -| previous.stall_usec, span_us, permille_per_core);
            workers += 1;
        }
        if (workers == 0) return .{};
        return .{
            .workers = workers,
            .cpu_permille = @intCast(cpu_permille_sum / workers),
            .stall_permille = @intCast(stall_permille_sum / workers),
        };
    }

    /// The idle CPU the workers may still use since the sample before, in
    /// thousandths of a core: the idle time of their CPUs, at most the room
    /// left under the quota. 0 when the sample before read nothing, or when
    /// `/proc/stat` cannot be read now, which leaves CPU-bound definitions
    /// the workers they have.
    pub fn readNodeIdle(self: *Sampler) u32 {
        const previous = self.node;
        const idle_ticks = self.readIdleTicks() catch |err| {
            if (!self.node_warned) {
                self.node_warned = true;
                std.log.warn("scale-out: {s} cannot be read: {s}; the node counts as having no idle CPU", .{ self.proc_stat_path, @errorName(err) });
            }
            self.node = .{};
            return 0;
        };
        var quota_usage_usec: u64 = 0;
        if (self.quota) |quota| {
            quota_usage_usec = cgroup.cpu.readStatUsageUsecAt(quota.dir) catch |err| {
                if (!self.node_warned) {
                    self.node_warned = true;
                    std.log.warn("scale-out: the cpu.stat of the quota's cgroup cannot be read: {s}; the node counts as having no idle CPU", .{@errorName(err)});
                }
                self.node = .{};
                return 0;
            };
        }
        self.node = .{ .sequence = self.sequence, .idle_ticks = idle_ticks, .quota_usage_usec = quota_usage_usec };
        const span_us = self.windowUs() orelse return 0;
        if (previous.sequence + 1 != self.sequence) return 0;
        const idle_us = (idle_ticks -| previous.idle_ticks) * (std.time.us_per_s / proc_stat_ticks_per_second);
        const cpu_capacity_permille: u64 = @as(u64, self.cpus.count()) * permille_per_core;
        var idle_permille = permilleOf(idle_us, span_us, cpu_capacity_permille);
        if (self.quota) |quota| {
            const used_permille = permilleOf(quota_usage_usec -| previous.quota_usage_usec, span_us, std.math.maxInt(u32));
            idle_permille = @min(idle_permille, @as(u64, quota.permille) -| used_permille);
        }
        return @intCast(idle_permille);
    }

    /// The span since the sample before in microseconds, or null when there
    /// was none within `window_ns_max`.
    fn windowUs(self: *const Sampler) ?u64 {
        if (self.previous_sample_ns == 0) return null;
        if (self.sample_ns <= self.previous_sample_ns) return null;
        const span_ns = self.sample_ns - self.previous_sample_ns;
        if (span_ns > window_ns_max) return null;
        return @max(1, span_ns / std.time.ns_per_us);
    }

    /// Idle and iowait ticks summed over the workers' CPUs.
    fn readIdleTicks(self: *Sampler) !u64 {
        const file = try std.fs.openFileAbsolute(self.proc_stat_path, .{});
        defer file.close();
        // The lines after the CPUs', the interrupt counts among them, may not
        // fit; only whole `cpu` lines are parsed.
        const read_len = try file.readAll(self.proc_stat_buffer);
        return parseProcStatIdleTicks(self.proc_stat_buffer[0..read_len], &self.cpus);
    }
};

/// The reading slot of the worker `key` among a definition's `readings`: its
/// own when it has one, else one whose worker is not among `live`, which a
/// definition with at most `pool_workers_max` live workers always has.
fn readingFor(readings: []Sampler.WorkerReading, live: []const LiveWorker, key: WorkerKey) *Sampler.WorkerReading {
    for (readings) |*reading| {
        if (reading.sequence != 0 and reading.key.eql(key)) return reading;
    }
    for (readings) |*reading| {
        const held = for (live) |worker| {
            if (reading.sequence != 0 and reading.key.eql(worker.key)) break true;
        } else false;
        if (!held) {
            reading.* = .{};
            return reading;
        }
    }
    unreachable; // `live` has at most `pool_workers_max` workers, each holding one slot.
}

/// `amount_us` over `span_us` in thousandths, at most `ceiling`.
fn permilleOf(amount_us: u64, span_us: u64, ceiling: u64) u64 {
    std.debug.assert(span_us != 0);
    const permille = @as(u128, amount_us) * permille_per_core / span_us;
    return @intCast(@min(permille, ceiling));
}

/// The idle and iowait ticks of the `cpu<N>` lines of `/proc/stat` text
/// whose CPU is in `cpus`. The lines start the file, after the machine's
/// own `cpu` line; parsing stops at the first line of another kind or at a
/// line cut short by the end of `contents`. Fails with
/// `error.InvalidProcStat` for a CPU line without its idle and iowait
/// counts.
pub fn parseProcStatIdleTicks(contents: []const u8, cpus: *const CpuSet) !u64 {
    var idle_ticks: u64 = 0;
    var rest = contents;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |line_end| {
        const line = rest[0..line_end];
        rest = rest[line_end + 1 ..];
        if (!std.mem.startsWith(u8, line, "cpu")) break;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const name = fields.next() orelse break;
        // The machine's line, `cpu` alone, sums every CPU.
        if (name.len == "cpu".len) continue;
        const cpu = std.fmt.parseUnsigned(usize, name["cpu".len..], 10) catch return error.InvalidProcStat;
        if (cpu >= CpuSet.bit_length or !cpus.isSet(cpu)) continue;
        // user nice system idle iowait ...
        var counts: [5]u64 = undefined;
        for (&counts) |*count| {
            const text = fields.next() orelse return error.InvalidProcStat;
            count.* = std.fmt.parseUnsigned(u64, text, 10) catch return error.InvalidProcStat;
        }
        idle_ticks +|= counts[3] +| counts[4];
    }
    return idle_ticks;
}

/// The CPUs of the calling thread's affinity mask, or CPUs 0 to
/// `getCpuCount` - 1 when the mask cannot be read, as the lane plan takes
/// them (`server/net/lane_plan.zig:discoverAllowedCpus`).
fn affinityCpus() CpuSet {
    var cpus = CpuSet.initEmpty();
    const mask = std.posix.sched_getaffinity(0) catch {
        const count = std.Thread.getCpuCount() catch 1;
        for (0..@min(@max(count, 1), CpuSet.bit_length)) |cpu| cpus.set(cpu);
        return cpus;
    };
    const word_bits = @bitSizeOf(usize);
    for (mask, 0..) |word, word_index| {
        var bit: usize = 0;
        while (bit < word_bits) : (bit += 1) {
            if ((word >> @intCast(bit)) & 1 != 0)
                cpus.set(word_index * word_bits + bit);
        }
    }
    return cpus;
}

fn lastSet(cpus: *const CpuSet) ?usize {
    var last: ?usize = null;
    var iterator = cpus.iterator(.{});
    while (iterator.next()) |cpu| last = cpu;
    return last;
}

/// Narrows `cpus` to the workers directory's `cpuset.cpus.effective`, which
/// exists only where the cpuset controller is enabled; without it, or when
/// it names none of `cpus`, the mask stays as it is.
fn narrowToCpuset(cpus: *CpuSet, workers_dir_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(workers_dir_path, .{}) catch |err| {
        std.log.warn("scale-out: cannot open {s}: {s}; its cpuset is not read", .{ workers_dir_path, @errorName(err) });
        return;
    };
    defer dir.close();
    var effective = CpuSet.initEmpty();
    cgroup.cpuset.readEffectiveCpusAt(dir.fd, &effective) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.log.warn("scale-out: the cpuset of {s} cannot be read: {s}; the affinity mask alone bounds the workers", .{ workers_dir_path, @errorName(err) });
            return;
        },
    };
    var narrowed = cpus.*;
    narrowed.setIntersection(effective);
    if (narrowed.count() == 0) return;
    cpus.* = narrowed;
}

/// The tightest `cpu.max` quota of `workers_dir_path` and its ancestors below
/// `mount_root`, with its cgroup's directory kept open, or null when none
/// sets one. A cgroup whose `cpu.max` is missing, because the cpu controller
/// is not enabled there, or cannot be read, bounds nothing.
fn findQuota(workers_dir_path: []const u8, mount_root: []const u8) ?Sampler.Quota {
    var tightest: ?Sampler.Quota = null;
    var current: []const u8 = workers_dir_path;
    // Each step drops one path component, so the walk ends.
    while (current.len > mount_root.len and std.mem.startsWith(u8, current, mount_root)) {
        defer current = std.fs.path.dirname(current) orelse mount_root;
        const fd = std.posix.open(current, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) catch continue;
        const max = cgroup.cpu.readMaxAt(fd) catch {
            std.posix.close(fd);
            continue;
        };
        const quota_us = max.quota_us orelse {
            std.posix.close(fd);
            continue;
        };
        const permille: u32 = @intCast(@min(@as(u128, quota_us) * permille_per_core / max.period_us, std.math.maxInt(u32)));
        if (tightest) |held| {
            if (permille >= held.permille) {
                std.posix.close(fd);
                continue;
            }
            std.posix.close(held.dir);
        }
        tightest = .{ .dir = fd, .permille = permille };
    }
    return tightest;
}
