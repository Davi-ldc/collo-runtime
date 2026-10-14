//! Engine tests of HTTP/1 fetches (`egress/client/engine/h1.zig`, lane
//! `egress-test`): bodies parked on their consumer or their wire share the
//! owner loop with other fetches, a credit resumes a paused body, a cancel
//! ends a wire-parked fetch once, and the total deadline bounds a body parked
//! on credit. The exchange and body steps are tested on their own in
//! `../http1/`.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const http1_support = @import("../http1/support.zig");
const network_policy = @import("../network_policy.zig");
const support = @import("support.zig");

const egress_engine = egress_client.engine;
const task_model = egress_client.task;

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

    var first = try support.initEngineFetchTask(std.testing.allocator, 1, stall_url, 1);
    defer first.deinit();
    var second = try support.initEngineFetchTask(std.testing.allocator, 2, stall_url, 2);
    defer second.deinit();
    var third = try support.initEngineFetchTask(std.testing.allocator, 3, fast_url, 3);
    defer third.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &third);
    defer _ = support.releaseTaskBodyCredits(&engine, &second);
    defer _ = support.releaseTaskBodyCredits(&engine, &first);
    // Every body is still paused at the end, so the engine stops before the
    // releases above run: a credit a running engine took would let a body
    // append after its queue was emptied.
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = origin.policy(),
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .max_pending_decoded_body_bytes = 1,
        .socket_timeout_ms = 1_000,
    };

    try engine.submit(.{ .task = &first, .config = config });
    try support.waitTaskDone(&first, 1_000);
    try support.expectTaskStatus(&first, 200);

    try engine.submit(.{ .task = &second, .config = config });
    try support.waitTaskDone(&second, 1_000);
    try support.expectTaskStatus(&second, 200);

    try engine.submit(.{ .task = &third, .config = config });
    try support.waitTaskDone(&third, 1_000);
    try support.expectTaskStatus(&third, 200);
}

fn bigFirstHalfQueued(task: *task_model.Task) bool {
    return task.response_body.queuedBytes() == http1_support.big_held_first_bytes;
}

// A fetch submitted while a large body is half delivered completes on the
// same owner loop, and the large body is still driven to its end once the
// rest arrives. The origin holds the second half until the small fetch is
// done, so the large body cannot have finished first. That a body step
// consumes only what one receive delivered, so a flowing body yields the
// owner between receives, is tested on the continuation in
// `../http1/streaming.zig`.
test "egress engine HTTP1 fetch completes while a large body is half delivered" {
    var big_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer big_origin.stop(std.testing.allocator);
    var small_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer small_origin.stop(std.testing.allocator);

    const big_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/big-held", .{ big_origin.host(), big_origin.port });
    defer std.testing.allocator.free(big_url);
    const small_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stall", .{ small_origin.host(), small_origin.port });
    defer std.testing.allocator.free(small_url);

    const big_len: u64 = http1_support.big_body_bytes;
    var big = try support.initEngineFetchTaskShaped(std.testing.allocator, 70, big_url, 70, "GET", "", big_len * 2);
    defer big.deinit();
    var small = try support.initEngineFetchTaskShaped(std.testing.allocator, 71, small_url, 71, "GET", "", 1024);
    defer small.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &small);
    defer _ = support.releaseTaskBodyCredits(&engine, &big);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    // Both origins serve on this host's routable address.
    var origins: network_policy.Origins = .{};
    try origins.init(big_origin.host(), &.{ big_origin.port, small_origin.port });
    const config = egress_client.Config{
        .network = origins.policy(),
        .enable_http2 = false,
        .max_response_body_bytes = @intCast(big_len * 2),
        .max_encoded_response_bytes = @intCast(big_len * 2),
        .max_pending_decoded_body_bytes = @intCast(big_len * 2),
        .socket_timeout_ms = 5_000,
    };

    try engine.submit(.{ .task = &big, .config = config });
    try support.waitTaskDone(&big, 5_000);
    try support.expectTaskStatus(&big, 200);
    try support.waitUntil(&big, bigFirstHalfQueued, 5_000);

    try engine.submit(.{ .task = &small, .config = config });
    try support.waitTaskDone(&small, 5_000);
    try support.expectTaskStatus(&small, 200);
    try support.waitBodyComplete(small.response_body, 5_000);
    try std.testing.expect(support.queueState(big.response_body) == .open);
    try std.testing.expectEqual(http1_support.big_held_first_bytes, big.response_body.queuedBytes());

    big_origin.releaseHeldBody();
    try support.waitBodyComplete(big.response_body, 10_000);
    try std.testing.expectEqual(big_len, @as(u64, big.response_body.queuedBytes()));
}

test "egress engine HTTP1 paused body resumes from body credit" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const stall_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stall", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(stall_url);

    var task = try support.initEngineFetchTask(std.testing.allocator, 10, stall_url, 10);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &task);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = origin.policy(),
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .max_pending_decoded_body_bytes = 1,
        .socket_timeout_ms = 1_000,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 1_000);
    try support.expectTaskStatus(&task, 200);

    const start = try std.time.Instant.now();
    while (support.queueState(task.response_body) != .complete) {
        if (support.releaseTaskBodyCredits(&engine, &task) == 0)
            std.Thread.sleep(1 * std.time.ns_per_ms);
        try std.testing.expect(support.queueState(task.response_body) != .failed);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 1_000 * std.time.ns_per_ms)
            return error.Http1BodyDidNotResume;
    }
}

test "egress engine holds 130 wire-parked HTTP1 fetches without mass-fail" {
    const herd_count = 130;
    var origin = try support.HeldOrigin.start(std.testing.allocator, herd_count);
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
    var fast = try support.initEngineFetchTask(std.testing.allocator, 3999, fast_url, 3999);
    defer fast.deinit();

    // The engine is declared after the tasks so its deinit, which settles
    // every fetch and joins the owner, runs before any task is freed; the
    // stop deferred last runs first of all, then the credit releases.
    var engine = try egress_engine.Engine.init(std.testing.allocator, herd_count + 1);
    defer engine.deinit();
    defer for (tasks[0..initialized]) |*task| {
        _ = support.releaseTaskBodyCredits(&engine, task);
    };
    defer _ = support.releaseTaskBodyCredits(&engine, &fast);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);

    var origins: network_policy.Origins = .{};
    try origins.init(origin.host(), &.{ origin.port, fast_origin.port });
    const config = egress_client.Config{
        .network = origins.policy(),
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 3_000,
    };

    for (0..herd_count) |index| {
        const id: u64 = 3_000 + @as(u64, index);
        tasks[index] = try support.initEngineFetchTask(std.testing.allocator, id, held_url, id);
        initialized += 1;
        try engine.submit(.{ .task = &tasks[index], .config = config });
    }
    try origin.waitAccepted(herd_count, 10_000);

    // With the whole herd parked and every stall deadline still far off,
    // nothing may have settled.
    std.Thread.sleep(100 * std.time.ns_per_ms);
    for (tasks[0..initialized]) |*task|
        try std.testing.expect(!support.taskDone(task));

    // Co-located traffic keeps flowing through the same owner loop.
    try engine.submit(.{ .task = &fast, .config = config });
    try support.waitTaskDone(&fast, 2_000);
    try support.expectTaskStatus(&fast, 200);
    try support.waitBodyComplete(fast.response_body, 2_000);

    // Every stall deadline fires with the read-timeout error.
    for (tasks[0..initialized]) |*task| {
        try support.waitTaskDone(task, 10_000);
        try support.expectTaskFailureMessage(task, "FetchReadTimeout");
    }
}

// A cancel ends an HTTP/1 fetch parked on its wire at once; late bytes on the
// abandoned socket change nothing, and the engine keeps serving.
test "egress engine cancel of a wire-parked HTTP1 fetch settles it once" {
    var origin = try support.HeldOrigin.start(std.testing.allocator, 1);
    defer origin.stop(std.testing.allocator);
    var fast_origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer fast_origin.stop(std.testing.allocator);

    const held_url = try origin.url(std.testing.allocator);
    defer std.testing.allocator.free(held_url);
    const fast_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/fast", .{ fast_origin.host(), fast_origin.port });
    defer std.testing.allocator.free(fast_url);

    var task = try support.initEngineFetchTask(std.testing.allocator, 4_100, held_url, 4_100);
    defer task.deinit();
    var second = try support.initEngineFetchTask(std.testing.allocator, 4_101, fast_url, 4_101);
    defer second.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &task);
    defer _ = support.releaseTaskBodyCredits(&engine, &second);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);

    var origins: network_policy.Origins = .{};
    try origins.init(origin.host(), &.{ origin.port, fast_origin.port });
    const config = egress_client.Config{
        .network = origins.policy(),
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .socket_timeout_ms = 10_000,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try origin.waitAccepted(1, 5_000);
    std.Thread.sleep(20 * std.time.ns_per_ms);
    engine.cancel(&task);
    try support.waitTaskDone(&task, 2_000);
    try origin.waitPeerClosed(0, 2_000);

    origin.writeLate("late bytes");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try engine.submit(.{ .task = &second, .config = config });
    try support.waitTaskDone(&second, 2_000);
    try support.expectTaskStatus(&second, 200);
    try support.waitBodyComplete(second.response_body, 2_000);
    engine.stop();
    try support.expectSettledOnceCanceled(&wake, &task);
}

// An HTTP/1 body parked on consumer backpressure watches only the total
// request deadline, which still fires while the consumer never releases
// credit.
test "egress engine credit-parked HTTP1 body expires at the total deadline" {
    var origin = try http1_support.LocalHttp1Origin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);

    const stall_url = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/stall", .{ origin.host(), origin.port });
    defer std.testing.allocator.free(stall_url);

    var task = try support.initEngineFetchTask(std.testing.allocator, 4_200, stall_url, 4_200);
    defer task.deinit();

    var engine = try egress_engine.Engine.init(std.testing.allocator, 8);
    defer engine.deinit();
    defer _ = support.releaseTaskBodyCredits(&engine, &task);
    defer engine.stop();
    var wake = support.WakeState{};
    try support.startEngine(&engine, &wake);
    const config = egress_client.Config{
        .network = origin.policy(),
        .enable_http2 = false,
        .max_response_body_bytes = 1024,
        .max_encoded_response_bytes = 1024,
        .max_pending_decoded_body_bytes = 1,
        .socket_timeout_ms = 10_000,
        .request_deadline_mono_ns = (try egress_client.transport.config.monotonicNowNs()) + 700 * std.time.ns_per_ms,
    };

    try engine.submit(.{ .task = &task, .config = config });
    try support.waitTaskDone(&task, 2_000);
    try support.expectTaskStatus(&task, 200);

    // The consumer never releases credit, so the body pauses on
    // backpressure, and the total deadline bounds it.
    const start = try std.time.Instant.now();
    while (support.queueState(task.response_body) != .failed) {
        try std.testing.expect(support.queueState(task.response_body) != .complete);
        std.Thread.sleep(2 * std.time.ns_per_ms);
        const now = try std.time.Instant.now();
        if (now.since(start) >= 5_000 * std.time.ns_per_ms)
            return error.CreditParkedBodyNeverExpired;
    }
    try std.testing.expectEqualStrings("FetchRequestDeadlineExceeded", task.response_body.failureMessage().?);
}
