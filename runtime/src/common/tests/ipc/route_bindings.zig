//! A route's bindings section (`common/ipc/route_bindings.zig`): the name
//! grammar, the encoder's checks on its input, the round trip, and the
//! decode that re-checks every rule on bytes the encoder would refuse. The
//! route table that carries one section per route is covered by
//! `route_table.zig`, the worker building `env` from a section by
//! `worker/tests/runtime/env.zig`, and WorkerInit delivering it by
//! local-e2e.

const std = @import("std");
const ipc = @import("collo_ipc");

const route_bindings = ipc.route_bindings;
const Entry = route_bindings.Entry;

/// `entries` encoded as the route table builder writes a route's section;
/// the caller frees the result.
fn encodeSection(entries: []const Entry) ![]u8 {
    const bytes = try std.testing.allocator.alloc(u8, try route_bindings.encodedLen(entries));
    route_bindings.encode(bytes, entries);
    return bytes;
}

test "binding names are identifiers within the name bound" {
    try std.testing.expect(route_bindings.isBindingName("SECRET"));
    try std.testing.expect(route_bindings.isBindingName("_private"));
    try std.testing.expect(route_bindings.isBindingName("a1_B2"));
    try std.testing.expect(route_bindings.isBindingName("x" ** route_bindings.name_bytes_max));

    try std.testing.expect(!route_bindings.isBindingName(""));
    try std.testing.expect(!route_bindings.isBindingName("1NAME"));
    try std.testing.expect(!route_bindings.isBindingName("has-dash"));
    try std.testing.expect(!route_bindings.isBindingName("dot.name"));
    try std.testing.expect(!route_bindings.isBindingName("x" ** (route_bindings.name_bytes_max + 1)));
}

test "an encoded section decodes to its entries in order" {
    const entries = [_]Entry{
        .{ .name = "SECRET", .value = "s3cr3t" },
        .{ .name = "GREETING", .value = "olá" },
        .{ .name = "EMPTY", .value = "" },
    };
    const bytes = try encodeSection(&entries);
    defer std.testing.allocator.free(bytes);

    var storage: route_bindings.Entries = undefined;
    const decoded = try route_bindings.decode(bytes, &storage);
    try std.testing.expectEqual(entries.len, decoded.len);
    for (entries, decoded) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqualStrings(expected.value, actual.value);
    }
}

test "a route without bindings gets the empty section" {
    const bytes = try encodeSection(&.{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &route_bindings.empty_blob, bytes);
}

test "the encoder refuses entries a worker would refuse" {
    var too_many: [route_bindings.entries_max + 1]Entry = undefined;
    var names: [too_many.len][8]u8 = undefined;
    for (&too_many, &names, 0..) |*entry, *name, index|
        entry.* = .{ .name = try std.fmt.bufPrint(name, "B{d}", .{index}), .value = "v" };
    const oversized = try std.testing.allocator.alloc(u8, route_bindings.bytes_max);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'v');

    const cases = [_][]const Entry{
        &.{.{ .name = "1NAME", .value = "v" }},
        &.{ .{ .name = "TWICE", .value = "a" }, .{ .name = "TWICE", .value = "b" } },
        &.{.{ .name = "BYTES", .value = "\xff\xfe" }},
        &too_many,
        &.{.{ .name = "BIG", .value = oversized }},
    };
    for (cases) |entries|
        try std.testing.expectError(error.InvalidRouteBindings, route_bindings.encodedLen(entries));
}

test "decode refuses truncated, oversized and trailing layouts" {
    var storage: route_bindings.Entries = undefined;
    const cases = [_][]const u8{
        // Shorter than the count.
        &.{ 0, 0 },
        &.{},
        // A count with no entry behind it.
        &.{ 1, 0, 0, 0 },
        // A name length past the end.
        &.{ 1, 0, 0, 0, 200, 0, 0, 0, 'A' },
        // A byte after the last entry.
        &.{ 0, 0, 0, 0, 0 },
        // An entry count above `entries_max`.
        &.{ 0xff, 0xff, 0, 0 },
        // A name outside the grammar: one entry "1" = "v".
        &.{ 1, 0, 0, 0, 1, 0, 0, 0, '1', 1, 0, 0, 0, 'v' },
    };
    for (cases) |bytes|
        try std.testing.expectError(error.InvalidRouteBindings, route_bindings.decode(bytes, &storage));
}
