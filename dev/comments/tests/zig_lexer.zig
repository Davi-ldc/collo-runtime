//! How `zig_lexer` separates Zig comments from code tokens, including a
//! comment the tokenizer rejects. What the guard concludes from those tokens
//! is covered in `equivalence.zig` in the same lane, and comment counting by
//! the provenance gate in `runtime/tests/conventions.zig`.
const std = @import("std");
const comments = @import("collo_comments");
const zig_lexer = comments.zig_lexer;

fn expectComments(source: [:0]const u8, expected: []const []const u8) !void {
    var it: zig_lexer.CommentIterator = .init(source);
    for (expected) |want| {
        const comment = it.next() orelse {
            std.debug.print("missing comment `{s}`\n", .{want});
            return error.TestMissingComment;
        };
        try std.testing.expectEqualStrings(want, source[comment.start..comment.end]);
    }
    if (it.next()) |extra| {
        std.debug.print("unexpected comment `{s}`\n", .{source[extra.start..extra.end]});
        return error.TestUnexpectedComment;
    }
}

test "plain, doc and container doc comments come back in source order" {
    try expectComments(
        \\//! Module doc.
        \\const a = 1; // trailing
        \\/// Declaration doc.
        \\// plain
        \\//// four slashes are plain
        \\const b = 2;
        \\// last line without newline
    , &.{
        "//! Module doc.",
        "// trailing",
        "/// Declaration doc.",
        "// plain",
        "//// four slashes are plain",
        "// last line without newline",
    });
}

test "comment markers inside string literals are code" {
    try expectComments(
        \\const url = "https://example.com"; // real
        \\const text =
        \\    \\// inside a multiline string
        \\;
        \\const slash = '/';
    , &.{"// real"});
}

test "a comment holding a byte the tokenizer rejects is still a comment" {
    try expectComments("const a = 1; // tab\there\nconst b = 2;\n", &.{"// tab\there"});
}

test "code tokens skip every comment form" {
    const source =
        \\//! Doc.
        \\/// More doc.
        \\pub const a = 1; // plain
    ;
    var it: zig_lexer.CodeIterator = .init(source);
    const expected = [_][]const u8{ "pub", "const", "a", "=", "1", ";", "" };
    for (expected) |want| {
        const token = it.next();
        try std.testing.expectEqualStrings(want, source[token.loc.start..token.loc.end]);
    }
}
