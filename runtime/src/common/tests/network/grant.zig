//! Matching hops against grants and policies (`common/network/grant.zig`):
//! names, suffixes and addresses, `*` and ports, plain HTTP, the union of
//! several grants, private and reserved addresses before and after DNS,
//! policy 0 and the constant policies, and the denial text. Every table here
//! goes through the builder and the decoder first (`support.Fixture`).

const std = @import("std");
const network = @import("collo_network");
const support = @import("support.zig");

const decide = support.decide;
const expectAdmitted = support.expectAdmitted;
const expectDenied = support.expectDenied;
const gpa = std.testing.allocator;

test "a name admits itself in any spelling and nothing else" {
    var fixture = try support.Fixture.init(gpa, &.{.{ .allow = &.{"api.example.com"} }});
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectAdmitted(try decide(policy, .https, "api.example.com", null), false);
    try expectAdmitted(try decide(policy, .https, "API.Example.COM.", 443), false);
    try expectDenied(try decide(policy, .https, "evil.example.com", null), .host_not_allowed);
    try expectDenied(try decide(policy, .https, "example.com", null), .host_not_allowed);
    try expectDenied(try decide(policy, .https, "a.api.example.com", null), .host_not_allowed);
}

test "a suffix admits deeper names and never the name itself" {
    var fixture = try support.Fixture.init(gpa, &.{.{ .allow = &.{"*.example.com"} }});
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectAdmitted(try decide(policy, .https, "a.example.com", null), false);
    try expectAdmitted(try decide(policy, .https, "a.b.example.com", null), false);
    try expectDenied(try decide(policy, .https, "example.com", null), .host_not_allowed);
    try expectDenied(try decide(policy, .https, "badexample.com", null), .host_not_allowed);
    try expectDenied(try decide(policy, .https, "example.com.evil.net", null), .host_not_allowed);
}

test "an address entry matches its bytes in any spelling" {
    var fixture = try support.Fixture.init(gpa, &.{.{ .allow = &.{ "93.184.216.34", "[2606:4700::1111]" } }});
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectAdmitted(try decide(policy, .https, "93.184.216.34", null), false);
    try expectAdmitted(try decide(policy, .https, "[2606:4700:0:0:0:0:0:1111]", null), false);
    try expectAdmitted(try decide(policy, .https, "[2606:4700::1111]", 443), false);
    try expectDenied(try decide(policy, .https, "93.184.216.35", null), .host_not_allowed);
    try expectDenied(try decide(policy, .https, "[2606:4700::1112]", null), .host_not_allowed);
}

test "\"*\" admits public names and addresses on default ports, and never a private address" {
    var fixture = try support.Fixture.init(gpa, &.{.{ .allow = &.{"*"}, .allow_http = true }});
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectAdmitted(try decide(policy, .https, "api.example.com", null), false);
    try expectAdmitted(try decide(policy, .http, "api.example.com", 80), false);
    try expectAdmitted(try decide(policy, .https, "93.184.216.34", null), false);
    try expectDenied(try decide(policy, .https, "api.example.com", 8443), .port_not_allowed);
    try expectDenied(try decide(policy, .http, "api.example.com", 443), .port_not_allowed);
    try expectDenied(try decide(policy, .https, "10.0.0.1", null), .private_address);
    try expectDenied(try decide(policy, .https, "[fd00::1]", null), .private_address);

    // A name admitted by "*" that resolves to a private address is refused
    // after DNS.
    const admission: network.Admission = .{ .allow_private_networks = false };
    try std.testing.expectEqual(
        @as(?network.Denial, .private_address),
        network.admitAddress(admission, try std.net.Address.parseIp4("10.0.0.1", 443)),
    );
}

test "\"*\" beside an entry under allowPrivateNetworks lends that flag to nothing else" {
    var fixture = try support.Fixture.init(gpa, &.{.{
        .allow = &.{ "*", "internal.example" },
        .allow_private_networks = true,
    }});
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectAdmitted(try decide(policy, .https, "api.example.com", null), false);
    try expectAdmitted(try decide(policy, .https, "internal.example", null), true);
    try expectDenied(try decide(policy, .https, "10.0.0.1", null), .private_address);
}

test "an entry with a port admits only that port, for every scheme its setting allows" {
    var fixture = try support.Fixture.init(gpa, &.{.{ .allow = &.{"api.example.com:8443"}, .allow_http = true }});
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectAdmitted(try decide(policy, .https, "api.example.com", 8443), false);
    try expectAdmitted(try decide(policy, .http, "api.example.com", 8443), false);
    try expectDenied(try decide(policy, .https, "api.example.com", null), .port_not_allowed);
    try expectDenied(try decide(policy, .http, "api.example.com", null), .port_not_allowed);

    var explicit = try support.Fixture.init(gpa, &.{.{ .allow = &.{"api.example.com:443"}, .allow_http = true }});
    defer explicit.deinit(gpa);
    try expectAdmitted(try decide(explicit.policy(), .http, "api.example.com", 443), false);
    try expectDenied(try decide(explicit.policy(), .http, "api.example.com", null), .port_not_allowed);
}

test "an entry without a port admits the default port of each scheme" {
    var fixture = try support.Fixture.init(gpa, &.{.{ .allow = &.{"api.example.com"}, .allow_http = true }});
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectAdmitted(try decide(policy, .https, "api.example.com", 443), false);
    try expectAdmitted(try decide(policy, .http, "api.example.com", 80), false);
    try expectDenied(try decide(policy, .https, "api.example.com", 80), .port_not_allowed);
    try expectDenied(try decide(policy, .http, "api.example.com", 443), .port_not_allowed);
}

test "plain HTTP needs allowHttp in a setting that names the host" {
    var https_only = try support.Fixture.init(gpa, &.{.{ .allow = &.{"api.example.com"} }});
    defer https_only.deinit(gpa);
    try expectDenied(try decide(https_only.policy(), .http, "api.example.com", null), .http_not_allowed);
    try expectAdmitted(try decide(https_only.policy(), .https, "api.example.com", null), false);

    // The scheme is refused before the port is weighed when no setting that
    // names the host allows it.
    var other_port = try support.Fixture.init(gpa, &.{.{ .allow = &.{"api.example.com:8443"} }});
    defer other_port.deinit(gpa);
    try expectDenied(try decide(other_port.policy(), .http, "api.example.com", null), .http_not_allowed);
}

test "a union admits exactly what one of its grants admits" {
    var fixture = try support.Fixture.init(gpa, &.{
        .{ .allow = &.{"a.example"}, .allow_http = true },
        .{ .allow = &.{"b.example"} },
        .{ .allow = &.{ "*.corp.example", "10.0.0.5" }, .allow_private_networks = true },
    });
    defer fixture.deinit(gpa);
    const policy = fixture.policy();
    try std.testing.expectEqual(@as(usize, 3), policy.grants.len);

    try expectAdmitted(try decide(policy, .http, "a.example", null), false);
    try expectAdmitted(try decide(policy, .https, "b.example", null), false);
    // The first grant's allowHttp does not reach the second grant's host.
    try expectDenied(try decide(policy, .http, "b.example", null), .http_not_allowed);
    // The third grant's allowPrivateNetworks reaches its own entries only.
    try expectAdmitted(try decide(policy, .https, "db.corp.example", null), true);
    try expectAdmitted(try decide(policy, .https, "10.0.0.5", null), true);
    try expectDenied(try decide(policy, .http, "db.corp.example", null), .http_not_allowed);
    try expectDenied(try decide(policy, .https, "c.example", null), .host_not_allowed);
}

test "a near miss names the change that would admit it" {
    // One grant names the host and the port without plain HTTP, another
    // allows plain HTTP for the host on another port: listing the port is
    // the change that admits the hop.
    var fixture = try support.Fixture.init(gpa, &.{
        .{ .allow = &.{"api.example.com"} },
        .{ .allow = &.{"api.example.com:8080"}, .allow_http = true },
    });
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectDenied(try decide(policy, .http, "api.example.com", null), .port_not_allowed);
    try expectAdmitted(try decide(policy, .http, "api.example.com", 8080), false);
    try expectAdmitted(try decide(policy, .https, "api.example.com", null), false);
    try expectDenied(try decide(policy, .https, "api.example.com", 9000), .port_not_allowed);
    try expectDenied(try decide(policy, .https, "web.example.com", null), .host_not_allowed);
}

test "localhost and reserved addresses are refused before any grant is consulted" {
    var fixture = try support.Fixture.init(gpa, &.{.{ .allow = &.{"*"}, .allow_http = true }});
    defer fixture.deinit(gpa);
    const policy = fixture.policy();

    try expectDenied(try decide(policy, .https, "localhost", null), .reserved_address);
    try expectDenied(try decide(policy, .https, "LOCALHOST.", null), .reserved_address);
    try expectDenied(try decide(policy, .https, "api.localhost", null), .reserved_address);
    try expectDenied(try decide(policy, .http, "127.0.0.1", null), .reserved_address);
    try expectDenied(try decide(policy, .http, "169.254.169.254", null), .reserved_address);
    try expectDenied(try decide(policy, .https, "[::1]", null), .reserved_address);
    try expectDenied(try decide(policy, .https, "[fd00:ec2::254]", null), .reserved_address);
    try expectDenied(try decide(policy, .https, "[fd20:ce::254]", null), .reserved_address);
    try expectDenied(try decide(policy, .https, "[::7f00:1]", null), .reserved_address);
    try expectDenied(try decide(policy, .https, "[::ffff:127.0.0.1]", null), .reserved_address);
    try expectAdmitted(try decide(policy, .https, "192.0.78.9", null), false);
    // Even on a port no entry names.
    try expectDenied(try decide(policy, .https, "localhost", 8443), .reserved_address);
}

test "a policy without grants refuses everything first, with no_grant" {
    try expectDenied(try decide(network.deny_all, .https, "api.example.com", null), .no_grant);
    try expectDenied(try decide(network.deny_all, .https, "localhost", null), .no_grant);

    var fixture = try support.Fixture.init(gpa, &.{.{ .allow = &.{"*"} }});
    defer fixture.deinit(gpa);
    const zero = fixture.table.policy(network.table.deny_all_id).?;
    try std.testing.expectEqual(@as(usize, 0), zero.grants.len);
    try expectDenied(try decide(zero, .https, "api.example.com", null), .no_grant);
}

test "public_https admits any public host over HTTPS on port 443 only" {
    const policy = network.public_https;
    try expectAdmitted(try decide(policy, .https, "api.example.com", null), false);
    try expectAdmitted(try decide(policy, .https, "93.184.216.34", null), false);
    try expectDenied(try decide(policy, .http, "api.example.com", null), .http_not_allowed);
    try expectDenied(try decide(policy, .https, "api.example.com", 8443), .port_not_allowed);
    try expectDenied(try decide(policy, .https, "10.0.0.1", null), .private_address);
    try expectDenied(try decide(policy, .https, "localhost", null), .reserved_address);
}

test "a resolved address passes only by its class and the admission" {
    const public_only: network.Admission = .{ .allow_private_networks = false };
    const with_private: network.Admission = .{ .allow_private_networks = true };
    const Case = struct {
        text: []const u8,
        public_only: ?network.Denial,
        with_private: ?network.Denial,
    };
    const cases = [_]Case{
        .{ .text = "93.184.216.34", .public_only = null, .with_private = null },
        .{ .text = "10.0.0.1", .public_only = .private_address, .with_private = null },
        .{ .text = "192.168.1.1", .public_only = .private_address, .with_private = null },
        .{ .text = "127.0.0.1", .public_only = .reserved_address, .with_private = .reserved_address },
        .{ .text = "169.254.169.254", .public_only = .reserved_address, .with_private = .reserved_address },
        .{ .text = "100.64.0.1", .public_only = .reserved_address, .with_private = .reserved_address },
        .{ .text = "0.0.0.0", .public_only = .reserved_address, .with_private = .reserved_address },
    };
    for (cases) |case| {
        const resolved = try std.net.Address.parseIp4(case.text, 443);
        try std.testing.expectEqual(case.public_only, network.admitAddress(public_only, resolved));
        try std.testing.expectEqual(case.with_private, network.admitAddress(with_private, resolved));
    }
    const ula = try std.net.Address.parseIp6("fd00::1", 443);
    try std.testing.expectEqual(@as(?network.Denial, null), network.admitAddress(with_private, ula));
    // A tenant's AAAA record may name a cloud's metadata server inside
    // unique-local space; allowing private networks never reaches it.
    for ([_][]const u8{ "fd00:ec2::254", "fd20:ce::254", "fd00:a9fe:a9fe::1", "fd00:42::42" }) |text| {
        const metadata = try std.net.Address.parseIp6(text, 443);
        try std.testing.expectEqual(@as(?network.Denial, .reserved_address), network.admitAddress(with_private, metadata));
    }
    const wireserver = try std.net.Address.parseIp4("168.63.129.16", 443);
    try std.testing.expectEqual(@as(?network.Denial, .reserved_address), network.admitAddress(with_private, wireserver));
}

test "a host no entry could name has no target" {
    var buffer: [network.pattern.name_bytes_max]u8 = undefined;
    const refused = [_][]const u8{ "exämple.com", "127.1", "0177.0.0.1", "a..b", "%6cocalhost", "[::1%25lo]", "" };
    for (refused) |host|
        try std.testing.expectEqual(@as(?network.Target, null), network.Target.init(.https, host, null, &buffer));

    const target = network.Target.init(.http, "[2606:4700::1111]", null, &buffer).?;
    try std.testing.expectEqual(@as(u16, 80), target.port);
    try std.testing.expectEqual(network.Scheme.http, target.scheme);
}

fn denialText(buffer: []u8, origin: network.Origin, denial: network.Denial) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try network.writeDenial(&writer, origin, denial);
    return writer.buffered();
}

test "a denial names the origin and what to change" {
    var buffer: [network.grant.denial_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "fetch to https://api.example.com denied by the network setting: the host is not in the allow list",
        try denialText(&buffer, .{ .scheme = .https, .host = "api.example.com", .port = 443 }, .host_not_allowed),
    );
    try std.testing.expectEqualStrings(
        "fetch to http://api.example.com:8080 denied by the network setting: the host is allowed only on other ports; list it as host:port",
        try denialText(&buffer, .{ .scheme = .http, .host = "api.example.com", .port = 8080 }, .port_not_allowed),
    );
    try std.testing.expectEqualStrings(
        "fetch to http://[2606:4700::1111] denied by the network setting: plain HTTP needs allowHttp",
        try denialText(&buffer, .{ .scheme = .http, .host = "[2606:4700::1111]", .port = 80 }, .http_not_allowed),
    );
    // A tenant's bytes never reach the log as control characters.
    try std.testing.expectEqualStrings(
        "fetch to https://a?b?c?d denied by the network setting: no network setting grants access to this route",
        try denialText(&buffer, .{ .scheme = .https, .host = "a\x00b\x7fc d", .port = 443 }, .no_grant),
    );
}

test "the longest denial fits denial_bytes_max, with a long host cut" {
    var buffer: [network.grant.denial_bytes_max]u8 = undefined;
    const long_host = "a" ** 400;
    var longest: usize = 0;
    for (std.enums.values(network.Denial)) |denial| {
        const text = try denialText(&buffer, .{ .scheme = .https, .host = long_host, .port = 65535 }, denial);
        longest = @max(longest, text.len);
        const shown = "https://" ++ "a" ** network.grant.denial_host_bytes_max ++ "...:65535 ";
        try std.testing.expect(std.mem.indexOf(u8, text, shown) != null);
    }
    try std.testing.expectEqual(network.grant.denial_bytes_max, longest);
}
