//! The local full flow: the server on a TLS listener serving the routes of
//! `fixtures/local_e2e/collo.json`, a zygote that forks fully sandboxed
//! workers, and, for a configuration that grants `network`, the egress
//! gateway behind them. The tests here drive it with h2 clients from the TLS
//! test shim and check responses, deadlines, the handler's `env`, the routes
//! of one definition served by one worker in a realm each and in one shared
//! realm, a module loaded through `import()` from the definition's pack, the
//! paths and the heads the server answers itself (404, 431, 413 and 400),
//! each with one record under an id of its own, the analytics records, the
//! gateway's OOM score, and a worker that outlives its gateway: a gateway
//! killed mid-fetch fails that fetch with a TypeError, the worker keeps
//! serving, and its fetches reach the origin again once the launcher
//! attaches it to the next gateway. Four benchmarks run only when their
//! environment variable is set. The static fixture grants no route any
//! network access; the tests that fetch write a configuration that grants
//! their origin. How the server shares, loses and retires workers across
//! requests and lanes is covered in `workers.zig`, what the `network`
//! setting admits and denies in `network.zig`, bodies streamed from a
//! ReadableStream in `streams.zig`, and a definition's `cpuMs`, `timeoutMs`
//! for JavaScript no request owns, `concurrency` and `memoryMiB` in
//! `limits.zig`, all of which this file brings into the lane, and the stack
//! they drive is `harness.zig`. Lane: `local-e2e`
//! (`skills/runtime/references/e2e.md`). The installed binary's own boot and
//! shutdown under `collo serve` belong to the serve smoke
//! (`runtime/tests/support/serve_smoke.zig`).
//!
//! The server runs on a thread of the test process, while the zygote, its
//! workers and the gateway are processes of their own; every test owns its
//! own stack in a `Harness`. The lane runs from the repository root, which
//! anchors the fixture paths, and needs the delegated cgroup subtree and a
//! kernel with a usable kTLS cipher; without either a test skips. A test that
//! fetches through the gateway also skips on a host with no routable IPv4
//! address (`origin.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const server_main = @import("collo_server_main");
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const zygote_support = @import("zygote_support");
const harness_mod = @import("harness.zig");
const network_mod = @import("network.zig");
const origin_mod = @import("origin.zig");

const tls_shim = @import("collo_test_tls_shim");
const TlsMaterial = tls_shim.TlsMaterial;
const H2ServerResult = tls_shim.H2ServerResult;
const H2GetTimings = tls_shim.H2GetTimings;
const collo_test_h2_server_roundtrip = tls_shim.collo_test_h2_server_roundtrip;
const collo_test_h2_server_get = tls_shim.collo_test_h2_server_get;
const collo_test_h2_server_get_timed = tls_shim.collo_test_h2_server_get_timed;
const collo_test_h2_server_get_pair = tls_shim.collo_test_h2_server_get_pair;
const collo_test_tls_last_error = tls_shim.collo_test_tls_last_error;

const Harness = harness_mod.Harness;
const Client = harness_mod.Client;
const LaunchTrace = harness_mod.LaunchTrace;
const h2Get = harness_mod.h2Get;
const tokenOf = harness_mod.tokenOf;
const decodeResponseHeaders = harness_mod.decodeResponseHeaders;
const headerValue = harness_mod.headerValue;
const responseStatus = harness_mod.responseStatus;
const waitForCompletedRequests = harness_mod.waitForCompletedRequests;
const waitForRecordLines = harness_mod.waitForRecordLines;
const dumpZygoteTrace = harness_mod.dumpZygoteTrace;
const GzipOrigin = origin_mod.GzipOrigin;
const gzipRoutePath = origin_mod.gzipRoutePath;

comptime {
    _ = @import("workers.zig");
    _ = @import("streams.zig");
    _ = @import("limits.zig");
    _ = network_mod;
}

test "local e2e drives TLS ALPN h2 through server worker streams" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    // One connection, three streams: a GET with a route parameter, a POST
    // whose body crosses the ingress channel, and a 4 MiB response.
    const before = harness.runtime_server.countersSnapshot();
    var result: H2ServerResult = undefined;
    if (collo_test_h2_server_roundtrip(harness.port(), &harness.tls_material, &result) != 0) {
        std.debug.print("HTTP/2 server helper failed: {s}\n", .{std.mem.span(collo_test_tls_last_error())});
        return error.H2ServerRoundtripFailed;
    }

    try std.testing.expect(result.get_body_len <= result.get_body.len);
    try std.testing.expect(result.post_body_len <= result.post_body.len);
    try std.testing.expectEqualStrings(
        "{\"message\":\"hello h2\",\"x\":\"7\"}",
        result.get_body[0..@intCast(result.get_body_len)],
    );
    try std.testing.expectEqualStrings(
        "{\"body\":\"alpha-omega\",\"length\":11}",
        result.post_body[0..@intCast(result.post_body_len)],
    );
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024), result.large_body_len);
    try std.testing.expect(result.header_frame_count >= 3);
    try std.testing.expect(result.data_frame_count >= 3);
    try waitForCompletedRequests(&harness.runtime_server, before.completed_requests + 3);

    const delta = server_main.ingress.lane.CounterSnapshot.diff(harness.runtime_server.countersSnapshot(), before);
    try std.testing.expect(delta.ingress_channels_started >= 3);
    try std.testing.expect(delta.h2_request_body_frames >= 2);
    try std.testing.expect(delta.h2_request_body_bytes >= 11);
    try std.testing.expect(delta.ingress_response_body_bytes >= 4 * 1024 * 1024);
}

test "local e2e maps a hung route's deadline to the server timeout response and reclaims the slot" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    const before = harness.runtime_server.countersSnapshot();
    var body_buf: [256]u8 = undefined;
    var header_block_buf: [1024]u8 = undefined;
    // The handler awaits a promise that never settles. Its event loop stays
    // free, so the worker answers its own deadline with the 504 and the
    // lane's deadline wheel, which only backs it up, is cancelled.
    const reply = try h2Get(&harness, "/hang-before", &body_buf, &header_block_buf);
    var headers = try decodeResponseHeaders(reply.header_block);
    defer headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 504), try responseStatus(&headers));
    try std.testing.expectEqualStrings("gateway timeout", reply.body);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", headerValue(&headers, "content-type").?);
    try waitForCompletedRequests(&harness.runtime_server, before.completed_requests + 1);

    // The lane still serves after the timeout.
    var second_body_buf: [256]u8 = undefined;
    var second_header_block_buf: [1024]u8 = undefined;
    const second = try h2Get(&harness, "/hello/reclaimed?x=1", &second_body_buf, &second_header_block_buf);
    var second_headers = try decodeResponseHeaders(second.header_block);
    defer second_headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(&second_headers));
    try std.testing.expectEqualStrings("{\"message\":\"hello reclaimed\",\"x\":\"1\"}", second.body);
    try waitForCompletedRequests(&harness.runtime_server, before.completed_requests + 2);
}

test "local e2e interrupts a synchronously spinning worker at its deadline sentinel and reclaims the route" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    const before = harness.runtime_server.countersSnapshot();
    var body_buf: [256]u8 = undefined;
    var header_block_buf: [1024]u8 = undefined;
    // The handler spins without yielding. The worker's deadline sentinel
    // interrupts the VM mid-spin, the worker serves the 504 and stops after
    // the drain, because the interrupted VM cannot run JavaScript again.
    const reply = try h2Get(&harness, "/hang-sync", &body_buf, &header_block_buf);
    var headers = try decodeResponseHeaders(reply.header_block);
    defer headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 504), try responseStatus(&headers));
    try std.testing.expectEqualStrings("gateway timeout", reply.body);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", headerValue(&headers, "content-type").?);
    try waitForCompletedRequests(&harness.runtime_server, before.completed_requests + 1);

    // A fresh worker serves the next request.
    var second_body_buf: [256]u8 = undefined;
    var second_header_block_buf: [1024]u8 = undefined;
    const second = try h2Get(&harness, "/hello/wheelreclaim?x=2", &second_body_buf, &second_header_block_buf);
    var second_headers = try decodeResponseHeaders(second.header_block);
    defer second_headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(&second_headers));
    try std.testing.expectEqualStrings("{\"message\":\"hello wheelreclaim\",\"x\":\"2\"}", second.body);
    try waitForCompletedRequests(&harness.runtime_server, before.completed_requests + 2);
}

test "local e2e hands a route its bindings as a frozen env and leaves process.env empty" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    // The `env` route declares one text binding; the handler reports what it
    // received and what `process.env` holds in the sandboxed worker.
    var body_buf: [256]u8 = undefined;
    var header_block_buf: [1024]u8 = undefined;
    const reply = try h2Get(&harness, "/env", &body_buf, &header_block_buf);
    var headers = try decodeResponseHeaders(reply.header_block);
    defer headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(&headers));
    try std.testing.expectEqualStrings("{\"token\":\"e2e-token\",\"frozen\":true,\"processEnv\":[]}", reply.body);
}

test "local e2e serves both routes of a definition from one worker, in a realm each or in one shared realm" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    var client = try Client.open(&harness);
    defer client.close();

    // Both routes of each definition share the entry `api/realm_probe.js`,
    // which counts its module instance's requests (`hits`) and its global
    // object's (`requests`). With a realm per route each route counts alone;
    // with one shared realm the two routes count together. Either way each
    // route receives its own binding and a `Request` of its realm.
    const cases = [_]struct { definition: []const u8, paths: [3][]const u8, bodies: [3][]const u8 }{
        .{
            .definition = "realms-isolated",
            .paths = .{ "/realms/isolated/a", "/realms/isolated/b", "/realms/isolated/a" },
            .bodies = .{
                "{\"route\":\"a\",\"hits\":1,\"requests\":1,\"request\":true}",
                "{\"route\":\"b\",\"hits\":1,\"requests\":1,\"request\":true}",
                "{\"route\":\"a\",\"hits\":2,\"requests\":2,\"request\":true}",
            },
        },
        .{
            .definition = "realms-shared",
            .paths = .{ "/realms/shared/a", "/realms/shared/b", "/realms/shared/a" },
            .bodies = .{
                "{\"route\":\"a\",\"hits\":1,\"requests\":1,\"request\":true}",
                "{\"route\":\"b\",\"hits\":2,\"requests\":2,\"request\":true}",
                "{\"route\":\"a\",\"hits\":3,\"requests\":3,\"request\":true}",
            },
        },
    };
    for (cases) |case| {
        const definition = try harness.definitionIndex(case.definition);
        for (case.paths, case.bodies) |path, expected| {
            const response = try client.get(path);
            try std.testing.expectEqual(@as(u16, 200), response.status);
            try std.testing.expectEqualStrings(expected, response.body());
        }
        // The counts above already say one process served the three
        // requests; the launches say it too.
        var traces: [16]LaunchTrace = undefined;
        const launches = harness_mod.countLaunches(harness.takeLaunches(&traces), definition);
        try std.testing.expectEqual(@as(usize, 1), launches.published);
        try std.testing.expectEqual(@as(usize, 0), launches.failed);
    }
}

test "local e2e loads a module named by a string-literal import() from the route's pack and rejects one the pack lacks" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    // `api/lazy.js` reaches `api/lib/lazy_value.js` only through import():
    // the server packed it at boot from the string-literal call, the handler
    // loads the same module again through a computed specifier, and a
    // computed specifier for a module no pack holds rejects in the worker.
    var body_buf: [512]u8 = undefined;
    var header_block_buf: [1024]u8 = undefined;
    const reply = try h2Get(&harness, "/lazy", &body_buf, &header_block_buf);
    var headers = try decodeResponseHeaders(reply.header_block);
    defer headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(&headers));
    const expected = [_][]const u8{
        "\"value\":\"from the pack\"",
        "\"same\":true",
        "Cannot find module '/var/task/lib/absent.js'",
    };
    for (expected) |part| {
        if (!std.mem.containsAtLeast(u8, reply.body, 1, part)) {
            std.debug.print("expected the body to contain {s}\nbody: {s}\n", .{ part, reply.body });
            return error.TestUnexpectedBody;
        }
    }
}

test "local e2e usage and access records land in the analytics directory" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    const before = harness.runtime_server.countersSnapshot();
    var body_buf: [256]u8 = undefined;
    var header_block_buf: [1024]u8 = undefined;
    const reply = try h2Get(&harness, "/hello/usage?x=9", &body_buf, &header_block_buf);
    var headers = try decodeResponseHeaders(reply.header_block);
    defer headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(&headers));
    try std.testing.expectEqualStrings("{\"message\":\"hello usage\",\"x\":\"9\"}", reply.body);
    try waitForCompletedRequests(&harness.runtime_server, before.completed_requests + 1);

    // The metrics thread drains the worker's completion ring and the lane's
    // access ring every tick, then flushes the sink. This is the harness's
    // only request, so each file holds exactly one record for it.
    var usage = try waitForRecordLines(harness_mod.UsageLine, &harness, "usage.jsonl", 1);
    defer usage.deinit();
    var access = try waitForRecordLines(harness_mod.AccessLine, &harness, "access.jsonl", 1);
    defer access.deinit();
    try std.testing.expectEqual(@as(usize, 1), usage.items.len);
    try std.testing.expectEqual(@as(usize, 1), access.items.len);
    const usage_record = usage.items[0];
    const access_record = access.items[0];

    // Both records name the same request and the same worker, the usage
    // record names the worker definition that served it, and it is the
    // worker's own report of a request that finished.
    try std.testing.expectEqual(access_record.request_id, usage_record.request_id);
    try std.testing.expectEqual(access_record.worker_id, usage_record.worker_id);
    try std.testing.expectEqual(access_record.worker_generation, usage_record.worker_generation);
    try std.testing.expectEqualStrings("hello", usage_record.worker);
    try std.testing.expectEqualStrings("worker", usage_record.origin);
    try std.testing.expectEqualStrings("done", usage_record.error_code);
    // The server's own clock gives the usage record's wall time, from the
    // dispatch to the lane's end of the request, which lies inside the
    // access record's span from arrival to end; `duration_ms` is whole
    // milliseconds, so one more covers its rounding.
    try std.testing.expect(usage_record.wall_ns > 0);
    try std.testing.expect(usage_record.wall_ns <= (access_record.duration_ms + 1) * std.time.ns_per_ms);

    // The client address is the TCP peer the lane accepted.
    try std.testing.expectEqual(@as(u16, 200), access_record.status);
    try std.testing.expectEqualStrings("127.0.0.1", access_record.client_ip);
}

test "local e2e answers the health path and unmatched paths itself and records each 404" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    // The health path is the server's own and never reaches a worker. The
    // harness serves on one lane, with the zygote up and room in the usage
    // stream.
    var health_body: [server_main.ingress.server_responses.health_body_bytes_max]u8 = undefined;
    var health_header_block: [1024]u8 = undefined;
    const health = try h2Get(&harness, config.pattern.health_path, &health_body, &health_header_block);
    var health_headers = try decodeResponseHeaders(health.header_block);
    defer health_headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(&health_headers));
    try std.testing.expectEqualStrings("application/json", headerValue(&health_headers, "content-type").?);
    try std.testing.expectEqualStrings(
        "{\"status\":\"ok\",\"zygote\":\"alive\",\"lanes\":{\"running\":1,\"total\":1},\"usage_stream\":\"ok\"}",
        health.body,
    );

    // No route of the fixture matches the first two paths, `/healthz` being
    // an ordinary path no route claims, and the third is deeper than any
    // pattern can be.
    const unmatched = [_][]const u8{
        "/no-such-route",
        "/healthz",
        "/a" ** (routes_mod.table.path_segments_max + 1),
    };
    for (unmatched) |path| {
        var body: [8192]u8 = undefined;
        var header_block: [1024]u8 = undefined;
        const reply = try h2Get(&harness, path, &body, &header_block);
        var headers = try decodeResponseHeaders(reply.header_block);
        defer headers.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 404), try responseStatus(&headers));
    }

    // Each 404 leaves one access record that the server answered, with no
    // worker and no route, under a request id of its own; the health path
    // leaves none.
    var access = try waitForRecordLines(harness_mod.LocalAccessLine, &harness, "access.jsonl", unmatched.len);
    defer access.deinit();
    try std.testing.expectEqual(unmatched.len, access.items.len);
    for (access.items, 0..) |record, index| {
        try std.testing.expectEqual(@as(u16, 404), record.status);
        try std.testing.expectEqualStrings("server", record.answered_by);
        try std.testing.expectEqualStrings("", record.worker);
        try std.testing.expectEqualStrings("", record.route);
        try std.testing.expectEqual(@as(u64, 0), record.worker_id);
        try expectFreshRequestId(access.items[0..index], record.request_id);
    }
}

/// Fails unless `request_id` is nonzero and no record of `earlier` has it.
fn expectFreshRequestId(earlier: []const harness_mod.LocalAccessLine, request_id: u64) !void {
    try std.testing.expect(request_id != 0);
    for (earlier) |record| try std.testing.expect(record.request_id != request_id);
}

test "local e2e answers a head with too many fields, an oversized declared body and a malformed head itself, each with one record" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    // A head holds at most `ipc.max_request_header_count` + 3 fields with its
    // four pseudo-header fields (`server/ingress/http2/request_head.zig`), so
    // this many regular fields are one too many.
    const too_many_fields = ipc.max_request_header_count;
    var field_names: [too_many_fields][16:0]u8 = undefined;
    var fields: [too_many_fields]tls_shim.H2Field = undefined;
    for (&field_names, &fields, 0..) |*name, *field, index| {
        const written = try std.fmt.bufPrintZ(name, "x-field-{d}", .{index});
        field.* = .{ .name = written.ptr, .value = "v" };
    }
    const crowded = try client.readResponse(try client.sendRequestWithFields("GET", "/hello/crowded", &fields));
    try std.testing.expectEqual(@as(u16, 431), crowded.status);

    // A body declared past what a request may carry is refused on a matched
    // route before any byte of it arrives.
    const oversized = try client.readResponse(
        try client.sendPost("/echo", limits.http_body.MATERIALIZED_BODY_BYTES_MAX + 1),
    );
    try std.testing.expectEqual(@as(u16, 413), oversized.status);

    // `te` in a request may only say `trailers` (RFC 9113 §8.2.2); the head
    // decoded, so the lane answers it instead of resetting the stream.
    const te_field = [_]tls_shim.H2Field{.{ .name = "te", .value = "gzip" }};
    const malformed = try client.readResponse(try client.sendRequestWithFields("GET", "/hello/te", &te_field));
    try std.testing.expectEqual(@as(u16, 400), malformed.status);

    // One record each, answered by the server under a request id of its own;
    // the 413's names the route it matched.
    var access = try waitForRecordLines(harness_mod.LocalAccessLine, &harness, "access.jsonl", 3);
    defer access.deinit();
    try std.testing.expectEqual(@as(usize, 3), access.items.len);
    var seen_413 = false;
    for (access.items, 0..) |record, index| {
        try std.testing.expectEqualStrings("server", record.answered_by);
        try std.testing.expectEqual(@as(u64, 0), record.worker_id);
        try expectFreshRequestId(access.items[0..index], record.request_id);
        switch (record.status) {
            431, 400 => {},
            413 => {
                seen_413 = true;
                try std.testing.expectEqualStrings("echo", record.worker);
                try std.testing.expectEqualStrings("/echo", record.route);
            },
            else => {
                std.debug.print("unexpected early answer status {d}\n", .{record.status});
                return error.TestUnexpectedResult;
            },
        }
    }
    try std.testing.expect(seen_413);
}

test "local e2e fails a fetch in flight with a TypeError when the gateway dies, keeps the worker serving and fetches again after the reattach (#47)" {
    var origin = try GzipOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var fixture = try FetchTokenFixture.write(std.testing.allocator, origin);
    defer fixture.deinit(std.testing.allocator);

    var harness: Harness = undefined;
    try harness.init(.{ .config_path = fixture.config_path });
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    var fetch_buffer: [FetchTokenFixture.request_path_bytes_max]u8 = undefined;
    const fetch_path = try FetchTokenFixture.requestPath(&fetch_buffer, origin, "/gzip");
    var hold_buffer: [FetchTokenFixture.request_path_bytes_max]u8 = undefined;
    const hold_path = try FetchTokenFixture.requestPath(&hold_buffer, origin, GzipOrigin.hold_path);

    var client = try Client.open(&harness);
    defer client.close();

    // The first request launches the route's worker, and its fetch goes
    // through the gateway the harness spawned before traffic.
    const warm = try client.get(fetch_path);
    const token = try tokenOf(&warm);
    try std.testing.expectEqual(FetchResult.reached_origin, try fetchResultOf(&warm));
    const first_generation = harness.gatewayGeneration();
    try std.testing.expect(first_generation != 0);
    var killed = try harness_mod.currentGatewayProcess();
    defer killed.deinit();

    // The origin holds the next fetch open, so it is still in flight when
    // the gateway dies, and the worker fails it with a TypeError.
    const in_flight = try client.sendGet(hold_path);
    try origin.waitForHeld(1);
    try killed.kill();
    const failed = try client.readResponse(in_flight);
    try std.testing.expect(token.eql(try tokenOf(&failed)));
    try std.testing.expectEqual(FetchResult.rejected_with_type_error, try fetchResultOf(&failed));

    // The same worker answers a request that does not fetch, attached to a
    // new gateway yet or not.
    const next = try client.get(FetchTokenFixture.route_path);
    try std.testing.expect(token.eql(try tokenOf(&next)));

    // The launcher spawns the next gateway and attaches the worker to it,
    // after which the worker's fetches reach the origin again.
    try waitForFetchAfterReattach(&client, fetch_path, token);
    try std.testing.expect(harness.gatewayGeneration() > first_generation);
    // The server runs one gateway again, the one that took over.
    var replacement = try harness_mod.currentGatewayProcess();
    replacement.deinit();
}

test "local e2e gives the gateway its OOM score without any privilege" {
    // Any grant makes the server run a gateway, which the harness spawns
    // before traffic. The lane runs unprivileged, and a score at or above the
    // server's own needs no privilege to write.
    const allow = [_][]const u8{"*"};
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "granted",
        .routes = &.{.{ .path = "/hello/:name", .entry = "./api/hello.js" }},
        .network = .{ .allow = &allow },
    }});
    defer std.testing.allocator.free(configuration);

    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();
    errdefer dumpZygoteTrace(&harness.spawned);

    var gateway = try harness_mod.currentGatewayProcess();
    defer gateway.deinit();
    var path_buffer: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/oom_score_adj", .{gateway.pid});
    var contents_buffer: [16]u8 = undefined;
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const contents = contents_buffer[0..try file.readAll(&contents_buffer)];
    const score = try std.fmt.parseInt(i16, std.mem.trim(u8, contents, &std.ascii.whitespace), 10);
    try std.testing.expectEqual(limits.process.OOM_SCORE_ADJ_EGRESS_GATEWAY, score);
}

/// Fetches `waitForFetchAfterReattach` sends at most,
/// `reattach_retry_interval_ns` apart, about ten seconds in all. Spawning a
/// gateway takes milliseconds and the attach one round trip.
const reattach_fetches_max: usize = 200;
const reattach_retry_interval_ns: u64 = 50 * std.time.ns_per_ms;

/// Sends the fixture route's fetch of the origin through `client` until one
/// reaches the origin, at most `reattach_fetches_max` times. Until the
/// launcher attaches the worker to the next gateway, its fetches reject at
/// once with a TypeError. The reattach keeps the worker, so every reply must
/// come from the one `token` names.
fn waitForFetchAfterReattach(client: *Client, path: []const u8, token: harness_mod.Token) !void {
    for (0..reattach_fetches_max) |_| {
        const response = try client.get(path);
        try std.testing.expect(token.eql(try tokenOf(&response)));
        switch (try fetchResultOf(&response)) {
            .reached_origin => return,
            .rejected_with_type_error => std.Thread.sleep(reattach_retry_interval_ns),
        }
    }
    return error.FetchNotRestoredAfterReattach;
}

/// How a fetch of the fixture route ended.
const FetchResult = enum {
    /// The fetch read the origin's body, decoded.
    reached_origin,
    /// The fetch rejected with a TypeError.
    rejected_with_type_error,
};

/// The fields of the fixture route's reply that say how its fetch ended.
const FetchOutcome = struct {
    status: ?u16 = null,
    text: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// How the fetch behind a reply of the fixture route ended. An ending that
/// `FetchResult` does not name fails the test with the reply printed.
fn fetchResultOf(response: *const harness_mod.Response) !FetchResult {
    const parsed = try harness_mod.parseReply(FetchOutcome, response);
    defer parsed.deinit();
    const outcome = parsed.value;
    if (outcome.@"error") |name| {
        if (std.mem.eql(u8, name, "TypeError"))
            return .rejected_with_type_error;
    } else if (outcome.status) |status| {
        if (status == 200) {
            if (outcome.text) |text| {
                if (std.mem.eql(u8, text, GzipOrigin.decoded_body))
                    return .reached_origin;
            }
        }
    }
    std.debug.print("unexpected fetch outcome: {s}\n", .{response.body()});
    return error.UnexpectedFetchOutcome;
}

/// A temporary configuration with one route, `route_path`, granted the
/// origin, whose worker answers with a token drawn once per worker process
/// (`entry_source`). A request that names a path of the origin has the
/// worker fetch that path first, and the reply says how the fetch ended. The
/// route takes two requests at once, so a request that arrives while the
/// lane still drains the previous one's completion takes the worker's other
/// slot, and one worker serves them all.
const FetchTokenFixture = struct {
    directory: []u8,
    config_path: []u8,

    /// The one route the configuration `write` produces declares.
    const route_path = "/fetch-token";
    /// Bytes of a path `requestPath` builds: the route, the origin's IPv4
    /// address and port, and a short origin path.
    const request_path_bytes_max: usize = 128;

    const entry_source =
        \\let token = "";
        \\
        \\export default async function handler(req) {
        \\  if (token === "") token = crypto.randomUUID();
        \\  const path = req.query.get("fetch");
        \\  if (path === null) return Response.json({ token });
        \\  const target = "http://" + req.query.get("host") + ":" + req.query.get("port") + path;
        \\  try {
        \\    const res = await fetch(target);
        \\    return Response.json({ token, status: res.status, text: await res.text() });
        \\  } catch (error) {
        \\    return Response.json({ token, error: error.name, message: String(error.message) });
        \\  }
        \\}
        \\
    ;

    fn write(allocator: std.mem.Allocator, origin: *const GzipOrigin) !FetchTokenFixture {
        const directory = try zygote_support.makeTempPath(allocator, "collo-local-e2e-fetch-token");
        errdefer allocator.free(directory);
        try std.fs.makeDirAbsolute(directory);
        errdefer std.fs.deleteTreeAbsolute(directory) catch {};
        var dir = try std.fs.openDirAbsolute(directory, .{});
        defer dir.close();
        var authority_buffer: [network_mod.authority_bytes_max]u8 = undefined;
        const allow = [_][]const u8{try origin.authority(&authority_buffer)};
        const configuration = try network_mod.configText(allocator, &.{.{
            .name = "fetch-token",
            .routes = &.{.{ .path = route_path, .entry = "./entry.js" }},
            .network = try network_mod.originGrant(&allow, origin.host()),
            .concurrency = 2,
        }});
        defer allocator.free(configuration);
        try dir.writeFile(.{ .sub_path = "collo.json", .data = configuration });
        try dir.writeFile(.{ .sub_path = "entry.js", .data = entry_source });
        const config_path = try std.fs.path.join(allocator, &.{ directory, "collo.json" });
        return .{ .directory = directory, .config_path = config_path };
    }

    fn deinit(self: *FetchTokenFixture, allocator: std.mem.Allocator) void {
        std.fs.deleteTreeAbsolute(self.directory) catch {};
        allocator.free(self.config_path);
        allocator.free(self.directory);
        self.* = undefined;
    }

    /// The route's path with a request for `origin_path` of `origin`,
    /// written into `buffer`.
    fn requestPath(buffer: []u8, origin: *const GzipOrigin, origin_path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}?host={s}&port={d}&fetch={s}", .{
            route_path,
            origin.host(),
            origin.port,
            origin_path,
        });
    }
};

// Directed cold-start burst. COLLO_BENCH_BURST=<max N> enables it and caps
// the round size; each round fires its N concurrent h2 GETs on fresh
// connections at one route and prints client-side latency percentiles. The
// concurrent rounds exercise warm workers, busy ones and requests that wait
// for a launch.
test "local e2e bench: directed cold-start burst (env-gated)" {
    const burst_spec = std.posix.getenv("COLLO_BENCH_BURST") orelse return error.SkipZigTest;
    const max_burst = std.fmt.parseInt(usize, burst_spec, 10) catch return error.SkipZigTest;

    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    // Round 0 (n=1) is the route's cold start; round 1 repeats the same
    // single request against the now-warm pool. Their difference is the cold
    // start, the extra time before the request can begin, and round 1 is the
    // baseline every later, concurrent round subtracts.
    var warm_baseline_ns: u64 = 0;
    const bursts = [_]usize{ 1, 1, 4, 16, 64 };
    var lat: [64]u64 = undefined;
    var handshake: [64]u64 = @splat(0);
    var threads: [64]std.Thread = undefined;
    var cold_wall_ns: u64 = 0;
    var cold_handshake_ns: u64 = 0;
    for (bursts, 0..) |n, round| {
        if (n > max_burst or n > lat.len) break;
        var failures = std.atomic.Value(u32).init(0);
        var wrong_responses = std.atomic.Value(u32).init(0);
        for (0..n) |i| {
            lat[i] = 0;
            handshake[i] = 0;
            threads[i] = try std.Thread.spawn(.{}, benchBurstWorker, .{
                harness.port(),
                &harness.tls_material,
                &lat[i],
                &handshake[i],
                &failures,
                &wrong_responses,
            });
        }
        for (0..n) |i|
            threads[i].join();
        std.sort.pdq(u64, lat[0..n], {}, std.sort.asc(u64));
        // Client-side wall clock: TLS handshake, cold start, handler and
        // response. Only the delta against a warm round is cold start; the
        // launch traces printed at the end report the cold start itself.
        std.debug.print(
            "bench burst round={d} n={d}: wall p50={d}us p90={d}us max={d}us failures={d} wrong={d}\n",
            .{
                round,                            n,
                lat[n / 2] / std.time.ns_per_us,  lat[(n * 9) / 10] / std.time.ns_per_us,
                lat[n - 1] / std.time.ns_per_us,  failures.load(.monotonic),
                wrong_responses.load(.monotonic),
            },
        );
        if (round == 0) {
            cold_wall_ns = lat[0];
            cold_handshake_ns = handshake[0];
        } else if (round == 1) {
            warm_baseline_ns = lat[0];
            std.debug.print(
                "bench cold handshake={d}us warm handshake={d}us\n",
                .{ cold_handshake_ns / std.time.ns_per_us, handshake[0] / std.time.ns_per_us },
            );
            std.debug.print(
                "bench COLD START = {d}us (cold {d}us - warm {d}us, same single request)\n",
                .{
                    (cold_wall_ns -| warm_baseline_ns) / std.time.ns_per_us,
                    cold_wall_ns / std.time.ns_per_us,
                    warm_baseline_ns / std.time.ns_per_us,
                },
            );
        } else {
            std.debug.print(
                "bench burst round={d}: delta p50={d}us over the warm baseline {d}us\n",
                .{ round, (lat[n / 2] -| warm_baseline_ns) / std.time.ns_per_us, warm_baseline_ns / std.time.ns_per_us },
            );
        }

        try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
        // The GET helper checks stream integrity but not :status, and a shed
        // 503 completes cleanly; the route's own body is the witness of a
        // 200, so a round whose percentiles include a fast failure fails.
        try std.testing.expectEqual(@as(u32, 0), wrong_responses.load(.monotonic));
    }
    reportLaunches(&harness);
}

/// The route the burst measures, chosen by COLLO_BENCH_ROUTE. The default is
/// a one-line handler; `todos` is an Elysia API and `hono` a Hono app, each
/// bundled into one module, so their cold start includes the evaluation of
/// a real module graph.
fn benchRoutePath() [*:0]const u8 {
    const raw = std.posix.getenv("COLLO_BENCH_ROUTE") orelse return "/hello/bench";
    if (std.mem.eql(u8, raw, "todos")) return "/api/todos";
    if (std.mem.eql(u8, raw, "hono")) return "/api/hono";
    return "/hello/bench";
}

fn benchBurstWorker(
    port: u16,
    material: *const TlsMaterial,
    out_ns: *u64,
    out_handshake_ns: *u64,
    failures: *std.atomic.Value(u32),
    wrong_responses: *std.atomic.Value(u32),
) void {
    var body: [512]u8 = undefined;
    var body_len: u64 = 0;
    var timings: H2GetTimings = .{ .handshake_ns = 0, .total_ns = 0 };
    var timer = std.time.Timer.start() catch {
        _ = failures.fetchAdd(1, .monotonic);
        return;
    };
    if (collo_test_h2_server_get_timed(
        port,
        material,
        benchRoutePath(),
        &body,
        body.len,
        &body_len,
        null,
        0,
        null,
        &timings,
    ) != 0) {
        _ = failures.fetchAdd(1, .monotonic);
        return;
    }
    out_ns.* = timer.read();
    out_handshake_ns.* = timings.handshake_ns;
    const got = body[0..@min(@as(usize, @intCast(body_len)), body.len)];
    // A shed 503 completes cleanly, so each route's body is the witness of
    // a 200.
    const witness: []const u8 = if (std.posix.getenv("COLLO_BENCH_ROUTE")) |raw|
        (if (std.mem.eql(u8, raw, "todos"))
            "[]"
        else if (std.mem.eql(u8, raw, "hono"))
            "\"ok\""
        else
            "hello bench")
    else
        "hello bench";
    if (std.mem.indexOf(u8, got, witness) == null)
        _ = wrong_responses.fetchAdd(1, .monotonic);
}

/// Prints the launches the launcher finished since the last call
/// (`Server.takeLaunchTraces`) and where each one's time went: the claim to
/// the fork request (the egress attach and the cgroup leaf), the zygote's
/// fork, the fork reply to `WorkerInit` (the launch's own preparation), the
/// child's boot up to `WorkerReady`, and the publish. The client's wall
/// clock also carries the handshake, the wait for the launch, the handler
/// and the response; these traces do not. A launch is traced when it
/// publishes, before its waiters are dispatched, so a client that has its
/// response finds its launch here.
fn reportLaunches(harness: *Harness) void {
    var traces: [64]LaunchTrace = undefined;
    const launches = harness.takeLaunches(&traces);
    std.debug.print("launch traces drained: {d}\n", .{launches.len});
    for (launches) |trace| {
        if (trace.failure) |failure| {
            std.debug.print("  launch definition={d} failed={s}\n", .{ trace.definition, @tagName(failure) });
            continue;
        }
        std.debug.print(
            "  launch definition={d} total={d}us | leaf={d}us fork={d}us prep={d}us boot={d}us publish={d}us\n",
            .{
                trace.definition,
                spanUs(trace.claimed_ns, trace.published_ns),
                spanUs(trace.claimed_ns, trace.fork_sent_ns),
                spanUs(trace.fork_sent_ns, trace.fork_reply_ns),
                spanUs(trace.fork_reply_ns, trace.init_sent_ns),
                spanUs(trace.init_sent_ns, trace.ready_received_ns),
                spanUs(trace.ready_received_ns, trace.published_ns),
            },
        );
    }
}

fn spanUs(from_ns: u64, to_ns: u64) u64 {
    if (from_ns == 0 or to_ns == 0 or to_ns < from_ns)
        return 0;
    return (to_ns - from_ns) / std.time.ns_per_us;
}

/// One GET of `path` on a fresh connection, for a thread of a burst; a
/// failed request counts in `failures`.
fn concurrentGet(
    port: u16,
    material: *const TlsMaterial,
    path: [*:0]const u8,
    failures: *std.atomic.Value(u32),
) void {
    var body: [4096]u8 = undefined;
    var body_len: u64 = 0;
    if (collo_test_h2_server_get_timed(
        port,
        material,
        path,
        &body,
        body.len,
        &body_len,
        null,
        0,
        null,
        null,
    ) != 0)
        _ = failures.fetchAdd(1, .monotonic);
}

// Cold start, attributed, in the shapes production sees. A reverse proxy in
// front of the server pools its connections, so a common request arrives on
// a socket whose handshake was paid long ago and the whole boot lands in the
// user's latency; a cold connection adds the handshake on top of the same
// boot; and a warm request is the floor both are measured against.
//
// Every scenario runs on a fresh harness, because a cold start is a first
// touch: a second sample against a live server measures a warm pool, a
// different question. Repetitions are therefore expensive, and they are
// counted rather than assumed, since one sample of a millisecond-scale event
// on a shared machine is not a measurement.
//
// COLLO_BENCH_TLS=1 enables it, COLLO_BENCH_REPS sets the repetitions
// (default 5). Both scenarios measure the same route, or the comparison would
// price two module graphs instead of the handshake; the warm route only pays
// the handshake and occupies a pool of its own.
const tls_bench_warm_route: [*:0]const u8 = "/hello/bench";
const tls_bench_measured_route: [*:0]const u8 = "/api/hono";
const tls_bench_max_reps: usize = 32;

fn benchReps() usize {
    const raw = std.posix.getenv("COLLO_BENCH_REPS") orelse return 5;
    const n = std.fmt.parseInt(usize, raw, 10) catch return 5;
    return @max(1, @min(n, tls_bench_max_reps));
}

/// Sorts `samples` in place. With few samples p90 lands on the maximum, by
/// the same index convention the burst bench uses.
fn reportSamples(label: []const u8, samples: []u64) void {
    if (samples.len == 0) return;
    std.sort.pdq(u64, samples, {}, std.sort.asc(u64));
    const us = std.time.ns_per_us;
    std.debug.print("bench tls {s}: n={d} p50={d}us p90={d}us max={d}us min={d}us\n", .{
        label,
        samples.len,
        samples[samples.len / 2] / us,
        samples[(samples.len * 9) / 10] / us,
        samples[samples.len - 1] / us,
        samples[0] / us,
    });
}

test "local e2e bench: cold start with TLS cold vs TLS already open (env-gated)" {
    if (std.posix.getenv("COLLO_BENCH_TLS") == null) return error.SkipZigTest;
    const reps = benchReps();
    std.debug.print("bench tls: reps={d}\n", .{reps});

    var cold_wall: [tls_bench_max_reps]u64 = @splat(0);
    var cold_handshake: [tls_bench_max_reps]u64 = @splat(0);
    var cold_server: [tls_bench_max_reps]u64 = @splat(0);
    var warm_wall: [tls_bench_max_reps]u64 = @splat(0);
    var open_wall: [tls_bench_max_reps]u64 = @splat(0);

    for (0..reps) |rep| {
        // A and C: a fresh connection to a cold route, then the same route
        // on the same connection. The first request pays the handshake and
        // the cold start, the second neither: the warm floor.
        {
            var harness: Harness = undefined;
            try harness.init(.{});
            defer harness.deinit();

            var body: [4096]u8 = undefined;
            var body_len: u64 = 0;
            var first: H2GetTimings = .{ .handshake_ns = 0, .total_ns = 0 };
            var second: H2GetTimings = .{ .handshake_ns = 0, .total_ns = 0 };
            if (collo_test_h2_server_get_pair(
                harness.port(),
                &harness.tls_material,
                tls_bench_measured_route,
                tls_bench_measured_route,
                &body,
                body.len,
                &body_len,
                &first,
                &second,
            ) != 0) {
                std.debug.print("h2 pair helper failed: {s}\n", .{std.mem.span(collo_test_tls_last_error())});
                return error.H2ColdTlsFailed;
            }
            cold_wall[rep] = first.total_ns;
            cold_handshake[rep] = first.handshake_ns;
            cold_server[rep] = first.total_ns -| first.handshake_ns;
            warm_wall[rep] = second.total_ns;
            std.debug.print("bench tls rep={d} scenario=A/C (TLS COLD, then warm)\n", .{rep});
            reportLaunches(&harness);
        }

        // B: one connection, a warm route first, then a route whose pool has
        // never been touched. The second request pays no handshake, so it
        // measures the cold start alone.
        {
            var harness: Harness = undefined;
            try harness.init(.{});
            defer harness.deinit();

            var body: [4096]u8 = undefined;
            var body_len: u64 = 0;
            var first: H2GetTimings = .{ .handshake_ns = 0, .total_ns = 0 };
            var second: H2GetTimings = .{ .handshake_ns = 0, .total_ns = 0 };
            if (collo_test_h2_server_get_pair(
                harness.port(),
                &harness.tls_material,
                tls_bench_warm_route,
                tls_bench_measured_route,
                &body,
                body.len,
                &body_len,
                &first,
                &second,
            ) != 0) {
                std.debug.print("h2 pair helper failed: {s}\n", .{std.mem.span(collo_test_tls_last_error())});
                return error.H2WarmTlsFailed;
            }
            open_wall[rep] = second.total_ns;
            std.debug.print("bench tls rep={d} scenario=B (TLS OPEN)\n", .{rep});
            reportLaunches(&harness);
        }
    }

    reportSamples("A COLD, TLS cold  wall  ", cold_wall[0..reps]);
    reportSamples("A COLD, TLS cold  hshake", cold_handshake[0..reps]);
    reportSamples("A COLD, TLS cold  server", cold_server[0..reps]);
    reportSamples("B COLD, TLS open  wall  ", open_wall[0..reps]);
    reportSamples("C WARM, TLS open  wall  ", warm_wall[0..reps]);
}

// What adding one more worker costs the machine, apart from what the tenant's
// code allocates.
//
// RSS counts the copy-on-write pages every child of the zygote shares and
// nobody paid twice for, and PSS divides the shared part by N, which
// overstates the marginal cost exactly in the small-N range that decides how
// many workers fit on a machine. `Private_Dirty` is the closest single field
// to the pages that exist only because this worker exists: copy-on-write
// faults plus fresh allocation. It is not conserved across a fork, though:
// an anonymous dirty page that was private in the parent becomes shared in
// both processes without any allocation, so a summed private-dirty delta can
// understate or even go negative. Compare the deltas between worker counts;
// a single total does not measure the marginal cost.
//
// Two costs no worker's private total shows are sampled as well: shared
// pages the server commits per worker (the state page, egress state), which
// `Shared_Dirty` catches, and kernel memory (page tables, task structs,
// cgroups, namespaces), which no smaps file holds and /proc/meminfo deltas
// partly catch.
//
// The process set comes from walking the tree down from this process, not
// from a list of known pids, so no child, the egress gateway included, is
// missed. COLLO_BENCH_MEM=1 enables it.
const MemSample = struct {
    rss_kib: u64 = 0,
    pss_kib: u64 = 0,
    private_dirty_kib: u64 = 0,
    shared_dirty_kib: u64 = 0,
    procs: u32 = 0,

    fn add(a: MemSample, b: MemSample) MemSample {
        return .{
            .rss_kib = a.rss_kib + b.rss_kib,
            .pss_kib = a.pss_kib + b.pss_kib,
            .private_dirty_kib = a.private_dirty_kib + b.private_dirty_kib,
            .shared_dirty_kib = a.shared_dirty_kib + b.shared_dirty_kib,
            .procs = a.procs + b.procs,
        };
    }
};

fn readKibField(text: []const u8, key: []const u8) u64 {
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var num = std.mem.tokenizeAny(u8, line[key.len..], " \tkB");
        const raw = num.next() orelse return 0;
        return std.fmt.parseInt(u64, raw, 10) catch 0;
    }
    return 0;
}

fn sampleProcess(pid: u32) ?MemSample {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/smaps_rollup", .{pid}) catch return null;
    var buf: [8192]u8 = undefined;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const len = file.readAll(&buf) catch return null;
    const text = buf[0..len];
    return .{
        .rss_kib = readKibField(text, "Rss:"),
        .pss_kib = readKibField(text, "Pss:"),
        .private_dirty_kib = readKibField(text, "Private_Dirty:"),
        .shared_dirty_kib = readKibField(text, "Shared_Dirty:"),
        .procs = 1,
    };
}

/// Every descendant of `root_pid`, transitively, sampled in one pass, so the
/// printed rows and the returned total come from the same snapshot and the
/// total is exactly their sum.
fn sampleProcessTree(allocator: std.mem.Allocator, root_pid: u32, label: []const u8) !MemSample {
    var parents = std.AutoHashMap(u32, u32).init(allocator);
    defer parents.deinit();

    var dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch continue;
        var buf: [4096]u8 = undefined;
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const len = file.readAll(&buf) catch continue;
        const ppid = readKibField(buf[0..len], "PPid:");
        try parents.put(pid, @intCast(ppid));
    }

    var total: MemSample = .{};
    var pit = parents.iterator();
    while (pit.next()) |kv| {
        // Walk up to the root, bounded so a pid reused into a cycle cannot
        // hang the bench.
        var cur = kv.key_ptr.*;
        var hops: u32 = 0;
        const in_tree = while (hops < 64) : (hops += 1) {
            if (cur == root_pid) break true;
            cur = parents.get(cur) orelse break false;
            if (cur <= 1) break false;
        } else false;
        if (in_tree)
            if (sampleProcess(kv.key_ptr.*)) |m| {
                total = total.add(m);
                var name_buf: [512]u8 = undefined;
                std.debug.print(
                    "bench mem   [{s}] pid={d} {s}: private_dirty={d}KiB shared_dirty={d}KiB rss={d}KiB\n",
                    .{
                        label,
                        kv.key_ptr.*,
                        processName(kv.key_ptr.*, &name_buf),
                        m.private_dirty_kib,
                        m.shared_dirty_kib,
                        m.rss_kib,
                    },
                );
            };
    }
    return total;
}

/// The command line's base names, which tell the zygote, the gateway and the
/// workers apart; `/proc/<pid>/status` names every one of them "collo".
fn processName(pid: u32, out: *[512]u8) []const u8 {
    var cmd_path: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&cmd_path, "/proc/{d}/cmdline", .{pid}) catch return "?";
    const file = std.fs.openFileAbsolute(path, .{}) catch return "?";
    defer file.close();
    const len = file.readAll(out) catch return "?";
    if (len == 0) return "?";
    var parts = std.mem.tokenizeScalar(u8, out[0..len], 0);
    var joined: usize = 0;
    while (parts.next()) |part| {
        const base = std.fs.path.basename(part);
        if (joined + base.len + 1 >= out.len) break;
        if (joined != 0) {
            out[joined] = ' ';
            joined += 1;
        }
        std.mem.copyForwards(u8, out[joined..][0..base.len], base);
        joined += base.len;
    }
    return out[0..@min(joined, 60)];
}

fn sampleMeminfo() struct { committed_kib: u64, pagetables_kib: u64 } {
    var buf: [8192]u8 = undefined;
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch
        return .{ .committed_kib = 0, .pagetables_kib = 0 };
    defer file.close();
    const len = file.readAll(&buf) catch return .{ .committed_kib = 0, .pagetables_kib = 0 };
    return .{
        .committed_kib = readKibField(buf[0..len], "Committed_AS:"),
        .pagetables_kib = readKibField(buf[0..len], "PageTables:"),
    };
}

fn reportMem(label: []const u8, m: MemSample, mi: anytype) void {
    std.debug.print(
        "bench mem {s} TOTAL (= sum of the rows above): procs={d} private_dirty={d}KiB shared_dirty={d}KiB pss={d}KiB rss={d}KiB | committed={d}KiB pagetables={d}KiB\n",
        .{ label, m.procs, m.private_dirty_kib, m.shared_dirty_kib, m.pss_kib, m.rss_kib, mi.committed_kib, mi.pagetables_kib },
    );
}

test "local e2e bench: what one more worker costs the system (env-gated)" {
    if (std.posix.getenv("COLLO_BENCH_MEM") == null) return error.SkipZigTest;

    // One request on a real route takes the whole production path: the
    // route's pool, the launch and the gateway session, which the route's
    // grant of the origin gives it. Both phases hit the same route, or the
    // second worker would price a different module graph and the delta
    // would stop being a marginal cost.
    var gzip_origin = try GzipOrigin.start(std.testing.allocator);
    defer gzip_origin.stop(std.testing.allocator);
    var authority_buffer: [network_mod.authority_bytes_max]u8 = undefined;
    const allow = [_][]const u8{try gzip_origin.authority(&authority_buffer)};
    const configuration = try network_mod.configText(std.testing.allocator, &.{.{
        .name = "fetch-gzip",
        .routes = &.{.{ .path = "/fetch-gzip", .entry = "./api/fetch_gzip.js" }},
        .network = try network_mod.originGrant(&allow, gzip_origin.host()),
    }});
    defer std.testing.allocator.free(configuration);
    const hold_path = try gzipRoutePath(std.testing.allocator, "/fetch-gzip", gzip_origin);
    defer std.testing.allocator.free(hold_path);

    var harness: Harness = undefined;
    try harness.init(.{ .config_source = configuration });
    defer harness.deinit();

    const self_pid: u32 = @intCast(std.os.linux.getpid());
    const base = try sampleProcessTree(std.testing.allocator, self_pid, "0-workers");
    const base_mi = sampleMeminfo();
    reportMem("0-workers", base, base_mi);

    var body: [4096]u8 = undefined;
    var body_len: u64 = 0;
    if (collo_test_h2_server_get_timed(
        harness.port(),
        &harness.tls_material,
        hold_path.ptr,
        &body,
        body.len,
        &body_len,
        null,
        0,
        null,
        null,
    ) != 0) return error.H2MemBenchFailed;

    const one = try sampleProcessTree(std.testing.allocator, self_pid, "1-worker");
    const one_mi = sampleMeminfo();
    reportMem("1-worker ", one, one_mi);

    // A second worker needs more requests at once than one worker runs: its
    // definition's `concurrency`, two by default. Each client pays its own
    // TLS handshake first, which staggers the threads, so eight requests are
    // sent at once, on a route that holds its worker for two gateway
    // fetches, long enough for the others to arrive and make the pool grow.
    var failures = std.atomic.Value(u32).init(0);
    var threads: [8]std.Thread = undefined;
    for (0..8) |i|
        threads[i] = try std.Thread.spawn(.{}, concurrentGet, .{
            harness.port(),
            &harness.tls_material,
            hold_path.ptr,
            &failures,
        });
    for (0..8) |i| threads[i].join();

    const two = try sampleProcessTree(std.testing.allocator, self_pid, "N-workers");
    const two_mi = sampleMeminfo();
    reportMem("N-workers", two, two_mi);

    std.debug.print(
        "bench mem DELTA 0->1: private_dirty={d}KiB shared_dirty={d}KiB committed={d}KiB pagetables={d}KiB procs=+{d}\n",
        .{
            one.private_dirty_kib -| base.private_dirty_kib,
            one.shared_dirty_kib -| base.shared_dirty_kib,
            one_mi.committed_kib -| base_mi.committed_kib,
            one_mi.pagetables_kib -| base_mi.pagetables_kib,
            one.procs -| base.procs,
        },
    );
    std.debug.print(
        "bench mem DELTA 1->N: private_dirty={d}KiB shared_dirty={d}KiB committed={d}KiB pagetables={d}KiB procs=+{d}\n",
        .{
            two.private_dirty_kib -| one.private_dirty_kib,
            two.shared_dirty_kib -| one.shared_dirty_kib,
            two_mi.committed_kib -| one_mi.committed_kib,
            two_mi.pagetables_kib -| one_mi.pagetables_kib,
            two.procs -| one.procs,
        },
    );
    // The second delta is the marginal cost. The first also carries what a
    // route's first worker does once, such as the first gateway session.
}

// How many private bytes a worker pays per byte of module pack.
//
// The bench writes a configuration of its own with one route whose entry is
// the fixture's gzip handler preceded by side-effect imports of filler
// modules, each a single 2 MiB comment. The engine lexes a filler and
// evaluates nothing, so every variant runs the same code while the pack the
// worker maps grows with the filler. A coefficient near 1.0 means every
// worker keeps a private copy of its pack; near 0 means the pages stay
// shared. COLLO_BENCH_PACK=<MiB of filler> selects the variant: an even
// number from 0 to `pack_filler_mib_max`.
test "local e2e bench: private bytes per byte of module pack (env-gated)" {
    const variant = std.posix.getenv("COLLO_BENCH_PACK") orelse return error.SkipZigTest;
    const filler_mib = std.fmt.parseInt(usize, variant, 10) catch return error.InvalidPackVariant;
    if (filler_mib % 2 != 0 or filler_mib > pack_filler_mib_max)
        return error.InvalidPackVariant;

    var gzip_origin = try GzipOrigin.start(std.testing.allocator);
    defer gzip_origin.stop(std.testing.allocator);
    var pack_variant = try PackVariant.write(std.testing.allocator, filler_mib / 2, gzip_origin);
    defer pack_variant.deinit(std.testing.allocator);

    var harness: Harness = undefined;
    try harness.init(.{ .config_path = pack_variant.config_path });
    defer harness.deinit();

    const path = try gzipRoutePath(std.testing.allocator, PackVariant.route_path, gzip_origin);
    defer std.testing.allocator.free(path);

    var body: [4096]u8 = undefined;
    var body_len: u64 = 0;
    if (collo_test_h2_server_get_timed(
        harness.port(),
        &harness.tls_material,
        path.ptr,
        &body,
        body.len,
        &body_len,
        null,
        0,
        null,
        null,
    ) != 0) return error.H2PackBenchFailed;

    const self_pid: u32 = @intCast(std.os.linux.getpid());
    _ = try sampleProcessTree(std.testing.allocator, self_pid, variant);
}

/// Bytes of one filler module, chosen so a pack with N fillers is about N
/// times 2 MiB plus the entry.
const pack_filler_module_bytes: usize = 2 * 1024 * 1024 - 8;
/// The most filler, in MiB, that keeps the pack under `max_pack_bytes`
/// (`common/ipc/module_pack.zig`) with room for the entry.
const pack_filler_mib_max: usize = 14;

/// A temporary directory holding the pack benchmark's configuration, whose
/// one route is granted the origin, its entry and its filler modules.
const PackVariant = struct {
    directory: []u8,
    config_path: []u8,

    /// The one route the configuration `write` produces declares.
    const route_path = "/fetch-gzip-big";

    fn write(allocator: std.mem.Allocator, filler_count: usize, origin: *const GzipOrigin) !PackVariant {
        const directory = try zygote_support.makeTempPath(allocator, "collo-local-e2e-pack");
        errdefer allocator.free(directory);
        try std.fs.makeDirAbsolute(directory);
        errdefer std.fs.deleteTreeAbsolute(directory) catch {};
        var dir = try std.fs.openDirAbsolute(directory, .{});
        defer dir.close();

        var authority_buffer: [network_mod.authority_bytes_max]u8 = undefined;
        const allow = [_][]const u8{try origin.authority(&authority_buffer)};
        const configuration = try network_mod.configText(allocator, &.{.{
            .name = "fetch-gzip-big",
            .routes = &.{.{ .path = route_path, .entry = "./entry.js" }},
            .network = try network_mod.originGrant(&allow, origin.host()),
        }});
        defer allocator.free(configuration);
        try dir.writeFile(.{ .sub_path = "collo.json", .data = configuration });

        const filler = try allocator.alloc(u8, pack_filler_module_bytes);
        defer allocator.free(filler);
        @memset(filler, 'x');
        @memcpy(filler[0..2], "/*");
        @memcpy(filler[filler.len - 3 ..], "*/\n");
        var entry: std.Io.Writer.Allocating = .init(allocator);
        defer entry.deinit();
        for (0..filler_count) |index| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "filler_{d}.js", .{index});
            try dir.writeFile(.{ .sub_path = name, .data = filler });
            try entry.writer.print("import \"./{s}\";\n", .{name});
        }
        var api = try std.fs.cwd().openDir(harness_mod.fixture_api_directory, .{});
        defer api.close();
        const handler = try api.readFileAlloc(allocator, "fetch_gzip.js", 64 * 1024);
        defer allocator.free(handler);
        try entry.writer.writeAll(handler);
        try dir.writeFile(.{ .sub_path = "entry.js", .data = entry.written() });

        const config_path = try std.fs.path.join(allocator, &.{ directory, "collo.json" });
        return .{ .directory = directory, .config_path = config_path };
    }

    fn deinit(self: *PackVariant, allocator: std.mem.Allocator) void {
        std.fs.deleteTreeAbsolute(self.directory) catch {};
        allocator.free(self.config_path);
        allocator.free(self.directory);
        self.* = undefined;
    }
};
