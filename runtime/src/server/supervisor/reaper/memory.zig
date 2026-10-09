//! The reaper's readings of memory and its victim score: node memory
//! pressure from the server's cgroup or `/proc/meminfo`, what a failed
//! reading stands on, the PSI trigger that wakes the reaper, a worker's
//! reclaimable memory from `smaps_rollup` or its cgroup, and the score that
//! weighs those bytes by idle age. Pure functions, file reads and the reaper
//! thread's own reading state, with no supervisor state; the reaper thread
//! (`root.zig`) and its passes (`reaping.zig`) call them.
//!
//! The pressure levels are percentages of the memory `readMemoryPressure`
//! reads, defined in `scheduler_limits.zig` with the reasons for each.

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

/// Node memory pressure: the `memory.current` of the cgroup `/proc/self/cgroup`
/// names against its `memory.max`, or `MemTotal` less `MemAvailable` from
/// `/proc/meminfo` when that cgroup has no limit or cannot be read.
pub fn readMemoryPressure(allocator: std.mem.Allocator) !MemoryPressure {
    // In the delegated placement the server's cgroup is `<own>/main`, which
    // the server creates and never limits (`prepareDelegatedSubtree` in
    // `host/cgroup_root.zig`), so the reading is the machine's. In the
    // env-root placement it is the cgroup the server started in. Either way
    // the cgroup holds the server, the zygote and the gateway, never a worker.
    if (readCgroupMemoryPressure(allocator)) |pressure| {
        return pressure;
    } else |_| {}
    return readMeminfoMemoryPressure(allocator);
}

fn readCgroupMemoryPressure(allocator: std.mem.Allocator) !MemoryPressure {
    const dir = try currentCgroupMemoryDir(allocator);
    defer allocator.free(dir);
    const current_path = try std.fmt.allocPrint(allocator, "{s}/memory.current", .{dir});
    defer allocator.free(current_path);
    const max_path = try std.fmt.allocPrint(allocator, "{s}/memory.max", .{dir});
    defer allocator.free(max_path);

    const current = try readUnsignedFile(allocator, current_path);
    const max = (try readOptionalUnsignedFile(allocator, max_path)) orelse return error.UnboundedCgroupMemory;
    if (max == 0)
        return error.InvalidCgroupMemoryLimit;
    return memoryPressureFromUsedPercent(usedPercent(current, max));
}

fn readMeminfoMemoryPressure(allocator: std.mem.Allocator) !MemoryPressure {
    const bytes = try readSmallFileAbsolute(allocator, "/proc/meminfo", 16 * 1024);
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
    return memoryPressureFromUsedPercent(usedPercent(used, total));
}

fn currentCgroupMemoryDir(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try readSmallFileAbsolute(allocator, "/proc/self/cgroup", 16 * 1024);
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::"))
            continue;
        const relative = line["0::".len..];
        if (relative.len == 0 or std.mem.eql(u8, relative, "/"))
            return allocator.dupe(u8, "/sys/fs/cgroup");
        return std.fmt.allocPrint(allocator, "/sys/fs/cgroup{s}", .{relative});
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

fn readOptionalUnsignedFile(allocator: std.mem.Allocator, path: []const u8) !?u64 {
    const bytes = try readSmallFileAbsolute(allocator, path, 128);
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "max"))
        return null;
    return try std.fmt.parseInt(u64, trimmed, 10);
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
