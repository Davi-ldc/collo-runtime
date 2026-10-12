//! Fixtures shared by the `collo_network` suite: allow lists parsed from
//! text, tables built from settings through the builder and decoded the way
//! the gateway decodes them, and the hop decisions the tests compare. It
//! declares no test.

const std = @import("std");
const network = @import("collo_network");

const name_bytes_max = network.pattern.name_bytes_max;

/// Parses every entry of `texts` with its name in memory from `arena`, and
/// fails the test when the grammar refuses one.
pub fn parseAll(arena: std.mem.Allocator, texts: []const []const u8) ![]network.Pattern {
    const patterns = try arena.alloc(network.Pattern, texts.len);
    for (texts, patterns) |text, *out| {
        const buffer = try arena.create([name_bytes_max]u8);
        switch (network.pattern.parse(text, buffer)) {
            .pattern => |parsed| out.* = parsed,
            .problem => |problem| {
                std.debug.print("'{s}' was refused: {s}\n", .{ text, problem.describe() });
                return error.TestUnexpectedResult;
            },
        }
    }
    return patterns;
}

/// One setting written as the configuration writes it.
pub const Spec = struct {
    allow: []const []const u8,
    allow_http: bool = false,
    allow_private_networks: bool = false,
};

/// Adds the grant of `spec` to `builder`, parsing its entries into `arena`.
pub fn addGrant(builder: *network.Builder, arena: std.mem.Allocator, spec: Spec) !network.table.GrantId {
    return builder.addGrant(.{
        .allow = try parseAll(arena, spec.allow),
        .allow_http = spec.allow_http,
        .allow_private_networks = spec.allow_private_networks,
    });
}

/// A decoded table whose policy `policy_id` holds one grant per spec, built
/// and decoded along the path the server and the gateway take.
pub const Fixture = struct {
    table: network.Table,
    policy_id: network.PolicyId,

    pub fn init(gpa: std.mem.Allocator, specs: []const Spec) !Fixture {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var builder = network.Builder.init(gpa);
        defer builder.deinit();

        var ids: [network.table.members_per_policy_max]network.table.GrantId = undefined;
        if (specs.len > ids.len)
            return error.TestUnexpectedResult;
        for (specs, 0..) |spec, index|
            ids[index] = try addGrant(&builder, arena.allocator(), spec);
        const policy_id = try builder.addPolicy(ids[0..specs.len]);

        const image = try builder.encode(gpa);
        defer gpa.free(image);
        return .{ .table = try network.Table.decode(gpa, image), .policy_id = policy_id };
    }

    pub fn deinit(fixture: *Fixture, gpa: std.mem.Allocator) void {
        fixture.table.deinit(gpa);
    }

    pub fn policy(fixture: *const Fixture) network.Policy {
        return fixture.table.policy(fixture.policy_id).?;
    }
};

/// Decides a hop to `host`, spelled as a URL spells it, under `policy`.
pub fn decide(policy: network.Policy, scheme: network.Scheme, host: []const u8, port: ?u16) !network.Decision {
    var buffer: [name_bytes_max]u8 = undefined;
    const target = network.Target.init(scheme, host, port, &buffer) orelse {
        std.debug.print("'{s}' is not a host an entry could name\n", .{host});
        return error.TestUnexpectedResult;
    };
    return network.admit(policy, target);
}

pub fn expectAdmitted(decision: network.Decision, allow_private_networks: bool) !void {
    const expected: network.Decision = .{ .admitted = .{ .allow_private_networks = allow_private_networks } };
    try std.testing.expectEqual(expected, decision);
}

pub fn expectDenied(decision: network.Decision, denial: network.Denial) !void {
    const expected: network.Decision = .{ .denied = denial };
    try std.testing.expectEqual(expected, decision);
}
