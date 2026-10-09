//! Which tests may skip when skips are strict, and why each one may. Under
//! `COLLO_TEST_STRICT_SKIPS=1` the custom runner (`test_runner.zig`) reads
//! `skip_allowlist.zon`: a test that returns `error.SkipZigTest` then fails
//! the run unless the allowlist lists it for the suite being run, and an
//! entry that names no test compiled into its suite fails the run too, so a
//! renamed or deleted test cannot leave a stale permission behind. Without
//! the variable the allowlist is never read and a skip passes, as under Zig's
//! stock runner.
//!
//! A suite is the root source file of one test compilation, relative to the
//! repository root. Test names are paths relative to that file's directory,
//! so one test compiled into two suites carries two names, and an entry is
//! checked only against the suite it names.
//!
//! Nothing here keeps state, and the runner calls it only from its main
//! thread. The build (`runtime/build/tests.zig`) imports this file for
//! `strict_env`, so the file must depend on nothing but std.
const std = @import("std");

/// The variable that makes skips strict: "1" turns strictness on; unset,
/// empty or "0" leaves it off.
pub const strict_env = "COLLO_TEST_STRICT_SKIPS";

/// Largest allowlist the runner reads; the file is a short hand-written list.
pub const source_bytes_max = 64 * 1024;

pub const Strictness = enum { lenient, strict };

/// Reads the value of `strict_env`. Any other value is rejected: reading a
/// typo such as "true" as off would let a run meant to be strict pass.
pub fn parseStrictness(value: ?[]const u8) error{InvalidStrictSkips}!Strictness {
    const text = value orelse return .lenient;
    if (text.len == 0) return .lenient;
    if (std.mem.eql(u8, text, "0")) return .lenient;
    if (std.mem.eql(u8, text, "1")) return .strict;
    return error.InvalidStrictSkips;
}

pub const Entry = struct {
    /// Root source file of the test compilation, relative to the repository
    /// root.
    suite: []const u8,
    /// The fully qualified test name, as the runner prints it.
    name: []const u8,
    /// The host capability the skip stands for, the opt-in that gates the
    /// test, or the recorded defect the skip reproduces.
    reason: []const u8,
};

pub const Allowlist = struct {
    entries: []const Entry,

    pub const empty: Allowlist = .{ .entries = &.{} };

    /// Why `name` may skip in `suite`, or null when it may not.
    pub fn reasonFor(allowlist: Allowlist, suite: []const u8, name: []const u8) ?[]const u8 {
        for (allowlist.entries) |entry| {
            if (!std.mem.eql(u8, entry.suite, suite)) continue;
            if (std.mem.eql(u8, entry.name, name)) return entry.reason;
        }
        return null;
    }
};

/// Parses ZON source without validating the entries; `firstDefect` does that.
/// On `error.ParseZon`, `diagnostics` explains the failure. Every slice in the
/// result, and everything `diagnostics` holds, lives in `arena`.
pub fn parse(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    diagnostics: *std.zon.parse.Diagnostics,
) error{ OutOfMemory, ParseZon }!Allowlist {
    const entries = try std.zon.parse.fromSlice(
        []const Entry,
        arena,
        source,
        diagnostics,
        .{ .free_on_error = false },
    );
    return .{ .entries = entries };
}

pub const Defect = struct {
    /// Index of the offending entry in the file.
    index: usize,
    kind: Kind,

    pub const Kind = enum {
        empty_suite,
        empty_name,
        empty_reason,
        /// The same suite and name already appear at an earlier index.
        duplicate,
    };
};

/// The first entry that breaks the file's contract: every field is set and no
/// suite and name pair appears twice.
pub fn firstDefect(allowlist: Allowlist) ?Defect {
    for (allowlist.entries, 0..) |entry, index| {
        if (entry.suite.len == 0) return .{ .index = index, .kind = .empty_suite };
        if (entry.name.len == 0) return .{ .index = index, .kind = .empty_name };
        if (entry.reason.len == 0) return .{ .index = index, .kind = .empty_reason };
        for (allowlist.entries[0..index]) |earlier| {
            if (!std.mem.eql(u8, earlier.suite, entry.suite)) continue;
            if (std.mem.eql(u8, earlier.name, entry.name)) {
                return .{ .index = index, .kind = .duplicate };
            }
        }
    }
    return null;
}

/// Whether `entry` belongs to `suite` and names no test compiled into it.
/// An entry of another suite is never stale here; that suite's run judges it.
pub fn isStale(entry: Entry, suite: []const u8, tests: []const std.builtin.TestFn) bool {
    if (!std.mem.eql(u8, entry.suite, suite)) return false;
    for (tests) |test_fn| {
        if (std.mem.eql(u8, test_fn.name, entry.name)) return false;
    }
    return true;
}

pub const SkipVerdict = union(enum) {
    /// Skips are lenient: the skip passes, as under Zig's own runner.
    lenient,
    /// Skips are strict and the allowlist names the test; the payload is why.
    allowed: []const u8,
    /// Skips are strict and no entry names the test: the run fails.
    denied,
};

/// What a skip of `name` in `suite` means for the run.
pub fn judgeSkip(
    strictness: Strictness,
    allowlist: Allowlist,
    suite: []const u8,
    name: []const u8,
) SkipVerdict {
    switch (strictness) {
        .lenient => return .lenient,
        .strict => {
            if (allowlist.reasonFor(suite, name)) |reason| return .{ .allowed = reason };
            return .denied;
        },
    }
}
