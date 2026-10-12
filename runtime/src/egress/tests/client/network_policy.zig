//! Network policies for the egress client's tests, which serve their origins on this host's
//! routable address (`collo_test_net`) or name hosts no test resolves. A transport `Config` has
//! no default policy and a policy admits only what its grants name (`collo_network`), so each
//! test names the origins it reaches here instead of turning a check off. Holds no tests.

const std = @import("std");
const network = @import("collo_egress_client").network;

/// Any public host over HTTPS on port 443.
pub const public_https = network.public_https;

const public_any_scheme_grant: network.Grant = .{
    .allow_http = true,
    .allow_private_networks = false,
    .any = true,
    .names = &.{},
    .suffixes = &.{},
    .ipv4 = &.{},
    .ipv6 = &.{},
};

/// Any public host over HTTP on port 80 or HTTPS on port 443.
pub const public_http_and_https: network.Policy = .{ .grants = &.{&public_any_scheme_grant} };

/// Plain HTTP and HTTPS to one IPv4 address on the ports a test serves, private or public as the
/// address is. The policy points into this value, so a test initializes it in place and keeps
/// it where it is while a fetch uses the policy.
pub const Origins = struct {
    rules: [ports_max]network.Pattern = undefined,
    grant: network.Grant = undefined,
    grants: [1]*const network.Grant = undefined,

    pub const ports_max: usize = 8;

    /// `host` is a dotted quad, such as `collo_test_net.routableLocalIpv4` writes, and `ports`
    /// holds 1 to `ports_max` distinct ports.
    pub fn init(self: *Origins, host: []const u8, ports: []const u16) !void {
        std.debug.assert(ports.len >= 1);
        std.debug.assert(ports.len <= ports_max);
        const address = try std.net.Address.parseIp4(host, 0);
        const bytes = network.address.ipv4Bytes(address);
        const rules = self.rules[0..ports.len];
        for (ports, rules) |port, *rule|
            rule.* = .{ .host = .{ .ipv4 = bytes }, .port = port };
        // A grant's rules are in canonical order, which `admit` searches.
        std.mem.sort(network.Pattern, rules, {}, network.Pattern.lessThan);
        self.grant = .{
            .allow_http = true,
            .allow_private_networks = true,
            .any = false,
            .names = &.{},
            .suffixes = &.{},
            .ipv4 = rules,
            .ipv6 = &.{},
        };
        self.grants = .{&self.grant};
    }

    pub fn policy(self: *const Origins) network.Policy {
        return .{ .grants = &self.grants };
    }
};
