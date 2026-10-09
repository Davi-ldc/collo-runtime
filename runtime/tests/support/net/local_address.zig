//! The test-network fixture, module `collo_test_net`: an IPv4 address of this
//! host that the egress client agrees to connect to. The egress policy refuses
//! loopback, so a test that serves an origin on this host has the client dial
//! the source address the kernel picks for the default route. A host without
//! such an address skips the test instead of failing it. The fixture imports
//! `collo_egress_client`, so `runtime/build/tests.zig` builds one instance per
//! bindings flavor. It keeps no state and runs on the calling test's thread.

const std = @import("std");

const transport = @import("collo_egress_client").transport;

// A public address, so the probe follows the default route.
const route_probe_ipv4 = "1.1.1.1";
const route_probe_port: u16 = 9;

/// Writes the address into `out` in dotted decimal and returns that slice.
/// Fails with `error.SkipZigTest` when the host has no IPv4 default route, or
/// when its source address is one the egress policy refuses even with private
/// networks allowed, such as link-local or shared carrier space.
pub fn routableLocalIpv4(out: *[64]u8) ![]const u8 {
    const address = try defaultRouteSourceAddress();
    (transport.EgressPolicy{ .allow_private_networks = true }).validateResolvedAddress(address) catch {
        return error.SkipZigTest;
    };

    const bytes = transport.ipv4Bytes(address);
    return std.fmt.bufPrint(
        out,
        "{d}.{d}.{d}.{d}",
        .{ bytes[0], bytes[1], bytes[2], bytes[3] },
    ) catch return error.SkipZigTest;
}

fn defaultRouteSourceAddress() !std.net.Address {
    const remote = std.net.Address.parseIp4(route_probe_ipv4, route_probe_port) catch {
        return error.SkipZigTest;
    };
    const socket = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch return error.SkipZigTest;
    defer std.posix.close(socket);

    // Connecting a UDP socket sends no packet. It only makes the kernel choose
    // the route and the source address a real connection would use.
    std.posix.connect(socket, &remote.any, remote.getOsSockLen()) catch {
        return error.SkipZigTest;
    };

    var storage: std.posix.sockaddr.storage = undefined;
    var storage_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getsockname(socket, @ptrCast(&storage), &storage_len) catch {
        return error.SkipZigTest;
    };

    if (storage.family != std.posix.AF.INET) {
        return error.SkipZigTest;
    }

    const socket_address: *align(4) const std.posix.sockaddr = @ptrCast(&storage);
    return std.net.Address.initPosix(socket_address);
}
