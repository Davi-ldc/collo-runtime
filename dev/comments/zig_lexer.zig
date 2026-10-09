//! Comments and code tokens of Zig source, read with `std.zig.Tokenizer`. The
//! tokenizer skips `//` comments like whitespace and returns `///` and `//!`
//! as doc comment tokens, so the bytes between two tokens are whitespace and
//! plain comments only. A comment holding a byte the tokenizer rejects, such as
//! a tab, comes back as an `invalid` token that starts with `//`; it is a
//! comment here too, and the compiler reports it on its own.
const std = @import("std");

pub const Comment = struct {
    start: usize,
    end: usize,
};

/// Plain, doc and container doc comments in source order.
pub const CommentIterator = struct {
    source: [:0]const u8,
    tokenizer: std.zig.Tokenizer,
    /// Plain comments are searched for in `source[gap_start..gap_end]`, the
    /// bytes before `gap_token`.
    gap_start: usize,
    gap_end: usize,
    /// Null once the gap before the end of file is the last one left.
    gap_token: ?std.zig.Token,

    pub fn init(source: [:0]const u8) CommentIterator {
        var it: CommentIterator = .{
            .source = source,
            .tokenizer = .init(source),
            .gap_start = 0,
            .gap_end = 0,
            .gap_token = null,
        };
        it.openGapAfter(0);
        return it;
    }

    pub fn next(it: *CommentIterator) ?Comment {
        while (true) {
            const gap = it.source[0..it.gap_end];
            if (std.mem.indexOfPos(u8, gap, it.gap_start, "//")) |start| {
                const end = std.mem.indexOfScalarPos(u8, gap, start, '\n') orelse gap.len;
                it.gap_start = end;
                return .{ .start = start, .end = end };
            }
            const token = it.gap_token orelse return null;
            it.openGapAfter(token.loc.end);
            if (isComment(it.source, token)) return .{ .start = token.loc.start, .end = token.loc.end };
        }
    }

    fn openGapAfter(it: *CommentIterator, previous_end: usize) void {
        const token = it.tokenizer.next();
        it.gap_start = previous_end;
        it.gap_end = token.loc.start;
        it.gap_token = if (token.tag == .eof) null else token;
    }
};

/// Every token that is not a comment, ending with `eof`.
pub const CodeIterator = struct {
    source: [:0]const u8,
    tokenizer: std.zig.Tokenizer,

    pub fn init(source: [:0]const u8) CodeIterator {
        return .{ .source = source, .tokenizer = .init(source) };
    }

    pub fn next(it: *CodeIterator) std.zig.Token {
        while (true) {
            const token = it.tokenizer.next();
            if (!isComment(it.source, token)) return token;
        }
    }
};

fn isComment(source: []const u8, token: std.zig.Token) bool {
    return switch (token.tag) {
        .doc_comment, .container_doc_comment => true,
        .invalid => std.mem.startsWith(u8, source[token.loc.start..token.loc.end], "//"),
        else => false,
    };
}
