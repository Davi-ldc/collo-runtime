//! The import graph of one worker definition's routes, read from disk at
//! boot so the definition's artifact holds every module a route's entry can
//! load: the modules it needs before it evaluates, and the targets of the
//! string-literal `import()` calls those modules make (`imports.zig`).
//!
//! Every file the graph reads lies within the definition's root (`Root`),
//! the deepest directory holding every route's entry, and imports never
//! widen it. A static import whose path leaves the root lexically fails the
//! boot, and a dynamic one is left out without a look at the file. A file is
//! opened beneath the root's descriptor, so a path that a symlink inside the
//! root leads outside it fails the boot before anything outside is opened;
//! files are opened non-blocking and only a regular file is read. Code of
//! one definition therefore never makes the server read, or pack into the
//! definition's artifact, a file outside that definition's root, such as
//! another tenant's code. The root's own path comes from the operator's
//! configuration, and symlinks in it are followed.
//!
//! Static and dynamic imports resolve by the same rules, which follow the
//! engine's (`canonicalModuleSpecifier` and `resolveRegisteredSpecifier` in
//! `bindings/jsc/runtime/module_loader.cpp`): a relative specifier (`./`,
//! `../`) resolves lexically against the importing module's directory,
//! names exactly one file, and gets no extension or index probing. A
//! specifier whose `..` would rise above `/` fails the boot, since the
//! engine refuses it where the filesystem would stop. Modules are keyed by
//! their path below the key directory (`keyDirectory`, used by
//! `artifacts.zig`), the deepest directory holding every module and every
//! directory a packed import's specifier passes through on its way to its
//! file. The engine's walk from the importer's key then never rises above
//! the task root, so it lands on the key of the file resolved here.
//! Symlinks inside the root are followed when a file is read but never
//! change its path, because the engine resolves the importer's key the same
//! lexical way. `fs` and `fs/promises`, with or without the `node:` scheme,
//! are modules the runtime provides and are not read.
//!
//! A static import names a module its importer cannot evaluate without, so
//! any other target fails the boot: a package name must be bundled into the
//! entry (with Bun or esbuild), an absolute path or a URL does not resolve to
//! a packed module, and a relative path must name a file inside the root.
//! An `import()` runs only when its module calls it, and rejects then when
//! the pack lacks the module, which code may catch for a dependency it
//! treats as optional. So a string-literal `import()` adds its target only
//! when the target is relative, inside the root and exists, and fails the
//! boot only when such a target cannot be packed; any other target is left
//! out, like a computed specifier's, and in the worker it loads only a
//! module the pack already holds.
//!
//! Sources are kept as the UTF-8 bytes read from disk, empty files included;
//! the pack builder transcodes them (`module_pack.buildAlloc`). A graph and
//! every byte it reads live in a scratch arena the caller owns and frees once
//! the definition's artifact exists, and the graph borrows its `Root`, which
//! the caller closes after it. Boot builds graphs on one thread.

const std = @import("std");
const config = @import("collo_server_config");
const collo_os = @import("collo_os");
const module_pack = @import("collo_ipc").module_pack;
const server_limits = @import("collo_limits").server;
const imports_mod = @import("imports.zig");

const fd_mod = collo_os.fd;
const Diagnostic = config.Diagnostic;

/// `RoutesInvalid` for a graph the configuration's files cannot form,
/// `RouteResourcesUnavailable` for a file the server could not read for a
/// cause of its own.
pub const Error = error{ OutOfMemory, RoutesInvalid, RouteResourcesUnavailable };

pub const Module = struct {
    /// Absolute and lexically normalized, within the graph's root.
    path: []const u8,
    /// The file's bytes, as UTF-8 text; empty for an empty file.
    source: []const u8,
    /// The modules this one imports statically, each once, in the order the
    /// source first names them.
    imports: []const u32,
    /// The targets of this module's string-literal `import()` calls that the
    /// graph packs, each once, in source order; one may also be in
    /// `imports`.
    dynamic_imports: []const u32,
};

/// The route a graph walk is for, named in every message.
pub const Label = struct {
    worker: []const u8,
    pattern: []const u8,
};

/// The directory a definition's graph is confined to, with a descriptor that
/// every module is opened beneath.
pub const Root = struct {
    /// Absolute and lexically normalized.
    path: []const u8,
    /// An `O_PATH` descriptor of `path`.
    dir: fd_mod.OwnedFd,

    pub const OpenModuleError = error{
        /// Resolution left the root: a `..` that rose above it, or a symlink
        /// whose target lies outside it or is absolute.
        OutsideRoot,
        FileNotFound,
        NotDir,
        /// A loop of symlinks, or a magic link such as `/proc/self/fd/N`.
        SymLinkLoop,
        NameTooLong,
        /// The path holds a NUL byte, so the kernel would read a shorter one.
        BadPathName,
        AccessDenied,
        PermissionDenied,
        /// A socket or a device that refuses a read-only open.
        NotRegularFile,
        SystemResources,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        /// The kernel could not prove that a `..` stayed beneath the root
        /// while another process renamed a directory.
        WouldBlock,
        /// The kernel has no `openat2` (before Linux 5.6).
        OpenBeneathUnsupported,
        Unexpected,
    };

    /// Opens `path`, which the caller keeps alive as long as the root.
    /// Symlinks in `path` itself are followed: it is the operator's.
    pub fn open(path: []const u8) std.posix.OpenError!Root {
        std.debug.assert(std.fs.path.isAbsolute(path));
        const raw = try std.posix.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true, .CLOEXEC = true }, 0);
        return .{ .path = path, .dir = fd_mod.OwnedFd.fromRaw(raw) };
    }

    pub fn deinit(self: *Root) void {
        self.dir.deinit();
        self.* = undefined;
    }

    /// Opens the file at `path`, which lies within the root, for reading.
    /// Resolution runs beneath the root's descriptor (`collo_os.fd.openat2`
    /// with `RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS`), so the kernel refuses a
    /// path that leaves the root through a `..` or a symlink before it opens
    /// anything outside, which no check of a path made before the open could
    /// guarantee while the files can change. An absolute symlink is refused
    /// even when it names a file inside the root, since the kernel resolves
    /// it from `/`. `O_NONBLOCK` keeps a FIFO from holding the open until a
    /// writer appears, and `O_NOCTTY` keeps a terminal from becoming the
    /// server's; the caller reads only a regular file (`readRegularFile`).
    pub fn openModule(self: *const Root, path: []const u8) OpenModuleError!fd_mod.OwnedFd {
        std.debug.assert(isWithin(self.path, path));
        const below = std.mem.trimLeft(u8, path[self.path.len..], "/");
        const sub_path = if (below.len == 0) "." else below;
        if (std.mem.indexOfScalar(u8, sub_path, 0) != null)
            return error.BadPathName;
        const sub_path_z = try std.posix.toPosixPath(sub_path);
        return fd_mod.openat2(
            self.dir.fd(),
            &sub_path_z,
            .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true },
            fd_mod.resolve_beneath | fd_mod.resolve_no_magiclinks,
        ) catch |err| return switch (err) {
            error.PathEscapesDirectory => error.OutsideRoot,
            error.NoDevice => error.NotRegularFile,
            error.SystemOutdated => error.OpenBeneathUnsupported,
            // A read-only open never meets a directory's EISDIR.
            error.IsDir => error.Unexpected,
            else => |other| other,
        };
    }
};

pub const Graph = struct {
    arena: std.mem.Allocator,
    /// Every module lies within it, and every file is opened beneath it.
    root: *const Root,
    modules: std.ArrayList(Module) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    /// Bytes of every source read, bounded by `pack_bytes_total_max`.
    source_bytes: u64 = 0,
    /// See `keyDirectory`; null until the first module is read.
    key_directory: ?[]const u8 = null,

    /// Reads `entry_path`, which lies within the root, and every module it
    /// reaches through either kind of import, sharing modules already read
    /// for an earlier route, and returns the entry's module index.
    pub fn addEntry(self: *Graph, entry_path: []const u8, label: Label, diagnostic: *Diagnostic) Error!u32 {
        if (self.by_path.get(entry_path)) |index|
            return index;
        var file = self.root.openModule(entry_path) catch |err|
            return self.openFailure(entry_path, err, label, null, diagnostic);
        defer file.deinit();
        const entry_index = try self.read(entry_path, file.fd(), label, null, diagnostic);
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

    /// The deepest directory that holds every module of the graph and every
    /// directory a packed import's specifier passes through, such as the
    /// parent that `../src/util.js` climbs to before it descends again. It is
    /// the root or one of its ancestors. A module keyed by its path below it
    /// is found by the engine's lexical walk from its importer's key, which
    /// never rises above the key of this directory.
    pub fn keyDirectory(self: *const Graph) []const u8 {
        std.debug.assert(self.modules.items.len != 0);
        return self.key_directory.?;
    }

    const Importer = struct {
        path: []const u8,
        line: u32,
        specifier: []const u8,
        kind: imports_mod.Import.Kind,
    };

    /// Reads the opened file at `path` as a new module.
    fn read(
        self: *Graph,
        path: []const u8,
        file: std.posix.fd_t,
        label: Label,
        importer: ?Importer,
        diagnostic: *Diagnostic,
    ) Error!u32 {
        if (self.modules.items.len == module_pack.max_module_count)
            return fail(diagnostic, label, importer, "the import graph exceeds {d} modules at {s}", .{ module_pack.max_module_count, path });
        const source = readRegularFile(self.arena, file, module_pack.max_pack_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileTooBig => return fail(diagnostic, label, importer, "module {s} exceeds {d} bytes", .{ path, module_pack.max_pack_bytes }),
            // What the configuration names: a directory, a FIFO or another
            // file that is not regular.
            error.IsDir, error.NotRegularFile => return fail(diagnostic, label, importer, "cannot read module {s}: {s}", .{ path, @errorName(err) }),
            // The rest are the server's: kernel memory and I/O errors, which
            // a correct configuration also meets.
            else => return unavailable(diagnostic, label, importer, "cannot read module {s}: {s}", .{ path, @errorName(err) }),
        };
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
        self.widenKeyDirectory(std.fs.path.dirname(owned_path) orelse "/");
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
            const walked = walk(self.arena, directory, item.specifier) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AboveFilesystemRoot => return fail(diagnostic, label, importer, "the path rises above the filesystem root", .{}),
            };
            if (!isWithin(self.root.path, walked.target)) {
                switch (item.kind) {
                    // Nothing outside the root is ever opened, so the target
                    // is left to fail at run time, like one that does not
                    // exist.
                    .dynamic => continue,
                    .static => return fail(diagnostic, label, importer, "{s} lies outside the definition's root {s}", .{ walked.target, self.root.path }),
                }
            }
            const target = self.by_path.get(walked.target) orelse first_read: {
                var file = self.root.openModule(walked.target) catch |err| switch (err) {
                    error.FileNotFound => switch (item.kind) {
                        // A dependency the module may treat as optional.
                        .dynamic => continue,
                        .static => return self.openFailure(walked.target, err, label, importer, diagnostic),
                    },
                    else => return self.openFailure(walked.target, err, label, importer, diagnostic),
                };
                defer file.deinit();
                break :first_read try self.read(walked.target, file.fd(), label, importer, diagnostic);
            };
            self.widenKeyDirectory(walked.shallowest);
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

    /// Widens the key directory to hold `directory`, which is absolute and
    /// lexically normalized.
    fn widenKeyDirectory(self: *Graph, directory: []const u8) void {
        if (self.key_directory) |current| {
            self.key_directory = commonAncestor(current, directory);
        } else {
            self.key_directory = directory;
        }
    }

    /// Reports why the module at `path` could not be opened beneath the root.
    fn openFailure(
        self: *const Graph,
        path: []const u8,
        err: Root.OpenModuleError,
        label: Label,
        importer: ?Importer,
        diagnostic: *Diagnostic,
    ) Error {
        switch (err) {
            error.OutsideRoot => return fail(diagnostic, label, importer, "cannot read module {s}: it resolves outside the definition's root {s}", .{ path, self.root.path }),
            // What the configuration names: a path to nothing, through a
            // loop or a non-directory, too long, holding a NUL, a socket or
            // device, or a file the server may not read.
            error.FileNotFound,
            error.NotDir,
            error.SymLinkLoop,
            error.NameTooLong,
            error.BadPathName,
            error.AccessDenied,
            error.PermissionDenied,
            error.NotRegularFile,
            => return fail(diagnostic, label, importer, "cannot read module {s}: {s}", .{ path, @errorName(err) }),
            // The rest are the server's: descriptor quotas, kernel memory, a
            // rename racing the resolution and an old kernel, which a correct
            // configuration also meets.
            error.SystemResources,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.WouldBlock,
            error.OpenBeneathUnsupported,
            error.Unexpected,
            => return unavailable(diagnostic, label, importer, "cannot read module {s}: {s}", .{ path, @errorName(err) }),
        }
    }
};

/// The deepest directory that holds both `directory` and `other`, which are
/// absolute and lexically normalized; a slice of `directory`.
pub fn commonAncestor(directory: []const u8, other: []const u8) []const u8 {
    var common = directory;
    while (!isWithin(common, other))
        common = std.fs.path.dirname(common) orelse "/";
    return common;
}

/// True when `path` is `ancestor` or lies below it; both are absolute and
/// lexically normalized.
pub fn isWithin(ancestor: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, ancestor))
        return false;
    if (path.len == ancestor.len)
        return true;
    return std.mem.eql(u8, ancestor, "/") or path[ancestor.len] == '/';
}

const Walk = struct {
    /// Absolute and lexically normalized.
    target: []const u8,
    /// The shallowest directory the walk passes through: the importer's
    /// directory or one of its ancestors.
    shallowest: []const u8,
};

/// Resolves the relative `specifier` against `directory`, absolute and
/// lexically normalized, segment by segment as the engine resolves it
/// against the importer's key: an empty or `.` segment changes nothing and
/// `..` drops the last segment. Fails with `error.AboveFilesystemRoot` for a
/// `..` at `/`, where `std.fs.path.resolvePosix` would stop and the engine
/// fails.
fn walk(arena: std.mem.Allocator, directory: []const u8, specifier: []const u8) error{ OutOfMemory, AboveFilesystemRoot }!Walk {
    var segments: std.ArrayList([]const u8) = .empty;
    var directory_segments = std.mem.tokenizeScalar(u8, directory, '/');
    while (directory_segments.next()) |segment|
        try segments.append(arena, segment);
    // Once the walk is above `directory`, it reaches a shallower directory
    // only through the parent of the one it stands in, so the shallowest
    // directory is always the ancestor of `directory` at this depth.
    var shallowest_depth = segments.items.len;
    var specifier_segments = std.mem.splitScalar(u8, specifier, '/');
    while (specifier_segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, "."))
            continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len == 0)
                return error.AboveFilesystemRoot;
            _ = segments.pop();
            shallowest_depth = @min(shallowest_depth, segments.items.len);
            continue;
        }
        try segments.append(arena, segment);
    }
    var target: std.ArrayList(u8) = .empty;
    if (segments.items.len == 0)
        try target.append(arena, '/');
    for (segments.items) |segment| {
        try target.append(arena, '/');
        try target.appendSlice(arena, segment);
    }
    return .{ .target = target.items, .shallowest = ancestorAtDepth(directory, shallowest_depth) };
}

/// The ancestor of `path`, absolute and lexically normalized, that has
/// `depth` segments: `/` at depth 0, `path` itself at its own depth.
fn ancestorAtDepth(path: []const u8, depth: usize) []const u8 {
    if (depth == 0)
        return "/";
    var slashes_seen: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte != '/')
            continue;
        if (slashes_seen == depth)
            return path[0..index];
        slashes_seen += 1;
    }
    return path;
}

/// Reads the regular file `file` to its end, at most `max_bytes`. The size
/// `fstat` reports is only the first allocation's: a file that grows while
/// it is read is read until it ends or passes `max_bytes`.
fn readRegularFile(
    arena: std.mem.Allocator,
    file: std.posix.fd_t,
    max_bytes: usize,
) (error{ OutOfMemory, FileTooBig, IsDir, NotRegularFile } || std.posix.FStatError || std.posix.ReadError)![]u8 {
    const stat = try std.posix.fstat(file);
    if (std.posix.S.ISDIR(stat.mode))
        return error.IsDir;
    if (!std.posix.S.ISREG(stat.mode))
        return error.NotRegularFile;
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (size > max_bytes)
        return error.FileTooBig;
    // One byte past the size, so a file that kept it ends with a read of
    // zero bytes and no reallocation.
    var bytes = try std.ArrayList(u8).initCapacity(arena, size + 1);
    while (true) {
        if (bytes.unusedCapacitySlice().len == 0)
            try bytes.ensureUnusedCapacity(arena, 1);
        const amount = try std.posix.read(file, bytes.unusedCapacitySlice());
        if (amount == 0)
            break;
        bytes.items.len += amount;
        if (bytes.items.len > max_bytes)
            return error.FileTooBig;
    }
    return bytes.items;
}

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

/// Sets the message and returns `error.RoutesInvalid`.
fn fail(
    diagnostic: *Diagnostic,
    label: Label,
    importer: ?Graph.Importer,
    comptime format: []const u8,
    args: anytype,
) Error {
    describe(diagnostic, label, importer, format, args);
    return error.RoutesInvalid;
}

/// Sets the message and returns `error.RouteResourcesUnavailable`.
fn unavailable(
    diagnostic: *Diagnostic,
    label: Label,
    importer: ?Graph.Importer,
    comptime format: []const u8,
    args: anytype,
) Error {
    describe(diagnostic, label, importer, format, args);
    return error.RouteResourcesUnavailable;
}

fn describe(
    diagnostic: *Diagnostic,
    label: Label,
    importer: ?Graph.Importer,
    comptime format: []const u8,
    args: anytype,
) void {
    if (importer) |site| {
        const site_args = .{ label.worker, label.pattern, site.path, site.line, site.specifier };
        switch (site.kind) {
            .static => diagnostic.set("worker '{s}' route '{s}': {s}:{d}: import '{s}': " ++ format, site_args ++ args),
            .dynamic => diagnostic.set("worker '{s}' route '{s}': {s}:{d}: import('{s}'): " ++ format, site_args ++ args),
        }
    } else {
        diagnostic.set("worker '{s}' route '{s}': " ++ format, .{ label.worker, label.pattern } ++ args);
    }
}
