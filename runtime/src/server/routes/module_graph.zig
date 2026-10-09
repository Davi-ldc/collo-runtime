//! The import graph of one worker definition's routes, read from disk at
//! boot so every route's module pack holds every module its entry can load:
//! the modules it needs before it evaluates, and the targets of the
//! string-literal `import()` calls those modules make (`imports.zig`).
//!
//! Static and dynamic imports resolve by the same rules, which follow the
//! engine's (`canonicalModuleSpecifier` and `resolveRegisteredSpecifier` in
//! `bindings/jsc/runtime/module_loader.cpp`): a relative specifier (`./`,
//! `../`) resolves lexically against the importing module's directory,
//! names exactly one file, and gets no extension or index probing. Symlinks
//! are followed when a file is read but never change its path, because the
//! engine resolves the importer's path the same lexical way. `fs` and
//! `fs/promises`, with or without the `node:` scheme, are modules the
//! runtime provides and are not read.
//!
//! A static import names a module its importer cannot evaluate without, so
//! any other target fails the boot: a package name must be bundled into the
//! entry (with Bun or esbuild), an absolute path or a URL does not resolve to
//! a packed module, and a relative path must name a file. An `import()` runs
//! only when its module calls it, and rejects then when the pack lacks the
//! module, which code may catch for a dependency it treats as optional. So a
//! string-literal `import()` adds its target only when the target is
//! relative and exists, and fails the boot only when such a target cannot be
//! packed; any other target is left out, like a computed specifier's, and in
//! the worker it loads only a module the pack already holds.
//!
//! A graph and every byte it reads live in a scratch arena the caller owns
//! and frees once the definition's packs exist. Boot builds graphs on one
//! thread.

const std = @import("std");
const config = @import("collo_server_config");
const module_pack = @import("collo_ipc").module_pack;
const server_limits = @import("collo_limits").server;
const imports_mod = @import("imports.zig");

const Diagnostic = config.Diagnostic;

pub const Error = error{ OutOfMemory, RouteBuildFailed };

/// The source an empty module file is packed as.
const empty_module_source = "\n";

pub const Module = struct {
    /// Absolute and lexically normalized.
    path: []const u8,
    /// Never empty.
    source: []const u8,
    /// The modules this one imports statically, each once, in the order the
    /// source first names them. They become the module's dependency records
    /// in the pack (`module_pack.Dependency`).
    imports: []const u32,
    /// The targets of this module's string-literal `import()` calls that the
    /// graph packs, each once, in source order. They are packed but are not
    /// dependency records, since the module evaluates without them; one may
    /// also be in `imports`.
    dynamic_imports: []const u32,
};

/// The route a graph walk is for, named in every message.
pub const Label = struct {
    worker: []const u8,
    pattern: []const u8,
};

pub const Graph = struct {
    arena: std.mem.Allocator,
    modules: std.ArrayList(Module) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    /// Bytes of every source read, bounded by `pack_bytes_total_max`.
    source_bytes: u64 = 0,

    /// Reads `entry_path` and every module it reaches through either kind of
    /// import, sharing modules already read for an earlier route, and
    /// returns the entry's module index.
    pub fn addEntry(self: *Graph, entry_path: []const u8, label: Label, diagnostic: *Diagnostic) Error!u32 {
        if (self.by_path.get(entry_path)) |index|
            return index;
        const entry_index = try self.read(entry_path, label, null, diagnostic);
        // Every module appended below gets its imports resolved in turn, so
        // the loop ends when the graph is closed; `read` bounds its size.
        var cursor: usize = entry_index;
        while (cursor < self.modules.items.len) : (cursor += 1)
            try self.resolveImports(@intCast(cursor), label, diagnostic);
        return entry_index;
    }

    /// The modules `entry` reaches through either kind of import, `entry`
    /// first, then breadth first.
    pub fn reachable(self: *const Graph, entry: u32, out: *std.ArrayList(u32)) error{OutOfMemory}!void {
        var visited = try std.DynamicBitSetUnmanaged.initEmpty(self.arena, self.modules.items.len);
        try out.append(self.arena, entry);
        visited.set(entry);
        var cursor: usize = 0;
        while (cursor < out.items.len) : (cursor += 1) {
            const module = self.modules.items[out.items[cursor]];
            for ([_][]const u32{ module.imports, module.dynamic_imports }) |edges| {
                for (edges) |imported| {
                    if (visited.isSet(imported))
                        continue;
                    visited.set(imported);
                    try out.append(self.arena, imported);
                }
            }
        }
    }

    /// The deepest directory that contains every module of the graph.
    pub fn commonDirectory(self: *const Graph) []const u8 {
        std.debug.assert(self.modules.items.len != 0);
        var common = std.fs.path.dirname(self.modules.items[0].path) orelse "/";
        for (self.modules.items[1..]) |module| {
            const directory = std.fs.path.dirname(module.path) orelse "/";
            while (!isWithin(common, directory))
                common = std.fs.path.dirname(common) orelse "/";
        }
        return common;
    }

    const Importer = struct {
        path: []const u8,
        line: u32,
        specifier: []const u8,
        kind: imports_mod.Import.Kind,
    };

    fn read(self: *Graph, path: []const u8, label: Label, importer: ?Importer, diagnostic: *Diagnostic) Error!u32 {
        if (self.modules.items.len == module_pack.max_module_count)
            return fail(diagnostic, label, importer, "the import graph exceeds {d} modules at {s}", .{ module_pack.max_module_count, path });
        const read_source = std.fs.cwd().readFileAlloc(self.arena, path, module_pack.max_pack_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileTooBig => return fail(diagnostic, label, importer, "module {s} exceeds {d} bytes", .{ path, module_pack.max_pack_bytes }),
            else => return fail(diagnostic, label, importer, "cannot read module {s}: {s}", .{ path, @errorName(err) }),
        };
        // An empty file is a valid module that exports nothing, but the pack
        // format refuses an empty source (`validateModuleList` in
        // `common/ipc/module_pack.zig`), so it is packed as one newline,
        // which evaluates the same.
        const source = if (read_source.len == 0) empty_module_source else read_source;
        self.source_bytes += source.len;
        if (self.source_bytes > server_limits.pack_bytes_total_max)
            return fail(diagnostic, label, importer, "the modules read exceed {d} bytes at {s}", .{ server_limits.pack_bytes_total_max, path });

        const index: u32 = @intCast(self.modules.items.len);
        const owned_path = try self.arena.dupe(u8, path);
        try self.modules.append(self.arena, .{
            .path = owned_path,
            .source = source,
            .imports = &.{},
            .dynamic_imports = &.{},
        });
        try self.by_path.put(self.arena, owned_path, index);
        return index;
    }

    fn resolveImports(self: *Graph, module_index: u32, label: Label, diagnostic: *Diagnostic) Error!void {
        // Fields are copied out because `read` may grow `modules`.
        const path = self.modules.items[module_index].path;
        const source = self.modules.items[module_index].source;
        const directory = std.fs.path.dirname(path) orelse "/";

        var found: std.ArrayList(imports_mod.Import) = .empty;
        var failure: imports_mod.Failure = undefined;
        imports_mod.scan(self.arena, source, &found, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidModuleSource => return fail(diagnostic, label, null, "{s}:{d}: {s}", .{
                path,
                failure.line,
                failure.reason.describe(),
            }),
        };

        var static_imports: std.ArrayList(u32) = .empty;
        var dynamic_imports: std.ArrayList(u32) = .empty;
        for (found.items) |item| {
            const importer: Importer = .{
                .path = path,
                .line = item.line,
                .specifier = item.specifier,
                .kind = item.kind,
            };
            const class = classify(item.specifier);
            // Only a relative target can be packed. Any other `import()`
            // target is left to run time, where the runtime's own modules
            // load and the rest reject (the header's rule).
            if (item.kind == .dynamic and class != .relative)
                continue;
            switch (class) {
                .runtime => continue,
                .relative => {},
                .package => return fail(diagnostic, label, importer, "package imports are not supported; bundle dependencies into the entry with Bun or esbuild", .{}),
                .absolute => return fail(diagnostic, label, importer, "absolute imports are not supported; import modules with a './' or '../' path", .{}),
                .scheme => return fail(diagnostic, label, importer, "only relative paths and the runtime's node:fs modules can be imported", .{}),
            }
            const target_path = try std.fs.path.resolvePosix(self.arena, &.{ directory, item.specifier });
            const known = self.by_path.get(target_path);
            if (known == null and item.kind == .dynamic and !pathExists(target_path))
                continue;
            const target = known orelse try self.read(target_path, label, importer, diagnostic);
            const resolved = switch (item.kind) {
                .static => &static_imports,
                .dynamic => &dynamic_imports,
            };
            if (std.mem.indexOfScalar(u32, resolved.items, target) == null)
                try resolved.append(self.arena, target);
        }
        self.modules.items[module_index].imports = static_imports.items;
        self.modules.items[module_index].dynamic_imports = dynamic_imports.items;
    }
};

const SpecifierClass = enum { relative, runtime, package, absolute, scheme };

fn classify(specifier: []const u8) SpecifierClass {
    if (std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../"))
        return .relative;
    const runtime_modules = [_][]const u8{ "fs", "fs/promises", "node:fs", "node:fs/promises" };
    for (runtime_modules) |name| {
        if (std.mem.eql(u8, specifier, name))
            return .runtime;
    }
    if (std.mem.startsWith(u8, specifier, "/"))
        return .absolute;
    if (std.mem.indexOfScalar(u8, specifier, ':') != null)
        return .scheme;
    return .package;
}

/// False only when nothing exists at `path`. Any other failure to look counts
/// as there, and `read` then reports it.
fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

/// True when `directory` is `ancestor` or lies below it.
fn isWithin(ancestor: []const u8, directory: []const u8) bool {
    if (!std.mem.startsWith(u8, directory, ancestor))
        return false;
    if (directory.len == ancestor.len)
        return true;
    return std.mem.eql(u8, ancestor, "/") or directory[ancestor.len] == '/';
}

fn fail(
    diagnostic: *Diagnostic,
    label: Label,
    importer: ?Graph.Importer,
    comptime format: []const u8,
    args: anytype,
) Error {
    if (importer) |site| {
        const site_args = .{ label.worker, label.pattern, site.path, site.line, site.specifier };
        switch (site.kind) {
            .static => diagnostic.set("worker '{s}' route '{s}': {s}:{d}: import '{s}': " ++ format, site_args ++ args),
            .dynamic => diagnostic.set("worker '{s}' route '{s}': {s}:{d}: import('{s}'): " ++ format, site_args ++ args),
        }
    } else {
        diagnostic.set("worker '{s}' route '{s}': " ++ format, .{ label.worker, label.pattern } ++ args);
    }
    return error.RouteBuildFailed;
}
