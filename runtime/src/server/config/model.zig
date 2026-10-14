//! The server configuration after parsing, validation and the settings
//! cascade: the top-level `settings`, then the worker definitions in file
//! order, each with its resolved settings and its routes.
//!
//! A `Config` owns one arena that holds every string and slice reachable
//! from it, so nothing inside it is freed piecemeal and `deinit` frees all of
//! it. The arena lives behind a pointer, which makes a `Config` safe to move
//! by value. Nothing mutates a `Config` after its constructor returns except
//! a caller that overrides `listen` before handing it on; readers on any
//! thread need no lock.
//!
//! Every value here is final: defaults are filled in, relative paths are
//! absolute (resolved against the configuration file's directory), a
//! definition's `settings` already merge `Config.defaults` with its own
//! overrides, and a route's `network` is already the value it runs under.
//! A configured limit is enforced by the runtime; a limit with no enforcing
//! mechanism is rejected by the parser and has no field here.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const collo_network = @import("collo_network");

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
    /// `default_settings` with the top-level `settings` applied; every
    /// definition starts from it.
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

/// Settings that cascade from the top-level `settings` to a worker
/// definition's `settings`. A definition overrides only the fields it names.
pub const Settings = struct {
    /// Whether each route of a worker runs in a realm of its own, with its
    /// own globals, intrinsics and module registry; false runs every route of
    /// the worker in one realm. Fixed when the worker starts. Realms separate
    /// state, not trust: a worker's routes share its process and its limits.
    isolate_realm: bool,
    limits: Limits,
    /// The outbound access a route's `fetch()` has, or null for none. Unlike
    /// the fields above, which merge key by key, a level that names
    /// `network` replaces the inherited value whole: allow lists never
    /// merge, so a level grants exactly what it lists. A route reads its own
    /// effective value from `Route.network`, never from here.
    network: ?Network,
};

/// One `network` value: its allow entries in canonical form, in
/// configuration order, and its two flags. Names point into the `Config`
/// arena. An empty list with neither flag grants nothing, which is how a
/// level drops the value it would inherit.
pub const Network = collo_network.Setting;

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
    /// CPU budget of one request, from 1 to `request_cpu_ms_max`, or null
    /// for none: the worker's VM thread while the request owns it. It is
    /// independent of `timeout_ms` and the first limit reached ends the
    /// request.
    cpu_ms: ?u32,

    pub fn memoryBytes(self: Limits) u64 {
        return @as(u64, self.memory_mib) * 1024 * 1024;
    }

    pub fn timeoutNs(self: Limits) u64 {
        return @as(u64, self.timeout_ms) * std.time.ns_per_ms;
    }

    /// The CPU budget in nanoseconds, 0 for none, as `WorkerInit` carries
    /// it.
    pub fn cpuBudgetNs(self: Limits) u64 {
        const cpu_ms = self.cpu_ms orelse return 0;
        return @as(u64, cpu_ms) * std.time.ns_per_ms;
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
    /// The value the route's requests fetch under: the route's own when it
    /// names `network`, else its definition's `settings.network`, which
    /// already holds the top-level value when the definition names none. Null
    /// or an empty list grants nothing.
    network: ?Network,
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

/// The defaults of a configuration file. A file that names no `network`
/// grants no route any outbound access.
pub const default_settings: Settings = .{
    .isolate_realm = true,
    .limits = .{
        .memory_mib = 128,
        .concurrency = 2,
        .timeout_ms = 30_000,
        .cpu_ms = null,
    },
    .network = null,
};

comptime {
    std.debug.assert(server_limits.worker_definitions_max <= std.math.maxInt(DefinitionIndex) + 1);
    std.debug.assert(server_limits.routes_per_definition_max <= std.math.maxInt(RouteIndex) + 1);
    std.debug.assert(server_limits.routes_max <= std.math.maxInt(u16));
    std.debug.assert(default_settings.limits.memory_mib >= server_limits.worker_memory_mib_min);
    std.debug.assert(default_settings.limits.memory_mib <= server_limits.worker_memory_mib_max);
    std.debug.assert(default_settings.limits.concurrency >= 1);
    std.debug.assert(default_settings.limits.concurrency <= server_limits.worker_concurrency_max);
    std.debug.assert(default_settings.limits.timeout_ms <= server_limits.request_timeout_ms_max);
}
