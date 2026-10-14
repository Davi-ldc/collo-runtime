//! Engine tests of HTTP/2 streams and their credits
//! (`egress/client/engine/h2.zig`, lane `egress-test`): a stream opens on a
//! connection the owner dialed, the pool-wait deadline is fixed at the first
//! park, a credit kept across a restart reaches no stream of the next run,
//! and a credit worth more than its stream holds is dropped. The codec and
//! the pool are tested on their own in `../http2/` and `../pool/`.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const local_address = @import("collo_test_net");
const tls_shim = @import("collo_test_tls_shim");
const http1_support = @import("../http1/support.zig");
const network_policy = @import("../network_policy.zig");
const support = @import("support.zig");

const egress_engine = egress_client.engine;
const body_credit = egress_client.body_credit;
const core = egress_client.core;
const task_model = egress_client.task;

/// A local h2 origin of the test shim: it serves one connection, answers
/// stream 1 with "one" in one DATA frame that ends the stream, and keeps the
/// connection open until a second stream or its stop.
const H2Origin = struct {
    server: *tls_shim.TestH2Origin,
    port: u16,

    fn start() !H2Origin {
        var server: ?*tls_shim.TestH2Origin = null;
        var port: u16 = 0;
        if (tls_shim.collo_test_h2_origin_start(tls_shim.test_h2_origin_alpn_h2, &server, &port) != 0)
            return error.StartLocalH2OriginFailed;
        return .{ .server = server.?, .port = port };
    }

    fn stop(self: H2Origin) void {
        tls_shim.collo_test_h2_origin_stop(self.server);
    }
};

/// Pulls `queue` the way the gateway loop does until a chunk carries a
/// credit, and returns that credit without giving it back to the engine.
fn pullCredit(queue: *core.ResponseQueue, timeout_ms: u64) !body_credit.Handle {
    const start = try std.time.Instant.now();
    while (true) {
        _ = queue.armPull();
        const pulled = queue.pull(std.testing.allocator);
        if (pulled.bytes) |bytes|
            std.testing.allocator.free(bytes);
        if (!pulled.credit.isNone())
            return pulled.credit;
        if (pulled.failed or pulled.done)
            return error.BodyEndedWithoutCredit;
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.NoCreditArrived;
    }
}

test "egress engine pool-wait deadline is fixed at the first park" {
    var task = try support.initEngineFetchTask(std.testing.allocator, 90, "https://example.test/", 90);
    defer task.deinit();
    const config: egress_client.Config = .{ .network = network_policy.public_https };
    task.engine.config = config;
    const plan = try egress_client.transport.prepareRequest(std.testing.allocator, task.url, task.method, task.headers, config);
    // The hop takes a task reference of its own, as the engine's does.
    task.retain();
    var hop = egress_engine.Hop.init(&task, plan);
    defer hop.deinit();
    try std.testing.expectEqual(@as(u64, 1_000), hop.poolParkDeadline(1_000));
    // A re-park under sustained pool saturation must not renew the deadline,
    // or a fetch without a request deadline would never expire.
    try std.testing.expectEqual(@as(u64, 1_000), hop.poolParkDeadline(5_000));
}

test "egress engine opens an HTTP/2 stream on a connection its owner dialed" {
    var origin: ?*tls_shim.TestH2Origin = null;
    var port: u16 = 0;
    if (tls_shim.collo_test_h2_origin_start(tls_shim.test_h2_origin_alpn_h2, &origin, &port) != 0)
        return error.StartLocalH2OriginFailed;
    defer tls_shim.collo_test_h2_origin_stop(origin.?);

    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const url = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/one", .{ host, port });
    defer std.testing.allocator.free(url);
    var task = try support.initEngineFetchTask(std.testing.allocator, 20, url, 20);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &task);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{port});
    const config = egress_client.Config{
        .network = origins.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 5_000);
    try support.expectTaskStatus(&task, 200);
    var body_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("one", try support.readBody(&engine, task.response_body, &body_buffer, 5_000));
    try std.testing.expectEqual(tls_shim.test_alpn_h2, tls_shim.collo_test_h2_origin_selected_alpn(origin.?));
}

/// Runs one HTTP/1 fetch to completion on `engine`. Every credit released
/// before the call was taken by the owner by the time it returns, since the
/// owner takes credits with the submission that starts this fetch, or
/// before it.
fn settleOneFetch(engine: *egress_engine.Engine, task: *task_model.Task, network: egress_client.network.Policy) !void {
    try engine.submit(.{ .task = task, .config = .{
        .network = network,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 5_000,
    } });
    try support.waitTaskDone(task, 5_000);
    try support.expectTaskStatus(task, 200);
}

// A worker can hold a body extent, and with it the extent's credit, across a
// shard restart. Each run's first stream is stream 1 of a fresh connection,
// so only a source id that runs on across runs keeps that credit from
// acknowledging bytes of the new run's stream, which would open its window
// over bytes its consumer never took and surface its end early.
test "egress engine credits kept across a restart reach no stream of the next run" {
    const first_origin = try H2Origin.start();
    defer first_origin.stop();
    const second_origin = try H2Origin.start();
    defer second_origin.stop();
    var sync_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer sync_origin.stop(std.testing.allocator);

    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const first_url = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/one", .{ host, first_origin.port });
    defer std.testing.allocator.free(first_url);
    const second_url = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/one", .{ host, second_origin.port });
    defer std.testing.allocator.free(second_url);
    const sync_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ host, sync_origin.port });
    defer std.testing.allocator.free(sync_url);
    var first = try support.initEngineFetchTask(std.testing.allocator, 110, first_url, 110);
    defer first.deinit();
    var second = try support.initEngineFetchTask(std.testing.allocator, 111, second_url, 111);
    defer second.deinit();
    var sync = try support.initEngineFetchTask(std.testing.allocator, 112, sync_url, 112);
    defer sync.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 4);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &sync);
    defer _ = support.releaseTaskBodyCredits(&engine, &second);
    defer _ = support.releaseTaskBodyCredits(&engine, &first);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{ first_origin.port, second_origin.port, sync_origin.port });
    const config = egress_client.Config{
        .network = origins.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &first, .config = config });
    try support.waitTaskDone(&first, 5_000);
    try support.expectTaskStatus(&first, 200);
    const kept = (try pullCredit(first.response_body, 5_000)).h2_data;

    engine.stop();
    try support.startEngine(&engine, &wake);
    try engine.submit(.{ .task = &second, .config = config });
    try support.waitTaskDone(&second, 5_000);
    try support.expectTaskStatus(&second, 200);
    const live = (try pullCredit(second.response_body, 5_000)).h2_data;
    try std.testing.expectEqual(kept.stream_id, live.stream_id);
    try std.testing.expect(kept.source_id != live.source_id);

    engine.releaseFetchBodyCredit(.{ .h2_data = kept });
    try settleOneFetch(&engine, &sync, origins.policy());
    // The second stream's end still waits for its own credit.
    try std.testing.expect(support.queueState(second.response_body) == .open);
    engine.releaseFetchBodyCredit(.{ .h2_data = live });
    try support.waitBodyComplete(second.response_body, 5_000);
}

// Every credit of a stream was issued for bytes it delivered, so a credit
// worth more than the stream holds unacknowledged names bytes nobody
// consumed. The engine drops it whole, the stream lives on, and its own
// credit still ends it.
test "egress engine drops a credit worth more than its stream holds" {
    const origin = try H2Origin.start();
    defer origin.stop();
    var sync_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer sync_origin.stop(std.testing.allocator);

    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const url = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/one", .{ host, origin.port });
    defer std.testing.allocator.free(url);
    const sync_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ host, sync_origin.port });
    defer std.testing.allocator.free(sync_url);
    var task = try support.initEngineFetchTask(std.testing.allocator, 120, url, 120);
    defer task.deinit();
    var sync = try support.initEngineFetchTask(std.testing.allocator, 121, sync_url, 121);
    defer sync.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 4);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &sync);
    defer _ = support.releaseTaskBodyCredits(&engine, &task);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{ origin.port, sync_origin.port });

    try engine.submit(.{ .task = &task, .config = .{
        .network = origins.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
    } });
    try support.waitTaskDone(&task, 5_000);
    try support.expectTaskStatus(&task, 200);
    const issued = (try pullCredit(task.response_body, 5_000)).h2_data;

    engine.releaseFetchBodyCredit(body_credit.h2Data(
        issued.source_id,
        issued.stream_id,
        issued.encoded_bytes + 1,
        issued.update_stream_window,
    ));
    try settleOneFetch(&engine, &sync, origins.policy());
    try std.testing.expect(support.queueState(task.response_body) == .open);
    engine.releaseFetchBodyCredit(.{ .h2_data = issued });
    try support.waitBodyComplete(task.response_body, 5_000);
}
