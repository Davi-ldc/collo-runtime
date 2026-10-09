//! How the server shares workers among requests and lanes, seen from clients
//! against real sandboxed workers: two connections on two lanes served at
//! once by one worker, a steady load on one connection served by the one
//! worker its first request launched, a deadline that ends its request and
//! keeps its worker, a worker's death answered on every lane that held one of
//! its requests, and request bodies that meet a worker running synchronous
//! JavaScript or a worker that dies. The routes answer with a token drawn
//! once per worker process (`fixtures/local_e2e/api/token.js`), which tells
//! whether two responses came from one worker. Lane `local-e2e`; the pool's
//! own rules run without a server in `server/tests/supervisor/`, and a lane
//! against stub workers in `server/tests/ingress/`.

const std = @import("std");
const harness_mod = @import("harness.zig");

const Harness = harness_mod.Harness;
const Client = harness_mod.Client;
const LaunchTrace = harness_mod.LaunchTrace;
const tokenOf = harness_mod.tokenOf;
const uploadReplyOf = harness_mod.uploadReplyOf;

/// Requests of the steady load: enough that, with the old one-request
/// workers, several would meet the worker still finishing the one before.
const steady_requests: usize = 64;
/// A body well past the worker's control socket buffer, about 208 KiB by
/// default, and past the stream's receive window, 512 KiB, so the lane holds
/// part of it and the client waits for credit.
const upload_bytes: u64 = 2 * 1024 * 1024;
/// The part of the body a client sends before its worker is killed.
const partial_upload_bytes: u64 = 256 * 1024;
/// DATA frames of the uploads: each chunk stays under the payload ring's
/// threshold, so it travels inline on the worker's control socket
/// (`shared_payload_threshold` in `common/ipc/ingress_channel/payload_ring.zig`).
const upload_frame_bytes: u32 = 16 * 1024;

test "two connections on two lanes are served at once by one worker and both get their responses" {
    var harness: Harness = undefined;
    try harness.init(.{ .lane_count = 2 });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("token");

    var lane_zero = try harness_mod.openClientOnLane(&harness, 0);
    defer lane_zero.close();
    var lane_one = try harness_mod.openClientOnLane(&harness, 1);
    defer lane_one.close();

    // The first request launches the route's worker, and lane 0, whose
    // request took the worker's first slot, reads it from then on
    // (`server/supervisor/pool.zig`). Its slot comes back once the lane
    // drains the worker's completion, which can trail the response.
    const warm = try lane_zero.get("/token");
    const token = try tokenOf(&warm);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // Each request holds the worker long enough for the other to arrive, so
    // the worker runs both at once. Lane 1's response comes back through
    // lane 0, the worker's reader, which forwards it to lane 1.
    const from_lane_one = try lane_one.sendGet("/token?ms=500");
    const from_lane_zero = try lane_zero.sendGet("/token?ms=500");
    const one = try lane_one.readResponse(from_lane_one);
    const zero = try lane_zero.readResponse(from_lane_zero);
    try std.testing.expect(token.eql(try tokenOf(&one)));
    try std.testing.expect(token.eql(try tokenOf(&zero)));

    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 1), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);
}

test "a steady load on one connection is served by the one worker its first request launched" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("token");

    var client = try Client.open(&harness);
    defer client.close();

    // Each request follows the previous response at once, so it often
    // reaches the lane before the worker's completion of the previous one
    // does. The worker then still holds that request's slot, and the new
    // request takes its other slot instead of launching a second worker.
    const first = try client.get("/token");
    const token = try tokenOf(&first);
    for (1..steady_requests) |_| {
        const response = try client.get("/token");
        try std.testing.expect(token.eql(try tokenOf(&response)));
    }

    var traces: [16]LaunchTrace = undefined;
    const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
    try std.testing.expectEqual(@as(usize, 1), launches.published);
    try std.testing.expectEqual(@as(usize, 0), launches.failed);
}

test "a request past its deadline is answered 504 while its worker serves the request beside it and the next one" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("deadline");

    var held = try Client.open(&harness);
    defer held.close();
    var other = try Client.open(&harness);
    defer other.close();

    const warm = try other.get("/deadline");
    const token = try tokenOf(&warm);
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // The route's deadline is 1000 ms (`fixtures/local_e2e/collo.json`). The
    // held request never answers by itself; the other one arrives 500 ms
    // later and answers 600 ms after that, so both run on the worker when
    // the first one's deadline passes and the worker answers it 504 itself.
    const hanging = try held.sendGet("/deadline?hang=1");
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 1);
    std.Thread.sleep(500 * std.time.ns_per_ms);
    const beside = try other.sendGet("/deadline?ms=600");
    const timed_out = try held.readResponse(hanging);
    try std.testing.expectEqual(@as(u16, 504), timed_out.status);
    const answered = try other.readResponse(beside);
    try std.testing.expect(token.eql(try tokenOf(&answered)));

    // The deadline ended its request and left the worker serving.
    const next = try other.get("/deadline");
    try std.testing.expect(token.eql(try tokenOf(&next)));
    const after = try harness_mod.soleLiveWorker(&harness, definition);
    try std.testing.expect(after.key.eql(worker.key));
}

test "a worker killed while it holds requests from two lanes answers both 502 and a new worker serves the next request" {
    var harness: Harness = undefined;
    try harness.init(.{ .lane_count = 2 });
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("token");

    var lane_zero = try harness_mod.openClientOnLane(&harness, 0);
    defer lane_zero.close();
    var lane_one = try harness_mod.openClientOnLane(&harness, 1);
    defer lane_one.close();

    // Both requests below must reach the worker the first one launched, so
    // they wait for its slot to come back.
    const warm = try lane_zero.get("/token");
    const token = try tokenOf(&warm);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 0);
    const from_lane_one = try lane_one.sendGet("/token?hang=1");
    const from_lane_zero = try lane_zero.sendGet("/token?hang=1");
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 2);
    try harness_mod.killWorker(worker);

    // Lane 0 reads the worker and sees it die; lane 1 holds a request on it
    // and hears of the death from lane 0. Neither response head went out,
    // so each request is answered 502.
    const zero = try lane_zero.readResponse(from_lane_zero);
    const one = try lane_one.readResponse(from_lane_one);
    try std.testing.expectEqual(@as(u16, 502), zero.status);
    try std.testing.expectEqual(@as(u16, 502), one.status);

    const next = try lane_one.get("/token");
    try std.testing.expect(!token.eql(try tokenOf(&next)));
}

test "an upload past the worker's control socket buffer reaches whole a worker running synchronous JavaScript" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);

    var client = try Client.open(&harness);
    defer client.close();

    // For a second the handler runs JavaScript and reads nothing. The lane's
    // sends fill the worker's control socket, the rest of the body waits in
    // the lane behind the socket's writability, and the client waits for
    // flow-control credit until the handler reads the body.
    const stream = try client.sendPost("/upload?spin_ms=1000", upload_bytes);
    try std.testing.expectEqual(upload_bytes, try client.sendBody(stream, upload_bytes, upload_frame_bytes, true));
    const response = try client.readResponse(stream);
    const reply = try uploadReplyOf(&response);
    try std.testing.expectEqual(upload_bytes, reply.length);

    // The connection and the worker keep serving.
    const next_stream = try client.sendPost("/upload", 0);
    const next = try client.readResponse(next_stream);
    const next_reply = try uploadReplyOf(&next);
    try std.testing.expectEqual(@as(u64, 0), next_reply.length);
    try std.testing.expect(reply.token.eql(next_reply.token));
}

test "a worker killed mid-upload answers the upload 502 and the lane serves the next request" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    const definition = try harness.definitionIndex("upload");

    var client = try Client.open(&harness);
    defer client.close();

    // An empty upload launches the route's worker first. Once its slot is
    // back, the next upload reaches that worker at once and is the one
    // request it holds.
    const warm_stream = try client.sendPost("/upload", 0);
    const warm = try client.readResponse(warm_stream);
    const warm_reply = try uploadReplyOf(&warm);
    _ = try harness_mod.waitForSlotsHeld(&harness, definition, 0);

    // The handler waits for the whole body, which never comes: the client
    // sends part of it and the worker dies while its request reads.
    const stream = try client.sendPost("/upload", upload_bytes);
    _ = try client.sendBody(stream, partial_upload_bytes, upload_frame_bytes, false);
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 1);
    try harness_mod.killWorker(worker);
    const response = try client.readResponse(stream);
    try std.testing.expectEqual(@as(u16, 502), response.status);

    // The lane serves the next request, from a new worker.
    const next_stream = try client.sendPost("/upload", 0);
    const next = try client.readResponse(next_stream);
    const next_reply = try uploadReplyOf(&next);
    try std.testing.expect(!warm_reply.token.eql(next_reply.token));
}
