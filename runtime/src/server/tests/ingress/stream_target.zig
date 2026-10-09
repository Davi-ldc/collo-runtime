//! How a lane classifies a new stream (`streamTarget` in
//! `ingress/runner/admission.zig`): the server's own paths ahead of every
//! route, the health path among them, a path no route matches, a path deeper
//! than any pattern, and a match that depends on the path alone. Responses
//! written for each class, and the access record of a 404, are covered by
//! local-e2e. Lane: server-ingress-test.

const std = @import("std");
const server_main = @import("collo_server_main");
const config = @import("collo_server_config");
const routes = @import("collo_server_routes");
const server_limits = @import("collo_limits").server;

const admission = server_main.ingress.runner.admission;

const catch_all = [_]config.WorkerDefinition{.{
    .name = "app",
    .settings = config.default_settings,
    .routes = &.{.{ .pattern = "/*", .entry_path = "/srv/app.js", .bindings = &.{} }},
}};

const two_routes = [_]config.WorkerDefinition{
    .{
        .name = "users",
        .settings = config.default_settings,
        .routes = &.{.{ .pattern = "/users/:id", .entry_path = "/srv/users.js", .bindings = &.{} }},
    },
    .{
        .name = "assets",
        .settings = config.default_settings,
        .routes = &.{.{ .pattern = "/static/*", .entry_path = "/srv/assets.js", .bindings = &.{} }},
    },
};

fn buildTable(definitions: []const config.WorkerDefinition) !routes.Table {
    var table: routes.Table = undefined;
    try table.init(std.testing.allocator, definitions);
    return table;
}

test "the paths under the reserved prefix are the server's even when a catch-all route matches every other path" {
    var table = try buildTable(&catch_all);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    try std.testing.expect(admission.streamTarget(&table, config.pattern.health_path, &captures) == .health);
    // Every other path under the prefix is the server's too, and has no
    // answer, however its slashes fall.
    const reserved = [_][]const u8{
        "/__collo",
        "/__collo/",
        "/__collo/other",
        "/__collo/healthz/",
        "/__collo/healthz/live",
        "/__collo/healthzz",
        "//__collo/healthz",
        "/__collo//healthz",
    };
    for (reserved) |path|
        try std.testing.expect(admission.streamTarget(&table, path, &captures) == .not_found);
    // Paths outside the prefix reach the route, those that only look like it
    // included.
    const outside = [_][]const u8{
        "/",
        "/healthz",
        "/__collox",
        "/__collox/healthz",
        "/api/__collo/healthz",
    };
    for (outside) |path| {
        const target = admission.streamTarget(&table, path, &captures);
        try std.testing.expect(target == .matched);
        try std.testing.expectEqualStrings("/*", target.matched.pattern);
    }
}

test "a path no route matches is not found" {
    var table = try buildTable(&two_routes);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    for ([_][]const u8{ "/", "/users", "/users/1/extra", "/other" }) |path|
        try std.testing.expect(admission.streamTarget(&table, path, &captures) == .not_found);
}

test "a path deeper than any pattern is not found even under a catch-all route" {
    var table = try buildTable(&catch_all);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    const deepest = "/a" ** server_limits.route_path_segments_max;
    try std.testing.expect(admission.streamTarget(&table, deepest, &captures) == .matched);
    try std.testing.expect(admission.streamTarget(&table, deepest ++ "/a", &captures) == .not_found);
}

test "the path alone selects the definition and the captures" {
    var table = try buildTable(&two_routes);
    defer table.deinit(std.testing.allocator);
    var captures: routes.Captures = undefined;

    // `streamTarget` takes no authority, so the same path reaches the same
    // definition whatever host the request names.
    const users = admission.streamTarget(&table, "/users/42", &captures);
    try std.testing.expect(users == .matched);
    try std.testing.expectEqual(config.RouteKey{ .definition = 0, .route = 0 }, users.matched.key);
    try std.testing.expectEqual(@as(usize, 1), users.matched.captures.len);
    try std.testing.expectEqualStrings("id", users.matched.captures[0].name);
    try std.testing.expectEqualStrings("42", users.matched.captures[0].value);

    const assets = admission.streamTarget(&table, "/static/css/site.css", &captures);
    try std.testing.expect(assets == .matched);
    try std.testing.expectEqual(config.RouteKey{ .definition = 1, .route = 0 }, assets.matched.key);
}
