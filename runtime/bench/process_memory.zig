//! Prints the RSS, peak RSS and PSS of this process alone, read from
//! /proc/self. An RSS or PSS it cannot read, for any reason, prints as 0, and
//! an unreadable peak prints as the RSS. It starts no zygote or worker, so its
//! numbers say nothing about the runtime's memory; proc_memory.zig is the
//! reader that fails on a missing key.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const rss_kib = readProcKeyKb(allocator, "/proc/self/status", "VmRSS:") catch 0;
    const peak_rss_kib = readProcKeyKb(allocator, "/proc/self/status", "VmHWM:") catch rss_kib;
    const pss_kib = readProcKeyKb(allocator, "/proc/self/smaps_rollup", "Pss:") catch 0;

    std.debug.print(
        \\process_memory
        \\  process_model: server+zygote+workers placeholder
        \\  rss_kib: {d}
        \\  peak_rss_kib: {d}
        \\  pss_kib: {d}
        \\
    , .{ rss_kib, peak_rss_kib, pss_kib });
}

fn readProcKeyKb(allocator: std.mem.Allocator, path: []const u8, key: []const u8) !u64 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key))
            continue;
        var fields = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        const value = fields.next() orelse return error.InvalidProcStatus;
        return std.fmt.parseUnsigned(u64, value, 10);
    }
    return error.ProcKeyNotFound;
}
