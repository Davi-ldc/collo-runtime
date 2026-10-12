//! The reaper's readings of memory and its victim score: node memory
//! pressure from every bound above the runtime, what a failed reading stands
//! on, the PSI trigger that wakes the reaper, a worker's reclaimable memory
//! from `smaps_rollup` or its cgroup, and the score that weighs those bytes
//! by idle age. Pure functions, file reads and the reaper thread's own
//! reading state, with no supervisor state; the reaper thread (`root.zig`)
//! and its passes (`reaping.zig`) call them.
//!
//! Node memory is a question of which limit bounds the runtime, and the boot
//! answers it once (`MemoryDomains`): the machine, and every cgroup above the
//! workers and above the server, each of which may carry a `memory.max` an
//! operator or a container runtime set. A reading takes, for each bound, the
//! share of it in use, and reports the highest, since the bound nearest to
//! being hit is the one that decides. The pressure levels are percentages of
//! that share, defined in `scheduler_limits.zig` with the reasons for each.

const std = @import("std");

const limits = @import("../scheduler_limits.zig");

const soft_memory_pressure_used_percent: u8 = limits.memory.autoscale_high_water_percent;
const hard_memory_pressure_used_percent: u8 = limits.memory.evict_before_fork_percent;
const critical_memory_pressure_used_percent: u8 = limits.memory.fork_deny_percent;
pub const memory_pressure_low_water_percent: u8 = limits.memory.reclaim_low_water_percent;

/// What `armPsiTrigger` writes: the trigger and a NUL. The kernel's handler
/// (`psi_write` in `kernel/sched/psi.c`) copies at most `psi_write_bytes_max`
/// bytes of a write and overwrites the last of them with its terminator, so a
/// trigger written without its own NUL loses its last digit.
pub const psi_trigger_bytes = limits.memory.psi_some_trigger ++ "\x00";
const psi_write_bytes_max: usize = 32;

comptime {
    std.debug.assert(psi_trigger_bytes.len <= psi_write_bytes_max);
}

pub const MemoryPressureMode = enum {
    none,
    soft,
    hard,
    critical,
};

pub const MemoryPressure = struct {
    mode: MemoryPressureMode,
    used_percent: u8 = 0,
};

/// What the reaper acts on when it has no reading to trust.
const critical_pressure = MemoryPressure{ .mode = .critical, .used_percent = 100 };

/// The reaper's last reading of node memory, which stands in for a read that
/// fails. A failed read says nothing new about memory, so the last reading
/// that succeeded stands; before the first one, and when the read failed for
/// want of memory, which is evidence of the very condition measured, the
/// stand-in is critical. A reading of 0% is a reading like any other. Only
/// the thread that runs the reaper's passes touches it.
pub const LastReading = struct {
    /// The used percentage of the last read that succeeded; null before the
    /// first.
    used_percent: ?u8 = null,

    /// The pressure to act on after a read that ended in `result`: the
    /// reading itself, which is remembered, or its stand-in, which is not.
    pub fn settle(self: *LastReading, result: anyerror!MemoryPressure) MemoryPressure {
        const pressure = result catch |err| {
            const stand_in = self.standIn(err);
            std.log.warn("memory pressure read failed: {s}; acting on {d}% used", .{
                @errorName(err),
                stand_in.used_percent,
            });
            return stand_in;
        };
        self.used_percent = pressure.used_percent;
        return pressure;
    }

    fn standIn(self: *const LastReading, err: anyerror) MemoryPressure {
        if (err == error.OutOfMemory)
            return critical_pressure;
        const used_percent = self.used_percent orelse return critical_pressure;
        return memoryPressureFromUsedPercent(used_percent);
    }
};

/// A PSI trigger on `/proc/pressure/memory` (`limits.memory.psi_some_trigger`);
/// the kernel reports it as POLLPRI on the descriptor and drops it when the
/// descriptor closes. `init` fails when the kernel has no PSI, so no pressure
/// file exists, or refuses the trigger, as kernels before Linux 6.4 do for a
/// process without `CAP_SYS_RESOURCE`, failing the open (`psiRefusalReason`).
pub const MemoryPressureWake = struct {
    fd: std.posix.fd_t,

    pub fn init() !MemoryPressureWake {
        const fd = try std.posix.openZ("/proc/pressure/memory", .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
            .NONBLOCK = true,
        }, 0);
        errdefer std.posix.close(fd);

        try armPsiTrigger(fd);
        return .{ .fd = fd };
    }

    pub fn deinit(self: *MemoryPressureWake) void {
        if (self.fd >= 0)
            std.posix.close(self.fd);
        self.* = undefined;
    }
};

/// Arms the reaper's trigger on `fd`, an open `/proc/pressure/memory`, with
/// one write of `psi_trigger_bytes`: the kernel parses each write as a whole
/// trigger and keeps one trigger per descriptor.
pub fn armPsiTrigger(fd: std.posix.fd_t) !void {
    const written = try std.posix.write(fd, psi_trigger_bytes);
    if (written != psi_trigger_bytes.len)
        return error.ShortWrite;
}

/// Why `MemoryPressureWake.init` failed with `err`, for the reaper's warning.
pub fn psiRefusalReason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "the kernel has no PSI",
        error.AccessDenied, error.PermissionDenied => "the kernel gives no PSI trigger to a process " ++
            "without CAP_SYS_RESOURCE, as kernels before Linux 6.4 do",
        else => @errorName(err),
    };
}

/// A worker's victim score: its reclaimable bytes weighted by idle age. The
/// worker with the higher score is reaped first.
pub fn workerMemoryVictimScore(reclaimable_bytes: u64, idle_ns: u64, worker_idle_ttl_ns: u64) u128 {
    return @as(u128, reclaimable_bytes) * idleWeightScaled(idle_ns, worker_idle_ttl_ns);
}

/// `workerMemoryVictimScore`, except that a size of 0, which is what an
/// unreadable size becomes, counts as one byte, so the worker still ranks by
/// idle age and keeps the positive score the victim set requires.
pub fn workerMemoryVictimScoreWithUnknownFallback(reclaimable_bytes: u64, idle_ns: u64, worker_idle_ttl_ns: u64) u128 {
    const weighted_bytes = @max(reclaimable_bytes, 1);
    return @as(u128, weighted_bytes) * idleWeightScaled(idle_ns, worker_idle_ttl_ns);
}

/// Idle age as a fraction of the idle TTL, in thousandths, clamped to 50
/// through 1000, so a worker that just went idle still weighs a twentieth of
/// one at its TTL. Without a TTL every worker weighs 1000.
pub fn idleWeightScaled(idle_ns: u64, worker_idle_ttl_ns: u64) u128 {
    if (worker_idle_ttl_ns == 0)
        return 1000;
    const raw = (@as(u128, idle_ns) * 1000) / worker_idle_ttl_ns;
    return std.math.clamp(raw, 50, 1000);
}

pub fn readWorkerMemoryCurrent(allocator: std.mem.Allocator, cgroup_dir: []const u8) !u64 {
    const path = try std.fmt.allocPrint(allocator, "{s}/memory.current", .{cgroup_dir});
    defer allocator.free(path);
    return readUnsignedFile(allocator, path);
}

/// The highest `memory.current` the worker's cgroup reached since its
/// creation, or null on a kernel without `memory.peak` (before Linux 5.19).
pub fn readWorkerMemoryPeak(allocator: std.mem.Allocator, cgroup_dir: []const u8) !?u64 {
    const path = try std.fmt.allocPrint(allocator, "{s}/memory.peak", .{cgroup_dir});
    defer allocator.free(path);
    return readUnsignedFile(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
}

/// The worker's private resident bytes from `/proc/<pid>/smaps_rollup`: the
/// pages only this worker maps, so the copy-on-write pages it still shares
/// with the zygote do not count.
pub fn readWorkerPrivateRssBytes(allocator: std.mem.Allocator, pid: u32) !u64 {
    if (pid == 0)
        return error.InvalidPid;
    const path = try std.fmt.allocPrint(allocator, "/proc/{d}/smaps_rollup", .{pid});
    defer allocator.free(path);
    const bytes = try readSmallFileAbsolute(allocator, path, 32 * 1024);
    defer allocator.free(bytes);
    return parseSmapsRollupPrivateRssBytes(bytes);
}

pub fn parseSmapsRollupPrivateRssBytes(bytes: []const u8) !u64 {
    var private_kb: u64 = 0;
    var found = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const value = if (std.mem.startsWith(u8, line, "Private_Clean:"))
            parseMeminfoKb(line["Private_Clean:".len..])
        else if (std.mem.startsWith(u8, line, "Private_Dirty:"))
            parseMeminfoKb(line["Private_Dirty:".len..])
        else if (std.mem.startsWith(u8, line, "Private_Hugetlb:"))
            parseMeminfoKb(line["Private_Hugetlb:".len..])
        else
            continue;
        private_kb = try std.math.add(u64, private_kb, try value);
        found = true;
    }
    if (!found)
        return error.SmapsRollupMissingPrivateRss;
    return std.math.mul(u64, private_kb, 1024);
}

/// The cgroup directories a node reading watches at most.
pub const domains_max: usize = limits.memory.cgroup_ancestors_max;

/// Where the cgroup v2 hierarchy is mounted; the walk up from a cgroup stops
/// at it, since the root cgroup carries no `memory.max`.
pub const cgroup_mount_root = "/sys/fs/cgroup";

/// The bounds node memory is read against, resolved once at boot from the
/// cgroups that hold the workers and the server (`init`): every ancestor of
/// each, itself included, up to `mount_root`, each once, kept open as a
/// directory, the nearest first, and the machine's own reading. A directory
/// that cannot be opened, or a cgroup past `domains_max`, is left out with a
/// warning; a bound the walk misses only makes the reading less strict,
/// never wrong about the bounds it holds. Only the thread that runs the
/// reaper's passes reads it.
pub const MemoryDomains = struct {
    dirs: [domains_max]std.posix.fd_t = undefined,
    len: usize = 0,
    /// The machine's reading, `/proc/meminfo` outside tests.
    meminfo_path: []const u8,
    /// The domains whose failed read was warned about, so a domain warns
    /// once per boot; the machine's is the last bit.
    warned: std.StaticBitSet(domains_max + 1) = .initEmpty(),

    pub const Options = struct {
        /// The cgroups whose limits bound the runtime, as absolute paths.
        cgroup_paths: []const []const u8,
        mount_root: []const u8 = cgroup_mount_root,
        meminfo_path: []const u8 = "/proc/meminfo",
    };

    /// Opens the directories `options` names. Never fails: what cannot be
    /// opened is left out, with a warning.
    pub fn init(target: *MemoryDomains, options: Options) void {
        target.* = .{ .meminfo_path = options.meminfo_path };
        var opened: [domains_max][]const u8 = undefined;
        for (options.cgroup_paths) |cgroup_path| {
            var current: []const u8 = cgroup_path;
            // Each step drops one path component, so the walk ends.
            while (isWithin(options.mount_root, current) and current.len > options.mount_root.len) {
                defer current = std.fs.path.dirname(current) orelse options.mount_root;
                const seen = for (opened[0..target.len]) |path| {
                    if (std.mem.eql(u8, path, current)) break true;
                } else false;
                if (seen) continue;
                if (target.len == domains_max) {
                    std.log.warn("node memory: more than {d} cgroups above the runtime; {s} and its ancestors are not read", .{ domains_max, current });
                    break;
                }
                const fd = std.posix.open(current, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) catch |err| {
                    std.log.warn("node memory: cannot open {s}, whose limit is then not read: {s}", .{ current, @errorName(err) });
                    continue;
                };
                target.dirs[target.len] = fd;
                opened[target.len] = current;
                target.len += 1;
            }
        }
    }

    pub fn deinit(self: *MemoryDomains) void {
        for (self.dirs[0..self.len]) |fd|
            std.posix.close(fd);
        self.* = undefined;
    }

    /// The share of its limit each domain uses, the highest of them, or
    /// `error.NoMemoryDomainReadable` when not one could be read. A cgroup
    /// without a limit is no bound and is not read further.
    fn highestUsedPercent(self: *MemoryDomains, allocator: std.mem.Allocator) !u8 {
        var highest: ?u8 = null;
        for (self.dirs[0..self.len], 0..) |dir, index| {
            const percent = cgroupUsedPercent(dir) catch |err| {
                self.warnOnce(index, err);
                continue;
            } orelse continue;
            highest = @max(highest orelse 0, percent);
        }
        if (meminfoUsedPercent(allocator, self.meminfo_path)) |percent| {
            highest = @max(highest orelse 0, percent);
        } else |err| {
            self.warnOnce(domains_max, err);
        }
        return highest orelse error.NoMemoryDomainReadable;
    }

    fn warnOnce(self: *MemoryDomains, index: usize, err: anyerror) void {
        if (self.warned.isSet(index))
            return;
        self.warned.set(index);
        if (index == domains_max) {
            std.log.warn("node memory: {s} cannot be read: {s}; the reading leaves it out", .{ self.meminfo_path, @errorName(err) });
        } else {
            std.log.warn("node memory: the limit of a cgroup above the runtime cannot be read: {s}; the reading leaves it out", .{@errorName(err)});
        }
    }
};

/// Node memory pressure: the highest share in use of any bound `domains`
/// holds (`MemoryDomains`). Fails only when no bound could be read, which the
/// caller's `LastReading` answers.
pub fn readMemoryPressure(allocator: std.mem.Allocator, domains: *MemoryDomains) !MemoryPressure {
    return memoryPressureFromUsedPercent(try domains.highestUsedPercent(allocator));
}

/// The share of its `memory.max` the cgroup in `dir` uses, or null when it
/// has no limit: `max`, or no file, as at the root of a hierarchy.
fn cgroupUsedPercent(dir: std.posix.fd_t) !?u8 {
    const max = (readUnsignedAt(dir, "memory.max") catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    }) orelse return null;
    if (max == 0)
        return error.InvalidCgroupMemoryLimit;
    const current = (try readUnsignedAt(dir, "memory.current")) orelse return error.InvalidCgroupMemoryCurrent;
    return usedPercent(current, max);
}

/// A cgroup file of one unsigned number, or null for `max`.
fn readUnsignedAt(dir: std.posix.fd_t, name: [:0]const u8) !?u64 {
    const fd = try std.posix.openatZ(dir, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer std.posix.close(fd);
    var buffer: [64]u8 = undefined;
    const length = try std.posix.read(fd, &buffer);
    const trimmed = std.mem.trim(u8, buffer[0..length], " \t\r\n");
    if (std.mem.eql(u8, trimmed, "max"))
        return null;
    return try std.fmt.parseInt(u64, trimmed, 10);
}

/// True when `path` is `ancestor` or lies below it.
fn isWithin(ancestor: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, ancestor))
        return false;
    return path.len == ancestor.len or path[ancestor.len] == '/';
}

/// The machine's share of memory in use, `MemTotal` less `MemAvailable`.
fn meminfoUsedPercent(allocator: std.mem.Allocator, meminfo_path: []const u8) !u8 {
    const bytes = try readSmallFileAbsolute(allocator, meminfo_path, 16 * 1024);
    defer allocator.free(bytes);

    var total_kb: ?u64 = null;
    var available_kb: ?u64 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseMeminfoKb(line["MemTotal:".len..]) catch null;
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = parseMeminfoKb(line["MemAvailable:".len..]) catch null;
        }
    }

    const total = total_kb orelse return error.MeminfoMissingTotal;
    const available = available_kb orelse return error.MeminfoMissingAvailable;
    if (total == 0)
        return error.InvalidMeminfoTotal;
    const used = if (available >= total) 0 else total - available;
    return usedPercent(used, total);
}

/// The server's own cgroup, from `/proc/self/cgroup`, as an absolute path
/// under `cgroup_mount_root`; the caller frees it.
pub fn currentCgroupDir(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try readSmallFileAbsolute(allocator, "/proc/self/cgroup", 16 * 1024);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::"))
            continue;
        const relative = line["0::".len..];
        if (relative.len == 0 or std.mem.eql(u8, relative, "/"))
            return allocator.dupe(u8, cgroup_mount_root);
        return std.fmt.allocPrint(allocator, cgroup_mount_root ++ "{s}", .{relative});
    }
    return error.CgroupV2PathNotFound;
}

pub fn memoryPressureFromUsedPercent(percent: u8) MemoryPressure {
    return .{
        .mode = if (percent >= critical_memory_pressure_used_percent)
            .critical
        else if (percent >= hard_memory_pressure_used_percent)
            .hard
        else if (percent >= soft_memory_pressure_used_percent)
            .soft
        else
            .none,
        .used_percent = percent,
    };
}

fn usedPercent(used: u64, limit: u64) u8 {
    if (limit == 0)
        return 100;
    const percent = (@as(u128, used) * 100) / limit;
    return @intCast(@min(percent, 100));
}

fn readUnsignedFile(allocator: std.mem.Allocator, path: []const u8) !u64 {
    const bytes = try readSmallFileAbsolute(allocator, path, 128);
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10);
}

fn readSmallFileAbsolute(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn parseMeminfoKb(bytes: []const u8) !u64 {
    var it = std.mem.tokenizeAny(u8, bytes, " \t");
    const number = it.next() orelse return error.InvalidMeminfoLine;
    return std.fmt.parseInt(u64, number, 10);
}
