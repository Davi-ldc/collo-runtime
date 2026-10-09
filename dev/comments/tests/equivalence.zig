//! Which Zig, C and C++ edits `equivalence` accepts as comment-only, where it
//! reports the first difference on each side, and how a tree comparison pairs
//! files by path. The command-line front end in `comment_guard.zig`, with its
//! argument handling and exit status, has no test in any lane.
const std = @import("std");
const comments = @import("collo_comments");
const equivalence = comments.equivalence;
const Language = comments.source.Language;

fn expectEquivalent(language: ?Language, before: [:0]const u8, after: [:0]const u8) !void {
    const difference = equivalence.firstDifference(language, before, after) orelse return;
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try equivalence.writeDifference(&out, "sample", difference);
    std.debug.print("{s}", .{out.buffered()});
    return error.TestUnexpectedDifference;
}

const Expected = struct {
    before_line: u32,
    before: []const u8,
    after_line: u32,
    after: []const u8,
};

/// `before` and `after` name the differing token on each side, or the
/// differing line when the files are compared byte by byte; "end of file" and
/// "end of directive" stand for the zero-width ends.
fn expectDifference(language: ?Language, before: [:0]const u8, after: [:0]const u8, expected: Expected) !void {
    const difference = equivalence.firstDifference(language, before, after) orelse {
        return error.TestExpectedDifference;
    };
    try std.testing.expectEqual(expected.before_line, difference.before.line);
    try std.testing.expectEqual(expected.after_line, difference.after.line);
    try std.testing.expectEqualStrings(expected.before, describe(difference.before));
    try std.testing.expectEqualStrings(expected.after, describe(difference.after));
}

fn describe(side: equivalence.Side) []const u8 {
    return switch (side.what) {
        .token, .line_text => |text| text,
        .directive_end => "end of directive",
        .end_of_file => "end of file",
    };
}

const zig_original =
    \\//! Ring of pending completions.
    \\const std = @import("std");
    \\
    \\/// Capacity in entries.
    \\pub const capacity = 64; // a power of two
    \\
    \\pub fn index(sequence: u64) u64 {
    \\    // Masking is exact because the capacity is a power of two.
    \\    return sequence & (capacity - 1);
    \\}
    \\
;

test "a Zig edit that only rewrites, adds, removes and reindents comments is equivalent" {
    try expectEquivalent(.zig, zig_original,
        \\//! Fixed ring of pending completions, indexed by sequence number.
        \\//! One owner thread.
        \\const std = @import("std");
        \\
        \\pub const capacity = 64;
        \\
        \\// The mask below needs a power-of-two capacity.
        \\pub fn index(sequence: u64) u64 {
        \\        return sequence & (capacity - 1); // wraps
        \\}
        \\
    );
}

test "a Zig doc comment rewrite is equivalent, including one turned into a plain comment" {
    try expectEquivalent(.zig, zig_original,
        \\//! Ring of pending completions.
        \\const std = @import("std");
        \\
        \\// Entries the ring holds; the index mask relies on this being a power of two.
        \\/// Capacity in entries.
        \\pub const capacity = 64; // a power of two
        \\
        \\/// Slot of `sequence` in the ring.
        \\pub fn index(sequence: u64) u64 {
        \\    // Masking is exact because the capacity is a power of two.
        \\    return sequence & (capacity - 1);
        \\}
        \\
    );
}

test "a changed Zig identifier differs, reported at its line on each side" {
    try expectDifference(.zig, zig_original,
        \\//! Ring of pending completions.
        \\//! Second header line.
        \\const std = @import("std");
        \\
        \\/// Capacity in entries.
        \\pub const capacity = 64; // a power of two
        \\
        \\pub fn index(seq: u64) u64 {
        \\    // Masking is exact because the capacity is a power of two.
        \\    return seq & (capacity - 1);
        \\}
        \\
    , .{ .before_line = 7, .before = "sequence", .after_line = 8, .after = "seq" });
}

test "a changed Zig operator differs" {
    try expectDifference(.zig, "const a = b + c;\n", "const a = b +% c; // wraps\n", .{
        .before_line = 1,
        .before = "+",
        .after_line = 1,
        .after = "+%",
    });
}

test "a changed Zig string literal differs, even when it reads like a comment" {
    try expectDifference(.zig, "const a = \"// keep\";\n", "const a = \"// kept\";\n", .{
        .before_line = 1,
        .before = "\"// keep\"",
        .after_line = 1,
        .after = "\"// kept\"",
    });
    try expectDifference(.zig, "const a =\n    \\\\// line\n;\n", "const a =\n    \\\\// lines\n;\n", .{
        .before_line = 2,
        .before = "\\\\// line",
        .after_line = 2,
        .after = "\\\\// lines",
    });
}

test "Zig code added at the end differs from the end of file" {
    try expectDifference(.zig, "const a = 1;\n// end\n", "const a = 1;\nconst b = 2;\n", .{
        .before_line = 3,
        .before = "end of file",
        .after_line = 2,
        .after = "const",
    });
}

test "a C++ edit inside a block comment is equivalent" {
    try expectEquivalent(.c_family,
        \\/* Owns the bridge's module table. */
        \\int table_size = 4; /* entries */
        \\
    ,
        \\/*
        \\ * Owns the module table of the bridge; the loader is its only writer.
        \\ */
        \\int table_size = 4;
        \\
    );
}

test "a C++ edit inside a line comment is equivalent, as is turning it into a block comment" {
    try expectEquivalent(.c_family,
        \\// Returns the cached value.
        \\int value() { return cached; } // fast path
        \\
    ,
        \\/* Returns the value computed at load time. */
        \\int value() { return cached; }
        \\
    );
}

test "C++ raw strings are code even when they hold comment delimiters" {
    // The opening delimiter inside the raw string must not start a comment; a
    // lexer that thought it did would hide the changed declaration after it.
    try expectDifference(.c_family,
        \\auto pattern = R"(/*)"; int before_name; /* note */
    ,
        \\auto pattern = R"(/*)"; int after_name; /* note */
    , .{ .before_line = 1, .before = "before_name", .after_line = 1, .after = "after_name" });

    try expectDifference(.c_family,
        \\auto text = R"js(// keep
        \\)js";
    ,
        \\auto text = R"js(// kept
        \\)js";
    , .{ .before_line = 1, .before = "R\"js(// keep\n)js\"", .after_line = 1, .after = "R\"js(// kept\n)js\"" });

    try expectEquivalent(.c_family,
        \\auto text = R"js(// keep */)js";
    ,
        \\auto text = R"js(// keep */)js"; // The script the loader evaluates first.
    );
}

test "C++ whitespace may change except where it ends a directive or makes a macro object-like" {
    try expectEquivalent(.c_family, "int x=a+b;\nif(x){f(x);}\n", "int x = a + b;\nif (x) {\n    f(x);\n}\n");

    try expectDifference(.c_family, "#define LIMIT 1\n+ 2;\n", "#define LIMIT 1 + 2;\n", .{
        .before_line = 1,
        .before = "end of directive",
        .after_line = 1,
        .after = "+",
    });

    try expectDifference(.c_family, "#define SQUARE(x) ((x) * (x))\n", "#define SQUARE (x) ((x) * (x))\n", .{
        .before_line = 1,
        .before = "(",
        .after_line = 1,
        .after = "(",
    });
}

test "a C++ comment that gains a trailing backslash swallows the next line and differs" {
    try expectDifference(.c_family, "// note\nint guard = 1;\n", "// note \\\nint guard = 1;\n", .{
        .before_line = 2,
        .before = "int",
        .after_line = 3,
        .after = "end of file",
    });
}

test "files no lexer understands must be byte-identical" {
    try expectEquivalent(null, "same\n", "same\n");
    try expectDifference(null, "a\nb\n", "a\nc\n", .{
        .before_line = 2,
        .before = "b",
        .after_line = 2,
        .after = "c",
    });
}

test "tree comparison pairs files by path and reports differences and one-sided files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const files = [_]struct { path: []const u8, text: []const u8 }{
        .{ .path = "before/same.zig", .text = "const a = 1; // old\n" },
        .{ .path = "after/same.zig", .text = "// new\nconst a = 1;\n" },
        .{ .path = "before/sub/deep.cpp", .text = "int b; /* old */\n" },
        .{ .path = "after/sub/deep.cpp", .text = "int b; // new\n" },
        .{ .path = "before/changed.h", .text = "int c;\n" },
        .{ .path = "after/changed.h", .text = "long c;\n" },
        .{ .path = "before/notes.md", .text = "unchanged\n" },
        .{ .path = "after/notes.md", .text = "unchanged\n" },
        .{ .path = "before/gone.zig", .text = "const d = 1;\n" },
        .{ .path = "after/new.zig", .text = "const e = 1;\n" },
        .{ .path = "after/.zig-cache/ignored.zig", .text = "const f = 1;\n" },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try tmp.dir.makePath(parent);
        try tmp.dir.writeFile(.{ .sub_path = file.path, .data = file.text });
    }
    var before = try tmp.dir.openDir("before", .{ .iterate = true });
    defer before.close();
    var after = try tmp.dir.openDir("after", .{ .iterate = true });
    defer after.close();

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    const summary = try equivalence.compareTrees(std.testing.allocator, before, after, &report.writer);

    try std.testing.expectEqual(@as(u32, 4), summary.compared);
    try std.testing.expectEqual(@as(u32, 1), summary.differing);
    try std.testing.expectEqual(@as(u32, 2), summary.one_sided);
    try std.testing.expect(!summary.equivalent());
    try std.testing.expectEqualStrings(
        \\changed.h: code differs
        \\  before:1: `int`
        \\  after:1: `long`
        \\gone.zig: only in before
        \\new.zig: only in after
        \\
    , report.written());
}
