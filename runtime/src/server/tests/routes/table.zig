//! The route table (`server/routes/table.zig`) over hand-built definitions:
//! match priority and backtracking, the wildcard's empty rest and the root
//! pattern, captures that borrow the path, the path depth bound, duplicate
//! and invalid patterns, the route bound, a table of the largest allowed
//! size, and allocation failure while building.

const std = @import("std");
const config = @import("collo_server_config");
const routes = @import("collo_server_routes");
const server_limits = @import("collo_limits").server;

const Table = routes.Table;

fn single(comptime name: []const u8, comptime route_pattern: []const u8) config.WorkerDefinition {
    return .{
        .name = name,
        .settings = config.default_settings,
        .routes = &.{.{ .pattern = route_pattern, .entry_path = "/srv/" ++ name ++ ".js", .bindings = &.{} }},
    };
}

fn expectKey(matched: routes.Match, definition: config.DefinitionIndex, route: config.RouteIndex) !void {
    try std.testing.expectEqual(config.RouteKey{ .definition = definition, .route = route }, matched.key);
}

/// `count` definitions of one route each, `/route/<index>`.
const Generated = struct {
    definitions: []config.WorkerDefinition,
    routes: []config.Route,
    patterns: [][]u8,

    fn init(allocator: std.mem.Allocator, count: usize) !Generated {
        const definitions = try allocator.alloc(config.WorkerDefinition, count);
        errdefer allocator.free(definitions);
        const route_list = try allocator.alloc(config.Route, count);
        errdefer allocator.free(route_list);
        const patterns = try allocator.alloc([]u8, count);
        errdefer allocator.free(patterns);
        var initialized: usize = 0;
        errdefer for (patterns[0..initialized]) |item| allocator.free(item);
        for (definitions, route_list, patterns, 0..) |*definition, *route, *route_pattern, index| {
            route_pattern.* = try std.fmt.allocPrint(allocator, "/route/{d}", .{index});
            initialized += 1;
            route.* = .{ .pattern = route_pattern.*, .entry_path = "/srv/app.js", .bindings = &.{} };
            definition.* = .{
                .name = "generated",
                .settings = config.default_settings,
                .routes = route_list[index..][0..1],
            };
        }
        return .{ .definitions = definitions, .routes = route_list, .patterns = patterns };
    }

    fn deinit(self: *Generated, allocator: std.mem.Allocator) void {
        for (self.patterns) |item|
            allocator.free(item);
        allocator.free(self.patterns);
        allocator.free(self.routes);
        allocator.free(self.definitions);
        self.* = undefined;
    }
};

test "a static segment beats a parameter, which beats the wildcard" {
    const definitions = [_]config.WorkerDefinition{
        single("param", "/hello/:name"),
        single("static", "/hello/world"),
        single("wild", "/hello/*"),
    };
    var table: Table = undefined;
    try table.init(std.testing.allocator, &definitions);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    const static_match = (try table.match("/hello/world", &captures)).?;
    try expectKey(static_match, 1, 0);
    try std.testing.expectEqualStrings("/hello/world", static_match.pattern);
    try std.testing.expectEqual(@as(usize, 0), static_match.captures.len);

    const param_match = (try table.match("/hello/alice", &captures)).?;
    try expectKey(param_match, 0, 0);
    try std.testing.expectEqualStrings("/hello/:name", param_match.pattern);
    try std.testing.expectEqual(@as(usize, 1), param_match.captures.len);
    try std.testing.expectEqualStrings("name", param_match.captures[0].name);
    try std.testing.expectEqualStrings("alice", param_match.captures[0].value);

    const wildcard_match = (try table.match("/hello/alice/profile", &captures)).?;
    try expectKey(wildcard_match, 2, 0);
    try std.testing.expectEqual(@as(usize, 0), wildcard_match.captures.len);
}

test "a static branch that dead-ends backtracks into the parameter branch" {
    const definitions = [_]config.WorkerDefinition{
        single("static", "/a/b/c"),
        single("param", "/a/:x/d"),
    };
    var table: Table = undefined;
    try table.init(std.testing.allocator, &definitions);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    const matched = (try table.match("/a/b/d", &captures)).?;
    try expectKey(matched, 1, 0);
    try std.testing.expectEqualStrings("x", matched.captures[0].name);
    try std.testing.expectEqualStrings("b", matched.captures[0].value);
    try expectKey((try table.match("/a/b/c", &captures)).?, 0, 0);
    try std.testing.expect((try table.match("/a/b", &captures)) == null);
}

test "the wildcard matches the rest of the path, including an empty rest" {
    const definitions = [_]config.WorkerDefinition{
        single("assets", "/assets/*"),
        single("hello", "/hello/*"),
    };
    var table: Table = undefined;
    try table.init(std.testing.allocator, &definitions);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    try std.testing.expect((try table.match("/assetsx", &captures)) == null);
    try expectKey((try table.match("/hello/a", &captures)).?, 1, 0);
    try expectKey((try table.match("/hello/a/b", &captures)).?, 1, 0);
    try expectKey((try table.match("/hello", &captures)).?, 1, 0);
    try expectKey((try table.match("/hello/", &captures)).?, 1, 0);
    try std.testing.expect((try table.match("/", &captures)) == null);
}

test "the root pattern matches only the root and the catch-all matches every path" {
    const both = [_]config.WorkerDefinition{
        single("root", "/"),
        single("rest", "/*"),
    };
    var table: Table = undefined;
    try table.init(std.testing.allocator, &both);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;
    try expectKey((try table.match("/", &captures)).?, 0, 0);
    try expectKey((try table.match("", &captures)).?, 0, 0);
    try expectKey((try table.match("/x", &captures)).?, 1, 0);
    try expectKey((try table.match("/x/y/z", &captures)).?, 1, 0);

    const catch_all = [_]config.WorkerDefinition{single("rest", "/*")};
    var catch_all_table: Table = undefined;
    try catch_all_table.init(std.testing.allocator, &catch_all);
    defer catch_all_table.deinit(std.testing.allocator);
    try expectKey((try catch_all_table.match("/", &captures)).?, 0, 0);
    try expectKey((try catch_all_table.match("/any/path", &captures)).?, 0, 0);
}

test "captures borrow the request path and empty segments are skipped" {
    const definitions = [_]config.WorkerDefinition{single("users", "/users/:id/files/:file")};
    var table: Table = undefined;
    try table.init(std.testing.allocator, &definitions);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    const path = "//users//42/files/report.pdf/";
    const matched = (try table.match(path, &captures)).?;
    try std.testing.expectEqual(@as(usize, 2), matched.captures.len);
    try std.testing.expectEqualStrings("id", matched.captures[0].name);
    try std.testing.expectEqualStrings("42", matched.captures[0].value);
    try std.testing.expectEqualStrings("file", matched.captures[1].name);
    try std.testing.expectEqualStrings("report.pdf", matched.captures[1].value);
    const path_start = @intFromPtr(path.ptr);
    const value_start = @intFromPtr(matched.captures[1].value.ptr);
    try std.testing.expect(value_start >= path_start and value_start < path_start + path.len);
    try std.testing.expectEqual(@intFromPtr(&captures), @intFromPtr(matched.captures.ptr));
}

test "a path deeper than the segment bound fails before the walk" {
    const definitions = [_]config.WorkerDefinition{single("rest", "/*")};
    var table: Table = undefined;
    try table.init(std.testing.allocator, &definitions);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    const deepest = "/a" ** routes.table.path_segments_max;
    try expectKey((try table.match(deepest, &captures)).?, 0, 0);
    try std.testing.expectError(error.PathTooDeep, table.match(deepest ++ "/a", &captures));
}

test "duplicate, invalid and too many routes are rejected at build" {
    const allocator = std.testing.allocator;
    var table: Table = undefined;

    const same_shape = [_]config.WorkerDefinition{ single("first", "/dup/:id"), single("second", "/dup/:name") };
    try std.testing.expectError(error.DuplicateRoute, table.init(allocator, &same_shape));
    const same_static = [_]config.WorkerDefinition{ single("first", "/x"), single("second", "/x") };
    try std.testing.expectError(error.DuplicateRoute, table.init(allocator, &same_static));
    const same_wildcard = [_]config.WorkerDefinition{ single("first", "/x/*"), single("second", "/x/*") };
    try std.testing.expectError(error.DuplicateRoute, table.init(allocator, &same_wildcard));
    const invalid = [_]config.WorkerDefinition{single("bad", "/bad*")};
    try std.testing.expectError(error.InvalidRoutePattern, table.init(allocator, &invalid));

    var generated = try Generated.init(allocator, server_limits.routes_max + 1);
    defer generated.deinit(allocator);
    try std.testing.expectError(error.TooManyRoutes, table.init(allocator, generated.definitions));
}

test "a table of the largest allowed size matches its last route" {
    const allocator = std.testing.allocator;
    var generated = try Generated.init(allocator, server_limits.routes_max);
    defer generated.deinit(allocator);
    var table: Table = undefined;
    try table.init(allocator, generated.definitions);
    defer table.deinit(allocator);
    var captures: routes.Captures = undefined;

    try std.testing.expect(table.nodes.len > server_limits.routes_max);
    try std.testing.expect(table.nodes.len <= routes.table.node_count_max);
    const last = (try table.match("/route/255", &captures)).?;
    try expectKey(last, server_limits.routes_max - 1, 0);
    try std.testing.expect((try table.match("/route/256", &captures)) == null);
}

fn buildTable(allocator: std.mem.Allocator) !void {
    const definitions = [_]config.WorkerDefinition{
        single("param", "/hello/:name"),
        single("static", "/hello/world"),
        single("wild", "/hello/*"),
        single("root", "/"),
    };
    var table: Table = undefined;
    try table.init(allocator, &definitions);
    table.deinit(allocator);
}

test "building frees everything when any allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildTable, .{});
}
