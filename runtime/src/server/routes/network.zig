//! Every route's `network` grant, compiled once at boot into the policy
//! image the gateway decodes at its hello (`common/network/table.zig`) and
//! the policy ids the server stamps into egress tokens. Nothing here
//! changes after `init`, so the lanes and the supervisor read it from any
//! thread without a lock, for as long as `Routes` lives.
//!
//! Each route's effective `config.Route.network` with a nonempty allow list
//! becomes a grant, and its route's policy is the policy of that one grant;
//! a route without `network`, or with an empty list, maps to policy 0, which
//! admits nothing. A worker definition's boot policy, which its boot token
//! names and so its routes' module top-level code fetches under, is the
//! union of its routes' distinct grants, or 0 when none has one. The union
//! is a policy of several grants, never a merged grant: a fetch is admitted
//! when one grant admits it with that grant's own flags, so one route's
//! `allowHttp` or `allowPrivateNetworks` never reaches another route's
//! hosts. The image builder stores equal grants and equal policies once.
//!
//! A definition is granted exactly when its boot policy is not 0. Only a
//! granted definition gets an egress session and wake set, so a worker of a
//! definition with no grant holds no egress path at all, and a node whose
//! definitions have no grant never starts a gateway.

const std = @import("std");
const config = @import("collo_server_config");
const collo_network = @import("collo_network");
const fd_mod = @import("collo_os").fd;
const server_limits = @import("collo_limits").server;
const sealed = @import("sealed.zig");

const network_table = collo_network.table;

pub const PolicyId = network_table.PolicyId;

/// Policy 0, which every image holds and which admits nothing.
pub const deny_all_id: PolicyId = network_table.deny_all_id;

pub const Error = error{ OutOfMemory, RoutesInvalid, RouteResourcesUnavailable };

pub const NetworkPolicies = struct {
    /// The sealed read-only memfd holding the image; every gateway's hello
    /// carries a duplicate.
    image: fd_mod.OwnedFd,
    /// The image's exact length, which the hello announces and the gateway
    /// checks against the memfd's size.
    image_bytes: u32,
    /// Each route's policy, the policy of route `r` of definition `d` at
    /// `route_first[d] + r`.
    route_policies: []PolicyId,
    /// The index in `route_policies` of each definition's route 0.
    route_first: []u16,
    /// Each definition's boot policy.
    boot_policies: []PolicyId,

    /// Compiles every route of `definitions`, which a parsed `config.Config`
    /// holds. On `error.RoutesInvalid` and `error.RouteResourcesUnavailable`
    /// the diagnostic says what failed.
    pub fn init(
        target: *NetworkPolicies,
        gpa: std.mem.Allocator,
        definitions: []const config.WorkerDefinition,
        diagnostic: *config.Diagnostic,
    ) Error!void {
        std.debug.assert(definitions.len <= server_limits.worker_definitions_max);
        var route_count: usize = 0;
        for (definitions) |definition|
            route_count += definition.routes.len;
        std.debug.assert(route_count <= server_limits.routes_max);

        const route_policies = try gpa.alloc(PolicyId, route_count);
        errdefer gpa.free(route_policies);
        const route_first = try gpa.alloc(u16, definitions.len);
        errdefer gpa.free(route_first);
        const boot_policies = try gpa.alloc(PolicyId, definitions.len);
        errdefer gpa.free(boot_policies);

        var builder = network_table.Builder.init(gpa);
        defer builder.deinit();
        var first: usize = 0;
        for (definitions, route_first, boot_policies) |*definition, *definition_first, *boot_policy| {
            definition_first.* = @intCast(first);
            var members: [server_limits.routes_per_definition_max]network_table.GrantId = undefined;
            var member_count: usize = 0;
            for (definition.routes, route_policies[first..][0..definition.routes.len]) |*route, *route_policy| {
                const grant = try addRouteGrant(&builder, definition, route, diagnostic) orelse {
                    route_policy.* = deny_all_id;
                    continue;
                };
                route_policy.* = try addPolicy(&builder, &.{grant}, definition, diagnostic);
                members[member_count] = grant;
                member_count += 1;
            }
            boot_policy.* = try addPolicy(&builder, members[0..member_count], definition, diagnostic);
            first += definition.routes.len;
        }
        std.debug.assert(first == route_count);

        const image = try builder.encode(gpa);
        defer gpa.free(image);
        std.debug.assert(image.len <= network_table.image_bytes_max);
        const image_fd = sealed.sealBytes("collo-network-policies", image) catch |err| {
            diagnostic.set("cannot seal the network policy image: {s}", .{@errorName(err)});
            return error.RouteResourcesUnavailable;
        };

        target.* = .{
            .image = image_fd,
            .image_bytes = @intCast(image.len),
            .route_policies = route_policies,
            .route_first = route_first,
            .boot_policies = boot_policies,
        };
    }

    pub fn deinit(self: *NetworkPolicies, gpa: std.mem.Allocator) void {
        gpa.free(self.boot_policies);
        gpa.free(self.route_first);
        gpa.free(self.route_policies);
        self.image.deinit();
        self.* = undefined;
    }

    /// The policy a request token of route `key` names.
    pub fn routePolicy(self: *const NetworkPolicies, key: config.RouteKey) PolicyId {
        std.debug.assert(key.definition < self.route_first.len);
        const index = @as(usize, self.route_first[key.definition]) + key.route;
        std.debug.assert(index < self.route_policies.len);
        return self.route_policies[index];
    }

    /// The policy the boot token of a worker of `definition` names: the
    /// union of its routes' grants.
    pub fn bootPolicy(self: *const NetworkPolicies, definition: config.DefinitionIndex) PolicyId {
        std.debug.assert(definition < self.boot_policies.len);
        return self.boot_policies[definition];
    }

    /// Whether some route of `definition` has a grant, which decides
    /// whether its workers get an egress session.
    pub fn definitionGranted(self: *const NetworkPolicies, definition: config.DefinitionIndex) bool {
        return self.bootPolicy(definition) != deny_all_id;
    }

    /// Whether some definition is granted, so a gateway may ever be needed.
    pub fn anyGranted(self: *const NetworkPolicies) bool {
        for (self.boot_policies) |policy| {
            if (policy != deny_all_id)
                return true;
        }
        return false;
    }

    /// The image, borrowed for as long as these policies live.
    pub fn imageFd(self: *const NetworkPolicies) fd_mod.FdRef {
        return self.image.borrow();
    }
};

/// The grant of `route`, or null when its value grants nothing.
fn addRouteGrant(
    builder: *network_table.Builder,
    definition: *const config.WorkerDefinition,
    route: *const config.Route,
    diagnostic: *config.Diagnostic,
) Error!?network_table.GrantId {
    const value = route.network orelse return null;
    if (value.allow.len == 0)
        return null;
    return builder.addGrant(value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The parser checks every value with the rules the builder holds
        // it to, and the configuration's bounds keep the grants and their
        // entries within the image's, so neither is reachable from a parsed
        // configuration.
        error.InvalidSetting, error.InvalidPolicy, error.TableFull => {
            diagnostic.set("worker '{s}' route '{s}': cannot compile its network value: {s}", .{
                definition.name,
                route.pattern,
                @errorName(err),
            });
            return error.RoutesInvalid;
        },
    };
}

fn addPolicy(
    builder: *network_table.Builder,
    grants: []const network_table.GrantId,
    definition: *const config.WorkerDefinition,
    diagnostic: *config.Diagnostic,
) Error!PolicyId {
    return builder.addPolicy(grants) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Every grant id came from this builder, a union holds at most one
        // grant per route of a definition, and the configuration's bounds
        // keep the policies and members within the image's.
        error.InvalidSetting, error.InvalidPolicy, error.TableFull => {
            diagnostic.set("worker '{s}': cannot compile the network policies of its routes: {s}", .{
                definition.name,
                @errorName(err),
            });
            return error.RoutesInvalid;
        },
    };
}
