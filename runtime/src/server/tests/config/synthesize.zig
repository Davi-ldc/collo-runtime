//! The configuration synthesized for an entry module
//! (`server/config/synthesize.zig`): one worker named after the file's stem
//! with one catch-all route and every global default, the worker name
//! derivation, and relative entry paths. The routes built from it are
//! covered in `tests/routes/artifacts.zig`.

const std = @import("std");
const config = @import("collo_server_config");
const server_limits = @import("collo_limits").server;

test "an entry module becomes one worker with one catch-all route" {
    var diagnostic: config.Diagnostic = .{};
    var synthesized = try config.synthesize(std.testing.allocator, "/srv/app/../site/Hello World.mjs", &diagnostic);
    defer synthesized.deinit();

    try std.testing.expectEqualStrings("/srv/site/Hello World.mjs", synthesized.path);
    try std.testing.expect(synthesized.listen.eql(try config.parseListen(config.default_listen)));
    try std.testing.expect(synthesized.tls == null);
    try std.testing.expect(synthesized.analytics == null);
    try std.testing.expectEqual(config.default_settings, synthesized.defaults);
    try std.testing.expectEqual(@as(u16, 1), synthesized.route_count);
    try std.testing.expectEqual(@as(usize, 1), synthesized.definitions.len);

    const definition = synthesized.definitions[0];
    try std.testing.expectEqualStrings("hello-world", definition.name);
    try std.testing.expectEqual(config.default_settings, definition.settings);
    try std.testing.expectEqual(@as(usize, 1), definition.routes.len);
    try std.testing.expectEqualStrings(config.synthesized_route_pattern, definition.routes[0].pattern);
    try std.testing.expectEqualStrings("/*", definition.routes[0].pattern);
    try std.testing.expectEqualStrings("/srv/site/Hello World.mjs", definition.routes[0].entry_path);
    try std.testing.expectEqual(@as(usize, 0), definition.routes[0].bindings.len);
    try std.testing.expectEqual(@as(?config.pattern.Problem, null), config.pattern.validate(definition.routes[0].pattern));
}

test "the worker name is the stem lowercased with invalid bytes replaced" {
    const allocator = std.testing.allocator;
    const Case = struct { path: []const u8, name: []const u8 };
    const long_stem = "a" ** (server_limits.worker_name_bytes_max + 10);
    const cases = [_]Case{
        .{ .path = "/x/app.js", .name = "app" },
        .{ .path = "/x/My_App.JS", .name = "my-app" },
        .{ .path = "/x/server.min.js", .name = "server-min" },
        .{ .path = "/x/@@@.js", .name = "---" },
        .{ .path = "/x/.js", .name = "-js" },
        .{ .path = "/x/handler", .name = "handler" },
        .{ .path = "/x/" ++ long_stem ++ ".js", .name = "a" ** server_limits.worker_name_bytes_max },
        .{ .path = "/", .name = config.synthesized_fallback_worker_name },
    };
    for (cases) |case| {
        const name = try config.workerName(allocator, case.path);
        defer allocator.free(name);
        try std.testing.expectEqualStrings(case.name, name);
        try std.testing.expect(config.isWorkerName(name));
    }
}

test "a relative entry resolves against the working directory" {
    const allocator = std.testing.allocator;
    const working_directory = try std.process.getCwdAlloc(allocator);
    defer allocator.free(working_directory);
    const expected = try std.fs.path.resolvePosix(allocator, &.{ working_directory, "src/app.js" });
    defer allocator.free(expected);

    var diagnostic: config.Diagnostic = .{};
    var synthesized = try config.synthesize(allocator, "./src/app.js", &diagnostic);
    defer synthesized.deinit();
    try std.testing.expectEqualStrings(expected, synthesized.definitions[0].routes[0].entry_path);

    try std.testing.expectError(error.InvalidConfig, config.synthesize(allocator, "", &diagnostic));
    try std.testing.expectEqualStrings("the entry module path is empty", diagnostic.message());
}
