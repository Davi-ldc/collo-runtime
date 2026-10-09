//! `comment-guard <before> <after>` exits 0 when `after` differs from
//! `before` only in comments and whitespace. Both arguments are files, or both
//! are directories compared file by file at matching relative paths, skipping
//! the directories `source.isSkippedDirectory` names. The rules per language
//! are in `equivalence.zig`. It runs as its own single-threaded process on the
//! build host and never writes to either side.
//!
//! Exit status: 0 when everything matches, 1 when a pair differs or a file
//! exists on one side only, 2 when the comparison could not run: bad usage,
//! unreadable input or exhausted memory.
const std = @import("std");
const comments = @import("root.zig");

const usage =
    \\usage: comment-guard <before> <after>
    \\  Both paths are files, or both are directories. Exits 0 when every pair
    \\  of files differs only in comments and whitespace.
    \\
;

const Status = enum(u8) {
    equivalent = 0,
    different = 1,
    failed = 2,
};

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;
    const status = try run(gpa, args, out);
    try out.flush();
    return @intFromEnum(status);
}

fn run(gpa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !Status {
    if (args.len != 3) {
        try out.writeAll(usage);
        return .failed;
    }
    const before_path = args[1];
    const after_path = args[2];
    const cwd = std.fs.cwd();
    const before_stat = cwd.statFile(before_path) catch |err| return failed(out, before_path, err);
    const after_stat = cwd.statFile(after_path) catch |err| return failed(out, after_path, err);
    const before_is_directory = before_stat.kind == .directory;
    const after_is_directory = after_stat.kind == .directory;
    if (before_is_directory != after_is_directory) {
        try out.print("{s} and {s} must both be files or both be directories\n", .{ before_path, after_path });
        return .failed;
    }

    const summary = if (before_is_directory) summary: {
        var before = cwd.openDir(before_path, .{ .iterate = true }) catch |err| return failed(out, before_path, err);
        defer before.close();
        var after = cwd.openDir(after_path, .{ .iterate = true }) catch |err| return failed(out, after_path, err);
        defer after.close();
        break :summary comments.equivalence.compareTrees(gpa, before, after, out) catch |err| {
            return failed(out, after_path, err);
        };
    } else comments.equivalence.compareFiles(gpa, after_path, cwd, before_path, cwd, after_path, out) catch |err| {
        return failed(out, after_path, err);
    };

    try out.print("{d} files compared, {d} differ outside comments, {d} on one side only\n", .{
        summary.compared, summary.differing, summary.one_sided,
    });
    return if (summary.equivalent()) .equivalent else .different;
}

fn failed(out: *std.Io.Writer, path: []const u8, err: anyerror) !Status {
    try out.print("{s}: cannot compare: {s}\n", .{ path, @errorName(err) });
    return .failed;
}
