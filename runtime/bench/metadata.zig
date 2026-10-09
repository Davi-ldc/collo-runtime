//! The JSON metadata line a bench prints before its first number: build
//! mode, target, the revision hash baked in at build time, machine, kernel
//! and CPU model, and `final`, which is true only for a ReleaseFast build.
//! Numbers from any other mode are not comparable, so such a build also
//! prints a NOT FINAL warning and, under COLLO_BENCH_REQUIRE_RELEASEFAST=1,
//! fails before measuring. Runs on the bench's main thread and writes to
//! stderr.

const std = @import("std");
const build_options = @import("collo_bench_build_options");

/// Prints the metadata line for `bench_name`. A /proc file that cannot be
/// read prints as "unknown". Fails with `error.BenchmarkRequiresReleaseFast`
/// for a non-ReleaseFast build when COLLO_BENCH_REQUIRE_RELEASEFAST is 1, and
/// with `error.OutOfMemory`.
pub fn print(allocator: std.mem.Allocator, bench_name: []const u8) !void {
    const final = std.mem.eql(u8, build_options.optimize_mode_name, "ReleaseFast");
    const machine = try readTrimmedOrUnknown(allocator, "/proc/sys/kernel/hostname", 256);
    defer allocator.free(machine);
    const kernel = try readTrimmedOrUnknown(allocator, "/proc/sys/kernel/osrelease", 256);
    defer allocator.free(kernel);
    const cpu_model = try readCpuModel(allocator);
    defer allocator.free(cpu_model);

    std.debug.print("{{\"bench\":\"metadata\"", .{});
    printJsonString("benchmark", bench_name);
    printJsonString("optimize_mode", build_options.optimize_mode_name);
    printJsonString("target_arch", build_options.target_arch_name);
    printJsonString("target_os", build_options.target_os_name);
    printJsonString("git_or_deploy_hash", build_options.git_or_deploy_hash);
    printJsonString("machine", machine);
    printJsonString("kernel", kernel);
    printJsonString("cpu_model", cpu_model);
    std.debug.print(",\"timestamp_unix\":{d},\"final\":{s}}}\n", .{
        std.time.timestamp(),
        if (final) "true" else "false",
    });

    if (!final)
        std.debug.print("NOT FINAL: benchmark was not built with ReleaseFast\n", .{});
    if (!final and releaseFastRequired(allocator))
        return error.BenchmarkRequiresReleaseFast;
}

fn releaseFastRequired(allocator: std.mem.Allocator) bool {
    const raw = std.process.getEnvVarOwned(allocator, "COLLO_BENCH_REQUIRE_RELEASEFAST") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };
    defer allocator.free(raw);
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "1");
}

fn readTrimmedOrUnknown(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const contents = std.fs.cwd().readFileAlloc(allocator, path, max_bytes) catch
        return allocator.dupe(u8, "unknown");
    defer allocator.free(contents);
    return allocator.dupe(u8, std.mem.trim(u8, contents, " \t\r\n"));
}

fn readCpuModel(allocator: std.mem.Allocator) ![]u8 {
    const contents = std.fs.cwd().readFileAlloc(allocator, "/proc/cpuinfo", 256 * 1024) catch
        return allocator.dupe(u8, "unknown");
    defer allocator.free(contents);

    if (try findCpuinfoValue(allocator, contents, "model name")) |value|
        return value;
    if (try findCpuinfoValue(allocator, contents, "Hardware")) |value|
        return value;
    if (try findCpuinfoValue(allocator, contents, "Processor")) |value|
        return value;
    if (try findCpuinfoValue(allocator, contents, "processor")) |value|
        return value;
    return allocator.dupe(u8, "unknown");
}

fn findCpuinfoValue(allocator: std.mem.Allocator, contents: []const u8, wanted: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(key, wanted))
            continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
        if (value.len != 0)
            return try allocator.dupe(u8, value);
    }
    return null;
}

fn printJsonString(name: []const u8, value: []const u8) void {
    std.debug.print(",\"{s}\":\"", .{name});
    for (value) |byte| switch (byte) {
        '"' => std.debug.print("\\\"", .{}),
        '\\' => std.debug.print("\\\\", .{}),
        '\n' => std.debug.print("\\n", .{}),
        '\r' => std.debug.print("\\r", .{}),
        '\t' => std.debug.print("\\t", .{}),
        else => if (byte < 0x20)
            std.debug.print("\\u{X:0>4}", .{byte})
        else
            std.debug.print("{c}", .{byte}),
    };
    std.debug.print("\"", .{});
}
