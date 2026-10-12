//! What the egress benchmarks need to reach origins they start on this
//! host: the address to dial and a `network` policy that names them. Every
//! grant refuses loopback, so an origin listening on every address is dialed
//! at the source address the kernel picks for the default route, as
//! `runtime/tests/support/net/local_address.zig` does for the tests, and the
//! policy names that address on each origin's port with both flags, as a
//! configuration entry `<address>:<port>` with `allowHttp` and
//! `allowPrivateNetworks` does. The transport then checks every hop as it
//! does in the gateway.

const std = @import("std");
const network = @import("collo_network");

/// Origins one policy names; `egress_h2_engine` starts at most this many per
/// engine.
pub const origins_max: usize = 32;

/// A public address, so the probe follows the default route.
const route_probe_ipv4 = "1.1.1.1";
const route_probe_port: u16 = 9;

/// The default route's source address. Fails with
/// `error.BenchNoRoutableLocalAddress` when the host has no IPv4 default
/// route, or when that address is of a class no grant reaches even with
/// private networks allowed, such as link-local or shared carrier space.
pub fn routableLocalIpv4() ![4]u8 {
    const remote = try std.net.Address.parseIp4(route_probe_ipv4, route_probe_port);
    const socket = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    defer std.posix.close(socket);
    // Connecting a UDP socket sends no packet; it only makes the kernel
    // choose the route and the source address a real connection would use.
    try std.posix.connect(socket, &remote.any, remote.getOsSockLen());

    var storage: std.posix.sockaddr.storage = undefined;
    var storage_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(socket, @ptrCast(&storage), &storage_len);
    if (storage.family != std.posix.AF.INET)
        return error.BenchNoRoutableLocalAddress;
    const socket_address: *align(4) const std.posix.sockaddr = @ptrCast(&storage);
    const address = std.net.Address.initPosix(socket_address);
    if (!network.address.permitted(network.address.classify(address), true))
        return error.BenchNoRoutableLocalAddress;
    return network.address.ipv4Bytes(address);
}

/// `address` in dotted decimal, written into `out`.
pub fn formatIpv4(address: [4]u8, out: *[15]u8) []const u8 {
    // Four parts of at most three digits and three dots fill `out` at most.
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ address[0], address[1], address[2], address[3] }) catch
        unreachable;
}

/// The policy of one grant naming `address` on each port given to `init`.
/// It points into itself: initialize it in place and keep it there while a
/// fetch runs under `policy()`.
pub const LocalGrant = struct {
    rules: [origins_max]network.Pattern,
    grant: network.Grant,
    members: [1]*const network.Grant,

    pub fn init(self: *LocalGrant, address: [4]u8, ports: []const u16) error{TooManyOrigins}!void {
        if (ports.len > origins_max)
            return error.TooManyOrigins;
        for (ports, 0..) |port, index|
            self.rules[index] = .{ .host = .{ .ipv4 = address }, .port = port };
        // A grant's rules are in canonical order, which its lookups search.
        std.mem.sort(network.Pattern, self.rules[0..ports.len], {}, patternLessThan);
        self.grant = .{
            .allow_http = true,
            .allow_private_networks = true,
            .any = false,
            .names = &.{},
            .suffixes = &.{},
            .ipv4 = self.rules[0..ports.len],
            .ipv6 = &.{},
        };
        self.members = .{&self.grant};
    }

    pub fn policy(self: *const LocalGrant) network.Policy {
        return .{ .grants = &self.members };
    }
};

fn patternLessThan(context: void, left: network.Pattern, right: network.Pattern) bool {
    _ = context;
    return left.order(right) == .lt;
}
