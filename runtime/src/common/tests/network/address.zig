//! The address classes of `collo_network` (`common/network/address.zig`):
//! the class of every special-purpose range, the documented cloud
//! host-service addresses, IPv4-mapped addresses and the IPv6 space outside
//! global unicast, and which classes a fetch may ever reach. The
//! transport's check of resolved addresses with these classes is covered in
//! `egress/tests/client/policy.zig`.

const std = @import("std");
const network = @import("collo_network");

const address = network.address;
const AddressClass = network.AddressClass;

const Case = struct {
    text: []const u8,
    class: AddressClass,
};

fn expectClasses(cases: []const Case, comptime parse: fn ([]const u8, u16) anyerror!std.net.Address) !void {
    for (cases) |case| {
        const parsed = try parse(case.text, 443);
        const class = address.classify(parsed);
        if (class != case.class)
            std.debug.print("{s} classified as {s}\n", .{ case.text, @tagName(class) });
        try std.testing.expectEqual(case.class, class);
    }
}

fn parseIpv4(text: []const u8, port: u16) anyerror!std.net.Address {
    return std.net.Address.parseIp4(text, port);
}

fn parseIpv6(text: []const u8, port: u16) anyerror!std.net.Address {
    return std.net.Address.parseIp6(text, port);
}

test "every special-purpose IPv4 range has its class" {
    const cases = [_]Case{
        .{ .text = "0.0.0.0", .class = .unspecified },
        .{ .text = "0.1.2.3", .class = .unspecified },
        .{ .text = "10.0.0.1", .class = .private_routable },
        .{ .text = "10.255.255.255", .class = .private_routable },
        .{ .text = "100.64.0.1", .class = .shared_carrier },
        .{ .text = "100.127.255.255", .class = .shared_carrier },
        .{ .text = "100.128.0.1", .class = .public },
        .{ .text = "127.0.0.1", .class = .loopback },
        .{ .text = "127.255.0.1", .class = .loopback },
        .{ .text = "169.254.169.254", .class = .metadata },
        .{ .text = "169.254.0.1", .class = .metadata },
        .{ .text = "172.16.0.1", .class = .private_routable },
        .{ .text = "172.31.255.255", .class = .private_routable },
        .{ .text = "172.32.0.1", .class = .public },
        .{ .text = "192.0.0.1", .class = .reserved },
        .{ .text = "192.0.0.255", .class = .reserved },
        .{ .text = "192.0.1.1", .class = .public },
        .{ .text = "192.0.2.1", .class = .documentation },
        .{ .text = "192.0.3.1", .class = .public },
        .{ .text = "192.88.99.1", .class = .reserved },
        .{ .text = "192.168.1.1", .class = .private_routable },
        .{ .text = "198.18.0.1", .class = .benchmark },
        .{ .text = "198.19.255.255", .class = .benchmark },
        .{ .text = "198.51.100.1", .class = .documentation },
        .{ .text = "203.0.113.1", .class = .documentation },
        .{ .text = "224.0.0.1", .class = .multicast },
        .{ .text = "239.255.255.255", .class = .multicast },
        .{ .text = "240.0.0.1", .class = .reserved },
        .{ .text = "255.255.255.255", .class = .broadcast },
        .{ .text = "1.1.1.1", .class = .public },
        .{ .text = "93.184.216.34", .class = .public },
    };
    try expectClasses(&cases, parseIpv4);
}

test "every special-purpose IPv6 range has its class, and a mapped address takes its IPv4 class" {
    const cases = [_]Case{
        .{ .text = "::", .class = .unspecified },
        .{ .text = "::1", .class = .loopback },
        .{ .text = "fc00::1", .class = .private_routable },
        .{ .text = "fd00::1", .class = .private_routable },
        .{ .text = "fe80::1", .class = .link_local },
        .{ .text = "febf::1", .class = .link_local },
        .{ .text = "ff02::fb", .class = .multicast },
        .{ .text = "::ffff:127.0.0.1", .class = .loopback },
        .{ .text = "::ffff:10.0.0.1", .class = .private_routable },
        .{ .text = "::ffff:169.254.169.254", .class = .metadata },
        .{ .text = "::ffff:93.184.216.34", .class = .public },
        .{ .text = "64:ff9b::7f00:1", .class = .reserved },
        .{ .text = "64:ff9b::5db8:d822", .class = .reserved },
        .{ .text = "64:ff9b:1::7f00:1", .class = .reserved },
        .{ .text = "100::1", .class = .reserved },
        .{ .text = "2001::1", .class = .reserved },
        .{ .text = "2001:2::1", .class = .benchmark },
        .{ .text = "2001:db8::1", .class = .documentation },
        .{ .text = "2002::1", .class = .reserved },
        .{ .text = "3fff::1", .class = .documentation },
        .{ .text = "3fff:fff:ffff::1", .class = .documentation },
        .{ .text = "3fff:1000::1", .class = .public },
        .{ .text = "2606:2800:220:1:248:1893:25c8:1946", .class = .public },
        .{ .text = "2606:4700::1111", .class = .public },
    };
    try expectClasses(&cases, parseIpv6);
}

test "IPv6 outside global unicast is reserved, so no embedded IPv4 address escapes its class" {
    const cases = [_]Case{
        // IPv4-compatible ::/96 with loopback, metadata and public payloads.
        .{ .text = "::7f00:1", .class = .reserved },
        .{ .text = "::a9fe:a9fe", .class = .reserved },
        .{ .text = "::5db8:d822", .class = .reserved },
        // IPv4-translated ::ffff:0:0:0/96.
        .{ .text = "::ffff:0:7f00:1", .class = .reserved },
        .{ .text = "::ffff:0:a9fe:a9fe", .class = .reserved },
        // Deprecated site-local fec0::/10, segment routing 5f00::/16 and
        // unassigned space on both sides of 2000::/3.
        .{ .text = "fec0::1", .class = .reserved },
        .{ .text = "5f00::1", .class = .reserved },
        .{ .text = "1fff::1", .class = .reserved },
        .{ .text = "4000::1", .class = .reserved },
        .{ .text = "2000::1", .class = .public },
    };
    try expectClasses(&cases, parseIpv6);
}

test "every documented cloud host-service address is metadata, and the addresses beside it keep their class" {
    const ipv6_cases = [_]Case{
        // AWS instance metadata, Route 53 Resolver and Time Sync.
        .{ .text = "fd00:ec2::254", .class = .metadata },
        .{ .text = "fd00:ec2::253", .class = .metadata },
        .{ .text = "fd00:ec2::123", .class = .metadata },
        .{ .text = "fd00:ec2::1", .class = .private_routable },
        // Google Cloud, inside the fd20::/20 range its VPC networks use.
        .{ .text = "fd20:ce::254", .class = .metadata },
        .{ .text = "fd20:ce::253", .class = .private_routable },
        // Akamai Linode.
        .{ .text = "fd00:a9fe:a9fe::1", .class = .metadata },
        // Scaleway.
        .{ .text = "fd00:42::42", .class = .metadata },
        // The link-local metadata address of OpenStack and Linode.
        .{ .text = "fe80::a9fe:a9fe", .class = .link_local },
        // Each one mapped into IPv4 space keeps the IPv4 class.
        .{ .text = "::ffff:169.254.169.254", .class = .metadata },
        .{ .text = "::ffff:168.63.129.16", .class = .metadata },
    };
    try expectClasses(&ipv6_cases, parseIpv6);

    const ipv4_cases = [_]Case{
        // Azure's WireServer, in public space.
        .{ .text = "168.63.129.16", .class = .metadata },
        .{ .text = "168.63.129.17", .class = .public },
        // Oracle's legacy metadata address, inside 192.0.0.0/24.
        .{ .text = "192.0.0.192", .class = .reserved },
        // Alibaba Cloud's metadata service, inside shared carrier space.
        .{ .text = "100.100.100.200", .class = .shared_carrier },
    };
    try expectClasses(&ipv4_cases, parseIpv4);
}

test "192.0.0.0/24 alone is reserved: the rest of 192.0.0.0/16 is public" {
    const cases = [_]Case{
        // Automattic's 192.0.64.0/18 and IANA's 192.0.32.0/20.
        .{ .text = "192.0.78.9", .class = .public },
        .{ .text = "192.0.32.8", .class = .public },
        .{ .text = "192.0.255.255", .class = .public },
        .{ .text = "192.0.0.0", .class = .reserved },
    };
    try expectClasses(&cases, parseIpv4);
}

test "a fetch may reach a public address always, a private one only when allowed, and nothing else" {
    for (std.enums.values(AddressClass)) |class| {
        try std.testing.expectEqual(class == .public, address.permitted(class, false));
        const reachable_with_private = class == .public or class == .private_routable;
        try std.testing.expectEqual(reachable_with_private, address.permitted(class, true));
    }
}

test "an address of another family is never reachable" {
    const unix = try std.net.Address.initUnix("/tmp/collo-network-test.sock");
    try std.testing.expectEqual(AddressClass.unknown, address.classify(unix));
    try std.testing.expect(!address.permitted(address.classify(unix), true));
}

test "IPv4 bytes come out in network order" {
    const parsed = try std.net.Address.parseIp4("1.2.3.4", 443);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, address.ipv4Bytes(parsed));
}
