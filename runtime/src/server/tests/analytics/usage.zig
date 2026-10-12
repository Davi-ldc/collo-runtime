//! Usage records (`server/analytics/usage.zig`): the times a `usage.jsonl`
//! line carries, where each comes from and the key it goes under. Draining a
//! worker's ring, floors, the stream's batches and the worst-case bound are
//! covered with the supervisor in `server/tests/supervisor/usage.zig`.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const page = @import("collo_worker_state").page;

const usage = analytics.usage;

test "a usage line carries the server's wall time and the worker's execution, waiting, I/O and CPU, each under its own key" {
    const clock = analytics.Clock{ .wall_now_ms = 1_700_000_000_000, .mono_now_ns = 9_000_000_000 };
    const identity: analytics.Identity = .{
        .worker = "demo.example.test",
        .route = "/api/:kind",
        .worker_id = 5,
        .worker_generation = 2,
    };
    const completed: page.CompletedRecord = .{
        .request_id = 77,
        .exec_ns = 11,
        .waiting_ns = 13,
        .io_ns = 17,
        .cpu_ns = 19,
        .status = @intFromEnum(page.CompletedStatus.done),
    };
    // Dispatched at 8 s and ended by the lane at 8.5 s on the server's clock.
    const dispatch: usage.Dispatch = .{ .started_mono_ns = 8_000_000_000, .accounting_flags = 0 };
    const record = usage.fromCompleted(identity, .worker, completed, dispatch, 8_500_000_000, clock);

    var buffer: [usage.json_record_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try usage.writeRecordJson(&writer, &record);
    const json = writer.buffered();
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;

    // The wall time is the server's, from its dispatch to the lane's end, and
    // `ts` is that end on the wall clock, 0.5 s before the reading.
    try std.testing.expectEqual(@as(i64, 500_000_000), object.get("wall_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000 - 500), object.get("ts").?.integer);
    try std.testing.expectEqual(@as(i64, 11), object.get("exec_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 13), object.get("waiting_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 17), object.get("io_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 19), object.get("cpu_ns").?.integer);
    for ([_][]const u8{ "wall_time_ns", "cpu_time_ns", "io_time_ns" }) |key|
        try std.testing.expect(object.get(key) == null);

    // The times keep one order on every line: the server's span, then the
    // worker's partition of its own span, then the CPU.
    const keys = [_][]const u8{ "\"wall_ns\"", "\"exec_ns\"", "\"waiting_ns\"", "\"io_ns\"", "\"cpu_ns\"" };
    var previous: usize = 0;
    for (keys) |key| {
        const at = std.mem.indexOf(u8, json, key) orelse return error.TestExpectedKey;
        try std.testing.expect(at > previous);
        previous = at;
    }
}
