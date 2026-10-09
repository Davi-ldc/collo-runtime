//! How `cpp_lexer` splits C and C++ source into comments and preprocessing
//! tokens: literals that hold comment delimiters, splices, directives, header
//! names, raw strings and the longest-match punctuators, checked token by token.
//! What the guard concludes from those tokens is covered in `equivalence.zig`
//! in the same lane, and comment counting by the provenance gate in
//! `runtime/tests/conventions.zig`.
const std = @import("std");
const comments = @import("collo_comments");
const cpp_lexer = comments.cpp_lexer;
const Tag = cpp_lexer.Token.Tag;

const Expected = struct {
    tag: Tag,
    text: []const u8,
};

/// Lexes `source` to the end and checks every token, comments included, by
/// tag and spelling.
fn expectTokens(source: []const u8, expected: []const Expected) !void {
    var lexer: cpp_lexer.Lexer = .init(source);
    for (expected, 0..) |want, index| {
        const token = lexer.next();
        const text = source[token.start..token.end];
        if (token.tag != want.tag or !std.mem.eql(u8, text, want.text)) {
            std.debug.print("token {d}: expected {s} `{s}`, got {s} `{s}`\n", .{
                index, @tagName(want.tag), want.text, @tagName(token.tag), text,
            });
            return error.TestUnexpectedToken;
        }
    }
    try std.testing.expectEqual(Tag.eof, lexer.next().tag);
}

test "comment markers inside string, character and raw string literals are code" {
    try expectTokens(
        \\auto a = "// not a comment"; auto b = '/'; auto c = R"x(/* still */ // code )" x)x";
    , &.{
        .{ .tag = .identifier, .text = "auto" },
        .{ .tag = .identifier, .text = "a" },
        .{ .tag = .punctuator, .text = "=" },
        .{ .tag = .string_literal, .text = "\"// not a comment\"" },
        .{ .tag = .punctuator, .text = ";" },
        .{ .tag = .identifier, .text = "auto" },
        .{ .tag = .identifier, .text = "b" },
        .{ .tag = .punctuator, .text = "=" },
        .{ .tag = .char_literal, .text = "'/'" },
        .{ .tag = .punctuator, .text = ";" },
        .{ .tag = .identifier, .text = "auto" },
        .{ .tag = .identifier, .text = "c" },
        .{ .tag = .punctuator, .text = "=" },
        .{ .tag = .string_literal, .text = "R\"x(/* still */ // code )\" x)x\"" },
        .{ .tag = .punctuator, .text = ";" },
    });
}

test "both comment forms are tokens and a block comment ignores line breaks" {
    try expectTokens("int a; // tail\n/* one\n * two */ int b;", &.{
        .{ .tag = .identifier, .text = "int" },
        .{ .tag = .identifier, .text = "a" },
        .{ .tag = .punctuator, .text = ";" },
        .{ .tag = .line_comment, .text = "// tail" },
        .{ .tag = .block_comment, .text = "/* one\n * two */" },
        .{ .tag = .identifier, .text = "int" },
        .{ .tag = .identifier, .text = "b" },
        .{ .tag = .punctuator, .text = ";" },
    });
}

test "a line comment ending in a splice swallows the next line" {
    try expectTokens("x; // tail \\\nhidden();\ny;", &.{
        .{ .tag = .identifier, .text = "x" },
        .{ .tag = .punctuator, .text = ";" },
        .{ .tag = .line_comment, .text = "// tail \\\nhidden();" },
        .{ .tag = .identifier, .text = "y" },
        .{ .tag = .punctuator, .text = ";" },
    });
}

test "a splice may separate the two bytes that close a block comment" {
    try expectTokens("/* a *\\\n/ b", &.{
        .{ .tag = .block_comment, .text = "/* a *\\\n/" },
        .{ .tag = .identifier, .text = "b" },
    });
}

test "an unterminated block comment runs to the end of the source" {
    try expectTokens("a /* open", &.{
        .{ .tag = .identifier, .text = "a" },
        .{ .tag = .block_comment, .text = "/* open" },
    });
}

test "directives end at their newline, and a splice continues them" {
    try expectTokens("#define A 1 \\\n  + 2\n#define F(x) x\n#define G (x)\nA", &.{
        .{ .tag = .punctuator, .text = "#" },
        .{ .tag = .identifier, .text = "define" },
        .{ .tag = .identifier, .text = "A" },
        .{ .tag = .number, .text = "1" },
        .{ .tag = .punctuator, .text = "+" },
        .{ .tag = .number, .text = "2" },
        .{ .tag = .directive_end, .text = "" },
        .{ .tag = .punctuator, .text = "#" },
        .{ .tag = .identifier, .text = "define" },
        .{ .tag = .identifier, .text = "F" },
        .{ .tag = .macro_parameters, .text = "(" },
        .{ .tag = .identifier, .text = "x" },
        .{ .tag = .punctuator, .text = ")" },
        .{ .tag = .identifier, .text = "x" },
        .{ .tag = .directive_end, .text = "" },
        .{ .tag = .punctuator, .text = "#" },
        .{ .tag = .identifier, .text = "define" },
        .{ .tag = .identifier, .text = "G" },
        .{ .tag = .punctuator, .text = "(" },
        .{ .tag = .identifier, .text = "x" },
        .{ .tag = .punctuator, .text = ")" },
        .{ .tag = .directive_end, .text = "" },
        .{ .tag = .identifier, .text = "A" },
    });
}

test "a hash after code on the same line does not open a directive" {
    try expectTokens("a # b\n  /* c */ # d\n", &.{
        .{ .tag = .identifier, .text = "a" },
        .{ .tag = .punctuator, .text = "#" },
        .{ .tag = .identifier, .text = "b" },
        .{ .tag = .block_comment, .text = "/* c */" },
        .{ .tag = .punctuator, .text = "#" },
        .{ .tag = .identifier, .text = "d" },
        .{ .tag = .directive_end, .text = "" },
    });
}

test "a header name is one token and holds no comment" {
    try expectTokens("#include <a//b.h>\n#include \"c.h\" // d", &.{
        .{ .tag = .punctuator, .text = "#" },
        .{ .tag = .identifier, .text = "include" },
        .{ .tag = .header_name, .text = "<a//b.h>" },
        .{ .tag = .directive_end, .text = "" },
        .{ .tag = .punctuator, .text = "#" },
        .{ .tag = .identifier, .text = "include" },
        .{ .tag = .string_literal, .text = "\"c.h\"" },
        .{ .tag = .line_comment, .text = "// d" },
        .{ .tag = .directive_end, .text = "" },
    });
}

test "numbers absorb digit separators, exponents and suffixes" {
    try expectTokens("1'000'000 0x1p-3 1.5e+10f .5 10_km", &.{
        .{ .tag = .number, .text = "1'000'000" },
        .{ .tag = .number, .text = "0x1p-3" },
        .{ .tag = .number, .text = "1.5e+10f" },
        .{ .tag = .number, .text = ".5" },
        .{ .tag = .number, .text = "10_km" },
    });
}

test "encoding prefixes and literal suffixes stay inside their literal" {
    try expectTokens("u8\"a\" L'b' u8R\"(c)\" \"d\"_s LR uR", &.{
        .{ .tag = .string_literal, .text = "u8\"a\"" },
        .{ .tag = .char_literal, .text = "L'b'" },
        .{ .tag = .string_literal, .text = "u8R\"(c)\"" },
        .{ .tag = .string_literal, .text = "\"d\"_s" },
        .{ .tag = .identifier, .text = "LR" },
        .{ .tag = .identifier, .text = "uR" },
    });
}

test "a raw string keeps the delimiter that closes it" {
    try expectTokens("R\"ab()\" )a\" )ab\" x", &.{
        .{ .tag = .string_literal, .text = "R\"ab()\" )a\" )ab\"" },
        .{ .tag = .identifier, .text = "x" },
    });
}

test "punctuators are the longest match, with the template exception for less-colon-colon" {
    try expectTokens("a->*b <=> c >>= d ... v<::T> w<:::> e<:f:>", &.{
        .{ .tag = .identifier, .text = "a" },
        .{ .tag = .punctuator, .text = "->*" },
        .{ .tag = .identifier, .text = "b" },
        .{ .tag = .punctuator, .text = "<=>" },
        .{ .tag = .identifier, .text = "c" },
        .{ .tag = .punctuator, .text = ">>=" },
        .{ .tag = .identifier, .text = "d" },
        .{ .tag = .punctuator, .text = "..." },
        .{ .tag = .identifier, .text = "v" },
        .{ .tag = .punctuator, .text = "<" },
        .{ .tag = .punctuator, .text = "::" },
        .{ .tag = .identifier, .text = "T" },
        .{ .tag = .punctuator, .text = ">" },
        .{ .tag = .identifier, .text = "w" },
        .{ .tag = .punctuator, .text = "<:" },
        .{ .tag = .punctuator, .text = "::" },
        .{ .tag = .punctuator, .text = ">" },
        .{ .tag = .identifier, .text = "e" },
        .{ .tag = .punctuator, .text = "<:" },
        .{ .tag = .identifier, .text = "f" },
        .{ .tag = .punctuator, .text = ":>" },
    });
}

test "a quote left open ends its token at the end of the line" {
    try expectTokens("#error don't // still the literal\nnext", &.{
        .{ .tag = .punctuator, .text = "#" },
        .{ .tag = .identifier, .text = "error" },
        .{ .tag = .identifier, .text = "don" },
        .{ .tag = .other, .text = "'t // still the literal" },
        .{ .tag = .directive_end, .text = "" },
        .{ .tag = .identifier, .text = "next" },
    });
}

test "tokens carry the line they start on" {
    const source = "a\n/* b\n c */ d \\\n e\n#x\n";
    var lexer: cpp_lexer.Lexer = .init(source);
    const lines = [_]u32{ 1, 2, 3, 4, 5, 5, 5 };
    for (lines) |line| try std.testing.expectEqual(line, lexer.next().line);
    try std.testing.expectEqual(Tag.eof, lexer.next().tag);
}

test "spellings compare equal across splices except inside raw strings" {
    const a_source = "ab \"xy\" R\"(z)\"";
    const b_source = "a\\\nb \"x\\\ny\" R\"(z)\"";
    var a_lexer: cpp_lexer.Lexer = .init(a_source);
    var b_lexer: cpp_lexer.Lexer = .init(b_source);
    for (0..3) |_| {
        const a = a_lexer.next();
        const b = b_lexer.next();
        try std.testing.expect(cpp_lexer.spellingEql(a_source, a, b_source, b));
    }

    const raw_a = "R\"(a\\\nb)\"";
    const raw_b = "R\"(ab)\"";
    var raw_a_lexer: cpp_lexer.Lexer = .init(raw_a);
    var raw_b_lexer: cpp_lexer.Lexer = .init(raw_b);
    try std.testing.expect(!cpp_lexer.spellingEql(raw_a, raw_a_lexer.next(), raw_b, raw_b_lexer.next()));
}
