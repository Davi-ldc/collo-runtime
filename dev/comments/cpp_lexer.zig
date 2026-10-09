//! Lexer for C and C++ preprocessing tokens, for tools that must tell comments
//! from code without compiling anything. It follows translation phases 1 to 3:
//! a backslash-newline splice joins lines everywhere except inside a raw string
//! literal, every comment is a token of its own, and a newline matters only
//! where it ends a preprocessing directive, which the lexer reports as a
//! zero-width `directive_end` token. Trigraphs are not replaced, as in C++17
//! and in the GNU dialects of C, so `??/` before a newline is not a splice
//! here; under a strict ISO C mode such as `-std=c99` the compiler would read
//! one. Macros are not expanded and includes are not read, so the tokens of a
//! file depend on that file alone.
//!
//! A token's span is its byte range in the source, splices included;
//! `spellingEql` compares two spellings the way the compiler sees them.
const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,
    /// One-based line of `start`.
    line: u32,

    pub const Tag = enum {
        identifier,
        /// A preprocessing number, which also absorbs suffixes, exponents and
        /// digit separators.
        number,
        /// A string literal, raw or not, with its encoding prefix and any
        /// user-defined suffix.
        string_literal,
        /// A character literal with its encoding prefix and any user-defined
        /// suffix.
        char_literal,
        /// `<...>` after `#include`, `#include_next` or `#import`. Nothing
        /// inside it starts a comment.
        header_name,
        punctuator,
        /// The `(` written directly after the name in `#define`, which makes the
        /// macro function-like. With whitespace before it, the same byte opens
        /// an object-like macro's replacement list instead.
        macro_parameters,
        line_comment,
        block_comment,
        /// Zero-width, at the newline or end of file that ends a preprocessing
        /// directive.
        directive_end,
        /// A byte no other rule accepts, a literal whose line ends before its
        /// closing quote, or a raw string literal that never closes, which
        /// runs to the end of the source.
        other,
        eof,

        pub fn isComment(tag: Tag) bool {
            return tag == .line_comment or tag == .block_comment;
        }
    };
};

/// Longest first, so the first entry that matches is the maximal munch.
const punctuators = [_][]const u8{
    "%:%:",
    "<=>",
    "<<=",
    ">>=",
    "...",
    "->*",
    "->",
    "++",
    "--",
    "<<",
    ">>",
    "<=",
    ">=",
    "==",
    "!=",
    "&&",
    "||",
    "*=",
    "/=",
    "%=",
    "+=",
    "-=",
    "&=",
    "|=",
    "^=",
    "##",
    "::",
    ".*",
    "<:",
    ":>",
    "<%",
    "%>",
    "%:",
    "{",
    "}",
    "[",
    "]",
    "(",
    ")",
    ";",
    ":",
    "?",
    ".",
    "~",
    "!",
    "+",
    "-",
    "*",
    "/",
    "%",
    "^",
    "&",
    "|",
    "=",
    "<",
    ">",
    ",",
    "#",
};

const punctuator_length_max = 4;

/// The standard caps a raw string delimiter at 16 characters.
const raw_delimiter_length_max = 16;

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    /// Only whitespace and comments precede `index` on its logical line, so a
    /// `#` here opens a directive.
    at_line_start: bool = true,
    in_directive: bool = false,
    directive_step: DirectiveStep = .body,
    line: u32 = 1,
    line_counted_to: usize = 0,

    /// Where the lexer stands inside a directive, for the two places where a
    /// directive changes how bytes lex: a header name after an include, and
    /// the parameter list of a function-like macro.
    const DirectiveStep = enum {
        /// Just after the `#`.
        name,
        /// After `include`, `include_next` or `import`.
        header,
        /// After `define`.
        macro_name,
        /// After a macro name written directly before `(`.
        macro_parameters,
        /// Past every position-dependent token.
        body,
    };

    const Char = struct {
        byte: u8,
        at: usize,
        next: usize,
    };

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    /// Returns `eof` forever once the source is exhausted.
    pub fn next(lexer: *Lexer) Token {
        while (lexer.peek(lexer.index)) |char| {
            switch (char.byte) {
                ' ', '\t', '\r', 0x0b, 0x0c => lexer.index = char.next,
                '\n' => {
                    lexer.index = char.next;
                    lexer.at_line_start = true;
                    if (lexer.in_directive) {
                        lexer.in_directive = false;
                        return lexer.token(.directive_end, char.at, char.at);
                    }
                },
                else => return lexer.lexToken(char),
            }
        }
        lexer.index = lexer.source.len;
        if (lexer.in_directive) {
            lexer.in_directive = false;
            return lexer.token(.directive_end, lexer.source.len, lexer.source.len);
        }
        return lexer.token(.eof, lexer.source.len, lexer.source.len);
    }

    /// The next token that is not a comment.
    pub fn nextCode(lexer: *Lexer) Token {
        while (true) {
            const result = lexer.next();
            if (!result.tag.isComment()) return result;
        }
    }

    fn lexToken(lexer: *Lexer, first: Char) Token {
        const start = first.at;
        switch (first.byte) {
            '/' => {
                if (lexer.peek(first.next)) |second| {
                    if (second.byte == '/') return lexer.lineComment(start, second.next);
                    if (second.byte == '*') return lexer.blockComment(start, second.next);
                }
                return lexer.punctuatorOrOther(first);
            },
            '"' => return lexer.quotedLiteral(.string_literal, start, first.next, '"'),
            '\'' => return lexer.quotedLiteral(.char_literal, start, first.next, '\''),
            '0'...'9' => return lexer.code(.number, start, lexer.numberEnd(first.next)),
            '.' => {
                if (lexer.peek(first.next)) |second| {
                    if (isDigit(second.byte)) return lexer.code(.number, start, lexer.numberEnd(second.next));
                }
                return lexer.punctuatorOrOther(first);
            },
            '<' => {
                if (lexer.in_directive and lexer.directive_step == .header) {
                    if (lexer.headerNameEnd(first.next)) |end| return lexer.code(.header_name, start, end);
                }
                return lexer.punctuatorOrOther(first);
            },
            else => {
                if (isIdentifierStart(first.byte)) return lexer.identifierOrPrefixedLiteral(start, first.next);
                return lexer.punctuatorOrOther(first);
            },
        }
    }

    fn lineComment(lexer: *Lexer, start: usize, after_slashes: usize) Token {
        var end = after_slashes;
        while (lexer.peek(end)) |char| {
            if (char.byte == '\n') break;
            end = char.next;
        }
        lexer.index = end;
        return lexer.token(.line_comment, start, end);
    }

    /// An unterminated block comment runs to the end of the source.
    fn blockComment(lexer: *Lexer, start: usize, after_opening: usize) Token {
        var cursor = after_opening;
        while (lexer.peek(cursor)) |char| {
            cursor = char.next;
            if (char.byte != '*') continue;
            const closing = lexer.peek(cursor) orelse break;
            if (closing.byte == '/') {
                lexer.index = closing.next;
                return lexer.token(.block_comment, start, closing.next);
            }
        }
        lexer.index = lexer.source.len;
        return lexer.token(.block_comment, start, lexer.source.len);
    }

    fn quotedLiteral(lexer: *Lexer, tag: Token.Tag, start: usize, after_quote: usize, quote: u8) Token {
        var cursor = after_quote;
        while (lexer.peek(cursor)) |char| {
            switch (char.byte) {
                '\n' => return lexer.code(.other, start, char.at),
                '\\' => {
                    const escaped = lexer.peek(char.next) orelse break;
                    if (escaped.byte == '\n') return lexer.code(.other, start, escaped.at);
                    cursor = escaped.next;
                },
                else => {
                    cursor = char.next;
                    if (char.byte == quote) return lexer.code(tag, start, lexer.suffixEnd(cursor));
                },
            }
        }
        return lexer.code(.other, start, lexer.source.len);
    }

    /// `quote_at` is the opening `"`. The delimiter and body are raw bytes:
    /// splices inside a raw string literal are part of its value.
    fn rawStringLiteral(lexer: *Lexer, start: usize, quote_at: usize) Token {
        const source = lexer.source;
        const delimiter_start = quote_at + 1;
        var open = delimiter_start;
        while (true) : (open += 1) {
            // Not a raw string after all: lex what follows the quote as an
            // ordinary literal, which is how the compiler recovers too.
            if (open >= source.len or open - delimiter_start > raw_delimiter_length_max) {
                return lexer.quotedLiteral(.string_literal, start, delimiter_start, '"');
            }
            switch (source[open]) {
                '(' => break,
                ' ', ')', '\\', '\t', '\r', '\n', 0x0b, 0x0c, '"' => {
                    return lexer.quotedLiteral(.string_literal, start, delimiter_start, '"');
                },
                else => {},
            }
        }
        const delimiter = source[delimiter_start..open];
        var search = open + 1;
        while (std.mem.indexOfScalarPos(u8, source, search, ')')) |close| {
            const delimiter_end = close + 1 + delimiter.len;
            if (delimiter_end < source.len and
                std.mem.eql(u8, source[close + 1 .. delimiter_end], delimiter) and
                source[delimiter_end] == '"')
            {
                return lexer.code(.string_literal, start, lexer.suffixEnd(delimiter_end + 1));
            }
            search = close + 1;
        }
        return lexer.code(.other, start, source.len);
    }

    fn identifierOrPrefixedLiteral(lexer: *Lexer, start: usize, after_first: usize) Token {
        const end = lexer.identifierEnd(after_first);
        if (lexer.peek(end)) |char| {
            const prefix = encodingPrefix(lexer.source[start..end]);
            switch (char.byte) {
                '"' => switch (prefix) {
                    .plain => return lexer.quotedLiteral(.string_literal, start, char.next, '"'),
                    .raw => return lexer.rawStringLiteral(start, char.at),
                    .none => {},
                },
                '\'' => {
                    if (prefix == .plain) return lexer.quotedLiteral(.char_literal, start, char.next, '\'');
                },
                else => {},
            }
        }
        return lexer.code(.identifier, start, end);
    }

    fn identifierEnd(lexer: *const Lexer, after_first: usize) usize {
        var end = after_first;
        while (lexer.peek(end)) |char| {
            if (!isIdentifierContinue(char.byte)) break;
            end = char.next;
        }
        return end;
    }

    /// A user-defined literal suffix belongs to its literal: `"x"_s` and
    /// `"x" _s` are different programs.
    fn suffixEnd(lexer: *const Lexer, after_literal: usize) usize {
        const char = lexer.peek(after_literal) orelse return after_literal;
        if (!isIdentifierStart(char.byte)) return after_literal;
        return lexer.identifierEnd(char.next);
    }

    fn numberEnd(lexer: *const Lexer, after_first: usize) usize {
        var end = after_first;
        while (lexer.peek(end)) |char| {
            switch (char.byte) {
                'e', 'E', 'p', 'P' => {
                    end = char.next;
                    const sign = lexer.peek(end) orelse break;
                    if (sign.byte == '+' or sign.byte == '-') end = sign.next;
                },
                '.' => end = char.next,
                '\'' => {
                    const digit = lexer.peek(char.next) orelse break;
                    if (!isIdentifierContinue(digit.byte)) break;
                    end = digit.next;
                },
                else => {
                    if (!isIdentifierContinue(char.byte)) break;
                    end = char.next;
                },
            }
        }
        return end;
    }

    fn headerNameEnd(lexer: *const Lexer, after_open: usize) ?usize {
        var cursor = after_open;
        while (lexer.peek(cursor)) |char| {
            cursor = char.next;
            switch (char.byte) {
                '>' => return cursor,
                '\n' => return null,
                else => {},
            }
        }
        return null;
    }

    fn punctuatorOrOther(lexer: *Lexer, first: Char) Token {
        var window: [punctuator_length_max]u8 = undefined;
        var ends: [punctuator_length_max]usize = undefined;
        var count: usize = 0;
        var cursor = first.at;
        while (count < punctuator_length_max) : (count += 1) {
            const char = lexer.peek(cursor) orelse break;
            window[count] = char.byte;
            ends[count] = char.next;
            cursor = char.next;
        }
        for (punctuators) |punctuator| {
            if (punctuator.len > count) continue;
            if (!std.mem.eql(u8, punctuator, window[0..punctuator.len])) continue;
            // `<::` is `<` then `::` unless a third `:` or a `>` follows, so a
            // template argument may start with a qualified name.
            if (std.mem.eql(u8, punctuator, "<:") and count >= 3 and window[2] == ':') {
                const opens_digraph = count == 4 and (window[3] == ':' or window[3] == '>');
                if (!opens_digraph) return lexer.code(.punctuator, first.at, ends[0]);
            }
            const opens_parameters = punctuator[0] == '(' and
                lexer.in_directive and lexer.directive_step == .macro_parameters;
            const tag: Token.Tag = if (opens_parameters) .macro_parameters else .punctuator;
            return lexer.code(tag, first.at, ends[punctuator.len - 1]);
        }
        return lexer.code(.other, first.at, first.next);
    }

    /// Emits a token that is not a comment and advances the directive state.
    fn code(lexer: *Lexer, tag: Token.Tag, start: usize, end: usize) Token {
        lexer.index = end;
        const spelling = lexer.source[start..end];
        const opens_directive = tag == .punctuator and lexer.at_line_start and !lexer.in_directive and
            (std.mem.eql(u8, spelling, "#") or std.mem.eql(u8, spelling, "%:"));
        lexer.at_line_start = false;
        if (opens_directive) {
            lexer.in_directive = true;
            lexer.directive_step = .name;
        } else if (lexer.in_directive) {
            lexer.directive_step = lexer.stepAfter(tag, spelling, end);
        }
        return lexer.token(tag, start, end);
    }

    fn stepAfter(lexer: *const Lexer, tag: Token.Tag, spelling: []const u8, end: usize) DirectiveStep {
        if (tag != .identifier) return .body;
        switch (lexer.directive_step) {
            .name => {
                if (std.mem.eql(u8, spelling, "define")) return .macro_name;
                const includes = [_][]const u8{ "include", "include_next", "import" };
                for (includes) |include| {
                    if (std.mem.eql(u8, spelling, include)) return .header;
                }
                return .body;
            },
            .macro_name => {
                const char = lexer.peek(end) orelse return .body;
                return if (char.byte == '(') .macro_parameters else .body;
            },
            .header, .macro_parameters, .body => return .body,
        }
    }

    fn token(lexer: *Lexer, tag: Token.Tag, start: usize, end: usize) Token {
        std.debug.assert(start >= lexer.line_counted_to);
        std.debug.assert(end >= start);
        const newlines = std.mem.count(u8, lexer.source[lexer.line_counted_to..start], "\n");
        lexer.line += @intCast(newlines);
        lexer.line_counted_to = start;
        return .{ .tag = tag, .start = start, .end = end, .line = lexer.line };
    }

    /// The byte at `index` once splices are skipped, or null at the end.
    fn peek(lexer: *const Lexer, index: usize) ?Char {
        const at = skipSplices(lexer.source, index);
        if (at >= lexer.source.len) return null;
        return .{ .byte = lexer.source[at], .at = at, .next = at + 1 };
    }
};

/// Whether two tokens spell the same thing once splices are removed. A raw
/// string literal keeps its splices, as the compiler does.
pub fn spellingEql(a_source: []const u8, a: Token, b_source: []const u8, b: Token) bool {
    const a_text = a_source[a.start..a.end];
    const b_text = b_source[b.start..b.end];
    if (std.mem.eql(u8, a_text, b_text)) return true;
    if (isRawStringLiteral(a_text) or isRawStringLiteral(b_text)) return false;
    var a_cursor: usize = 0;
    var b_cursor: usize = 0;
    while (true) {
        a_cursor = skipSplices(a_text, a_cursor);
        b_cursor = skipSplices(b_text, b_cursor);
        const a_done = a_cursor == a_text.len;
        const b_done = b_cursor == b_text.len;
        if (a_done or b_done) return a_done and b_done;
        if (a_text[a_cursor] != b_text[b_cursor]) return false;
        a_cursor += 1;
        b_cursor += 1;
    }
}

fn isRawStringLiteral(text: []const u8) bool {
    const quote = std.mem.indexOfScalar(u8, text, '"') orelse return false;
    return quote > 0 and text[quote - 1] == 'R';
}

const EncodingPrefix = enum { none, plain, raw };

/// Prefixes are short, so a spelling broken by a splice is not one.
fn encodingPrefix(spelling: []const u8) EncodingPrefix {
    const plain = [_][]const u8{ "u8", "u", "U", "L" };
    const raw = [_][]const u8{ "R", "u8R", "uR", "UR", "LR" };
    for (plain) |prefix| {
        if (std.mem.eql(u8, spelling, prefix)) return .plain;
    }
    for (raw) |prefix| {
        if (std.mem.eql(u8, spelling, prefix)) return .raw;
    }
    return .none;
}

fn skipSplices(source: []const u8, index: usize) usize {
    var cursor = index;
    while (cursor < source.len) {
        const length = spliceLength(source, cursor);
        if (length == 0) break;
        cursor += length;
    }
    return cursor;
}

/// Length of the backslash-newline splice at `index`, or zero. Clang and GCC
/// accept horizontal whitespace between the backslash and the newline, so this
/// does too.
fn spliceLength(source: []const u8, index: usize) usize {
    if (source[index] != '\\') return 0;
    var cursor = index + 1;
    while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t')) cursor += 1;
    if (cursor < source.len and source[cursor] == '\n') return cursor + 1 - index;
    if (cursor + 1 < source.len and source[cursor] == '\r' and source[cursor + 1] == '\n') {
        return cursor + 2 - index;
    }
    return 0;
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

/// Bytes of a UTF-8 sequence count as identifier characters, as in Clang.
fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or isDigit(byte);
}
