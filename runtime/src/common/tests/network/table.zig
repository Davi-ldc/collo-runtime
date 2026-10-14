//! The policy image (`common/network/table.zig`): the builder's round trip
//! through `check` and `decode`, its deduplication and its refusals, the
//! bounds of a table, every corruption `check` refuses with the reason it
//! gives, and allocation failures in the builder and the decoder.

const std = @import("std");
const network = @import("collo_network");
const support = @import("support.zig");

const table = network.table;
const Problem = table.Problem;
const Layout = table.Layout;
const gpa = std.testing.allocator;

/// The reference image's grants, in the order they are added:
/// - grant 0 holds one rule of every kind, sorted to `*`,
///   `api.example.com`, `api.example.com:8443`, `*.example.org`,
///   `93.184.216.34` and `[2606:4700::1111]`, rules 0 to 5;
/// - grant 1 holds `internal.example`, `10.0.0.5` and `10.0.0.6`, rules 6
///   to 8, under allowPrivateNetworks;
/// - grant 2 holds `1.1.1.1` and `93.184.216.34`, rules 9 and 10.
const reference_specs = [_]support.Spec{
    .{
        .allow = &.{ "[2606:4700::1111]", "api.example.com:8443", "*", "93.184.216.34", "*.example.org", "api.example.com" },
        .allow_http = true,
    },
    .{ .allow = &.{ "10.0.0.6", "internal.example", "10.0.0.5" }, .allow_private_networks = true },
    .{ .allow = &.{ "93.184.216.34", "1.1.1.1" } },
};

/// The reference image's policies after policy 0, with ids 1 to 4; their
/// members are member slots 0 to 4.
const reference_policies = [_][]const table.GrantId{ &.{0}, &.{1}, &.{ 1, 0 }, &.{2} };

/// The names in rule order: `api.example.com` twice, `example.org` and
/// `internal.example`.
const reference_name_bytes = 15 + 15 + 11 + 16;

fn buildReference(allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = network.Builder.init(allocator);
    defer builder.deinit();
    for (reference_specs, 0..) |spec, index| {
        const id = try support.addGrant(&builder, arena.allocator(), spec);
        try std.testing.expectEqual(@as(table.GrantId, @intCast(index)), id);
    }
    for (reference_policies, 1..) |members, index| {
        const id = try builder.addPolicy(members);
        try std.testing.expectEqual(@as(table.PolicyId, @intCast(index)), id);
    }
    return builder.encode(allocator);
}

fn referenceLayout(image: []const u8) Layout {
    return Layout.init(table.readHeader(image));
}

test "the builder's image passes its checks and decodes to what was added" {
    const image = try buildReference(gpa);
    defer gpa.free(image);
    try std.testing.expectEqual(@as(?Problem, null), table.check(image));

    const header = table.readHeader(image);
    try std.testing.expectEqualSlices(u8, &table.magic, &header.magic);
    try std.testing.expectEqual(@as(u32, 3), header.grant_count);
    try std.testing.expectEqual(@as(u32, 11), header.rule_count);
    try std.testing.expectEqual(@as(u32, 5), header.policy_count);
    try std.testing.expectEqual(@as(u32, 5), header.member_count);
    try std.testing.expectEqual(@as(u32, reference_name_bytes), header.name_bytes);
    try std.testing.expectEqual(referenceLayout(image).total, image.len);

    var decoded = try network.Table.decode(gpa, image);
    defer decoded.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), decoded.policy(0).?.grants.len);
    try std.testing.expectEqual(@as(?network.Policy, null), decoded.policy(5));

    const first = decoded.policy(1).?.grants[0];
    try std.testing.expect(first.any);
    try std.testing.expect(first.allow_http);
    try std.testing.expect(!first.allow_private_networks);
    try std.testing.expectEqual(@as(usize, 2), first.names.len);
    try std.testing.expectEqualStrings("api.example.com", first.names[0].host.name);
    try std.testing.expectEqual(@as(u16, 0), first.names[0].port);
    try std.testing.expectEqual(@as(u16, 8443), first.names[1].port);
    try std.testing.expectEqual(@as(usize, 1), first.suffixes.len);
    try std.testing.expectEqualStrings("example.org", first.suffixes[0].host.suffix);
    try std.testing.expectEqual(@as(usize, 1), first.ipv4.len);
    try std.testing.expectEqual(@as(usize, 1), first.ipv6.len);

    const second = decoded.policy(2).?.grants[0];
    try std.testing.expect(second.allow_private_networks);
    try std.testing.expect(!second.any);
    try std.testing.expectEqual(@as(usize, 2), second.ipv4.len);

    // The union's members point at the same decoded grants.
    const union_policy = decoded.policy(3).?;
    try std.testing.expectEqual(@as(usize, 2), union_policy.grants.len);
    try std.testing.expectEqual(first, union_policy.grants[0]);
    try std.testing.expectEqual(second, union_policy.grants[1]);
    try support.expectAdmitted(try support.decide(union_policy, .https, "internal.example", null), true);
    try support.expectAdmitted(try support.decide(union_policy, .http, "api.example.com", 8443), false);
}

test "a decoded table keeps its own copy of the image's names" {
    const image = try buildReference(gpa);
    defer gpa.free(image);
    var decoded = try network.Table.decode(gpa, image);
    defer decoded.deinit(gpa);
    @memset(image, 0);
    try support.expectAdmitted(try support.decide(decoded.policy(1).?, .https, "api.example.com", null), false);
}

test "an empty builder writes policy 0 alone" {
    var builder = network.Builder.init(gpa);
    defer builder.deinit();
    try std.testing.expectEqual(table.deny_all_id, try builder.addPolicy(&.{}));
    const image = try builder.encode(gpa);
    defer gpa.free(image);

    var decoded = try network.Table.decode(gpa, image);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), decoded.grants.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.policies.len);
    try support.expectDenied(try support.decide(decoded.policy(0).?, .https, "api.example.com", null), .no_grant);
}

test "equal grants and equal policies are stored once" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var builder = network.Builder.init(gpa);
    defer builder.deinit();

    const first = try support.addGrant(&builder, arena.allocator(), .{ .allow = &.{ "b.example", "A.example" } });
    const same = try support.addGrant(&builder, arena.allocator(), .{ .allow = &.{ "a.example", "b.example." } });
    try std.testing.expectEqual(first, same);
    // A flag makes another grant.
    const with_http = try support.addGrant(&builder, arena.allocator(), .{
        .allow = &.{ "a.example", "b.example" },
        .allow_http = true,
    });
    try std.testing.expect(with_http != first);
    // A port makes another grant.
    const with_port = try support.addGrant(&builder, arena.allocator(), .{ .allow = &.{ "a.example:8443", "b.example" } });
    try std.testing.expect(with_port != first);
    try std.testing.expect(with_port != with_http);

    const union_id = try builder.addPolicy(&.{ with_http, first });
    try std.testing.expectEqual(union_id, try builder.addPolicy(&.{ first, with_http, first }));
    try std.testing.expect(union_id != try builder.addPolicy(&.{first}));
    try std.testing.expectEqual(table.deny_all_id, try builder.addPolicy(&.{}));

    const image = try builder.encode(gpa);
    defer gpa.free(image);
    const header = table.readHeader(image);
    try std.testing.expectEqual(@as(u32, 3), header.grant_count);
    // Policy 0, the union and the single grant.
    try std.testing.expectEqual(@as(u32, 3), header.policy_count);
}

test "the builder refuses what the configuration parser would refuse" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var builder = network.Builder.init(gpa);
    defer builder.deinit();

    // An empty list compiles to policy 0, not to a grant.
    try std.testing.expectError(error.InvalidSetting, builder.addGrant(.{ .allow = &.{} }));
    try std.testing.expectError(
        error.InvalidSetting,
        support.addGrant(&builder, arena.allocator(), .{ .allow = &.{ "a.example", "A.example." } }),
    );
    try std.testing.expectError(
        error.InvalidSetting,
        support.addGrant(&builder, arena.allocator(), .{ .allow = &.{"10.0.0.5"} }),
    );
    try std.testing.expectError(
        error.InvalidSetting,
        support.addGrant(&builder, arena.allocator(), .{ .allow = &.{"*"}, .allow_private_networks = true }),
    );
    // Patterns the grammar never produces.
    const not_canonical = [_]network.Pattern{
        .{ .host = .{ .name = "API.example" }, .port = 0 },
        .{ .host = .any, .port = 443 },
        .{ .host = .{ .ipv4 = .{ 127, 0, 0, 1 } }, .port = 0 },
        .{ .host = .{ .suffix = "localhost" }, .port = 0 },
    };
    for (not_canonical) |entry|
        try std.testing.expectError(error.InvalidSetting, builder.addGrant(.{ .allow = &.{entry} }));

    try std.testing.expectError(error.InvalidPolicy, builder.addPolicy(&.{0}));
    const id = try support.addGrant(&builder, arena.allocator(), .{ .allow = &.{"a.example"} });
    try std.testing.expectError(error.InvalidPolicy, builder.addPolicy(&.{ id, id + 1 }));
}

/// Adds `count` grants of one distinct name each and returns their ids.
fn addDistinctGrants(builder: *network.Builder, arena: std.mem.Allocator, count: usize) ![]table.GrantId {
    const ids = try arena.alloc(table.GrantId, count);
    for (ids, 0..) |*id, index| {
        const text = try std.fmt.allocPrint(arena, "g{d}.example", .{index});
        id.* = try support.addGrant(builder, arena, .{ .allow = &.{text} });
    }
    return ids;
}

test "the builder stops at grants_max grants and policies_max policies" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var builder = network.Builder.init(gpa);
    defer builder.deinit();

    const ids = try addDistinctGrants(&builder, arena.allocator(), table.grants_max);
    try std.testing.expectError(
        error.TableFull,
        support.addGrant(&builder, arena.allocator(), .{ .allow = &.{"one-more.example"} }),
    );
    // An equal grant is no new grant.
    try std.testing.expectEqual(ids[0], try support.addGrant(&builder, arena.allocator(), .{ .allow = &.{"g0.example"} }));

    // Policy 0 holds one of the ids.
    for (ids[0 .. table.policies_max - 1]) |id|
        _ = try builder.addPolicy(&.{id});
    try std.testing.expectError(error.TableFull, builder.addPolicy(&.{ids[table.policies_max - 1]}));
    try std.testing.expectEqual(@as(table.PolicyId, 1), try builder.addPolicy(&.{ids[0]}));

    const image = try builder.encode(gpa);
    defer gpa.free(image);
    try std.testing.expectEqual(@as(?Problem, null), table.check(image));
    try std.testing.expect(image.len <= table.image_bytes_max);
}

test "the builder stops at members_per_policy_max members and members_max in all" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var builder = network.Builder.init(gpa);
    defer builder.deinit();

    const width = table.members_per_policy_max;
    const ids = try addDistinctGrants(&builder, arena.allocator(), width + 8);
    try std.testing.expectError(error.InvalidPolicy, builder.addPolicy(ids[0 .. width + 1]));

    // Windows of `width` members, each a distinct policy, until the members
    // run out.
    const full_windows = table.members_max / width;
    for (0..full_windows) |start|
        _ = try builder.addPolicy(ids[start..][0..width]);
    try std.testing.expectError(error.TableFull, builder.addPolicy(ids[full_windows..][0..width]));
}

test "the builder stops at rules_max rules" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var builder = network.Builder.init(gpa);
    defer builder.deinit();

    const per_grant = table.rules_per_grant_max;
    const texts = try arena.allocator().alloc([]const u8, per_grant);
    for (0..table.rules_max / per_grant) |grant_index| {
        for (texts, 0..) |*text, index|
            text.* = try std.fmt.allocPrint(arena.allocator(), "r{d}.g{d}.example", .{ index, grant_index });
        _ = try support.addGrant(&builder, arena.allocator(), .{ .allow = texts });
    }
    try std.testing.expectError(
        error.TableFull,
        support.addGrant(&builder, arena.allocator(), .{ .allow = &.{"one-more.example"} }),
    );
}

/// A copy of `image` changed by `mutation`; the caller frees it.
fn mutated(image: []const u8, mutation: anytype) ![]u8 {
    const copy = try gpa.dupe(u8, image);
    mutation.apply(copy, referenceLayout(image));
    return copy;
}

fn expectProblem(image: []const u8, expected: Problem) !void {
    const problem = table.check(image) orelse {
        std.debug.print("expected {s}, the image passed\n", .{@tagName(expected)});
        return error.TestUnexpectedResult;
    };
    if (problem != expected)
        std.debug.print("expected {s}, found {s}\n", .{ @tagName(expected), @tagName(problem) });
    try std.testing.expectEqual(expected, problem);
}

fn expectMutationProblem(image: []const u8, mutation: anytype, expected: Problem) !void {
    const copy = try mutated(image, mutation);
    defer gpa.free(copy);
    try expectProblem(copy, expected);
    try std.testing.expectError(error.InvalidPolicyImage, network.Table.decode(gpa, copy));
}

fn putU32(image: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, image[offset..][0..4], value, .little);
}

fn putU16(image: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, image[offset..][0..2], value, .little);
}

/// Writes `value` into the header field `field`.
fn HeaderCount(comptime field: []const u8) type {
    return struct {
        value: u32,
        fn apply(mutation: @This(), image: []u8, layout: Layout) void {
            _ = layout;
            putU32(image, @offsetOf(table.Header, field), mutation.value);
        }
    };
}

/// Writes `value` at `field_offset` of grant `index`.
const GrantByte = struct {
    index: usize,
    field_offset: usize,
    value: u8,
    fn apply(mutation: GrantByte, image: []u8, layout: Layout) void {
        image[layout.grantOffset(mutation.index) + mutation.field_offset] = mutation.value;
    }
};

const GrantRules = struct {
    index: usize,
    value: u16,
    fn apply(mutation: GrantRules, image: []u8, layout: Layout) void {
        putU16(image, layout.grantOffset(mutation.index), mutation.value);
    }
};

/// Writes `value` at `field_offset` of rule `index`.
const RuleByte = struct {
    index: usize,
    field_offset: usize,
    value: u8,
    fn apply(mutation: RuleByte, image: []u8, layout: Layout) void {
        image[layout.ruleOffset(mutation.index) + mutation.field_offset] = mutation.value;
    }
};

const RulePort = struct {
    index: usize,
    value: u16,
    fn apply(mutation: RulePort, image: []u8, layout: Layout) void {
        putU16(image, layout.ruleOffset(mutation.index) + @offsetOf(table.RuleRecord, "port"), mutation.value);
    }
};

/// Copies the address of rule `source` over that of rule `target`.
const RuleAddressCopy = struct {
    source: usize,
    target: usize,
    fn apply(mutation: RuleAddressCopy, image: []u8, layout: Layout) void {
        const offset = @offsetOf(table.RuleRecord, "address");
        const source = image[layout.ruleOffset(mutation.source) + offset ..][0..16].*;
        @memcpy(image[layout.ruleOffset(mutation.target) + offset ..][0..16], &source);
    }
};

/// Swaps the addresses of two rules.
const RuleAddressSwap = struct {
    left: usize,
    right: usize,
    fn apply(mutation: RuleAddressSwap, image: []u8, layout: Layout) void {
        const offset = @offsetOf(table.RuleRecord, "address");
        const left = image[layout.ruleOffset(mutation.left) + offset ..][0..16];
        const right = image[layout.ruleOffset(mutation.right) + offset ..][0..16];
        const saved = left.*;
        left.* = right.*;
        right.* = saved;
    }
};

const NameByte = struct {
    offset: usize,
    value: u8,
    fn apply(mutation: NameByte, image: []u8, layout: Layout) void {
        image[layout.names_offset + mutation.offset] = mutation.value;
    }
};

const PolicyMembers = struct {
    index: usize,
    value: u16,
    fn apply(mutation: PolicyMembers, image: []u8, layout: Layout) void {
        putU16(image, layout.policyOffset(mutation.index), mutation.value);
    }
};

const Member = struct {
    index: usize,
    value: u16,
    fn apply(mutation: Member, image: []u8, layout: Layout) void {
        putU16(image, layout.memberOffset(mutation.index), mutation.value);
    }
};

test "each structural rule refuses the image that breaks it alone" {
    const image = try buildReference(gpa);
    defer gpa.free(image);
    const kind_offset = @offsetOf(table.RuleRecord, "kind");
    const name_len_offset = @offsetOf(table.RuleRecord, "name_len");
    const address_offset = @offsetOf(table.RuleRecord, "address");
    const http_offset = @offsetOf(table.GrantRecord, "allow_http");
    const private_offset = @offsetOf(table.GrantRecord, "allow_private_networks");

    try expectMutationProblem(image, HeaderCount("grant_count"){ .value = table.grants_max + 1 }, .grant_count);
    try expectMutationProblem(image, HeaderCount("rule_count"){ .value = table.rules_max + 1 }, .rule_count);
    try expectMutationProblem(image, HeaderCount("policy_count"){ .value = 0 }, .policy_count);
    try expectMutationProblem(image, HeaderCount("policy_count"){ .value = table.policies_max + 1 }, .policy_count);
    try expectMutationProblem(image, HeaderCount("member_count"){ .value = table.members_max + 1 }, .member_count);
    try expectMutationProblem(image, HeaderCount("name_bytes"){ .value = table.name_bytes_max + 1 }, .name_bytes);
    try expectMutationProblem(image, HeaderCount("rule_count"){ .value = 12 }, .length);

    try expectMutationProblem(image, GrantByte{ .index = 0, .field_offset = http_offset, .value = 2 }, .grant_flag);
    try expectMutationProblem(image, GrantByte{ .index = 1, .field_offset = private_offset, .value = 2 }, .grant_flag);
    try expectMutationProblem(image, GrantRules{ .index = 2, .value = 0 }, .grant_rules);
    try expectMutationProblem(image, GrantRules{ .index = 2, .value = table.rules_per_grant_max + 1 }, .grant_rules);
    // The last grant claims a rule past the last one.
    try expectMutationProblem(image, GrantRules{ .index = 2, .value = 3 }, .rule_total);
    // The last grant leaves its last rule to no grant.
    try expectMutationProblem(image, GrantRules{ .index = 2, .value = 1 }, .rule_total);

    try expectMutationProblem(image, RuleByte{ .index = 5, .field_offset = kind_offset, .value = 9 }, .rule_kind);
    try expectMutationProblem(image, RuleByte{ .index = 0, .field_offset = name_len_offset, .value = 1 }, .rule_unused);
    try expectMutationProblem(image, RuleByte{ .index = 0, .field_offset = address_offset, .value = 1 }, .rule_unused);
    try expectMutationProblem(image, RuleByte{ .index = 1, .field_offset = address_offset + 15, .value = 1 }, .rule_unused);
    try expectMutationProblem(image, RuleByte{ .index = 4, .field_offset = address_offset + 4, .value = 1 }, .rule_unused);
    try expectMutationProblem(image, RuleByte{ .index = 4, .field_offset = name_len_offset, .value = 1 }, .rule_unused);
    try expectMutationProblem(image, RuleByte{ .index = 5, .field_offset = name_len_offset, .value = 1 }, .rule_unused);
    try expectMutationProblem(image, RulePort{ .index = 0, .value = 443 }, .rule_port);
    try expectMutationProblem(image, NameByte{ .offset = 0, .value = 'A' }, .rule_name);
    try expectMutationProblem(image, NameByte{ .offset = 0, .value = '.' }, .rule_name);
    try expectMutationProblem(image, RuleByte{ .index = 3, .field_offset = name_len_offset, .value = 0 }, .rule_name);
    // 93.184.216.34 becomes 127.184.216.34, a loopback address.
    try expectMutationProblem(image, RuleByte{ .index = 4, .field_offset = address_offset, .value = 127 }, .rule_address);
    // 2606:4700::1111 becomes ff06:4700::1111, a multicast address.
    try expectMutationProblem(image, RuleByte{ .index = 5, .field_offset = address_offset, .value = 0xff }, .rule_address);
    try expectMutationProblem(image, RuleAddressSwap{ .left = 7, .right = 8 }, .rule_order);
    try expectMutationProblem(image, RuleAddressCopy{ .source = 7, .target = 8 }, .rule_order);
    try expectMutationProblem(image, RulePort{ .index = 2, .value = 0 }, .rule_order);
    // `internal.example`, the last name, claims a byte past the name bytes.
    try expectMutationProblem(image, RuleByte{ .index = 6, .field_offset = name_len_offset, .value = 17 }, .name_total);

    try expectMutationProblem(image, GrantByte{ .index = 1, .field_offset = private_offset, .value = 0 }, .private_address);
    try expectMutationProblem(image, GrantByte{ .index = 2, .field_offset = private_offset, .value = 1 }, .private_unused);

    try expectMutationProblem(image, PolicyMembers{ .index = 0, .value = 1 }, .policy_zero);
    try expectMutationProblem(image, PolicyMembers{ .index = 1, .value = 0 }, .policy_members);
    try expectMutationProblem(
        image,
        PolicyMembers{ .index = 1, .value = table.members_per_policy_max + 1 },
        .policy_members,
    );
    // The last policy claims a member past the last one.
    try expectMutationProblem(image, PolicyMembers{ .index = 4, .value = 2 }, .member_total);
    // The union gives up a member, which then belongs to no policy.
    try expectMutationProblem(image, PolicyMembers{ .index = 3, .value = 1 }, .member_total);
    try expectMutationProblem(image, Member{ .index = 2, .value = 1 }, .member_order);
    try expectMutationProblem(image, Member{ .index = 3, .value = 0 }, .member_order);
    try expectMutationProblem(image, Member{ .index = 4, .value = 3 }, .member_grant);
}

test "a length that disagrees with the counts is refused" {
    const image = try buildReference(gpa);
    defer gpa.free(image);

    const longer = try gpa.alloc(u8, image.len + 1);
    defer gpa.free(longer);
    @memcpy(longer[0..image.len], image);
    longer[image.len] = 'x';
    try expectProblem(longer, .length);

    const shorter = try gpa.dupe(u8, image[0 .. image.len - 1]);
    defer gpa.free(shorter);
    try expectProblem(shorter, .length);

    // Counted name bytes that no rule claims.
    putU32(longer, @offsetOf(table.Header, "name_bytes"), reference_name_bytes + 1);
    try expectProblem(longer, .name_total);
}

test "an image shorter than a header is truncated, and a changed magic byte is refused" {
    const image = try buildReference(gpa);
    defer gpa.free(image);
    const copy = try gpa.dupe(u8, image);
    defer gpa.free(copy);

    for (0..table.magic.len) |index| {
        copy[index] ^= 0x01;
        try expectProblem(copy, .magic);
        copy[index] ^= 0x01;
    }
    try std.testing.expectEqual(@as(?Problem, null), table.check(copy));

    try expectProblem(image[0 .. @sizeOf(table.Header) - 1], .truncated);
    try expectProblem(&.{}, .truncated);
    try std.testing.expectError(error.InvalidPolicyImage, network.Table.decode(gpa, image[0..10]));
}

fn buildAndEncode(allocator: std.mem.Allocator) !void {
    const image = try buildReference(allocator);
    allocator.free(image);
}

fn decodeAndFree(allocator: std.mem.Allocator, image: []const u8) !void {
    var decoded = try network.Table.decode(allocator, image);
    decoded.deinit(allocator);
}

test "the builder and the decoder free everything when any allocation fails" {
    try std.testing.checkAllAllocationFailures(gpa, buildAndEncode, .{});

    const image = try buildReference(gpa);
    defer gpa.free(image);
    try std.testing.checkAllAllocationFailures(gpa, decodeAndFree, .{image});
}
