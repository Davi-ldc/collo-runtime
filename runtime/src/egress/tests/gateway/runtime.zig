//! The gateway loop's own state, apart from any engine: the shard a fetch hashes to, the router's
//! session-scoped route keys, what a route keeps and per-worker removal, the drop queue's
//! deduplication and overflow, the invalid-command window, a worker attach under allocation
//! failure, the readiness ring's size, and the hysteresis of the backpressure levels. The loop's
//! dispatch over a real endpoint is covered in `worker_flow.zig`, and its control socket in
//! `control_flow.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");

test "egress gateway shard hashing is deterministic and bounded" {
    const isolation: gateway.policy.PoolIsolation = .{
        .security_cell_id = [_]u8{10} ** 16,
        .policy_id = [_]u8{20} ** 16,
    };
    var other_cell = isolation;
    other_cell.security_cell_id[0] = 11;
    var other_policy = isolation;
    other_policy.policy_id[0] = 21;

    try std.testing.expectEqual(
        @as(usize, 0),
        gateway.shard.hashFetch(isolation, "https://api.example.test/v1", 1),
    );

    const shard_a = gateway.shard.hashFetch(isolation, "https://api.example.test/v1", 8);
    const shard_b = gateway.shard.hashFetch(isolation, "https://api.example.test/v2?x=1", 8);
    const shard_c = gateway.shard.hashFetch(other_cell, "https://api.example.test/v1", 8);
    const shard_d = gateway.shard.hashFetch(other_policy, "https://api.example.test/v1", 8);

    try std.testing.expect(shard_a < 8);
    try std.testing.expect(shard_c < 8);
    try std.testing.expect(shard_d < 8);
    try std.testing.expectEqual(shard_a, shard_b);
}

test "egress gateway route keys do not collide across worker sessions" {
    var routes: std.AutoHashMap(gateway.router.RouteKey, usize) = .init(std.testing.allocator);
    defer routes.deinit();

    const first = gateway.router.RouteKey{
        .worker_session_id = 1,
        .fetch_id = 7,
        .body_id = 9,
    };
    const second = gateway.router.RouteKey{
        .worker_session_id = 2,
        .fetch_id = 7,
        .body_id = 9,
    };

    try routes.put(first, 11);
    try routes.put(second, 22);

    try std.testing.expectEqual(@as(usize, 11), routes.get(first).?);
    try std.testing.expectEqual(@as(usize, 22), routes.get(second).?);
    try std.testing.expectEqual(@as(usize, 2), routes.count());
}

test "egress gateway body route lookup validates fetch id and keeps what admission decided" {
    var router = gateway.router.Router{};
    defer router.deinit(std.testing.allocator);

    const route_key = gateway.router.RouteKey{
        .worker_session_id = 1,
        .fetch_id = 7,
        .body_id = 9,
    };
    try router.record(std.testing.allocator, route_key, .{
        .shard_index = 2,
        .security_cell_id = [_]u8{3} ** 16,
        .policy_id = 5,
    });

    const route = router.routeForBody(1, 7, 9) orelse return error.MissingRoute;
    try std.testing.expect(router.routeForBody(1, 8, 9) == null);
    try std.testing.expect(router.routeForBody(2, 7, 9) == null);
    // A fetch resubmitted after its shard restarts runs under the cell and the policy entry
    // its token named at admission, which the route keeps.
    try std.testing.expectEqual(@as(usize, 2), route.record.shard_index);
    try std.testing.expectEqualSlices(u8, &([_]u8{3} ** 16), &route.record.security_cell_id);
    try std.testing.expectEqual(@as(u16, 5), route.record.policy_id);
}

test "egress gateway removes all worker routes in one pass" {
    const RemovedRoutes = struct {
        count: usize = 0,
        security_total: usize = 0,

        fn onRemove(self: *@This(), route: gateway.router.Route) void {
            self.count += 1;
            self.security_total += route.record.security_cell_id[0];
        }
    };

    var router = gateway.router.Router{};
    defer router.deinit(std.testing.allocator);

    const first = gateway.router.RouteKey{
        .worker_session_id = 1,
        .fetch_id = 10,
        .body_id = 20,
    };
    const second = gateway.router.RouteKey{
        .worker_session_id = 2,
        .fetch_id = 10,
        .body_id = 20,
    };
    const third = gateway.router.RouteKey{
        .worker_session_id = 1,
        .fetch_id = 11,
        .body_id = 21,
    };

    try router.record(std.testing.allocator, first, .{
        .shard_index = 0,
        .security_cell_id = [_]u8{3} ** 16,
        .policy_id = 0,
    });
    try router.record(std.testing.allocator, second, .{
        .shard_index = 1,
        .security_cell_id = [_]u8{7} ** 16,
        .policy_id = 0,
    });
    try router.record(std.testing.allocator, third, .{
        .shard_index = 0,
        .security_cell_id = [_]u8{5} ** 16,
        .policy_id = 0,
    });

    var removed = RemovedRoutes{};
    router.removeWorkerRoutes(
        std.testing.allocator,
        *RemovedRoutes,
        &removed,
        1,
        RemovedRoutes.onRemove,
    );

    try std.testing.expectEqual(@as(usize, 2), removed.count);
    try std.testing.expectEqual(@as(usize, 8), removed.security_total);
    try std.testing.expect(router.routeForKey(first) == null);
    try std.testing.expect(router.routeForFetch(1, 11) == null);
    try std.testing.expect(router.routeForBody(1, 11, 21) == null);
    try std.testing.expect(router.routeForKey(second) != null);
    try std.testing.expect(router.routeForFetch(2, 10) != null);
    try std.testing.expect(router.routeForBody(2, 10, 20) != null);
}

test "egress gateway removes many routes for one worker without touching others" {
    const RemovedRoutes = struct {
        count: usize = 0,

        fn onRemove(self: *@This(), route: gateway.router.Route) void {
            _ = route;
            self.count += 1;
        }
    };

    var router = gateway.router.Router{};
    defer router.deinit(std.testing.allocator);

    const route_count: usize = 2048;
    for (0..route_count) |index| {
        const id: u64 = @intCast(index + 1);
        try router.record(std.testing.allocator, .{
            .worker_session_id = 7,
            .fetch_id = id,
            .body_id = id + 10_000,
        }, .{
            .shard_index = index % 4,
            .security_cell_id = [_]u8{3} ** 16,
            .policy_id = 0,
        });
    }
    try router.record(std.testing.allocator, .{
        .worker_session_id = 8,
        .fetch_id = 1,
        .body_id = 1,
    }, .{
        .shard_index = 1,
        .security_cell_id = [_]u8{9} ** 16,
        .policy_id = 0,
    });

    var removed = RemovedRoutes{};
    router.removeWorkerRoutes(
        std.testing.allocator,
        *RemovedRoutes,
        &removed,
        7,
        RemovedRoutes.onRemove,
    );

    try std.testing.expectEqual(route_count, removed.count);
    try std.testing.expectEqual(@as(usize, 1), router.by_route.count());
    try std.testing.expect(router.routeForFetch(8, 1) != null);
}

test "egress gateway drop queue deduplicates and pops in fifo order" {
    var queue = gateway.drop_queue.Queue{};
    defer queue.deinit(std.testing.allocator);

    queue.mark(std.testing.allocator, 10);
    queue.mark(std.testing.allocator, 11);
    queue.mark(std.testing.allocator, 10);

    try std.testing.expectEqual(@as(usize, 2), queue.len());
    try std.testing.expectEqual(@as(?u64, 10), queue.next());
    try std.testing.expectEqual(@as(?u64, 11), queue.next());
    try std.testing.expectEqual(@as(?u64, null), queue.next());

    queue.mark(std.testing.allocator, 10);
    try std.testing.expectEqual(@as(?u64, 10), queue.next());
}

test "egress gateway drop queue records forced overflow instead of overwriting" {
    var queue = gateway.drop_queue.Queue{};
    defer queue.deinit(std.testing.allocator);

    // More sessions than the fixed ring holds (`forcedQueueCapacity`): the
    // extra ones are lost and recorded as an overflow.
    var worker_session_id: u64 = 1;
    while (worker_session_id <= 70) : (worker_session_id += 1)
        gateway.drop_queue.testing.pushForced(&queue, worker_session_id);

    var popped: usize = 0;
    while (queue.next()) |_|
        popped += 1;

    try std.testing.expectEqual(gateway.drop_queue.testing.forcedQueueCapacity, popped);
    try std.testing.expect(queue.takeForcedOverflow());
}

test "egress gateway invalid command budget is windowed not consecutive" {
    var window = gateway.sessions.InvalidCommandWindow{};
    const now_ns: u64 = 10 * std.time.ns_per_s;

    var count: u32 = 0;
    while (count < gateway.sessions.max_invalid_commands_per_window) : (count += 1)
        try std.testing.expect(window.record(now_ns));
    try std.testing.expect(!window.record(now_ns));

    try std.testing.expect(window.record(now_ns + gateway.sessions.invalid_command_window_ns));
}

test "egress gateway worker attach registry is transactional under allocation failure" {
    for (0..4) |fail_index| {
        var registry = gateway.worker_registry.Registry{};
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        defer registry.deinit(failing.allocator());

        var session_fds = try createSession();
        defer session_fds.deinit();

        var gateway_raw = try dupEgressRawFds(session_fds.rawForGateway());
        var endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
        var endpoint_owned = true;
        defer {
            if (endpoint_owned)
                endpoint.deinit();
        }

        const attached = registry.attachEndpoint(
            failing.allocator(),
            &endpoint,
            [_]u8{7} ** 16,
        );
        if (attached) |result| {
            endpoint_owned = false;
            try std.testing.expectEqual(@as(usize, 1), registry.len());
            try std.testing.expectEqual(result.index, registry.indexBySession(result.session_id).?);
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expectEqual(@as(usize, 0), registry.len());
            try std.testing.expect(registry.indexBySession(1) == null);
            try std.testing.expectEqual(@as(u64, 0), endpoint.command.workerSessionId());
            try std.testing.expectEqual(@as(u64, 0), endpoint.completion.workerSessionId());
            try std.testing.expectEqual(@as(u64, 0), endpoint.body_pool.workerSessionId());
            try endpoint.validateConsistentSession();
        }
    }
}

test "egress gateway readiness ring accounts for all worker polls" {
    const shard_count: usize = 8;
    const max_workers: usize = 256;
    const entries = gateway.readiness.recommendedEntryCount(shard_count, max_workers);

    // The control poll, a poll per shard and two per worker, plus the removal
    // headroom and the floor that `recommendedEntryCount` keeps.
    try std.testing.expect(entries >= 1 + shard_count + max_workers * 2 + 32);
    try std.testing.expect(entries >= 256);
}

/// A session on a wake set of its own. The session holds its own copy of
/// every wake descriptor, so the set closes once the session is built.
fn createSession() !ipc.egress_shared.SessionFds {
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    return ipc.egress_shared.createSessionForWorker(&wake_set);
}

fn dupEgressRawFds(fds: ipc.egress_shared.RawFds) !ipc.egress_shared.RawFds {
    var out = ipc.egress_shared.RawFds{};
    errdefer out.close();
    out.command_control_fd = try std.posix.dup(fds.command_control_fd);
    out.command_producer_fd = try std.posix.dup(fds.command_producer_fd);
    out.command_consumer_fd = try std.posix.dup(fds.command_consumer_fd);
    out.command_data_fd = try std.posix.dup(fds.command_data_fd);
    out.completion_control_fd = try std.posix.dup(fds.completion_control_fd);
    out.completion_producer_fd = try std.posix.dup(fds.completion_producer_fd);
    out.completion_consumer_fd = try std.posix.dup(fds.completion_consumer_fd);
    out.completion_data_fd = try std.posix.dup(fds.completion_data_fd);
    out.body_pool_control_fd = try std.posix.dup(fds.body_pool_control_fd);
    out.body_pool_producer_fd = try std.posix.dup(fds.body_pool_producer_fd);
    out.body_pool_consumer_fd = try std.posix.dup(fds.body_pool_consumer_fd);
    out.body_pool_data_fd = try std.posix.dup(fds.body_pool_data_fd);
    out.upload_pool_control_fd = try std.posix.dup(fds.upload_pool_control_fd);
    out.upload_pool_producer_fd = try std.posix.dup(fds.upload_pool_producer_fd);
    out.upload_pool_consumer_fd = try std.posix.dup(fds.upload_pool_consumer_fd);
    out.upload_pool_data_fd = try std.posix.dup(fds.upload_pool_data_fd);
    out.command_eventfd = try std.posix.dup(fds.command_eventfd);
    out.completion_eventfd = try std.posix.dup(fds.completion_eventfd);
    out.liveness_fd = try std.posix.dup(fds.liveness_fd);
    out.peer_liveness_fd = try std.posix.dup(fds.peer_liveness_fd);
    return out;
}

test "egress gateway worker backpressure uses hysteresis" {
    const empty = ipc.egress_shared.Usage{ .used = 0, .capacity = 100 };
    const reduce = ipc.egress_shared.Usage{ .used = 60, .capacity = 100 };
    const reduce_recover = ipc.egress_shared.Usage{ .used = 50, .capacity = 100 };
    const pause = ipc.egress_shared.Usage{ .used = 75, .capacity = 100 };
    const pause_recover = ipc.egress_shared.Usage{ .used = 60, .capacity = 100 };
    const hard = ipc.egress_shared.Usage{ .used = 95, .capacity = 100 };

    try std.testing.expectEqual(
        gateway.backpressure.Level.normal,
        gateway.backpressure.computeForTest(.normal, empty, empty),
    );
    try std.testing.expectEqual(
        gateway.backpressure.Level.reduced_chunks,
        gateway.backpressure.computeForTest(.normal, empty, reduce),
    );
    try std.testing.expectEqual(
        gateway.backpressure.Level.reduced_chunks,
        gateway.backpressure.computeForTest(.reduced_chunks, empty, reduce_recover),
    );
    try std.testing.expectEqual(
        gateway.backpressure.Level.paused,
        gateway.backpressure.computeForTest(.normal, pause, empty),
    );
    try std.testing.expectEqual(
        gateway.backpressure.Level.paused,
        gateway.backpressure.computeForTest(.paused, pause_recover, empty),
    );
    // Only the completion ring escalates to hard; a full body pool pauses
    // instead (`backpressure.compute` gives the reason).
    try std.testing.expectEqual(
        gateway.backpressure.Level.hard,
        gateway.backpressure.computeForTest(.paused, hard, empty),
    );
    try std.testing.expectEqual(
        gateway.backpressure.Level.paused,
        gateway.backpressure.computeForTest(.paused, empty, hard),
    );
    try std.testing.expectEqual(
        gateway.backpressure.Level.paused,
        gateway.backpressure.computeForTest(.normal, empty, hard),
    );
}
