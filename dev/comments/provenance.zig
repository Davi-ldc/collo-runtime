//! Provenance markers in comments: traces of how code was planned, scheduled
//! or reviewed, where a comment should state what the code guarantees. The
//! conventions gate in `runtime/tests/conventions.zig` counts them per file
//! and fails when a file holds more than `baseline_path` allows; the
//! `provenance-baseline` build step lowers that baseline once comments are
//! rewritten and refuses to raise it. Only comment text is read, never string
//! literals, so a test may spell a marker in a literal.
//!
//! Words and identifiers match only on word boundaries, and the exclusions
//! below keep ordinary technical vocabulary out: protocol versions,
//! instruction sets, cache levels, encodings, hash names, sections of numbered
//! standards, hexadecimal byte runs and timestamps in test vectors. A new
//! false positive gets an exclusion here and a case in the vocabulary test of
//! `runtime/tests/conventions.zig`. Short labels a test gives its own actors
//! share the plan identifier form and do count; name such actors by role
//! instead.
const std = @import("std");
const source = @import("source.zig");

/// Directories scanned, relative to the repository root.
pub const scan_roots = [_][]const u8{ "runtime/src", "runtime/tests", "runtime/build", "runtime/bench", "dev" };

/// Relative to the repository root.
pub const baseline_path = "runtime/tests/comment_provenance.zon";

/// Largest source file read; anything bigger is not hand-written source.
pub const file_size_max = 16 * 1024 * 1024;

pub const Marker = enum {
    /// A work-plan item: one to three capital letters, one or two digits, up
    /// to three lowercase letters, then any dash-joined segments, all counted
    /// as one marker.
    plan_id,
    /// A ledger or finding number: one to four capital letters, a dash and one
    /// or two digits.
    ledger_id,
    /// A hash sign before a number, naming an item of a plan or review list.
    /// Not after an ampersand or a quote, which is an escape or a format.
    numbered_ref,
    /// A section sign before a number, unless it cites a numbered standard.
    section,
    /// An ISO date or year-month from `repository_year_first` on. A timestamp
    /// is data and does not count.
    date,
    /// Vocabulary of plan bookkeeping that has no technical meaning here.
    plan_word,
    /// A code review event: the word review followed by what it found, or a
    /// numbered finding.
    review,
    /// A path into the ledger directory, where plans live.
    todo_path,
    /// The name of an agent that wrote or reviewed the code.
    agent_name,

    pub fn label(marker: Marker) []const u8 {
        return switch (marker) {
            .plan_id => "plan identifier",
            .ledger_id => "ledger identifier",
            .numbered_ref => "numbered reference",
            .section => "section citation",
            .date => "date",
            .plan_word => "plan vocabulary",
            .review => "review reference",
            .todo_path => "ledger path",
            .agent_name => "agent name",
        };
    }
};

const marker_count = @typeInfo(Marker).@"enum".fields.len;

/// Ordinary technical names that share the plan identifier form, compared
/// against the capitals and digits of a match.
const technical_identifiers = [_][]const []const u8{
    &.{ "H1", "H2", "H3" }, // HTTP versions
    &.{ "L1", "L2", "L3", "L4", "L7" }, // cache levels and network layers
    &.{ "C0", "C1" }, // control-character sets
    &.{ "C89", "C90", "C99", "C11", "C17", "C23", "ES5", "ES6" }, // language standards
    &.{ "MD4", "MD5", "SHA1", "SHA2", "SHA3", "RC4" }, // hashes and ciphers
    &.{ "TLS1", "SSL2", "SSL3" }, // protocol versions
    &.{ "UTF8", "UCS2", "UCS4", "IPV4", "IPV6" }, // encodings and address families
    &.{ "X86", "X64", "ARM32", "ARM64", "AVX2", "SSE2", "SSE3", "SSE4" }, // instruction sets
    &.{ "ALU64", "JMP32", "MOV64" }, // eBPF instruction classes
    &.{ "ELF32", "ELF64" }, // object formats
    &.{ "U8", "U16", "U32", "U64", "I8", "I16", "I32", "I64", "F16", "F32", "F64" }, // number types
    &.{ "S3", "R2", "EC2", "K8", "V8", "WSL1", "WSL2" }, // services, engines and platforms
    &.{ "A1", "A2", "A4" }, // Ampere instance types
};

/// Technical names that share the ledger identifier form.
const technical_dashed = [_][]const u8{ "UTF-8", "UTF-16", "UTF-32", "UCS-2", "UCS-4", "SHA-1", "SHA-2", "SHA-3" };

/// Bodies whose numbered standards cite their own sections.
const standard_bodies = [_][]const u8{ "RFC", "ECMA", "ISO", "IEEE" };

/// Words that, after the word review, say what a review found.
const review_qualifiers = [_][]const u8{
    "finding", "findings", "fix", "fixes", "nit",      "nits", "item", "items", "stage", "round",
    "high",    "medium",   "med", "low",   "critical",
};

const agent_names = [_][]const u8{ "Sol", "Codex", "Claude", "Astra" };

/// The earliest year a date in a comment can come from this repository.
const repository_year_first = 2025;

pub const Match = struct {
    marker: Marker,
    start: usize,
    end: usize,
};

/// Markers in `text[start..]`, offsets into `text`. A matcher may read the
/// bytes before `start`, which lets a citation wrapped onto the next comment
/// line see its first half. Matches of different markers may overlap; matches
/// of one marker never do.
pub const TextMatches = struct {
    text: []const u8,
    index: usize,
    /// Next marker to try at `index`.
    marker_index: usize = 0,
    /// Per marker, the first index a new match may start at.
    free_from: [marker_count]usize = @splat(0),

    pub fn init(text: []const u8) TextMatches {
        return .initAt(text, 0);
    }

    pub fn initAt(text: []const u8, start: usize) TextMatches {
        return .{ .text = text, .index = start };
    }

    pub fn next(it: *TextMatches) ?Match {
        while (it.index < it.text.len) {
            while (it.marker_index < marker_count) {
                const marker: Marker = @enumFromInt(it.marker_index);
                it.marker_index += 1;
                if (it.index < it.free_from[@intFromEnum(marker)]) continue;
                const length = matchAt(marker, it.text, it.index) orelse continue;
                std.debug.assert(length > 0);
                it.free_from[@intFromEnum(marker)] = it.index + length;
                return .{ .marker = marker, .start = it.index, .end = it.index + length };
            }
            it.index += 1;
            it.marker_index = 0;
        }
        return null;
    }
};

/// Markers in the comments of one source, with offsets into the source.
pub const SourceMatches = struct {
    comments: source.CommentIterator,
    in_comment: TextMatches = .init(""),
    text: [:0]const u8,

    pub fn init(language: source.Language, text: [:0]const u8) SourceMatches {
        return .{ .comments = .init(language, text), .text = text };
    }

    pub fn next(it: *SourceMatches) ?Match {
        while (true) {
            if (it.in_comment.next()) |match| return match;
            const comment = it.comments.next() orelse return null;
            it.in_comment = .initAt(it.text[0..comment.end], comment.start);
        }
    }
};

pub fn countText(text: []const u8) u32 {
    var matches: TextMatches = .init(text);
    var count: u32 = 0;
    while (matches.next()) |_| count += 1;
    return count;
}

pub fn countSource(language: source.Language, text: [:0]const u8) u32 {
    var matches: SourceMatches = .init(language, text);
    var count: u32 = 0;
    while (matches.next()) |_| count += 1;
    return count;
}

fn matchAt(marker: Marker, text: []const u8, index: usize) ?usize {
    if (marker != .section and !startsWord(text, index)) return null;
    return switch (marker) {
        .plan_id => matchPlanId(text, index),
        .ledger_id => matchLedgerId(text, index),
        .numbered_ref => matchNumberedReference(text, index),
        .section => matchSection(text, index),
        .date => matchDate(text, index),
        .plan_word => matchPlanWord(text, index),
        .review => matchReview(text, index),
        .todo_path => if (std.mem.startsWith(u8, text[index..], "todo/")) "todo/".len else null,
        .agent_name => matchAgentName(text, index),
    };
}

fn matchPlanId(text: []const u8, start: usize) ?usize {
    const letters_end = runEnd(text, start, std.ascii.isUpper);
    if (!within(letters_end - start, 1, 3)) return null;
    const digits_end = runEnd(text, letters_end, std.ascii.isDigit);
    if (!within(digits_end - letters_end, 1, 2)) return null;
    const suffix_end = runEnd(text, digits_end, std.ascii.isLower);
    if (suffix_end - digits_end > 3) return null;
    var end = suffix_end;
    while (end + 1 < text.len and text[end] == '-' and std.ascii.isAlphanumeric(text[end + 1])) {
        end = runEnd(text, end + 1, std.ascii.isAlphanumeric);
    }
    if (!endsWord(text, end)) return null;
    for (technical_identifiers) |group| {
        if (contains(group, text[start..digits_end])) return null;
    }
    // A quoted value, such as a two-letter code a protocol reserves.
    if (start > 0 and end < text.len and text[start - 1] == '"' and text[end] == '"') return null;
    if (end == digits_end and isHexByteRun(text, start, end)) return null;
    return end - start;
}

/// `start..end` is a two-digit hexadecimal byte next to another one, as in a
/// UTF-8 sequence written out in a comment.
fn isHexByteRun(text: []const u8, start: usize, end: usize) bool {
    if (!isHexByte(text, start, end)) return false;
    if (start >= 3 and text[start - 1] == ' ' and isHexByte(text, start - 3, start - 1) and startsWord(text, start - 3)) {
        return true;
    }
    return end + 3 <= text.len and text[end] == ' ' and isHexByte(text, end + 1, end + 3) and endsWord(text, end + 3);
}

fn isHexByte(text: []const u8, start: usize, end: usize) bool {
    if (end - start != 2) return false;
    for (text[start..end]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'A' and byte <= 'F')) return false;
    }
    return true;
}

fn matchLedgerId(text: []const u8, start: usize) ?usize {
    const letters_end = runEnd(text, start, std.ascii.isUpper);
    if (!within(letters_end - start, 1, 4)) return null;
    if (letters_end >= text.len or text[letters_end] != '-') return null;
    const digits_end = runEnd(text, letters_end + 1, std.ascii.isDigit);
    if (!within(digits_end - letters_end - 1, 1, 2)) return null;
    if (!endsWord(text, digits_end)) return null;
    if (contains(&technical_dashed, text[start..digits_end])) return null;
    return digits_end - start;
}

fn matchNumberedReference(text: []const u8, start: usize) ?usize {
    if (text[start] != '#') return null;
    if (start > 0 and (text[start - 1] == '&' or text[start - 1] == '"')) return null;
    const digits_end = runEnd(text, start + 1, std.ascii.isDigit);
    if (!within(digits_end - start - 1, 1, 4)) return null;
    if (!endsWord(text, digits_end)) return null;
    return digits_end - start;
}

const section_sign = "\u{a7}";

fn matchSection(text: []const u8, start: usize) ?usize {
    if (!std.mem.startsWith(u8, text[start..], section_sign)) return null;
    var cursor = start + section_sign.len;
    if (cursor < text.len and text[cursor] == ' ') cursor += 1;
    var end = runEnd(text, cursor, std.ascii.isDigit);
    if (end == cursor) return null;
    if (citesNumberedStandard(text, start)) return null;
    while (end + 1 < text.len and text[end] == '.' and std.ascii.isDigit(text[end + 1])) {
        end = runEnd(text, end + 1, std.ascii.isDigit);
    }
    return end - start;
}

/// Whether the section sign at `section_start` follows a numbered standard,
/// with a space or a dash before the number, as in a request-for-comments
/// citation. The citation may wrap onto the next comment line.
fn citesNumberedStandard(text: []const u8, section_start: usize) bool {
    var cursor = section_start;
    while (cursor > 0 and isCommentGlue(text[cursor - 1])) cursor -= 1;
    const number_end = cursor;
    while (cursor > 0 and std.ascii.isDigit(text[cursor - 1])) cursor -= 1;
    if (cursor == number_end or cursor == 0) return false;
    const separator = text[cursor - 1];
    if (separator != ' ' and separator != '-') return false;
    const name_end = cursor - 1;
    var name_start = name_end;
    while (name_start > 0 and std.ascii.isUpper(text[name_start - 1])) name_start -= 1;
    if (!startsWord(text, name_start)) return false;
    return contains(&standard_bodies, text[name_start..name_end]);
}

fn matchDate(text: []const u8, start: usize) ?usize {
    const year_end = start + 4;
    const month_end = year_end + 3;
    if (month_end > text.len) return null;
    const year = parseDigits(text[start..year_end]) orelse return null;
    if (year < repository_year_first) return null;
    if (text[year_end] != '-') return null;
    const month = parseDigits(text[year_end + 1 .. month_end]) orelse return null;
    if (!within(month, 1, 12)) return null;
    var end = month_end;
    if (end + 3 <= text.len and text[end] == '-') {
        if (parseDigits(text[end + 1 .. end + 3])) |day| {
            if (within(day, 1, 31)) end += 3;
        }
    }
    if (!endsWord(text, end)) return null;
    return end - start;
}

/// Plan vocabulary in English and in Portuguese, the language of the older
/// plans and of the frozen area references. None of these words names
/// anything in the code.
const plan_words = [_][]const u8{ "wave", "waves", "onda", "ondas", "fase", "fases", "arco", "arcos" };

fn matchPlanWord(text: []const u8, start: usize) ?usize {
    const end = runEnd(text, start, std.ascii.isAlphabetic);
    if (end == start or !endsWord(text, end)) return null;
    const word = text[start..end];
    for (plan_words) |plan_word| {
        if (std.ascii.eqlIgnoreCase(word, plan_word)) return end - start;
    }
    // The capitalized acronym is reference counting.
    const is_arc = std.ascii.eqlIgnoreCase(word, "arc") or std.ascii.eqlIgnoreCase(word, "arcs");
    if (is_arc and !std.ascii.isUpper(word[1])) return end - start;
    if (std.ascii.startsWithIgnoreCase(word, "ratif")) return end - start;
    return null;
}

fn matchReview(text: []const u8, start: usize) ?usize {
    const word_end = runEnd(text, start, std.ascii.isAlphabetic);
    if (!endsWord(text, word_end)) return null;
    const word = text[start..word_end];
    if (std.ascii.eqlIgnoreCase(word, "review")) {
        const qualifier = runEnd(text, word_end, isBlank);
        if (qualifier == word_end) return null;
        const qualifier_end = reviewQualifierEnd(text, qualifier) orelse return null;
        return qualifier_end - start;
    }
    if (std.ascii.eqlIgnoreCase(word, "finding")) {
        const number = runEnd(text, word_end, isBlank);
        if (number == word_end) return null;
        const number_end = runEnd(text, number, std.ascii.isDigit);
        if (number_end == number) return null;
        return number_end - start;
    }
    return null;
}

/// A numbered item after the word review counts as a numbered reference
/// instead, so it is not counted twice.
fn reviewQualifierEnd(text: []const u8, start: usize) ?usize {
    const word_end = runEnd(text, start, std.ascii.isAlphabetic);
    if (word_end > start and endsWord(text, word_end)) {
        for (review_qualifiers) |qualifier| {
            if (std.ascii.eqlIgnoreCase(text[start..word_end], qualifier)) return word_end;
        }
    }
    const plan_id_length = matchPlanId(text, start) orelse return null;
    return start + plan_id_length;
}

fn matchAgentName(text: []const u8, start: usize) ?usize {
    const end = runEnd(text, start, std.ascii.isAlphabetic);
    if (!endsWord(text, end)) return null;
    if (!contains(&agent_names, text[start..end])) return null;
    return end - start;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn startsWord(text: []const u8, index: usize) bool {
    return index == 0 or !isWordByte(text[index - 1]);
}

fn endsWord(text: []const u8, index: usize) bool {
    return index == text.len or !isWordByte(text[index]);
}

fn isBlank(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

/// Whitespace and the delimiters that continue a comment on its next line.
fn isCommentGlue(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', '/', '!', '*' => true,
        else => false,
    };
}

fn runEnd(text: []const u8, start: usize, comptime predicate: fn (u8) bool) usize {
    var end = start;
    while (end < text.len and predicate(text[end])) end += 1;
    return end;
}

fn within(value: usize, low: usize, high: usize) bool {
    return value >= low and value <= high;
}

fn parseDigits(digits: []const u8) ?usize {
    var value: usize = 0;
    for (digits) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
        value = value * 10 + (digit - '0');
    }
    return value;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) return true;
    }
    return false;
}

/// A count per repository-relative path.
pub const FileCount = struct {
    path: []const u8,
    markers: u32,
};

/// Files with at least one marker, sorted by path.
pub const Counts = struct {
    files: []FileCount,

    pub fn deinit(counts: Counts, gpa: std.mem.Allocator) void {
        for (counts.files) |file| gpa.free(file.path);
        gpa.free(counts.files);
    }
};

fn totalMarkers(files: []const FileCount) u64 {
    var sum: u64 = 0;
    for (files) |file| sum += file.markers;
    return sum;
}

/// Prints as "3 markers in 2 files".
pub const Totals = struct {
    markers: u64,
    files: u64,

    pub fn of(files: []const FileCount) Totals {
        return .{ .markers = totalMarkers(files), .files = files.len };
    }

    pub fn format(totals: Totals, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("{d} {s} in {d} {s}", .{
            totals.markers, noun(totals.markers, "marker"), totals.files, noun(totals.files, "file"),
        });
    }
};

pub fn noun(count: u64, comptime singular: []const u8) []const u8 {
    return if (count == 1) singular else singular ++ "s";
}

/// Counts the markers of every Zig and C-family file under the scan roots of
/// `repository`, the repository root.
pub fn countRepository(gpa: std.mem.Allocator, repository: std.fs.Dir) !Counts {
    var files: std.ArrayList(FileCount) = .empty;
    errdefer {
        for (files.items) |file| gpa.free(file.path);
        files.deinit(gpa);
    }
    for (scan_roots) |root| {
        var directory = try repository.openDir(root, .{ .iterate = true });
        defer directory.close();
        const listing = try source.listFiles(gpa, directory);
        defer listing.deinit(gpa);
        for (listing.files) |file| {
            if (file.kind != .file) continue;
            const language = source.languageOf(file.path) orelse continue;
            const text = try directory.readFileAllocOptions(gpa, file.path, file_size_max, null, .of(u8), 0);
            defer gpa.free(text);
            const markers = countSource(language, text);
            if (markers == 0) continue;
            const path = try std.fs.path.join(gpa, &.{ root, file.path });
            errdefer gpa.free(path);
            try files.append(gpa, .{ .path = path, .markers = markers });
        }
    }
    const sorted = try files.toOwnedSlice(gpa);
    std.mem.sort(FileCount, sorted, {}, fileCountLessThan);
    return .{ .files = sorted };
}

fn fileCountLessThan(_: void, a: FileCount, b: FileCount) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Writes every marker of the file at `path`, relative to `repository`, one
/// per line as `path:line: label: text`.
pub fn writeFileMarkers(gpa: std.mem.Allocator, repository: std.fs.Dir, path: []const u8, out: *std.Io.Writer) !void {
    const language = source.languageOf(path) orelse return;
    const text = try repository.readFileAllocOptions(gpa, path, file_size_max, null, .of(u8), 0);
    defer gpa.free(text);
    var matches: SourceMatches = .init(language, text);
    var line: u32 = 1;
    var line_counted_to: usize = 0;
    while (matches.next()) |match| {
        line += @intCast(std.mem.count(u8, text[line_counted_to..match.start], "\n"));
        line_counted_to = match.start;
        try out.print("{s}:{d}: {s}: {s}\n", .{ path, line, match.marker.label(), text[match.start..match.end] });
    }
}

pub const Baseline = struct {
    files: []const FileCount,

    pub fn deinit(baseline: Baseline, gpa: std.mem.Allocator) void {
        std.zon.parse.free(gpa, baseline.files);
    }
};

/// Parses a baseline file; on a syntax error or a value that is not a list of
/// `FileCount` entries, `diagnostics` explains it.
pub fn parseBaseline(gpa: std.mem.Allocator, text: [:0]const u8, diagnostics: *std.zon.parse.Diagnostics) !Baseline {
    const files = try std.zon.parse.fromSlice([]const FileCount, gpa, text, diagnostics, .{});
    return .{ .files = files };
}

/// Reads and parses the baseline at `baseline_path`, writing any parse error
/// to `out` before returning it.
pub fn readBaseline(gpa: std.mem.Allocator, repository: std.fs.Dir, out: *std.Io.Writer) !Baseline {
    const text = try repository.readFileAllocOptions(gpa, baseline_path, file_size_max, null, .of(u8), 0);
    defer gpa.free(text);
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(gpa);
    return parseBaseline(gpa, text, &diagnostics) catch |err| switch (err) {
        error.ParseZon => {
            try out.print("{s}: not a list of .{{ .path, .markers }} entries\n{f}", .{ baseline_path, diagnostics });
            return err;
        },
        error.OutOfMemory => return err,
    };
}

/// A file holding more markers than the baseline allows.
pub const Excess = struct {
    /// Borrowed from the current counts.
    path: []const u8,
    markers: u32,
    allowed: u32,
};

/// Every file in `current` above its baseline entry, where a file the baseline
/// does not list allows none. The result borrows paths from `current`, and the
/// caller frees the slice. Fails with `error.DuplicateBaselineEntry` when the
/// baseline lists a path twice.
pub fn findExcess(gpa: std.mem.Allocator, baseline: []const FileCount, current: []const FileCount) ![]Excess {
    var allowed: std.StringHashMapUnmanaged(u32) = .empty;
    defer allowed.deinit(gpa);
    for (baseline) |entry| {
        const slot = try allowed.getOrPut(gpa, entry.path);
        if (slot.found_existing) return error.DuplicateBaselineEntry;
        slot.value_ptr.* = entry.markers;
    }
    var excess: std.ArrayList(Excess) = .empty;
    errdefer excess.deinit(gpa);
    for (current) |file| {
        const limit = allowed.get(file.path) orelse 0;
        if (file.markers > limit) try excess.append(gpa, .{ .path = file.path, .markers = file.markers, .allowed = limit });
    }
    return excess.toOwnedSlice(gpa);
}

const baseline_header =
    \\// Provenance markers allowed per file in comments, enforced by the
    \\// conventions gate in runtime/tests/conventions.zig. Generated: after
    \\// rewriting comments, `zig build provenance-baseline` lowers these counts
    \\// and drops files that reach zero. It never raises a count.
    \\
;

/// Writes `files` in the baseline format, which `parseBaseline` reads back.
pub fn writeBaseline(out: *std.Io.Writer, files: []const FileCount) !void {
    try out.writeAll(baseline_header);
    try out.writeAll(".{\n");
    for (files) |file| {
        try out.print("    .{{ .path = \"{f}\", .markers = {d} }},\n", .{ std.zig.fmtString(file.path), file.markers });
    }
    try out.writeAll("}\n");
}
