//! Network policy images for the gateway suites, built as the server builds its image
//! (`collo_network`'s `Builder`) and lent as the server lends it, in a memfd under
//! `memfd_readonly_seals`, so a hello under test and the table the gateway decodes from it take
//! the production path. Holds no tests.

const std = @import("std");
const gateway = @import("collo_egress_gateway");
const ipc = @import("collo_ipc");
const os = @import("collo_os");
const network = @import("collo_egress_client").network;

const control_flow = gateway.testing.control_flow;
const policy = gateway.policy;

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

/// The digest the image's header carries, which the gateway folds into each policy's isolation
/// id.
pub fn digest(image: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    return network.table.readHeader(image).digest;
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

/// What the gateway keeps after a hello that carries `image` under `key`: the decoded table and
/// each policy's isolation id under the production limits, as `runtime/control_flow.zig`
/// computes them, for suites that run the gateway's mixins without its control socket. The
/// caller frees it with `HelloState.deinit` and `gpa`.
pub fn helloState(
    gpa: std.mem.Allocator,
    image: []const u8,
    key: ipc.egress_token.Key,
) !control_flow.HelloState {
    var table = try network.Table.decode(gpa, image);
    errdefer table.deinit(gpa);
    const isolation_ids = try gpa.alloc(policy.PoolIsolationId, table.policies.len);
    const limits_id = policy.policyIsolationId(policy.production);
    for (isolation_ids, 0..) |*isolation_id, index|
        isolation_id.* = policy.networkPolicyIsolationId(limits_id, table.digest, @intCast(index));
    return .{
        .received = true,
        .key = key,
        .table = table,
        .isolation_ids = isolation_ids,
    };
}
