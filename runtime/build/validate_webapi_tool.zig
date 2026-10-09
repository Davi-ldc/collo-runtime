//! Build-time tool enforcing the WebAPI test/bench contract:
//! every runtime/tests/webapi/**.test.js has a sibling .bench.js that is embedded by
//! the webapi bench target, and every .bench.js declares bench(...) cases and
//! keeps the Bun comparison enabled.
//!
//! argv: <webapi_dir> <bench_source> [extra scan sources...] <out_stamp>
//! Runs as a cached Run step (inputs hashed), not at configure time.
const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 4) {
        std.debug.print("usage: {s} <webapi_dir> <bench_source> [scan sources...] <out_stamp>\n", .{args[0]});
        std.process.exit(64);
    }
    const webapi_dir_path = args[1];
    const out_stamp_path = args[args.len - 1];
    const scan_paths = args[2 .. args.len - 1];

    var scan_sources = try arena.alloc([]const u8, scan_paths.len);
    for (scan_paths, 0..) |path, index|
        scan_sources[index] = try std.fs.cwd().readFileAlloc(arena, path, 4 * 1024 * 1024);

    var root = try std.fs.cwd().openDir(webapi_dir_path, .{ .iterate = true });
    defer root.close();
    var walker = try root.walk(arena);
    defer walker.deinit();

    var failed = false;
    while (try walker.next()) |entry| {
        if (entry.kind != .file)
            continue;

        if (std.mem.endsWith(u8, entry.path, ".test.js")) {
            if (isImportedFixturePath(entry.path) or isLeakFixturePath(entry.path))
                continue;
            const bench_rel = try benchPathForTestPath(arena, entry.path);
            root.access(bench_rel, .{}) catch {
                std.debug.print("missing WebAPI bench for runtime/tests/webapi/{s}; expected runtime/tests/webapi/{s}\n", .{ entry.path, bench_rel });
                failed = true;
                continue;
            };

            const embed_path = try std.fmt.allocPrint(arena, "runtime/tests/webapi/{s}", .{bench_rel});
            var embedded = false;
            for (scan_sources) |source| {
                if (std.mem.indexOf(u8, source, embed_path) != null)
                    embedded = true;
            }
            if (!embedded) {
                std.debug.print("WebAPI bench runtime/tests/webapi/{s} is not embedded by the webapi bench target\n", .{bench_rel});
                failed = true;
            }
            continue;
        }

        if (std.mem.endsWith(u8, entry.path, ".bench.js")) {
            const test_rel = try testPathForBenchPath(arena, entry.path);
            root.access(test_rel, .{}) catch {
                std.debug.print("orphan WebAPI bench runtime/tests/webapi/{s}; expected runtime/tests/webapi/{s}\n", .{ entry.path, test_rel });
                failed = true;
                continue;
            };

            const source = try root.readFileAlloc(arena, entry.path, 1024 * 1024);
            if (!hasBenchCase(source)) {
                std.debug.print("WebAPI bench runtime/tests/webapi/{s} does not declare any bench(...) cases\n", .{entry.path});
                failed = true;
            }
            if (hasDisabledComparison(source)) {
                std.debug.print("WebAPI bench runtime/tests/webapi/{s} disables Bun comparison\n", .{entry.path});
                failed = true;
            }
        }
    }

    if (failed)
        std.process.exit(1);
    try std.fs.cwd().writeFile(.{ .sub_path = out_stamp_path, .data = "ok\n" });
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
