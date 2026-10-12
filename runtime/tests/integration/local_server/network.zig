//! The `network` setting through the production stack: a route's grant
//! admits the hosts, ports and schemes it names and nothing else, on every
//! hop, redirects included; `"*"` covers public addresses only; loopback,
//! link-local and metadata addresses are never reached; a definition without
//! a grant has no egress path and no gateway runs for it; and module
//! top-level code fetches under the union of its definition's grants, while a
//! request fetches under its own route's, whichever route's code makes the
//! call; top-level code still pending keeps that union after `WorkerReady`,
//! while another route of the same worker serves, and past the init
//! deadline. Each denial rejects the handler's fetch with a TypeError whose
//! message is the denial text `collo_network.writeDenial` writes, and puts
//! one `warn` line with that text in the tenant's log.
//!
//! The configurations are written here, from the origins' run-time
//! addresses, by `configText`; the static fixture
//! (`fixtures/local_e2e/collo.json`) grants nothing, so every test that does
//! not fetch also runs the path of a worker without an egress session. The
//! handlers live in `fixtures/local_e2e/api/` (`network_fetch.js`,
//! `network_no_grant.js`), except the generated modules of the union test.
//! The origins are `origin.zig`'s, on this host's routable IPv4 address,
//! which is private on every host the lane runs on; the private-address test
//! skips, naming the reason, on a host where it is public. Lane `local-e2e`;
//! the grammar, the compilation and the matching run without a server in
//! `common/tests/network/`, `server/tests/config/` and `server/tests/routes/`.

const std = @import("std");
const collo_network = @import("collo_network");
const config = @import("collo_server_config");
const process = @import("collo_os").process;
const process_limits = @import("collo_limits").process;
const zygote_support = @import("zygote_support");
const harness_mod = @import("harness.zig");
const origin_mod = @import("origin.zig");

const Harness = harness_mod.Harness;
const Client = harness_mod.Client;
const GzipOrigin = origin_mod.GzipOrigin;
const Denial = collo_network.Denial;

/// One `network` value as a configuration declares it.
pub const NetworkValue = struct {
    allow: []const []const u8,
    allow_http: bool = false,
    allow_private_networks: bool = false,
};

pub const RouteSpec = struct {
    path: []const u8,
    /// Relative to the configuration's directory.
    entry: []const u8,
    /// The route's own value, which replaces its definition's whole.
    network: ?NetworkValue = null,
};

pub const WorkerSpec = struct {
    name: []const u8,
    routes: []const RouteSpec,
    /// The definition's value, which every route without one inherits.
    network: ?NetworkValue = null,
    isolate_realm: ?bool = null,
    /// The definition's own limits; each one left null keeps the global
    /// value.
    concurrency: ?u32 = null,
    timeout_ms: ?u32 = null,
    cpu_ms: ?u32 = null,
    memory_mib: ?u32 = null,
};

/// One key of a definition's `limits` object and the value a `WorkerSpec`
/// gives it, null when it gives none.
const LimitValue = struct {
    key: []const u8,
    value: ?u32,
};

fn limitValues(worker: WorkerSpec) [4]LimitValue {
    return .{
        .{ .key = "concurrency", .value = worker.concurrency },
        .{ .key = "timeoutMs", .value = worker.timeout_ms },
        .{ .key = "cpuMs", .value = worker.cpu_ms },
        .{ .key = "memoryMiB", .value = worker.memory_mib },
    };
}

/// The text of a configuration declaring `workers`, under the static
/// fixture's global limits. The caller owns it.
pub fn configText(allocator: std.mem.Allocator, workers: []const WorkerSpec) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(
        \\{
        \\  "globalSettings": { "limits": { "memoryMiB": 1024, "timeoutMs": 15000 } },
        \\  "workers": {
        \\
    );
    for (workers, 0..) |worker, worker_index| {
        try writer.writeAll("    ");
        try writeString(writer, worker.name);
        try writer.writeAll(": {\n      \"routes\": {");
        for (worker.routes, 0..) |route, route_index| {
            try writer.writeAll(if (route_index == 0) "\n        " else ",\n        ");
            try writeString(writer, route.path);
            try writer.writeAll(": { \"entry\": ");
            try writeString(writer, route.entry);
            if (route.network) |value| {
                try writer.writeAll(", \"network\": ");
                try writeNetwork(writer, value);
            }
            try writer.writeAll(" }");
        }
        try writer.writeAll("\n      }");
        var settings_count: usize = 0;
        if (worker.network) |value| {
            try beginSetting(writer, &settings_count);
            try writer.writeAll("\"network\": ");
            try writeNetwork(writer, value);
        }
        if (worker.isolate_realm) |isolate_realm| {
            try beginSetting(writer, &settings_count);
            try writer.print("\"isolateRealm\": {}", .{isolate_realm});
        }
        var limits_count: usize = 0;
        for (limitValues(worker)) |limit| {
            const value = limit.value orelse continue;
            if (limits_count == 0) {
                try beginSetting(writer, &settings_count);
                try writer.writeAll("\"limits\": { ");
            } else {
                try writer.writeAll(", ");
            }
            try writer.print("\"{s}\": {d}", .{ limit.key, value });
            limits_count += 1;
        }
        if (limits_count != 0) try writer.writeAll(" }");
        if (settings_count != 0) try writer.writeAll(" }");
        try writer.writeAll("\n    }");
        try writer.writeAll(if (worker_index + 1 == workers.len) "\n" else ",\n");
    }
    try writer.writeAll("  }\n}\n");
    return out.toOwnedSlice();
}

/// Opens the definition's `settings` object before its first key, and
/// separates later keys.
fn beginSetting(writer: *std.Io.Writer, settings_count: *usize) !void {
    try writer.writeAll(if (settings_count.* == 0) ",\n      \"settings\": { " else ", ");
    settings_count.* += 1;
}

fn writeNetwork(writer: *std.Io.Writer, value: NetworkValue) !void {
    try writer.writeAll("{ \"allow\": [");
    for (value.allow, 0..) |entry, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeString(writer, entry);
    }
    try writer.print("], \"allowHttp\": {}, \"allowPrivateNetworks\": {} }}", .{
        value.allow_http,
        value.allow_private_networks,
    });
}

fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

/// Whether `host`, an IPv4 literal, is a private address, which a grant must
/// name with `allowPrivateNetworks` for a fetch to reach it.
pub fn isPrivateIpv4(host: []const u8) !bool {
    const address = try std.net.Address.parseIp4(host, 0);
    return collo_network.address.classifyIpv4(collo_network.address.ipv4Bytes(address)) == .private_routable;
}

/// The grant of plain HTTP to the origins `allow` names, with private
/// networks when `host` is private. `allow` must outlive the value.
pub fn originGrant(allow: []const []const u8, host: []const u8) !NetworkValue {
    return .{
        .allow = allow,
        .allow_http = true,
        .allow_private_networks = try isPrivateIpv4(host),
    };
}

/// Bytes of an authority, `<IPv4>:<port>`.
pub const authority_bytes_max: usize = 32;
/// Bytes of a request path the tests send: a route and one URL, escaped.
const request_path_bytes_max: usize = 512;

/// `route?url=<url>&timeout=<ms>`, the URL escaped as a query value, written
/// into `buffer`; `timeout_ms` 0 leaves the fetch unbounded.
fn fetchPath(buffer: []u8, route: []const u8, url: []const u8, timeout_ms: u32) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeAll(route);
    try writer.writeAll("?url=");
    for (url) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
    if (timeout_ms != 0)
        try writer.print("&timeout={d}", .{timeout_ms});
    return writer.buffered();
}

/// The text a denial of `scheme://host:port` writes, into `buffer`.
fn denialText(
    buffer: *[collo_network.grant.denial_bytes_max]u8,
    scheme: collo_network.Scheme,
    host: []const u8,
    port: u16,
    denial: Denial,
) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    // The buffer holds the longest denial `writeDenial` can write.
    collo_network.writeDenial(&writer, .{ .scheme = scheme, .host = host, .port = port }, denial) catch unreachable;
    return writer.buffered();
}

/// How the fetch behind a reply of `api/network_fetch.js` ended.
const FetchOutcome = struct {
    status: ?u16 = null,
    text: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// Sends `path`, which `api/network_fetch.js` serves, and expects its fetch
/// to have read the origin's decoded body.
fn expectReached(client: *Client, path: []const u8) !void {
    const response = try client.get(path);
    const parsed = try harness_mod.parseReply(FetchOutcome, &response);
    defer parsed.deinit();
    const outcome = parsed.value;
    if (outcome.status == 200) {
        if (outcome.text) |text| {
            if (std.mem.eql(u8, text, GzipOrigin.decoded_body)) return;
        }
    }
    std.debug.print("expected the fetch of {s} to reach its origin: {s}\n", .{ path, response.body() });
    return error.FetchDidNotReachOrigin;
}

/// Sends `path` and expects its fetch to have rejected with a TypeError
/// whose message is `expected`.
fn expectDenied(client: *Client, path: []const u8, expected: []const u8) !void {
    const response = try client.get(path);
    const parsed = try harness_mod.parseReply(FetchOutcome, &response);
    defer parsed.deinit();
    expectDeniedOutcome(parsed.value, expected, response.body()) catch |err| {
        std.debug.print("from {s}\n", .{path});
        return err;
    };
}

fn expectDeniedOutcome(outcome: FetchOutcome, expected: []const u8, body: []const u8) !void {
    const name = outcome.@"error" orelse "";
    const message = outcome.message orelse "";
    if (std.mem.eql(u8, name, "TypeError") and std.mem.eql(u8, message, expected)) return;
    std.debug.print("expected a TypeError \"{s}\", got: {s}\n", .{ expected, body });
    return error.FetchNotDeniedAsExpected;
}

/// The fields of a `logs.jsonl` record the tests check; a drop marker has
/// neither a level nor a message.
const LogLine = struct {
    request_id: u64 = 0,
    level: []const u8 = "",
    message: []const u8 = "",
};

const AccessLine = struct {
    request_id: u64,
    route: []const u8,
    status: u16,
};

/// Waits, at most `log_polls_max` polls, until `logs.jsonl` holds at least
/// `minimum` `warn` lines whose message is `message`, and returns their
/// request ids, written into `out`. Fails with `error.TooManyDenialLines`
/// when more lines match than `out` holds.
fn denialRequestIds(harness: *Harness, message: []const u8, minimum: usize, out: []u64) ![]u64 {
    for (0..log_polls_max) |_| {
        var lines = try harness_mod.waitForRecordLines(LogLine, harness, "logs.jsonl", 0);
        defer lines.deinit();
        var count: usize = 0;
        for (lines.items) |line| {
            if (!std.mem.eql(u8, line.level, "warn")) continue;
            if (!std.mem.eql(u8, line.message, message)) continue;
            if (count == out.len) return error.TooManyDenialLines;
            out[count] = line.request_id;
            count += 1;
        }
        if (count >= minimum) return out[0..count];
        std.Thread.sleep(log_poll_interval_ns);
    }
    return error.DenialLineNotObserved;
}

/// Polls `denialRequestIds` makes, `log_poll_interval_ns` apart; the metrics
/// thread drains console rings every tick.
const log_polls_max: usize = 200;
const log_poll_interval_ns: u64 = 10 * std.time.ns_per_ms;

/// The request id of the one access record of `route`.
fn accessRequestId(harness: *Harness, route: []const u8) !u64 {
    var lines = try harness_mod.waitForRecordLines(AccessLine, harness, "access.jsonl", 1);
    defer lines.deinit();
    var found: ?u64 = null;
    for (lines.items) |line| {
        if (!std.mem.eql(u8, line.route, route)) continue;
        if (found != null) return error.SeveralAccessRecords;
        found = line.request_id;
    }
    return found orelse error.AccessRecordNotObserved;
}

/// Sends `path` and expects its fetch denied with `expected`, and one `warn`
/// line with that text in the tenant's log under the request's id. The route
/// `path` names must have no other access record.
fn expectDeniedAndLogged(harness: *Harness, client: *Client, path: []const u8, expected: []const u8) !void {
    try expectDenied(client, path, expected);
    const route = path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
    const request_id = try accessRequestId(harness, route);
    var line_ids_buffer: [4]u64 = undefined;
    const line_ids = try denialRequestIds(harness, expected, 1, &line_ids_buffer);
    try std.testing.expectEqual(@as(usize, 1), line_ids.len);
    try std.testing.expectEqual(request_id, line_ids[0]);
}

/// Starts the harness on `text`, which the harness parses against the
/// static fixture's directory, so `./api/` entries resolve there.
fn initHarness(harness: *Harness, text: []const u8, prewarm_gateway: bool) !void {
    try harness.init(.{ .config_source = text, .prewarm_gateway = prewarm_gateway });
}

fn findRoute(definition: *const config.WorkerDefinition, pattern: []const u8) !*const config.Route {
    for (definition.routes) |*route| {
        if (std.mem.eql(u8, route.pattern, pattern)) return route;
    }
    return error.TemplateRouteMissing;
}

test "local e2e network: the configuration template writes what the parser reads, grants and settings included" {
    const allow = [_][]const u8{ "10.1.2.3:8080", "*.example.test" };
    const text = try configText(std.testing.allocator, &.{
        .{
            .name = "granted",
            .routes = &.{
                .{ .path = "/inherits", .entry = "./inherits.js" },
                .{ .path = "/opts-out", .entry = "./opts_out.js", .network = .{ .allow = &.{} } },
            },
            .network = .{ .allow = &allow, .allow_http = true, .allow_private_networks = true },
            .isolate_realm = false,
            .concurrency = 4,
            .timeout_ms = 2500,
            .cpu_ms = 50,
            .memory_mib = 64,
        },
        .{ .name = "plain", .routes = &.{.{ .path = "/plain", .entry = "./plain.js" }} },
    });
    defer std.testing.allocator.free(text);

    var diagnostic: config.Diagnostic = .{};
    var parsed = config.parse(std.testing.allocator, text, "/collo-template/collo.json", &diagnostic) catch |err| {
        std.debug.print("the template's configuration was rejected: {s}\n{s}\n", .{ diagnostic.message(), text });
        return err;
    };
    defer parsed.deinit();

    const granted = parsed.definition(parsed.findDefinition("granted") orelse return error.TemplateDefinitionMissing);
    try std.testing.expect(!granted.settings.isolate_realm);
    try std.testing.expectEqual(@as(u8, 4), granted.settings.limits.concurrency);
    try std.testing.expectEqual(@as(u32, 2500), granted.settings.limits.timeout_ms);
    try std.testing.expectEqual(@as(?u32, 50), granted.settings.limits.cpu_ms);
    try std.testing.expectEqual(@as(u32, 64), granted.settings.limits.memory_mib);
    const inherited = (try findRoute(granted, "/inherits")).network orelse return error.TemplateGrantMissing;
    try std.testing.expectEqual(@as(usize, 2), inherited.allow.len);
    try std.testing.expect(inherited.allow_http);
    try std.testing.expect(inherited.allow_private_networks);
    const opted_out = (try findRoute(granted, "/opts-out")).network orelse return error.TemplateGrantMissing;
    try std.testing.expectEqual(@as(usize, 0), opted_out.allow.len);

    const plain = parsed.definition(parsed.findDefinition("plain") orelse return error.TemplateDefinitionMissing);
    try std.testing.expect((try findRoute(plain, "/plain")).network == null);
    // A definition that names no limit keeps the global ones.
    try std.testing.expectEqual(@as(u32, 15000), plain.settings.limits.timeout_ms);
    try std.testing.expectEqual(@as(?u32, null), plain.settings.limits.cpu_ms);
}

test "local e2e network: a route's grant admits its origin, and the first attach spawns the gateway" {
    var origin = try GzipOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var authority_buffer: [authority_bytes_max]u8 = undefined;
    const allow = [_][]const u8{try origin.authority(&authority_buffer)};
    const text = try configText(std.testing.allocator, &.{.{
        .name = "fetch-gzip",
        .routes = &.{.{ .path = "/fetch-gzip", .entry = "./api/fetch_gzip.js" }},
        .network = try originGrant(&allow, origin.host()),
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    // Nothing prewarms the gateway, so the first launch's attach spawns it.
    try initHarness(&harness, text, false);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    try std.testing.expectEqual(@as(u64, 0), harness.gatewayGeneration());

    // The handler fetches twice, decoding `content-encoding: gzip` through
    // `text()` and through the body's reader.
    const path = try origin_mod.gzipRoutePath(std.testing.allocator, "/fetch-gzip", origin);
    defer std.testing.allocator.free(path);
    var client = try Client.open(&harness);
    defer client.close();
    const response = try client.get(path);
    const parsed = try harness_mod.parseReply(struct {
        status: u16,
        text: []const u8,
        streamed: []const u8,
    }, &response);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 200), parsed.value.status);
    try std.testing.expectEqualStrings(GzipOrigin.decoded_body, parsed.value.text);
    try std.testing.expectEqualStrings(GzipOrigin.decoded_body, parsed.value.streamed);
    // The origin closes every connection, so two fetches took two.
    try std.testing.expect(origin.accepted.load(.acquire) >= 2);
    try std.testing.expect(harness.gatewayGeneration() != 0);
}

test "local e2e network: a host the grant does not name is denied with a TypeError and one log line, and its origin sees no connection" {
    var origin = try GzipOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    const allow = [_][]const u8{"granted.example.test"};
    const text = try configText(std.testing.allocator, &.{.{
        .name = "denied",
        .routes = &.{.{ .path = "/denied", .entry = "./api/network_fetch.js" }},
        .network = .{ .allow = &allow, .allow_http = true },
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    try initHarness(&harness, text, true);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);

    var url_buffer: [request_path_bytes_max]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/gzip", .{ origin.host(), origin.port });
    var path_buffer: [request_path_bytes_max]u8 = undefined;
    const path = try fetchPath(&path_buffer, "/denied", url, 0);
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    const expected = denialText(&expected_buffer, .http, origin.host(), origin.port, .host_not_allowed);

    var client = try Client.open(&harness);
    defer client.close();
    try expectDeniedAndLogged(&harness, &client, path, expected);
    try std.testing.expectEqual(@as(usize, 0), origin.accepted.load(.acquire));
}

test "local e2e network: a wildcard entry denies its apex before any lookup and admits a subdomain" {
    const allow = [_][]const u8{"*.example.test"};
    const text = try configText(std.testing.allocator, &.{.{
        .name = "wildcard",
        .routes = &.{.{ .path = "/wildcard", .entry = "./api/network_fetch.js" }},
        .network = .{ .allow = &allow, .allow_http = true },
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    try initHarness(&harness, text, true);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    var path_buffer: [request_path_bytes_max]u8 = undefined;
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    try expectDenied(
        &client,
        try fetchPath(&path_buffer, "/wildcard", "http://example.test/", 0),
        denialText(&expected_buffer, .http, "example.test", 80, .host_not_allowed),
    );

    // The subdomain passes the setting and goes to DNS, and the host's
    // resolver decides what follows for a `.test` name, which may include a
    // denial of the resolved address by its class. The fetch may therefore
    // end any way but a refusal before DNS.
    const response = try client.get(try fetchPath(&path_buffer, "/wildcard", "http://a.example.test/", 1000));
    const parsed = try harness_mod.parseReply(FetchOutcome, &response);
    defer parsed.deinit();
    const message = parsed.value.message orelse return;
    for (std.enums.values(Denial)) |denial| {
        switch (denial) {
            // The reasons `admitAddress` gives a resolved address.
            .private_address, .reserved_address => continue,
            .no_grant, .host_not_allowed, .port_not_allowed, .http_not_allowed => {},
        }
        if (std.mem.eql(u8, message, denialText(&expected_buffer, .http, "a.example.test", 80, denial))) {
            std.debug.print("a subdomain of a wildcard entry was refused before DNS: {s}\n", .{message});
            return error.WildcardSubdomainDenied;
        }
    }
}

test "local e2e network: an entry with a port admits only that port, and the other port's origin sees no connection" {
    var granted = try GzipOrigin.start(std.testing.allocator);
    defer granted.stop(std.testing.allocator);
    var other = try GzipOrigin.start(std.testing.allocator);
    defer other.stop(std.testing.allocator);
    var authority_buffer: [authority_bytes_max]u8 = undefined;
    const allow = [_][]const u8{try granted.authority(&authority_buffer)};
    const text = try configText(std.testing.allocator, &.{.{
        .name = "port",
        .routes = &.{.{ .path = "/port", .entry = "./api/network_fetch.js" }},
        .network = try originGrant(&allow, granted.host()),
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    try initHarness(&harness, text, true);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    var url_buffer: [request_path_bytes_max]u8 = undefined;
    var path_buffer: [request_path_bytes_max]u8 = undefined;
    const granted_url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/gzip", .{ granted.host(), granted.port });
    try expectReached(&client, try fetchPath(&path_buffer, "/port", granted_url, 0));

    const other_url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/gzip", .{ other.host(), other.port });
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    try expectDenied(
        &client,
        try fetchPath(&path_buffer, "/port", other_url, 0),
        denialText(&expected_buffer, .http, other.host(), other.port, .port_not_allowed),
    );
    try std.testing.expectEqual(@as(usize, 0), other.accepted.load(.acquire));
}

test "local e2e network: plain HTTP to an origin the grant names without allowHttp is denied with a TypeError and one log line, and the origin sees no connection" {
    var origin = try GzipOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    var authority_buffer: [authority_bytes_max]u8 = undefined;
    const allow = [_][]const u8{try origin.authority(&authority_buffer)};
    const text = try configText(std.testing.allocator, &.{.{
        .name = "https-only",
        .routes = &.{.{ .path = "/https-only", .entry = "./api/network_fetch.js" }},
        // The grant `originGrant` writes, less `allowHttp`.
        .network = .{ .allow = &allow, .allow_private_networks = try isPrivateIpv4(origin.host()) },
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    try initHarness(&harness, text, true);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);

    var url_buffer: [request_path_bytes_max]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/gzip", .{ origin.host(), origin.port });
    var path_buffer: [request_path_bytes_max]u8 = undefined;
    const path = try fetchPath(&path_buffer, "/https-only", url, 0);
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    const expected = denialText(&expected_buffer, .http, origin.host(), origin.port, .http_not_allowed);

    var client = try Client.open(&harness);
    defer client.close();
    try expectDeniedAndLogged(&harness, &client, path, expected);
    try std.testing.expectEqual(@as(usize, 0), origin.accepted.load(.acquire));
}

test "local e2e network: a redirect to an origin the grant does not name is denied on that hop, which never connects" {
    var granted = try GzipOrigin.start(std.testing.allocator);
    defer granted.stop(std.testing.allocator);
    var target = try GzipOrigin.start(std.testing.allocator);
    defer target.stop(std.testing.allocator);
    var authority_buffer: [authority_bytes_max]u8 = undefined;
    const allow = [_][]const u8{try granted.authority(&authority_buffer)};
    const text = try configText(std.testing.allocator, &.{.{
        .name = "redirect",
        .routes = &.{.{ .path = "/redirect", .entry = "./api/network_fetch.js" }},
        .network = try originGrant(&allow, granted.host()),
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    try initHarness(&harness, text, true);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    var url_buffer: [request_path_bytes_max]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}{s}?to={s}:{d}", .{
        granted.host(),
        granted.port,
        GzipOrigin.redirect_path,
        target.host(),
        target.port,
    });
    var path_buffer: [request_path_bytes_max]u8 = undefined;
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    // The denial names the redirect's target, the hop it refused.
    try expectDenied(
        &client,
        try fetchPath(&path_buffer, "/redirect", url, 0),
        denialText(&expected_buffer, .http, target.host(), target.port, .port_not_allowed),
    );
    try std.testing.expectEqual(@as(usize, 1), granted.accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), target.accepted.load(.acquire));
}

test "local e2e network: a private address needs allowPrivateNetworks and an entry that names it, and \"*\" never reaches one" {
    var origin = try GzipOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    if (!try isPrivateIpv4(origin.host())) {
        std.debug.print("this host's routable address {s} is public, so no private address is at hand\n", .{origin.host()});
        return error.SkipZigTest;
    }
    var authority_buffer: [authority_bytes_max]u8 = undefined;
    const any = [_][]const u8{"*"};
    const named = [_][]const u8{try origin.authority(&authority_buffer)};
    const text = try configText(std.testing.allocator, &.{.{
        .name = "private",
        .routes = &.{
            .{ .path = "/any", .entry = "./api/network_fetch.js", .network = .{ .allow = &any, .allow_http = true } },
            .{ .path = "/named", .entry = "./api/network_fetch.js", .network = try originGrant(&named, origin.host()) },
        },
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    try initHarness(&harness, text, true);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    var url_buffer: [request_path_bytes_max]u8 = undefined;
    var path_buffer: [request_path_bytes_max]u8 = undefined;
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    const bare_url = try std.fmt.bufPrint(&url_buffer, "http://{s}/", .{origin.host()});
    try expectDenied(
        &client,
        try fetchPath(&path_buffer, "/any", bare_url, 0),
        denialText(&expected_buffer, .http, origin.host(), 80, .private_address),
    );

    const named_url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/gzip", .{ origin.host(), origin.port });
    try expectReached(&client, try fetchPath(&path_buffer, "/named", named_url, 0));
}

test "local e2e network: loopback, link-local and metadata addresses are denied under \"*\" and under a grant that allows private networks, and the origin sees no connection" {
    var origin = try GzipOrigin.start(std.testing.allocator);
    defer origin.stop(std.testing.allocator);
    const any = [_][]const u8{"*"};
    // An entry may name a private address only with `allowPrivateNetworks`,
    // so this grant carries the flag whatever this host's address is. The
    // addresses below are refused whatever a grant says.
    const private = [_][]const u8{"10.0.0.1"};
    const text = try configText(std.testing.allocator, &.{.{
        .name = "reserved",
        .routes = &.{
            .{ .path = "/any", .entry = "./api/network_fetch.js", .network = .{ .allow = &any, .allow_http = true } },
            .{
                .path = "/private",
                .entry = "./api/network_fetch.js",
                .network = .{ .allow = &private, .allow_http = true, .allow_private_networks = true },
            },
        },
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    try initHarness(&harness, text, true);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    // The origin listens on every IPv4 address and the gateway shares the
    // host's network namespace, so a loopback fetch the gateway let through
    // would reach the origin and show in its count.
    var url_buffer: [request_path_bytes_max]u8 = undefined;
    const loopback_url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/gzip", .{origin.port});
    // Loopback, the IPv4 metadata address, an IPv6 link-local address and
    // AWS's IPv6 metadata address, which lies in the unique-local range a
    // grant with `allowPrivateNetworks` may name. Each comes with the host
    // and port its denial names; the worker serializes an IPv6 host in
    // brackets, and both are written here in that canonical form.
    const targets = [_]struct { url: []const u8, host: []const u8, port: u16 }{
        .{ .url = loopback_url, .host = "127.0.0.1", .port = origin.port },
        .{ .url = "http://169.254.169.254/latest/meta-data/", .host = "169.254.169.254", .port = 80 },
        .{ .url = "http://[fe80::1]/", .host = "[fe80::1]", .port = 80 },
        .{ .url = "http://[fd00:ec2::254]/", .host = "[fd00:ec2::254]", .port = 80 },
    };
    var path_buffer: [request_path_bytes_max]u8 = undefined;
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    for ([_][]const u8{ "/any", "/private" }) |route| {
        for (targets) |target| {
            try expectDenied(
                &client,
                try fetchPath(&path_buffer, route, target.url, 0),
                denialText(&expected_buffer, .http, target.host, target.port, .reserved_address),
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), origin.accepted.load(.acquire));
}

test "local e2e network: a definition without a grant refuses every fetch at once, has no egress session and spawns no gateway" {
    const text = try configText(std.testing.allocator, &.{.{
        .name = "no-grant",
        .routes = &.{.{ .path = "/no-grant", .entry = "./api/network_no_grant.js" }},
    }});
    defer std.testing.allocator.free(text);

    var harness: Harness = undefined;
    try initHarness(&harness, text, false);
    defer harness.deinit();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();

    const response = try client.get("/no-grant");
    const parsed = try harness_mod.parseReply(struct {
        top_level: FetchOutcome,
        request_time: FetchOutcome,
    }, &response);
    defer parsed.deinit();
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    const expected = denialText(&expected_buffer, .http, "no-grant.example.test", 80, .no_grant);
    try expectDeniedOutcome(parsed.value.top_level, expected, response.body());
    try expectDeniedOutcome(parsed.value.request_time, expected, response.body());

    // One line for each fetch: the handler's under its request, the module's
    // top-level one under no request, since a reserved id prints as 0.
    const request_id = try accessRequestId(&harness, "/no-grant");
    var line_ids_buffer: [4]u64 = undefined;
    const line_ids = try denialRequestIds(&harness, expected, 2, &line_ids_buffer);
    try std.testing.expectEqual(@as(usize, 2), line_ids.len);
    var request_lines: usize = 0;
    var unowned_lines: usize = 0;
    for (line_ids) |line_id| {
        if (line_id == request_id) request_lines += 1;
        if (line_id == 0) unowned_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), request_lines);
    try std.testing.expectEqual(@as(usize, 1), unowned_lines);

    const definition = try harness.definitionIndex("no-grant");
    const worker = try harness_mod.soleLiveWorker(&harness, definition);
    try std.testing.expectEqual(@as(u64, 0), worker.record.egress_gateway_session_id);
    try std.testing.expect(!worker.record.egress_wake_set.command_event.isValid());
    try std.testing.expectEqual(@as(u64, 0), harness.gatewayGeneration());
}

test "local e2e network: top-level code keeps its definition's union across Ready, and requests use their own route's grant whatever code calls fetch" {
    try startupUnionCase(.after_ready);
}

test "local e2e network: an awaited startup fetch after the init deadline still uses the union before its evaluation deadline" {
    try startupUnionCase(.after_init_deadline);
}

const StartupRelease = enum { after_ready, after_init_deadline };

fn startupUnionCase(release_at: StartupRelease) !void {
    var origin_a = try GzipOrigin.start(std.testing.allocator);
    defer origin_a.stop(std.testing.allocator);
    var origin_b = try GzipOrigin.start(std.testing.allocator);
    defer origin_b.stop(std.testing.allocator);
    var fixture = try UnionFixture.write(std.testing.allocator, origin_a, origin_b);
    defer fixture.deinit(std.testing.allocator);

    var harness: Harness = undefined;
    try harness.init(.{ .config_path = fixture.config_path });
    defer harness.deinit();
    // On a failed check, answers A's held fetch before the server's teardown.
    defer origin_b.releaseBarrier();
    errdefer harness_mod.dumpZygoteTrace(&harness.spawned);
    var client = try Client.open(&harness);
    defer client.close();
    var ready_client = try Client.open(&harness);
    defer ready_client.close();

    var url_buffer: [request_path_bytes_max]u8 = undefined;
    var path_buffer: [request_path_bytes_max]u8 = undefined;
    var expected_buffer: [collo_network.grant.denial_bytes_max]u8 = undefined;
    const url_a = try std.fmt.allocPrint(std.testing.allocator, "http://{s}:{d}/gzip", .{ origin_a.host(), origin_a.port });
    defer std.testing.allocator.free(url_a);
    const url_b = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/gzip", .{ origin_b.host(), origin_b.port });

    // A's request waits for its evaluation, whose first fetch the origin
    // holds, so the worker reports ready with that evaluation pending, and B
    // serves on the same worker meanwhile.
    const stream_a = try client.sendGet(try fetchPath(&path_buffer, "/union/a", url_b, 0));
    const definition = try harness.definitionIndex("union");
    const worker = try harness_mod.waitForSlotsHeld(&harness, definition, 1);
    const launch = try waitForStartupLaunch(&harness, definition);
    {
        const response = try ready_client.get("/union/b?probe=1");
        const parsed = try harness_mod.parseReply(struct { startup_pending: bool }, &response);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.startup_pending);
    }

    // The timed case uses the launch's clock samples, so time spent starting
    // the harness or waiting for Ready never stands in for the init window.
    const complete_before_ns: ?u64 = switch (release_at) {
        .after_ready => null,
        .after_init_deadline => try waitPastInitDeadline(launch),
    };
    origin_b.releaseBarrier();

    {
        const response = try client.readResponse(stream_a);
        if (complete_before_ns) |deadline_ns|
            try std.testing.expect((try process.monotonicNowNs()) < deadline_ns);
        const parsed = try harness_mod.parseReply(struct {
            top_level: FetchOutcome,
            follow_up: FetchOutcome,
            request_time: FetchOutcome,
        }, &response);
        defer parsed.deinit();
        for ([_]FetchOutcome{ parsed.value.top_level, parsed.value.follow_up }) |outcome| {
            const reached = outcome.status == 200 and
                std.mem.eql(u8, outcome.text orelse "", GzipOrigin.decoded_body);
            if (!reached) {
                std.debug.print("expected both awaited startup fetches of B to reach it: {s}\n", .{response.body()});
                return error.FetchDidNotReachOrigin;
            }
        }
        // A's request cannot use the union its two startup fetches used.
        try expectDeniedOutcome(
            parsed.value.request_time,
            denialText(&expected_buffer, .http, origin_b.host(), origin_b.port, .port_not_allowed),
            response.body(),
        );
    }

    // Route B's handler calls the function route A's module put on the
    // shared global: the fetch runs under B's grant, the turn owner's.
    try expectDenied(
        &ready_client,
        try fetchPath(&path_buffer, "/union/b", url_a, 0),
        denialText(&expected_buffer, .http, origin_a.host(), origin_a.port, .port_not_allowed),
    );
    try expectReached(&ready_client, try fetchPath(&path_buffer, "/union/b", url_b, 0));

    // Every request ran on the one worker the first launch started.
    const after = try harness_mod.waitForSlotsHeld(&harness, definition, 0);
    try std.testing.expect(worker.key.eql(after.key));
    var extra_launches: [4]harness_mod.LaunchTrace = undefined;
    try std.testing.expectEqual(@as(usize, 0), harness.takeLaunches(&extra_launches).len);
}

const startup_poll_interval_ns: u64 = 10 * std.time.ns_per_ms;
const startup_polls_max: usize = 500;

fn waitForStartupLaunch(harness: *Harness, definition: config.DefinitionIndex) !harness_mod.LaunchTrace {
    for (0..startup_polls_max) |_| {
        var traces: [4]harness_mod.LaunchTrace = undefined;
        const launches = harness.takeLaunches(&traces);
        if (launches.len != 0) {
            try std.testing.expectEqual(@as(usize, 1), launches.len);
            const launch = launches[0];
            try std.testing.expectEqual(definition, launch.definition);
            try std.testing.expectEqual(harness_mod.LaunchTrace.Outcome.published, launch.outcome);
            return launch;
        }
        std.Thread.sleep(startup_poll_interval_ns);
    }
    return error.StartupLaunchNotObserved;
}

/// Sleeps until the worker's init deadline has passed and returns the
/// instant by which its startup evaluation must still finish. The init
/// deadline is at most `init_sent_ns` plus `WORKER_INIT_TIMEOUT_MS`, and the
/// evaluation budget starts no earlier than `fork_reply_ns`.
fn waitPastInitDeadline(launch: harness_mod.LaunchTrace) !u64 {
    const init_budget_ns = @as(u64, @intCast(process_limits.WORKER_INIT_TIMEOUT_MS)) * std.time.ns_per_ms;
    const release_after_ns = launch.init_sent_ns + init_budget_ns;
    const complete_before_ns = launch.fork_reply_ns + process_limits.MODULE_EVAL_BUDGET_NS;
    for (0..startup_polls_max) |_| {
        const now_ns = try process.monotonicNowNs();
        if (now_ns >= complete_before_ns) return error.StartupEvaluationWindowMissed;
        if (now_ns > release_after_ns) return complete_before_ns;
        std.Thread.sleep(@min(startup_poll_interval_ns, release_after_ns - now_ns + 1));
    }
    return error.InitDeadlineNotObserved;
}

/// A temporary configuration with one definition of two routes in one shared
/// realm, `/union/a` granted origin A and `/union/b` granted origin B, and
/// their two entries, generated because route A's module names origin B's
/// run-time address at top level.
const UnionFixture = struct {
    directory: []u8,
    config_path: []u8,

    fn write(allocator: std.mem.Allocator, origin_a: *const GzipOrigin, origin_b: *const GzipOrigin) !UnionFixture {
        const directory = try zygote_support.makeTempPath(allocator, "collo-local-e2e-network-union");
        errdefer allocator.free(directory);
        try std.fs.makeDirAbsolute(directory);
        errdefer std.fs.deleteTreeAbsolute(directory) catch {};
        var dir = try std.fs.openDirAbsolute(directory, .{});
        defer dir.close();

        var authority_a_buffer: [authority_bytes_max]u8 = undefined;
        var authority_b_buffer: [authority_bytes_max]u8 = undefined;
        const allow_a = [_][]const u8{try origin_a.authority(&authority_a_buffer)};
        const allow_b = [_][]const u8{try origin_b.authority(&authority_b_buffer)};
        const text = try configText(allocator, &.{.{
            .name = "union",
            .isolate_realm = false,
            .concurrency = 2,
            .routes = &.{
                .{ .path = "/union/a", .entry = "./a.js", .network = try originGrant(&allow_a, origin_a.host()) },
                .{ .path = "/union/b", .entry = "./b.js", .network = try originGrant(&allow_b, origin_b.host()) },
            },
        }});
        defer allocator.free(text);
        try dir.writeFile(.{ .sub_path = "collo.json", .data = text });

        const module_a = try std.fmt.allocPrint(allocator, route_a_source_format, .{
            origin_b.host(), origin_b.port, GzipOrigin.barrier_path,
        });
        defer allocator.free(module_a);
        try dir.writeFile(.{ .sub_path = "a.js", .data = module_a });
        try dir.writeFile(.{ .sub_path = "b.js", .data = route_b_source });

        const config_path = try std.fs.path.join(allocator, &.{ directory, "collo.json" });
        return .{ .directory = directory, .config_path = config_path };
    }

    fn deinit(self: *UnionFixture, allocator: std.mem.Allocator) void {
        std.fs.deleteTreeAbsolute(self.directory) catch {};
        allocator.free(self.config_path);
        allocator.free(self.directory);
        self.* = undefined;
    }

    // Route A: its top-level code fetches origin B twice, the first held at
    // the origin's barrier, and puts on the shared global a function that
    // fetches any URL. A's handler runs only once that evaluation settles.
    const route_a_source_format =
        \\async function outcome(url) {{
        \\  try {{
        \\    const res = await fetch(url);
        \\    return {{ status: res.status, text: await res.text() }};
        \\  }} catch (error) {{
        \\    return {{ error: error.name, message: String(error.message) }};
        \\  }}
        \\}}
        \\
        \\globalThis.fetchOrigin = outcome;
        \\globalThis.unionStartupFinished = false;
        \\const origin = "http://{s}:{d}";
        \\const topLevel = await outcome(origin + "{s}");
        \\const followUp = await outcome(origin + "/gzip");
        \\globalThis.unionStartupFinished = true;
        \\
        \\export default async function handler(req) {{
        \\  return Response.json({{
        \\    top_level: topLevel,
        \\    follow_up: followUp,
        \\    request_time: await outcome(req.query.get("url")),
        \\  }});
        \\}}
        \\
    ;

    // Route B fetches through route A's function; `?probe=1` reports whether
    // A's top-level code is still pending.
    const route_b_source =
        \\export default async function handler(req) {
        \\  if (req.query.get("probe") === "1") {
        \\    return Response.json({ startup_pending: globalThis.unionStartupFinished === false });
        \\  }
        \\  return Response.json(await globalThis.fetchOrigin(req.query.get("url")));
        \\}
        \\
    ;
};
