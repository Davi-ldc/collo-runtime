//! What every worker of one definition needs, built once at boot from the
//! configuration and immutable until shutdown: a sealed memfd with the
//! module pack of every module the definition's routes can load
//! (`module_graph.zig`), a sealed memfd with the definition's route table
//! (each route's entry specifier and text bindings, in route order;
//! `common/ipc/route_table.zig`), and the filesystem index. A worker serves
//! every route of its definition, so these are per definition, not per
//! route, and a dispatch names its route by its index in the table.
//!
//! Module specifiers follow the engine's transport layout (the header of
//! `bindings/jsc/runtime/module_loader.cpp`): every module of a definition's
//! routes is keyed `/__collo_route/<worker>/<path>`, where `<worker>` is the
//! definition's name and `<path>` is the module's path relative to the
//! deepest directory holding every module of the definition
//! (`Graph.commonDirectory`). A relative import then resolves in key space to
//! the key of the file it names on disk, and tenant code sees the same path
//! under `/var/task/`. Two routes with the same entry file share its key.
//!
//! `<worker>` is one segment per definition because a worker process serves
//! every route of its definition and its VM accepts a single segment: the
//! first pack it registers pins it, and a later pack under another one is
//! refused (`registerModulePackLocked` in
//! `bindings/jsc/runtime/module_loader.cpp`). Within a pack, every module
//! must share one segment (`validateSameDeployScopedPack` in
//! `common/ipc/module_pack.zig`).
//!
//! The pack holds each module some route reaches exactly once: route 0's
//! entry and what it reaches first, breadth first, then whatever each later
//! route adds, in route order. It is built with the host's graph pack builder
//! (`createModulePackGraphFd` in `host/dispatch.zig`) with route 0's entry as
//! its entry. The route table is built with `ipc.route_table`, one section
//! per route with one entry per text binding. The filesystem index is the
//! empty placeholder every definition shares until filesystem bindings
//! exist; `Routes` owns it.
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
const route_table = ipc.route_table;
const Diagnostic = config.Diagnostic;

pub const Error = module_graph.Error;

pub const DefinitionArtifact = struct {
    /// Sealed read-only memfd holding every module the definition's routes
    /// reach, each once; route 0's entry is its module 0.
    module_pack: fd_mod.OwnedFd,
    module_pack_bytes: u64,
    module_count: u32,
    /// Sealed read-only memfd with every route's entry specifier and text
    /// bindings, in route order.
    route_table: route_table.Sealed,
    /// The shared placeholder index; borrowed from `Routes`.
    fs_index: fd_mod.FdRef,

    pub fn deinit(self: *DefinitionArtifact) void {
        self.module_pack.deinit();
        self.route_table.close();
        self.* = undefined;
    }
};

pub const BuildContext = struct {
    gpa: std.mem.Allocator,
    fs_index: fd_mod.FdRef,
    /// Pack bytes built so far for every definition, bounded by
    /// `pack_bytes_total_max`.
    pack_bytes_total: *u64,
    diagnostic: *Diagnostic,
};

/// Builds the artifact of `definition`. On `error.RouteBuildFailed` the
/// diagnostic names the worker, and the route or module at fault when one
/// is.
pub fn buildDefinition(
    context: BuildContext,
    definition: *const config.WorkerDefinition,
) Error!DefinitionArtifact {
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

    var pack = try buildPack(context, scratch, definition, &graph, keys, entries);
    errdefer pack.fd.deinit();
    const table = try buildRouteTable(context, scratch, definition, keys, entries);
    return .{
        .module_pack = pack.fd,
        .module_pack_bytes = pack.bytes,
        .module_count = pack.module_count,
        .route_table = table,
        .fs_index = context.fs_index,
    };
}

const BuiltPack = struct {
    fd: fd_mod.OwnedFd,
    bytes: u64,
    module_count: u32,
};

/// The definition's pack: every module some route reaches, once, in the
/// order the file header gives.
fn buildPack(
    context: BuildContext,
    scratch: std.mem.Allocator,
    definition: *const config.WorkerDefinition,
    graph: *const module_graph.Graph,
    keys: []const []const u8,
    entries: []const u32,
) Error!BuiltPack {
    var order: std.ArrayList(u32) = .empty;
    var included = try std.DynamicBitSetUnmanaged.initEmpty(scratch, graph.modules.items.len);
    var reached: std.ArrayList(u32) = .empty;
    for (entries) |entry| {
        reached.clearRetainingCapacity();
        try graph.reachable(entry, &reached);
        for (reached.items) |module_index| {
            if (included.isSet(module_index))
                continue;
            included.set(module_index);
            try order.append(scratch, module_index);
        }
    }
    std.debug.assert(order.items[0] == entries[0]);

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
        error.ModulePackTooLarge => return failWorker(context.diagnostic, definition, "the module pack exceeds {d} bytes", .{module_pack.max_pack_bytes}),
        else => return failWorker(context.diagnostic, definition, "cannot build the module pack: {s}", .{@errorName(err)}),
    };
    var pack = fd_mod.OwnedFd.fromRaw(raw_pack);
    errdefer pack.deinit();
    const pack_stat = std.posix.fstat(pack.fd()) catch |err|
        return failWorker(context.diagnostic, definition, "cannot read the module pack size: {s}", .{@errorName(err)});
    const pack_bytes: u64 = @intCast(pack_stat.size);
    context.pack_bytes_total.* += pack_bytes;
    if (context.pack_bytes_total.* > server_limits.pack_bytes_total_max)
        return failWorker(context.diagnostic, definition, "the module packs of all workers exceed {d} bytes", .{server_limits.pack_bytes_total_max});
    return .{ .fd = pack, .bytes = pack_bytes, .module_count = @intCast(order.items.len) };
}

/// The definition's route table: each route's entry key and text bindings,
/// in route order.
fn buildRouteTable(
    context: BuildContext,
    scratch: std.mem.Allocator,
    definition: *const config.WorkerDefinition,
    keys: []const []const u8,
    entries: []const u32,
) Error!route_table.Sealed {
    const inputs = try scratch.alloc(route_table.RouteInput, definition.routes.len);
    for (definition.routes, entries, inputs) |*route, entry, *input| {
        const entry_key = keys[entry];
        if (entry_key.len > route_table.entry_specifier_bytes_max) {
            const label: module_graph.Label = .{ .worker = definition.name, .pattern = route.pattern };
            return failRoute(context.diagnostic, label, "the entry specifier {s} exceeds {d} bytes", .{ entry_key, route_table.entry_specifier_bytes_max });
        }
        const binding_entries = try scratch.alloc(route_bindings.Entry, route.bindings.len);
        for (route.bindings, binding_entries) |binding, *binding_entry| {
            binding_entry.* = switch (binding.value) {
                .text => |text| .{ .name = binding.name, .value = text },
            };
        }
        input.* = .{ .entry_specifier = entry_key, .bindings = binding_entries };
    }
    return route_table.buildSealed(context.gpa, inputs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failWorker(context.diagnostic, definition, "cannot build the route table: {s}", .{@errorName(err)}),
    };
}

/// `/__collo_route/<worker>/<path below root>`.
fn moduleKey(allocator: std.mem.Allocator, worker: []const u8, root: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    std.debug.assert(std.mem.startsWith(u8, path, root));
    const relative = std.mem.trimLeft(u8, path[root.len..], "/");
    std.debug.assert(relative.len != 0);
    return std.mem.concat(allocator, u8, &.{ module_pack.route_specifier_prefix, worker, "/", relative });
}

fn failWorker(diagnostic: *Diagnostic, definition: *const config.WorkerDefinition, comptime format: []const u8, args: anytype) Error {
    diagnostic.set("worker '{s}': " ++ format, .{definition.name} ++ args);
    return error.RouteBuildFailed;
}

fn failRoute(diagnostic: *Diagnostic, label: module_graph.Label, comptime format: []const u8, args: anytype) Error {
    diagnostic.set("worker '{s}' route '{s}': " ++ format, .{ label.worker, label.pattern } ++ args);
    return error.RouteBuildFailed;
}
