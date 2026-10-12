//! The WebAPI fixture check (`runtime/build/validate_webapi_tool.zig`) over
//! fixture trees built in a temporary directory: a fixture no suite file
//! embeds, a contract fixture without its bench, and a tree that passes. The
//! real tree is checked by the build's own run of the tool. Lanes:
//! `buildtool-test` and `meta-test`.
const std = @import("std");
const validate = @import("collo_validate_webapi");

const bench_source = "bench(\"case\", () => {});\n";

fn writeFixture(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    try dir.writeFile(.{ .sub_path = path, .data = bytes });
}

/// Runs the check on `dir` and returns whether it passed; `report` receives
/// its problem lines.
fn runCheck(dir: std.fs.Dir, inputs: validate.Inputs, report: *std.Io.Writer) !bool {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var iterable = try dir.openDir(".", .{ .iterate = true });
    defer iterable.close();
    return validate.check(arena_state.allocator(), iterable, inputs, report);
}

test "a fixture that no suite file embeds fails the check and is named" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "timers/timers.test.js", "test(\"t\", () => {});\n");
    try writeFixture(tmp.dir, "timers/timers.bench.js", bench_source);
    try writeFixture(tmp.dir, "streams/port.bun.test.js", "test(\"t\", () => {});\n");

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    const passed = try runCheck(tmp.dir, .{
        .bench_sources = &.{"embeds runtime/tests/webapi/timers/timers.bench.js"},
        .suite_sources = &.{"@embedFile(\"timers/timers.test.js\")"},
    }, &report.writer);

    try std.testing.expect(!passed);
    const text = report.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "streams/port.bun.test.js is bound by no suite") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timers/timers.test.js") == null);
}

test "a contract fixture without its bench fails, while an exact port needs none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "url/url.test.js", "test(\"t\", () => {});\n");
    try writeFixture(tmp.dir, "url/url.wpt.test.js", "test(\"t\", () => {});\n");

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    const passed = try runCheck(tmp.dir, .{
        .bench_sources = &.{""},
        .suite_sources = &.{"@embedFile(\"url/url.test.js\") @embedFile(\"url/url.wpt.test.js\")"},
    }, &report.writer);

    try std.testing.expect(!passed);
    const text = report.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "missing WebAPI bench for runtime/tests/webapi/url/url.test.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "url.wpt") == null);
}

test "a tree whose fixtures are all bound and benched passes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "abort/abort.test.js", "test(\"t\", () => {});\n");
    try writeFixture(tmp.dir, "abort/abort.bench.js", bench_source);
    try writeFixture(tmp.dir, "abort/abort_leak.test.js", "test(\"t\", () => {});\n");
    try writeFixture(tmp.dir, "support/harness.js", "");

    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    const passed = try runCheck(tmp.dir, .{
        .bench_sources = &.{"runtime/tests/webapi/abort/abort.bench.js"},
        .suite_sources = &.{ "@embedFile(\"abort/abort.test.js\")", "@embedFile(\"abort/abort_leak.test.js\")" },
    }, &report.writer);

    try std.testing.expectEqualStrings("", report.written());
    try std.testing.expect(passed);
}
