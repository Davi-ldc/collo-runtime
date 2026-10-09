//! Root of the egress client suite, which `egress-test` runs, and home of its
//! engine-level tests. The task, policy, data-driver and TLS tests sit beside
//! this file; the HTTP/1, HTTP/2 and pool suites sit in their directories.
//!
//! Most tests here run a real `Engine`, with its owner and connector
//! threads, against loopback origins: `LocalHttp1Origin` from
//! http1/support.zig, a `HeldOrigin` that accepts and never answers, and a
//! silent origin that holds TLS handshakes open. They check fairness between
//! fetches on the owner loop, billing meters on failure and cancel paths,
//! connector-queue pressure, settlement on stop and on owner faults, and
//! that no fd watch outlives its fetch. Results are read from the task, its
//! body meters, `H2Stats` snapshots and the owner data driver's live
//! armed-watch count.

const std = @import("std");
const bindings = @import("collo_bindings");
const egress_client = @import("collo_egress_client");
const egress_engine = egress_client.engine;
const fetch_body = egress_client.fetch_body;
const task_model = egress_client.task;
const http1_support = @import("http1/support.zig");
const local_address = @import("collo_test_net");

comptime {
    _ = @import("task.zig");
    _ = @import("policy.zig");
    _ = @import("data_io.zig");
    _ = @import("tls.zig");
    _ = @import("http1/all.zig");
    _ = @import("http2/all.zig");
    _ = @import("pool/all.zig");
}

test "egress engine initializes before worker threads start" {
    var engine = try egress_engine.Engine.init(std.testing.allocator, 4, .{ .connector_count = 1 });
    engine.deinit();
}

// HTTP/1 bodies parked on consumer backpressure must not stall later fetches
// on the same owner loop: each head completes while the earlier bodies wait
// for credit.
test "egress engine HTTP1 slow bodies do not starve other fetches" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const stall_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stall", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(stall_url);
    const fast_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(fast_url);

    var first = try initEngineFetchTask(std.testing.allocator, 1, stall_url, 1);
    defer first.deinit();
    var second = try initEngineFetchTask(std.testing.allocator, 2, stall_url, 2);
    defer second.deinit();
    var third = try initEngineFetchTask(std.testing.allocator, 3, fast_url, 3);
    defer third.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &third);
    defer releaseTaskBodyCredits(&engine, &second);
    defer releaseTaskBodyCredits(&engine, &first);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .max_pending_decoded_body_bytes = 1,
        .socket_timeout_ms = 1_000,
    };

    try engine.submit(.{ .task = &first, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&first, 1_000);
    try expectTaskStatus(&first, 200);

    try engine.submit(.{ .task = &second, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&second, 1_000);
    try expectTaskStatus(&second, 200);

    try engine.submit(.{ .task = &third, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&third, 1_000);
    try expectTaskStatus(&third, 200);

    first.markCanceled();
    second.markCanceled();
    third.markCanceled();
    engine.wakeCancellation();
}

// With ample consumer credit nothing pauses a large fast body, so only the
// per-drive quantum breaks the transfer up. A second fetch must complete
// while the first streams, and the yielded pending must be driven to EOF by
// the owner's self-wake: a runnable pending has no watch source and no
// deadline, so a lost yield would strand it forever.
test "egress engine HTTP1 large fast body yields the owner loop to other fetches" {
    var big_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer big_origin.stop(std.testing.allocator);
    var small_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer small_origin.stop(std.testing.allocator);

    const big_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/big", .{ big_origin.host(), big_origin.port });
    defer std.testing.allocator.free(big_url);
    const small_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stall", .{ small_origin.host(), small_origin.port });
    defer std.testing.allocator.free(small_url);

    const big_len: u64 = http1_support.big_body_bytes;
    var big = try initEngineFetchTaskShaped(std.testing.allocator, 70, big_url, 70, "GET", "", big_len * 2);
    defer big.deinit();
    var small = try initEngineFetchTaskShaped(std.testing.allocator, 71, small_url, 71, "GET", "", 1024);
    defer small.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &small);
    defer releaseTaskBodyCredits(&engine, &big);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = @intCast(big_len * 2),
        .max_encoded_response_bytes = @intCast(big_len * 2),
        .max_pending_decoded_body_bytes = @intCast(big_len * 2),
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &big, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&big, 5_000);
    try expectTaskStatus(&big, 200);

    // Submitted while the big body streams, so the owner must interleave the
    // small fetch between the big body's drive quanta.
    try engine.submit(.{ .task = &small, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&small, 5_000);
    try expectTaskStatus(&small, 200);
    const start = try std.time.Instant.now();
    while (bodyState(big.response_body) != .complete) {
        try std.testing.expect(!big.response_body.isFailed());
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 10_000 * std.time.ns_per_ms)
            return error.LargeBodyDidNotComplete;
    }
    try std.testing.expectEqual(big_len, @as(u64, big.response_body.queuedDecodedBytes()));

    big.markCanceled();
    small.markCanceled();
    engine.wakeCancellation();
}

// Request bytes are billed when the write is prepared, so a failure before
// the response head must still fold them into the body meters: a POST whose
// head never arrives bills its upload on the failure.
test "egress engine HTTP1 pre-head failure bills the uploaded request" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/black-hole", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    const upload = "u" ** 512;
    var task = try initEngineFetchTaskShaped(std.testing.allocator, 80, url, 80, "POST", upload, 1024);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 150,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&task, 5_000);

    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    switch (result) {
        .success => return error.UnexpectedFetchSuccess,
        .failure => {},
    }
    // The request head and the 512-byte body crossed the wire before the
    // origin went silent, so the stall failure carries them as billed.
    const meters = task.response_body.egressMetersTotal();
    try std.testing.expect(meters.billed_sent > upload.len);
}

// A POST to an origin that accepts but never reads stalls mid-upload. When
// the stall deadline fails the fetch, settleFailureMeters must bill only the
// prefix that was written, not the whole upload counted when the write was
// prepared; billing the unsent remainder would also push billed above cost.
test "egress engine HTTP1 stalled upload failure bills only the written prefix" {
    var origin = try HeldOrigin.start(std.testing.allocator, 1);
    defer origin.stop(std.testing.allocator);
    const url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(url);

    // Far more than the loopback socket buffers (the tcp_wmem and tcp_rmem
    // caps) can absorb, so the write stalls mid-upload.
    const upload_len: usize = 24 * 1024 * 1024;
    const upload = try std.testing.allocator.alloc(u8, upload_len);
    defer std.testing.allocator.free(upload);
    @memset(upload, 'u');

    var task = try initEngineFetchTaskShaped(std.testing.allocator, 5_000, url, 5_000, "POST", upload, 1024);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 300,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&task, 15_000);
    try expectTaskFailureMessage(&task, "FetchWriteTimeout");

    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    switch (result) {
        .success => return error.UnexpectedFetchSuccess,
        .failure => {},
    }
    const meters = task.response_body.egressMetersTotal();
    // A prefix reached the kernel before the stall, and the unwritten
    // remainder is not billed.
    try std.testing.expect(meters.billed_sent > 0);
    try std.testing.expect(meters.billed_sent < upload_len);
}

// Canceling a fetch mid-upload also settles the body meters with the
// written prefix rather than the whole upload.
test "egress engine HTTP1 cancel mid-upload bills only the written prefix" {
    var origin = try HeldOrigin.start(std.testing.allocator, 1);
    defer origin.stop(std.testing.allocator);
    const url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(url);

    const upload_len: usize = 24 * 1024 * 1024;
    const upload = try std.testing.allocator.alloc(u8, upload_len);
    defer std.testing.allocator.free(upload);
    @memset(upload, 'u');

    var task = try initEngineFetchTaskShaped(std.testing.allocator, 5_050, url, 5_050, "POST", upload, 1024);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    // One live watch means the upload filled the socket buffers and parked
    // on write readiness, so the cancel lands mid-write.
    try waitLiveArmedWatchCount(&engine, 1, 5_000);
    task.markCanceled();
    engine.wakeCancellation();
    try waitTaskDone(&task, 5_000);

    // The written prefix was folded into the body meters before the task
    // completed as canceled.
    const meters = task.response_body.egressMetersTotal();
    try std.testing.expect(meters.billed_sent > 0);
    try std.testing.expect(meters.billed_sent < upload_len);
    try std.testing.expectEqual(@as(u64, 0), meters.billed_received);
}

// Billed bytes exclude interim 1xx heads (the `EgressMeters` contract in
// core/fetch_body.zig), just as the h2 codec never bills interim HEADERS.
// The origin sends two "100 Continue" heads before the final 200; they cross
// the wire but must not appear in billed_received.
test "egress engine HTTP1 interim 1xx heads are not billed" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/interim-ok", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var task = try initEngineFetchTask(std.testing.allocator, 5_100, url, 5_100);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 2_000,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&task, 5_000);
    try expectTaskStatus(&task, 200);
    try waitBodyComplete(task.response_body, 2_000);

    const interim_len: u64 = 2 * "HTTP/1.1 100 Continue\r\n\r\n".len;
    const meters = task.response_body.egressMetersTotal();
    try std.testing.expectEqual(origin.request_wire.load(.acquire), meters.billed_sent);
    try std.testing.expectEqual(
        origin.response_wire.load(.acquire) - interim_len,
        meters.billed_received,
    );
}

// The interim head that trips the cap must be excluded from billed too, so
// its refund has to run before the cap check; otherwise settleFailureMeters
// folds that head into billed_received with the TooManyInterimResponses
// failure. The origin sends only interim heads and no final response, so
// every received byte belongs to a 1xx head and billed_received must be
// exactly zero.
test "egress engine HTTP1 interim flood failure bills no interim head" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/interim-only", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(url);

    var task = try initEngineFetchTask(std.testing.allocator, 5_150, url, 5_150);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 2_000,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&task, 5_000);
    try expectTaskFailureMessage(&task, "TooManyInterimResponses");

    const meters = task.response_body.egressMetersTotal();
    // The request head stays billed on the failure.
    try std.testing.expectEqual(origin.request_wire.load(.acquire), meters.billed_sent);
    // No interim head is billed, including the ninth, which trips the cap.
    try std.testing.expectEqual(@as(u64, 0), meters.billed_received);
}

// A full connector queue is transient, so an h1 dial that meets one must not
// fail the fetch. The pending parks on a short retry tick, a deadline-only
// watch source rather than a self-wake spin, and retries the dispatch at
// each tick until a slot frees, bounded by the total request deadline.
test "egress engine h1 dial survives a full connector queue" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const bind_address = try std.net.Address.parseIp4(host, 0);

    // One silent origin occupies the single connector inside a TLS
    // handshake; two more park one connect command each in the capacity-2
    // connect queue, so the h1 dial below meets a full queue.
    var state_a = SilentOriginState{};
    var server_a = try bind_address.listen(.{ .reuse_address = true });
    const thread_a = try std.Thread.spawn(.{}, silentOriginMain, .{ &server_a, &state_a });
    defer stopSilentOrigin(&server_a, &state_a, thread_a);
    var state_b = SilentOriginState{};
    var server_b = try bind_address.listen(.{ .reuse_address = true });
    const thread_b = try std.Thread.spawn(.{}, silentOriginMain, .{ &server_b, &state_b });
    defer stopSilentOrigin(&server_b, &state_b, thread_b);
    var state_c = SilentOriginState{};
    var server_c = try bind_address.listen(.{ .reuse_address = true });
    const thread_c = try std.Thread.spawn(.{}, silentOriginMain, .{ &server_c, &state_c });
    defer stopSilentOrigin(&server_c, &state_c, thread_c);

    var fast_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer fast_origin.stop(std.testing.allocator);

    const url_a = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server_a.listen_address.getPort() });
    defer std.testing.allocator.free(url_a);
    const url_b = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server_b.listen_address.getPort() });
    defer std.testing.allocator.free(url_b);
    const url_c = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server_c.listen_address.getPort() });
    defer std.testing.allocator.free(url_c);
    const h1_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ fast_origin.host(), fast_origin.port });
    defer std.testing.allocator.free(h1_url);

    var task_a = try initEngineFetchTask(std.testing.allocator, 5_200, url_a, 5_200);
    defer task_a.deinit();
    var task_b = try initEngineFetchTask(std.testing.allocator, 5_201, url_b, 5_201);
    defer task_b.deinit();
    var task_c = try initEngineFetchTask(std.testing.allocator, 5_202, url_c, 5_202);
    defer task_c.deinit();
    var h1_task = try initEngineFetchTask(std.testing.allocator, 5_203, h1_url, 5_203);
    defer h1_task.deinit();

    // Capacity 2: two queued connects fill the queue while the connector
    // works on the one it popped.
    var engine = try egress_engine.Engine.init(std.testing.allocator, 2, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &h1_task);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const h2_config = egress_client.Config{
        .allow_private_networks = true,
        .enable_http2 = true,
        .insecure_tls = true,
        .socket_timeout_ms = 1_000,
    };
    const h1_config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    // The accepted dial proves the connector popped task_a's connect and is
    // busy; the next two connects then fill both queue slots.
    try submitRetryingQueueFull(&engine, .{ .task = &task_a, .config = h2_config }, &wake);
    try waitForAcceptedConnection(&state_a, 2_000);
    try submitRetryingQueueFull(&engine, .{ .task = &task_b, .config = h2_config }, &wake);
    try submitRetryingQueueFull(&engine, .{ .task = &task_c, .config = h2_config }, &wake);

    // The h1 dial meets the full queue and must keep retrying until the
    // connector works through the silent handshakes.
    try submitRetryingQueueFull(&engine, .{ .task = &h1_task, .config = h1_config }, &wake);
    try waitTaskDone(&h1_task, 15_000);
    try expectTaskStatus(&h1_task, 200);
    try waitBodyComplete(h1_task.response_body, 5_000);

    // The silent-handshake fetches settle on their own stage timeouts.
    try waitTaskDone(&task_a, 15_000);
    try waitTaskDone(&task_b, 15_000);
    try waitTaskDone(&task_c, 15_000);
}

/// Submits, retrying while the message queue is full. `Engine.init` sizes
/// the message queue and the connect queue from one capacity, so the small
/// capacity that lets a test fill the connect queue also lets a submit
/// bounce until the owner drains its messages.
fn submitRetryingQueueFull(engine: *egress_engine.Engine, command: egress_engine.Command, wake: *WakeState) !void {
    const start = try std.time.Instant.now();
    while (true) {
        engine.submit(command, wake, wakeEngineTest) catch |err| switch (err) {
            error.EgressEngineQueueFull => {
                const now = try std.time.Instant.now();
                if (now.since(start) >= 5_000 * std.time.ns_per_ms)
                    return err;
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        return;
    }
}

test "egress engine HTTP1 paused body resumes from body credit" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const stall_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stall", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(stall_url);

    var task = try initEngineFetchTask(std.testing.allocator, 10, stall_url, 10);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .max_pending_decoded_body_bytes = 1,
        .socket_timeout_ms = 1_000,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&task, 1_000);
    try expectTaskStatus(&task, 200);

    const start = try std.time.Instant.now();
    while (bodyState(task.response_body) != .complete) {
        var release_context = EngineCreditRelease{
            .engine = &engine,
        };
        task.response_body.releaseQueuedChunksCallback(
            std.testing.allocator,
            &release_context,
            releaseCreditToEngine,
        );
        if (release_context.count == 0)
            std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 1_000 * std.time.ns_per_ms)
            return error.Http1BodyDidNotResume;
    }

    try std.testing.expect(!task.response_body.isFailed());
}

test "egress h2 pool waiter deadline is fixed at first park" {
    var task = try initEngineFetchTask(std.testing.allocator, 90, "https://example.test/", 90);
    defer task.deinit();
    var command = egress_engine.Command{ .task = &task, .config = .{} };
    try std.testing.expectEqual(@as(u64, 1_000), command.h2PoolParkDeadline(1_000));
    // A re-park under sustained pool saturation must not renew the deadline,
    // or a command without a request deadline would never expire.
    try std.testing.expectEqual(@as(u64, 1_000), command.h2PoolParkDeadline(5_000));
}

test "egress engine stop fails h2 fetches coalesced in connect groups" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const bind_address = try std.net.Address.parseIp4(host, 0);

    var state_a = SilentOriginState{};
    var server_a = try bind_address.listen(.{ .reuse_address = true });
    const thread_a = try std.Thread.spawn(.{}, silentOriginMain, .{ &server_a, &state_a });
    defer stopSilentOrigin(&server_a, &state_a, thread_a);
    var state_b = SilentOriginState{};
    var server_b = try bind_address.listen(.{ .reuse_address = true });
    const thread_b = try std.Thread.spawn(.{}, silentOriginMain, .{ &server_b, &state_b });
    defer stopSilentOrigin(&server_b, &state_b, thread_b);

    const url_a = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server_a.listen_address.getPort() });
    defer std.testing.allocator.free(url_a);
    const url_b = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server_b.listen_address.getPort() });
    defer std.testing.allocator.free(url_b);

    var task_a = try initEngineFetchTask(std.testing.allocator, 31, url_a, 31);
    defer task_a.deinit();
    var task_b = try initEngineFetchTask(std.testing.allocator, 32, url_b, 32);
    defer task_b.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    var engine_alive = true;
    errdefer if (engine_alive) engine.deinit();
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_private_networks = true,
        .enable_http2 = true,
        .insecure_tls = true,
        .socket_timeout_ms = 2_000,
    };

    // The single connector dials origin A and blocks inside the TLS
    // handshake against the silent listener; origin B's command stays
    // coalesced in its connect group with the connect queued behind the
    // busy connector.
    try engine.submit(.{ .task = &task_a, .config = config }, &wake, wakeEngineTest);
    try engine.submit(.{ .task = &task_b, .config = config }, &wake, wakeEngineTest);
    try waitForAcceptedConnection(&state_a, 2_000);
    // Nothing signals that the owner has registered both connect groups, so
    // the test gives it a moment.
    std.Thread.sleep(20 * std.time.ns_per_ms);

    // Stopping with both commands still in `connecting` must settle both
    // fetches. The owner leaves its idle park on stop, and that exit must
    // fail coalesced connect groups too.
    engine.deinit();
    engine_alive = false;

    try waitTaskDone(&task_a, 1_000);
    try waitTaskDone(&task_b, 1_000);
}

test "egress engine canceled h2 connect keeps the origin usable" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const bind_address = try std.net.Address.parseIp4(host, 0);

    var state_a = SilentOriginState{};
    var server_a = try bind_address.listen(.{ .reuse_address = true });
    const thread_a = try std.Thread.spawn(.{}, silentOriginMain, .{ &server_a, &state_a });
    defer stopSilentOrigin(&server_a, &state_a, thread_a);
    var state_b = SilentOriginState{};
    var server_b = try bind_address.listen(.{ .reuse_address = true });
    const thread_b = try std.Thread.spawn(.{}, silentOriginMain, .{ &server_b, &state_b });
    defer stopSilentOrigin(&server_b, &state_b, thread_b);

    const url_a = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server_a.listen_address.getPort() });
    defer std.testing.allocator.free(url_a);
    const url_b = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server_b.listen_address.getPort() });
    defer std.testing.allocator.free(url_b);

    var task_a = try initEngineFetchTask(std.testing.allocator, 41, url_a, 41);
    defer task_a.deinit();
    var task_b = try initEngineFetchTask(std.testing.allocator, 42, url_b, 42);
    defer task_b.deinit();
    var task_c = try initEngineFetchTask(std.testing.allocator, 43, url_b, 43);
    defer task_c.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_private_networks = true,
        .enable_http2 = true,
        .insecure_tls = true,
        .socket_timeout_ms = 300,
    };

    // Occupy the single connector with origin A's (silent) handshake, queue
    // a connect for origin B behind it, and cancel B before the connector
    // can pick it up.
    try engine.submit(.{ .task = &task_a, .config = config }, &wake, wakeEngineTest);
    try waitForAcceptedConnection(&state_a, 2_000);
    try engine.submit(.{ .task = &task_b, .config = config }, &wake, wakeEngineTest);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    task_b.markCanceled();
    engine.wakeCancellation();

    try waitTaskDone(&task_a, 3_000);
    try waitTaskDone(&task_b, 3_000);

    // The canceled connect must still publish an outcome so origin B's
    // connect group is torn down; otherwise a new fetch to the same origin
    // joins the orphaned group and never gets a connector dispatch.
    try engine.submit(.{ .task = &task_c, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&task_c, 3_000);
}

// The per-turn h1 drive budget admits at most `max_pendings` drives and
// stops admitting once `max_bytes` have been drained, whichever comes first,
// so a runnable burst is bounded per owner iteration in both dimensions.
test "egress h1 turn budget caps a drive pass by pendings and by drained bytes" {
    var budget = egress_engine.H1TurnBudget{};
    for (0..egress_engine.H1TurnBudget.max_pendings) |_|
        try std.testing.expect(budget.admitDrive());
    try std.testing.expect(!budget.admitDrive());

    budget = .{};
    try std.testing.expect(budget.admitDrive());
    budget.chargeDrained(egress_engine.H1TurnBudget.max_bytes);
    try std.testing.expect(!budget.admitDrive());

    budget = .{};
    try std.testing.expect(budget.admitDrive());
    budget.chargeDrained(egress_engine.H1TurnBudget.max_bytes - 1);
    try std.testing.expect(budget.admitDrive());
    // The charge saturates, so over-draining cannot wrap the budget back
    // open.
    budget.chargeDrained(std.math.maxInt(usize));
    try std.testing.expect(!budget.admitDrive());
}

// One engine holds 130 io-parked h1 fetches. None may fail early, a
// co-located fetch keeps completing while the herd is parked, the owner does
// not spin, every stall deadline still fires, and no armed poll survives the
// herd.
test "egress engine holds 130 io-parked HTTP1 fetches without spin or mass-fail" {
    const herd_count = 130;
    var origin = try HeldOrigin.start(std.testing.allocator, herd_count);
    defer origin.stop(std.testing.allocator);
    var fast_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer fast_origin.stop(std.testing.allocator);

    const held_url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);
    const fast_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ fast_origin.host(), fast_origin.port });
    defer std.testing.allocator.free(fast_url);

    const tasks = try std.testing.allocator.alloc(task_model.Task, herd_count);
    defer std.testing.allocator.free(tasks);
    var initialized: usize = 0;
    defer for (tasks[0..initialized]) |*task| task.deinit();
    var fast = try initEngineFetchTask(std.testing.allocator, 3999, fast_url, 3999);
    defer fast.deinit();

    // The engine is declared after the tasks so its deinit, which joins the
    // owner and connector threads, runs before any task is freed; the credit
    // releases deferred after it run first of all.
    var engine = try egress_engine.Engine.init(std.testing.allocator, 512, .{ .connector_count = 2 });
    defer engine.deinit();
    defer for (tasks[0..initialized]) |*task| releaseTaskBodyCredits(&engine, task);
    defer releaseTaskBodyCredits(&engine, &fast);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 3_000,
    };

    for (0..herd_count) |index| {
        const id: u64 = 3_000 + @as(u64, index);
        tasks[index] = try initEngineFetchTask(std.testing.allocator, id, held_url, id);
        initialized += 1;
        try engine.submit(.{ .task = &tasks[index], .config = config }, &wake, wakeEngineTest);
    }
    try origin.waitAccepted(herd_count, 10_000);

    // With the whole herd parked and every stall deadline still far off,
    // nothing may have settled.
    std.Thread.sleep(100 * std.time.ns_per_ms);
    for (tasks[0..initialized]) |*task| {
        task.mutex.lock();
        const done = task.done;
        task.mutex.unlock();
        if (done)
            return error.HerdFetchFailedEarly;
    }

    // Co-located traffic keeps flowing through the same owner loop while
    // 130 polls stay armed.
    try engine.submit(.{ .task = &fast, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&fast, 2_000);
    try expectTaskStatus(&fast, 200);
    try waitBodyComplete(fast.response_body, 2_000);

    // A parked owner iterates only on events and watchdog ticks; a spinning
    // one would run thousands of iterations in this window.
    const iterations_before = engine.snapshotH2Stats().iterations;
    std.Thread.sleep(300 * std.time.ns_per_ms);
    const iterations_delta = engine.snapshotH2Stats().iterations - iterations_before;
    try std.testing.expect(iterations_delta < 100);

    // Every stall deadline fires with the read-timeout error rather than a
    // driver capacity error or a hang.
    for (tasks[0..initialized]) |*task| {
        try waitTaskDone(task, 10_000);
        try expectTaskFailureMessage(task, "FetchReadTimeout");
    }
    // With the herd gone, the owner goes idle with every arm retired.
    try waitLiveArmedWatchCount(&engine, 0, 2_000);
}

// A pending canceled while io-parked must not leave its persistent poll
// armed when the owner goes idle: a late readiness CQE would land in a freed
// watch context. The test checks for zero live arms at the driver, then
// delivers late bytes and expects the engine to keep serving.
test "egress engine idle transition disarms the poll of a canceled parked fetch" {
    var origin = try HeldOrigin.start(std.testing.allocator, 1);
    defer origin.stop(std.testing.allocator);
    var fast_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer fast_origin.stop(std.testing.allocator);

    const held_url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);
    const fast_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ fast_origin.host(), fast_origin.port });
    defer std.testing.allocator.free(fast_url);

    var task = try initEngineFetchTask(std.testing.allocator, 4_100, held_url, 4_100);
    defer task.deinit();
    var second = try initEngineFetchTask(std.testing.allocator, 4_101, fast_url, 4_101);
    defer second.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);
    defer releaseTaskBodyCredits(&engine, &second);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try origin.waitAccepted(1, 5_000);
    // The fetch parked on readability, with exactly one live arm.
    try waitLiveArmedWatchCount(&engine, 1, 2_000);

    // Canceling the last pending makes the owner sweep it and reconcile to
    // zero sources before going idle, so its arm must not survive.
    task.markCanceled();
    engine.wakeCancellation();
    try waitTaskDone(&task, 2_000);
    try waitLiveArmedWatchCount(&engine, 0, 2_000);

    // With the arm retired, late readiness on the abandoned socket is
    // dropped and the engine keeps serving.
    origin.writeLate("late bytes");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try engine.submit(.{ .task = &second, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&second, 2_000);
    try expectTaskStatus(&second, 200);
    try waitBodyComplete(second.response_body, 2_000);
}

// An h1 body parked on consumer backpressure has no fd poll armed (the
// credit park is deadline-only), and the total request deadline still fires
// while the consumer never releases credit.
test "egress engine credit-parked h1 body disarms its poll and expires at the total deadline" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const stall_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stall", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(stall_url);

    var task = try initEngineFetchTask(std.testing.allocator, 4_200, stall_url, 4_200);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .max_pending_decoded_body_bytes = 1,
        .socket_timeout_ms = 10_000,
        .request_deadline_mono_ns = (try egress_client.data_io.monotonicNowNs()) + 700 * std.time.ns_per_ms,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&task, 2_000);
    try expectTaskStatus(&task, 200);

    // The consumer never releases credit, so the body pauses on
    // backpressure.
    const pause_start = try std.time.Instant.now();
    while (task.response_body.queuedDecodedBytes() == 0) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(pause_start) >= 2_000 * std.time.ns_per_ms)
            return error.Http1BodyNeverPaused;
    }
    // A credit park arms no poll; only its deadline-only source stays in
    // the desired set.
    try waitLiveArmedWatchCount(&engine, 0, 2_000);

    // The total request deadline bounds the stalled consumer.
    const fail_start = try std.time.Instant.now();
    while (!task.response_body.isFailed()) {
        try std.testing.expect(bodyState(task.response_body) != .complete);
        std.Thread.sleep(2 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(fail_start) >= 5_000 * std.time.ns_per_ms)
            return error.CreditParkedBodyNeverExpired;
    }
}

// Several concurrent large fast bodies, all runnable with ample credit so
// only the fairness budgets break them up, must not starve a fetch
// submitted mid-burst, and the self-wake carryover must drive every yielded
// body to EOF; a lost carryover strands a runnable pending forever.
test "egress engine drive budget interleaves concurrent large bodies with new fetches" {
    const big_count = 4;
    const big_len: u64 = http1_support.big_body_bytes;
    var big_origins: [big_count]?*http1_support.LocalHttp1Origin = @splat(null);
    defer for (&big_origins) |*maybe_origin| {
        if (maybe_origin.*) |big_origin| big_origin.stop(std.testing.allocator);
    };
    for (&big_origins) |*slot|
        slot.* = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    var small_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer small_origin.stop(std.testing.allocator);

    var big_urls: [big_count]?[]u8 = @splat(null);
    defer for (&big_urls) |*maybe_url| {
        if (maybe_url.*) |big_url| std.testing.allocator.free(big_url);
    };
    for (&big_urls, 0..) |*slot, index| {
        const big_origin = big_origins[index].?;
        slot.* = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/big", .{ big_origin.host(), big_origin.port });
    }
    const small_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ small_origin.host(), small_origin.port });
    defer std.testing.allocator.free(small_url);

    var bigs: [big_count]?task_model.Task = @splat(null);
    defer for (&bigs) |*maybe_task| {
        if (maybe_task.*) |*task| task.deinit();
    };
    var small = try initEngineFetchTaskShaped(std.testing.allocator, 4_350, small_url, 4_350, "GET", "", 1024);
    defer small.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 32, .{ .connector_count = 2 });
    defer engine.deinit();
    defer for (&bigs) |*maybe_task| {
        if (maybe_task.*) |*task| releaseTaskBodyCredits(&engine, task);
    };
    defer releaseTaskBodyCredits(&engine, &small);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = @intCast(big_len * 2),
        .max_encoded_response_bytes = @intCast(big_len * 2),
        .max_pending_decoded_body_bytes = @intCast(big_len * 2),
        .socket_timeout_ms = 10_000,
    };

    for (&bigs, 0..) |*slot, index| {
        const id: u64 = 4_300 + @as(u64, index);
        slot.* = try initEngineFetchTaskShaped(std.testing.allocator, id, big_urls[index].?, id, "GET", "", big_len * 2);
        try engine.submit(.{ .task = &slot.*.?, .config = config }, &wake, wakeEngineTest);
    }
    // Submitted while the bodies stream, so the turn budget and drive quanta
    // must give the newcomer its share of the owner promptly.
    try engine.submit(.{ .task = &small, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&small, 10_000);
    try expectTaskStatus(&small, 200);
    try waitBodyComplete(small.response_body, 5_000);

    for (&bigs) |*maybe_task| {
        const task = &maybe_task.*.?;
        try waitTaskDone(task, 15_000);
        try expectTaskStatus(task, 200);
        const start = try std.time.Instant.now();
        while (bodyState(task.response_body) != .complete) {
            try std.testing.expect(!task.response_body.isFailed());
            std.Thread.sleep(1 * std.time.ns_per_ms);
            const now = try std.time.Instant.now();
            if (now.since(start) >= 20_000 * std.time.ns_per_ms)
                return error.LargeBodyDidNotComplete;
        }
        try std.testing.expectEqual(big_len, @as(u64, task.response_body.queuedDecodedBytes()));
    }
}

// A runnable burst wider than one turn budget, with more bulk-streaming
// pendings than the 4 MiB byte cap admits per pass, must not starve the
// pendings behind it. Each drive pass restarts at the head of the pending
// list, so only the rotation of yielders to the back keeps a fetch
// submitted behind the burst from going without service or a deadline
// source for as long as the burst stays runnable. Endless origins keep the
// burst runnable (socket data always waiting, never EOF), and a drain
// thread keeps releasing consumer credit so no head idles on backpressure;
// the tail fetch must still complete promptly.
test "egress engine turn budget exhaustion still services the tail pending" {
    // The 4 MiB turn byte cap admits 16 full 256 KiB quanta. Even when a few
    // heads find a shallow socket and io-park instead of streaming a full
    // quantum, 32 heads still carry one pass across the cap with runnables
    // to spare, so the exhaustion barrier below is reached on every run;
    // around 20 heads sit at the edge and reach it only sometimes.
    const head_count = 32;

    var head_origins: [head_count]?*http1_support.LocalHttp1Origin = @splat(null);
    defer for (&head_origins) |*maybe_origin| {
        if (maybe_origin.*) |head_origin| head_origin.stop(std.testing.allocator);
    };
    for (&head_origins) |*slot|
        slot.* = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    var tail_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer tail_origin.stop(std.testing.allocator);

    var head_urls: [head_count]?[]u8 = @splat(null);
    defer for (&head_urls) |*maybe_url| {
        if (maybe_url.*) |head_url| std.testing.allocator.free(head_url);
    };
    for (&head_urls, 0..) |*slot, index| {
        const head_origin = head_origins[index].?;
        slot.* = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/endless", .{ head_origin.host(), head_origin.port });
    }
    const tail_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ tail_origin.host(), tail_origin.port });
    defer std.testing.allocator.free(tail_url);

    const heads = try std.testing.allocator.alloc(task_model.Task, head_count);
    defer std.testing.allocator.free(heads);
    var initialized: usize = 0;
    defer for (heads[0..initialized]) |*task| task.deinit();
    var tail = try initEngineFetchTaskShaped(std.testing.allocator, 4_999, tail_url, 4_999, "GET", "", 1024);
    defer tail.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 512, .{ .connector_count = 2 });
    defer engine.deinit();
    defer for (heads[0..initialized]) |*task| releaseTaskBodyCredits(&engine, task);
    defer releaseTaskBodyCredits(&engine, &tail);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        // The bodies are endless and close-delimited, so the cumulative caps
        // are set high enough never to fire during the test, and memory is
        // bounded by the pending-decoded cap times the head count. That cap
        // is twice the 256 KiB drive quantum, so a drive on a freshly
        // drained pipe exhausts its quantum and yields instead of pausing at
        // the capacity boundary; only full quanta exhaust the turn's byte
        // budget.
        .max_response_body_bytes = 1 << 40,
        .max_encoded_response_bytes = 1 << 40,
        .max_pending_decoded_body_bytes = 512 * 1024,
        .socket_timeout_ms = 10_000,
    };

    for (0..head_count) |index| {
        const id: u64 = 4_900 + @as(u64, index);
        heads[index] = try initEngineFetchTaskShaped(std.testing.allocator, id, head_urls[index].?, id, "GET", "", 1024 * 1024);
        initialized += 1;
        try engine.submit(.{ .task = &heads[index], .config = config }, &wake, wakeEngineTest);
    }
    // Once every head is published, the burst is streaming.
    for (heads[0..initialized]) |*task| {
        try waitTaskDone(task, 10_000);
        try expectTaskStatus(task, 200);
    }

    // The drain thread keeps releasing the heads' consumer credit so they
    // stay runnable; a paused head stops consuming turn budget and would
    // hide the starvation.
    var drain = HeadDrainState{ .engine = &engine, .tasks = heads[0..initialized] };
    const drain_thread = try std.Thread.spawn(.{}, headDrainMain, .{&drain});
    var drain_joined = false;
    defer if (!drain_joined) {
        drain.stop.store(true, .release);
        drain_thread.join();
    };

    // Before the tail arrives, wait until a drive pass was cut short by the
    // turn budget with a runnable still waiting. With 32 heads the
    // 64-pending admit cap is out of reach, so only the 4 MiB byte cap can
    // cut a pass, after 16 full streaming quanta; connect dispatches drain
    // no bytes and cannot satisfy this barrier before the bodies stream.
    try waitH1TurnBudgetExhaustedAtLeast(&engine, 1, 20_000);

    // Submitted behind the burst, the tail must get the owner within a few
    // turn budgets, well inside the timeout.
    try engine.submit(.{ .task = &tail, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&tail, 10_000);
    try expectTaskStatus(&tail, 200);
    try waitBodyComplete(tail.response_body, 5_000);

    // Stop draining, cancel the endless heads, and wait for every head body
    // to settle so no append races the final credit drain.
    drain.stop.store(true, .release);
    drain_thread.join();
    drain_joined = true;
    for (heads[0..initialized]) |*task| task.markCanceled();
    engine.wakeCancellation();
    for (heads[0..initialized]) |*task| {
        const start = try std.time.Instant.now();
        while (!task.response_body.isFailed()) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            const now = try std.time.Instant.now();
            if (now.since(start) >= 10_000 * std.time.ns_per_ms)
                return error.EndlessHeadNeverSettled;
        }
    }
}

// A drive pass grants each runnable pending at most one quantum, so with 3
// endless streaming pendings no pass drives or yields more than 3 times.
// Rotating a yielder to the back leaves its index on the next pending, so a
// pass that is not bounded by the runnable count taken at its start keeps
// alternating between yielders until the turn budget ends it at 16 quanta.
test "egress engine drive pass grants each runnable at most one quantum" {
    const head_count = 3;

    var head_origins: [head_count]?*http1_support.LocalHttp1Origin = @splat(null);
    defer for (&head_origins) |*maybe_origin| {
        if (maybe_origin.*) |head_origin| head_origin.stop(std.testing.allocator);
    };
    for (&head_origins) |*slot|
        slot.* = try http1_support.LocalHttp1Origin.start(std.testing.allocator);

    var head_urls: [head_count]?[]u8 = @splat(null);
    defer for (&head_urls) |*maybe_url| {
        if (maybe_url.*) |head_url| std.testing.allocator.free(head_url);
    };
    for (&head_urls, 0..) |*slot, index| {
        const head_origin = head_origins[index].?;
        slot.* = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/endless", .{ head_origin.host(), head_origin.port });
    }

    const heads = try std.testing.allocator.alloc(task_model.Task, head_count);
    defer std.testing.allocator.free(heads);
    var initialized: usize = 0;
    defer for (heads[0..initialized]) |*task| task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 64, .{ .connector_count = 2 });
    defer engine.deinit();
    defer for (heads[0..initialized]) |*task| releaseTaskBodyCredits(&engine, task);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1 << 40,
        .max_encoded_response_bytes = 1 << 40,
        // Twice the 256 KiB drive quantum: a drive on a freshly drained
        // pipe exhausts its quantum and yields instead of pausing at the
        // capacity boundary, so the yields-per-pass barrier below is
        // reachable by construction.
        .max_pending_decoded_body_bytes = 512 * 1024,
        .socket_timeout_ms = 10_000,
    };

    for (0..head_count) |index| {
        const id: u64 = 6_000 + @as(u64, index);
        heads[index] = try initEngineFetchTaskShaped(std.testing.allocator, id, head_urls[index].?, id, "GET", "", 1024 * 1024);
        initialized += 1;
        try engine.submit(.{ .task = &heads[index], .config = config }, &wake, wakeEngineTest);
    }
    for (heads[0..initialized]) |*task| {
        try waitTaskDone(task, 10_000);
        try expectTaskStatus(task, 200);
    }

    // The credit drain keeps every head runnable, yielding and never
    // pausing.
    var drain = HeadDrainState{ .engine = &engine, .tasks = heads[0..initialized] };
    const drain_thread = try std.Thread.spawn(.{}, headDrainMain, .{&drain});
    var drain_joined = false;
    defer if (!drain_joined) {
        drain.stop.store(true, .release);
        drain_thread.join();
    };

    // Wait for a pass in which at least 2 drives yielded, which proves that
    // several pendings streamed in one pass. The drives-per-pass maximum
    // cannot serve as this barrier: connect dispatches and io parks count
    // there too, so it could be met before any body streams and the
    // assertions below would pass vacuously.
    try waitH1PassYieldsAtLeast(&engine, 2, 10_000);
    // No pass may have driven or yielded more entries than the 3 pendings
    // that exist.
    const stats = engine.snapshotH2Stats();
    try std.testing.expect(stats.h1_pass_drives_max <= head_count);
    try std.testing.expect(stats.h1_pass_yields_max <= head_count);

    drain.stop.store(true, .release);
    drain_thread.join();
    drain_joined = true;
    for (heads[0..initialized]) |*task| task.markCanceled();
    engine.wakeCancellation();
    for (heads[0..initialized]) |*task| {
        const start = try std.time.Instant.now();
        while (!task.response_body.isFailed()) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            const now = try std.time.Instant.now();
            if (now.since(start) >= 10_000 * std.time.ns_per_ms)
                return error.EndlessHeadNeverSettled;
        }
    }
}

// When the owner loop escapes on a fatal watch-build failure, it must not
// publish the connect-group command a connector is still executing:
// publishing could release the task's last reference while the connector
// still dereferences it. The task settles exactly once, through the
// connector's own completion delivery, after the connector returns.
test "egress engine owner escape leaves the connector-held connect command to the connector" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const bind_address = try std.net.Address.parseIp4(host, 0);

    var state = SilentOriginState{};
    var server = try bind_address.listen(.{ .reuse_address = true });
    const origin_thread = try std.Thread.spawn(.{}, silentOriginMain, .{ &server, &state });
    defer stopSilentOrigin(&server, &state, origin_thread);

    const url = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server.listen_address.getPort() });
    defer std.testing.allocator.free(url);

    // A held h1 fetch, io-parked on the data wait, keeps the owner out of
    // its idle park; with only a connect group in flight the owner would
    // park on the idle condvar and the injected build fault would never run.
    var held_origin = try HeldOrigin.start(std.testing.allocator, 1);
    defer held_origin.stop(std.testing.allocator);
    const held_url = try held_origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);

    var task = try initEngineFetchTask(std.testing.allocator, 6_100, url, 6_100);
    defer task.deinit();
    var held_task = try initEngineFetchTask(std.testing.allocator, 6_101, held_url, 6_101);
    defer held_task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    var engine_alive = true;
    errdefer if (engine_alive) engine.deinit();
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    // The silent origin holds the connector inside the TLS handshake for the
    // whole 5 s stage timeout, far longer than the owner fault below takes
    // to latch, so the connector is still executing the command when the
    // owner escapes.
    const config = egress_client.Config{
        .allow_private_networks = true,
        .enable_http2 = true,
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
    };
    const h1_config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &held_task, .config = h1_config }, &wake, wakeEngineTest);
    try held_origin.waitAccepted(1, 5_000);
    try waitLiveArmedWatchCount(&engine, 1, 2_000);
    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try waitForAcceptedConnection(&state, 2_000);

    // The owner escapes on a sticky watch-build failure while the connector
    // is mid-dial, so failAllH2Connecting runs with the group's dispatched
    // command in flight.
    engine.armTestH2BuildFault(error.OutOfMemory);
    engine.wakeCancellation();
    var fault: ?anyerror = null;
    const start = try std.time.Instant.now();
    while (fault == null) {
        fault = engine.takeOwnerFault();
        if (fault != null)
            break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 2_000 * std.time.ns_per_ms)
            return error.OwnerFaultNeverLatched;
    }
    try std.testing.expectEqual(@as(anyerror, error.OutOfMemory), fault.?);

    // The escape settles what the owner owns: the parked h1 pending.
    try waitTaskDone(&held_task, 2_000);
    try expectTaskFailureMessage(&held_task, "OutOfMemory");
    // The connector-held task stays unsettled; its last dereference belongs
    // to the connector.
    task.mutex.lock();
    const done_during_dial = task.done;
    task.mutex.unlock();
    try std.testing.expect(!done_during_dial);

    // Stopping joins the connector once its handshake fails against the
    // silent origin; the refused completion handoff or the stop's queue
    // drain then settles the task exactly once, after the connector returns.
    engine.deinit();
    engine_alive = false;
    try waitTaskDone(&task, 2_000);
    try expectTaskFailureMessage(&task, "EgressEngineStopped");
}

// The h1 counterpart of the test above: an owner-loop escape must not settle
// an h1 pending whose dial a connector is still executing. Settling drops
// the fetch's last task references (the gateway retires the fetch once it
// settles, and the pending's deinit releases its retain) while the
// connector still dereferences `command.task` through its cancel probe and
// dial; the testing allocator would catch the use-after-free. The failAll
// sweep skips the `.awaiting_connect` pending, and the connector's
// completion delivery settles it exactly once after the dial returns.
test "egress engine owner escape leaves the connector-held h1 dial to the connector" {
    var host_buffer: [64]u8 = undefined;
    const host = try local_address.routableLocalIpv4(&host_buffer);
    const bind_address = try std.net.Address.parseIp4(host, 0);

    var state = SilentOriginState{};
    var server = try bind_address.listen(.{ .reuse_address = true });
    const origin_thread = try std.Thread.spawn(.{}, silentOriginMain, .{ &server, &state });
    defer stopSilentOrigin(&server, &state, origin_thread);

    const url = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/", .{ host, server.listen_address.getPort() });
    defer std.testing.allocator.free(url);

    // A held h1 fetch keeps owner-owned work alive across the escape, so the
    // test sees the sweep tell the two apart: the io-parked pending settles
    // with the owner fault and the connector-held one does not.
    var held_origin = try HeldOrigin.start(std.testing.allocator, 1);
    defer held_origin.stop(std.testing.allocator);
    const held_url = try held_origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);

    var task = try initEngineFetchTask(std.testing.allocator, 6_200, url, 6_200);
    defer task.deinit();
    var held_task = try initEngineFetchTask(std.testing.allocator, 6_201, held_url, 6_201);
    defer held_task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    var engine_alive = true;
    errdefer if (engine_alive) engine.deinit();
    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    // With enable_http2 false the https URL takes the owner's h1 path, whose
    // pool-miss dispatch hands the blocking TLS dial to the connector. The
    // silent origin holds that handshake for the whole 5 s stage timeout,
    // far longer than the owner fault below takes to latch, so the connector
    // is still executing the command when the owner escapes.
    const config = egress_client.Config{
        .allow_private_networks = true,
        .enable_http2 = false,
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
    };
    const h1_config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &held_task, .config = h1_config }, &wake, wakeEngineTest);
    try held_origin.waitAccepted(1, 5_000);
    try waitLiveArmedWatchCount(&engine, 1, 2_000);
    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try waitForAcceptedConnection(&state, 2_000);

    // The owner escapes on a sticky watch-build failure while the connector
    // is mid-dial, so failAllH1Pending runs with the pending parked
    // `.awaiting_connect`.
    engine.armTestH2BuildFault(error.OutOfMemory);
    engine.wakeCancellation();
    var fault: ?anyerror = null;
    const start = try std.time.Instant.now();
    while (fault == null) {
        fault = engine.takeOwnerFault();
        if (fault != null)
            break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 2_000 * std.time.ns_per_ms)
            return error.OwnerFaultNeverLatched;
    }
    try std.testing.expectEqual(@as(anyerror, error.OutOfMemory), fault.?);

    // The escape settles what the owner owns: the io-parked h1 pending.
    try waitTaskDone(&held_task, 2_000);
    try expectTaskFailureMessage(&held_task, "OutOfMemory");
    // The connector-held task stays unsettled during the dial; its last
    // dereference belongs to the connector.
    task.mutex.lock();
    const done_during_dial = task.done;
    task.mutex.unlock();
    try std.testing.expect(!done_during_dial);

    // Stopping while the connector still dials makes the join wait out the
    // handshake. One completion delivery then settles the task exactly once,
    // after the connector returns: the drained outcome, the drained
    // never-popped command, or the sweep of pendings whose handoff was
    // refused.
    engine.deinit();
    engine_alive = false;
    try waitTaskDone(&task, 2_000);
    try expectTaskFailureMessage(&task, "EgressEngineStopped");
}

const HeadDrainState = struct {
    engine: *egress_engine.Engine,
    tasks: []task_model.Task,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Releases the heads' queued body credit until stopped, so streaming heads
/// never pause on consumer backpressure.
fn headDrainMain(state: *HeadDrainState) void {
    while (!state.stop.load(.acquire)) {
        for (state.tasks) |*task|
            releaseTaskBodyCredits(state.engine, task);
        std.Thread.sleep(200 * std.time.ns_per_us);
    }
}

// A failed data wait means the driver can no longer deliver readiness or
// deadlines. The owner must fail both the h2 and the h1 pending lists (a
// surviving h1 pending keeps the loop out of its idle park, spinning),
// disarm every watch, and park while staying alive for new work.
test "egress engine data wait failure fails both pending lists and parks" {
    var origin = try HeldOrigin.start(std.testing.allocator, 2);
    defer origin.stop(std.testing.allocator);
    var fast_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer fast_origin.stop(std.testing.allocator);

    const held_url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);
    const fast_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ fast_origin.host(), fast_origin.port });
    defer std.testing.allocator.free(fast_url);

    var first = try initEngineFetchTask(std.testing.allocator, 4_400, held_url, 4_400);
    defer first.deinit();
    var second = try initEngineFetchTask(std.testing.allocator, 4_401, held_url, 4_401);
    defer second.deinit();
    var after = try initEngineFetchTask(std.testing.allocator, 4_402, fast_url, 4_402);
    defer after.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &first);
    defer releaseTaskBodyCredits(&engine, &second);
    defer releaseTaskBodyCredits(&engine, &after);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &first, .config = config }, &wake, wakeEngineTest);
    try engine.submit(.{ .task = &second, .config = config }, &wake, wakeEngineTest);
    try origin.waitAccepted(2, 5_000);
    try waitLiveArmedWatchCount(&engine, 2, 2_000);

    engine.armTestH2WaitFault(error.EgressDataIoFailed);
    engine.signalH2Wake();

    // Both h1 pendings settle with the wait error.
    try waitTaskDone(&first, 2_000);
    try waitTaskDone(&second, 2_000);
    try expectTaskFailureMessage(&first, "EgressDataIoFailed");
    try expectTaskFailureMessage(&second, "EgressDataIoFailed");
    try waitLiveArmedWatchCount(&engine, 0, 2_000);

    // The loop parks instead of spinning on the failed wait.
    std.Thread.sleep(100 * std.time.ns_per_ms);
    const iterations_before = engine.snapshotH2Stats().iterations;
    std.Thread.sleep(300 * std.time.ns_per_ms);
    const iterations_delta = engine.snapshotH2Stats().iterations - iterations_before;
    try std.testing.expect(iterations_delta < 50);

    // It still serves new work.
    try engine.submit(.{ .task = &after, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&after, 2_000);
    try expectTaskStatus(&after, 200);
    try waitBodyComplete(after.response_body, 2_000);
}

// A watch-list build failure is sticky (an allocation failure at the
// shard's memory budget repeats on every retry), so the owner settles
// everything it owns and escapes h2Main, latching the owner fault for the
// shard supervisor instead of spinning on a build that keeps failing.
test "egress engine watch build failure settles pendings and latches the owner fault" {
    var origin = try HeldOrigin.start(std.testing.allocator, 1);
    defer origin.stop(std.testing.allocator);
    const held_url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);

    var task = try initEngineFetchTask(std.testing.allocator, 4_500, held_url, 4_500);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try origin.waitAccepted(1, 5_000);
    try waitLiveArmedWatchCount(&engine, 1, 2_000);

    engine.armTestH2BuildFault(error.OutOfMemory);
    engine.wakeCancellation();

    // The parked pending settles instead of stranding behind a dead owner.
    try waitTaskDone(&task, 2_000);
    try expectTaskFailureMessage(&task, "OutOfMemory");

    // The escape latched the owner fault for the shard supervisor.
    var fault: ?anyerror = null;
    const start = try std.time.Instant.now();
    while (fault == null) {
        fault = engine.takeOwnerFault();
        if (fault != null)
            break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 2_000 * std.time.ns_per_ms)
            return error.OwnerFaultNeverLatched;
    }
    try std.testing.expectEqual(@as(anyerror, error.OutOfMemory), fault.?);
}

// The shard supervisor answers an owner escape with stop and start on the
// same engine, because the gateway's seccomp filter forbids building a new
// one. The restart must clear the latched fault and serve new work on the
// threads and rings of the first start; the forked restart under the real
// filter is in the gateway's shard_chaos.zig.
test "egress engine serves again after an owner escape, stop and start" {
    var origin = try HeldOrigin.start(std.testing.allocator, 1);
    defer origin.stop(std.testing.allocator);
    var fast_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer fast_origin.stop(std.testing.allocator);

    const held_url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);
    const fast_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ fast_origin.host(), fast_origin.port });
    defer std.testing.allocator.free(fast_url);

    var held = try initEngineFetchTask(std.testing.allocator, 4_700, held_url, 4_700);
    defer held.deinit();
    var after = try initEngineFetchTask(std.testing.allocator, 4_701, fast_url, 4_701);
    defer after.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &held);
    defer releaseTaskBodyCredits(&engine, &after);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &held, .config = config }, &wake, wakeEngineTest);
    try origin.waitAccepted(1, 5_000);
    try waitLiveArmedWatchCount(&engine, 1, 2_000);

    engine.armTestH2BuildFault(error.OutOfMemory);
    engine.wakeCancellation();
    try waitTaskDone(&held, 2_000);
    try expectTaskFailureMessage(&held, "OutOfMemory");
    const start = try std.time.Instant.now();
    while (engine.owner_fault.load(.acquire) == 0) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 2_000 * std.time.ns_per_ms)
            return error.OwnerFaultNeverLatched;
    }

    engine.stop();
    try engine.start(&wake, wakeEngineTest);
    try std.testing.expect(engine.takeOwnerFault() == null);

    try engine.submit(.{ .task = &after, .config = config }, &wake, wakeEngineTest);
    try waitTaskDone(&after, 2_000);
    try expectTaskStatus(&after, 200);
    try waitBodyComplete(after.response_body, 2_000);
}

// After a failed syncSources the driver cannot be trusted to watch anything,
// and a ring-level failure such as a dead ring is sticky. Failing the work
// and continuing would re-enter the same failing reconcile on every dirty
// iteration and spin forever, because failAllOwnerWork's own empty re-sync
// deliberately swallows its error. As with a watch-build failure, the owner
// must settle everything it owns, disarm the watches, and latch the owner
// fault for the shard supervisor.
test "egress engine sync failure settles pendings and latches the owner fault" {
    var origin = try HeldOrigin.start(std.testing.allocator, 1);
    defer origin.stop(std.testing.allocator);
    const held_url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);

    var task = try initEngineFetchTask(std.testing.allocator, 4_600, held_url, 4_600);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8, .{ .connector_count = 1 });
    defer engine.deinit();
    defer releaseTaskBodyCredits(&engine, &task);

    var wake = WakeState{ .count = std.atomic.Value(usize).init(0) };
    const config = egress_client.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &task, .config = config }, &wake, wakeEngineTest);
    try origin.waitAccepted(1, 5_000);
    try waitLiveArmedWatchCount(&engine, 1, 2_000);

    engine.armTestH2SyncFault(error.EgressDataIoFailed);
    engine.wakeCancellation();

    // The parked pending settles with the sync error.
    try waitTaskDone(&task, 2_000);
    try expectTaskFailureMessage(&task, "EgressDataIoFailed");
    // The watches are disarmed: tokens retire in userspace, so this holds
    // even when the teardown's ring flush fails.
    try waitLiveArmedWatchCount(&engine, 0, 2_000);

    // The escape latched the owner fault for the shard supervisor.
    var fault: ?anyerror = null;
    const start = try std.time.Instant.now();
    while (fault == null) {
        fault = engine.takeOwnerFault();
        if (fault != null)
            break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 2_000 * std.time.ns_per_ms)
            return error.OwnerFaultNeverLatched;
    }
    try std.testing.expectEqual(@as(anyerror, error.EgressDataIoFailed), fault.?);
}

const SilentOriginState = struct {
    accepted: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Accepts and holds connections without ever writing a byte, so a TLS
/// handshake against it blocks until the client's own deadline.
fn silentOriginMain(server: *std.net.Server, state: *SilentOriginState) void {
    var held: [4]?std.net.Stream = .{ null, null, null, null };
    var held_len: usize = 0;
    defer for (held[0..held_len]) |maybe_stream| {
        if (maybe_stream) |stream| stream.close();
    };
    while (true) {
        const connection = server.accept() catch return;
        if (state.stopping.load(.acquire)) {
            connection.stream.close();
            return;
        }
        if (held_len < held.len) {
            held[held_len] = connection.stream;
            held_len += 1;
        } else {
            connection.stream.close();
        }
        _ = state.accepted.fetchAdd(1, .acq_rel);
    }
}

fn stopSilentOrigin(server: *std.net.Server, state: *SilentOriginState, thread: std.Thread) void {
    state.stopping.store(true, .release);
    if (std.net.tcpConnectToAddress(server.listen_address)) |wake| {
        wake.close();
    } else |_| {}
    thread.join();
    server.deinit();
}

fn waitForAcceptedConnection(state: *SilentOriginState, timeout_ms: u64) !void {
    const start = try std.time.Instant.now();
    while (state.accepted.load(.acquire) == 0) {
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.ConnectorNeverDialed;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

const WakeState = struct {
    count: std.atomic.Value(usize),
};

/// Accepts and holds up to `capacity` connections without reading a request
/// or writing a response, so every fetch against it io-parks until its own
/// stall deadline. `writeLate` writes to the held sockets to model readiness
/// that arrives after the engine dropped its watches.
const HeldOrigin = struct {
    server: std.net.Server,
    held: []?std.net.Stream,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    thread: std.Thread = undefined,
    held_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    accepted: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(allocator: std.mem.Allocator, capacity: usize) !*HeldOrigin {
        var host_buffer: [64]u8 = undefined;
        const host_text = try local_address.routableLocalIpv4(&host_buffer);
        const bind_address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var server = try bind_address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const held = try allocator.alloc(?std.net.Stream, capacity);
        errdefer allocator.free(held);
        @memset(held, null);
        const origin = try allocator.create(HeldOrigin);
        errdefer allocator.destroy(origin);
        origin.* = .{
            .server = server,
            .held = held,
            .host_buffer = host_buffer,
            .host_len = host_text.len,
            .port = server.listen_address.getPort(),
        };
        origin.thread = try std.Thread.spawn(.{}, HeldOrigin.threadMain, .{origin});
        return origin;
    }

    fn host(self: *const HeldOrigin) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    fn url(self: *const HeldOrigin, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://{s}:{d}/held", .{ self.host(), self.port });
    }

    fn stop(self: *HeldOrigin, allocator: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        if (std.net.Address.parseIp(self.host(), self.port)) |address| {
            if (std.net.tcpConnectToAddress(address)) |stream|
                stream.close()
            else |_| {}
        } else |_| {}
        self.thread.join();
        for (self.held[0..self.held_len.load(.acquire)]) |maybe_stream| {
            if (maybe_stream) |stream| stream.close();
        }
        self.server.deinit();
        allocator.free(self.held);
        allocator.destroy(self);
    }

    fn waitAccepted(self: *const HeldOrigin, count: usize, timeout_ms: u64) !void {
        const start_instant = try std.time.Instant.now();
        while (self.accepted.load(.acquire) < count) {
            const now = try std.time.Instant.now();
            if (now.since(start_instant) >= timeout_ms * std.time.ns_per_ms)
                return error.HeldOriginNeverAccepted;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Best-effort write on every held connection: readiness for sockets
    /// whose engine watches should already be gone.
    fn writeLate(self: *HeldOrigin, bytes: []const u8) void {
        for (self.held[0..self.held_len.load(.acquire)]) |maybe_stream| {
            if (maybe_stream) |stream|
                _ = stream.write(bytes) catch {};
        }
    }

    fn threadMain(self: *HeldOrigin) void {
        while (true) {
            const connection = self.server.accept() catch return;
            if (self.stopping.load(.acquire)) {
                connection.stream.close();
                return;
            }
            const held_len = self.held_len.load(.acquire);
            if (held_len < self.held.len) {
                self.held[held_len] = connection.stream;
                self.held_len.store(held_len + 1, .release);
            } else {
                connection.stream.close();
            }
            _ = self.accepted.fetchAdd(1, .acq_rel);
        }
    }
};

/// Waits until some h1 drive pass had at least `expected` drives yield, that
/// is, exhaust their quantum mid-body. A pass drives each runnable at most
/// once, and connect dispatches and io parks never yield, so this proves
/// that many pendings streamed in one pass.
fn waitH1PassYieldsAtLeast(engine: *egress_engine.Engine, expected: u64, timeout_ms: u64) !void {
    const start = try std.time.Instant.now();
    while (engine.snapshotH2Stats().h1_pass_yields_max < expected) {
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.H1PassYieldsNeverReached;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

/// Waits until at least `expected` h1 drive passes were cut short by the
/// per-turn budget with a runnable still waiting.
fn waitH1TurnBudgetExhaustedAtLeast(engine: *egress_engine.Engine, expected: u64, timeout_ms: u64) !void {
    const start = try std.time.Instant.now();
    while (engine.snapshotH2Stats().h1_turn_budget_exhausted < expected) {
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.H1TurnBudgetExhaustionNeverReached;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

/// Polls the owner's data driver until its live armed fd-watch count, the
/// one-shot polls whose token is still valid, equals `expected`.
fn waitLiveArmedWatchCount(engine: *egress_engine.Engine, expected: usize, timeout_ms: u64) !void {
    const driver = engine.h2DataDriver(0);
    const start = try std.time.Instant.now();
    while (driver.liveArmedWatchCount() != expected) {
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.ArmedWatchCountMismatch;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

/// Waits until a body is complete, with every chunk appended, so the
/// teardown credit drain sees the full queue; a drain that races ahead of
/// the last append leaves a chunk behind and trips the final-release
/// assertions.
fn waitBodyComplete(body: *fetch_body.Body, timeout_ms: u64) !void {
    const start = try std.time.Instant.now();
    while (bodyState(body) != .complete) {
        try std.testing.expect(!body.isFailed());
        std.Thread.sleep(1 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.BodyDidNotComplete;
    }
}

/// Failed fetches publish "fetch failed: <ErrorName>"; this matches the
/// error name at the end of the message.
fn expectTaskFailureMessage(task: *task_model.Task, expected_error_name: []const u8) !void {
    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    switch (result) {
        .success => return error.UnexpectedFetchSuccess,
        .failure => |failure| {
            if (!std.mem.endsWith(u8, failure.message, expected_error_name)) {
                std.debug.print("unexpected failure message: {s}\n", .{failure.message});
                return error.UnexpectedFailureMessage;
            }
        },
    }
}

const EngineCreditRelease = struct {
    engine: *egress_engine.Engine,
    count: usize = 0,
};

fn releaseCreditToEngine(context: *EngineCreditRelease, credit: egress_client.core.body_credit.Handle) void {
    context.engine.releaseFetchBodyCredit(credit);
    context.count += 1;
}

fn releaseTaskBodyCredits(engine: *egress_engine.Engine, task: *task_model.Task) void {
    var release_context = EngineCreditRelease{
        .engine = engine,
    };
    task.response_body.releaseQueuedChunksCallback(
        std.testing.allocator,
        &release_context,
        releaseCreditToEngine,
    );
}

fn wakeEngineTest(ctx: ?*anyopaque, event: egress_engine.WakeEvent) void {
    _ = event;
    const wake: *WakeState = @ptrCast(@alignCast(ctx orelse return));
    _ = wake.count.fetchAdd(1, .acq_rel);
}

fn initEngineFetchTask(
    allocator: std.mem.Allocator,
    id: u64,
    url: []const u8,
    body_id: u64,
) !task_model.Task {
    return initEngineFetchTaskShaped(allocator, id, url, body_id, "GET", "", 1024);
}

fn initEngineFetchTaskShaped(
    allocator: std.mem.Allocator,
    id: u64,
    url: []const u8,
    body_id: u64,
    method: []const u8,
    request_body: []const u8,
    max_body_bytes: u64,
) !task_model.Task {
    const identity = bindings.FetchBodyIdentity{
        .request_id = 100 + id,
        .request_generation = 200 + id,
        .fetch_id = id,
        .body_id = body_id,
    };
    const body = try allocator.create(fetch_body.Body);
    var body_owned = true;
    errdefer if (body_owned) {
        body.deinitAfterQueuedResourcesReleased(allocator);
        allocator.destroy(body);
    };
    body.* = fetch_body.Body.initOpen(allocator, identity, max_body_bytes);
    const task = try task_model.Task.init(
        allocator,
        id,
        100 + id,
        url,
        method,
        request_body,
        &.{},
        0,
        identity,
        body,
    );
    body_owned = false;
    return task;
}

fn waitTaskDone(task: *task_model.Task, timeout_ms: u64) !void {
    const start = try std.time.Instant.now();
    while (true) {
        task.mutex.lock();
        const done = task.done;
        task.mutex.unlock();
        if (done)
            return;
        const now = try std.time.Instant.now();
        if (now.since(start) >= timeout_ms * std.time.ns_per_ms)
            return error.TaskDidNotComplete;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

fn expectTaskStatus(task: *task_model.Task, expected: u16) !void {
    task.mutex.lock();
    defer task.mutex.unlock();
    const result = task.result orelse return error.MissingFetchResult;
    switch (result) {
        .success => |success| try std.testing.expectEqual(expected, success.status),
        .failure => return error.UnexpectedFetchFailure,
    }
}

fn bodyState(body: *fetch_body.Body) fetch_body.State {
    body.mutex.lock();
    defer body.mutex.unlock();
    return body.state;
}
