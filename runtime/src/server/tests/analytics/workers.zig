//! Worker lines (`server/analytics/workers.zig`): the `workers.jsonl` line
//! built from a worker's identity, life, leaf figures and ending, a figure the
//! leaf could not give, and the encoded bound against a worst-case line. The
//! teardown that writes the line, and a line that finds its stream full, are
//! covered with the supervisor in `server/tests/supervisor/reaper/retirement.zig`
//! and `server/tests/supervisor/supervisor.zig`.

const std = @import("std");
const analytics = @import("collo_server_analytics");

const workers = analytics.workers;

const line_keys = [_][]const u8{
    "ts",            "worker",            "worker_id", "worker_generation", "started_ts", "life_ns",
    "worker_cpu_ns", "memory_peak_bytes", "ending",
};

fn encode(buffer: []u8, line: *const workers.WorkerRecord) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try workers.writeRecordJson(&writer, line);
    return writer.buffered();
}

test "a worker line carries its identity, life, figures and ending, and a figure the leaf could not give prints null" {
    var buffer: [workers.json_record_bytes_max]u8 = undefined;
    const counted: workers.WorkerRecord = .{
        .worker = "demo\"\n",
        .worker_id = 5,
        .worker_generation = 2,
        .started_ts_ms = 1_700_000_000_000,
        .ts_ms = 1_700_000_004_250,
        .life_ns = 4_250_000_000,
        .worker_cpu_ns = 31_000_000,
        .memory_peak_bytes = 12 * 1024 * 1024,
        .ending = .recycled,
    };
    const json = try encode(&buffer, &counted);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, '\n') == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(line_keys.len, object.count());
    for (line_keys) |key|
        try std.testing.expect(object.get(key) != null);
    try std.testing.expectEqual(@as(i64, 1_700_000_004_250), object.get("ts").?.integer);
    try std.testing.expectEqualStrings("demo\"\n", object.get("worker").?.string);
    try std.testing.expectEqual(@as(i64, 5), object.get("worker_id").?.integer);
    try std.testing.expectEqual(@as(i64, 2), object.get("worker_generation").?.integer);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), object.get("started_ts").?.integer);
    try std.testing.expectEqual(@as(i64, 4_250_000_000), object.get("life_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 31_000_000), object.get("worker_cpu_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 12 * 1024 * 1024), object.get("memory_peak_bytes").?.integer);
    try std.testing.expectEqualStrings("recycled", object.get("ending").?.string);

    // A leaf without `memory.peak`, whose `cpu.stat` could not be read either.
    var unknown = counted;
    unknown.worker_cpu_ns = null;
    unknown.memory_peak_bytes = null;
    unknown.ending = .shutdown;
    const unknown_json = try encode(&buffer, &unknown);
    var unknown_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unknown_json, .{});
    defer unknown_parsed.deinit();
    const unknown_object = unknown_parsed.value.object;
    try std.testing.expectEqual(line_keys.len, unknown_object.count());
    try std.testing.expect(unknown_object.get("worker_cpu_ns").? == .null);
    try std.testing.expect(unknown_object.get("memory_peak_bytes").? == .null);
    try std.testing.expectEqualStrings("shutdown", unknown_object.get("ending").?.string);
}

test "a worst-case worker line stays within its bound" {
    // The teardown encodes into a buffer of exactly this bound and treats
    // running out of room as impossible.
    const limits = @import("collo_limits").runtime_logs;
    const widest = std.math.maxInt(u64);
    // A name past its cap, made of a byte that escapes to six.
    const control = [_]u8{0x01} ** (limits.WORKER_NAME_BYTES_MAX + 64);
    const longest_ending = comptime std.meta.stringToEnum(
        workers.Ending,
        analytics.record.longestTagName(workers.Ending),
    ).?;
    const line: workers.WorkerRecord = .{
        .worker = &control,
        .worker_id = widest,
        .worker_generation = widest,
        .started_ts_ms = widest,
        .ts_ms = widest,
        .life_ns = widest,
        .worker_cpu_ns = widest,
        .memory_peak_bytes = widest,
        .ending = longest_ending,
    };
    var buffer: [workers.json_record_bytes_max]u8 = undefined;
    const json = try encode(&buffer, &line);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(line_keys.len, parsed.value.object.count());
}
