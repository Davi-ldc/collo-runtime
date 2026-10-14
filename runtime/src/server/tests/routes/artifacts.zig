//! `Routes` and the definition artifacts (`server/routes/root.zig`,
//! `server/routes/artifacts.zig`, `server/routes/module_graph.zig`) built from
//! modules in a temporary directory: a two-module entry and its import
//! packed into one sealed memfd with the route and its bindings, keys under
//! the task root, lookups by path and by key, a definition with several
//! routes sharing one artifact and naming their entries by module index, the
//! synthesized configuration, the definition's root (the deepest directory
//! of its entries) confining what is read, whether an import leaves it
//! lexically, through a symlink or into another definition's files, a FIFO
//! that would block the boot, keys taken from the directory an import climbs
//! to, a '..' above the filesystem root, the runtime's own fs modules,
//! sources stored as Latin-1 or UTF-16 by their text, an empty module, the
//! targets of string-literal `import()` packed
//! with their own imports while computed ones and those that cannot be
//! packed stay out, the ways a graph fails with the file and line each
//! failure names, as invalid routes, a descriptor quota failing the build as
//! unavailable resources instead, allocation failure at every step, and the
//! configuration local-e2e serves. The network policies are covered in
//! `network.zig`, and the artifact's format in
//! `common/tests/ipc/module_pack.zig`.
//!
//! What a worker does with the artifacts is covered by `worker-test`
//! (`worker/tests/runtime/modules.zig` boots an artifact this builder made),
//! `zygote-integration` and `local-e2e`.

const std = @import("std");
const config = @import("collo_server_config");
const routes = @import("collo_server_routes");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

const module_pack = ipc.module_pack;
const route_bindings = ipc.route_bindings;

const index_source =
    \\import { greet } from "./lib/greet.js";
    \\export default { fetch() { return new Response(greet()); } };
;
const greet_source = "export function greet() { return \"hi\"; }\n";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    directory_buffer: [std.fs.max_path_bytes]u8 = undefined,
    directory_len: usize = 0,

    fn init(target: *Fixture) !void {
        target.* = .{ .tmp = std.testing.tmpDir(.{}) };
        errdefer target.tmp.cleanup();
        target.directory_len = (try target.tmp.dir.realpath(".", &target.directory_buffer)).len;
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn directory(self: *const Fixture) []const u8 {
        return self.directory_buffer[0..self.directory_len];
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent|
            try self.tmp.dir.makePath(parent);
        try self.tmp.dir.writeFile(.{ .sub_path = sub_path, .data = data });
    }

    fn path(self: *const Fixture, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.directory(), sub_path });
    }

    fn parse(self: *const Fixture, allocator: std.mem.Allocator, source: []const u8, diagnostic: *config.Diagnostic) !config.Config {
        const config_path = try self.path(allocator, "collo.json");
        defer allocator.free(config_path);
        return config.parse(allocator, source, config_path, diagnostic);
    }
};

fn catchAll(comptime route_body: []const u8) []const u8 {
    return "{\"workers\": {\"api\": {\"routes\": {\"/*\": " ++ route_body ++ "}}}}";
}

fn readAll(allocator: std.mem.Allocator, fd: std.posix.fd_t, length: u64) ![]u8 {
    const bytes = try allocator.alloc(u8, @intCast(length));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = try std.posix.pread(fd, bytes[offset..], offset);
        if (amount == 0)
            return error.ShortRead;
        offset += amount;
    }
    return bytes;
}

/// The bytes of `artifact`, read back from its sealed memfd; the caller frees
/// them and parses them with `module_pack.parse`, whose view borrows them.
fn readPack(allocator: std.mem.Allocator, artifact: *const routes.DefinitionArtifact) ![]u8 {
    try fd_mod.requireSeals(artifact.module_pack.fd(), fd_mod.memfd_readonly_seals);
    return readAll(allocator, artifact.module_pack.fd(), artifact.module_pack_bytes);
}

fn expectEntrySpecifier(artifact: *const routes.DefinitionArtifact, index: usize, expected: []const u8) !void {
    const bytes = try readPack(std.testing.allocator, artifact);
    defer std.testing.allocator.free(bytes);
    const pack = try module_pack.parse(bytes);
    try module_pack.validateDefinition(pack);
    try std.testing.expectEqualStrings(expected, pack.routeAt(index).entry_specifier);
}

/// The build of `source` fails as invalid routes, naming `expected`.
fn expectBuildFailure(fixture: *const Fixture, source: []const u8, expected: []const u8) !void {
    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(std.testing.allocator, source, &diagnostic);
    var built: routes.Routes = undefined;
    try std.testing.expectError(error.RoutesInvalid, built.init(std.testing.allocator, parsed, &diagnostic));
    if (std.mem.indexOf(u8, diagnostic.message(), expected) == null) {
        std.debug.print("message: {s}\nexpected it to contain: {s}\n", .{ diagnostic.message(), expected });
        return error.TestUnexpectedMessage;
    }
}

test "a two-module entry is packed with its import and its route in one sealed artifact" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app/index.js", index_source);
    try fixture.write("app/lib/greet.js", greet_source);

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll(
        \\{"entry": "./app/index.js", "bindings": {"GREETING": {"text": "hello"}, "EMPTY": {"text": ""}}}
    ), &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    const key: config.RouteKey = .{ .definition = 0, .route = 0 };
    const artifact = built.artifact(key.definition);
    // The module root is `app/`, the deepest directory holding both files,
    // and every key sits under the task root.
    const entry = "/var/task/index.js";
    try expectEntrySpecifier(artifact, key.route, entry);
    try std.testing.expectEqual(@as(u32, 2), artifact.module_count);
    try std.testing.expectEqual(artifact.module_pack_bytes, built.pack_bytes_total);

    const pack_bytes = try readPack(allocator, artifact);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try module_pack.validateDefinition(pack);
    try std.testing.expectEqual(@as(usize, 1), pack.routes.len);
    try std.testing.expectEqual(@as(u32, 0), pack.routeAt(0).entry_module);
    try std.testing.expectEqualStrings(entry, pack.moduleAt(0).specifier);
    try std.testing.expectEqual(module_pack.Encoding.latin1, pack.moduleAt(0).encoding);
    try std.testing.expectEqualStrings(index_source, pack.moduleAt(0).source);
    const greet = pack.findModule("/var/task/lib/greet.js") orelse return error.TestMissingModule;
    try std.testing.expectEqualStrings(greet_source, greet.source);

    // The route's bindings both processes read, byte for byte, in
    // configuration order.
    const expected_bindings = "\x02\x00\x00\x00" ++
        "\x08\x00\x00\x00GREETING" ++ "\x05\x00\x00\x00hello" ++
        "\x05\x00\x00\x00EMPTY" ++ "\x00\x00\x00\x00";
    try std.testing.expectEqualSlices(u8, expected_bindings, pack.routeAt(0).bindings);

    var captures: routes.Captures = undefined;
    const matched = (try built.match("/any/path", &captures)) orelse return error.TestNoMatch;
    try std.testing.expectEqual(key, matched.key);
    try std.testing.expectEqualStrings("/*", built.route(matched.key).pattern);
    try std.testing.expectEqualStrings("api", built.definition(0).name);
    try std.testing.expectEqual(@as(u16, 1), built.definitionCount());
}

test "a definition's routes share one artifact holding each module once and naming entries by module index" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app/a.js", "import { shared } from \"./lib/shared.js\";\nexport default () => new Response(shared);\n");
    try fixture.write("app/b.js", "import { shared } from \"./lib/shared.js\";\nimport { only } from \"./lib/only_b.js\";\nexport default () => new Response(shared + only);\n");
    try fixture.write("app/lib/shared.js", "export const shared = 's';\n");
    try fixture.write("app/lib/only_b.js", "export const only = 'b';\n");

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator,
        \\{"workers": {"api": {"routes": {
        \\  "/a": {"entry": "./app/a.js", "bindings": {"NAME": {"text": "a"}}},
        \\  "/b": {"entry": "./app/b.js", "bindings": {"NAME": {"text": "b"}}},
        \\  "/again": {"entry": "./app/a.js"}
        \\}}}}
    , &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 1), built.artifacts.len);
    const artifact = built.artifact(0);

    // Route 0's entry leads the pack, and every module some route reaches is
    // in it exactly once.
    try std.testing.expectEqual(@as(u32, 4), artifact.module_count);
    const pack_bytes = try readPack(allocator, artifact);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try std.testing.expectEqualStrings("/var/task/a.js", pack.moduleAt(0).specifier);
    try std.testing.expectEqual(@as(usize, 4), pack.records.len);
    for ([_][]const u8{ "a.js", "b.js", "lib/shared.js", "lib/only_b.js" }) |path| {
        const key = try std.fmt.allocPrint(allocator, "/var/task/{s}", .{path});
        defer allocator.free(key);
        try std.testing.expect(pack.findModule(key) != null);
    }

    // Each route names its entry by module index, routes that share an entry
    // name the same module, and each keeps its own bindings.
    try std.testing.expectEqual(@as(usize, 3), pack.routes.len);
    const b_index = pack.findIndex("/var/task/b.js") orelse return error.TestMissingModule;
    const expected = [_]struct { entry_module: usize, entry: []const u8, name: ?[]const u8 }{
        .{ .entry_module = 0, .entry = "/var/task/a.js", .name = "a" },
        .{ .entry_module = b_index, .entry = "/var/task/b.js", .name = "b" },
        .{ .entry_module = 0, .entry = "/var/task/a.js", .name = null },
    };
    for (expected, 0..) |want, route_index| {
        const route = pack.routeAt(route_index);
        try std.testing.expectEqual(want.entry_module, route.entry_module);
        try std.testing.expectEqualStrings(want.entry, route.entry_specifier);
        var entries: route_bindings.Entries = undefined;
        const bindings = try route_bindings.decode(route.bindings, &entries);
        if (want.name) |name| {
            try std.testing.expectEqual(@as(usize, 1), bindings.len);
            try std.testing.expectEqualStrings("NAME", bindings[0].name);
            try std.testing.expectEqualStrings(name, bindings[0].value);
        } else {
            try std.testing.expectEqual(@as(usize, 0), bindings.len);
        }
    }

    // A path's route key indexes the artifact's routes.
    var captures: routes.Captures = undefined;
    const matched = (try built.match("/b", &captures)) orelse return error.TestNoMatch;
    try std.testing.expectEqual(config.RouteKey{ .definition = 0, .route = 1 }, matched.key);
}

test "the synthesized configuration of an entry builds the same pack" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app/index.js", index_source);
    try fixture.write("app/lib/greet.js", greet_source);
    const entry_path = try fixture.path(allocator, "app/index.js");
    defer allocator.free(entry_path);

    var diagnostic: config.Diagnostic = .{};
    const synthesized = try config.synthesize(allocator, entry_path, &diagnostic);
    var built: routes.Routes = undefined;
    try built.init(allocator, synthesized, &diagnostic);
    defer built.deinit();

    const artifact = built.artifact(0);
    try expectEntrySpecifier(artifact, 0, "/var/task/index.js");
    try std.testing.expectEqual(@as(u32, 2), artifact.module_count);
    var captures: routes.Captures = undefined;
    try std.testing.expect((try built.match("/", &captures)) != null);
}

test "a static import that leaves the definition's root fails the boot with file and line, and a dynamic one is left out unread" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app/src/main.js", "import { util } from \"../../shared/util.js\";\nexport default { fetch: util };\n");
    try fixture.write("app/src/lazy.js", "export const later = () => import(\"../../shared/util.js\");\nexport default { fetch() {} };\n");
    try fixture.write("shared/util.js", "export function util() {}\n");

    // The root is app/src, the entry's directory, and the import does not
    // widen it.
    const directory = fixture.directory();
    const expected = try std.fmt.allocPrint(
        allocator,
        "worker 'api' route '/*': {s}/app/src/main.js:1: import '../../shared/util.js': {s}/shared/util.js lies outside the definition's root {s}/app/src",
        .{ directory, directory, directory },
    );
    defer allocator.free(expected);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"app/src/main.js\"}"), expected);

    // The same target behind `import()` boots and stays out of the pack, to
    // reject at run time.
    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"app/src/lazy.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();
    try std.testing.expectEqual(@as(u32, 1), built.artifact(0).module_count);
    try expectEntrySpecifier(built.artifact(0), 0, "/var/task/lazy.js");
}

test "one definition's code cannot pull another definition's files into its artifact" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("tenants/a/index.js",
        \\export const steal = () => import("../b/index.js");
        \\export default { fetch() { return new Response("a"); } };
    );
    try fixture.write("tenants/a/static.js",
        \\import { secret } from "../b/index.js";
        \\export default { fetch() { return new Response(secret); } };
    );
    try fixture.write("tenants/b/index.js",
        \\export const secret = "b-secret";
        \\export default { fetch() { return new Response(secret); } };
    );

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator,
        \\{"workers": {
        \\  "a": {"routes": {"/a": {"entry": "./tenants/a/index.js"}}},
        \\  "b": {"routes": {"/b": {"entry": "./tenants/b/index.js"}}}
        \\}}
    , &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    // a's root is tenants/a, so b's entry is never read for a's artifact,
    // which holds a's entry alone.
    const a_artifact = built.artifact(0);
    try std.testing.expectEqual(@as(u32, 1), a_artifact.module_count);
    try expectEntrySpecifier(a_artifact, 0, "/var/task/index.js");
    const pack_bytes = try readPack(allocator, a_artifact);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    for (0..pack.records.len) |index|
        try std.testing.expect(std.mem.indexOf(u8, pack.moduleAt(index).source, "b-secret") == null);

    // A static import of the same file fails a's boot instead.
    const directory = fixture.directory();
    const expected = try std.fmt.allocPrint(allocator, "{s}/tenants/a/static.js:1: import '../b/index.js': {s}/tenants/b/index.js lies outside the definition's root {s}/tenants/a", .{ directory, directory, directory });
    defer allocator.free(expected);
    try expectBuildFailure(&fixture,
        \\{"workers": {"a": {"routes": {"/a": {"entry": "./tenants/a/static.js"}}}}}
    , expected);
}

test "a symlink inside the root that leads outside it fails the boot, and one that stays inside keeps its own path" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("outside.js", "export const secret = 'outside';\n");
    try fixture.write("shared/util.js", "export const secret = 'shared';\n");
    try fixture.write("app/real.js", "export const value = 'real';\n");
    try fixture.tmp.dir.symLink("../outside.js", "app/escape.js", .{});
    try fixture.tmp.dir.symLink("../shared", "app/linked", .{});
    try fixture.tmp.dir.symLink("real.js", "app/alias.js", .{});
    const directory = fixture.directory();
    const absolute_target = try fixture.path(allocator, "app/real.js");
    defer allocator.free(absolute_target);
    try fixture.tmp.dir.symLink(absolute_target, "app/absolute.js", .{});
    try fixture.write("app/imports-escape.js", "import \"./escape.js\";\n");
    try fixture.write("app/imports-linked.js", "\nimport \"./linked/util.js\";\n");
    try fixture.write("app/imports-absolute.js", "import \"./absolute.js\";\n");
    try fixture.write("app/lazy-escape.js", "export const later = () => import(\"./escape.js\");\n");
    try fixture.write("app/imports-alias.js", "import { value } from \"./alias.js\";\nexport default () => new Response(value);\n");

    const cases = [_]struct { entry: []const u8, site: []const u8, module: []const u8 }{
        // A relative symlink to a file above the root.
        .{ .entry = "imports-escape.js", .site = "imports-escape.js:1: import './escape.js'", .module = "app/escape.js" },
        // A symlinked directory whose target lies outside the root.
        .{ .entry = "imports-linked.js", .site = "imports-linked.js:2: import './linked/util.js'", .module = "app/linked/util.js" },
        // An absolute symlink, refused even though it names a file inside
        // the root.
        .{ .entry = "imports-absolute.js", .site = "imports-absolute.js:1: import './absolute.js'", .module = "app/absolute.js" },
        // Behind `import()` the file exists and cannot be packed.
        .{ .entry = "lazy-escape.js", .site = "lazy-escape.js:1: import('./escape.js')", .module = "app/escape.js" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator, "{{\"workers\": {{\"api\": {{\"routes\": {{\"/*\": {{\"entry\": \"./app/{s}\"}}}}}}}}}}", .{case.entry});
        defer allocator.free(source);
        const expected = try std.fmt.allocPrint(allocator, "{s}/app/{s}: cannot read module {s}/{s}: it resolves outside the definition's root {s}/app", .{ directory, case.site, directory, case.module, directory });
        defer allocator.free(expected);
        try expectBuildFailure(&fixture, source, expected);
    }

    // An entry that is itself such a symlink fails with its route.
    const entry_failure = try std.fmt.allocPrint(allocator, "worker 'api' route '/*': cannot read module {s}/app/escape.js: it resolves outside the definition's root {s}/app", .{ directory, directory });
    defer allocator.free(entry_failure);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"./app/escape.js\"}"), entry_failure);

    // A relative symlink that stays inside is read, under its own path.
    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"./app/imports-alias.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();
    const pack_bytes = try readPack(allocator, built.artifact(0));
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    const alias = pack.findModule("/var/task/alias.js") orelse return error.TestMissingModule;
    try std.testing.expectEqualStrings("export const value = 'real';\n", alias.source);
}

test "a FIFO named by an import fails the boot instead of blocking it" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const rc = std.os.linux.mknodat(fixture.tmp.dir.fd, "pipe.js", std.os.linux.S.IFIFO | 0o600, 0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.E.init(rc));
    try fixture.write("imports-pipe.js", "import \"./pipe.js\";\n");
    try fixture.write("lazy-pipe.js", "export const later = () => import(\"./pipe.js\");\n");

    // No writer ever opens the FIFO, so an open that waited for one would
    // never return.
    const directory = fixture.directory();
    const static_failure = try std.fmt.allocPrint(allocator, "{s}/imports-pipe.js:1: import './pipe.js': cannot read module {s}/pipe.js: NotRegularFile", .{ directory, directory });
    defer allocator.free(static_failure);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"imports-pipe.js\"}"), static_failure);
    const dynamic_failure = try std.fmt.allocPrint(allocator, "{s}/lazy-pipe.js:1: import('./pipe.js'): cannot read module {s}/pipe.js: NotRegularFile", .{ directory, directory });
    defer allocator.free(dynamic_failure);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"lazy-pipe.js\"}"), dynamic_failure);
}

test "an import that climbs above the root and descends into it again is keyed from the directory it climbs to" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Every module lives in app/src, the root, but `../src/util.js` passes
    // through app/ on its way, as the engine's walk from the entry's key
    // does.
    try fixture.write("app/src/index.js",
        \\import { util } from "../src/util.js";
        \\export const later = () => import("../src/lib/lazy.js");
        \\export default { fetch() { return new Response(util); } };
    );
    try fixture.write("app/src/util.js", "export const util = 'u';\n");
    try fixture.write("app/src/lib/lazy.js", "export const value = 'l';\n");

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"app/src/index.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    const artifact = built.artifact(0);
    try expectEntrySpecifier(artifact, 0, "/var/task/src/index.js");
    try std.testing.expectEqual(@as(u32, 3), artifact.module_count);
    const pack_bytes = try readPack(allocator, artifact);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    // Resolving `../src/util.js` against `/var/task/src/index.js` lands on
    // the packed key.
    try std.testing.expect(pack.findModule("/var/task/src/util.js") != null);
    try std.testing.expect(pack.findModule("/var/task/src/lib/lazy.js") != null);
}

test "an import whose '..' would rise above the filesystem root fails the boot" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const directory = fixture.directory();
    // One `..` more than the entry's directory has segments, then back down
    // to a file inside the root: the filesystem stops at `/` and finds it,
    // while the engine's walk from `/var/task/app.js` fails at `/`.
    var specifier: std.ArrayList(u8) = .empty;
    defer specifier.deinit(allocator);
    for (0..std.mem.count(u8, directory, "/") + 1) |_|
        try specifier.appendSlice(allocator, "../");
    try specifier.appendSlice(allocator, directory[1..]);
    try specifier.appendSlice(allocator, "/lib.js");
    const source = try std.fmt.allocPrint(allocator, "import \"{s}\";\n", .{specifier.items});
    defer allocator.free(source);
    try fixture.write("app.js", source);
    try fixture.write("lib.js", "export {};\n");

    const expected = try std.fmt.allocPrint(allocator, "{s}/app.js:1: import '{s}': the path rises above the filesystem root", .{ directory, specifier.items });
    defer allocator.free(expected);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"app.js\"}"), expected);
}

test "a definition's root is the deepest directory holding its routes' entries, for a configuration and for a lone entry" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("api/index.js", "import { util } from \"../shared/util.js\";\nexport default () => new Response(util);\n");
    try fixture.write("web/index.js", "import { util } from \"../shared/util.js\";\nexport default () => new Response(util);\n");
    try fixture.write("shared/util.js", "export const util = 'u';\n");

    // Two routes in api/ and web/ give the definition the directory above
    // both, which holds shared/.
    {
        var diagnostic: config.Diagnostic = .{};
        const parsed = try fixture.parse(allocator,
            \\{"workers": {"site": {"routes": {
            \\  "/api": {"entry": "./api/index.js"},
            \\  "/web": {"entry": "./web/index.js"}
            \\}}}}
        , &diagnostic);
        var built: routes.Routes = undefined;
        built.init(allocator, parsed, &diagnostic) catch |err| {
            std.debug.print("{s}\n", .{diagnostic.message()});
            return err;
        };
        defer built.deinit();
        const pack_bytes = try readPack(allocator, built.artifact(0));
        defer allocator.free(pack_bytes);
        const pack = try module_pack.parse(pack_bytes);
        for ([_][]const u8{ "/var/task/api/index.js", "/var/task/web/index.js", "/var/task/shared/util.js" }) |key|
            try std.testing.expect(pack.findModule(key) != null);
    }

    // The api route alone has api/ for its root, which shared/ is not in.
    const directory = fixture.directory();
    const expected = try std.fmt.allocPrint(allocator, "{s}/api/index.js:1: import '../shared/util.js': {s}/shared/util.js lies outside the definition's root {s}/api", .{ directory, directory, directory });
    defer allocator.free(expected);
    try expectBuildFailure(&fixture,
        \\{"workers": {"site": {"routes": {"/api": {"entry": "./api/index.js"}}}}}
    , expected);

    // `collo serve api/index.js` synthesizes a configuration whose root is
    // the entry's directory, with the same result.
    const entry_path = try fixture.path(allocator, "api/index.js");
    defer allocator.free(entry_path);
    var diagnostic: config.Diagnostic = .{};
    const synthesized = try config.synthesize(allocator, entry_path, &diagnostic);
    var built: routes.Routes = undefined;
    try std.testing.expectError(error.RoutesInvalid, built.init(allocator, synthesized, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "lies outside the definition's root") != null);
}

test "the runtime's own fs modules are not read from disk" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app.js",
        \\import fs from "node:fs";
        \\import { readFile } from "fs/promises";
        \\export * from "fs";
        \\const lazyFs = () => import("node:fs/promises");
        \\export default { fetch() { return fs && readFile && lazyFs; } };
    );

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"app.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    try built.init(allocator, parsed, &diagnostic);
    defer built.deinit();
    try std.testing.expectEqual(@as(u32, 1), built.artifact(0).module_count);
}

test "module text with a character above U+00FF is stored as UTF-16 and Latin-1 text as Latin-1" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const latin_source = "export const word = 'caf\xc3\xa9';\n";
    const wide_source = "export const word = '\xcf\x80 \xf0\x9f\x98\x80';\n";
    try fixture.write("app.js", "import \"./latin.js\";\nimport \"./wide.js\";\nexport default { fetch() {} };\n");
    try fixture.write("latin.js", latin_source);
    try fixture.write("wide.js", wide_source);

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"app.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    const pack_bytes = try readPack(allocator, built.artifact(0));
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);

    // U+00E9 fits a byte, so the whole module stays one byte per character.
    const latin = pack.findModule("/var/task/latin.js") orelse return error.TestMissingModule;
    try std.testing.expectEqual(module_pack.Encoding.latin1, latin.encoding);
    try std.testing.expectEqualSlices(u8, "export const word = 'caf\xe9';\n", latin.source);

    // U+03C0 does not, so the module is stored as UTF-16LE, U+1F600 as a
    // surrogate pair.
    const wide = pack.findModule("/var/task/wide.js") orelse return error.TestMissingModule;
    try std.testing.expectEqual(module_pack.Encoding.utf16le, wide.encoding);
    const expected_units = std.unicode.utf8ToUtf16LeStringLiteral(wide_source);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_units), wide.source);

    // The entry, plain ASCII, keeps its bytes as they are on disk.
    const entry = pack.moduleAt(0);
    try std.testing.expectEqual(module_pack.Encoding.latin1, entry.encoding);
}

test "an empty module is packed as an empty Latin-1 source" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app.js", "import \"./polyfill.js\";\nexport default { fetch() {} };\n");
    try fixture.write("polyfill.js", "");

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"app.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    const pack_bytes = try readPack(allocator, built.artifact(0));
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    const polyfill = pack.findModule("/var/task/polyfill.js") orelse return error.TestMissingModule;
    try std.testing.expectEqual(module_pack.Encoding.latin1, polyfill.encoding);
    try std.testing.expectEqual(@as(usize, 0), polyfill.source.len);
}

test "a string-literal import() is packed with its own imports and a computed one is not" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app/index.js",
        \\const name = "./lib/computed.js";
        \\export default {
        \\    async fetch() {
        \\        const lazy = await import("./lib/lazy.js");
        \\        const computed = await import(name);
        \\        const joined = await import("./lib/" + "joined.js");
        \\        return new Response(lazy.value + computed.value + joined.value);
        \\    },
        \\};
    );
    try fixture.write("app/lib/lazy.js",
        \\import { shared } from "./shared.js";
        \\export const value = shared;
        \\export const deeper = () => import('./deeper.js');
    );
    try fixture.write("app/lib/shared.js", "export const shared = 's';\n");
    try fixture.write("app/lib/deeper.js", "export const value = 'd';\n");
    // On disk but named only by computed specifiers, so never read.
    try fixture.write("app/lib/computed.js", "export const value = 'c';\n");
    try fixture.write("app/lib/joined.js", "export const value = 'j';\n");

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"app/index.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    const artifact = built.artifact(0);
    try expectEntrySpecifier(artifact, 0, "/var/task/index.js");
    try std.testing.expectEqual(@as(u32, 4), artifact.module_count);
    const pack_bytes = try readPack(allocator, artifact);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);

    // The lazy module, its own static import and the target of its own
    // `import()` are packed.
    try std.testing.expect(pack.findModule("/var/task/lib/lazy.js") != null);
    try std.testing.expect(pack.findModule("/var/task/lib/shared.js") != null);
    try std.testing.expect(pack.findModule("/var/task/lib/deeper.js") != null);

    try std.testing.expect(pack.findModule("/var/task/lib/computed.js") == null);
    try std.testing.expect(pack.findModule("/var/task/lib/joined.js") == null);
}

test "a string-literal import() of a target that cannot be packed boots and leaves it to fail at run time" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Each call guards a dependency the module treats as optional: in the
    // worker it rejects, which the module may catch. `./\x61.js` spells
    // `./a.js`, which is on disk, but the scan does not decode escapes.
    try fixture.write("app.js",
        \\export const optional = [
        \\    () => import("hono"),
        \\    () => import('/etc/x.js'),
        \\    () => import("https://example.com/x.js"),
        \\    () => import("node:path"),
        \\    () => import("./nope.js"),
        \\    () => import("../outside/nope.js"),
        \\    () => import('./\x61.js'),
        \\];
        \\export default { fetch() { return new Response("ok"); } };
    );
    try fixture.write("a.js", "export const value = 'a';\n");

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"app.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    built.init(allocator, parsed, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    const artifact = built.artifact(0);
    try std.testing.expectEqual(@as(u32, 1), artifact.module_count);
    const pack_bytes = try readPack(allocator, artifact);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try std.testing.expect(pack.findModule("/var/task/a.js") == null);
}

test "a string-literal import() of a target that exists but cannot be packed fails the boot, with file and line" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("dynamic-broken.js", "\nexport const later = () => import(\"./broken.js\");\n");
    try fixture.write("broken.js", "const s = 'never closed\n");
    try fixture.write("dynamic-directory.js", "\n\nexport const later = () => import(\"./lib\");\n");
    try fixture.tmp.dir.makePath("lib");

    const allocator = std.testing.allocator;
    const directory = fixture.directory();
    // The target is read and scanned as any packed module is.
    const broken = try std.fmt.allocPrint(allocator, "{s}/broken.js:1: unterminated string literal", .{directory});
    defer allocator.free(broken);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"dynamic-broken.js\"}"), broken);

    // A path that names a directory exists but holds no module.
    const directory_target = try std.fmt.allocPrint(allocator, "{s}/dynamic-directory.js:3: import('./lib'): cannot read module {s}/lib", .{ directory, directory });
    defer allocator.free(directory_target);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"dynamic-directory.js\"}"), directory_target);
}

test "the configuration local-e2e serves builds, with the target of its string-literal import() packed" {
    // Lanes run from the repository root, which anchors the fixture path, as
    // local-e2e does.
    const allocator = std.testing.allocator;
    var diagnostic: config.Diagnostic = .{};
    const loaded = config.load(allocator, "runtime/tests/integration/fixtures/local_e2e/collo.json", &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    var built: routes.Routes = undefined;
    built.init(allocator, loaded, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    defer built.deinit();

    var captures: routes.Captures = undefined;
    const matched = (try built.match("/lazy", &captures)) orelse return error.TestNoMatch;
    const artifact = built.artifact(matched.key.definition);
    try expectEntrySpecifier(artifact, matched.key.route, "/var/task/lazy.js");
    const pack_bytes = try readPack(allocator, artifact);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try std.testing.expect(pack.findModule("/var/task/lib/lazy_value.js") != null);
    try std.testing.expect(pack.findModule("/var/task/lib/absent.js") == null);
}

test "a graph that cannot be packed fails with the route and the file" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("bare.js", "import { Hono } from \"hono\";\n");
    try fixture.write("missing-import.js", "\nimport x from \"./nope.js\";\n");
    try fixture.write("absolute.js", "import x from \"/etc/x.js\";\n");
    try fixture.write("url.js", "import x from \"https://example.com/x.js\";\n");
    try fixture.write("node-path.js", "import path from \"node:path\";\n");
    try fixture.write("imports-broken.js", "import \"./broken.js\";\n");
    try fixture.write("broken.js", "const s = 'never closed\n");
    try fixture.write("imports-spaced.js", "import \"./my file.js\";\n");
    try fixture.write("my file.js", "export {};\n");

    const allocator = std.testing.allocator;
    const directory = fixture.directory();
    const missing_entry = try std.fmt.allocPrint(allocator, "worker 'api' route '/*': cannot read module {s}/missing.js: FileNotFound", .{directory});
    defer allocator.free(missing_entry);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"missing.js\"}"), missing_entry);

    const bare = try std.fmt.allocPrint(allocator, "worker 'api' route '/*': {s}/bare.js:1: import 'hono': package imports are not supported", .{directory});
    defer allocator.free(bare);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"bare.js\"}"), bare);

    const missing_import = try std.fmt.allocPrint(allocator, "{s}/missing-import.js:2: import './nope.js': cannot read module {s}/nope.js: FileNotFound", .{ directory, directory });
    defer allocator.free(missing_import);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"missing-import.js\"}"), missing_import);

    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"absolute.js\"}"), "import '/etc/x.js': absolute imports are not supported");
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"url.js\"}"), "only relative paths and the runtime's node:fs modules can be imported");
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"node-path.js\"}"), "import 'node:path': only relative paths");

    const broken = try std.fmt.allocPrint(allocator, "{s}/broken.js:1: unterminated string literal", .{directory});
    defer allocator.free(broken);
    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"imports-broken.js\"}"), broken);

    try expectBuildFailure(&fixture, catchAll("{\"entry\": \"imports-spaced.js\"}"), "my file.js has a path that cannot be a module specifier");
}

test "a descriptor the server cannot get fails the build as unavailable resources, not as invalid routes" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app/index.js", index_source);
    try fixture.write("app/lib/greet.js", greet_source);
    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"./app/index.js\"}"), &diagnostic);

    // Every descriptor below the lowest free one is open, so a soft limit at
    // it refuses the next memfd and the next module file alike. The runner
    // is single-threaded, so nothing else opens a descriptor meanwhile.
    const probe = try std.fs.openFileAbsolute("/dev/null", .{});
    const lowest_free = probe.handle;
    probe.close();
    const saved = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = @intCast(lowest_free), .max = saved.max });
    var built: routes.Routes = undefined;
    const result = built.init(allocator, parsed, &diagnostic);
    try std.posix.setrlimit(.NOFILE, saved);

    if (result) |_| {
        built.deinit();
        return error.TestExpectedResourceFailure;
    } else |err| {
        try std.testing.expectEqual(error.RouteResourcesUnavailable, err);
    }
}

fn buildFixtureRoutes(allocator: std.mem.Allocator, fixture: *const Fixture) !void {
    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll(
        \\{"entry": "./app/index.js", "bindings": {"GREETING": {"text": "hello"}}}
    ), &diagnostic);
    var built: routes.Routes = undefined;
    try built.init(allocator, parsed, &diagnostic);
    built.deinit();
}

test "building routes frees everything when any allocation fails" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Both kinds of import, so every list the graph grows meets a failure.
    try fixture.write("app/index.js",
        \\import { greet } from "./lib/greet.js";
        \\export default { fetch: async () => (await import("./lib/lazy.js")).value + greet() };
    );
    try fixture.write("app/lib/greet.js", greet_source);
    try fixture.write("app/lib/lazy.js", "export const value = 'lazy';\n");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildFixtureRoutes, .{&fixture});
}
