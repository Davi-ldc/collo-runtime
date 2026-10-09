//! The strict-skip policy of the custom test runner: which values of
//! `COLLO_TEST_STRICT_SKIPS` turn it on, which skips pass, how the allowlist
//! parses and validates, when an entry is stale, and that the checked-in
//! `skip_allowlist.zon` is well formed. Runs in `meta-test`. The runner's
//! wiring around the policy, its arguments and exit codes, has no test here;
//! every strict run exercises it, `zig build smoke` first among them.
//!
//! The policy is reached as `@import("root").skip_allowlist` because the
//! runner is the root module of every compilation this file joins.
const std = @import("std");

const skip_allowlist = @import("root").skip_allowlist;
const Allowlist = skip_allowlist.Allowlist;
const Entry = skip_allowlist.Entry;
const Defect = skip_allowlist.Defect;
const judgeSkip = skip_allowlist.judgeSkip;
const firstDefect = skip_allowlist.firstDefect;
const isStale = skip_allowlist.isStale;
const expectEqual = std.testing.expectEqual;
const no_defect: ?Defect = null;

const aggregate_suite = "runtime/all_tests.zig";
const e2e_suite = "runtime/tests/integration/all.zig";
const bpf_test = "src.a.test.needs bpf";

const sample_entries = [_]Entry{
    .{ .suite = aggregate_suite, .name = bpf_test, .reason = "needs CAP_BPF" },
    .{ .suite = e2e_suite, .name = "e2e.test.bench (env-gated)", .reason = "opt-in benchmark" },
};
const sample: Allowlist = .{ .entries = &sample_entries };

fn passingTest() anyerror!void {}

test "strict skips turn on only for 1, and any value but 1, 0 or empty is rejected" {
    try expectEqual(.lenient, try skip_allowlist.parseStrictness(null));
    try expectEqual(.lenient, try skip_allowlist.parseStrictness(""));
    try expectEqual(.lenient, try skip_allowlist.parseStrictness("0"));
    try expectEqual(.strict, try skip_allowlist.parseStrictness("1"));
    for ([_][]const u8{ "true", "yes", "2", " 1", "1 ", "01" }) |typo| {
        try std.testing.expectError(error.InvalidStrictSkips, skip_allowlist.parseStrictness(typo));
    }
}

test "a lenient run lets every skip pass, listed or not" {
    try expectEqual(.lenient, judgeSkip(.lenient, sample, aggregate_suite, bpf_test));
    try expectEqual(.lenient, judgeSkip(.lenient, sample, aggregate_suite, "src.b.test.unlisted"));
    try expectEqual(.lenient, judgeSkip(.lenient, Allowlist.empty, "", "anything"));
}

test "a strict run allows a skip only when an entry has the same suite and the exact name" {
    switch (judgeSkip(.strict, sample, aggregate_suite, bpf_test)) {
        .allowed => |reason| try std.testing.expectEqualStrings("needs CAP_BPF", reason),
        else => return error.TestExpectedAllowed,
    }
    // The same name in another suite is a different test.
    try expectEqual(.denied, judgeSkip(.strict, sample, e2e_suite, bpf_test));
    // Names match exactly; a prefix or an extension names another test.
    try expectEqual(.denied, judgeSkip(.strict, sample, aggregate_suite, "src.a.test.needs"));
    try expectEqual(.denied, judgeSkip(.strict, sample, aggregate_suite, bpf_test ++ "2"));
    try expectEqual(.denied, judgeSkip(.strict, Allowlist.empty, aggregate_suite, bpf_test));
}

test "the allowlist parses from ZON with comments and rejects unknown or missing fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostics: std.zon.parse.Diagnostics = .{};
    const parsed = try skip_allowlist.parse(arena,
        \\// Leading comment.
        \\.{
        \\    .{ .suite = "runtime/all_tests.zig", .name = "src.a.test.x", .reason = "needs CAP_BPF" },
        \\}
    , &diagnostics);
    try expectEqual(@as(usize, 1), parsed.entries.len);
    try std.testing.expectEqualStrings("runtime/all_tests.zig", parsed.entries[0].suite);
    try std.testing.expectEqualStrings("src.a.test.x", parsed.entries[0].name);
    try std.testing.expectEqualStrings("needs CAP_BPF", parsed.entries[0].reason);

    var empty_diagnostics: std.zon.parse.Diagnostics = .{};
    const empty = try skip_allowlist.parse(arena, ".{}", &empty_diagnostics);
    try expectEqual(@as(usize, 0), empty.entries.len);

    var unknown_diagnostics: std.zon.parse.Diagnostics = .{};
    try std.testing.expectError(error.ParseZon, skip_allowlist.parse(arena,
        \\.{ .{ .suite = "s", .name = "n", .reason = "r", .until = "later" } }
    , &unknown_diagnostics));

    var missing_diagnostics: std.zon.parse.Diagnostics = .{};
    try std.testing.expectError(error.ParseZon, skip_allowlist.parse(arena,
        \\.{ .{ .suite = "s", .name = "n" } }
    , &missing_diagnostics));
}

test "an allowlist defect names the first entry with an empty field or a repeated suite and name" {
    try expectEqual(no_defect, firstDefect(sample));
    try expectEqual(no_defect, firstDefect(Allowlist.empty));

    const Case = struct { entries: []const Entry, defect: Defect };
    const cases = [_]Case{
        .{
            .entries = &.{.{ .suite = "", .name = "n", .reason = "r" }},
            .defect = .{ .index = 0, .kind = .empty_suite },
        },
        .{
            .entries = &.{ sample_entries[0], .{ .suite = "s", .name = "", .reason = "r" } },
            .defect = .{ .index = 1, .kind = .empty_name },
        },
        .{
            .entries = &.{.{ .suite = "s", .name = "n", .reason = "" }},
            .defect = .{ .index = 0, .kind = .empty_reason },
        },
        .{
            .entries = &.{ sample_entries[0], sample_entries[1], sample_entries[0] },
            .defect = .{ .index = 2, .kind = .duplicate },
        },
    };
    for (cases) |case| {
        const found = firstDefect(.{ .entries = case.entries }) orelse
            return error.TestExpectedDefect;
        try expectEqual(case.defect, found);
    }

    // One name in two suites is two tests, so both entries stand.
    const two_suites = [_]Entry{
        .{ .suite = aggregate_suite, .name = "x.test.t", .reason = "r" },
        .{ .suite = e2e_suite, .name = "x.test.t", .reason = "r" },
    };
    try expectEqual(no_defect, firstDefect(.{ .entries = &two_suites }));
}

test "an entry is stale only when its own suite compiles no test with its exact name" {
    const compiled = [_]std.builtin.TestFn{
        .{ .name = bpf_test, .func = &passingTest },
        .{ .name = "src.a.test.other", .func = &passingTest },
    };
    try std.testing.expect(!isStale(sample_entries[0], aggregate_suite, &compiled));
    // Another suite's entry is that suite's run to judge.
    try std.testing.expect(!isStale(sample_entries[1], aggregate_suite, &compiled));
    try std.testing.expect(isStale(sample_entries[1], e2e_suite, &compiled));

    const renamed: Entry = .{ .suite = aggregate_suite, .name = "src.a.test.needs", .reason = "r" };
    try std.testing.expect(isStale(renamed, aggregate_suite, &compiled));
    try std.testing.expect(isStale(sample_entries[0], aggregate_suite, &.{}));
}

test "the checked-in allowlist parses and every entry is well formed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try std.fs.cwd().readFileAllocOptions(
        arena,
        "runtime/tests/support/skip_allowlist.zon",
        skip_allowlist.source_bytes_max,
        null,
        .of(u8),
        0,
    );
    var diagnostics: std.zon.parse.Diagnostics = .{};
    const allowlist = skip_allowlist.parse(arena, source, &diagnostics) catch |err| {
        std.debug.print("runtime/tests/support/skip_allowlist.zon:\n{f}", .{diagnostics});
        return err;
    };
    try expectEqual(no_defect, firstDefect(allowlist));
}
