//! What every worker of one definition needs, built once at boot from the
//! configuration and immutable until shutdown: the definition's artifact
//! (`common/ipc/module_pack.zig`), one sealed memfd holding every module the
//! definition's routes can load (`module_graph.zig`) and every route, as its
//! entry module and its text bindings, in route order
//! (`common/ipc/route_table.zig`). A worker serves every route
//! of its definition, so the artifact is per definition, not per route, and
//! a dispatch names its route by its index in the artifact.
//!
//! The graph reads only files within the definition's root, the deepest
//! directory holding every route's entry (`definitionRoot`), so one
//! definition's code cannot pull another's files into its artifact
//! (`module_graph.zig` says how the confinement holds). For `collo serve
//! app.js` the root is the entry's directory; for a `collo.json`, it is the
//! deepest directory holding the entries of the definition's routes, which
//! the configuration resolves against its own directory.
//!
//! Every module is keyed by its public specifier, `<task_root>/<path>`, where
//! `<path>` is the module's path relative to the graph's key directory
//! (`Graph.keyDirectory`): the root, or the ancestor of it that a packed
//! import climbs to before it descends again. A relative import then
//! resolves in the engine's loader to the key of the file it names on disk,
//! and tenant code sees the same path in `import.meta` and in stack frames.
//! Two routes with the same entry file name the same module.
//!
//! The pack holds each module some route reaches exactly once: route 0's
//! entry and what it reaches first, breadth first, then whatever each later
//! route adds, in route order. `module_pack.buildAlloc` transcodes each
//! source from UTF-8 into the form the engine wraps without a copy, so a
//! module with text above U+00FF takes two bytes per character; the pack's
//! bound (`max_pack_bytes`) covers the sources and the routes' bindings
//! together, and every definition's pack counts against
//! `pack_bytes_total_max`.
//!
//! A failure is either the configuration's, `error.RoutesInvalid` (a root
//! that cannot be opened, a module that cannot be read or packed, a pack
//! over its bound), or the server's, `error.RouteResourcesUnavailable` (a
//! memfd, a descriptor quota, an I/O error), and every callee's errors are
//! assigned to one of the two here.
//!
//! The memfd is sealed read-only, so any thread may duplicate it or pass it
//! over SCM_RIGHTS while the server runs; nobody reads it through the shared
//! file offset, and workers map it at offset 0.

const std = @import("std");
const config = @import("collo_server_config");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const server_limits = @import("collo_limits").server;
const module_graph = @import("module_graph.zig");
const sealed = @import("sealed.zig");

const module_pack = ipc.module_pack;
const route_bindings = ipc.route_bindings;
const route_table = ipc.route_table;
const Diagnostic = config.Diagnostic;

pub const Error = module_graph.Error;

pub const DefinitionArtifact = struct {
    /// Sealed read-only memfd holding the definition's artifact: every module
    /// the routes reach, each once, and every route in route order.
    module_pack: fd_mod.OwnedFd,
    module_pack_bytes: u64,
    module_count: u32,

    pub fn deinit(self: *DefinitionArtifact) void {
        self.module_pack.deinit();
        self.* = undefined;
    }
};

pub const BuildContext = struct {
    gpa: std.mem.Allocator,
    /// Pack bytes built so far for every definition, bounded by
    /// `pack_bytes_total_max`.
    pack_bytes_total: *u64,
    diagnostic: *Diagnostic,
};

/// Builds the artifact of `definition`. On `error.RoutesInvalid` and
/// `error.RouteResourcesUnavailable` the diagnostic names the worker, and
/// the route or module at fault when one is.
pub fn buildDefinition(
    context: BuildContext,
    definition: *const config.WorkerDefinition,
) Error!DefinitionArtifact {
    var scratch_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const root_path = definitionRoot(definition);
    var root = module_graph.Root.open(root_path) catch |err| switch (err) {
        // What the configuration names: a directory that is missing, not a
        // directory, through a loop, too long, or one the server may not
        // open.
        error.FileNotFound,
        error.NotDir,
        error.SymLinkLoop,
        error.NameTooLong,
        error.BadPathName,
        error.AccessDenied,
        error.PermissionDenied,
        => return failWorker(context.diagnostic, definition, "cannot open the definition's root {s}: {s}", .{ root_path, @errorName(err) }),
        else => return unavailable(context.diagnostic, definition, "cannot open the definition's root {s}: {s}", .{ root_path, @errorName(err) }),
    };
    defer root.deinit();

    var graph: module_graph.Graph = .{ .arena = scratch, .root = &root };
    const entries = try scratch.alloc(u32, definition.routes.len);
    for (definition.routes, entries) |route, *entry| {
        const label: module_graph.Label = .{ .worker = definition.name, .pattern = route.pattern };
        entry.* = try graph.addEntry(route.entry_path, label, context.diagnostic);
    }

    const key_directory = graph.keyDirectory();
    const keys = try scratch.alloc([]const u8, graph.modules.items.len);
    for (graph.modules.items, keys) |module, *key| {
        key.* = try moduleKey(scratch, key_directory, module.path);
        module_pack.validateSpecifier(key.*) catch {
            context.diagnostic.set("worker '{s}': module {s} has a path that cannot be a module specifier (it holds a space, '?', '#', '\\' or a control byte)", .{
                definition.name,
                module.path,
            });
            return error.RoutesInvalid;
        };
    }

    return buildPack(context, scratch, definition, &graph, keys, entries);
}

/// The definition's artifact: every module some route reaches, once, in the
/// order the file header gives, and every route, in route order, naming its
/// entry by its position in that order.
fn buildPack(
    context: BuildContext,
    scratch: std.mem.Allocator,
    definition: *const config.WorkerDefinition,
    graph: *const module_graph.Graph,
    keys: []const []const u8,
    entries: []const u32,
) Error!DefinitionArtifact {
    // `position[module_index]` is the module's place in the pack, once the
    // module is included.
    const position = try scratch.alloc(u32, graph.modules.items.len);
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
            position[module_index] = @intCast(order.items.len);
            try order.append(scratch, module_index);
        }
    }
    std.debug.assert(order.items[0] == entries[0]);

    const modules = try scratch.alloc(module_pack.Module, order.items.len);
    for (order.items, modules) |module_index, *packed_module| {
        packed_module.* = .{
            .specifier = keys[module_index],
            .source = graph.modules.items[module_index].source,
        };
    }

    const route_inputs = try scratch.alloc(route_table.RouteInput, definition.routes.len);
    for (definition.routes, entries, route_inputs) |*route, entry, *input| {
        const binding_entries = try scratch.alloc(route_bindings.Entry, route.bindings.len);
        for (route.bindings, binding_entries) |binding, *binding_entry| {
            binding_entry.* = switch (binding.value) {
                .text => |text| .{ .name = binding.name, .value = text },
            };
        }
        input.* = .{ .entry_module = position[entry], .bindings = binding_entries };
    }

    const encoded = module_pack.buildAlloc(context.gpa, modules, route_inputs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ModulePackTooLarge => return failWorker(context.diagnostic, definition, "the module pack, its transcoded modules and its routes' bindings together, exceeds {d} bytes", .{module_pack.max_pack_bytes}),
        error.InvalidModulePack => return failWorker(context.diagnostic, definition, "cannot build the module pack: {s}", .{@errorName(err)}),
    };
    defer context.gpa.free(encoded);
    const pack_bytes: u64 = encoded.len;
    context.pack_bytes_total.* += pack_bytes;
    if (context.pack_bytes_total.* > server_limits.pack_bytes_total_max)
        return failWorker(context.diagnostic, definition, "the module packs of all workers exceed {d} bytes", .{server_limits.pack_bytes_total_max});
    const pack = sealed.sealBytes("collo-definition-artifact", encoded) catch |err|
        return unavailable(context.diagnostic, definition, "cannot seal the module pack: {s}", .{@errorName(err)});
    return .{
        .module_pack = pack,
        .module_pack_bytes = pack_bytes,
        .module_count = @intCast(order.items.len),
    };
}

/// The directory the definition's graph is confined to: the deepest one
/// holding every route's entry. Entry paths are absolute and lexically
/// normalized, so the result is too, and it never depends on what the
/// entries import.
fn definitionRoot(definition: *const config.WorkerDefinition) []const u8 {
    std.debug.assert(definition.routes.len != 0);
    var root = std.fs.path.dirname(definition.routes[0].entry_path) orelse "/";
    for (definition.routes[1..]) |route|
        root = module_graph.commonAncestor(root, std.fs.path.dirname(route.entry_path) orelse "/");
    return root;
}

/// `<task_root>/<path below key_directory>`.
fn moduleKey(allocator: std.mem.Allocator, key_directory: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    std.debug.assert(module_graph.isWithin(key_directory, path));
    const relative = std.mem.trimLeft(u8, path[key_directory.len..], "/");
    std.debug.assert(relative.len != 0);
    return std.mem.concat(allocator, u8, &.{ module_pack.task_root, "/", relative });
}

fn failWorker(diagnostic: *Diagnostic, definition: *const config.WorkerDefinition, comptime format: []const u8, args: anytype) Error {
    diagnostic.set("worker '{s}': " ++ format, .{definition.name} ++ args);
    return error.RoutesInvalid;
}

fn unavailable(diagnostic: *Diagnostic, definition: *const config.WorkerDefinition, comptime format: []const u8, args: anytype) Error {
    diagnostic.set("worker '{s}': " ++ format, .{definition.name} ++ args);
    return error.RouteResourcesUnavailable;
}
