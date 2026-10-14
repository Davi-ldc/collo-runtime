//! The answers an ingress lane gives a stream before admitting it
//! (`runner/admission.zig`, `answerUnadmitted`), each with the access record
//! it calls for: 431 for a head over a head's bounds, 400 for a head whose
//! block decoded but is malformed, 413 for a declared body over the bound,
//! named by its route, 404, and 503 while the server stops, each under a
//! fresh request id from the server with its first byte stamped; the health
//! answer and a refused stream with none. Also the lane's own answer to a
//! dispatched request's body, which that request's record reports instead of
//! the worker's status. Lane `server-ingress-test`, through
//! `lane_harness.zig`; the HTTP/2 layer's side of a refused head is covered
//! in `server/tests/http2/connection.zig`, and these answers through a real
//! server in `local-e2e`.

const std = @import("std");
const h2 = @import("collo_http").http2;
const hpack = @import("collo_hpack");
const limits = @import("collo_limits");
const lane_harness = @import("lane_harness.zig");

const Harness = lane_harness.Harness;
const OneWorker = lane_harness.OneWorker;
const access = @import("collo_server_analytics").access;
const http2_request = lane_harness.ingress.http2.request_head;

/// The route the harness's default path matches, and its definition.
const default_route = "/demo/*";
const default_worker = "demo";

/// Asserts the record of an answer the lane gave alone: from the server,
/// with no worker, a fresh request id, `done` as its error code, and its
/// first byte stamped, since the answer was queued.
fn expectServerRecord(record: access.AccessRecord, status: u16) !void {
    try std.testing.expectEqual(status, record.status);
    try std.testing.expectEqual(access.AnsweredBy.server, record.answered_by);
    try std.testing.expect(record.facts.request_id != 0);
    try std.testing.expectEqual(@as(u64, 0), record.facts.worker_id);
    try std.testing.expectEqual(access.ErrorCode.done, record.facts.error_code);
    // No worker took it, so it carries no usage.
    try std.testing.expect(record.usage == null);
    try std.testing.expect(record.facts.first_byte_mono_ns != 0);
    try std.testing.expect(record.ttfbMs() >= 1);
}

test "a head with more fields than a head may hold gets 431 and one access record, and its connection keeps serving" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;

    // One field past the decoder's bound: the block decodes whole and is
    // refused, so no field of it reaches the record.
    var fields: [http2_request.max_header_count + 1]hpack.Header = undefined;
    fields[0] = .{ .name = ":method", .value = "GET" };
    fields[1] = .{ .name = ":scheme", .value = "https" };
    fields[2] = .{ .name = ":authority", .value = lane_harness.authority };
    fields[3] = .{ .name = ":path", .value = lane_harness.default_path };
    for (fields[4..]) |*field|
        field.* = .{ .name = "x-repeat", .value = "1" };
    try scene.client.requestFields(1, &fields, .{});
    try scene.client.drive();
    try scene.expectStatus(1, 431);

    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try expectServerRecord(record, 431);
    try std.testing.expectEqualStrings("", record.facts.methodSlice());
    try std.testing.expectEqualStrings("", record.facts.pathSlice());
    try std.testing.expectEqualStrings("", record.facts.routeSlice());
    try std.testing.expect(harness.takeAccessRecord(0) == null);

    // The next request on the connection reaches the worker.
    const next = try scene.get(3);
    try scene.stub.answer(next, 200, "after");
    try harness.handleControl(0, scene.stub);
    try scene.expectStatus(3, 200);
    const served = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    // Every record of the connection has its own request id.
    try std.testing.expect(served.facts.request_id != record.facts.request_id);
    try harness.expectLanesRunning();
}

test "a head whose block decoded but is malformed gets 400 and one access record with its method and path" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;

    // A host naming another origin than `:authority` (RFC 9113 §8.3.1).
    try scene.client.requestFields(1, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = lane_harness.authority },
        .{ .name = ":path", .value = "/demo/forged?x=1" },
        .{ .name = "host", .value = "other.example.test" },
        .{ .name = "user-agent", .value = "probe/1" },
    }, .{});
    try scene.client.drive();
    try scene.expectStatus(1, 400);
    try std.testing.expect((try scene.client.stream(1)).ended);

    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try expectServerRecord(record, 400);
    try std.testing.expectEqualStrings("GET", record.facts.methodSlice());
    try std.testing.expectEqualStrings("/demo/forged", record.facts.pathSlice());
    try std.testing.expectEqualStrings("probe/1", record.facts.userAgentSlice());
    // A malformed head's path is never matched.
    try std.testing.expectEqualStrings("", record.facts.routeSlice());
    try std.testing.expect(scene.client.open());
    try harness.expectLanesRunning();
    // The worker heard nothing of it.
    try std.testing.expect(!try scene.stub.controlReadable());
}

test "a declared body over the bound on a matched path gets 413, a record naming the route, and a request to stop sending" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;

    try scene.client.request(1, "POST", lane_harness.default_path, .{
        .body_follows = true,
        .content_length = limits.http_body.MATERIALIZED_BODY_BYTES_MAX + 1,
    });
    try scene.client.drive();
    try scene.expectStatus(1, 413);
    // The client had not ended its request, so the answer asks it to stop
    // (RFC 9113 §8.1).
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.no_error)), (try scene.client.stream(1)).reset_code);

    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try expectServerRecord(record, 413);
    try std.testing.expectEqualStrings(default_route, record.facts.routeSlice());
    try std.testing.expectEqualStrings(default_worker, record.facts.workerSlice());
    try std.testing.expectEqualStrings("POST", record.facts.methodSlice());
    try std.testing.expect(!try scene.stub.controlReadable());
    try harness.expectLanesRunning();
}

test "a path no route matches gets 404 with a record whose first byte is the answer's" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;

    try scene.client.request(1, "GET", "/nowhere", .{});
    try scene.client.drive();
    try scene.expectStatus(1, 404);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try expectServerRecord(record, 404);
    try std.testing.expectEqualStrings("/nowhere", record.facts.pathSlice());
    try std.testing.expectEqualStrings("", record.facts.routeSlice());
}

test "a matched stream while the server stops gets 503 and a record naming its route" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;

    harness.service.requestStopSignal();
    try scene.client.get(1);
    try scene.client.drive();
    try scene.expectStatus(1, 503);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try expectServerRecord(record, 503);
    try std.testing.expectEqualStrings(default_route, record.facts.routeSlice());
    try std.testing.expect(!try scene.stub.controlReadable());
}

test "the health answer and a refused stream write no access record, and a refused stream is counted" {
    var harness: Harness = undefined;
    try harness.init(std.testing.allocator, .{ .table_capacities = .{ .requests = 1 } });
    defer harness.deinit();
    const stub = try harness.publishWorker(.{});
    const client = try harness.connect(0, .{});

    try client.request(1, "GET", "/__collo/healthz", .{});
    try client.drive();
    try client.collect();
    try std.testing.expect((try client.stream(1)).status != null);
    try std.testing.expect(harness.takeAccessRecord(0) == null);

    // The one request slot holds stream 3's request, so stream 5 is refused.
    try client.get(3);
    try client.get(5);
    try client.drive();
    const held = try stub.readRequestBegin();
    try client.expectReset(5);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(h2.ErrorCode.refused_stream)), (try client.stream(5)).reset_code);
    try std.testing.expectEqual(@as(u64, 1), harness.lane(0).lane.counters.streams_refused);
    try std.testing.expect(harness.takeAccessRecord(0) == null);

    try stub.answer(held, 200, "held");
    try harness.handleControl(0, stub);
    try client.expectStatus(3, 200);
    try harness.expectLanesRunning();
}

test "a dispatched request whose body passes its declared length records the lane's 400 from the server, not the worker's status" {
    var scene: OneWorker = undefined;
    try scene.init(.{});
    defer scene.deinit();
    const harness = &scene.harness;

    const request = try scene.post(1, 5);
    try scene.client.data(1, "123456", true);
    try scene.client.drive();
    try scene.expectStatus(1, 400);

    // The lane cancelled the request toward the worker, which ends it as the
    // client's departure.
    try scene.stub.sendDone(request, .{ .http_status = 499, .done = .client_closed });
    try harness.handleControl(0, scene.stub);
    const record = harness.takeAccessRecord(0) orelse return error.AccessRecordMissing;
    try std.testing.expectEqual(@as(u16, 400), record.status);
    try std.testing.expectEqual(access.AnsweredBy.server, record.answered_by);
    try std.testing.expectEqual(access.ErrorCode.bad_request, record.facts.error_code);
    // The request still ran on its worker, which the record names.
    try std.testing.expectEqual(scene.stub.key.worker_id, record.facts.worker_id);
    try harness.expectLanesRunning();
    try harness.expectServing(scene.stub);
}
