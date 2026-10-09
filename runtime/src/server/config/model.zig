//! The server configuration after parsing, validation and the settings
//! cascade: global settings, then the worker definitions in file order, each
//! with its resolved settings and its routes.
//!
//! A `Config` owns one arena that holds every string and slice reachable
//! from it, so nothing inside it is freed piecemeal and `deinit` frees all of
//! it. The arena lives behind a pointer, which makes a `Config` safe to move
//! by value. Nothing mutates a `Config` after its constructor returns except
//! a caller that overrides `listen` before handing it on; readers on any
//! thread need no lock.
//!
//! Every value here is final: defaults are filled in, relative paths are
//! absolute (resolved against the configuration file's directory), and a
//! definition's `settings` already merge the global defaults with its own
//! overrides. A configured limit is enforced by the runtime; a limit with no
//! enforcing mechanism is rejected by the parser and has no field here.

const std = @import("std");
const server_limits = @import("collo_limits").server;

pub const Config = struct {
    arena: *std.heap.ArenaAllocator,
    /// Absolute path of the configuration file, or of the entry module the
    /// configuration was synthesized from. Error messages name it.
    path: []const u8,
    /// Address the server listens on. Port 0 asks the kernel for an
    /// ephemeral port.
    listen: std.net.Address,
    /// Null when the server must generate a self-signed certificate.
    tls: ?Tls,
    /// Null when only console lines are written, to stderr.
    analytics: ?Analytics,
    /// The global settings every definition starts from.
    defaults: Settings,
    definitions: []const WorkerDefinition,
    /// Routes across every definition; at least one, at most
    /// `routes_max` in `common/limits/server.zig`.
    route_count: u16,

    pub fn deinit(self: *Config) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }

    pub fn definition(self: *const Config, index: DefinitionIndex) *const WorkerDefinition {
        std.debug.assert(index < self.definitions.len);
        return &self.definitions[index];
    }

    pub fn route(self: *const Config, key: RouteKey) *const Route {
        const owner = self.definition(key.definition);
        std.debug.assert(key.route < owner.routes.len);
        return &owner.routes[key.route];
    }

    pub fn findDefinition(self: *const Config, name: []const u8) ?DefinitionIndex {
        for (self.definitions, 0..) |item, index| {
            if (std.mem.eql(u8, item.name, name))
                return @intCast(index);
        }
        return null;
    }
};

pub const Tls = struct {
    certificate_path: []const u8,
    private_key_path: []const u8,
};

pub const Analytics = struct {
    directory_path: []const u8,
};

/// Settings that cascade from `globalSettings` to a worker definition. A
/// definition overrides only the fields it names.
pub const Settings = struct {
    /// Whether each route of a worker runs in a realm of its own, with its
    /// own globals, intrinsics and module registry; false runs every route of
    /// the worker in one realm. Fixed when the worker starts. Realms separate
    /// state, not trust: a worker's routes share its process and its limits.
    isolate_realm: bool,
    limits: Limits,
};

pub const Limits = struct {
    /// Memory limit of one worker process, shared by its routes.
    memory_mib: u32,
    /// Requests one worker process runs at once, from 1 to
    /// `worker_concurrency_max` in `common/limits/server.zig`.
    concurrency: u8,
    /// Wall-clock deadline of one request, counted from the moment the
    /// server admits it: time spent waiting for a worker or for a cold start
    /// counts against it, and the handler gets what remains.
    timeout_ms: u32,

    pub fn memoryBytes(self: Limits) u64 {
        return @as(u64, self.memory_mib) * 1024 * 1024;
    }

    pub fn timeoutNs(self: Limits) u64 {
        return @as(u64, self.timeout_ms) * std.time.ns_per_ms;
    }
};

pub const WorkerDefinition = struct {
    /// Matches `[a-z0-9-]{1,worker_name_bytes_max}` and is unique.
    name: []const u8,
    settings: Settings,
    /// At least one route, in file order. The index of a route here is its
    /// route index.
    routes: []const Route,
};

pub const Route = struct {
    /// A pattern `pattern.zig` accepts; no other route in the configuration
    /// has the same shape.
    pattern: []const u8,
    /// Absolute, lexically normalized path of the entry module.
    entry_path: []const u8,
    /// Names are unique within the route, in file order.
    bindings: []const Binding,
};

pub const Binding = struct {
    /// Matches `[A-Za-z_][A-Za-z0-9_]*`.
    name: []const u8,
    value: BindingValue,
};

pub const BindingValue = union(enum) {
    text: []const u8,
};

/// Position of a definition in `Config.definitions`.
pub const DefinitionIndex = u16;
/// Position of a route in its definition's `routes`.
pub const RouteIndex = u16;

/// The identity of one route in the configuration. The server assigns it;
/// nothing a worker sends chooses it.
pub const RouteKey = struct {
    definition: DefinitionIndex,
    route: RouteIndex,
};

pub const default_listen = "127.0.0.1:8443";

pub const default_settings: Settings = .{
    .isolate_realm = true,
    .limits = .{
        .memory_mib = 128,
        .concurrency = 2,
        .timeout_ms = 30_000,
    },
};

comptime {
    std.debug.assert(server_limits.worker_definitions_max <= std.math.maxInt(DefinitionIndex) + 1);
    std.debug.assert(server_limits.routes_per_definition_max <= std.math.maxInt(RouteIndex) + 1);
    std.debug.assert(server_limits.routes_max <= std.math.maxInt(u16));
    std.debug.assert(default_settings.limits.memory_mib >= server_limits.worker_memory_mib_min);
    std.debug.assert(default_settings.limits.memory_mib <= server_limits.worker_memory_mib_max);
    std.debug.assert(default_settings.limits.concurrency <= server_limits.worker_concurrency_max);
    std.debug.assert(default_settings.limits.timeout_ms <= server_limits.request_timeout_ms_max);
}
