//! Access records (`server/analytics/access.zig`): stamping facts with each
//! capture cut at its cap on a UTF-8 boundary, the derived durations, the
//! `access.jsonl` line built from hostile client bytes, the usage a
//! dispatched request's line carries beside the server's identity and wall
//! time and the line of a request no worker was dispatched without it, the
//! encoded bound against a worst-case record, the ingress lane's handoff
//! ring, and draining a ring into a sink in a temporary directory with and
//! without an access file. The status, error code and usage an ingress lane
//! records for each way a dispatched request ends, and the metrics tick that
//! drains every ingress lane's ring, are covered in `server/tests/ingress/`,
//! and the usage floor in `server/tests/supervisor/usage.zig`.

const std = @import("std");
const analytics = @import("collo_server_analytics");

const access = analytics.access;
const Sink = analytics.Sink;
const Clock = analytics.Clock;
const AccessRecord = access.AccessRecord;
const AccessRing = access.AccessRing;

const file_bytes_max = 16 * 1024 * 1024;

const clock = Clock{ .wall_now_ms = 1_700_000_000_000, .mono_now_ns = 9_000_000_000 };

fn makeFacts(request_id: u64) access.AccessFacts {
    return access.stamp(.{
        .request_id = request_id,
        .worker = "demo.example.test",
        .route = "/api/:kind",
        .method = "GET",
        .path = "/api/items",
        .user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/139.0.0.0 Safari/537.36",
        .client_ip = "203.0.113.7",
        .started_mono_ns = 1_000_000_000,
    });
}

test "stamped facts cut each capture at its cap without splitting a UTF-8 sequence" {
    const limits = @import("collo_limits").runtime_logs;
    // The path, route and user agent each put a multibyte sequence across
    // their cap, so the cut must back off to the byte before the sequence.
    var long_path: [limits.PATH_BYTES_MAX + 64]u8 = undefined;
    @memset(&long_path, 'p');
    @memcpy(long_path[limits.PATH_BYTES_MAX - 2 ..][0..3], "\u{20ac}");
    var long_route: [limits.ROUTE_BYTES_MAX + 32]u8 = undefined;
    @memset(&long_route, 'r');
    @memcpy(long_route[limits.ROUTE_BYTES_MAX - 2 ..][0..3], "\u{20ac}");
    var long_user_agent: [limits.USER_AGENT_BYTES_MAX + 32]u8 = undefined;
    @memset(&long_user_agent, 'u');
    @memcpy(long_user_agent[limits.USER_AGENT_BYTES_MAX - 1 ..][0..2], "\u{e9}");
    var long_worker: [limits.WORKER_NAME_BYTES_MAX + 8]u8 = undefined;
    @memset(&long_worker, 'w');

    const facts = access.stamp(.{
        .request_id = 42,
        .worker = &long_worker,
        .route = &long_route,
        .method = "PROPFIND",
        .path = &long_path,
        .user_agent = &long_user_agent,
        .client_ip = "x" ** (limits.CLIENT_IP_BYTES_MAX + 6),
        .started_mono_ns = 5_000_000_000,
        .cold_start = true,
    });
    try std.testing.expectEqual(limits.PATH_BYTES_MAX - 2, facts.pathSlice().len);
    try std.testing.expectEqual(limits.ROUTE_BYTES_MAX - 2, facts.routeSlice().len);
    try std.testing.expectEqual(limits.USER_AGENT_BYTES_MAX - 1, facts.userAgentSlice().len);
    try std.testing.expectEqual(limits.WORKER_NAME_BYTES_MAX, facts.workerSlice().len);
    try std.testing.expectEqual(limits.CLIENT_IP_BYTES_MAX, facts.clientIpSlice().len);
    try std.testing.expectEqualStrings("PROPFIND", facts.methodSlice());
    try std.testing.expect(facts.cold_start);
    try std.testing.expectEqual(@as(u64, 0), facts.worker_id);
}

test "duration clamps at zero and a queued response head reports at least one millisecond" {
    var facts = makeFacts(1);
    const record = access.recordFromFacts(facts, 200, .worker, 1_250_000_000);
    try std.testing.expectEqual(@as(u64, 250), record.durationMs());
    try std.testing.expectEqual(@as(u64, 0), record.ttfbMs());

    const early = access.recordFromFacts(facts, 200, .worker, 500_000_000);
    try std.testing.expectEqual(@as(u64, 0), early.durationMs());

    facts.first_byte_mono_ns = facts.started_mono_ns + 700_000;
    const fast = access.recordFromFacts(facts, 200, .worker, 1_250_000_000);
    try std.testing.expectEqual(@as(u64, 1), fast.ttfbMs());
    facts.first_byte_mono_ns = facts.started_mono_ns + 30_000_000;
    const slow = access.recordFromFacts(facts, 200, .worker, 1_250_000_000);
    try std.testing.expectEqual(@as(u64, 30), slow.ttfbMs());
}

test "the line of a request no worker was dispatched encodes every field as one valid JSON line, and no usage field" {
    var facts = access.stamp(.{
        .request_id = 77,
        .worker = "demo.example.test",
        .route = "/blog/:slug",
        .method = "GET",
        .path = "/pa\xffth\n",
        .user_agent = "Bot/1.\xff0",
        .client_ip = "2001:db8::1",
        .started_mono_ns = 1_000_000_000,
        .cold_start = true,
    });
    facts.worker_id = 5;
    facts.worker_generation = 2;
    facts.cold_start_ns = 4_000_000;
    facts.cold_start_blocked_ns = 3_000_000;
    facts.first_byte_mono_ns = 1_100_000_000;
    facts.error_code = .deadline;
    facts.worker_fault = "deadline_grace_expired";
    const record = access.recordFromFacts(facts, 504, .worker, 1_750_000_000);

    var buffer: [access.json_record_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try access.writeRecordJson(&writer, &record, clock);
    const json = writer.buffered();
    try std.testing.expect(std.mem.indexOfScalar(u8, json, '\n') == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    // Finalized 7.25 s before the clock reading.
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000 - 7250), object.get("ts").?.integer);
    try std.testing.expectEqual(@as(i64, 77), object.get("request_id").?.integer);
    try std.testing.expectEqualStrings("demo.example.test", object.get("worker").?.string);
    try std.testing.expectEqualStrings("/blog/:slug", object.get("route").?.string);
    try std.testing.expectEqual(@as(i64, 5), object.get("worker_id").?.integer);
    try std.testing.expectEqual(@as(i64, 2), object.get("worker_generation").?.integer);
    try std.testing.expectEqualStrings("GET", object.get("method").?.string);
    try std.testing.expectEqualStrings("/pa\xef\xbf\xbdth\n", object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 504), object.get("status").?.integer);
    try std.testing.expectEqualStrings("worker", object.get("answered_by").?.string);
    try std.testing.expect(object.get("cold_start").?.bool);
    try std.testing.expectEqual(@as(i64, 750), object.get("duration_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 100), object.get("ttfb_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 4), object.get("cold_start_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 3), object.get("cold_start_blocked_ms").?.integer);
    try std.testing.expectEqualStrings("deadline", object.get("error_code").?.string);
    try std.testing.expectEqualStrings("deadline_grace_expired", object.get("worker_fault").?.string);
    try std.testing.expectEqualStrings("2001:db8::1", object.get("client_ip").?.string);
    try std.testing.expectEqualStrings("Bot/1.\xef\xbf\xbd0", object.get("user_agent").?.string);
    // No worker measured anything for the request, so the line has no usage
    // field at all.
    for ([_][]const u8{ "origin", "wall_ns", "exec_ns", "waiting_ns", "io_ns", "cpu_ns", "client_served_bytes", "fetch_sent_bytes", "fetch_received_bytes" }) |key|
        try std.testing.expect(object.get(key) == null);
    try std.testing.expectEqual(@as(usize, 19), object.count());
}

test "a dispatched request's line carries the worker's measures beside the server's identity and wall time" {
    var facts = makeFacts(78);
    facts.worker_id = 5;
    facts.worker_generation = 2;
    // Dispatched at 8 s and ended by the lane at 8.5 s on the server's clock.
    facts.dispatched_mono_ns = 8_000_000_000;
    var record = access.recordFromFacts(facts, 200, .worker, 8_500_000_000);
    record.usage = .{
        .origin = .worker,
        .exec_ns = 11,
        .waiting_ns = 13,
        .io_ns = 17,
        .cpu_ns = 19,
        .client_served_bytes = 100,
        .fetch_sent_bytes = 20,
        .fetch_received_bytes = 3,
    };

    var buffer: [access.json_record_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try access.writeRecordJson(&writer, &record, clock);
    const json = writer.buffered();
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;

    // The identity and the times are the server's: the facts the lane
    // stamped, and its dispatch to its end, 0.5 s before the clock reading.
    try std.testing.expectEqual(@as(i64, 78), object.get("request_id").?.integer);
    try std.testing.expectEqualStrings("demo.example.test", object.get("worker").?.string);
    try std.testing.expectEqualStrings("/api/:kind", object.get("route").?.string);
    try std.testing.expectEqual(@as(i64, 5), object.get("worker_id").?.integer);
    try std.testing.expectEqual(@as(i64, 2), object.get("worker_generation").?.integer);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000 - 500), object.get("ts").?.integer);
    try std.testing.expectEqual(@as(i64, 500_000_000), object.get("wall_ns").?.integer);
    // The measures are the worker's, each under its own key.
    try std.testing.expectEqualStrings("worker", object.get("origin").?.string);
    try std.testing.expectEqual(@as(i64, 11), object.get("exec_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 13), object.get("waiting_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 17), object.get("io_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 19), object.get("cpu_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 100), object.get("client_served_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 20), object.get("fetch_sent_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 3), object.get("fetch_received_bytes").?.integer);
    try std.testing.expect(object.get("fetch_wire_bytes") == null);
    try std.testing.expectEqual(@as(usize, 28), object.count());

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

test "a floor's line says the server measured it, and a request the lane never dispatched has no wall time" {
    var facts = makeFacts(79);
    facts.dispatched_mono_ns = 1_200_000_000;
    var record = access.recordFromFacts(facts, 502, .worker, 1_250_000_000);
    record.usage = .{ .origin = .server, .cpu_ns = 40 };
    try std.testing.expectEqual(@as(u64, 50_000_000), record.wallNs());

    var buffer: [access.json_record_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try access.writeRecordJson(&writer, &record, clock);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("server", parsed.value.object.get("origin").?.string);
    try std.testing.expectEqual(@as(i64, 40), parsed.value.object.get("cpu_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("exec_ns").?.integer);

    // The wall time runs from the dispatch, never from the head's arrival,
    // and a clock reading before the dispatch clamps it at zero.
    facts.dispatched_mono_ns = 0;
    try std.testing.expectEqual(@as(u64, 0), access.recordFromFacts(facts, 503, .server, 1_250_000_000).wallNs());
    facts.dispatched_mono_ns = 1_300_000_000;
    try std.testing.expectEqual(@as(u64, 0), access.recordFromFacts(facts, 502, .worker, 1_250_000_000).wallNs());
}

test "a worst-case access record fits its encoded bound" {
    // The metrics thread encodes into a buffer of exactly this bound and
    // treats running out of room as impossible.
    const limits = @import("collo_limits").runtime_logs;
    const widest = std.math.maxInt(u64);
    // Every capture past its cap, made of a byte that escapes to six.
    const control = [_]u8{0x01} ** 1024;
    var facts = access.stamp(.{
        .request_id = widest,
        .worker = &control,
        .route = &control,
        .method = &control,
        .path = &control,
        .user_agent = &control,
        .client_ip = &control,
        .started_mono_ns = 0,
    });
    facts.worker_id = widest;
    facts.worker_generation = widest;
    facts.first_byte_mono_ns = widest;
    facts.cold_start_ns = widest;
    facts.cold_start_blocked_ns = widest;
    // A dispatch at 1 ns and an end at the widest stamp give the widest wall
    // time.
    facts.dispatched_mono_ns = 1;
    facts.error_code = comptime std.meta.stringToEnum(access.ErrorCode, analytics.record.longestTagName(access.ErrorCode)).?;
    facts.worker_fault = control[0..limits.WORKER_FAULT_BYTES_MAX];
    const longest_answerer = comptime std.meta.stringToEnum(access.AnsweredBy, analytics.record.longestTagName(access.AnsweredBy)).?;
    var record = access.recordFromFacts(facts, std.math.maxInt(u16), longest_answerer, widest);
    record.usage = .{
        .origin = comptime std.meta.stringToEnum(access.Origin, analytics.record.longestTagName(access.Origin)).?,
        .exec_ns = widest,
        .waiting_ns = widest,
        .io_ns = widest,
        .cpu_ns = widest,
        .client_served_bytes = widest,
        .fetch_sent_bytes = widest,
        .fetch_received_bytes = widest,
    };

    var buffer: [access.json_record_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try access.writeRecordJson(&writer, &record, .{ .wall_now_ms = widest, .mono_now_ns = widest });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
}

test "answerer names are pinned" {
    try std.testing.expectEqual(2, @typeInfo(access.AnsweredBy).@"enum".fields.len);
    try std.testing.expectEqualStrings("worker", access.AnsweredBy.worker.jsonName());
    try std.testing.expectEqualStrings("server", access.AnsweredBy.server.jsonName());
}

test "the user agent is the first user-agent header, or empty" {
    const Header = struct { name: []const u8, value: []const u8 };
    const headers = [_]Header{
        .{ .name = "accept", .value = "*/*" },
        .{ .name = "user-agent", .value = "curl/8.9.1" },
        .{ .name = "user-agent", .value = "second" },
    };
    try std.testing.expectEqualStrings("curl/8.9.1", access.userAgent(&headers));
    try std.testing.expectEqualStrings("", access.userAgent(headers[0..1]));
}

test "the access ring hands records over in order and drops the newest when full" {
    var storage = try AccessRing.init();
    defer storage.deinit();
    const ring = &storage;

    var index: u64 = 0;
    while (index < AccessRing.capacity) : (index += 1)
        try std.testing.expect(ring.push(access.recordFromFacts(makeFacts(index + 1), 200, .worker, 2_000_000_000)));
    try std.testing.expect(!ring.push(access.recordFromFacts(makeFacts(9001), 200, .worker, 2_000_000_000)));
    try std.testing.expect(!ring.push(access.recordFromFacts(makeFacts(9002), 200, .worker, 2_000_000_000)));

    var record: AccessRecord = undefined;
    try std.testing.expect(ring.pop(&record));
    try std.testing.expectEqual(@as(u64, 1), record.facts.request_id);
    try std.testing.expect(ring.push(access.recordFromFacts(makeFacts(9003), 200, .worker, 2_000_000_000)));
    try std.testing.expectEqual(@as(u64, 2), ring.takeDropped());
    try std.testing.expectEqual(@as(u64, 0), ring.takeDropped());

    var drained: usize = 0;
    var last_id: u64 = 0;
    while (ring.pop(&record)) {
        drained += 1;
        last_id = record.facts.request_id;
    }
    try std.testing.expectEqual(AccessRing.capacity, drained);
    try std.testing.expectEqual(@as(u64, 9003), last_id);
}

/// Pages of the ring's slots the kernel holds for it.
fn residentSlotPages(ring: *const AccessRing) !usize {
    const page = std.heap.pageSize();
    const vector = try std.testing.allocator.alloc(u8, AccessRing.slot_bytes / page);
    defer std.testing.allocator.free(vector);
    const start: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(ring.slots.ptr));
    try std.posix.mincore(start, AccessRing.slot_bytes, vector.ptr);
    var count: usize = 0;
    for (vector) |state| {
        if (state & 1 != 0)
            count += 1;
    }
    return count;
}

test "an access ring holds none of its slots' memory until records land on them" {
    var ring = try AccessRing.init();
    defer ring.deinit();
    try std.testing.expectEqual(@as(usize, 0), try residentSlotPages(&ring));

    try std.testing.expect(ring.push(access.recordFromFacts(makeFacts(1), 200, .worker, 2_000_000_000)));
    const resident = try residentSlotPages(&ring);
    // One record spans at most two pages.
    try std.testing.expect(resident >= 1 and resident <= 2);
}

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
};

test "a ring drain writes every record to access.jsonl and counts the ring's refusals" {
    var output: SinkHarness = undefined;
    try output.init(true);
    defer output.deinit();
    var storage = try AccessRing.init();
    defer storage.deinit();
    const ring = &storage;

    var index: u64 = 0;
    while (index < AccessRing.capacity + 2) : (index += 1)
        _ = ring.push(access.recordFromFacts(makeFacts(index + 1), 200, .server, 2_000_000_000));

    access.drainRing(ring, &output.sink, clock);
    var record: AccessRecord = undefined;
    try std.testing.expect(!ring.pop(&record));
    const stats = output.sink.stats(.access);
    try std.testing.expectEqual(@as(u64, AccessRing.capacity), stats.appended);
    try std.testing.expectEqual(@as(u64, 2), stats.dropped);

    output.sink.flush(0);
    const written = try output.tmp.dir.readFileAlloc(std.testing.allocator, "access.jsonl", file_bytes_max);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqual(AccessRing.capacity, std.mem.count(u8, written, "\n"));
    const first_line = written[0..std.mem.indexOfScalar(u8, written, '\n').?];
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first_line, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("request_id").?.integer);
    try std.testing.expectEqualStrings("server", parsed.value.object.get("answered_by").?.string);
}

test "without an access file a ring drain pops the records and counts them as discarded" {
    var output: SinkHarness = undefined;
    try output.init(false);
    defer output.deinit();
    var storage = try AccessRing.init();
    defer storage.deinit();
    const ring = &storage;

    _ = ring.push(access.recordFromFacts(makeFacts(1), 200, .worker, 2_000_000_000));
    _ = ring.push(access.recordFromFacts(makeFacts(2), 404, .server, 2_000_000_000));
    access.drainRing(ring, &output.sink, clock);

    var record: AccessRecord = undefined;
    try std.testing.expect(!ring.pop(&record));
    try std.testing.expectEqual(@as(u64, 2), output.sink.stats(.access).discarded);
    try std.testing.expectEqual(@as(u64, 0), output.sink.stats(.access).appended);
}
