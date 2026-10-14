//! Network policy images for the gateway suites, built as the server builds its image
//! (`collo_network`'s `Builder`) and lent as the server lends it, in a memfd under
//! `memfd_readonly_seals`, so a hello under test and the table the gateway decodes from it take
//! the production path. Holds no tests.

const std = @import("std");
const os = @import("collo_os");
const network = @import("collo_egress_client").network;

/// Policy 1 of `standard`: any public host over HTTPS on port 443.
pub const public_https_id: network.PolicyId = 1;
/// Policy 2 of `standard`: any public host over HTTP on port 80 or HTTPS on port 443.
pub const public_http_and_https_id: network.PolicyId = 2;
/// The policies of `standard`: policy 0, which grants nothing, and the two above.
pub const standard_policy_count: usize = 3;

/// The settings, the policies and the members of one policy an image built here holds at most.
pub const settings_max: usize = 8;

const any_host = [_]network.Pattern{.{ .host = .any, .port = 0 }};

const standard_settings = [_]network.Setting{
    .{ .allow = &any_host },
    .{ .allow = &any_host, .allow_http = true },
};
const standard_https_members = [_]usize{0};
const standard_http_members = [_]usize{1};
const standard_policies = [_][]const usize{ &standard_https_members, &standard_http_members };

/// The image every suite's hello carries unless the suite says otherwise; the caller frees it.
pub fn standard(gpa: std.mem.Allocator) ![]u8 {
    return encode(gpa, &standard_settings, &standard_policies);
}

/// Policy 3 of `withOrigin`: plain HTTP to one IPv4 address and port.
pub const origin_id: network.PolicyId = 3;

/// `standard` with policy `origin_id`, which grants plain HTTP to `ipv4` on `port`, private
/// networks included when `ipv4` is private, as a configuration naming that literal grants it.
/// Loopback stays refused, as under every grant. The caller frees the image.
pub fn withOrigin(gpa: std.mem.Allocator, ipv4: [4]u8, port: u16) ![]u8 {
    const entry = [_]network.Pattern{.{ .host = .{ .ipv4 = ipv4 }, .port = port }};
    const settings = [_]network.Setting{
        standard_settings[0],
        standard_settings[1],
        .{
            .allow = &entry,
            .allow_http = true,
            .allow_private_networks = entry[0].canReachPrivate(),
        },
    };
    const origin_members = [_]usize{standard_settings.len};
    const policies = [_][]const usize{ standard_policies[0], standard_policies[1], &origin_members };
    comptime std.debug.assert(standard_policies.len + 1 == origin_id);
    return encode(gpa, &settings, &policies);
}

/// The image of `settings`, in which policy `index + 1` holds the grants of the settings that
/// `policies[index]` names by index, allocated with `gpa`; the caller frees it. The builder
/// stores equal policies once, so the policies must differ from each other.
pub fn encode(
    gpa: std.mem.Allocator,
    settings: []const network.Setting,
    policies: []const []const usize,
) ![]u8 {
    if (settings.len > settings_max or policies.len > settings_max)
        return error.TestImageTooLarge;
    var builder = network.Builder.init(gpa);
    defer builder.deinit();
    var grant_ids: [settings_max]network.table.GrantId = undefined;
    for (settings, 0..) |setting, index|
        grant_ids[index] = try builder.addGrant(setting);
    for (policies, 1..) |members, expected_id| {
        if (members.len > settings_max)
            return error.TestImageTooLarge;
        var member_ids: [settings_max]network.table.GrantId = undefined;
        for (members, 0..) |setting_index, slot|
            member_ids[slot] = grant_ids[setting_index];
        const id = try builder.addPolicy(member_ids[0..members.len]);
        try std.testing.expectEqual(@as(network.PolicyId, @intCast(expected_id)), id);
    }
    return builder.encode(gpa);
}

/// A memfd that holds `image` under `seals`, as the server lends its image to a hello when
/// `seals` is `memfd_readonly_seals`. The caller closes it; a hello carries a copy the kernel
/// makes.
pub fn memfdHolding(image: []const u8, seals: usize) !os.fd.OwnedFd {
    var memfd = os.fd.OwnedFd.fromRaw(try std.posix.memfd_create(
        "collo-test-policy-image",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    ));
    errdefer memfd.deinit();
    try os.fd.writeAllRaw(memfd.fd(), image);
    try os.fd.addSeals(memfd.fd(), seals);
    return memfd;
}
