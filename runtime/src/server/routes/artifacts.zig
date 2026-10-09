//! What a worker needs to run one route, built once at boot from the
//! configuration and immutable until shutdown: the route's entry specifier,
//! a sealed memfd with the module pack of every module the entry can load
//! (`module_graph.zig`), a sealed memfd with the route's bindings, and the
//! filesystem index.
//!
//! Module specifiers follow the engine's transport layout (the header of
//! `bindings/jsc/runtime/module_loader.cpp`): every module of a definition's
//! routes is keyed `/__collo_route/<worker>/<path>`, where `<worker>` is the
//! definition's name and `<path>` is the module's path relative to the
//! deepest directory holding every module of the definition
//! (`Graph.commonDirectory`). A relative import then resolves in key space to
//! the key of the file it names on disk, and tenant code sees the same path
//! under `/var/task/`.
//!
//! `<worker>` is one segment per definition because a worker process can
//! serve any route of its definition and its VM accepts a single segment:
//! the first pack it registers pins it, and a later pack under another one
//! is refused (`registerModulePackLocked` in
//! `bindings/jsc/runtime/module_loader.cpp`). Within a pack, every module
//! must share its entry's segment (`validateSameDeployScopedPack` in
//! `common/ipc/module_pack.zig`).
//!
//! The pack is built with the host's graph pack builder
//! (`createModulePackGraphFd` in `host/dispatch.zig`) with the entry first,
//! and the bindings blob with `ipc.route_bindings`, one entry per text
//! binding. The filesystem index is the empty placeholder every route shares
//! until filesystem bindings exist; `Routes` owns it.
//!
//! The memfds are sealed read-only, so any thread may duplicate them or pass
//! them over SCM_RIGHTS while the server runs; nobody reads them through the
//! shared file offset, and workers map them at offset 0.

const std = @import("std");
const config = @import("collo_server_config");
const host = @import("collo_host");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const server_limits = @import("collo_limits").server;
const module_graph = @import("module_graph.zig");

const module_pack = ipc.module_pack;
const route_bindings = ipc.route_bindings;
const Diagnostic = config.Diagnostic;

pub const Error = module_graph.Error;

pub const RouteArtifact = struct {
    /// The specifier the worker registers and evaluates the entry under;
    /// owned by the `Routes` arena.
    entry_specifier: []const u8,
    /// Sealed read-only memfd holding the pack; the entry is its module 0.
    module_pack: fd_mod.OwnedFd,
    module_pack_bytes: u64,
    module_count: u32,
    /// Sealed read-only memfd with the route's text bindings, name and
    /// value per entry, in configuration order.
    bindings: route_bindings.Sealed,
    /// The shared placeholder index; borrowed from `Routes`.
    fs_index: fd_mod.FdRef,

    pub fn deinit(self: *RouteArtifact) void {
        self.module_pack.deinit();
        self.bindings.close();
        self.* = undefined;
    }
};

pub const BuildContext = struct {
    gpa: std.mem.Allocator,
    /// Holds the entry specifiers for as long as the artifacts live.
    arena: std.mem.Allocator,
    fs_index: fd_mod.FdRef,
    /// Pack bytes built so far for every definition, bounded by
    /// `pack_bytes_total_max`.
    pack_bytes_total: *u64,
    diagnostic: *Diagnostic,
};

/// Builds the artifacts of every route of `definition` into `out`, in route
/// order. On error the artifacts this call built are closed again, and on
/// `error.RouteBuildFailed` the diagnostic names the worker and the route or
/// module at fault.
pub fn buildDefinition(
    context: BuildContext,
    definition: *const config.WorkerDefinition,
    out: []RouteArtifact,
) Error!void {
    std.debug.assert(out.len == definition.routes.len);
    var scratch_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var graph: module_graph.Graph = .{ .arena = scratch };
    const entries = try scratch.alloc(u32, definition.routes.len);
    for (definition.routes, entries) |route, *entry| {
        const label: module_graph.Label = .{ .worker = definition.name, .pattern = route.pattern };
        entry.* = try graph.addEntry(route.entry_path, label, context.diagnostic);
    }

    const root = graph.commonDirectory();
    const keys = try scratch.alloc([]const u8, graph.modules.items.len);
    for (graph.modules.items, keys) |module, *key| {
        key.* = try moduleKey(scratch, definition.name, root, module.path);
        module_pack.validateSpecifier(key.*) catch {
            context.diagnostic.set("worker '{s}': module {s} has a path that cannot be a module specifier (it holds a space, '?', '#', '\\' or a control byte)", .{
                definition.name,
                module.path,
            });
            return error.RouteBuildFailed;
        };
    }

    var built: usize = 0;
    errdefer for (out[0..built]) |*artifact| artifact.deinit();
    for (definition.routes, entries, out) |*route, entry, *artifact| {
        const label: module_graph.Label = .{ .worker = definition.name, .pattern = route.pattern };
        artifact.* = try buildRoute(context, scratch, &graph, keys, route, entry, label);
        built += 1;
    }
}

fn buildRoute(
    context: BuildContext,
    scratch: std.mem.Allocator,
    graph: *const module_graph.Graph,
    keys: []const []const u8,
    route: *const config.Route,
    entry: u32,
    label: module_graph.Label,
) Error!RouteArtifact {
    const entry_key = keys[entry];
    if (entry_key.len > ipc.WorkerInit.max_route_entry_specifier_bytes)
        return fail(context.diagnostic, label, "the entry specifier {s} exceeds {d} bytes", .{ entry_key, ipc.WorkerInit.max_route_entry_specifier_bytes });

    var order: std.ArrayList(u32) = .empty;
    try graph.reachable(entry, &order);
    const modules = try scratch.alloc(module_pack.Module, order.items.len);
    for (order.items, modules) |module_index, *packed_module| {
        const module = graph.modules.items[module_index];
        const dependencies = try scratch.alloc(module_pack.Dependency, module.imports.len);
        for (module.imports, dependencies) |imported, *dependency|
            dependency.* = .{ .specifier = keys[imported] };
        packed_module.* = .{
            .specifier = keys[module_index],
            .source = module.source,
            .dependencies = dependencies,
        };
    }

    const raw_pack = host.dispatch.createModulePackGraphFd(context.gpa, modules, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ModulePackTooLarge => return fail(context.diagnostic, label, "the module pack exceeds {d} bytes", .{module_pack.max_pack_bytes}),
        else => return fail(context.diagnostic, label, "cannot build the module pack: {s}", .{@errorName(err)}),
    };
    var pack = fd_mod.OwnedFd.fromRaw(raw_pack);
    errdefer pack.deinit();
    const pack_stat = std.posix.fstat(pack.fd()) catch |err|
        return fail(context.diagnostic, label, "cannot read the module pack size: {s}", .{@errorName(err)});
    const pack_bytes: u64 = @intCast(pack_stat.size);
    context.pack_bytes_total.* += pack_bytes;
    if (context.pack_bytes_total.* > server_limits.pack_bytes_total_max)
        return fail(context.diagnostic, label, "the module packs of all routes exceed {d} bytes", .{server_limits.pack_bytes_total_max});

    const binding_entries = try scratch.alloc(route_bindings.Entry, route.bindings.len);
    for (route.bindings, binding_entries) |binding, *binding_entry| {
        binding_entry.* = switch (binding.value) {
            .text => |text| .{ .name = binding.name, .value = text },
        };
    }
    const bindings = route_bindings.buildSealed(context.gpa, binding_entries) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(context.diagnostic, label, "cannot build the bindings blob: {s}", .{@errorName(err)}),
    };
    errdefer bindings.close();

    return .{
        .entry_specifier = try context.arena.dupe(u8, entry_key),
        .module_pack = pack,
        .module_pack_bytes = pack_bytes,
        .module_count = @intCast(order.items.len),
        .bindings = bindings,
        .fs_index = context.fs_index,
    };
}

/// `/__collo_route/<worker>/<path below root>`.
fn moduleKey(allocator: std.mem.Allocator, worker: []const u8, root: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    std.debug.assert(std.mem.startsWith(u8, path, root));
    const relative = std.mem.trimLeft(u8, path[root.len..], "/");
    std.debug.assert(relative.len != 0);
    return std.mem.concat(allocator, u8, &.{ module_pack.route_specifier_prefix, worker, "/", relative });
}

fn fail(diagnostic: *Diagnostic, label: module_graph.Label, comptime format: []const u8, args: anytype) Error {
    diagnostic.set("worker '{s}' route '{s}': " ++ format, .{ label.worker, label.pattern } ++ args);
    return error.RouteBuildFailed;
}
