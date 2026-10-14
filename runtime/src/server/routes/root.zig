//! The server's routes: the configuration, the route table that matches
//! request paths against it, every definition's artifact and every route's
//! network policy, built together at boot and immutable until shutdown.
//!
//! - `table.zig`: the path trie and its bounds.
//! - `artifacts.zig`: one definition's artifact, the sealed pack of its
//!   modules and routes, and how it is built.
//! - `module_graph.zig`: the import graph read from disk, confined to the
//!   definition's root.
//! - `imports.zig`: the lexical scan that finds a module's static imports
//!   and its string-literal `import()` calls.
//! - `network.zig`: the `network` grants compiled into the gateway's policy
//!   image, each route's and each definition's policy id, and which
//!   definitions are granted.
//! - `sealed.zig`: the sealed memfd every blob built here travels in.
//!
//! A failure of `init` is the configuration's (`error.RoutesInvalid`: a
//! route the table refuses, a module that cannot be read or packed, an
//! import that leaves its definition's root) or the server's
//! (`error.RouteResourcesUnavailable`: a memfd, a descriptor quota, an I/O
//! error), so boot can tell an operator which one to fix.
//!
//! `Routes` owns all of it. Once `init` returns nothing mutates it, so the
//! ingress lanes and the supervisor read it from any thread without leases,
//! reference counts or locks; its owner calls `deinit` only after every
//! thread that reads it has stopped, because slices and descriptors handed
//! out by the lookups stay valid exactly that long. A route is addressed by
//! its `config.RouteKey`, which the server assigns; a key never comes from a
//! worker. Its `route` field is also the route's index in its definition's
//! artifact, which is how a dispatch names the route to the worker.

const std = @import("std");
const config = @import("collo_server_config");

pub const table = @import("table.zig");
pub const artifacts = @import("artifacts.zig");
pub const module_graph = @import("module_graph.zig");
pub const imports = @import("imports.zig");
pub const network = @import("network.zig");

pub const Table = table.Table;
pub const Match = table.Match;
pub const Captures = table.Captures;
pub const RouteCapture = table.RouteCapture;
pub const DefinitionArtifact = artifacts.DefinitionArtifact;
pub const NetworkPolicies = network.NetworkPolicies;
pub const PolicyId = network.PolicyId;

pub const Error = error{ OutOfMemory, RoutesInvalid, RouteResourcesUnavailable };

pub const Routes = struct {
    gpa: std.mem.Allocator,
    config: config.Config,
    table: Table,
    /// Every definition's artifact, in definition order.
    artifacts: []DefinitionArtifact,
    /// Bytes of every definition's module pack together.
    pack_bytes_total: u64,
    /// The policy image, each route's and each definition's policy.
    network: NetworkPolicies,

    /// Builds the table, every definition's artifact and the network
    /// policies from `routes_config`, reading each entry's import graph from
    /// disk. `routes_config` is consumed on every call: on success `Routes`
    /// owns it, on failure it is freed. On `error.RoutesInvalid` and
    /// `error.RouteResourcesUnavailable` the diagnostic says what failed,
    /// naming the worker, and the route and the file when one of them is at
    /// fault.
    pub fn init(
        target: *Routes,
        gpa: std.mem.Allocator,
        routes_config: config.Config,
        diagnostic: *config.Diagnostic,
    ) Error!void {
        var owned_config = routes_config;
        errdefer owned_config.deinit();

        var route_table: Table = undefined;
        route_table.init(gpa, owned_config.definitions) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRoutePattern, error.DuplicateRoute, error.TooManyRoutes => {
                diagnostic.set("{s}: the route table rejected the configuration: {s}", .{ owned_config.path, @errorName(err) });
                return error.RoutesInvalid;
            },
        };
        errdefer route_table.deinit(gpa);

        const definitions = owned_config.definitions;
        const definition_artifacts = try gpa.alloc(DefinitionArtifact, definitions.len);
        errdefer gpa.free(definition_artifacts);
        var pack_bytes_total: u64 = 0;
        var built: usize = 0;
        errdefer for (definition_artifacts[0..built]) |*item| item.deinit();
        for (definitions, definition_artifacts) |*owner, *slot| {
            slot.* = try artifacts.buildDefinition(.{
                .gpa = gpa,
                .pack_bytes_total = &pack_bytes_total,
                .diagnostic = diagnostic,
            }, owner);
            built += 1;
        }

        var network_policies: NetworkPolicies = undefined;
        try network_policies.init(gpa, definitions, diagnostic);

        target.* = .{
            .gpa = gpa,
            .config = owned_config,
            .table = route_table,
            .artifacts = definition_artifacts,
            .pack_bytes_total = pack_bytes_total,
            .network = network_policies,
        };
    }

    /// Call only after every thread that reads these routes has stopped.
    pub fn deinit(self: *Routes) void {
        self.network.deinit(self.gpa);
        for (self.artifacts) |*item|
            item.deinit();
        self.gpa.free(self.artifacts);
        self.table.deinit(self.gpa);
        self.config.deinit();
        self.* = undefined;
    }

    /// The route serving `path`, without allocating; see `Table.match`.
    pub fn match(self: *const Routes, path: []const u8, captures: *Captures) table.MatchError!?Match {
        return self.table.match(path, captures);
    }

    pub fn definitionCount(self: *const Routes) u16 {
        return @intCast(self.config.definitions.len);
    }

    pub fn definition(self: *const Routes, index: config.DefinitionIndex) *const config.WorkerDefinition {
        return self.config.definition(index);
    }

    pub fn route(self: *const Routes, key: config.RouteKey) *const config.Route {
        return self.config.route(key);
    }

    pub fn artifact(self: *const Routes, index: config.DefinitionIndex) *const DefinitionArtifact {
        std.debug.assert(index < self.artifacts.len);
        return &self.artifacts[index];
    }
};
