//! Worker console lines (`server/analytics/logs.zig`): frame decoding, the
//! `logs.jsonl` record and the stderr line for hostile message bytes, and
//! draining a real log ring (a memfd page, as a worker maps it) into a sink
//! in a temporary directory: line and drop-marker output, the line budget, a
//! faulted ring, and console-only output without a directory. The sink's own
//! buffering is covered in `sink.zig`, the ring's framing in
//! `common/tests/worker_state/page.zig`, and the order the metrics tick
//! drains worker rings in by `server/tests/ingress/analytics_drain.zig`.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const page = @import("collo_worker_state").page;

const logs = analytics.logs;
const Sink = analytics.Sink;
const Identity = analytics.Identity;
const Clock = analytics.Clock;

const file_bytes_max = 16 * 1024 * 1024;

const clock = Clock{ .wall_now_ms = 1_700_000_000_000, .mono_now_ns = 5_000_000_000 };

const identity = Identity{
    .worker = "api.example.test",
    .route = "/users/:id",
    .worker_id = 7,
    .worker_generation = 3,
};

fn encodeJson(buffer: []u8, line: logs.Line) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try logs.writeLineJson(&writer, identity, line);
    return writer.buffered();
}

fn encodeConsole(buffer: []u8, line_identity: Identity, message: []const u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try logs.writeLineConsole(&writer, line_identity, message);
    return writer.buffered();
}

test "a drained frame decodes its level and flags, and is never dated after the drain" {
    const frame = page.DrainedLogLine{
        .header = .{
            .payload_len = 2,
            .level = 9,
            .flags = page.LogLineFlags.truncated | page.LogLineFlags.js_exception,
            .request_id = 42,
            .ts_mono_ns = clock.mono_now_ns + 1,
        },
        .payload = "hi",
    };
    const line = logs.decodeLine(frame, clock);
    // A level byte no writer produces reads as info.
    try std.testing.expectEqual(page.LogLevel.info, line.level);
    try std.testing.expect(line.truncated);
    try std.testing.expect(line.exception);
    try std.testing.expectEqual(@as(u64, 42), line.request_id);
    try std.testing.expectEqual(clock.wall_now_ms, line.ts_ms);

    var past = frame;
    past.header.level = @intFromEnum(page.LogLevel.warn);
    past.header.ts_mono_ns = clock.mono_now_ns - 1_500_000_000;
    const earlier = logs.decodeLine(past, clock);
    try std.testing.expectEqual(page.LogLevel.warn, earlier.level);
    try std.testing.expectEqual(clock.wall_now_ms - 1500, earlier.ts_ms);
}

test "a console line encodes as one valid JSON record whatever bytes the worker wrote" {
    // Valid é, a control byte, quote, backslash, newline, an invalid lead
    // byte, then a truncated two-byte sequence at the very end.
    const hostile = "a\xc3\xa9b\x01\"\\\n\xffz\xc3";
    var buffer: [logs.json_record_bytes_max]u8 = undefined;
    const json = try encodeJson(&buffer, .{
        .request_id = 123,
        .level = .err,
        .ts_ms = 1_700_000_000_123,
        .message = hostile,
        .truncated = true,
        .exception = false,
    });
    try std.testing.expect(std.mem.indexOfScalar(u8, json, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, 0xff) == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1_700_000_000_123), object.get("ts").?.integer);
    try std.testing.expectEqualStrings("api.example.test", object.get("worker").?.string);
    try std.testing.expectEqualStrings("/users/:id", object.get("route").?.string);
    try std.testing.expectEqual(@as(i64, 7), object.get("worker_id").?.integer);
    try std.testing.expectEqual(@as(i64, 3), object.get("worker_generation").?.integer);
    try std.testing.expectEqual(@as(i64, 123), object.get("request_id").?.integer);
    try std.testing.expectEqualStrings("error", object.get("level").?.string);
    try std.testing.expect(object.get("truncated").?.bool);
    try std.testing.expect(!object.get("exception").?.bool);
    // Valid UTF-8 survives raw; each invalid byte became U+FFFD.
    try std.testing.expectEqualStrings(
        "a\xc3\xa9b\x01\"\\\n\xef\xbf\xbdz\xef\xbf\xbd",
        object.get("message").?.string,
    );
}

test "level names follow the console methods" {
    try std.testing.expectEqualStrings("debug", logs.levelName(.debug));
    try std.testing.expectEqualStrings("info", logs.levelName(.info));
    try std.testing.expectEqualStrings("warn", logs.levelName(.warn));
    try std.testing.expectEqualStrings("error", logs.levelName(.err));
}

test "every physical stderr line starts with the server's prefix or a continuation indent" {
    var buffer: [logs.console_record_bytes_max]u8 = undefined;
    // A worker trying to start its own line under another worker's name.
    const forged = try encodeConsole(&buffer, identity, "ok\n[billing.example.test /] fake");
    try std.testing.expectEqualStrings(
        "[api.example.test /users/:id] ok\n  [billing.example.test /] fake",
        forged,
    );

    const no_route = Identity{ .worker = "api.example.test", .route = "", .worker_id = 7, .worker_generation = 3 };
    try std.testing.expectEqualStrings("[api.example.test] hi", try encodeConsole(&buffer, no_route, "hi"));
}

test "stderr text escapes terminal controls and invalid UTF-8 and keeps the rest" {
    var buffer: [logs.console_record_bytes_max]u8 = undefined;
    // Escape, carriage return, DEL, an 8-bit CSI (U+009B), an invalid byte,
    // then a tab and é, which pass.
    const text = try encodeConsole(&buffer, identity, "a\x1b[31m\rb\x7f\xc2\x9b\xff\t\xc3\xa9");
    try std.testing.expectEqualStrings(
        "[api.example.test /users/:id] a\\x1b[31m\\x0db\\x7f\\xc2\\x9b\\xff\t\xc3\xa9",
        text,
    );
}

const RingHarness = struct {
    fd: std.posix.fd_t,
    view: page.WorkerWriterView,

    fn init(target: *RingHarness, name: []const u8) !void {
        const fd = try page.createMemfd(name);
        errdefer std.posix.close(fd);
        target.* = .{ .fd = fd, .view = try page.mapReadWrite(fd) };
        target.view.initializeCrashDefault(1, 4096, 1);
    }

    fn deinit(self: *RingHarness) void {
        self.view.deinit();
        std.posix.close(self.fd);
    }
};

const SinkHarness = struct {
    tmp: std.testing.TmpDir,
    console: std.fs.File,
    sink: Sink,

    fn init(target: *SinkHarness, with_directory: bool) !void {
        target.tmp = std.testing.tmpDir(.{});
        errdefer target.tmp.cleanup();
        target.console = try target.tmp.dir.createFile("console.txt", .{ .read = true });
        errdefer target.console.close();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try target.tmp.dir.realpath(".", &path_buffer);
        try target.sink.open(std.testing.allocator, .{
            .directory = if (with_directory) path else null,
            .console_fd = target.console.handle,
        });
    }

    fn deinit(self: *SinkHarness) void {
        self.sink.close();
        self.console.close();
        self.tmp.cleanup();
    }

    fn readLines(self: *SinkHarness, name: []const u8) ![]u8 {
        self.sink.flush(0);
        self.sink.flushConsole();
        return self.tmp.dir.readFileAlloc(std.testing.allocator, name, file_bytes_max);
    }
};

test "a ring drain writes each line to logs.jsonl and stderr and reports drops once" {
    var ring: RingHarness = undefined;
    try ring.init("analytics-logs-drain");
    defer ring.deinit();
    var output: SinkHarness = undefined;
    try output.init(true);
    defer output.deinit();

    ring.view.publishLogLine(.info, 0, 11, 4_000_000_000, "first");
    ring.view.publishLogLine(.warn, 0, 11, 4_500_000_000, "second");
    ring.view.publishLogLine(.err, page.LogLineFlags.js_exception, 0, 4_900_000_000, "Error: boom\n    at handler");
    ring.view.countBudgetDroppedLogLine();
    ring.view.countBudgetDroppedLogLine();

    var drop_reported: u64 = 0;
    const drained = try logs.drainRing(&ring.view, identity, &drop_reported, &output.sink, clock, 100);
    try std.testing.expectEqual(@as(usize, 3), drained);
    try std.testing.expectEqual(@as(u64, 2), drop_reported);

    // A drain with nothing new writes nothing, not even a marker.
    try std.testing.expectEqual(@as(usize, 0), try logs.drainRing(&ring.view, identity, &drop_reported, &output.sink, clock, 100));

    const records = try output.readLines("logs.jsonl");
    defer std.testing.allocator.free(records);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, records, "\n"), '\n');
    const expected_messages = [_][]const u8{ "first", "second", "Error: boom\n    at handler" };
    for (expected_messages, 0..) |expected, index| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(expected, parsed.value.object.get("message").?.string);
        try std.testing.expectEqualStrings("api.example.test", parsed.value.object.get("worker").?.string);
        if (index == 2)
            try std.testing.expect(parsed.value.object.get("exception").?.bool);
    }
    var marker = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{});
    defer marker.deinit();
    try std.testing.expectEqual(@as(i64, 2), marker.value.object.get("dropped_lines").?.integer);
    try std.testing.expect(marker.value.object.get("message") == null);
    try std.testing.expect(lines.next() == null);

    const console = try output.readLines("console.txt");
    defer std.testing.allocator.free(console);
    try std.testing.expectEqualStrings(
        "[api.example.test /users/:id] first\n" ++
            "[api.example.test /users/:id] second\n" ++
            "[api.example.test /users/:id] Error: boom\n" ++
            "      at handler\n" ++
            "[api.example.test /users/:id] collo: 2 console lines dropped\n",
        console,
    );
}

test "a ring drain stops at its line budget and leaves the rest for the next one" {
    var ring: RingHarness = undefined;
    try ring.init("analytics-logs-budget");
    defer ring.deinit();
    var output: SinkHarness = undefined;
    try output.init(true);
    defer output.deinit();

    var index: u64 = 0;
    while (index < 5) : (index += 1)
        ring.view.publishLogLine(.info, 0, index, 4_000_000_000, "line");

    var drop_reported: u64 = 0;
    try std.testing.expectEqual(@as(usize, 2), try logs.drainRing(&ring.view, identity, &drop_reported, &output.sink, clock, 2));
    try std.testing.expectEqual(@as(usize, 3), try logs.drainRing(&ring.view, identity, &drop_reported, &output.sink, clock, 100));
    try std.testing.expectEqual(@as(u64, 5), output.sink.stats(.logs).appended);
    try std.testing.expectEqual(@as(u64, 5), output.sink.stats(.console).appended);
}

test "a faulted ring fails the drain and gets no drop marker" {
    var ring: RingHarness = undefined;
    try ring.init("analytics-logs-fault");
    defer ring.deinit();
    var output: SinkHarness = undefined;
    try output.init(true);
    defer output.deinit();

    ring.view.countBudgetDroppedLogLine();
    // What a worker rewriting its own page can do to the ring.
    @atomicStore(u32, &ring.view.log_header.fatal, 1, .release);

    var drop_reported: u64 = 0;
    try std.testing.expectError(
        error.LogRingFatal,
        logs.drainRing(&ring.view, identity, &drop_reported, &output.sink, clock, 100),
    );
    try std.testing.expectEqual(@as(u64, 0), drop_reported);
    try std.testing.expectEqual(@as(u64, 0), output.sink.stats(.logs).appended);
    try std.testing.expectEqual(@as(u64, 0), output.sink.stats(.console).appended);

    // Teardown's drain of the same ring writes none of its lines to the sink;
    // `drainDyingRing` only logs that they are lost.
    logs.drainDyingRing(&ring.view, identity, &drop_reported, &output.sink);
    try std.testing.expectEqual(@as(u64, 0), output.sink.stats(.console).appended);
}

test "without a directory console lines still reach stderr and their records are discarded" {
    var ring: RingHarness = undefined;
    try ring.init("analytics-logs-console-only");
    defer ring.deinit();
    var output: SinkHarness = undefined;
    try output.init(false);
    defer output.deinit();

    ring.view.publishLogLine(.info, 0, 1, 4_000_000_000, "only stderr");
    var drop_reported: u64 = 0;
    logs.drainDyingRing(&ring.view, identity, &drop_reported, &output.sink);

    try std.testing.expectEqual(@as(u64, 1), output.sink.stats(.logs).discarded);
    const console = try output.readLines("console.txt");
    defer std.testing.allocator.free(console);
    try std.testing.expectEqualStrings("[api.example.test /users/:id] only stderr\n", console);
}
