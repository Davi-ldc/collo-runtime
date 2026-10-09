//! The COLLOFS1 fs index (`common/ipc/fs_index.zig`): path rules and their
//! cap, the builder's checks on its input, the placeholder, the round trip
//! through `IndexView`, and the parse that re-checks every invariant on bytes
//! the builder would refuse. A worker mapping and routing by the index is
//! covered by `worker/tests/fs_index.zig` and the zygote-integration lane.

const std = @import("std");
const ipc = @import("collo_ipc");

const fs_index = ipc.fs_index;
const File = fs_index.File;

fn file(path: []const u8) File {
    return .{ .path = path, .size = 1, .sha256 = @splat(0xaa) };
}

const two_files = [_]File{
    .{ .path = "data/users.json", .size = 42, .sha256 = @splat(0xaa) },
    .{ .path = "index.txt", .size = 7, .sha256 = @splat(0xbb) },
};

test "paths reject traversal, absolute paths, empty segments and forbidden bytes" {
    try fs_index.validatePath("data.json");
    try fs_index.validatePath("deep/dir/título.txt");
    try fs_index.validatePath(".collorc");

    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath(""));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("/etc/passwd"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("a//b"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("a/"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("./data.json"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("a/../b"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("a\\b"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("a\rb"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("a\nb"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("a\x00b"));
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath("a\xffb"));
}

test "a path at the path cap is accepted" {
    const path = "x" ** fs_index.path_bytes_max;
    try fs_index.validatePath(path);
}

test "a path one byte beyond the path cap is rejected" {
    const path = "x" ** (fs_index.path_bytes_max + 1);
    try std.testing.expectError(error.InvalidFsPath, fs_index.validatePath(path));
}

test "the builder refuses files out of strict byte order, and thereby duplicates" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.UnorderedFsIndex,
        fs_index.buildIndexBytes(allocator, 1, &.{ file("index.txt"), file("data.json") }),
    );
    try std.testing.expectError(
        error.UnorderedFsIndex,
        fs_index.buildIndexBytes(allocator, 1, &.{ file("data.json"), file("data.json") }),
    );
}

test "the builder refuses an invalid path" {
    try std.testing.expectError(
        error.InvalidFsPath,
        fs_index.buildIndexBytes(std.testing.allocator, 1, &.{file("../escape")}),
    );
}

test "the builder refuses a file that is also an ancestor directory" {
    const allocator = std.testing.allocator;
    const conflicts = comptime [_][]const File{
        &.{ file("a"), file("a/b") },
        // `!` (0x21) sorts between `a` and `a/`, so the conflicting pair is
        // not adjacent.
        &.{ file("a"), file("a!x"), file("a/b") },
        // The conflicting file is a nested ancestor.
        &.{ file("a/b"), file("a/b/c/d") },
        // Two ancestor relations at once, and the tail pair alone: the check
        // keeps the whole nested chain, not just the immediate parent.
        &.{ file("a"), file("a/b"), file("a/b/c") },
        &.{ file("a/b"), file("a/b/c") },
    };
    for (conflicts) |files| {
        try std.testing.expectError(
            error.FsIndexAncestorConflict,
            fs_index.buildIndexBytes(allocator, 1, files),
        );
    }

    // A byte prefix without a `/` boundary is no conflict, and neither is a
    // shared directory with no file at the fork.
    const prefix = try fs_index.buildIndexBytes(allocator, 1, &.{ file("ab"), file("abc") });
    defer allocator.free(prefix);
    try std.testing.expectEqual(@as(u32, 2), (try fs_index.IndexView.parse(prefix)).entry_count);
    const clean = try fs_index.buildIndexBytes(allocator, 1, &.{ file("a/b"), file("a/c") });
    defer allocator.free(clean);
    try std.testing.expectEqual(@as(u32, 2), (try fs_index.IndexView.parse(clean)).entry_count);
}

test "the builder refuses more files than the entry cap" {
    const allocator = std.testing.allocator;
    const files = try allocator.alloc(File, fs_index.entries_max + 1);
    defer allocator.free(files);
    // The cap is checked before any path, so the entries need no content.
    @memset(files, file("x"));
    try std.testing.expectError(
        error.TooManyFsIndexEntries,
        fs_index.buildIndexBytes(allocator, 1, files),
    );
}

test "an index round-trips its files and binary-searches by path" {
    const allocator = std.testing.allocator;
    const bytes = try fs_index.buildIndexBytes(allocator, 1_752_710_400_000, &two_files);
    defer allocator.free(bytes);

    try std.testing.expectEqual(
        fs_index.header_bytes + 2 * fs_index.entry_bytes + "data/users.json".len + "index.txt".len,
        bytes.len,
    );
    const view = try fs_index.IndexView.parse(bytes);
    try std.testing.expectEqual(@as(u32, 2), view.entry_count);
    try std.testing.expectEqual(@as(u64, 1_752_710_400_000), view.mtime_ms);

    const users = view.lookup("data/users.json").?;
    try std.testing.expectEqualStrings("data/users.json", view.entryPathAt(users));
    try std.testing.expectEqual(@as(u64, 42), view.entrySizeAt(users));
    try std.testing.expectEqual(@as(u8, 0xaa), view.entrySha256At(users)[0]);
    const index_txt = view.lookup("index.txt").?;
    try std.testing.expectEqual(@as(u64, 7), view.entrySizeAt(index_txt));
    try std.testing.expectEqual(@as(?usize, null), view.lookup("missing.txt"));
    try std.testing.expectEqual(@as(?usize, null), view.lookup(""));
    // Entries keep byte order, the binary search's precondition.
    try std.testing.expect(std.mem.order(u8, view.entryPathAt(0), view.entryPathAt(1)) == .lt);
}

test "the placeholder is the index of no files and a valid header-only index" {
    const allocator = std.testing.allocator;
    const bytes = try fs_index.buildIndexBytes(allocator, 0, &.{});
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &fs_index.placeholder_bytes, bytes);

    const view = try fs_index.IndexView.parse(&fs_index.placeholder_bytes);
    try std.testing.expectEqual(@as(u32, 0), view.entry_count);
    try std.testing.expectEqual(@as(?usize, null), view.lookup("anything"));
}

test "the placeholder memfd is sealed and holds the placeholder bytes" {
    const fd = try ipc.zygote_worker.createPlaceholderFsIndexMemfd();
    defer std.posix.close(fd);
    try @import("collo_os").fd.requireSeals(fd, @import("collo_os").fd.memfd_readonly_seals);
    var buffer: [fs_index.header_bytes + 1]u8 = undefined;
    const read_len = try std.posix.pread(fd, &buffer, 0);
    try std.testing.expectEqualSlices(u8, &fs_index.placeholder_bytes, buffer[0..read_len]);
}

test "parse rejects corrupted headers" {
    const allocator = std.testing.allocator;
    const bytes = try fs_index.buildIndexBytes(allocator, 1, &two_files);
    defer allocator.free(bytes);

    try std.testing.expectError(error.InvalidFsIndex, fs_index.IndexView.parse(bytes[0..8]));
    try std.testing.expectError(error.InvalidFsIndex, fs_index.IndexView.parse(bytes[0 .. bytes.len - 1]));

    const corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);
    corrupted[0] = 'X';
    try std.testing.expectError(error.InvalidFsIndex, fs_index.IndexView.parse(corrupted));
}

test "parse re-checks the path rules and the ancestor rule on bytes the builder refuses" {
    // The worker routes syscalls by the index, so the parse re-enforces every
    // invariant against a host that wrote bytes the builder would refuse.
    const allocator = std.testing.allocator;

    const bad_paths = [_][]const u8{ "../etc/passwd", "/abs", "a\xffb", "a//b" };
    for (bad_paths) |bad_path| {
        const bytes = try buildRawIndex(allocator, &.{bad_path});
        defer allocator.free(bytes);
        try std.testing.expectError(error.InvalidFsIndex, fs_index.IndexView.parse(bytes));
    }

    const conflicts = [_][]const []const u8{
        &.{ "a", "a!x", "a/b" },
        &.{ "a", "a/b", "a/b/c" },
        &.{ "a/b", "a/b/c" },
        // Out of order, then a duplicate.
        &.{ "b", "a" },
        &.{ "a", "a" },
    };
    for (conflicts) |paths| {
        const bytes = try buildRawIndex(allocator, paths);
        defer allocator.free(bytes);
        try std.testing.expectError(error.InvalidFsIndex, fs_index.IndexView.parse(bytes));
    }

    const legal = [_][]const []const u8{
        &.{ "ab", "abc" },
        &.{ "a!x", "a/b", "a/c" },
    };
    for (legal) |paths| {
        const bytes = try buildRawIndex(allocator, paths);
        defer allocator.free(bytes);
        const view = try fs_index.IndexView.parse(bytes);
        try std.testing.expectEqual(@as(u32, @intCast(paths.len)), view.entry_count);
    }
}

test "ancestor validation stays linear at the caps" {
    // A valid index at the entry cap with the deepest nesting and the longest
    // shared prefix the path cap allows. A check that compares every entry
    // against every ancestor takes minutes of CPU here, at every worker boot;
    // the prefix stack takes milliseconds. The test asserts no time: its
    // guard is that the suite finishes at all.
    const allocator = std.testing.allocator;

    // "d/" repeated, then "f#####", as deep as the path cap allows.
    const leaf_bytes = 6;
    const depth = (fs_index.path_bytes_max - leaf_bytes) / 2;
    const prefix_len = depth * 2;
    const paths = try allocator.alloc([]const u8, fs_index.entries_max);
    var built: usize = 0;
    defer {
        for (paths[0..built]) |path|
            allocator.free(path);
        allocator.free(paths);
    }
    for (0..fs_index.entries_max) |index| {
        const path = try allocator.alloc(u8, prefix_len + leaf_bytes);
        for (0..depth) |segment| {
            path[segment * 2] = 'd';
            path[segment * 2 + 1] = '/';
        }
        _ = std.fmt.bufPrint(path[prefix_len..], "f{d:0>5}", .{index}) catch unreachable;
        paths[built] = path;
        built += 1;
    }
    try std.testing.expect(paths[0].len <= fs_index.path_bytes_max);

    const bytes = try buildRawIndex(allocator, paths[0..built]);
    defer allocator.free(bytes);
    const view = try fs_index.IndexView.parse(bytes);
    try std.testing.expectEqual(@as(u32, fs_index.entries_max), view.entry_count);
    try std.testing.expect(view.lookup(paths[0]) != null);
}

/// Writes index bytes for paths without the builder's checks, field by
/// field as the layout in `fs_index.zig` defines them.
fn buildRawIndex(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    const entry_count: u32 = @intCast(paths.len);
    var string_table_len: u64 = 0;
    for (paths) |path|
        string_table_len += path.len;
    const entries_offset: u64 = fs_index.header_bytes;
    const string_table_offset: u64 = entries_offset + @as(u64, entry_count) * fs_index.entry_bytes;
    const total_bytes: u64 = string_table_offset + string_table_len;
    const bytes = try allocator.alloc(u8, @intCast(total_bytes));
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..8], &fs_index.magic);
    std.mem.writeInt(u32, bytes[8..12], fs_index.version, .little);
    std.mem.writeInt(u32, bytes[12..16], entry_count, .little);
    std.mem.writeInt(u64, bytes[16..24], 1, .little);
    std.mem.writeInt(u64, bytes[24..32], entries_offset, .little);
    std.mem.writeInt(u64, bytes[32..40], string_table_offset, .little);
    std.mem.writeInt(u64, bytes[40..48], total_bytes, .little);
    var path_offset: u32 = 0;
    var string_cursor: usize = @intCast(string_table_offset);
    for (paths, 0..) |path, index| {
        const entry_start: usize = @intCast(entries_offset + index * fs_index.entry_bytes);
        const entry = bytes[entry_start..][0..fs_index.entry_bytes];
        std.mem.writeInt(u32, entry[0..4], path_offset, .little);
        std.mem.writeInt(u32, entry[4..8], @intCast(path.len), .little);
        std.mem.writeInt(u64, entry[8..16], 1, .little);
        @memset(entry[16..48], 0xaa);
        @memcpy(bytes[string_cursor..][0..path.len], path);
        path_offset += @intCast(path.len);
        string_cursor += path.len;
    }
    return bytes;
}
