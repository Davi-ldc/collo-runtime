//! The `collo.json` parser (`server/config/parse.zig`): a full configuration
//! with the settings cascade and relative paths, the defaults of a minimal
//! one, comments, file order, rejections and the key path each message
//! names, the server bounds, the listen address grammar, loading from a
//! file, message truncation, and allocation failure at every step. Every
//! kind of rejected route pattern is covered in `pattern.zig`.

const std = @import("std");
const config = @import("collo_server_config");
const server_limits = @import("collo_limits").server;

const config_path = "/srv/app/collo.json";

fn parseOk(source: []const u8) !config.Config {
    var diagnostic: config.Diagnostic = .{};
    return config.parse(std.testing.allocator, source, config_path, &diagnostic) catch |err| {
        std.debug.print("unexpected rejection: {s}\n", .{diagnostic.message()});
        return err;
    };
}

fn expectRejected(source: []const u8, expected: []const u8) !void {
    var diagnostic: config.Diagnostic = .{};
    var result = config.parse(std.testing.allocator, source, config_path, &diagnostic);
    if (result) |*parsed| {
        parsed.deinit();
        return error.TestExpectedRejection;
    } else |err| {
        try std.testing.expectEqual(error.InvalidConfig, err);
    }
    if (std.mem.indexOf(u8, diagnostic.message(), expected) == null) {
        std.debug.print("message: {s}\nexpected it to contain: {s}\n", .{ diagnostic.message(), expected });
        return error.TestUnexpectedMessage;
    }
}

/// A one-worker configuration whose route body is `route_body`.
fn withRoute(comptime route_body: []const u8) []const u8 {
    return "{\"workers\": {\"api\": {\"routes\": {\"/x\": " ++ route_body ++ "}}}}";
}

/// A one-worker configuration whose worker settings are `settings`.
fn withWorkerSettings(comptime settings: []const u8) []const u8 {
    return "{\"workers\": {\"api\": {\"routes\": {\"/x\": {\"entry\": \"app.js\"}}, \"settings\": " ++ settings ++ "}}}";
}

/// A one-worker configuration with `global` as its global settings.
fn withGlobal(comptime global: []const u8) []const u8 {
    return "{\"globalSettings\": " ++ global ++ ", \"workers\": {\"api\": {\"routes\": {\"/x\": {\"entry\": \"app.js\"}}}}}";
}

const full_source =
    \\{
    \\  // Global defaults every worker starts from.
    \\  "globalSettings": {
    \\    "listen": "0.0.0.0:9443",
    \\    "tls": { "certificate": "certs/cert.pem", "privateKey": "/etc/collo/key.pem" },
    \\    "analytics": { "directory": "./collo-analytics" },
    \\    "isolateRealm": true,
    \\    "limits": { "memoryMiB": 192, "concurrency": 2, "timeoutMs": 20000 }
    \\  },
    \\  "workers": {
    \\    "users": {
    \\      "routes": { "/users/:id": { "entry": "./users/app.js", "bindings": { "SECRET": { "text": "s3cr3t" } } } },
    \\      "settings": { "isolateRealm": false, "limits": { "memoryMiB": 256 } }
    \\    },
    \\    "static-site": {
    \\      "routes": { "/static/*": { "entry": "../shared/site.js" } }
    \\    }
    \\  }
    \\}
;

test "a full configuration resolves the cascade and relative paths" {
    var parsed = try parseOk(full_source);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(config_path, parsed.path);
    try std.testing.expect(parsed.listen.eql(try std.net.Address.parseIp4("0.0.0.0", 9443)));
    try std.testing.expectEqualStrings("/srv/app/certs/cert.pem", parsed.tls.?.certificate_path);
    try std.testing.expectEqualStrings("/etc/collo/key.pem", parsed.tls.?.private_key_path);
    try std.testing.expectEqualStrings("/srv/app/collo-analytics", parsed.analytics.?.directory_path);
    try std.testing.expect(parsed.defaults.isolate_realm);
    try std.testing.expectEqual(@as(u32, 192), parsed.defaults.limits.memory_mib);
    try std.testing.expectEqual(@as(u8, 2), parsed.defaults.limits.concurrency);
    try std.testing.expectEqual(@as(u32, 20_000), parsed.defaults.limits.timeout_ms);

    try std.testing.expectEqual(@as(usize, 2), parsed.definitions.len);
    try std.testing.expectEqual(@as(u16, 2), parsed.route_count);

    const users = parsed.definitions[0];
    try std.testing.expectEqualStrings("users", users.name);
    try std.testing.expect(!users.settings.isolate_realm);
    // The worker names only memoryMiB; the other limits come from the
    // global settings, not from the built-in defaults.
    try std.testing.expectEqual(@as(u32, 256), users.settings.limits.memory_mib);
    try std.testing.expectEqual(@as(u8, 2), users.settings.limits.concurrency);
    try std.testing.expectEqual(@as(u32, 20_000), users.settings.limits.timeout_ms);
    try std.testing.expectEqual(@as(u64, 256 * 1024 * 1024), users.settings.limits.memoryBytes());
    try std.testing.expectEqual(@as(u64, 20 * std.time.ns_per_s), users.settings.limits.timeoutNs());
    try std.testing.expectEqual(@as(usize, 1), users.routes.len);
    try std.testing.expectEqualStrings("/users/:id", users.routes[0].pattern);
    try std.testing.expectEqualStrings("/srv/app/users/app.js", users.routes[0].entry_path);
    try std.testing.expectEqual(@as(usize, 1), users.routes[0].bindings.len);
    try std.testing.expectEqualStrings("SECRET", users.routes[0].bindings[0].name);
    try std.testing.expectEqualStrings("s3cr3t", users.routes[0].bindings[0].value.text);

    const site = parsed.definitions[1];
    try std.testing.expectEqualStrings("static-site", site.name);
    try std.testing.expectEqual(parsed.defaults, site.settings);
    try std.testing.expectEqualStrings("/srv/shared/site.js", site.routes[0].entry_path);
    try std.testing.expectEqual(@as(usize, 0), site.routes[0].bindings.len);

    try std.testing.expectEqual(@as(?config.DefinitionIndex, 1), parsed.findDefinition("static-site"));
    try std.testing.expectEqual(@as(?config.DefinitionIndex, null), parsed.findDefinition("missing"));
    try std.testing.expectEqualStrings("/static/*", parsed.route(.{ .definition = 1, .route = 0 }).pattern);
}

test "a minimal configuration takes every default" {
    var parsed = try parseOk(
        \\{"workers": {"api": {"routes": {"/*": {"entry": "app.js"}}}}}
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.listen.eql(try config.parseListen(config.default_listen)));
    try std.testing.expect(parsed.tls == null);
    try std.testing.expect(parsed.analytics == null);
    try std.testing.expectEqual(config.default_settings, parsed.defaults);
    try std.testing.expectEqual(config.default_settings, parsed.definitions[0].settings);
    try std.testing.expectEqualStrings("/srv/app/app.js", parsed.definitions[0].routes[0].entry_path);
}

test "comments are blanked outside strings and kept inside them" {
    var parsed = try parseOk(
        \\// A line comment before the object.
        \\{
        \\  /* A block comment
        \\     across lines. */
        \\  "workers": { // trailing comment
        \\    "api": {"routes": {"/x": {"entry": "app.js", "bindings": {
        \\      "URL": {"text": "https://example.com/a // not /* a comment */"}
        \\    }}}}
        \\  }
        \\}
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "https://example.com/a // not /* a comment */",
        parsed.definitions[0].routes[0].bindings[0].value.text,
    );
}

test "definitions and bindings keep file order" {
    var parsed = try parseOk(
        \\{"workers": {
        \\  "zeta": {"routes": {"/z": {"entry": "z.js", "bindings": {"B": {"text": "2"}, "A": {"text": "1"}}}}},
        \\  "alpha": {"routes": {"/a": {"entry": "a.js"}}}
        \\}}
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("zeta", parsed.definitions[0].name);
    try std.testing.expectEqualStrings("alpha", parsed.definitions[1].name);
    try std.testing.expectEqualStrings("B", parsed.definitions[0].routes[0].bindings[0].name);
    try std.testing.expectEqualStrings("A", parsed.definitions[0].routes[0].bindings[1].name);
}

test "the JSON layer rejects syntax errors, duplicate keys and open comments with a position" {
    try expectRejected("{\"workers\": {},}", "collo.json:1:");
    try expectRejected("{\"workers\": {},}", "trailing commas are not");
    try expectRejected("{\"workers\": {}, \"workers\": {}}", "duplicate key");
    try expectRejected("{\n/* never closed\n", "collo.json:2:1: unterminated /* comment");
    try expectRejected("{\"workers\": ", "unexpected end");
    try expectRejected("[]", "/srv/app/collo.json: expected an object, found an array");
}

test "unknown keys are rejected with their key path" {
    try expectRejected("{\"colors\": 1}", "colors: unknown key");
    try expectRejected(withGlobal("{\"port\": 1}"), "globalSettings.port: unknown key");
    try expectRejected(withGlobal("{\"tls\": {\"certificate\": \"c\", \"privateKey\": \"k\", \"ca\": \"x\"}}"), "globalSettings.tls.ca: unknown key");
    try expectRejected(withGlobal("{\"limits\": {\"cpu\": 1}}"), "globalSettings.limits.cpu: unknown key");
    try expectRejected(withWorkerSettings("{\"memoryMiB\": 1}"), "workers.api.settings.memoryMiB: unknown key");
    try expectRejected(withRoute("{\"entry\": \"app.js\", \"bogus\": true}"), "workers.api.routes.\"/x\".bogus: unknown key");
}

test "structure and types are checked" {
    try expectRejected("{}", "missing key 'workers'");
    try expectRejected("{\"workers\": {}}", "workers: declare at least one worker");
    try expectRejected("{\"workers\": []}", "workers: expected an object, found an array");
    try expectRejected("{\"workers\": {\"api\": {}}}", "workers.api: missing key 'routes'");
    try expectRejected("{\"workers\": {\"api\": {\"routes\": {}}}}", "workers.api.routes: declare at least one route");
    try expectRejected(withRoute("{}"), "workers.api.routes.\"/x\": missing key 'entry'");
    try expectRejected(withRoute("{\"entry\": \"\"}"), "routes.\"/x\".entry: the path is empty");
    try expectRejected(withRoute("{\"entry\": 7}"), "entry: expected a string, found a number");
    try expectRejected(withGlobal("{\"isolateRealm\": \"yes\"}"), "globalSettings.isolateRealm: expected true or false");
    try expectRejected(withGlobal("{\"tls\": {\"certificate\": \"c\"}}"), "globalSettings.tls: missing key 'privateKey'");
    try expectRejected(withGlobal("{\"analytics\": {}}"), "globalSettings.analytics: missing key 'directory'");
    try expectRejected(withGlobal("{\"listen\": \"localhost:8443\"}"), "globalSettings.listen: 'localhost:8443' is not an address");
}

test "names and route patterns follow their grammars" {
    try expectRejected("{\"workers\": {\"API\": {\"routes\": {\"/x\": {\"entry\": \"a.js\"}}}}}", "workers.API: a worker name must match");
    try expectRejected("{\"workers\": {\"a_b\": {\"routes\": {\"/x\": {\"entry\": \"a.js\"}}}}}", "a worker name must match");
    const long_name = "w" ** (server_limits.worker_name_bytes_max + 1);
    try expectRejected("{\"workers\": {\"" ++ long_name ++ "\": {\"routes\": {\"/x\": {\"entry\": \"a.js\"}}}}}", "a worker name must match");
    try expectRejected("{\"workers\": {\"api\": {\"routes\": {\"users\": {\"entry\": \"a.js\"}}}}}", "workers.api.routes.users: a route pattern must start with '/'");
    try expectRejected("{\"workers\": {\"api\": {\"routes\": {\"/a/*/b\": {\"entry\": \"a.js\"}}}}}", "'*' is allowed only as the last segment");
    try expectRejected("{\"workers\": {\"api\": {\"routes\": {\"/__collo/x\": {\"entry\": \"a.js\"}}}}}", "workers.api.routes.\"/__collo/x\": the server keeps the paths under /__collo/ for itself");
    // The prefix is the server's; a path that only looks like a health check
    // is a route like any other.
    var health_route = try parseOk("{\"workers\": {\"api\": {\"routes\": {\"/healthz\": {\"entry\": \"a.js\"}}}}}");
    defer health_route.deinit();
    try std.testing.expectEqualStrings("/healthz", health_route.definitions[0].routes[0].pattern);
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"1BAD\": {\"text\": \"x\"}}}"), "bindings.1BAD: a binding name must match");
}

test "the limits are range checked and cpuMs is not supported yet" {
    try expectRejected(withGlobal("{\"limits\": {\"concurrency\": 3}}"), "globalSettings.limits.concurrency: 3 is out of range; expected 1 to 2");
    try expectRejected(withWorkerSettings("{\"limits\": {\"concurrency\": 0}}"), "workers.api.settings.limits.concurrency: 0 is out of range");
    try expectRejected(withGlobal("{\"limits\": {\"memoryMiB\": 8}}"), "memoryMiB: 8 is out of range");
    try expectRejected(withGlobal("{\"limits\": {\"memoryMiB\": 1.5}}"), "memoryMiB: expected a whole number");
    try expectRejected(withGlobal("{\"limits\": {\"memoryMiB\": \"128\"}}"), "memoryMiB: expected an integer, found a string");
    try expectRejected(withGlobal("{\"limits\": {\"memoryMiB\": 99999999999999999999}}"), "memoryMiB: the number is out of range");
    try expectRejected(withGlobal("{\"limits\": {\"timeoutMs\": 0}}"), "timeoutMs: 0 is out of range");
    try expectRejected(withGlobal("{\"limits\": {\"cpuMs\": 50}}"), "globalSettings.limits.cpuMs: a per-request CPU budget is not supported yet");
    try expectRejected(withWorkerSettings("{\"limits\": {\"cpuMs\": 50}}"), "workers.api.settings.limits.cpuMs: a per-request CPU budget is not supported yet");
}

test "features the runtime lacks are rejected as not supported yet" {
    try expectRejected(withGlobal("{\"network\": {\"allow\": [\"*\"]}}"), "globalSettings.network: network access is not supported yet");
    try expectRejected(withWorkerSettings("{\"network\": {}}"), "workers.api.settings.network: network access is not supported yet");
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"network\": {}}"), "workers.api.routes.\"/x\".network: network access is not supported yet");
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"DATA\": {\"json\": {}}}}"), "bindings.DATA.json: binding kind 'json' is not supported yet");
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"DATA\": {}}}"), "bindings.DATA: a binding needs a kind");
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"DATA\": {\"text\": \"a\", \"json\": 1}}}"), "bindings.DATA: a binding has exactly one kind");
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"DATA\": {\"text\": 1}}}"), "bindings.DATA.text: expected a string");
    try expectRejected(
        "{\"workers\": {\"api\": {\"routes\": {\"/a\": {\"entry\": \"a.js\"}, \"/b\": {\"entry\": \"b.js\"}}}}}",
        "workers.api.routes: multi-route workers are not supported yet",
    );
}

test "two routes that match the same paths are rejected across workers" {
    try expectRejected(
        "{\"workers\": {\"a\": {\"routes\": {\"/x\": {\"entry\": \"a.js\"}}}, \"b\": {\"routes\": {\"/x\": {\"entry\": \"b.js\"}}}}}",
        "workers.b.routes.\"/x\": matches the same paths as route '/x' of worker 'a'",
    );
    try expectRejected(
        "{\"workers\": {\"a\": {\"routes\": {\"/u/:id\": {\"entry\": \"a.js\"}}}, \"b\": {\"routes\": {\"/u/:name\": {\"entry\": \"b.js\"}}}}}",
        "matches the same paths as route '/u/:id' of worker 'a'",
    );
    // `/u/:id` also matches `/u/me`, but the two do not match exactly the same
    // paths (`pattern.sameShape`), so both are accepted and the static one wins
    // at match time.
    var parsed = try parseOk(
        "{\"workers\": {\"a\": {\"routes\": {\"/u/:id\": {\"entry\": \"a.js\"}}}, \"b\": {\"routes\": {\"/u/me\": {\"entry\": \"b.js\"}}}}}",
    );
    parsed.deinit();
}

test "the server bounds are enforced" {
    const allocator = std.testing.allocator;

    var oversized: std.ArrayList(u8) = .empty;
    defer oversized.deinit(allocator);
    try oversized.appendNTimes(allocator, ' ', server_limits.config_file_bytes_max + 1);
    try expectRejected(oversized.items, "the configuration exceeds");

    var workers: std.ArrayList(u8) = .empty;
    defer workers.deinit(allocator);
    try workers.appendSlice(allocator, "{\"workers\": {");
    for (0..server_limits.worker_definitions_max + 1) |index| {
        if (index != 0)
            try workers.append(allocator, ',');
        try workers.print(allocator, "\"w{d}\": {{\"routes\": {{\"/r{d}\": {{\"entry\": \"a.js\"}}}}}}", .{ index, index });
    }
    try workers.appendSlice(allocator, "}}");
    try expectRejected(workers.items, "workers: 257 workers are declared; at most 256 are allowed");

    var bindings: std.ArrayList(u8) = .empty;
    defer bindings.deinit(allocator);
    try bindings.appendSlice(allocator, "{\"workers\": {\"api\": {\"routes\": {\"/x\": {\"entry\": \"a.js\", \"bindings\": {");
    for (0..server_limits.bindings_per_route_max + 1) |index| {
        if (index != 0)
            try bindings.append(allocator, ',');
        try bindings.print(allocator, "\"B{d}\": {{\"text\": \"v\"}}", .{index});
    }
    try bindings.appendSlice(allocator, "}}}}}}");
    try expectRejected(bindings.items, "bindings: 65 bindings are declared; at most 64 are allowed per route");

    var heavy: std.ArrayList(u8) = .empty;
    defer heavy.deinit(allocator);
    try heavy.appendSlice(allocator, "{\"workers\": {\"api\": {\"routes\": {\"/x\": {\"entry\": \"a.js\", \"bindings\": {\"BIG\": {\"text\": \"");
    try heavy.appendNTimes(allocator, 'x', server_limits.binding_bytes_per_route_max);
    try heavy.appendSlice(allocator, "\"}}}}}}}");
    try expectRejected(heavy.items, "workers.api.routes.\"/x\".bindings: the route's bindings exceed");
}

test "parseListen accepts IPv4, bracketed IPv6 and port 0 and nothing else" {
    try std.testing.expect((try config.parseListen("127.0.0.1:0")).eql(try std.net.Address.parseIp4("127.0.0.1", 0)));
    try std.testing.expect((try config.parseListen("[::1]:8443")).eql(try std.net.Address.parseIp6("::1", 8443)));
    try std.testing.expectEqual(@as(u16, 65535), (try config.parseListen("0.0.0.0:65535")).getPort());
    const rejected = [_][]const u8{
        "",                "localhost:8443", "127.0.0.1",   "127.0.0.1:",
        "127.0.0.1:65536", "127.0.0.1:+1",   "[::1]8443",   "[::1]",
        ":80",             "::1:80",         "1.2.3.4:1_0",
    };
    for (rejected) |text|
        try std.testing.expectError(error.InvalidListenAddress, config.parseListen(text));
}

test "load reads the file and resolves paths against its directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "collo.json",
        .data = "{\"workers\": {\"api\": {\"routes\": {\"/*\": {\"entry\": \"./src/app.js\"}}}}}",
    });
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &directory_buffer);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "collo.json" });
    defer std.testing.allocator.free(file_path);
    const expected_entry = try std.fs.path.join(std.testing.allocator, &.{ directory, "src", "app.js" });
    defer std.testing.allocator.free(expected_entry);

    var diagnostic: config.Diagnostic = .{};
    var loaded = try config.load(std.testing.allocator, file_path, &diagnostic);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(file_path, loaded.path);
    try std.testing.expectEqualStrings(expected_entry, loaded.definitions[0].routes[0].entry_path);

    const missing = try std.fs.path.join(std.testing.allocator, &.{ directory, "missing.json" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.InvalidConfig, config.load(std.testing.allocator, missing, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "cannot read the configuration: FileNotFound") != null);
}

test "a message longer than the diagnostic buffer is cut and marked" {
    var diagnostic: config.Diagnostic = .{};
    const long = "y" ** (config.Diagnostic.message_bytes_max * 2);
    diagnostic.set("{s}", .{long});
    try std.testing.expectEqual(config.Diagnostic.message_bytes_max, diagnostic.message().len);
    try std.testing.expect(std.mem.endsWith(u8, diagnostic.message(), "..."));
    diagnostic.set("short {d}", .{1});
    try std.testing.expectEqualStrings("short 1", diagnostic.message());
}

fn parseFullConfig(allocator: std.mem.Allocator) !void {
    var diagnostic: config.Diagnostic = .{};
    var parsed = try config.parse(allocator, full_source, config_path, &diagnostic);
    parsed.deinit();
}

test "parse frees everything when any allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseFullConfig, .{});
}
