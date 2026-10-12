//! The network policies compiled from a configuration
//! (`server/routes/network.zig`), read back through the sealed image the
//! way the gateway reads it: routes that share a value share a grant, a flag
//! makes a grant of its own, a route without a grant maps to policy 0, a
//! definition's boot policy is the exact union of its routes' grants, which
//! definitions are granted, the image's seals and its bounds at a
//! worst-case configuration, and allocation failure at every step. What the
//! gateway does with the image is covered by `egress-gateway-test`; the
//! grammar and the matching by `common/tests/network/`.

const std = @import("std");
const config = @import("collo_server_config");
const routes = @import("collo_server_routes");
const collo_network = @import("collo_network");
const fd_mod = @import("collo_os").fd;
const server_limits = @import("collo_limits").server;

const PolicyId = routes.PolicyId;
const config_path = "/srv/app/collo.json";

/// A parsed configuration, its compiled policies and the table the image
/// decodes to.
const Compiled = struct {
    parsed: config.Config,
    policies: routes.NetworkPolicies,
    table: collo_network.Table,

    fn init(target: *Compiled, source: []const u8) !void {
        const allocator = std.testing.allocator;
        var diagnostic: config.Diagnostic = .{};
        target.parsed = config.parse(allocator, source, config_path, &diagnostic) catch |err| {
            std.debug.print("unexpected rejection: {s}\n", .{diagnostic.message()});
            return err;
        };
        errdefer target.parsed.deinit();
        try target.policies.init(allocator, target.parsed.definitions, &diagnostic);
        errdefer target.policies.deinit(allocator);

        const image = try readImage(allocator, &target.policies);
        defer allocator.free(image);
        target.table = try collo_network.Table.decode(allocator, image);
    }

    fn deinit(self: *Compiled) void {
        const allocator = std.testing.allocator;
        self.table.deinit(allocator);
        self.policies.deinit(allocator);
        self.parsed.deinit();
    }

    fn route(self: *const Compiled, definition: config.DefinitionIndex, route_index: config.RouteIndex) PolicyId {
        return self.policies.routePolicy(.{ .definition = definition, .route = route_index });
    }

    /// The decision policy `id` takes on a hop to `host` over `scheme` on
    /// its default port.
    fn decide(self: *const Compiled, id: PolicyId, scheme: collo_network.Scheme, host: []const u8) !collo_network.Decision {
        const policy = self.table.policy(id) orelse return error.TestUnknownPolicy;
        var buffer: [collo_network.pattern.name_bytes_max]u8 = undefined;
        const target = collo_network.Target.init(scheme, host, null, &buffer) orelse return error.TestInvalidHost;
        return collo_network.admit(policy, target);
    }

    fn expectAdmitted(self: *const Compiled, id: PolicyId, scheme: collo_network.Scheme, host: []const u8) !void {
        const decision = try self.decide(id, scheme, host);
        try std.testing.expect(decision == .admitted);
    }

    fn expectDenied(self: *const Compiled, id: PolicyId, scheme: collo_network.Scheme, host: []const u8, denial: collo_network.Denial) !void {
        const decision = try self.decide(id, scheme, host);
        switch (decision) {
            .admitted => return error.TestExpectedDenial,
            .denied => |actual| try std.testing.expectEqual(denial, actual),
        }
    }
};

/// The image's bytes, read from the sealed memfd at offset 0.
fn readImage(allocator: std.mem.Allocator, policies: *const routes.NetworkPolicies) ![]u8 {
    const image = try allocator.alloc(u8, policies.image_bytes);
    errdefer allocator.free(image);
    var filled: usize = 0;
    while (filled < image.len) {
        const read = try std.posix.pread(policies.imageFd().fd(), image[filled..], filled);
        if (read == 0)
            return error.TestShortImage;
        filled += read;
    }
    return image;
}

test "routes that share one value share one grant and one policy" {
    var compiled: Compiled = undefined;
    try compiled.init(
        \\{"globalSettings": {"network": {"allow": ["api.example.com"]}},
        \\ "workers": {
        \\   "a": {"routes": {"/a1": {"entry": "a.js"}, "/a2": {"entry": "a.js"}}},
        \\   "b": {"routes": {"/b": {"entry": "b.js"}}}
        \\ }}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), compiled.table.grants.len);
    // Policy 0 and the one grant's policy, which is also both unions.
    try std.testing.expectEqual(@as(usize, 2), compiled.table.policies.len);
    const shared = compiled.route(0, 0);
    try std.testing.expect(shared != routes.network.deny_all_id);
    try std.testing.expectEqual(shared, compiled.route(0, 1));
    try std.testing.expectEqual(shared, compiled.route(1, 0));
    try std.testing.expectEqual(shared, compiled.policies.bootPolicy(0));
    try std.testing.expectEqual(shared, compiled.policies.bootPolicy(1));
    try compiled.expectAdmitted(shared, .https, "api.example.com");
}

test "two values that differ only in a flag compile to two grants" {
    var compiled: Compiled = undefined;
    try compiled.init(
        \\{"workers": {"api": {"routes": {
        \\   "/https": {"entry": "a.js", "network": {"allow": ["api.example.com"]}},
        \\   "/http": {"entry": "a.js", "network": {"allow": ["API.example.com."], "allowHttp": true}}
        \\ }}}}
    );
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 2), compiled.table.grants.len);
    const https_only = compiled.route(0, 0);
    const with_http = compiled.route(0, 1);
    try std.testing.expect(https_only != with_http);
    try compiled.expectDenied(https_only, .http, "api.example.com", .http_not_allowed);
    try compiled.expectAdmitted(with_http, .http, "api.example.com");
}

test "a route without network and a route with an empty list map to policy 0" {
    var compiled: Compiled = undefined;
    try compiled.init(
        \\{"workers": {"api": {"routes": {
        \\   "/plain": {"entry": "a.js"},
        \\   "/empty": {"entry": "a.js", "network": {"allow": []}},
        \\   "/granted": {"entry": "a.js", "network": {"allow": ["*"]}}
        \\ }}}}
    );
    defer compiled.deinit();

    const deny_all = routes.network.deny_all_id;
    try std.testing.expectEqual(deny_all, compiled.route(0, 0));
    try std.testing.expectEqual(deny_all, compiled.route(0, 1));
    try compiled.expectDenied(deny_all, .https, "api.example.com", .no_grant);
    // The union of one grant is that grant's own policy.
    try std.testing.expect(compiled.route(0, 2) != deny_all);
    try std.testing.expectEqual(compiled.route(0, 2), compiled.policies.bootPolicy(0));
    try std.testing.expect(compiled.policies.definitionGranted(0));
}

test "a definition's boot policy is the union of its routes' grants, each with its own flags" {
    var compiled: Compiled = undefined;
    try compiled.init(
        \\{"workers": {"api": {"routes": {
        \\   "/a": {"entry": "a.js", "network": {"allow": ["a.example.com"], "allowHttp": true}},
        \\   "/b": {"entry": "b.js", "network": {"allow": ["b.example.com"]}}
        \\ }}}}
    );
    defer compiled.deinit();

    const route_a = compiled.route(0, 0);
    const route_b = compiled.route(0, 1);
    const boot = compiled.policies.bootPolicy(0);
    try std.testing.expect(boot != route_a);
    try std.testing.expect(boot != route_b);
    const union_policy = compiled.table.policy(boot) orelse return error.TestUnknownPolicy;
    try std.testing.expectEqual(@as(usize, 2), union_policy.grants.len);

    // The union admits what either route admits, and no more: route A's
    // plain HTTP never reaches route B's host.
    try compiled.expectAdmitted(boot, .http, "a.example.com");
    try compiled.expectAdmitted(boot, .https, "b.example.com");
    try compiled.expectDenied(boot, .http, "b.example.com", .http_not_allowed);
    try compiled.expectDenied(boot, .https, "c.example.com", .host_not_allowed);
    // Each route keeps its own grant only.
    try compiled.expectDenied(route_a, .https, "b.example.com", .host_not_allowed);
    try compiled.expectDenied(route_b, .https, "a.example.com", .host_not_allowed);
}

test "only a definition with a granted route is granted, and a configuration without network grants none" {
    var mixed: Compiled = undefined;
    try mixed.init(
        \\{"workers": {
        \\   "closed": {"routes": {"/c": {"entry": "c.js"}}},
        \\   "open": {"routes": {"/o": {"entry": "o.js", "network": {"allow": ["*"]}}, "/o2": {"entry": "o.js"}}}
        \\ }}
    );
    defer mixed.deinit();
    try std.testing.expect(!mixed.policies.definitionGranted(0));
    try std.testing.expectEqual(routes.network.deny_all_id, mixed.policies.bootPolicy(0));
    try std.testing.expect(mixed.policies.definitionGranted(1));
    try std.testing.expect(mixed.policies.anyGranted());

    var closed: Compiled = undefined;
    try closed.init(
        \\{"workers": {"api": {"routes": {"/x": {"entry": "a.js"}, "/y": {"entry": "a.js"}}}}}
    );
    defer closed.deinit();
    try std.testing.expect(!closed.policies.anyGranted());
    try std.testing.expect(!closed.policies.definitionGranted(0));
    // The image still holds policy 0, which every token of such a
    // configuration would name.
    try std.testing.expectEqual(@as(usize, 0), closed.table.grants.len);
    try std.testing.expectEqual(@as(usize, 1), closed.table.policies.len);
}

/// `definitions` definitions of two routes each, every route with a value of
/// its own; the caller frees it.
fn distinctValuesSource(allocator: std.mem.Allocator, definitions: usize) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "{\"workers\": {");
    for (0..definitions) |definition| {
        if (definition != 0)
            try source.appendSlice(allocator, ", ");
        try source.print(allocator, "\"w{d}\": {{\"routes\": {{", .{definition});
        for (0..2) |route| {
            if (route != 0)
                try source.appendSlice(allocator, ", ");
            try source.print(allocator, "\"/w{d}/r{d}\": {{\"entry\": \"a.js\", \"network\": {{\"allow\": [\"h{d}-{d}.example.com\"]}}}}", .{
                definition,
                route,
                definition,
                route,
            });
        }
        try source.appendSlice(allocator, "}}");
    }
    try source.appendSlice(allocator, "}}");
    return source.toOwnedSlice(allocator);
}

test "the image is sealed, sized as announced, and within its bounds at a worst-case configuration" {
    const allocator = std.testing.allocator;
    // Every route a grant of its own and every definition a union of two:
    // the most distinct policies the route bound allows.
    const definitions = server_limits.routes_max / 2;
    const source = try distinctValuesSource(allocator, definitions);
    defer allocator.free(source);
    var compiled: Compiled = undefined;
    try compiled.init(source);
    defer compiled.deinit();

    const image_fd = compiled.policies.imageFd().fd();
    try fd_mod.requireSeals(image_fd, fd_mod.memfd_readonly_seals);
    const stat = try std.posix.fstat(image_fd);
    try std.testing.expectEqual(@as(i64, compiled.policies.image_bytes), stat.size);

    try std.testing.expectEqual(@as(usize, 2 * definitions), compiled.table.grants.len);
    try std.testing.expectEqual(@as(usize, 1 + 2 * definitions + definitions), compiled.table.policies.len);
    try std.testing.expect(compiled.table.policies.len <= collo_network.table.policies_max);
    for (0..definitions) |index| {
        const definition: config.DefinitionIndex = @intCast(index);
        try std.testing.expect(compiled.policies.definitionGranted(definition));
        try std.testing.expect(compiled.route(definition, 0) != compiled.route(definition, 1));
    }
}

fn compile(allocator: std.mem.Allocator, definitions: []const config.WorkerDefinition) !void {
    var diagnostic: config.Diagnostic = .{};
    var policies: routes.NetworkPolicies = undefined;
    try policies.init(allocator, definitions, &diagnostic);
    policies.deinit(allocator);
}

test "compiling the policies frees everything when any allocation fails" {
    var diagnostic: config.Diagnostic = .{};
    var parsed = try config.parse(std.testing.allocator,
        \\{"globalSettings": {"network": {"allow": ["*", "10.0.0.5:8080"], "allowPrivateNetworks": true}},
        \\ "workers": {"api": {"routes": {
        \\   "/a": {"entry": "a.js"},
        \\   "/b": {"entry": "a.js", "network": {"allow": ["*.example.com"], "allowHttp": true}}
        \\ }}}}
    , config_path, &diagnostic);
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compile, .{parsed.definitions});
}
