//! Whether two versions of a file, or of a directory tree, differ only in
//! comments and whitespace. Zig is compared token by token through
//! `zig_lexer.CodeIterator`, which drops every comment, doc comments included.
//! C and C++ are compared as preprocessing tokens from `cpp_lexer`, where
//! whitespace counts only as the end of a directive and as the gap that makes
//! a macro object-like. Any other file must be byte-identical.
//!
//! Token positions are not compared, so values of `@src()` and `__LINE__` may
//! move. Macros are not expanded, so whitespace inside a stringified macro
//! argument is outside the proof. So is a Zig doc comment the compiler rejects,
//! such as one on a test, on a comptime block or after code on the same line:
//! the tokens still match, but the file no longer compiles.
const std = @import("std");
const cpp_lexer = @import("cpp_lexer.zig");
const zig_lexer = @import("zig_lexer.zig");
const source = @import("source.zig");

/// One side of the first difference.
pub const Side = struct {
    line: u32,
    what: What,

    pub const What = union(enum) {
        token: []const u8,
        directive_end,
        end_of_file,
        /// The line where two byte-compared files first differ.
        line_text: []const u8,
    };
};

pub const Difference = struct {
    before: Side,
    after: Side,
};

/// The first code difference between two sources, or null when they differ
/// only in comments and whitespace. A null language compares bytes. The text
/// in the result borrows `before` and `after`.
pub fn firstDifference(language: ?source.Language, before: [:0]const u8, after: [:0]const u8) ?Difference {
    const known = language orelse return firstByteDifference(before, after);
    return switch (known) {
        .zig => firstZigDifference(before, after),
        .c_family => firstCFamilyDifference(before, after),
    };
}

fn firstZigDifference(before: [:0]const u8, after: [:0]const u8) ?Difference {
    var before_tokens: zig_lexer.CodeIterator = .init(before);
    var after_tokens: zig_lexer.CodeIterator = .init(after);
    while (true) {
        const a = before_tokens.next();
        const b = after_tokens.next();
        const a_text = before[a.loc.start..a.loc.end];
        const b_text = after[b.loc.start..b.loc.end];
        if (a.tag != b.tag or !std.mem.eql(u8, a_text, b_text)) {
            return .{ .before = zigSide(before, a), .after = zigSide(after, b) };
        }
        if (a.tag == .eof) return null;
    }
}

fn zigSide(text: []const u8, token: std.zig.Token) Side {
    const line = lineOf(text, token.loc.start);
    if (token.tag == .eof) return .{ .line = line, .what = .end_of_file };
    return .{ .line = line, .what = .{ .token = text[token.loc.start..token.loc.end] } };
}

fn firstCFamilyDifference(before: [:0]const u8, after: [:0]const u8) ?Difference {
    var before_lexer: cpp_lexer.Lexer = .init(before);
    var after_lexer: cpp_lexer.Lexer = .init(after);
    while (true) {
        const a = before_lexer.nextCode();
        const b = after_lexer.nextCode();
        if (a.tag != b.tag or !cpp_lexer.spellingEql(before, a, after, b)) {
            return .{ .before = cFamilySide(before, a), .after = cFamilySide(after, b) };
        }
        if (a.tag == .eof) return null;
    }
}

fn cFamilySide(text: []const u8, token: cpp_lexer.Token) Side {
    return .{ .line = token.line, .what = switch (token.tag) {
        .eof => .end_of_file,
        .directive_end => .directive_end,
        else => .{ .token = text[token.start..token.end] },
    } };
}

fn firstByteDifference(before: []const u8, after: []const u8) ?Difference {
    const offset = std.mem.indexOfDiff(u8, before, after) orelse return null;
    return .{ .before = byteSide(before, offset), .after = byteSide(after, offset) };
}

fn byteSide(text: []const u8, offset: usize) Side {
    const line = lineOf(text, offset);
    if (offset >= text.len) return .{ .line = line, .what = .end_of_file };
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |newline| newline + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
    return .{ .line = line, .what = .{ .line_text = text[line_start..line_end] } };
}

fn lineOf(text: []const u8, offset: usize) u32 {
    return @intCast(1 + std.mem.count(u8, text[0..@min(offset, text.len)], "\n"));
}

pub const Summary = struct {
    /// Files present on both sides.
    compared: u32 = 0,
    /// Pairs that differ outside comments and whitespace.
    differing: u32 = 0,
    /// Files present on one side only.
    one_sided: u32 = 0,

    pub fn equivalent(summary: Summary) bool {
        return summary.differing == 0 and summary.one_sided == 0;
    }
};

/// Largest file either side may hold; anything bigger is not hand-written source.
pub const file_size_max = 64 * 1024 * 1024;

/// Compares two files and reports a difference under `label`. Paths whose
/// extensions name different languages differ without being read. Fails when
/// a file cannot be read or is larger than `file_size_max`.
pub fn compareFiles(
    gpa: std.mem.Allocator,
    label: []const u8,
    before_dir: std.fs.Dir,
    before_path: []const u8,
    after_dir: std.fs.Dir,
    after_path: []const u8,
    out: *std.Io.Writer,
) !Summary {
    var summary: Summary = .{ .compared = 1 };
    const before_language = source.languageOf(before_path);
    const after_language = source.languageOf(after_path);
    if (before_language != after_language) {
        try out.print("{s}: the two paths name different kinds of source\n", .{label});
        summary.differing = 1;
        return summary;
    }
    const before = try before_dir.readFileAllocOptions(gpa, before_path, file_size_max, null, .of(u8), 0);
    defer gpa.free(before);
    const after = try after_dir.readFileAllocOptions(gpa, after_path, file_size_max, null, .of(u8), 0);
    defer gpa.free(after);
    if (firstDifference(after_language, before, after)) |difference| {
        try writeDifference(out, label, difference);
        summary.differing = 1;
    }
    return summary;
}

/// Compares every file under `before` with the file at the same relative path
/// under `after`, reporting each pair that differs outside comments and every
/// file present on one side only. Two symbolic links match when their targets
/// do; any other kind of entry, or a file facing a link, differs. The first
/// file that cannot be read fails the whole comparison.
pub fn compareTrees(gpa: std.mem.Allocator, before: std.fs.Dir, after: std.fs.Dir, out: *std.Io.Writer) !Summary {
    const before_files = try source.listFiles(gpa, before);
    defer before_files.deinit(gpa);
    const after_files = try source.listFiles(gpa, after);
    defer after_files.deinit(gpa);

    var summary: Summary = .{};
    var before_index: usize = 0;
    var after_index: usize = 0;
    while (before_index < before_files.files.len or after_index < after_files.files.len) {
        const order = mergeOrder(before_files.files, before_index, after_files.files, after_index);
        switch (order) {
            .lt => {
                try out.print("{s}: only in before\n", .{before_files.files[before_index].path});
                summary.one_sided += 1;
                before_index += 1;
            },
            .gt => {
                try out.print("{s}: only in after\n", .{after_files.files[after_index].path});
                summary.one_sided += 1;
                after_index += 1;
            },
            .eq => {
                const before_file = before_files.files[before_index];
                const after_file = after_files.files[after_index];
                const pair = try comparePair(gpa, before, before_file, after, after_file, out);
                summary.compared += pair.compared;
                summary.differing += pair.differing;
                before_index += 1;
                after_index += 1;
            },
        }
    }
    return summary;
}

fn mergeOrder(before: []const source.File, before_index: usize, after: []const source.File, after_index: usize) std.math.Order {
    if (before_index == before.len) return .gt;
    if (after_index == after.len) return .lt;
    return std.mem.order(u8, before[before_index].path, after[after_index].path);
}

fn comparePair(
    gpa: std.mem.Allocator,
    before: std.fs.Dir,
    before_file: source.File,
    after: std.fs.Dir,
    after_file: source.File,
    out: *std.Io.Writer,
) !Summary {
    const path = after_file.path;
    if (before_file.kind == .file and after_file.kind == .file) {
        return compareFiles(gpa, path, before, path, after, path, out);
    }
    var summary: Summary = .{ .compared = 1 };
    if (before_file.kind == .sym_link and after_file.kind == .sym_link) {
        var before_target: [std.fs.max_path_bytes]u8 = undefined;
        var after_target: [std.fs.max_path_bytes]u8 = undefined;
        const before_link = try before.readLink(path, &before_target);
        const after_link = try after.readLink(path, &after_target);
        if (!std.mem.eql(u8, before_link, after_link)) {
            try out.print("{s}: symbolic link target changed from {s} to {s}\n", .{ path, before_link, after_link });
            summary.differing = 1;
        }
        return summary;
    }
    try out.print("{s}: {s} in before, {s} in after; only regular files and links are compared\n", .{
        path, @tagName(before_file.kind), @tagName(after_file.kind),
    });
    summary.differing = 1;
    return summary;
}

/// Longest excerpt of a token or line a report shows.
const excerpt_length_max = 80;

pub fn writeDifference(out: *std.Io.Writer, label: []const u8, difference: Difference) !void {
    try out.print("{s}: code differs\n", .{label});
    try writeSide(out, "before", difference.before);
    try writeSide(out, "after", difference.after);
}

fn writeSide(out: *std.Io.Writer, name: []const u8, side: Side) !void {
    try out.print("  {s}:{d}: ", .{ name, side.line });
    switch (side.what) {
        .token => |text| try writeExcerpt(out, text),
        .line_text => |text| try writeExcerpt(out, text),
        .directive_end => try out.writeAll("end of the preprocessor directive"),
        .end_of_file => try out.writeAll("end of file"),
    }
    try out.writeByte('\n');
}

fn writeExcerpt(out: *std.Io.Writer, text: []const u8) !void {
    const shown = text[0..@min(text.len, excerpt_length_max)];
    try out.writeByte('`');
    for (shown) |byte| {
        switch (byte) {
            '\n' => try out.writeAll("\\n"),
            '\t' => try out.writeAll("\\t"),
            '\r' => try out.writeAll("\\r"),
            else => try out.writeByte(byte),
        }
    }
    try out.writeByte('`');
    if (shown.len < text.len) try out.print(" ({d} more bytes)", .{text.len - shown.len});
}
