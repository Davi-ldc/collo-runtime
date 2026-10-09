//! The imports of one ES module, found by a lexical scan of its source, so
//! the server can pack every module an entry may load at boot without an
//! engine in the server process.
//!
//! The scan reports, in source order, the specifier of two kinds of import.
//! A static import is a declaration that loads another module before the
//! importing one evaluates: `import x from "m"`, `import "m"`,
//! `export * from "m"`, `export * as ns from "m"` and
//! `export { a } from "m"`, with any import clause between `import` and
//! `from`. ES modules allow these only at the top level, so an `import` or
//! `export` nested in brackets, or written as a property after `.`, is not
//! one. A dynamic import is a call `import("m")` or `import.defer("m")` at
//! any depth whose first argument is a single string literal, followed by
//! `)` or by the `,` of an options argument. The scan reports nothing for any
//! other first argument, such as a name, a template literal or a
//! concatenation, whose value only exists at run time, nor for `import.meta`
//! or a call after `.`, which is a method named `import`.
//!
//! To see imports only where code is, the scan lexes strings, template
//! literals with their `${}` expressions, comments, regular expressions and
//! a leading `#!` line. A `/` starts a regular expression when the previous
//! token cannot end an expression: an operator, an opening bracket, `}`, a
//! keyword such as `return` (not a property of that name), or a `)` that
//! closes an `if`, `while`, `for` or `with` condition. A regular expression
//! that reaches the end of its line unclosed was a division after all, and
//! the scan reads the `/` as one. Code that defeats this heuristic, such as
//! a division right after an object literal's `}`, can make the scan miss an
//! import or report a literal as unterminated.
//!
//! A specifier is the literal's bytes between the quotes, never decoded. A
//! declaration whose specifier holds an escape sequence fails the scan, and
//! an import call whose literal holds one is not reported, like a computed
//! one. Pure function over borrowed bytes; any thread may call it.

const std = @import("std");
const module_pack = @import("collo_ipc").module_pack;

pub const Import = struct {
    /// Borrowed from the source.
    specifier: []const u8,
    /// 1-based line of the specifier.
    line: u32,
    kind: Kind,

    pub const Kind = enum {
        /// A declaration the module needs before it evaluates.
        static,
        /// A call the module may run while it executes.
        dynamic,
    };
};

/// What made a scan fail, and where.
pub const Failure = struct {
    reason: Reason,
    line: u32,

    pub const Reason = enum {
        unterminated_comment,
        unterminated_string,
        unterminated_template,
        malformed_declaration,
        escaped_specifier,
        too_many_imports,
        nesting_too_deep,

        pub fn describe(reason: Reason) []const u8 {
            return switch (reason) {
                .unterminated_comment => "unterminated /* comment",
                .unterminated_string => "unterminated string literal",
                .unterminated_template => "unterminated template literal",
                .malformed_declaration => "import or export declaration without a string specifier",
                .escaped_specifier => "escape sequences in the specifier of an import or export declaration are not supported",
                .too_many_imports => "more imports than a module pack can hold modules",
                .nesting_too_deep => "brackets nested deeper than the scanner follows",
            };
        }
    };
};

pub const ScanError = error{ OutOfMemory, InvalidModuleSource };

/// Imports one module may hold, static and dynamic together: a module that
/// imports more than a pack holds modules cannot be packed anyway.
pub const imports_max: usize = module_pack.max_module_count;

/// Brackets and template expressions the scan tracks at once.
pub const nesting_max: usize = 4096;

/// Appends the module's static and dynamic imports to `imports`. On
/// `error.InvalidModuleSource`, `failure` says why and where.
pub fn scan(
    gpa: std.mem.Allocator,
    source: []const u8,
    imports: *std.ArrayList(Import),
    failure: *Failure,
) ScanError!void {
    var lexer: Lexer = .{ .source = source };
    lexer.skipPreamble();
    while (true) {
        const token = lexer.next() catch return lexer.reportFailure(failure);
        switch (token.kind) {
            .eof => return,
            .identifier => {
                if (token.after_dot)
                    continue;
                const word = lexer.text(token);
                if (std.mem.eql(u8, word, "import")) {
                    const read = if (token.top_level)
                        lexer.readImport(gpa, imports)
                    else
                        lexer.readImportCall(gpa, imports);
                    read catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Lex => return lexer.reportFailure(failure),
                    };
                } else if (token.top_level and std.mem.eql(u8, word, "export")) {
                    lexer.readExport(gpa, imports) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Lex => return lexer.reportFailure(failure),
                    };
                }
            },
            .string, .template, .number, .regex, .punct => {},
        }
    }
}

const TokenKind = enum { eof, identifier, string, template, number, regex, punct };

const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
    line: u32,
    /// No bracket or template expression was open where the token starts.
    top_level: bool,
    /// The previous token was `.`.
    after_dot: bool,
};

const Nest = enum(u8) {
    paren,
    /// The parenthesized condition of `if`, `while`, `for` or `with`.
    paren_condition,
    bracket,
    brace,
    /// The `${` of a template literal.
    template,
};

const LexError = error{Lex};

/// The lexer state where a token starts.
const Opening = struct {
    start: usize,
    line: u32,
    top_level: bool,
    after_dot: bool,
    after_control_keyword: bool,
};

const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: u32 = 1,
    nests: [nesting_max]Nest = undefined,
    depth: usize = 0,
    regex_allowed: bool = true,
    after_dot: bool = false,
    after_control_keyword: bool = false,
    failure_reason: Failure.Reason = .malformed_declaration,
    failure_line: u32 = 0,

    fn reportFailure(self: *const Lexer, failure: *Failure) ScanError {
        failure.* = .{ .reason = self.failure_reason, .line = self.failure_line };
        return error.InvalidModuleSource;
    }

    fn fail(self: *Lexer, reason: Failure.Reason, line: u32) LexError {
        self.failure_reason = reason;
        self.failure_line = line;
        return error.Lex;
    }

    fn text(self: *const Lexer, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }

    /// A UTF-8 byte order mark, then a `#!` line, may open a module.
    fn skipPreamble(self: *Lexer) void {
        if (std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF"))
            self.index = 3;
        if (std.mem.startsWith(u8, self.source[self.index..], "#!")) {
            while (self.index < self.source.len and self.source[self.index] != '\n')
                self.index += 1;
        }
    }

    /// After a top-level `import`: `(` and `.` start an import call or
    /// `import.meta` (`readImportCall`); a string is a side-effect import;
    /// anything else is a clause that ends in `from "m"`.
    fn readImport(self: *Lexer, gpa: std.mem.Allocator, imports: *std.ArrayList(Import)) (LexError || error{OutOfMemory})!void {
        const following = self.peekByte() orelse return self.fail(.malformed_declaration, self.line);
        switch (following) {
            '(', '.' => return self.readImportCall(gpa, imports),
            '"', '\'' => {
                const specifier = try self.next();
                return self.record(gpa, imports, specifier, .static);
            },
            else => {},
        }
        while (true) {
            const token = try self.next();
            switch (token.kind) {
                .identifier => {
                    if (std.mem.eql(u8, self.text(token), "from") and self.peekQuote())
                        return self.record(gpa, imports, try self.next(), .static);
                },
                .string => {},
                .punct => switch (self.source[token.start]) {
                    '{', '}', ',', '*' => {},
                    else => return self.fail(.malformed_declaration, token.line),
                },
                .eof, .template, .number, .regex => return self.fail(.malformed_declaration, token.line),
            }
        }
    }

    /// After an `import` that starts no declaration: `(`, or `.defer` then
    /// `(`, opens an import call, recorded when a single string literal
    /// followed by `)` or `,` is its first argument. The main loop lexes
    /// everything after what this consumed, the arguments of a computed call
    /// and the rest of `import.meta` included.
    fn readImportCall(self: *Lexer, gpa: std.mem.Allocator, imports: *std.ArrayList(Import)) (LexError || error{OutOfMemory})!void {
        const following = self.peekByte() orelse return;
        if (following == '.') {
            _ = try self.next();
            if (!self.peekWord("defer"))
                return;
            _ = try self.next();
        }
        const open = self.peekByte() orelse return;
        if (open != '(')
            return;
        _ = try self.next();
        if (!self.peekQuote())
            return;
        const specifier = try self.next();
        const closing = self.peekByte() orelse return;
        if (closing != ')' and closing != ',')
            return;
        return self.record(gpa, imports, specifier, .dynamic);
    }

    /// After `export`: `*` must lead to `from "m"`; a `{...}` list re-exports
    /// only when `from "m"` follows it; any other export declares a local
    /// binding.
    fn readExport(self: *Lexer, gpa: std.mem.Allocator, imports: *std.ArrayList(Import)) (LexError || error{OutOfMemory})!void {
        const following = self.peekByte() orelse return;
        switch (following) {
            '*' => {
                _ = try self.next();
                while (true) {
                    const token = try self.next();
                    switch (token.kind) {
                        // `as` and the namespace name, until `from "m"`.
                        .identifier => {
                            if (std.mem.eql(u8, self.text(token), "from") and self.peekQuote())
                                return self.record(gpa, imports, try self.next(), .static);
                        },
                        // The name after `as` may be a string.
                        .string => {},
                        .eof, .template, .number, .regex, .punct => return self.fail(.malformed_declaration, token.line),
                    }
                }
            },
            '{' => {
                const open = try self.next();
                std.debug.assert(self.depth == 1);
                while (self.depth != 0) {
                    const token = try self.next();
                    if (token.kind == .eof)
                        return self.fail(.malformed_declaration, open.line);
                }
                if (!self.peekWord("from"))
                    return;
                _ = try self.next();
                if (!self.peekQuote())
                    return self.fail(.malformed_declaration, self.line);
                return self.record(gpa, imports, try self.next(), .static);
            },
            else => return,
        }
    }

    fn record(
        self: *Lexer,
        gpa: std.mem.Allocator,
        imports: *std.ArrayList(Import),
        token: Token,
        kind: Import.Kind,
    ) (LexError || error{OutOfMemory})!void {
        std.debug.assert(token.kind == .string);
        const specifier = self.source[token.start + 1 .. token.end - 1];
        if (std.mem.indexOfScalar(u8, specifier, '\\') != null) {
            // The module needs a declaration's target before it evaluates, so
            // one the scan cannot read fails it; an import call's target is
            // left to run time.
            switch (kind) {
                .static => return self.fail(.escaped_specifier, token.line),
                .dynamic => return,
            }
        }
        if (imports.items.len == imports_max)
            return self.fail(.too_many_imports, token.line);
        try imports.append(gpa, .{ .specifier = specifier, .line = token.line, .kind = kind });
    }

    fn peekQuote(self: *const Lexer) bool {
        const byte = self.peekByte() orelse return false;
        return byte == '"' or byte == '\'';
    }

    fn peekWord(self: *const Lexer, word: []const u8) bool {
        const position = self.peekIndex() orelse return false;
        if (!std.mem.startsWith(u8, self.source[position..], word))
            return false;
        const after = position + word.len;
        return after == self.source.len or !isIdentifierPart(self.source[after]);
    }

    fn peekByte(self: *const Lexer) ?u8 {
        const position = self.peekIndex() orelse return null;
        return self.source[position];
    }

    /// Where the next token starts, without consuming anything; null at the
    /// end of the source or inside an unterminated comment, which the next
    /// call to `next` reports.
    fn peekIndex(self: *const Lexer) ?usize {
        var position: Position = .{ .index = self.index, .line = self.line };
        skipTrivia(self.source, &position) catch return null;
        if (position.index == self.source.len)
            return null;
        return position.index;
    }

    fn next(self: *Lexer) LexError!Token {
        var position: Position = .{ .index = self.index, .line = self.line };
        skipTrivia(self.source, &position) catch |err| switch (err) {
            error.UnterminatedComment => return self.fail(.unterminated_comment, position.line),
        };
        self.index = position.index;
        self.line = position.line;
        const opening: Opening = .{
            .start = self.index,
            .line = self.line,
            .top_level = self.depth == 0,
            .after_dot = self.after_dot,
            .after_control_keyword = self.after_control_keyword,
        };
        self.after_dot = false;
        self.after_control_keyword = false;

        if (opening.start == self.source.len)
            return self.finish(.eof, opening);

        const byte = self.source[opening.start];
        if (byte == '"' or byte == '\'') {
            try self.scanString(byte);
            self.regex_allowed = false;
            return self.finish(.string, opening);
        }
        if (byte == '`') {
            self.index += 1;
            try self.scanTemplate(opening.line);
            return self.finish(.template, opening);
        }
        if (isIdentifierStart(byte)) {
            self.scanIdentifier();
            // After `.` a keyword is a property name and ends an operand.
            const word = self.source[opening.start..self.index];
            self.regex_allowed = !opening.after_dot and isExpressionKeyword(word);
            self.after_control_keyword = !opening.after_dot and isControlKeyword(word);
            return self.finish(.identifier, opening);
        }
        const next_is_digit = opening.start + 1 < self.source.len and isDigit(self.source[opening.start + 1]);
        if (isDigit(byte) or (byte == '.' and next_is_digit)) {
            self.scanNumber();
            self.regex_allowed = false;
            return self.finish(.number, opening);
        }
        if (byte == '/' and self.regex_allowed) {
            if (self.scanRegex()) {
                self.regex_allowed = false;
                return self.finish(.regex, opening);
            }
        }
        return self.punct(opening);
    }

    fn punct(self: *Lexer, opening: Opening) LexError!Token {
        const byte = self.source[opening.start];
        self.index = opening.start + 1;
        self.regex_allowed = true;
        switch (byte) {
            '(' => try self.push(if (opening.after_control_keyword) .paren_condition else .paren, opening.line),
            '[' => try self.push(.bracket, opening.line),
            '{' => try self.push(.brace, opening.line),
            ')' => self.regex_allowed = if (self.pop()) |nest| nest == .paren_condition else false,
            ']' => {
                _ = self.pop();
                self.regex_allowed = false;
            },
            '}' => {
                if (self.depth != 0 and self.nests[self.depth - 1] == .template) {
                    _ = self.pop();
                    try self.scanTemplate(opening.line);
                    return self.finish(.template, opening);
                }
                _ = self.pop();
            },
            '.' => self.after_dot = true,
            '+', '-' => {
                // `++` and `--` never precede a regular expression: postfix,
                // they end an operand; prefix, they need one.
                if (self.index < self.source.len and self.source[self.index] == byte) {
                    self.index += 1;
                    self.regex_allowed = false;
                }
            },
            else => {},
        }
        return self.finish(.punct, opening);
    }

    /// The token from `opening` to the current index.
    fn finish(self: *const Lexer, kind: TokenKind, opening: Opening) Token {
        return .{
            .kind = kind,
            .start = opening.start,
            .end = self.index,
            .line = opening.line,
            .top_level = opening.top_level,
            .after_dot = opening.after_dot,
        };
    }

    fn push(self: *Lexer, nest: Nest, line: u32) LexError!void {
        if (self.depth == nesting_max)
            return self.fail(.nesting_too_deep, line);
        self.nests[self.depth] = nest;
        self.depth += 1;
    }

    /// An unbalanced closer leaves the depth at zero; the engine reports the
    /// syntax error when the module loads.
    fn pop(self: *Lexer) ?Nest {
        if (self.depth == 0)
            return null;
        self.depth -= 1;
        return self.nests[self.depth];
    }

    fn scanString(self: *Lexer, quote: u8) LexError!void {
        const line = self.line;
        self.index += 1;
        while (self.index < self.source.len) {
            const byte = self.source[self.index];
            if (byte == quote) {
                self.index += 1;
                return;
            }
            switch (byte) {
                '\\' => {
                    // A backslash before a line break continues the string
                    // on the next line.
                    const rest = self.source[self.index + 1 ..];
                    if (std.mem.startsWith(u8, rest, "\r\n")) {
                        self.line += 1;
                        self.index += 3;
                    } else {
                        if (std.mem.startsWith(u8, rest, "\n"))
                            self.line += 1;
                        self.index += 2;
                    }
                },
                '\n' => return self.fail(.unterminated_string, line),
                else => self.index += 1,
            }
        }
        return self.fail(.unterminated_string, line);
    }

    /// Scans template text from the current index up to the closing
    /// backtick, or up to a `${`, which opens an expression the main loop
    /// lexes until its `}` resumes the template.
    fn scanTemplate(self: *Lexer, line: u32) LexError!void {
        while (self.index < self.source.len) {
            const byte = self.source[self.index];
            switch (byte) {
                '`' => {
                    self.index += 1;
                    self.regex_allowed = false;
                    return;
                },
                '\\' => {
                    if (self.index + 1 < self.source.len and self.source[self.index + 1] == '\n')
                        self.line += 1;
                    self.index += 2;
                },
                '\n' => {
                    self.line += 1;
                    self.index += 1;
                },
                '$' => {
                    if (self.index + 1 < self.source.len and self.source[self.index + 1] == '{') {
                        self.index += 2;
                        try self.push(.template, self.line);
                        self.regex_allowed = true;
                        return;
                    }
                    self.index += 1;
                },
                else => self.index += 1,
            }
        }
        return self.fail(.unterminated_template, line);
    }

    /// True when a regular expression closes on its line; otherwise the
    /// index is left on the `/` and the caller reads it as division.
    fn scanRegex(self: *Lexer) bool {
        const start = self.index;
        var index = start + 1;
        var in_class = false;
        while (index < self.source.len) {
            const byte = self.source[index];
            switch (byte) {
                '\n', '\r' => break,
                '\\' => {
                    if (index + 1 < self.source.len and self.source[index + 1] == '\n')
                        break;
                    index += 2;
                    continue;
                },
                '[' => in_class = true,
                ']' => in_class = false,
                '/' => if (!in_class) {
                    index += 1;
                    while (index < self.source.len and isIdentifierPart(self.source[index]))
                        index += 1;
                    self.index = index;
                    return true;
                },
                else => {},
            }
            index += 1;
        }
        self.index = start;
        return false;
    }

    fn scanIdentifier(self: *Lexer) void {
        // The first byte may be `#` (a private name) or `\` (an escape).
        if (self.source[self.index] == '\\')
            self.index += 1;
        self.index += 1;
        while (self.index < self.source.len) {
            const byte = self.source[self.index];
            if (byte == '\\') {
                self.index += 2;
                continue;
            }
            if (!isIdentifierPart(byte))
                break;
            self.index += 1;
        }
        self.index = @min(self.index, self.source.len);
    }

    fn scanNumber(self: *Lexer) void {
        const start = self.index;
        const hex = std.mem.startsWith(u8, self.source[start..], "0x") or std.mem.startsWith(u8, self.source[start..], "0X");
        self.index += 1;
        while (self.index < self.source.len) {
            const byte = self.source[self.index];
            if (isIdentifierPart(byte) or byte == '.') {
                self.index += 1;
                continue;
            }
            const previous = self.source[self.index - 1];
            if ((byte == '+' or byte == '-') and !hex and (previous == 'e' or previous == 'E')) {
                self.index += 1;
                continue;
            }
            break;
        }
    }
};

const Position = struct {
    index: usize,
    line: u32,
};

/// Moves `position` past whitespace and comments to the next token. On
/// `error.UnterminatedComment` it is left on the comment's opening.
fn skipTrivia(source: []const u8, position: *Position) error{UnterminatedComment}!void {
    while (position.index < source.len) {
        switch (source[position.index]) {
            '\n' => {
                position.line += 1;
                position.index += 1;
            },
            ' ', '\t', '\r', 0x0b, 0x0c => position.index += 1,
            '/' => {
                if (position.index + 1 == source.len)
                    return;
                switch (source[position.index + 1]) {
                    '/' => {
                        while (position.index < source.len and source[position.index] != '\n')
                            position.index += 1;
                    },
                    '*' => {
                        const close = std.mem.indexOfPos(u8, source, position.index + 2, "*/") orelse
                            return error.UnterminatedComment;
                        position.line += @intCast(std.mem.count(u8, source[position.index..close], "\n"));
                        position.index = close + 2;
                    },
                    else => return,
                }
            },
            else => return,
        }
    }
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$' or byte == '#' or byte == '\\' or byte >= 0x80;
}

fn isIdentifierPart(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}

/// Keywords after which an expression, and so a regular expression, starts.
fn isExpressionKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "return", "typeof", "instanceof", "in", "of",   "new",   "delete",
        "void",   "throw",  "case",       "do", "else", "yield", "await",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, word, keyword))
            return true;
    }
    return false;
}

fn isControlKeyword(word: []const u8) bool {
    return std.mem.eql(u8, word, "if") or std.mem.eql(u8, word, "while") or
        std.mem.eql(u8, word, "for") or std.mem.eql(u8, word, "with");
}
