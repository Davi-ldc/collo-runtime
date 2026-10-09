//! The test runner of every suite in `runtime/build/tests.zig` except the two
//! bindings smokes, which keep Zig's stock runner. It is the root module of
//! each compilation it serves and runs the tests one at a time on the main
//! thread. The build compiles `runtime/all_tests.zig` once and links one large
//! binary, and each domain step, such as `zig build server-ingress-test`, runs
//! that same binary with its own `--filter` prefixes. The stock runner panics
//! on an argument it does not know, fails a run on any error log, and lets
//! every skip pass; this runner copies its terminal mode to change those three.
//!
//! Arguments before `--forwarded` come from the build. Those after it come from
//! `zig build <step> -- <args>`, which `runLinkedExecutable`
//! (`runtime/build/link.zig`) places behind that separator; suites the build
//! does not link that way receive the build's arguments alone.
//!
//! - `--filter=<prefix>` selects the tests whose fully qualified name starts
//!   with the prefix. Prefixes before `--forwarded` form the step's domain set
//!   and prefixes after it the user set. A test runs when it matches a prefix
//!   of each set that is not empty, so a forwarded filter narrows a domain and
//!   never leaves it. A domain prefix that matches no compiled test fails the
//!   run as partition drift, and so does a user prefix that matches no test
//!   inside the domain, which is how a filter meant for another lane shows up.
//! - `--assert-partition=<prefix>`, given only to the aggregate: every compiled
//!   test must start with one of these prefixes, and every prefix must match a
//!   test, so a domain that fell out of the aggregate through a lost aggregator
//!   import fails the run. Forwarded, it exits 2, because a command-line
//!   argument must never widen the partition the build declares.
//! - `--suite=<root>`: this compilation's root source file, relative to the
//!   repository root. It scopes the skip allowlist's entries.
//! - `--skip-allowlist=<path>`: the allowlist a strict run reads.
//! - `--seed=<n>` sets `std.testing.random_seed`, as in the stock runner. The
//!   build passes none.
//!
//! `--suite` and `--skip-allowlist` come only from the build: forwarded, empty
//! or given twice, either one exits 2.
//!
//! `COLLO_TEST_STRICT_SKIPS=1` makes skips strict under the rules in
//! `skip_allowlist.zig`: a skip the allowlist does not grant to this suite
//! fails the run, and so does an entry that names no test of this suite. A
//! strict run needs both build-configured arguments above. Without the
//! variable the allowlist is never read and a skip passes.
//!
//! A prefix matches with `startsWith`, never as a substring, so `worker.` does
//! not select `proxy.worker.`. The run exits 1 on a failed test, a leak, an
//! error log outside any test, a test whose error logs differ from its
//! declared count, a denied skip, a stale allowlist entry, or a failed
//! partition or prefix check. It exits 2 on an unknown or misplaced argument,
//! a `--suite` or `--skip-allowlist` that is empty, repeated or missing from a
//! strict run, an invalid `COLLO_TEST_STRICT_SKIPS` value, or an allowlist it
//! cannot read or that breaks its format. An empty prefix, too many selectors
//! of one kind or a seed that does not parse panic instead.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

/// Public so the runner's own tests reach it as `@import("root").skip_allowlist`:
/// a path import from a suite would put the file in a second module of the
/// same compilation, which Zig rejects.
pub const skip_allowlist = @import("skip_allowlist.zig");

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
/// Error logs the running test intends to drive, declared by the test itself
/// with `@import("root").expect_log_errors = N;` and reset to zero before
/// every test.
///
/// Some paths log at `err` because the loss they report must never pass
/// unnoticed, such as the start of a full usage stream (`reportFullBegan` in
/// `runtime/src/server/analytics/sink.zig`), whose refused records are lost
/// for good. A test of such a path cannot avoid the log, and the run-wide
/// error-log check would reject it. A declared count keeps the check exact in
/// both directions: an error nobody declared still fails the run, and so does
/// a test that declared one and saw none, because a path that stopped
/// reporting a loss looks the same as a path that stopped running.
pub var expect_log_errors: usize = 0;
/// Tests whose actual error-log count did not match what they declared.
var mismatched_log_expectations: usize = 0;
/// Error logs attributed to a test, whatever the verdict. What is left over is
/// what was logged outside any test, which nothing declares and nothing may.
var attributed_log_errors: usize = 0;
var fba_buffer: [16384]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);

/// The most prefixes each of the domain set, the user set and the partition
/// may hold; one more panics.
const max_selectors = 32;
/// Denied skips named again in the closing summary; the rest are counted.
const denied_names_max = 32;

pub fn main() void {
    const args = std.process.argsAlloc(fba.allocator()) catch
        @panic("unable to parse command line args");

    var configured_filters_buffer: [max_selectors][]const u8 = undefined;
    var configured_filters_len: usize = 0;
    var user_filters_buffer: [max_selectors][]const u8 = undefined;
    var user_filters_len: usize = 0;
    var partition_buffer: [max_selectors][]const u8 = undefined;
    var partition_len: usize = 0;
    var suite_arg: ?[]const u8 = null;
    var allowlist_path: ?[]const u8 = null;

    var forwarded = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--forwarded")) {
            forwarded = true;
        } else if (std.mem.startsWith(u8, arg, "--suite=")) {
            setConfiguredOnce(&suite_arg, "--suite=", arg, forwarded);
        } else if (std.mem.startsWith(u8, arg, "--skip-allowlist=")) {
            setConfiguredOnce(&allowlist_path, "--skip-allowlist=", arg, forwarded);
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            const prefix = arg["--filter=".len..];
            if (prefix.len == 0) @panic("--filter= requires a non-empty prefix");
            if (forwarded) {
                if (user_filters_len == max_selectors) @panic("too many --filter arguments");
                user_filters_buffer[user_filters_len] = prefix;
                user_filters_len += 1;
            } else {
                if (configured_filters_len == max_selectors) @panic("too many --filter arguments");
                configured_filters_buffer[configured_filters_len] = prefix;
                configured_filters_len += 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--assert-partition=")) {
            if (forwarded) {
                std.debug.print(
                    "--assert-partition is build-configured only (runtime/build/tests.zig) — a CLI `-- --assert-partition=...` must never widen a partition contract\n",
                    .{},
                );
                std.process.exit(2);
            }
            const prefix = arg["--assert-partition=".len..];
            if (prefix.len == 0) @panic("--assert-partition= requires a non-empty prefix");
            if (partition_len == max_selectors) @panic("too many --assert-partition arguments");
            partition_buffer[partition_len] = prefix;
            partition_len += 1;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else {
            std.debug.print("unrecognized argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    const configured_filters = configured_filters_buffer[0..configured_filters_len];
    const user_filters = user_filters_buffer[0..user_filters_len];
    const partition = partition_buffer[0..partition_len];

    const strict_value = std.posix.getenv(skip_allowlist.strict_env);
    const strictness = skip_allowlist.parseStrictness(strict_value) catch {
        std.debug.print("{s} must be 1 (strict skips), 0 or empty, not '{s}'\n", .{
            skip_allowlist.strict_env,
            strict_value.?,
        });
        std.process.exit(2);
    };
    const suite = suite_arg orelse "";
    const allowlist = switch (strictness) {
        .lenient => skip_allowlist.Allowlist.empty,
        .strict => loadAllowlist(suite_arg, allowlist_path),
    };

    const test_fn_list = builtin.test_functions;

    // The partition checks run before any test. A partition prefix that
    // matches no compiled test means a whole domain fell out of the aggregate,
    // as a dropped import in `runtime/all_tests.zig` causes, and a run of the
    // remaining tests could pass without reporting the loss.
    if (partition.len != 0) {
        for (partition) |prefix| {
            var hits: usize = 0;
            for (test_fn_list) |test_fn| {
                if (std.mem.startsWith(u8, test_fn.name, prefix)) hits += 1;
            }
            if (hits == 0) {
                std.debug.print(
                    "partition prefix matched no tests — domain lost from the aggregate: {s}\n",
                    .{prefix},
                );
                std.process.exit(1);
            }
        }
    }

    // A test outside every partition prefix means the domain table in
    // `runtime/build/tests.zig` no longer matches the tree; the first few are
    // named.
    if (partition.len != 0) {
        var uncovered: usize = 0;
        for (test_fn_list) |test_fn| {
            if (!matchesAny(test_fn.name, partition)) {
                uncovered += 1;
                if (uncovered <= 20)
                    std.debug.print("test outside every domain partition: {s}\n", .{test_fn.name});
            }
        }
        if (uncovered != 0) {
            std.debug.print(
                "{d} tests are outside the domain partition — update the table in runtime/build/tests.zig (docs/superpowers/plans/2026-07-16-runtime-tests-reorg.md)\n",
                .{uncovered},
            );
            std.process.exit(1);
        }
    }

    // Every domain filter must select a compiled test, and every forwarded
    // filter must select one inside the domain. A test must match both sets,
    // so a filter meant for another lane selects nothing, and this check fails
    // it instead of letting the step pass with no test run.
    for (configured_filters) |filter| {
        var hits: usize = 0;
        for (test_fn_list) |test_fn| {
            if (std.mem.startsWith(u8, test_fn.name, filter)) hits += 1;
        }
        if (hits == 0) {
            std.debug.print("--filter={s} matched no tests — dead prefix (partition drift)\n", .{filter});
            std.process.exit(1);
        }
    }
    for (user_filters) |filter| {
        var hits: usize = 0;
        for (test_fn_list) |test_fn| {
            if (configured_filters.len != 0 and !matchesAny(test_fn.name, configured_filters)) continue;
            if (std.mem.startsWith(u8, test_fn.name, filter)) hits += 1;
        }
        if (hits == 0) {
            std.debug.print(
                "--filter={s} matched no tests within this step's configured domain — dead prefix (partition drift, or a filter for another lane)\n",
                .{filter},
            );
            std.process.exit(1);
        }
    }

    // An entry of this suite whose test no longer exists would grant a skip to
    // whatever test later takes its name. Entries are checked against every
    // compiled test, so a filtered run checks the whole suite.
    var stale_entries: usize = 0;
    for (allowlist.entries) |entry| {
        if (!skip_allowlist.isStale(entry, suite, test_fn_list)) continue;
        stale_entries += 1;
        std.debug.print("skip allowlist entry names no test in {s}: {s}\n", .{ suite, entry.name });
    }
    if (stale_entries != 0) {
        std.debug.print("{d} stale entries in {s}: remove them or correct their names\n", .{
            stale_entries,
            allowlist_path.?,
        });
        std.process.exit(1);
    }

    var selected_total: usize = 0;
    for (test_fn_list) |test_fn| {
        if (isSelected(test_fn.name, configured_filters, user_filters)) selected_total += 1;
    }

    // The loop below follows `mainTerminal` of Zig's stock runner
    // (`lib/compiler/test_runner.zig` at zig 0.15.2, lines 185 to 267) over the
    // selected tests, with its output, leak and failure accounting. It differs
    // in two places: error logs are compared with each test's declared count,
    // and a skip gets a verdict when skips are strict.
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var denied_names: [denied_names_max][]const u8 = undefined;
    var denied_count: usize = 0;
    const root_node = std.Progress.start(.{
        .root_name = "Test",
        .estimated_total_items = selected_total,
    });
    const have_tty = std.fs.File.stderr().isTty();

    var leaks: usize = 0;
    var index: usize = 0;
    for (test_fn_list) |test_fn| {
        if (!isSelected(test_fn.name, configured_filters, user_filters)) continue;
        index += 1;
        testing.allocator_instance = .{};
        defer {
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
            }
        }
        testing.log_level = .warn;
        expect_log_errors = 0;
        const log_errors_before = log_err_count;

        const test_node = root_node.start(test_fn.name, 0);
        if (!have_tty) {
            std.debug.print("{d}/{d} {s}...", .{ index, selected_total, test_fn.name });
        }
        if (test_fn.func()) |_| {
            ok_count += 1;
            test_node.end();
            if (!have_tty) std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                const verdict = skip_allowlist.judgeSkip(strictness, allowlist, suite, test_fn.name);
                if (verdict == .denied) {
                    if (denied_count < denied_names_max) denied_names[denied_count] = test_fn.name;
                    denied_count += 1;
                }
                if (have_tty) {
                    std.debug.print("{d}/{d} {s}...", .{ index, selected_total, test_fn.name });
                }
                printSkip(verdict);
                test_node.end();
            },
            else => {
                fail_count += 1;
                if (have_tty) {
                    std.debug.print("{d}/{d} {s}...FAIL ({s})\n", .{
                        index, selected_total, test_fn.name, @errorName(err),
                    });
                } else {
                    std.debug.print("FAIL ({s})\n", .{@errorName(err)});
                }
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                test_node.end();
            },
        }

        const logged = log_err_count - log_errors_before;
        attributed_log_errors += logged;
        if (logged != expect_log_errors) {
            mismatched_log_expectations += 1;
            std.debug.print("{s}: expected {d} error logs, saw {d}\n", .{
                test_fn.name,
                expect_log_errors,
                logged,
            });
        }
    }
    root_node.end();
    if (ok_count == selected_total) {
        std.debug.print("All {d} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    }
    const stray_log_errors = log_err_count - attributed_log_errors;
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged ({d} outside any test).\n", .{
            log_err_count,
            stray_log_errors,
        });
    }
    if (mismatched_log_expectations != 0) {
        std.debug.print("{d} tests logged errors they did not declare.\n", .{mismatched_log_expectations});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    if (denied_count != 0) {
        std.debug.print("{d} tests skipped with no entry for {s} in {s}, and strict skips fail the run:\n", .{
            denied_count,
            suite,
            allowlist_path.?,
        });
        for (denied_names[0..@min(denied_count, denied_names_max)]) |name| {
            std.debug.print("  {s}\n", .{name});
        }
        if (denied_count > denied_names_max) {
            std.debug.print("  and {d} more\n", .{denied_count - denied_names_max});
        }
    }
    if (leaks != 0 or stray_log_errors != 0 or mismatched_log_expectations != 0 or
        fail_count != 0 or denied_count != 0)
    {
        std.process.exit(1);
    }
}

/// Stores a value the build configures once, before `--forwarded`. A forwarded
/// one exits 2, because a command-line argument must never choose which skips
/// a strict run allows; so does an empty or repeated one.
fn setConfiguredOnce(
    slot: *?[]const u8,
    comptime flag: []const u8,
    arg: []const u8,
    forwarded: bool,
) void {
    if (forwarded) {
        std.debug.print("{s} is build-configured only (runtime/build/tests.zig)\n", .{flag});
        std.process.exit(2);
    }
    const value = arg[flag.len..];
    if (value.len == 0) {
        std.debug.print("{s} requires a value\n", .{flag});
        std.process.exit(2);
    }
    if (slot.* != null) {
        std.debug.print("{s} given twice\n", .{flag});
        std.process.exit(2);
    }
    slot.* = value;
}

/// Reads and validates the allowlist for a strict run, exiting 2 when the run
/// cannot be strict as configured. The build hands every run its suite and
/// allowlist, so a missing one means the binary was started by hand. The
/// allowlist lives until the process exits.
fn loadAllowlist(suite: ?[]const u8, path: ?[]const u8) skip_allowlist.Allowlist {
    if (suite == null or path == null) {
        std.debug.print(
            "{s}=1 needs the build-configured --suite and --skip-allowlist; run this suite through its zig build step\n",
            .{skip_allowlist.strict_env},
        );
        std.process.exit(2);
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const source = std.fs.cwd().readFileAllocOptions(
        arena,
        path.?,
        skip_allowlist.source_bytes_max,
        null,
        .of(u8),
        0,
    ) catch |err| {
        std.debug.print("cannot read the skip allowlist {s}: {s}\n", .{ path.?, @errorName(err) });
        std.process.exit(2);
    };
    var diagnostics: std.zon.parse.Diagnostics = .{};
    const allowlist = skip_allowlist.parse(arena, source, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => @panic("out of memory parsing the skip allowlist"),
        error.ParseZon => {
            std.debug.print("{s}:\n{f}", .{ path.?, diagnostics });
            std.process.exit(2);
        },
    };
    if (skip_allowlist.firstDefect(allowlist)) |defect| {
        const problem = switch (defect.kind) {
            .empty_suite => "has an empty suite",
            .empty_name => "has an empty name",
            .empty_reason => "has an empty reason; name the missing capability or the opt-in",
            .duplicate => "repeats an earlier entry",
        };
        std.debug.print("{s}: entry {d} {s}\n", .{ path.?, defect.index, problem });
        std.process.exit(2);
    }
    return allowlist;
}

/// Ends the progress line of a skipped test; lenient output matches Zig's
/// default runner.
fn printSkip(verdict: skip_allowlist.SkipVerdict) void {
    switch (verdict) {
        .lenient => std.debug.print("SKIP\n", .{}),
        .allowed => |reason| std.debug.print("SKIP (allowlisted: {s})\n", .{reason}),
        .denied => std.debug.print("SKIP (not in the skip allowlist: fails the run)\n", .{}),
    }
}

/// Whether `name` matches a prefix of each set that is not empty. Without a
/// forwarded filter a step runs its whole domain, and a step with no domain
/// filter runs what the forwarded filters select.
fn isSelected(
    name: []const u8,
    configured_filters: []const []const u8,
    user_filters: []const []const u8,
) bool {
    if (configured_filters.len != 0 and !matchesAny(name, configured_filters)) return false;
    if (user_filters.len != 0 and !matchesAny(name, user_filters)) return false;
    return true;
}

fn matchesAny(name: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

/// Counts every `err` log for the checks in `main` and prints the logs at or
/// above `std.testing.log_level`, as the stock runner does.
pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
