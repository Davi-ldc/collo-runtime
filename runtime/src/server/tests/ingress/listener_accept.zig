//! A lane's accept boundary: the multishot accept registration
//! (`ingress/uring.zig`) through more-flagged, final, stale and EMFILE
//! completions and the backoff that keeps it from spinning, the accept
//! user_data packing, an accepted socket closed when the connection slab
//! runs out (`ingress/accept.zig`), and lane listeners that share one port.
//! Lane `server-ingress-test`; the listeners alone are covered in
//! `tests/net/listener.zig`.

const std = @import("std");
const fd_helpers = @import("collo_os").fd;
const server_main = @import("collo_server_main");

const ingress = server_main.ingress;

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

test "accepted fd is closed on connection slab exhaustion" {
    const pair = try fd_helpers.socketPairType(std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[1]);
    var slab = try ingress.runner.connection_slot.ConnectionSlab.init(1);
    defer slab.deinit();
    _ = slab.acquire() orelse return error.SlabRefusedItsFirstEntry;
    try std.testing.expect(slab.acquire() == null);
    var lane = try ingress.lane.IngressLane.init(std.testing.allocator, .{ .max_requests = 1 }, 0);
    defer lane.deinit();
    ingress.accept.closeRejectedAcceptedFd(pair[0], &lane.counters, .connection_slab_exhaustion);
    var scratch: [1]u8 = undefined;
    const read_len = try std.posix.read(pair[1], &scratch);
    try std.testing.expectEqual(@as(usize, 0), read_len);
    try std.testing.expectEqual(@as(u64, 1), lane.counters.silent_queue_overflows);
    try std.testing.expectEqual(@as(u64, 1), lane.counters.accepted_connection_slab_exhaustion);
}

test "negative accept cqe with more flag keeps active state" {
    var registration = ingress.uring.AcceptRegistration{};
    const generation = registration.arm();
    var counters = ingress.uring.Counters{};
    _ = ingress.uring.handleAcceptCompletion(&registration, .{ .generation = generation, .res = -@as(i32, @intFromEnum(std.os.linux.E.AGAIN)), .flags = ingress.uring.cqe_f_more }, 0, 1, &counters);
    try std.testing.expectEqual(ingress.uring.AcceptState.active, registration.state);
}
