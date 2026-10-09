//! A lane's accept boundary: the multishot accept registration
//! (`ingress/uring.zig`) through more-flagged, final, stale and EMFILE
//! completions and the backoff that keeps it from spinning, the accept
//! user_data packing, an accepted socket closed when the header buffers or
//! the connection slab run out (`ingress/accept.zig`), and lane listeners
//! that share one port. A completion naming an external request id that
//! another lane reuses changes only the lane and slot it names. Lane
//! `server-ingress-test`; the listeners alone are covered in
//! `tests/net/listener.zig`.

const std = @import("std");
const fd_helpers = @import("collo_os").fd;
const server_main = @import("collo_server_main");
const worker_shared_page = @import("collo_worker_state").page;

const ingress = server_main.ingress;
const lifecycle = server_main.lifecycle;

const loopback_any_port = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);

test "ingress listeners bind multiple lane sockets to one port" {
    var listeners_group = try server_main.listener.IngressListeners.init(std.testing.allocator, .{
        .address = loopback_any_port,
        .lane_count = 2,
        .backlog = 16,
    });
    defer listeners_group.deinit();
    const listeners = listeners_group.asSlice();
    try std.testing.expect(listeners[0].listen_address.getPort() != 0);
    try std.testing.expectEqual(listeners[0].listen_address.getPort(), listeners[1].listen_address.getPort());
}

test "multishot accept registration handles more final stale and EMFILE" {
    var registration = ingress.uring.AcceptRegistration{};
    const generation = registration.arm();
    var counters = ingress.uring.Counters{};
    try std.testing.expect(std.meta.activeTag(ingress.uring.handleAcceptCompletion(&registration, .{ .generation = generation, .res = 7, .flags = ingress.uring.cqe_f_more }, 0, 10, &counters)) == .accepted);
    try std.testing.expectEqual(ingress.uring.AcceptState.active, registration.state);
    try std.testing.expect(std.meta.activeTag(ingress.uring.handleAcceptCompletion(&registration, .{ .generation = 99, .res = 7, .flags = 0 }, 0, 10, &counters)) == .ignored_stale);
    try std.testing.expect(std.meta.activeTag(ingress.uring.handleAcceptCompletion(&registration, .{ .generation = generation, .res = -@as(i32, @intFromEnum(std.os.linux.E.MFILE)), .flags = 0 }, 0, 10, &counters)) == .backoff);
}

test "ingress accept user_data carries lane and generation" {
    const encoded = try ingress.uring.packAcceptUserData(7, 42);
    const decoded = try ingress.uring.unpackAcceptUserData(encoded);
    try std.testing.expectEqual(@as(u16, 7), decoded.lane_id);
    try std.testing.expectEqual(@as(u64, 42), decoded.generation);
    try std.testing.expectError(error.InvalidUserDataTag, ingress.uring.unpackAcceptUserData(0));
}

test "port zero multi lane shares concrete listener port" {
    var listeners_group = try server_main.listener.IngressListeners.init(std.testing.allocator, .{ .address = loopback_any_port, .lane_count = 2, .backlog = 16 });
    defer listeners_group.deinit();
    const listeners = listeners_group.asSlice();
    try std.testing.expectEqual(listeners[0].listen_address.getPort(), listeners[1].listen_address.getPort());
}

test "port zero first bind is replicated to remaining lane listeners" {
    var listeners_group = try server_main.listener.IngressListeners.init(std.testing.allocator, .{ .address = loopback_any_port, .lane_count = 3, .backlog = 16 });
    defer listeners_group.deinit();
    const listeners = listeners_group.asSlice();
    const port = listeners[0].listen_address.getPort();
    try std.testing.expect(port != 0);
    try std.testing.expectEqual(port, listeners[2].listen_address.getPort());
}

test "multi lane requires reuseport" {
    try std.testing.expectError(error.ReusePortUnavailable, server_main.listener.IngressListeners.init(std.testing.allocator, .{ .address = loopback_any_port, .lane_count = 2, .force_reuseport_unavailable = true }));
}

test "multishot accept more flag keeps registration active and does not rearm" {
    var registration = ingress.uring.AcceptRegistration{};
    const generation = registration.arm();
    var counters = ingress.uring.Counters{};
    _ = ingress.uring.handleAcceptCompletion(&registration, .{ .generation = generation, .res = 7, .flags = ingress.uring.cqe_f_more }, 0, 1, &counters);
    try std.testing.expectEqual(ingress.uring.AcceptState.active, registration.state);
    try std.testing.expectEqual(@as(u64, 0), counters.multishot_terminal_rearms);
}

test "multishot accept final cqe re-arms exactly once" {
    var registration = ingress.uring.AcceptRegistration{};
    const generation = registration.arm();
    var counters = ingress.uring.Counters{};
    _ = ingress.uring.handleAcceptCompletion(&registration, .{ .generation = generation, .res = 7, .flags = 0 }, 0, 1, &counters);
    try std.testing.expectEqual(ingress.uring.AcceptState.inactive, registration.state);
    try std.testing.expectEqual(@as(u64, 1), counters.multishot_terminal_rearms);
}

test "accept transient backoff cannot busy loop" {
    var registration = ingress.uring.AcceptRegistration{};
    const generation = registration.arm();
    var counters = ingress.uring.Counters{};
    _ = ingress.uring.handleAcceptCompletion(&registration, .{ .generation = generation, .res = -@as(i32, @intFromEnum(std.os.linux.E.MFILE)), .flags = 0 }, 10, 5, &counters);
    try std.testing.expectEqual(ingress.uring.AcceptState.backoff, registration.state);
    try std.testing.expect(!registration.finishBackoff(14));
    try std.testing.expect(registration.finishBackoff(15));
    try std.testing.expectEqual(ingress.uring.AcceptState.inactive, registration.state);
}

test "accepted fd is closed on header buffer exhaustion" {
    const pair = try fd_helpers.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .max_connections = 1, .max_requests = 1 }, 0);
    defer lane.deinit();
    ingress.accept.closeRejectedAcceptedFd(pair[0], &lane.counters, .header_buffer_exhaustion);
    var scratch: [1]u8 = undefined;
    const read_len = try std.posix.read(pair[1], &scratch);
    try std.testing.expectEqual(@as(usize, 0), read_len);
    try std.testing.expectEqual(@as(u64, 1), lane.counters.silent_queue_overflows);
    try std.testing.expectEqual(@as(u64, 1), lane.counters.accepted_header_buffer_exhaustion);
}

test "accepted fd is closed on connection slab exhaustion" {
    const pair = try fd_helpers.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    var slab_counters = ingress.state.SlabCounters{};
    var slab = try ingress.state.ConnectionSlab.init(std.testing.allocator, 0, 1, &slab_counters);
    defer slab.deinit();
    const occupied = try slab.alloc(.{});
    _ = occupied;
    try std.testing.expectError(error.ConnectionSlabFull, slab.alloc(fd_helpers.OwnedFd.fromRaw(pair[0])));
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .max_connections = 1, .max_requests = 1 }, 0);
    defer lane.deinit();
    ingress.accept.closeRejectedAcceptedFd(pair[0], &lane.counters, .connection_slab_exhaustion);
    var scratch: [1]u8 = undefined;
    const read_len = try std.posix.read(pair[1], &scratch);
    try std.testing.expectEqual(@as(usize, 0), read_len);
    try std.testing.expectEqual(@as(u64, 1), lane.counters.accepted_connection_slab_exhaustion);
}

test "negative accept cqe with more flag keeps active state" {
    var registration = ingress.uring.AcceptRegistration{};
    const generation = registration.arm();
    var counters = ingress.uring.Counters{};
    _ = ingress.uring.handleAcceptCompletion(&registration, .{ .generation = generation, .res = -@as(i32, @intFromEnum(std.os.linux.E.AGAIN)), .flags = ingress.uring.cqe_f_more }, 0, 1, &counters);
    try std.testing.expectEqual(ingress.uring.AcceptState.active, registration.state);
}

test "concurrent clients across lanes cannot complete each other's requests when external request ids are reused" {
    var lane0 = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .lane_id = 0, .max_connections = 1, .max_requests = 1 }, 0);
    defer lane0.deinit();
    var lane1 = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .lane_id = 1, .max_connections = 1, .max_requests = 1 }, 0);
    defer lane1.deinit();

    const conn0 = try lane0.allocateAcceptedConnection(.{});
    const conn1 = try lane1.allocateAcceptedConnection(.{});
    const worker0 = lifecycle.WorkerKey{ .worker_id = 10, .worker_generation = 1 };
    const worker1 = lifecycle.WorkerKey{ .worker_id = 11, .worker_generation = 1 };
    const req0 = try lane0.state.requests.alloc(77, conn0, worker0, 0, 10);
    const req1 = try lane1.state.requests.alloc(77, conn1, worker1, 0, 10);

    const completion0 = worker_shared_page.WorkerCompletionRecord{
        .sequence = 1,
        .external_request_id = 77,
        .request_generation = req0.generation,
        .worker_id = worker0.worker_id,
        .worker_generation = worker0.worker_generation,
        .request_slot = req0.slot,
        .request_lane_id = req0.lane_id,
        .http_status = 200,
        .status = 0,
    };
    const completion1 = worker_shared_page.WorkerCompletionRecord{
        .sequence = 1,
        .external_request_id = 77,
        .request_generation = req1.generation,
        .worker_id = worker1.worker_id,
        .worker_generation = worker1.worker_generation,
        .request_slot = req1.slot,
        .request_lane_id = req1.lane_id,
        .http_status = 200,
        .status = 0,
    };

    try std.testing.expect(!lane1.applySharedCompletionRecord(completion0));
    try std.testing.expectEqual(ingress.state.RequestTerminalState.active, lane1.state.requests.lookup(req1).live.terminal);
    try std.testing.expect(lane0.applySharedCompletionRecord(completion0));
    try std.testing.expect(lane1.applySharedCompletionRecord(completion1));
    try std.testing.expectEqual(ingress.state.RequestTerminalState.completed_by_worker, lane0.state.requests.lookup(req0).live.terminal);
    try std.testing.expectEqual(ingress.state.RequestTerminalState.completed_by_worker, lane1.state.requests.lookup(req1).live.terminal);
}
