//! The ingress listeners (`server/net/listener.zig`): port 0 resolved once
//! and shared by every lane, the bound address reported with that port, and
//! SO_REUSEPORT required only when there is more than one lane. Lane
//! `server-core-test`; accepting on the listeners is covered by
//! `server-ingress-test`.

const std = @import("std");
const listener = @import("collo_server_main").listener;

const loopback_any_port = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);

test "ingress listeners bind port zero then reuse concrete port" {
    var listeners_group = try listener.IngressListeners.init(std.testing.allocator, .{
        .address = loopback_any_port,
        .lane_count = 2,
        .backlog = 16,
    });
    defer listeners_group.deinit();
    const listeners = listeners_group.asSlice();

    const port = listeners[0].listen_address.getPort();
    try std.testing.expect(port != 0);
    try std.testing.expectEqual(port, listeners[1].listen_address.getPort());
}

test "the bound address carries the kernel-chosen port" {
    var listeners_group = try listener.IngressListeners.init(std.testing.allocator, .{
        .address = loopback_any_port,
        .lane_count = 1,
        .backlog = 16,
    });
    defer listeners_group.deinit();

    const bound = listeners_group.address();
    try std.testing.expect(bound.getPort() != 0);
    try std.testing.expectEqual(listeners_group.asSlice()[0].listen_address.getPort(), listeners_group.port());
    var expected = loopback_any_port;
    expected.setPort(bound.getPort());
    try std.testing.expect(expected.eql(bound));
}

test "single ingress lane tolerates reuseport unavailable" {
    var listeners_group = try listener.IngressListeners.init(std.testing.allocator, .{
        .address = loopback_any_port,
        .lane_count = 1,
        .backlog = 16,
        .force_reuseport_unavailable = true,
    });
    defer listeners_group.deinit();
    const listeners = listeners_group.asSlice();
    try std.testing.expect(listeners[0].listen_address.getPort() != 0);
}

test "multi lane ingress listeners require reuseport" {
    try std.testing.expectError(error.ReusePortUnavailable, listener.IngressListeners.init(std.testing.allocator, .{
        .address = loopback_any_port,
        .lane_count = 2,
        .backlog = 16,
        .force_reuseport_unavailable = true,
    }));
}
