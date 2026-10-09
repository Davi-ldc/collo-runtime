//! The route pattern grammar (`server/config/pattern.zig`): the patterns it
//! accepts, the problem it reports for each kind of rejected pattern, the
//! paths the server keeps for itself, the segment classification the route
//! table builds from, and when two patterns match the same paths.

const std = @import("std");
const config = @import("collo_server_config");
const server_limits = @import("collo_limits").server;

const pattern = config.pattern;

test "patterns that follow the grammar are accepted" {
    const valid = [_][]const u8{
        "/",          "/*",              "/a",           "/a/b",
        "/users/:id", "/static/*",       "/a/:b/c/*",    "/v1.0/x",
        "/a:b",       "/:first/:second", "/%7Euser",     "/a-b_c~d",
        // Neighbors of the reserved prefix are ordinary paths.
        "/healthz",   "/__collox",       "/a/__collo/b",
    };
    for (valid) |text| {
        if (pattern.validate(text)) |problem| {
            std.debug.print("{s}: {s}\n", .{ text, problem.describe() });
            return error.TestUnexpectedProblem;
        }
    }
}

test "each rejected pattern names its problem" {
    const Case = struct { text: []const u8, problem: pattern.Problem };
    const cases = [_]Case{
        .{ .text = "", .problem = .missing_leading_slash },
        .{ .text = "users", .problem = .missing_leading_slash },
        .{ .text = "//", .problem = .empty_segment },
        .{ .text = "/a/", .problem = .empty_segment },
        .{ .text = "/a//b", .problem = .empty_segment },
        .{ .text = "/*/a", .problem = .wildcard_not_last },
        .{ .text = "/a*", .problem = .partial_wildcard },
        .{ .text = "/a/*b", .problem = .partial_wildcard },
        .{ .text = "/:", .problem = .invalid_param_name },
        .{ .text = "/:1a", .problem = .invalid_param_name },
        .{ .text = "/:a-b", .problem = .invalid_param_name },
        .{ .text = "/:a/:a", .problem = .duplicate_param_name },
        .{ .text = "/.", .problem = .dot_segment },
        .{ .text = "/a/..", .problem = .dot_segment },
        .{ .text = "/a b", .problem = .invalid_character },
        .{ .text = "/a?b", .problem = .invalid_character },
        .{ .text = "/a#b", .problem = .invalid_character },
        .{ .text = "/a\\b", .problem = .invalid_character },
        .{ .text = "/\xc3\xa9", .problem = .invalid_character },
        .{ .text = pattern.health_path, .problem = .reserved_prefix },
        .{ .text = "/__collo", .problem = .reserved_prefix },
        .{ .text = "/__collo/x", .problem = .reserved_prefix },
        .{ .text = "/__collo/*", .problem = .reserved_prefix },
        .{ .text = "/__collo/:name/a b", .problem = .reserved_prefix },
    };
    for (cases) |case| {
        const problem = pattern.validate(case.text) orelse {
            std.debug.print("{s}: accepted\n", .{case.text});
            return error.TestExpectedProblem;
        };
        try std.testing.expectEqual(case.problem, problem);
    }
}

test "a path is the server's when its first segment is the reserved one, however its slashes fall" {
    const reserved = [_][]const u8{
        pattern.health_path, "/__collo",  "/__collo/",         "/__collo/x/y",
        "//__collo/x",       "__collo/x", "/__collo//healthz",
    };
    for (reserved) |path| {
        if (!pattern.isReserved(path)) {
            std.debug.print("{s}: not reserved\n", .{path});
            return error.TestExpectedReserved;
        }
    }
    const outside = [_][]const u8{ "", "/", "//", "/healthz", "/__collox", "/a/__collo", "/__coll" };
    for (outside) |path| {
        if (pattern.isReserved(path)) {
            std.debug.print("{s}: reserved\n", .{path});
            return error.TestUnexpectedReserved;
        }
    }
}

test "the segment and byte bounds are enforced at their edges" {
    const deepest = "/a" ** server_limits.route_path_segments_max;
    try std.testing.expectEqual(@as(?pattern.Problem, null), pattern.validate(deepest));
    try std.testing.expectEqual(@as(?pattern.Problem, .too_many_segments), pattern.validate(deepest ++ "/a"));

    const longest = "/" ++ "a" ** (server_limits.route_pattern_bytes_max - 1);
    try std.testing.expectEqual(@as(?pattern.Problem, null), pattern.validate(longest));
    try std.testing.expectEqual(@as(?pattern.Problem, .too_long), pattern.validate(longest ++ "a"));
}

test "segments classify static, parameter and wildcard segments" {
    var segments = pattern.segments("/users/:id/files/*");
    try std.testing.expectEqualStrings("users", segments.next().?.static);
    try std.testing.expectEqualStrings("id", segments.next().?.param);
    try std.testing.expectEqualStrings("files", segments.next().?.static);
    try std.testing.expect(segments.next().? == .wildcard);
    try std.testing.expect(segments.next() == null);

    var root = pattern.segments("/");
    try std.testing.expect(root.next() == null);
}

test "sameShape ignores parameter names and nothing else" {
    try std.testing.expect(pattern.sameShape("/u/:id", "/u/:name"));
    try std.testing.expect(pattern.sameShape("/a/*", "/a/*"));
    try std.testing.expect(pattern.sameShape("/", "/"));
    try std.testing.expect(!pattern.sameShape("/u/:id", "/u/me"));
    try std.testing.expect(!pattern.sameShape("/a", "/a/*"));
    try std.testing.expect(!pattern.sameShape("/", "/*"));
    try std.testing.expect(!pattern.sameShape("/a/:b", "/a/*"));
    try std.testing.expect(!pattern.sameShape("/a/b", "/a/c"));
}
