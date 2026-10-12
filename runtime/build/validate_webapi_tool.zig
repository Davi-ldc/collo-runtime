//! Build-time check of the WebAPI fixtures under `runtime/tests/webapi/`, run
//! by the `test` aggregate and the webapi bench step on every build that
//! needs it (build.zig says why it never answers from cache):
//!
//! - every `*.test.js` is embedded by one of the suite files that bind
//!   fixtures to runners (`suites.zig`, `forked.zig`), so a fixture nobody
//!   bound cannot sit in the tree without running;
//! - every Collo contract fixture has a sibling `.bench.js` that the webapi
//!   bench embeds; the exact Bun and WPT ports and the `_leak` fixtures have
//!   none;
//! - every `.bench.js` has its fixture, declares `bench(...)` cases and keeps
//!   the Bun comparison enabled.
//!
//! argv: `<webapi_dir> <out_stamp>`, then `--bench=<file>` for each source the
//! webapi bench embeds its benches through and `--suite=<file>` for each file
//! that binds fixtures. Every file name is relative to the working directory.
const std = @import("std");

/// The sources `check` reads besides the fixture tree.
pub const Inputs = struct {
    /// Searched for `runtime/tests/webapi/<bench>`, the path the bench embeds.
    bench_sources: []const []const u8,
    /// Searched for `@embedFile("<fixture>")`, the fixture's path relative to
    /// the fixture tree, which is where the suite files live.
    suite_sources: []const []const u8,
};

/// The largest source or fixture the tool reads.
const file_bytes_max = 4 * 1024 * 1024;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 3) usage(args[0]);
    const webapi_dir_path = args[1];
    const out_stamp_path = args[2];

    var bench_sources: std.ArrayList([]const u8) = .empty;
    var suite_sources: std.ArrayList([]const u8) = .empty;
    for (args[3..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--bench=")) {
            try bench_sources.append(arena, try std.fs.cwd().readFileAlloc(arena, arg["--bench=".len..], file_bytes_max));
        } else if (std.mem.startsWith(u8, arg, "--suite=")) {
            try suite_sources.append(arena, try std.fs.cwd().readFileAlloc(arena, arg["--suite=".len..], file_bytes_max));
        } else {
            usage(args[0]);
        }
    }
    if (bench_sources.items.len == 0 or suite_sources.items.len == 0) usage(args[0]);

    var root = try std.fs.cwd().openDir(webapi_dir_path, .{ .iterate = true });
    defer root.close();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const report = &stderr_writer.interface;
    const passed = try check(arena, root, .{
        .bench_sources = bench_sources.items,
        .suite_sources = suite_sources.items,
    }, report);
    try report.flush();
    if (!passed) std.process.exit(1);
    try std.fs.cwd().writeFile(.{ .sub_path = out_stamp_path, .data = "ok\n" });
}

fn usage(program: []const u8) noreturn {
    std.debug.print(
        "usage: {s} <webapi_dir> <out_stamp> --bench=<file>... --suite=<file>...\n",
        .{program},
    );
    std.process.exit(64);
}

/// Checks the fixture tree at `root` against `inputs` and writes one line per
/// problem to `report`. Returns whether the tree passed. `arena` holds the
/// paths and fixture bytes until the caller frees it.
pub fn check(
    arena: std.mem.Allocator,
    root: std.fs.Dir,
    inputs: Inputs,
    report: *std.Io.Writer,
) !bool {
    var walker = try root.walk(arena);
    defer walker.deinit();

    var passed = true;
    while (try walker.next()) |entry| {
        if (entry.kind != .file)
            continue;

        if (std.mem.endsWith(u8, entry.path, ".test.js")) {
            if (!try isBoundBySuite(arena, entry.path, inputs.suite_sources)) {
                try report.print(
                    "WebAPI fixture runtime/tests/webapi/{s} is bound by no suite; embed it in suites.zig or forked.zig\n",
                    .{entry.path},
                );
                passed = false;
            }
            if (isImportedFixturePath(entry.path) or isLeakFixturePath(entry.path))
                continue;
            const bench_rel = try benchPathForTestPath(arena, entry.path);
            root.access(bench_rel, .{}) catch {
                try report.print(
                    "missing WebAPI bench for runtime/tests/webapi/{s}; expected runtime/tests/webapi/{s}\n",
                    .{ entry.path, bench_rel },
                );
                passed = false;
                continue;
            };

            const embed_path = try std.fmt.allocPrint(arena, "runtime/tests/webapi/{s}", .{bench_rel});
            if (!containsInAny(inputs.bench_sources, embed_path)) {
                try report.print(
                    "WebAPI bench runtime/tests/webapi/{s} is not embedded by the webapi bench target\n",
                    .{bench_rel},
                );
                passed = false;
            }
            continue;
        }

        if (std.mem.endsWith(u8, entry.path, ".bench.js")) {
            const test_rel = try testPathForBenchPath(arena, entry.path);
            root.access(test_rel, .{}) catch {
                try report.print(
                    "orphan WebAPI bench runtime/tests/webapi/{s}; expected runtime/tests/webapi/{s}\n",
                    .{ entry.path, test_rel },
                );
                passed = false;
                continue;
            };

            const source = try root.readFileAlloc(arena, entry.path, file_bytes_max);
            if (!hasBenchCase(source)) {
                try report.print(
                    "WebAPI bench runtime/tests/webapi/{s} does not declare any bench(...) cases\n",
                    .{entry.path},
                );
                passed = false;
            }
            if (hasDisabledComparison(source)) {
                try report.print(
                    "WebAPI bench runtime/tests/webapi/{s} disables Bun comparison\n",
                    .{entry.path},
                );
                passed = false;
            }
        }
    }
    return passed;
}

/// Whether a suite file embeds the fixture at `fixture_path`, relative to the
/// fixture tree. The walker separates components with the host's separator,
/// which on the build hosts is the `/` an `@embedFile` path uses.
fn isBoundBySuite(
    arena: std.mem.Allocator,
    fixture_path: []const u8,
    suite_sources: []const []const u8,
) error{OutOfMemory}!bool {
    const needle = try std.fmt.allocPrint(arena, "@embedFile(\"{s}\")", .{fixture_path});
    return containsInAny(suite_sources, needle);
}

fn containsInAny(sources: []const []const u8, needle: []const u8) bool {
    for (sources) |source| {
        if (std.mem.indexOf(u8, source, needle) != null)
            return true;
    }
    return false;
}

fn isImportedFixturePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".bun.test.js") or
        std.mem.endsWith(u8, path, ".wpt.test.js");
}

fn isLeakFixturePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "_leak.test.js");
}

fn benchPathForTestPath(allocator: std.mem.Allocator, test_path: []const u8) ![]u8 {
    const suffix = ".test.js";
    std.debug.assert(std.mem.endsWith(u8, test_path, suffix));
    return std.fmt.allocPrint(
        allocator,
        "{s}.bench.js",
        .{test_path[0 .. test_path.len - suffix.len]},
    );
}

fn testPathForBenchPath(allocator: std.mem.Allocator, bench_path: []const u8) ![]u8 {
    const suffix = ".bench.js";
    std.debug.assert(std.mem.endsWith(u8, bench_path, suffix));
    return std.fmt.allocPrint(
        allocator,
        "{s}.test.js",
        .{bench_path[0 .. bench_path.len - suffix.len]},
    );
}

fn hasBenchCase(bytes: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, index, "bench")) |found| {
        index = found + "bench".len;
        if (found != 0 and isJsIdentifierByte(bytes[found - 1]))
            continue;

        var cursor = index;
        while (cursor < bytes.len and isJsWhitespace(bytes[cursor]))
            cursor += 1;
        if (cursor < bytes.len and bytes[cursor] == '(')
            return true;
    }
    return false;
}

fn hasDisabledComparison(bytes: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, index, "compare")) |found| {
        index = found + "compare".len;
        if (found != 0 and isJsIdentifierByte(bytes[found - 1]))
            continue;
        if (index < bytes.len and isJsIdentifierByte(bytes[index]))
            continue;

        var cursor = index;
        while (cursor < bytes.len and isJsWhitespace(bytes[cursor]))
            cursor += 1;
        if (cursor >= bytes.len or bytes[cursor] != ':')
            continue;
        cursor += 1;
        while (cursor < bytes.len and isJsWhitespace(bytes[cursor]))
            cursor += 1;
        if (cursor + "false".len > bytes.len)
            continue;
        if (!std.mem.eql(u8, bytes[cursor .. cursor + "false".len], "false"))
            continue;
        if (cursor + "false".len < bytes.len and isJsIdentifierByte(bytes[cursor + "false".len]))
            continue;
        return true;
    }
    return false;
}

fn isJsIdentifierByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '_' or
        byte == '$';
}

fn isJsWhitespace(byte: u8) bool {
    return byte == ' ' or
        byte == '\t' or
        byte == '\n' or
        byte == '\r' or
        byte == 0x0b or
        byte == 0x0c;
}
