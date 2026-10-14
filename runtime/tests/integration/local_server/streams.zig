//! Responses whose body is a ReadableStream the handler builds, through the
//! production stack: the head leaves before the body is complete and each
//! chunk as the stream produces it, the request's access record and the
//! usage on it cover the whole stream, a client that stops reading stalls the stream
//! without losing a byte or its worker slot, a stream that errors after its
//! head resets the client's stream while the worker keeps serving, and a
//! client that resets its stream frees the worker's slot at once. The route
//! is `fixtures/local_e2e/api/stream.js`, whose responses carry the worker's
//! token in `x-worker-token`. The client's frame instants
//! (`H2Response.head_ns` and the DATA instants, `runtime/tests/support/tls/`)
//! show when each part left the server. Lane `local-e2e`; the worker's side
//! of a streamed response runs without a server in `worker/tests/`.

const std = @import("std");
const http_body = @import("collo_limits").http_body;
const process = @import("collo_os").process;
const harness_mod = @import("harness.zig");

const Harness = harness_mod.Harness;
const Client = harness_mod.Client;
const Response = harness_mod.Response;
const AccessLine = harness_mod.AccessLine;
const expectStatus = harness_mod.expectStatus;

/// RST_STREAM's INTERNAL_ERROR and CANCEL (RFC 9113 section 7).
const h2_internal_error: u32 = 0x2;
const h2_cancel: u32 = 0x8;

/// Twice what can leave the worker while the client reads nothing: the
/// chunks of the response's credit, which the server holds, and what the
/// client's flow-control windows let the server send, at most its stream
/// window (`INITIAL_WINDOW_SIZE` in `runtime/tests/support/tls/tls_shim.cc`).
const stalled_body_bytes: u64 = 2 * (http_body.INGRESS_RESPONSE_CHUNKS_IN_FLIGHT_MAX *
    http_body.INGRESS_RESPONSE_CHUNK_BYTES + client_stream_window_bytes);
const client_stream_window_bytes: usize = 1024 * 1024;
/// How long the slow client reads nothing.
const stall_ns: u64 = 2 * std.time.ns_per_s;

/// The fields of a `logs.jsonl` record the stream tests check; a drop marker
/// has no message.
const LogLine = struct {
    message: []const u8 = "",
};

/// The token of a response of `/stream`; any other status fails the test.
fn workerToken(response: *const Response, buffer: []u8) ![]const u8 {
    try expectStatus(response, 200);
    const block_len: usize = @intCast(response.raw.header_block_len);
    var headers = try harness_mod.decodeResponseHeaders(response.raw.header_block[0..block_len]);
    defer headers.deinit(std.testing.allocator);
    const token = harness_mod.headerValue(&headers, "x-worker-token") orelse return error.MissingWorkerToken;
    if (token.len > buffer.len) return error.InvalidWorkerToken;
    @memcpy(buffer[0..token.len], token);
    return buffer[0..token.len];
}

fn expectContentType(response: *const Response, expected: []const u8) !void {
    const block_len: usize = @intCast(response.raw.header_block_len);
    var headers = try harness_mod.decodeResponseHeaders(response.raw.header_block[0..block_len]);
    defer headers.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, harness_mod.headerValue(&headers, "content-type") orelse "");
}

/// The body of a response that ended with END_STREAM, all of which the
/// client kept.
fn completeBody(response: *const Response) ![]const u8 {
    if (response.raw.reset != 0) {
        std.debug.print("the stream was reset with code {d} after: {s}\n", .{ response.raw.reset_code, response.body() });
        return error.UnexpectedStreamReset;
    }
    if (response.raw.body_len > response.raw.body.len) return error.ResponseBodyTruncated;
    return response.body();
}

test "a server-sent events response delivers each event as it is produced, before its stream closes, and its records cover the whole stream" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    const events = "data: 0\n\ndata: 1\n\ndata: 2\n\n";
    const response = try client.get("/stream?events=3&ms=300");
    try expectStatus(&response, 200);
    try expectContentType(&response, "text/event-stream");
    try std.testing.expectEqualStrings(events, try completeBody(&response));

    // Each event left the worker when the stream produced it, 300 ms after
    // the one before: a body sent whole at the end would arrive in one burst.
    const raw = response.raw;
    try std.testing.expect(raw.data_frame_count >= 3);
    try std.testing.expect(raw.head_ns != 0);
    try std.testing.expect(raw.head_ns <= raw.first_data_ns);
    try std.testing.expect(raw.last_data_ns - raw.first_data_ns >= 500 * std.time.ns_per_ms);
    try std.testing.expect(raw.end_ns - raw.head_ns >= 500 * std.time.ns_per_ms);

    // This is the harness's only request, so the file holds one record,
    // written once the request ended. Its wall time runs from the dispatch
    // past the last event, which the stream made 600 ms after the first, and
    // it counts the bytes of every event.
    var access = try harness_mod.waitForRecordLines(AccessLine, &harness, "access.jsonl", 1);
    defer access.deinit();
    try std.testing.expectEqual(@as(usize, 1), access.items.len);
    const access_record = access.items[0];
    try std.testing.expectEqualStrings("/stream", access_record.route);
    try std.testing.expectEqual(@as(u16, 200), access_record.status);
    try std.testing.expectEqualStrings("done", access_record.error_code);
    try std.testing.expectEqualStrings("worker", access_record.origin orelse return error.TestExpectedUsage);
    try std.testing.expect((access_record.wall_ns orelse 0) >= 600 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(?u64, events.len), access_record.client_served_bytes);
}

test "a slow client stalls a streamed body without losing a byte or the worker's slot, and the stream finishes once it reads" {
    var harness: Harness = undefined;
    try harness.init(.{ .lane_count = 2 });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("stream");
    var client = try Client.open(&harness);
    defer client.close();

    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/stream?bytes={d}", .{stalled_body_bytes});
    const stream_id = try client.sendGet(path);

    // The client reads nothing for `stall_ns`, and the request keeps its
    // slot on the worker all along. The body is larger than what can leave
    // the worker meanwhile (`stalled_body_bytes`), so it arrives whole and
    // without a reset only if the worker stops producing until the client
    // reads again.
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 1);
    const stall_started_ns = try process.monotonicNowNs();
    // A second connection must finish on the same worker while the first
    // one reads nothing. Its request shares the worker's socket and rings.
    var sibling_client = try Client.open(&harness);
    defer sibling_client.close();
    const sibling_response = try sibling_client.get("/stream?events=1");
    try std.testing.expectEqualStrings("data: 0\n\n", try completeBody(&sibling_response));
    var sibling_token_buffer: [64]u8 = undefined;
    const sibling_token = try workerToken(&sibling_response, &sibling_token_buffer);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 1);
    while (try process.monotonicNowNs() - stall_started_ns < stall_ns) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        const worker = try harness_mod.soleLiveWorker(&harness, definition);
        try std.testing.expectEqual(@as(u8, 1), worker.slots_held);
    }

    const response = try client.readResponse(stream_id);
    try expectStatus(&response, 200);
    try std.testing.expectEqual(@as(u8, 0), response.raw.reset);
    // The count shows no byte was lost; the prefix the client keeps
    // (`H2Response.body`) shows what the bytes are.
    try std.testing.expectEqual(stalled_body_bytes, response.raw.body_len);
    for (response.body()) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
    var first_token_buffer: [64]u8 = undefined;
    const first_token = try workerToken(&response, &first_token_buffer);
    try std.testing.expectEqualStrings(first_token, sibling_token);

    // The worker that streamed it serves the connection's next request.
    const next = try client.get("/stream?events=1");
    try std.testing.expectEqualStrings("data: 0\n\n", try completeBody(&next));
    var next_token_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(first_token, try workerToken(&next, &next_token_buffer));
}

test "a stream that errors after its head resets the client's stream after the bytes it sent, and the worker keeps serving" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    // The head and two events went out before the stream failed, so the
    // client sees them, then a reset in place of END_STREAM.
    const failed = try client.get("/stream?events=5&ms=50&fail=2");
    try expectStatus(&failed, 200);
    try std.testing.expectEqual(@as(u8, 1), failed.raw.reset);
    try std.testing.expectEqual(h2_internal_error, failed.raw.reset_code);
    try std.testing.expectEqualStrings("data: 0\n\ndata: 1\n\n", failed.body());
    var failed_token_buffer: [64]u8 = undefined;
    const failed_token = try workerToken(&failed, &failed_token_buffer);

    // The connection and the worker both outlive the failed stream.
    const next = try client.get("/stream?events=1");
    try std.testing.expectEqualStrings("data: 0\n\n", try completeBody(&next));
    var next_token_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(failed_token, try workerToken(&next, &next_token_buffer));

    // The failed request is recorded as the exception that ended it, and the
    // tenant's log holds the error the stream raised.
    try std.testing.expectEqual(@as(usize, 1), try waitForMatchingLines(AccessLine, &harness, "access.jsonl", isExceptionRecord));
    try std.testing.expect(try waitForMatchingLines(LogLine, &harness, "logs.jsonl", namesStreamFailure) >= 1);
}

test "a client that resets a streamed response frees the worker's slot, is recorded as gone, and the worker keeps serving" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("stream");
    var client = try Client.open(&harness);
    defer client.close();

    // A stream that would run for ten seconds: the client takes its head and
    // first event while the request holds its slot, then cancels it.
    // `resetStream` fails on a stream whose END_STREAM or RST_STREAM the
    // client has read, so none had arrived before the reset.
    const stream_id = try client.sendGet("/stream?events=100&ms=100");
    try client.readBodyAtLeast(stream_id, "data: 0\n\n".len);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 1);
    const reset_ns = try process.monotonicNowNs();
    try client.resetStream(stream_id, h2_cancel);

    // The server passes the reset to the worker, which ends the request as
    // `client_closed` and cancels the stream, so the slot comes back long
    // before the stream would end.
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 0);
    try std.testing.expect(try process.monotonicNowNs() - reset_ns < std.time.ns_per_s);

    const reset = try client.readResponse(stream_id);
    try std.testing.expect(std.mem.startsWith(u8, reset.body(), "data: 0\n\n"));
    var reset_token_buffer: [64]u8 = undefined;
    const reset_token = try workerToken(&reset, &reset_token_buffer);

    // The same connection and worker serve the next request.
    const next = try client.get("/stream?events=1");
    try std.testing.expectEqualStrings("data: 0\n\n", try completeBody(&next));
    var next_token_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(reset_token, try workerToken(&next, &next_token_buffer));

    // The cancelled request is recorded as one the client left.
    try std.testing.expectEqual(@as(usize, 1), try waitForMatchingLines(AccessLine, &harness, "access.jsonl", isClientGoneRecord));
}

fn isExceptionRecord(record: AccessLine) bool {
    return std.mem.eql(u8, record.error_code, "js_exception");
}

/// The client took the stream's 200 head before it reset the stream, so the
/// record carries the status the client received and the error code says it
/// left (`server/ingress/runner/request_finish.zig:workerDoneStatus`).
fn isClientGoneRecord(record: AccessLine) bool {
    return record.status == 200 and std.mem.eql(u8, record.error_code, "client_closed");
}

fn namesStreamFailure(line: LogLine) bool {
    return std.mem.indexOf(u8, line.message, "stream failed on purpose") != null;
}

/// Polls `file_name` until some of its records match `matches`, the metrics
/// thread writing them every tick, and returns how many do then.
fn waitForMatchingLines(
    comptime Line: type,
    harness: *Harness,
    file_name: []const u8,
    comptime matches: fn (Line) bool,
) !usize {
    for (0..record_polls_max) |_| {
        var lines = try harness_mod.waitForRecordLines(Line, harness, file_name, 0);
        defer lines.deinit();
        var count: usize = 0;
        for (lines.items) |line| {
            if (matches(line)) count += 1;
        }
        if (count != 0) return count;
        std.Thread.sleep(record_poll_interval_ns);
    }
    return error.AnalyticsRecordsNotObserved;
}

/// Polls `waitForMatchingLines` makes, `record_poll_interval_ns` apart.
const record_polls_max: usize = 200;
const record_poll_interval_ns: u64 = 10 * std.time.ns_per_ms;
