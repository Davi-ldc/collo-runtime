//! `Routes` and the definition artifacts (`server/routes/root.zig`,
//! `server/routes/artifacts.zig`, `server/routes/module_graph.zig`) built from
//! modules in a temporary directory: a two-module entry packed into a sealed
//! memfd with its dependency, the route table with the route's bindings, the
//! shared placeholder fs index, lookups by path and by key, a definition with
//! several routes sharing one pack and one table, the synthesized
//! configuration, a module root above the entry's directory, the runtime's
//! own fs modules, an empty module, the targets of string-literal `import()`
//! packed with their own imports while computed ones and those that cannot
//! be packed stay out, the ways a graph fails with the file and line each
//! failure names, allocation failure at every step, and the configuration
//! local-e2e serves.
//!
//! What a worker does with the artifacts is covered by `worker-test`,
//! `zygote-integration` and `local-e2e`.

const std = @import("std");
const config = @import("collo_server_config");
const routes = @import("collo_server_routes");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

const module_pack = ipc.module_pack;

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

/// The route table of `artifact`, read back from its sealed memfd; the
/// caller frees it.
fn readRouteTable(allocator: std.mem.Allocator, artifact: *const routes.DefinitionArtifact) ![]u8 {
    try fd_mod.requireSeals(artifact.route_table.fd, fd_mod.memfd_readonly_seals);
    return readAll(allocator, artifact.route_table.fd, artifact.route_table.blob_len);
}

/// The entry specifier of route `index` in `artifact`'s route table; the
/// caller frees it.
fn entrySpecifier(allocator: std.mem.Allocator, artifact: *const routes.DefinitionArtifact, index: usize) ![]u8 {
    const table = try readRouteTable(allocator, artifact);
    defer allocator.free(table);
    var decoded: ipc.route_table.Routes = undefined;
    const table_routes = try ipc.route_table.decode(table, &decoded);
    return allocator.dupe(u8, table_routes[index].entry_specifier);
}

fn expectEntrySpecifier(artifact: *const routes.DefinitionArtifact, index: usize, expected: []const u8) !void {
    const actual = try entrySpecifier(std.testing.allocator, artifact, index);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectBuildFailure(fixture: *const Fixture, source: []const u8, expected: []const u8) !void {
    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(std.testing.allocator, source, &diagnostic);
    var built: routes.Routes = undefined;
    try std.testing.expectError(error.RouteBuildFailed, built.init(std.testing.allocator, parsed, &diagnostic));
    if (std.mem.indexOf(u8, diagnostic.message(), expected) == null) {
        std.debug.print("message: {s}\nexpected it to contain: {s}\n", .{ diagnostic.message(), expected });
        return error.TestUnexpectedMessage;
    }
}

test "a two-module entry is packed with its dependency next to its route table and fs index" {
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
    // The module root is `app/`, the deepest directory holding both files.
    const entry = "/__collo_route/api/index.js";
    try expectEntrySpecifier(artifact, key.route, entry);
    try std.testing.expectEqual(@as(u32, 2), artifact.module_count);
    try std.testing.expectEqual(artifact.module_pack_bytes, built.pack_bytes_total);

    try fd_mod.requireSeals(artifact.module_pack.fd(), fd_mod.memfd_readonly_seals);
    const pack_bytes = try readAll(allocator, artifact.module_pack.fd(), artifact.module_pack_bytes);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try std.testing.expectEqualStrings(entry, pack.entrySpecifier());
    try module_pack.validateSameDeployScopedPack(pack, entry);
    try std.testing.expectEqualStrings(index_source, pack.moduleAt(0).source);
    try std.testing.expectEqual(@as(usize, 1), pack.moduleAt(0).dependency_count);
    try std.testing.expectEqualStrings("/__collo_route/api/lib/greet.js", pack.dependencyAt(0, 0).specifier);
    const greet = pack.findModule("/__collo_route/api/lib/greet.js") orelse return error.TestMissingModule;
    try std.testing.expectEqualStrings(greet_source, greet.source);

    // The table both processes read, byte for byte: one route, its entry,
    // then its bindings in configuration order.
    const table = try readRouteTable(allocator, artifact);
    defer allocator.free(table);
    const expected_bindings = "\x02\x00\x00\x00" ++
        "\x08\x00\x00\x00GREETING" ++ "\x05\x00\x00\x00hello" ++
        "\x05\x00\x00\x00EMPTY" ++ "\x00\x00\x00\x00";
    const expected_table = "\x01\x00\x00\x00" ++
        "\x1b\x00\x00\x00" ++ entry ++
        "\x26\x00\x00\x00" ++ expected_bindings;
    try std.testing.expectEqualSlices(u8, expected_table, table);

    try fd_mod.requireSeals(artifact.fs_index.fd(), fd_mod.memfd_readonly_seals);
    try std.testing.expectEqual(built.fs_index.fd(), artifact.fs_index.fd());
    const index_bytes = try readAll(allocator, artifact.fs_index.fd(), 8);
    defer allocator.free(index_bytes);
    try std.testing.expectEqualStrings("COLLOFS1", index_bytes);

    var captures: routes.Captures = undefined;
    const matched = (try built.match("/any/path", &captures)) orelse return error.TestNoMatch;
    try std.testing.expectEqual(key, matched.key);
    try std.testing.expectEqualStrings("/*", built.route(matched.key).pattern);
    try std.testing.expectEqualStrings("api", built.definition(0).name);
    try std.testing.expectEqual(@as(u16, 1), built.definitionCount());
}

test "a definition's routes share one pack holding each module once and a table in route order" {
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
    const pack_bytes = try readAll(allocator, artifact.module_pack.fd(), artifact.module_pack_bytes);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try std.testing.expectEqualStrings("/__collo_route/api/a.js", pack.entrySpecifier());
    try std.testing.expectEqual(@as(usize, 4), pack.records.len);
    for ([_][]const u8{ "a.js", "b.js", "lib/shared.js", "lib/only_b.js" }) |path| {
        const key = try std.fmt.allocPrint(allocator, "/__collo_route/api/{s}", .{path});
        defer allocator.free(key);
        try std.testing.expect(pack.findModule(key) != null);
    }

    // Each route names its entry in the table, routes that share an entry
    // share its key, and each keeps its own bindings.
    const table = try readRouteTable(allocator, artifact);
    defer allocator.free(table);
    var decoded: ipc.route_table.Routes = undefined;
    const table_routes = try ipc.route_table.decode(table, &decoded);
    try std.testing.expectEqual(@as(usize, 3), table_routes.len);
    const expected = [_]struct { entry: []const u8, name: ?[]const u8 }{
        .{ .entry = "/__collo_route/api/a.js", .name = "a" },
        .{ .entry = "/__collo_route/api/b.js", .name = "b" },
        .{ .entry = "/__collo_route/api/a.js", .name = null },
    };
    for (table_routes, expected) |table_route, want| {
        try std.testing.expectEqualStrings(want.entry, table_route.entry_specifier);
        var entries: ipc.route_bindings.Entries = undefined;
        const bindings = try ipc.route_bindings.decode(table_route.bindings, &entries);
        if (want.name) |name| {
            try std.testing.expectEqual(@as(usize, 1), bindings.len);
            try std.testing.expectEqualStrings("NAME", bindings[0].name);
            try std.testing.expectEqualStrings(name, bindings[0].value);
        } else {
            try std.testing.expectEqual(@as(usize, 0), bindings.len);
        }
    }

    // A path's route key indexes that table.
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
    try expectEntrySpecifier(artifact, 0, "/__collo_route/index/index.js");
    try std.testing.expectEqual(@as(u32, 2), artifact.module_count);
    var captures: routes.Captures = undefined;
    try std.testing.expect((try built.match("/", &captures)) != null);
}

test "an import above the entry's directory moves the module root up" {
    const allocator = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("app/src/main.js", "import { util } from \"../../shared/util.js\";\nexport default { fetch: util };\n");
    try fixture.write("shared/util.js", "export function util() {}\n");

    var diagnostic: config.Diagnostic = .{};
    const parsed = try fixture.parse(allocator, catchAll("{\"entry\": \"app/src/main.js\"}"), &diagnostic);
    var built: routes.Routes = undefined;
    try built.init(allocator, parsed, &diagnostic);
    defer built.deinit();

    const artifact = built.artifact(0);
    try expectEntrySpecifier(artifact, 0, "/__collo_route/api/app/src/main.js");
    const pack_bytes = try readAll(allocator, artifact.module_pack.fd(), artifact.module_pack_bytes);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try std.testing.expect(pack.findModule("/__collo_route/api/shared/util.js") != null);
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

test "an empty module is packed as a one-newline source that evaluates the same" {
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

    const artifact = built.artifact(0);
    const pack_bytes = try readAll(allocator, artifact.module_pack.fd(), artifact.module_pack_bytes);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    const polyfill = pack.findModule("/__collo_route/api/polyfill.js") orelse return error.TestMissingModule;
    try std.testing.expectEqualStrings("\n", polyfill.source);
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
    try expectEntrySpecifier(artifact, 0, "/__collo_route/api/index.js");
    try std.testing.expectEqual(@as(u32, 4), artifact.module_count);
    const pack_bytes = try readAll(allocator, artifact.module_pack.fd(), artifact.module_pack_bytes);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);

    // The entry evaluates without the module it imports dynamically, so the
    // pack records no dependency for it; the lazy module's own static import
    // is one.
    try std.testing.expectEqual(@as(usize, 0), pack.moduleAt(0).dependency_count);
    const lazy_index = pack.findIndex("/__collo_route/api/lib/lazy.js") orelse return error.TestMissingModule;
    try std.testing.expectEqual(@as(usize, 1), pack.moduleAt(lazy_index).dependency_count);
    try std.testing.expectEqualStrings("/__collo_route/api/lib/shared.js", pack.dependencyAt(lazy_index, 0).specifier);
    try std.testing.expect(pack.findModule("/__collo_route/api/lib/deeper.js") != null);

    try std.testing.expect(pack.findModule("/__collo_route/api/lib/computed.js") == null);
    try std.testing.expect(pack.findModule("/__collo_route/api/lib/joined.js") == null);
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
    const pack_bytes = try readAll(allocator, artifact.module_pack.fd(), artifact.module_pack_bytes);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try std.testing.expect(pack.findModule("/__collo_route/api/a.js") == null);
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
    try expectEntrySpecifier(artifact, matched.key.route, "/__collo_route/lazy/lazy.js");
    const pack_bytes = try readAll(allocator, artifact.module_pack.fd(), artifact.module_pack_bytes);
    defer allocator.free(pack_bytes);
    const pack = try module_pack.parse(pack_bytes);
    try std.testing.expect(pack.findModule("/__collo_route/lazy/lib/lazy_value.js") != null);
    try std.testing.expect(pack.findModule("/__collo_route/lazy/lib/absent.js") == null);
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
