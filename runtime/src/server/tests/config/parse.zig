//! The `collo.json` parser (`server/config/parse.zig`): a full configuration
//! with the settings cascade and relative paths, the defaults of a minimal
//! one, comments, file order, rejections and the key path each message
//! names, the limits with `concurrency` and `cpuMs`, the `network` value's
//! cascade, entries, flags and bounds, the server bounds, the listen address
//! grammar, loading from a file, message truncation, and allocation failure
//! at every step. Every kind of rejected route pattern is covered in
//! `pattern.zig`, and every allow entry form in
//! `common/tests/network/pattern.zig`.

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

/// A one-worker configuration whose top-level settings are `settings`.
fn withSettings(comptime settings: []const u8) []const u8 {
    return "{\"settings\": " ++ settings ++ ", \"workers\": {\"api\": {\"routes\": {\"/x\": {\"entry\": \"app.js\"}}}}}";
}

const full_source =
    \\{
    \\  // Server settings and the defaults every worker starts from.
    \\  "settings": {
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
    // top-level settings, not from the built-in defaults.
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
    try expectRejected(withSettings("{\"port\": 1}"), config_path ++ ": settings.port: unknown key");
    try expectRejected(withSettings("{\"tls\": {\"certificate\": \"c\", \"privateKey\": \"k\", \"ca\": \"x\"}}"), config_path ++ ": settings.tls.ca: unknown key");
    try expectRejected(withSettings("{\"limits\": {\"cpu\": 1}}"), config_path ++ ": settings.limits.cpu: unknown key");
    try expectRejected(withWorkerSettings("{\"memoryMiB\": 1}"), "workers.api.settings.memoryMiB: unknown key");
    try expectRejected(withRoute("{\"entry\": \"app.js\", \"bogus\": true}"), "workers.api.routes.\"/x\".bogus: unknown key");
}

test "the top-level settings live under settings, and globalSettings is an unknown key named by its path" {
    try expectRejected(
        "{\"globalSettings\": {\"limits\": {\"memoryMiB\": 256}}, \"workers\": {\"api\": {\"routes\": {\"/x\": {\"entry\": \"app.js\"}}}}}",
        config_path ++ ": globalSettings: unknown key",
    );
    var parsed = try parseOk(withSettings("{\"limits\": {\"memoryMiB\": 256}}"));
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 256), parsed.defaults.limits.memory_mib);
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
    try expectRejected(withSettings("{\"isolateRealm\": \"yes\"}"), config_path ++ ": settings.isolateRealm: expected true or false");
    try expectRejected(withSettings("{\"tls\": {\"certificate\": \"c\"}}"), config_path ++ ": settings.tls: missing key 'privateKey'");
    try expectRejected(withSettings("{\"analytics\": {}}"), config_path ++ ": settings.analytics: missing key 'directory'");
    try expectRejected(withSettings("{\"listen\": \"localhost:8443\"}"), config_path ++ ": settings.listen: 'localhost:8443' is not an address");
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

test "concurrency admits the largest a worker's page holds and refuses one more" {
    const max = server_limits.worker_concurrency_max;
    var widest = try parseOk(withSettings(std.fmt.comptimePrint("{{\"limits\": {{\"concurrency\": {d}}}}}", .{max})));
    defer widest.deinit();
    try std.testing.expectEqual(max, widest.defaults.limits.concurrency);
    try expectRejected(
        withSettings(std.fmt.comptimePrint("{{\"limits\": {{\"concurrency\": {d}}}}}", .{max + 1})),
        std.fmt.comptimePrint(config_path ++ ": settings.limits.concurrency: {d} is out of range; expected 1 to {d}", .{ max + 1, max }),
    );
}

test "the limits are range checked" {
    try expectRejected(withWorkerSettings("{\"limits\": {\"concurrency\": 0}}"), "workers.api.settings.limits.concurrency: 0 is out of range");
    try expectRejected(withSettings("{\"limits\": {\"memoryMiB\": 8}}"), "memoryMiB: 8 is out of range");
    try expectRejected(withSettings("{\"limits\": {\"memoryMiB\": 1.5}}"), "memoryMiB: expected a whole number");
    try expectRejected(withSettings("{\"limits\": {\"memoryMiB\": \"128\"}}"), "memoryMiB: expected an integer, found a string");
    try expectRejected(withSettings("{\"limits\": {\"memoryMiB\": 99999999999999999999}}"), "memoryMiB: the number is out of range");
    try expectRejected(withSettings("{\"limits\": {\"timeoutMs\": 0}}"), "timeoutMs: 0 is out of range");
}

test "cpuMs is a per-request budget that cascades and is range checked" {
    var parsed = try parseOk(
        \\{"settings": {"limits": {"cpuMs": 50, "timeoutMs": 1000}},
        \\ "workers": {
        \\   "inherits": {"routes": {"/a": {"entry": "a.js"}}},
        \\   "own": {"routes": {"/b": {"entry": "b.js"}}, "settings": {"limits": {"cpuMs": 2000}}}
        \\ }}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, 50), parsed.defaults.limits.cpu_ms);
    try std.testing.expectEqual(@as(?u32, 50), parsed.definitions[0].settings.limits.cpu_ms);
    try std.testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), parsed.definitions[0].settings.limits.cpuBudgetNs());
    // A budget past the deadline is accepted, although it never binds: a
    // request's CPU on its one VM thread cannot outgrow its wall time.
    try std.testing.expectEqual(@as(?u32, 2000), parsed.definitions[1].settings.limits.cpu_ms);
    try std.testing.expectEqual(@as(u32, 1000), parsed.definitions[1].settings.limits.timeout_ms);

    var none = try parseOk(withSettings("{}"));
    defer none.deinit();
    try std.testing.expectEqual(@as(?u32, null), none.definitions[0].settings.limits.cpu_ms);
    try std.testing.expectEqual(@as(u64, 0), none.definitions[0].settings.limits.cpuBudgetNs());

    try expectRejected(withSettings("{\"limits\": {\"cpuMs\": 0}}"), config_path ++ ": settings.limits.cpuMs: 0 is out of range");
    try expectRejected(
        withWorkerSettings(std.fmt.comptimePrint("{{\"limits\": {{\"cpuMs\": {d}}}}}", .{server_limits.request_cpu_ms_max + 1})),
        std.fmt.comptimePrint("workers.api.settings.limits.cpuMs: {d} is out of range; expected 1 to {d}", .{
            server_limits.request_cpu_ms_max + 1,
            server_limits.request_cpu_ms_max,
        }),
    );
}

test "binding kinds the runtime lacks are rejected as not supported yet" {
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"DATA\": {\"json\": {}}}}"), "bindings.DATA.json: binding kind 'json' is not supported yet");
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"DATA\": {}}}"), "bindings.DATA: a binding needs a kind");
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"DATA\": {\"text\": \"a\", \"json\": 1}}}"), "bindings.DATA: a binding has exactly one kind");
    try expectRejected(withRoute("{\"entry\": \"a.js\", \"bindings\": {\"DATA\": {\"text\": 1}}}"), "bindings.DATA.text: expected a string");
}

/// Top-level grant inherited by `inherits`'s routes, dropped by its `/drop`
/// route; replaced by `own`'s settings, and that replaced again by its `/c`
/// route.
const network_source =
    \\{"settings": {"network": {"allow": ["api.example.com", "10.0.0.5:8080"], "allowPrivateNetworks": true}},
    \\ "workers": {
    \\   "inherits": {"routes": {"/a": {"entry": "a.js"}, "/drop": {"entry": "a.js", "network": {"allow": []}}}},
    \\   "own": {"settings": {"network": {"allow": ["*"], "allowHttp": true}},
    \\           "routes": {"/b": {"entry": "b.js"}, "/c": {"entry": "c.js", "network": {"allow": ["*.Example.COM."]}}}}
    \\ }}
;

test "a configuration that names no network grants no route any access" {
    var parsed = try parseOk(full_source);
    defer parsed.deinit();
    try std.testing.expect(parsed.defaults.network == null);
    for (parsed.definitions) |definition| {
        try std.testing.expect(definition.settings.network == null);
        for (definition.routes) |route|
            try std.testing.expect(route.network == null);
    }
}

test "network cascades by replacing the inherited value whole, down to each route" {
    var parsed = try parseOk(network_source);
    defer parsed.deinit();

    const top_level = parsed.defaults.network.?;
    try std.testing.expectEqual(@as(usize, 2), top_level.allow.len);
    try std.testing.expectEqualStrings("api.example.com", top_level.allow[0].host.name);
    try std.testing.expectEqual(@as(u16, 0), top_level.allow[0].port);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 5 }, top_level.allow[1].host.ipv4);
    try std.testing.expectEqual(@as(u16, 8080), top_level.allow[1].port);
    try std.testing.expect(top_level.allow_private_networks);
    try std.testing.expect(!top_level.allow_http);

    // A definition without its own value, and a route without one, run
    // under the top-level value.
    const inherits = parsed.definitions[0];
    try std.testing.expectEqual(@as(usize, 2), inherits.settings.network.?.allow.len);
    const route_a = inherits.routes[0].network.?;
    try std.testing.expectEqual(@as(usize, 2), route_a.allow.len);
    try std.testing.expect(route_a.allow_private_networks);
    // An empty list drops the inherited grant.
    const dropped = inherits.routes[1].network.?;
    try std.testing.expectEqual(@as(usize, 0), dropped.allow.len);
    try std.testing.expect(!dropped.allow_private_networks);
    try std.testing.expect(!dropped.allow_http);

    // A definition's value keeps none of the top-level entries or flags.
    const own = parsed.definitions[1];
    const own_value = own.settings.network.?;
    try std.testing.expectEqual(@as(usize, 1), own_value.allow.len);
    try std.testing.expect(own_value.allow[0].host == .any);
    try std.testing.expect(own_value.allow_http);
    try std.testing.expect(!own_value.allow_private_networks);
    try std.testing.expectEqual(@as(usize, 1), own.routes[0].network.?.allow.len);
    try std.testing.expect(own.routes[0].network.?.allow_http);
    // A route's value keeps none of its definition's, and its entry is in
    // canonical form: lowercase, without the trailing dot.
    const route_c = own.routes[1].network.?;
    try std.testing.expectEqual(@as(usize, 1), route_c.allow.len);
    try std.testing.expectEqualStrings("example.com", route_c.allow[0].host.suffix);
    try std.testing.expect(!route_c.allow_http);
}

test "a network entry the grammar refuses is named by its index and quoted" {
    try expectRejected(
        withRoute("{\"entry\": \"a.js\", \"network\": {\"allow\": [\"api.example.com\", \"ok.example.com\", \"*.*.example.com\"]}}"),
        "workers.api.routes.\"/x\".network.allow[2]: '*.*.example.com': a wildcard is \"*\" alone or a leading \"*.\" before a host name",
    );
    try expectRejected(withSettings("{\"network\": {\"allow\": [\"*:8443\"]}}"), config_path ++ ": settings.network.allow[0]: '*:8443': \"*\" takes no port");
    try expectRejected(
        withWorkerSettings("{\"network\": {\"allow\": [\"b\u{fc}cher.example\"]}}"),
        "workers.api.settings.network.allow[0]: 'b\u{fc}cher.example': a host must be ASCII; write an internationalized name in its xn-- form",
    );
    try expectRejected(withSettings("{\"network\": {\"allow\": [\"169.254.169.254\"]}}"), config_path ++ ": settings.network.allow[0]: '169.254.169.254': a link-local or cloud metadata address is never reachable");
    try expectRejected(withSettings("{\"network\": {\"allow\": [\"localhost\"]}}"), config_path ++ ": settings.network.allow[0]: 'localhost': localhost and its subdomains are never reachable");
    try expectRejected(withSettings("{\"network\": {\"allow\": [7]}}"), config_path ++ ": settings.network.allow[0]: expected a string, found a number");
}

test "a network value is an object with an allow array and two flags" {
    try expectRejected(withSettings("{\"network\": {}}"), config_path ++ ": settings.network: missing key 'allow'");
    try expectRejected(withSettings("{\"network\": {\"allowHttp\": true}}"), config_path ++ ": settings.network: missing key 'allow'");
    try expectRejected(withSettings("{\"network\": {\"allow\": \"*\"}}"), config_path ++ ": settings.network.allow: expected an array, found a string");
    try expectRejected(withSettings("{\"network\": [\"*\"]}"), config_path ++ ": settings.network: expected an object, found an array");
    try expectRejected(withWorkerSettings("{\"network\": {\"allow\": [], \"allowFtp\": true}}"), "workers.api.settings.network.allowFtp: unknown key");
    try expectRejected(withSettings("{\"network\": {\"allow\": [\"*\"], \"allowHttp\": 1}}"), config_path ++ ": settings.network.allowHttp: expected true or false");
}

test "a network value that admits less than it says is refused at the key at fault" {
    try expectRejected(
        withSettings("{\"network\": {\"allow\": [\"api.example.com\", \"10.0.0.5:8080\"]}}"),
        config_path ++ ": settings.network.allow[1]: '10.0.0.5:8080': the entry is a private address; set allowPrivateNetworks to allow it",
    );
    // "*" covers public addresses only, so the flag would admit nothing.
    try expectRejected(
        withSettings("{\"network\": {\"allow\": [\"*\"], \"allowPrivateNetworks\": true}}"),
        config_path ++ ": settings.network.allowPrivateNetworks: allowPrivateNetworks needs an entry that names a private host or address",
    );
    try expectRejected(
        withRoute("{\"entry\": \"a.js\", \"network\": {\"allow\": [], \"allowHttp\": true}}"),
        "workers.api.routes.\"/x\".network.allowHttp: allowHttp has no effect while the allow list is empty",
    );
    // A repeat in canonical form names the entry it repeats.
    try expectRejected(
        withRoute("{\"entry\": \"a.js\", \"network\": {\"allow\": [\"API.example.com\", \"*\", \"api.example.com.\"]}}"),
        "workers.api.routes.\"/x\".network.allow[2]: 'api.example.com.': the entry repeats an earlier entry of the same list (allow[0])",
    );

    var private = try parseOk(withSettings("{\"network\": {\"allow\": [\"[fd12::1]:8443\"], \"allowPrivateNetworks\": true}}"));
    defer private.deinit();
    const value = private.definitions[0].routes[0].network.?;
    try std.testing.expect(value.allow[0].host == .ipv6);
    try std.testing.expectEqual(@as(u16, 8443), value.allow[0].port);
}

/// A configuration whose `routes` routes each name a `network` value of
/// `entries` distinct hosts; the caller frees it.
fn networkEntriesSource(allocator: std.mem.Allocator, routes: usize, entries: usize) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "{\"workers\": {\"api\": {\"routes\": {");
    for (0..routes) |route| {
        if (route != 0)
            try source.appendSlice(allocator, ", ");
        try source.print(allocator, "\"/r{d}\": {{\"entry\": \"a.js\", \"network\": {{\"allow\": [", .{route});
        for (0..entries) |entry| {
            if (entry != 0)
                try source.appendSlice(allocator, ", ");
            try source.print(allocator, "\"h{d}.example.com\"", .{entry});
        }
        try source.appendSlice(allocator, "]}}");
    }
    try source.appendSlice(allocator, "}}}}");
    return source.toOwnedSlice(allocator);
}

test "allow entries are bounded per value and across the configuration" {
    const allocator = std.testing.allocator;
    const per_value = server_limits.network_allow_entries_max;
    const total = server_limits.network_allow_entries_total_max;

    const at_bound = try networkEntriesSource(allocator, 1, per_value);
    defer allocator.free(at_bound);
    var bounded = try parseOk(at_bound);
    defer bounded.deinit();
    try std.testing.expectEqual(per_value, bounded.definitions[0].routes[0].network.?.allow.len);

    const past_bound = try networkEntriesSource(allocator, 1, per_value + 1);
    defer allocator.free(past_bound);
    try expectRejected(past_bound, std.fmt.comptimePrint("workers.api.routes.\"/r0\".network.allow: an allow list holds at most {d} entries", .{per_value}));

    // Each value is within its bound, but together they pass the
    // configuration's, which no key names.
    const routes = total / per_value + 1;
    const past_total = try networkEntriesSource(allocator, routes, per_value);
    defer allocator.free(past_total);
    try expectRejected(past_total, std.fmt.comptimePrint("/srv/app/collo.json: the network values declare {d} allow entries; at most {d} are allowed in all", .{
        routes * per_value,
        total,
    }));
}

fn parseNetworkConfig(allocator: std.mem.Allocator) !void {
    var diagnostic: config.Diagnostic = .{};
    var parsed = try config.parse(allocator, network_source, config_path, &diagnostic);
    parsed.deinit();
}

test "parse frees every network value when any allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseNetworkConfig, .{});
}

test "a worker declares up to routes_per_definition_max routes, in file order, each with its own bindings" {
    var parsed = try parseOk(
        \\{"workers": {"api": {"settings": {"isolateRealm": false}, "routes": {
        \\  "/a": {"entry": "a.js", "bindings": {"NAME": {"text": "a"}}},
        \\  "/b": {"entry": "b.js", "bindings": {"NAME": {"text": "b"}}},
        \\  "/again": {"entry": "a.js"}
        \\}}}}
    );
    defer parsed.deinit();
    const api = parsed.definition(0);
    try std.testing.expect(!api.settings.isolate_realm);
    try std.testing.expectEqual(@as(usize, 3), api.routes.len);
    try std.testing.expectEqual(@as(u16, 3), parsed.route_count);
    const expected = [_]struct { pattern: []const u8, entry: []const u8, bindings: usize }{
        .{ .pattern = "/a", .entry = "/srv/app/a.js", .bindings = 1 },
        .{ .pattern = "/b", .entry = "/srv/app/b.js", .bindings = 1 },
        .{ .pattern = "/again", .entry = "/srv/app/a.js", .bindings = 0 },
    };
    for (api.routes, expected) |route, want| {
        try std.testing.expectEqualStrings(want.pattern, route.pattern);
        try std.testing.expectEqualStrings(want.entry, route.entry_path);
        try std.testing.expectEqual(want.bindings, route.bindings.len);
    }
    try std.testing.expectEqualStrings("b", api.routes[1].bindings[0].value.text);

    // A worker at the bound parses, and one route more is refused, naming
    // the bound.
    const allocator = std.testing.allocator;
    const at_bound = try routesSource(allocator, server_limits.routes_per_definition_max);
    defer allocator.free(at_bound);
    var bounded = try parseOk(at_bound);
    defer bounded.deinit();
    try std.testing.expectEqual(server_limits.routes_per_definition_max, bounded.definition(0).routes.len);
    const past_bound = try routesSource(allocator, server_limits.routes_per_definition_max + 1);
    defer allocator.free(past_bound);
    try expectRejected(past_bound, "routes are declared; at most 64 are allowed per worker");
}

/// A configuration whose one worker declares `count` routes on one entry;
/// the caller frees it.
fn routesSource(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "{\"workers\": {\"api\": {\"routes\": {");
    for (0..count) |index| {
        if (index != 0)
            try source.appendSlice(allocator, ", ");
        try source.print(allocator, "\"/r{d}\": {{\"entry\": \"a.js\"}}", .{index});
    }
    try source.appendSlice(allocator, "}}}}");
    return source.toOwnedSlice(allocator);
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
