//! One shard's transport engine in the gateway (`egress/gateway/engine.zig`): a submission to an
//! engine that never started fails and leaves nothing behind, an assembled upload body going back
//! to the allocator it came with; a submission fails transactionally at every allocation; a
//! submitted task carries its record's handle, which every ready token of the task names; the
//! ready drain empties the wake eventfd and hands over the queued tokens and the scan bit; and,
//! with live engine threads, the transport checks each fetch against the policy its token named,
//! a denial reaching the worker as `network_denied` with the denial's text, while a stop of a
//! running fetch comes back as one abort ack once the engine settled the canceled task. Lane:
//! egress-gateway-test. Admission is covered in `command_flow.zig`, the pump in `body_pump.zig`
//! and shard restarts in `shard_flow.zig`.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const egress = @import("collo_egress_client");

const policy_image = @import("support/policy_image.zig");
const support = @import("support/gateway.zig");

const network = egress.network;
const runtime = gateway.runtime;
const Harness = support.Harness;

/// How long one wait for an engine thread's wake lasts before the test fails, and how many
/// collection rounds a test runs at most.
const wake_timeout_ms: i32 = 5_000;
const collection_rounds_max: usize = 64;

const inline_start = ipc.EgressFetchStartView{
    .fetch_id = 1,
    .egress_token = ipc.egress_token.none,
    .body_id = 1,
    .method = "GET",
    .url = "https://example.test/",
    .headers = &.{},
    .body = "",
};

const pooled_start = ipc.EgressFetchStartView{
    .fetch_id = 2,
    .egress_token = ipc.egress_token.none,
    .body_id = 2,
    .method = "POST",
    .url = "https://example.test/",
    .headers = &.{},
    .body = "",
};

const grant = gateway.engine.Grant{
    .isolation = .{},
    .network = network.public_https,
    .request_id = 1,
    .request_generation = 1,
    .deadline_mono_ns = 0,
    .max_response_body_bytes = 1024,
};

/// Runs collection passes on shard 0 whenever its wake eventfd turns readable, as the loop does,
/// until the table holds no fetch.
fn collectUntilEmpty(harness: *Harness) !void {
    const wake_fd = harness.gateway.shards.get(0).engine.wake_fd;
    var rounds: usize = 0;
    while (harness.gateway.fetches.count() != 0) : (rounds += 1) {
        if (rounds == collection_rounds_max)
            return error.TestTimeout;
        var pollfds = [_]std.posix.pollfd{.{ .fd = wake_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&pollfds, wake_timeout_ms) == 0)
            return error.TestTimeout;
        try runtime.shard_flow.collectShardReady(harness.gateway, 0);
    }
}

fn wakeFdReadable(fd: std.posix.fd_t) !bool {
    var pollfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&pollfds, 0) == 1;
}

/// Whether `message` is the denial text `network.writeDenial` writes for `origin` and one of
/// `candidates`. Which check of a hop refuses a loopback literal first is the transport's to
/// decide, so a test that only needs a denial names every denial the hop could get.
fn isDenialOf(message: []const u8, origin: network.Origin, candidates: []const network.Denial) !bool {
    for (candidates) |denial| {
        var buffer: [network.grant.denial_bytes_max]u8 = undefined;
        var expected: std.Io.Writer = .fixed(&buffer);
        try network.writeDenial(&expected, origin, denial);
        if (std.mem.eql(u8, expected.buffered(), message))
            return true;
    }
    return false;
}

test "a submission to an engine that never started fails, leaving the shard's memory and an owned body as they were" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const shard = harness.gateway.shards.get(0);
    const live_bytes_before = shard.memory.liveBytes();

    try std.testing.expectError(
        error.EgressEngineUnavailable,
        shard.engine.submit(1, inline_start, grant, null),
    );
    try std.testing.expectEqual(live_bytes_before, shard.memory.liveBytes());

    // An assembled upload body goes back to the allocator it came with, never the shard's.
    var body_memory = gateway.counting_allocator.CountingAllocator{ .child = std.testing.allocator };
    const body = try body_memory.allocator().dupe(u8, "assembled upload body");
    try std.testing.expectError(
        error.EgressEngineUnavailable,
        shard.engine.submit(2, pooled_start, grant, .{ .bytes = body, .allocator = body_memory.allocator() }),
    );
    try std.testing.expectEqual(@as(u64, 0), body_memory.liveBytes());
    try std.testing.expectEqual(live_bytes_before, shard.memory.liveBytes());
}

test "a submission that fails at any allocation leaves nothing behind" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var engine = try gateway.engine.Engine.init(failing.allocator(), .{ .sources_max = 16, .ready_event_capacity = 16 });
    defer engine.deinit();

    var failing_allocation: usize = 0;
    while (failing_allocation < 64) : (failing_allocation += 1) {
        failing.fail_index = failing.alloc_index + failing_allocation;
        const body = try std.testing.allocator.dupe(u8, "body");
        const outcome = engine.submit(1, pooled_start, grant, .{ .bytes = body, .allocator = std.testing.allocator });
        if (outcome) |_| {
            return error.TestUnexpectedResult;
        } else |err| switch (err) {
            error.OutOfMemory => continue,
            // Every allocation succeeded and the engine that never started refused the task.
            error.EgressEngineUnavailable => break,
            else => return err,
        }
    }
    // The testing allocator's leak check at the end shows every failed submission freed its
    // queue, its task and the owned body.
    try std.testing.expect(failing_allocation < 64);
    try std.testing.expect(failing_allocation >= 2);
}

test "a submitted task carries its record's handle, which its ready tokens name" {
    var harness = try Harness.init(.{ .start_shards = true });
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 3, .body_id = 4, .token = harness.token(.{}) });
    const handle = harness.gateway.fetches.find(harness.session_id, 3).?;
    const record = harness.gateway.fetches.get(handle).?;
    try std.testing.expect(record.stage == .running);
    const task = record.stage.running.task;
    try std.testing.expectEqual(handle, task.readyToken().generation);
}

test "the ready drain empties the wake eventfd and hands over the queued tokens and the scan bit" {
    var harness = try Harness.init(.{});
    defer harness.deinit();
    const engine = &harness.gateway.shards.get(0).engine;
    const fetch = try harness.startRunningFetch(5, 6, 0);

    try std.testing.expect(engine.ready.enqueueTask(fetch.task.readyToken()));
    try std.testing.expect(engine.ready.requestScan());
    engine.signalWake();
    try std.testing.expect(try wakeFdReadable(engine.wake_fd));

    var batch: [4]gateway.ready_scan.Event = undefined;
    const drained = engine.drainReady(&batch);
    try std.testing.expectEqual(@as(usize, 1), drained.len);
    try std.testing.expect(drained.scan_required);
    try std.testing.expect(!drained.has_more);
    try std.testing.expectEqual(fetch.handle, batch[0].handle);
    try std.testing.expectEqual(fetch.task, batch[0].task);
    try std.testing.expect(!try wakeFdReadable(engine.wake_fd));

    // A drain of an empty ring hands over nothing.
    const empty = engine.drainReady(&batch);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expect(!empty.scan_required);
}

test "the transport refuses a loopback fetch under the policy its token named, and the worker gets network_denied with the denial's text" {
    var harness = try Harness.init(.{ .start_shards = true });
    defer harness.deinit();

    // Policy 1 grants any public host over HTTPS; policy 0 grants nothing. Each URL is a loopback
    // literal, so the transport refuses it before DNS and nothing leaves the host.
    try harness.expectAdmitted(.{
        .fetch_id = 1,
        .body_id = 1,
        .token = harness.token(.{ .policy_id = policy_image.public_https_id }),
    });
    try harness.expectAdmitted(.{
        .fetch_id = 2,
        .body_id = 2,
        .token = harness.token(.{ .policy_id = network.table.deny_all_id }),
    });
    try collectUntilEmpty(&harness);

    var seen: [3]bool = @splat(false);
    for (0..2) |_| {
        const packet = (try harness.worker_endpoint.completion.readPacket(harness.read_buffer)) orelse
            return error.MissingQueuedFetchError;
        const failure = try ipc.decodeEgressFetchError(packet);
        try std.testing.expectEqual(ipc.EgressFetchErrorCause.network_denied, failure.cause);
        var host_buffer: [support.loopback_host_bytes_max]u8 = undefined;
        const origin = network.Origin{
            .scheme = .https,
            .host = support.loopbackHost(&host_buffer, failure.fetch_id),
            .port = support.loopback_port,
        };
        switch (failure.fetch_id) {
            1 => try std.testing.expect(try isDenialOf(failure.message, origin, &.{ .port_not_allowed, .reserved_address })),
            2 => try std.testing.expect(try isDenialOf(failure.message, origin, &.{ .no_grant, .reserved_address })),
            else => return error.TestUnexpectedResult,
        }
        seen[failure.fetch_id] = true;
    }
    try std.testing.expect(seen[1] and seen[2]);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expectEqual(@as(u32, 0), harness.session().fetches.len);
}

test "a stop of a fetch the engine runs comes back as one abort ack once the engine settled the task" {
    var harness = try Harness.init(.{ .start_shards = true });
    defer harness.deinit();

    try harness.expectAdmitted(.{ .fetch_id = 7, .body_id = 8, .token = harness.token(.{}) });
    try std.testing.expect(harness.sendStop(7));
    // Whether the engine settled the task before the stop or because of it, the record waits for
    // the settlement's collection, and the worker gets the ack and nothing else.
    if (harness.record(7) != null)
        try collectUntilEmpty(&harness);
    try harness.expectAbortAck(7, 8);
    try harness.expectNoMoreCompletionPackets();
    try std.testing.expectEqual(@as(usize, 0), harness.gateway.fetches.count());
}
