//! Process and machine memory as the kernel accounts it, read from /proc by
//! the bench's own thread: RSS from `status`, PSS, private-dirty and
//! shared-clean from `smaps_rollup`, and system-wide counters from
//! `meminfo`. PSS splits every shared page among its sharers, so summing it
//! over a zygote and its workers gives the memory the set really holds.
//! Private-dirty counts the written pages no other process maps: in a forked
//! worker, the pages copy-on-write had to duplicate plus the ones it
//! allocated itself. A key the kernel does not report is an error, never a
//! zero, because a bench that cannot measure must not print a number.

const std = @import("std");

const proc_file_max_bytes: usize = 128 * 1024;

pub const Metrics = struct {
    rss_kib: u64 = 0,
    pss_kib: u64 = 0,
    private_dirty_kib: u64 = 0,
    shared_clean_kib: u64 = 0,

    pub fn add(self: Metrics, other: Metrics) Metrics {
        return .{
            .rss_kib = self.rss_kib + other.rss_kib,
            .pss_kib = self.pss_kib + other.pss_kib,
            .private_dirty_kib = self.private_dirty_kib + other.private_dirty_kib,
            .shared_clean_kib = self.shared_clean_kib + other.shared_clean_kib,
        };
    }
};

/// System-wide counters from /proc/meminfo. `used_kib` is MemTotal minus
/// MemAvailable, the memory the kernel estimates it cannot hand to a new
/// process without swapping. The others are the pieces that never come from
/// the page cache, so a delta between two readings prices what a set of
/// processes cost the machine, sandbox structures and page tables included.
pub const SystemMemory = struct {
    used_kib: u64,
    anon_kib: u64,
    slab_kib: u64,
    kernel_stack_kib: u64,
    page_tables_kib: u64,
};

/// Fails with `error.ProcKeyNotFound` when a counter is missing and with
/// `error.InvalidProcLine` when MemAvailable exceeds MemTotal.
pub fn readSystem(allocator: std.mem.Allocator) !SystemMemory {
    var file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, proc_file_max_bytes);
    defer allocator.free(contents);
    const total = try findKeyKb(contents, "MemTotal:");
    const available = try findKeyKb(contents, "MemAvailable:");
    if (available > total)
        return error.InvalidProcLine;
    return .{
        .used_kib = total - available,
        .anon_kib = try findKeyKb(contents, "AnonPages:"),
        .slab_kib = try findKeyKb(contents, "Slab:"),
        .kernel_stack_kib = try findKeyKb(contents, "KernelStack:"),
        .page_tables_kib = try findKeyKb(contents, "PageTables:"),
    };
}

/// Reads `pid`'s memory. Fails with the open error when the process is gone
/// or its /proc files are not readable to this process, and with
/// `error.ProcKeyNotFound` when a key is missing.
pub fn readProcess(allocator: std.mem.Allocator, pid: u32) !Metrics {
    const status = try readProcFile(allocator, pid, "status");
    defer allocator.free(status);
    const rollup = try readProcFile(allocator, pid, "smaps_rollup");
    defer allocator.free(rollup);
    return .{
        .rss_kib = try findKeyKb(status, "VmRSS:"),
        .pss_kib = try findKeyKb(rollup, "Pss:"),
        .private_dirty_kib = try findKeyKb(rollup, "Private_Dirty:"),
        .shared_clean_kib = try findKeyKb(rollup, "Shared_Clean:"),
    };
}

fn readProcFile(allocator: std.mem.Allocator, pid: u32, name: []const u8) ![]u8 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/{s}", .{ pid, name });
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, proc_file_max_bytes);
}

/// `key` carries its colon (`Pss:`), which is what keeps `Pss_Anon:` and the
/// other prefixed rollup lines from matching it.
fn findKeyKb(contents: []const u8, key: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key))
            continue;
        var fields = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        const value = fields.next() orelse return error.InvalidProcLine;
        return std.fmt.parseUnsigned(u64, value, 10);
    }
    return error.ProcKeyNotFound;
}
