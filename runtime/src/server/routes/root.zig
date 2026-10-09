//! The server's routes: the configuration, the route table that matches
//! request paths against it, and every route's artifacts, built together at
//! boot and immutable until shutdown.
//!
//! - `table.zig`: the path trie and its bounds.
//! - `artifacts.zig`: one route's entry specifier, module pack, bindings
//!   blob and filesystem index, and how they are built.
//! - `module_graph.zig`: the import graph read from disk.
//! - `imports.zig`: the lexical scan that finds a module's static imports
//!   and its string-literal `import()` calls.
//!
//! `Routes` owns all of it. Once `init` returns nothing mutates it, so the
//! ingress lanes and the supervisor read it from any thread without leases,
//! reference counts or locks; its owner calls `deinit` only after every
//! thread that reads it has stopped, because slices and descriptors handed
//! out by the lookups stay valid exactly that long. A route is addressed by
//! its `config.RouteKey`, which the server assigns; a key never comes from a
//! worker.

const std = @import("std");
const config = @import("collo_server_config");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

pub const table = @import("table.zig");
pub const artifacts = @import("artifacts.zig");
pub const module_graph = @import("module_graph.zig");
pub const imports = @import("imports.zig");

pub const Table = table.Table;
pub const Match = table.Match;
pub const Captures = table.Captures;
pub const RouteCapture = table.RouteCapture;
pub const RouteArtifact = artifacts.RouteArtifact;

pub const Error = error{ OutOfMemory, RouteBuildFailed };

pub const Routes = struct {
    gpa: std.mem.Allocator,
    /// Holds the artifact array, the definition offsets and the entry
    /// specifiers.
    arena: *std.heap.ArenaAllocator,
    config: config.Config,
    table: Table,
    /// Every route's artifacts in configuration order: definition 0's
    /// routes, then definition 1's, and so on.
    artifacts: []RouteArtifact,
    /// Index into `artifacts` of each definition's first route.
    first_artifact: []const u16,
    /// The placeholder filesystem index every artifact borrows.
    fs_index: fd_mod.OwnedFd,
    /// Bytes of every route's module pack together.
    pack_bytes_total: u64,

    /// Builds the table and every route's artifacts from `routes_config`,
    /// reading each entry's import graph from disk. `routes_config`
    /// is consumed on every call: on success `Routes` owns it, on failure it
    /// is freed. On `error.RouteBuildFailed` the diagnostic says what failed,
    /// naming the route and the file when one of them is at fault.
    pub fn init(
        target: *Routes,
        gpa: std.mem.Allocator,
        routes_config: config.Config,
        diagnostic: *config.Diagnostic,
    ) Error!void {
        var owned_config = routes_config;
        errdefer owned_config.deinit();

        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        var route_table: Table = undefined;
        route_table.init(gpa, owned_config.definitions) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRoutePattern, error.DuplicateRoute, error.TooManyRoutes => {
                diagnostic.set("{s}: the route table rejected the configuration: {s}", .{ owned_config.path, @errorName(err) });
                return error.RouteBuildFailed;
            },
        };
        errdefer route_table.deinit(gpa);

        const raw_fs_index = ipc.zygote_worker.createPlaceholderFsIndexMemfd() catch |err| {
            diagnostic.set("cannot create the filesystem index: {s}", .{@errorName(err)});
            return error.RouteBuildFailed;
        };
        var fs_index = fd_mod.OwnedFd.fromRaw(raw_fs_index);
        errdefer fs_index.deinit();

        const definitions = owned_config.definitions;
        const route_artifacts = try arena.allocator().alloc(RouteArtifact, owned_config.route_count);
        const first_artifact = try arena.allocator().alloc(u16, definitions.len);
        var pack_bytes_total: u64 = 0;
        var built: usize = 0;
        errdefer for (route_artifacts[0..built]) |*item| item.deinit();
        for (definitions, first_artifact) |*owner, *first| {
            first.* = @intCast(built);
            try artifacts.buildDefinition(.{
                .gpa = gpa,
                .arena = arena.allocator(),
                .fs_index = fs_index.borrow(),
                .pack_bytes_total = &pack_bytes_total,
                .diagnostic = diagnostic,
            }, owner, route_artifacts[built..][0..owner.routes.len]);
            built += owner.routes.len;
        }
        std.debug.assert(built == route_artifacts.len);

        target.* = .{
            .gpa = gpa,
            .arena = arena,
            .config = owned_config,
            .table = route_table,
            .artifacts = route_artifacts,
            .first_artifact = first_artifact,
            .fs_index = fs_index,
            .pack_bytes_total = pack_bytes_total,
        };
    }

    /// Call only after every thread that reads these routes has stopped.
    pub fn deinit(self: *Routes) void {
        for (self.artifacts) |*item|
            item.deinit();
        self.fs_index.deinit();
        self.table.deinit(self.gpa);
        self.config.deinit();
        self.arena.deinit();
        self.gpa.destroy(self.arena);
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

    pub fn artifact(self: *const Routes, key: config.RouteKey) *const RouteArtifact {
        const owner = self.config.definition(key.definition);
        std.debug.assert(key.route < owner.routes.len);
        return &self.artifacts[self.first_artifact[key.definition] + key.route];
    }
};
