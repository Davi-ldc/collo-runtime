//! The rules a whole `network` setting keeps (`common/network/setting.zig`):
//! repeated entries, private addresses and the two flags, the list bound,
//! and where each refusal points.

const std = @import("std");
const network = @import("collo_network");
const support = @import("support.zig");

const setting = network.setting;
const Violation = setting.Violation;

fn checkSpec(spec: support.Spec) !?Violation {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return setting.check(.{
        .allow = try support.parseAll(arena.allocator(), spec.allow),
        .allow_http = spec.allow_http,
        .allow_private_networks = spec.allow_private_networks,
    });
}

fn expectViolation(spec: support.Spec, expected: Violation) !void {
    const violation = try checkSpec(spec) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, violation);
}

test "a setting whose entries and flags all admit something passes" {
    try std.testing.expectEqual(@as(?Violation, null), try checkSpec(.{
        .allow = &.{ "api.example.com", "*.example.org", "10.0.0.5:8080", "[fd00::1]" },
        .allow_http = true,
        .allow_private_networks = true,
    }));
    try std.testing.expectEqual(@as(?Violation, null), try checkSpec(.{ .allow = &.{"*"} }));
    // One host on two ports is two entries.
    try std.testing.expectEqual(@as(?Violation, null), try checkSpec(.{
        .allow = &.{ "api.example.com", "api.example.com:443" },
    }));
}

test "an empty list without flags passes, which is how a route drops an inherited grant" {
    try std.testing.expectEqual(@as(?Violation, null), try checkSpec(.{ .allow = &.{} }));
}

test "an entry that repeats an earlier one in canonical form is refused at its index" {
    try expectViolation(
        .{ .allow = &.{ "API.example.com", "other.example", "api.example.com." } },
        .{ .problem = .duplicate_entry, .index = 2, .earlier = 0 },
    );
    try expectViolation(
        .{ .allow = &.{ "[2606:4700::1111]", "[2606:4700:0:0:0:0:0:1111]" } },
        .{ .problem = .duplicate_entry, .index = 1, .earlier = 0 },
    );
    try expectViolation(
        .{ .allow = &.{ "*", "*" } },
        .{ .problem = .duplicate_entry, .index = 1, .earlier = 0 },
    );
}

test "a private address needs allowPrivateNetworks" {
    try expectViolation(
        .{ .allow = &.{ "api.example.com", "10.0.0.5" } },
        .{ .problem = .private_address_needs_flag, .index = 1 },
    );
    try expectViolation(
        .{ .allow = &.{"[fd00::1]:8443"} },
        .{ .problem = .private_address_needs_flag, .index = 0 },
    );
    try std.testing.expectEqual(@as(?Violation, null), try checkSpec(.{
        .allow = &.{"10.0.0.5"},
        .allow_private_networks = true,
    }));
}

test "allowPrivateNetworks needs an entry that can reach a private address" {
    // "*" covers public addresses only, and a public address stays public.
    try expectViolation(
        .{ .allow = &.{"*"}, .allow_private_networks = true },
        .{ .problem = .private_flag_unused },
    );
    try expectViolation(
        .{ .allow = &.{ "*", "93.184.216.34" }, .allow_private_networks = true },
        .{ .problem = .private_flag_unused },
    );
    try expectViolation(
        .{ .allow = &.{}, .allow_private_networks = true },
        .{ .problem = .private_flag_unused },
    );
    // A name or a suffix may resolve to a private address.
    try std.testing.expectEqual(@as(?Violation, null), try checkSpec(.{
        .allow = &.{ "*", "internal.example" },
        .allow_private_networks = true,
    }));
    try std.testing.expectEqual(@as(?Violation, null), try checkSpec(.{
        .allow = &.{"*.corp.example"},
        .allow_private_networks = true,
    }));
}

test "allowHttp needs an entry" {
    try expectViolation(.{ .allow = &.{}, .allow_http = true }, .{ .problem = .http_flag_unused });
}

test "a list past entries_max is refused before its entries are compared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const texts = try arena.allocator().alloc([]const u8, setting.entries_max + 1);
    for (texts, 0..) |*text, index|
        text.* = try std.fmt.allocPrint(arena.allocator(), "h{d}.example", .{index});
    const entries = try support.parseAll(arena.allocator(), texts);

    try std.testing.expectEqual(@as(?Violation, null), setting.check(.{ .allow = entries[0..setting.entries_max] }));
    try std.testing.expectEqual(
        Violation{ .problem = .too_many_entries },
        setting.check(.{ .allow = entries }).?,
    );
}

test "every setting problem has a sentence" {
    for (std.enums.values(setting.Problem)) |problem|
        try std.testing.expect(problem.describe().len > 0);
}
