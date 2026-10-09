//! The route table (`common/ipc/route_table.zig`): the builder's checks on
//! its input, the round trip through the sealed memfd, and the decode that
//! re-checks every rule on bytes the builder would refuse. The worker
//! serving a table's routes is covered by `worker/tests/runtime/routes.zig`,
//! and WorkerInit delivering one by local-e2e.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

const route_table = ipc.route_table;
const route_bindings = ipc.route_bindings;

/// The bytes of a sealed table, read back the way a worker sees them.
fn readSealed(sealed: route_table.Sealed) ![]u8 {
    const bytes = try std.testing.allocator.alloc(u8, @intCast(sealed.blob_len));
    errdefer std.testing.allocator.free(bytes);
    if (try std.posix.pread(sealed.fd, bytes, 0) != bytes.len)
        return error.ShortTableRead;
    return bytes;
}

test "a built table is sealed read-only and decodes to its routes and their bindings in order" {
    const routes = [_]route_table.RouteInput{
        .{ .entry_specifier = "/__collo_route/shop/cart.js", .bindings = &.{
            .{ .name = "SECRET", .value = "s3cr3t" },
            .{ .name = "GREETING", .value = "olá" },
        } },
        .{ .entry_specifier = "/__collo_route/shop/admin/index.js", .bindings = &.{} },
        // Two routes may share an entry, each with bindings of its own.
        .{ .entry_specifier = "/__collo_route/shop/cart.js", .bindings = &.{
            .{ .name = "SECRET", .value = "other" },
        } },
    };
    const sealed = try route_table.buildSealed(std.testing.allocator, &routes);
    defer sealed.close();
    try fd_mod.requireSeals(sealed.fd, fd_mod.memfd_readonly_seals);
    const bytes = try readSealed(sealed);
    defer std.testing.allocator.free(bytes);

    var storage: route_table.Routes = undefined;
    const decoded = try route_table.decode(bytes, &storage);
    try std.testing.expectEqual(routes.len, decoded.len);
    for (routes, decoded) |expected, actual| {
        try std.testing.expectEqualStrings(expected.entry_specifier, actual.entry_specifier);
        var entries: route_bindings.Entries = undefined;
        const bindings = try route_bindings.decode(actual.bindings, &entries);
        try std.testing.expectEqual(expected.bindings.len, bindings.len);
        for (expected.bindings, bindings) |expected_binding, binding| {
            try std.testing.expectEqualStrings(expected_binding.name, binding.name);
            try std.testing.expectEqualStrings(expected_binding.value, binding.value);
        }
    }
}

test "a worker that serves no route gets the empty table" {
    const empty = try route_table.createEmptySealed();
    defer empty.close();
    const built = try route_table.buildSealed(std.testing.allocator, &.{});
    defer built.close();
    for ([_]route_table.Sealed{ empty, built }) |sealed| {
        const bytes = try readSealed(sealed);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, &route_table.empty_blob, bytes);
        var storage: route_table.Routes = undefined;
        try std.testing.expectEqual(@as(usize, 0), (try route_table.decode(bytes, &storage)).len);
    }
}

test "a table holds every route a definition may declare" {
    var routes: [route_table.routes_max]route_table.RouteInput = undefined;
    var specifiers: [routes.len][48]u8 = undefined;
    for (&routes, &specifiers, 0..) |*route, *specifier, index|
        route.* = .{
            .entry_specifier = try std.fmt.bufPrint(specifier, "/__collo_route/many/route{d}.js", .{index}),
            .bindings = &.{.{ .name = "INDEX", .value = "v" }},
        };
    const sealed = try route_table.buildSealed(std.testing.allocator, &routes);
    defer sealed.close();
    const bytes = try readSealed(sealed);
    defer std.testing.allocator.free(bytes);
    var storage: route_table.Routes = undefined;
    const decoded = try route_table.decode(bytes, &storage);
    try std.testing.expectEqual(routes.len, decoded.len);
    try std.testing.expectEqualStrings("/__collo_route/many/route63.js", decoded[decoded.len - 1].entry_specifier);
}

test "the builder refuses routes a worker would refuse" {
    var too_many: [route_table.routes_max + 1]route_table.RouteInput = undefined;
    for (&too_many) |*route|
        route.* = .{ .entry_specifier = "/__collo_route/w/a.js", .bindings = &.{} };
    const long_specifier = try std.testing.allocator.alloc(u8, route_table.entry_specifier_bytes_max + 1);
    defer std.testing.allocator.free(long_specifier);
    @memset(long_specifier, 'a');
    long_specifier[0] = '/';

    const cases = [_][]const route_table.RouteInput{
        &too_many,
        &.{.{ .entry_specifier = "", .bindings = &.{} }},
        &.{.{ .entry_specifier = "relative.js", .bindings = &.{} }},
        &.{.{ .entry_specifier = "/__collo_route/w/../escape.js", .bindings = &.{} }},
        &.{.{ .entry_specifier = long_specifier, .bindings = &.{} }},
        &.{.{ .entry_specifier = "/__collo_route/w/a.js", .bindings = &.{.{ .name = "1NAME", .value = "v" }} }},
        &.{.{ .entry_specifier = "/__collo_route/w/a.js", .bindings = &.{
            .{ .name = "TWICE", .value = "a" },
            .{ .name = "TWICE", .value = "b" },
        } }},
    };
    for (cases) |routes|
        try std.testing.expectError(error.InvalidRouteTable, route_table.buildSealed(std.testing.allocator, routes));
}

test "decode refuses truncated, oversized, malformed and trailing layouts" {
    var storage: route_table.Routes = undefined;
    const cases = [_][]const u8{
        // Shorter than the count.
        &.{},
        &.{ 1, 0 },
        // A count with no route behind it.
        &.{ 1, 0, 0, 0 },
        // A specifier length past the end.
        &.{ 1, 0, 0, 0, 200, 0, 0, 0, '/' },
        // A route count above `routes_max`.
        &.{ 0xff, 0, 0, 0 },
        // A byte after the last route.
        &.{ 0, 0, 0, 0, 0 },
        // A specifier that is not absolute: "a", then the empty bindings.
        &.{ 1, 0, 0, 0, 1, 0, 0, 0, 'a', 4, 0, 0, 0, 0, 0, 0, 0 },
        // A valid specifier "/a" whose bindings section is cut short.
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, '/', 'a', 2, 0, 0, 0, 0, 0 },
        // A valid specifier "/a" whose bindings section names "1" = "v".
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, '/', 'a', 14, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, '1', 1, 0, 0, 0, 'v' },
    };
    for (cases) |bytes|
        try std.testing.expectError(error.InvalidRouteTable, route_table.decode(bytes, &storage));

    // One byte past the largest table a worker accepts, refused before any
    // field is read.
    const oversized = try std.testing.allocator.alloc(u8, route_table.bytes_max + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.InvalidRouteTable, route_table.decode(oversized, &storage));
}
