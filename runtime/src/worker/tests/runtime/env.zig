//! Covers the handler's second argument: the `env` object a route's
//! bindings section becomes (`worker/modules/route_env.zig`), its identity
//! across requests, each route receiving its own bindings and never another
//! route's, the check of every bindings section when the worker boots its
//! definition's artifact, and the entries `collo_env_object_new` refuses on
//! its own. Valid artifacts come from the builder the server uses
//! (`module_pack.buildAlloc` in `common/ipc/module_pack.zig`); the refused
//! ones are written here byte by byte, so these tests also pin the routes
//! section's layout from the worker's side. The forked path, where WorkerInit
//! delivers the artifact, runs in `local-e2e`.

const std = @import("std");
const support = @import("bindings_support");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const server_limits = @import("collo_limits").server;
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const socketPairType = rt.socketPairType;

const module_pack = ipc.module_pack;
const route_bindings = ipc.route_bindings;
const route_table = ipc.route_table;
const Entry = route_bindings.Entry;

/// One route of a fixture's definition: the path the harness turns into the
/// route's entry specifier (`rt.routeSpecifier`), its entry's source, and its
/// bindings.
const RouteSpec = struct {
    path: []const u8,
    source: []const u8,
    bindings: []const Entry = &.{},
};

/// One runtime under test, booted from the artifact of `routes`, each route
/// with an entry module of its own.
const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    now_mono_ns: u64,
    completion: rt.CompletionFixture,
    runtime: worker.Runtime,

    /// Initializes in place: the runtime keeps pointers to the clock and the
    /// completion view.
    fn init(self: *Fixture, routes: []const RouteSpec) !void {
        var specifiers: [route_table.routes_max][]u8 = undefined;
        var modules: [route_table.routes_max]module_pack.Module = undefined;
        var inputs: [route_table.routes_max]route_table.RouteInput = undefined;
        var built: usize = 0;
        defer for (specifiers[0..built]) |specifier| std.testing.allocator.free(specifier);
        for (routes, 0..) |route, index| {
            specifiers[index] = try rt.routeSpecifier(std.testing.allocator, route.path);
            built += 1;
            modules[index] = .{ .specifier = specifiers[index], .source = route.source };
            inputs[index] = .{ .entry_module = @intCast(index), .bindings = route.bindings };
        }
        const pack_fd = try rt.createDefinitionFd(modules[0..routes.len], inputs[0..routes.len]);
        defer std.posix.close(pack_fd);

        self.vm = try support.createVm();
        errdefer self.vm.deinit();
        self.control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer for (self.control_pair) |fd| std.posix.close(fd);
        self.now_mono_ns = 0;
        self.completion = try rt.CompletionFixture.init();
        errdefer self.completion.deinit();
        self.runtime = try worker.Runtime.init(std.testing.allocator, &self.vm, self.control_pair[0], &self.completion.view, try rt.createCompletionEventfd(), .{
            .ctx = &self.now_mono_ns,
            .now_fn = fakeNow,
        });
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
        try rt.bootDefinition(&self.runtime, pack_fd);
    }

    /// The runtime goes before the VM, whose pack its routes borrow from.
    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        for (self.control_pair) |fd| std.posix.close(fd);
        self.vm.deinit();
        self.* = undefined;
    }

    /// Runs one request on the route at `route_index` and returns the
    /// response body, which the caller frees.
    fn run(self: *Fixture, request_id: u64, route_index: u16) ![]u8 {
        const specifier = self.runtime.modules.state.routes.items[route_index].entry_specifier;
        return rt.runRegisteredRouteAndReadBody(&self.runtime, self.control_pair[1], request_id, specifier, .{});
    }
};

test "handler receives the text bindings its route carries in the artifact as a frozen env object" {
    var fixture: Fixture = undefined;
    // Module code is strict, so writing to a frozen object throws.
    try fixture.init(&.{.{
        .path = "env-bindings.js",
        .source =
        \\export default function handle(request, env) {
        \\    let writeThrew = false;
        \\    try { env.SECRET = "changed"; } catch { writeThrew = true; }
        \\    return JSON.stringify({
        \\        keys: Object.keys(env),
        \\        secret: env.SECRET,
        \\        greeting: env.GREETING,
        \\        empty: env.EMPTY,
        \\        frozen: Object.isFrozen(env),
        \\        ordinary: Object.getPrototypeOf(env) === Object.prototype,
        \\        writeThrew,
        \\    });
        \\}
        ,
        .bindings = &.{
            .{ .name = "SECRET", .value = "s3cr3t" },
            .{ .name = "GREETING", .value = "olá" },
            .{ .name = "EMPTY", .value = "" },
        },
    }});
    defer fixture.deinit();

    const body = try fixture.run(1, 0);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"keys\":[\"SECRET\",\"GREETING\",\"EMPTY\"],\"secret\":\"s3cr3t\",\"greeting\":\"olá\",\"empty\":\"\"," ++
            "\"frozen\":true,\"ordinary\":true,\"writeThrew\":true}",
        body,
    );
}

test "every request of a route receives the same env object" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        .path = "env-identity.js",
        .source =
        \\let first = null;
        \\export default function handle(request, env) {
        \\    first ??= env;
        \\    return String(first === env && env.TOKEN === "abc");
        \\}
        ,
        .bindings = &.{.{ .name = "TOKEN", .value = "abc" }},
    }});
    defer fixture.deinit();

    for (1..4) |request_id| {
        const body = try fixture.run(request_id, 0);
        defer std.testing.allocator.free(body);
        try std.testing.expectEqualStrings("true", body);
    }
}

test "each route receives its own bindings and never another route's" {
    const source =
        \\export default function handle(request, env) {
        \\    return JSON.stringify(env);
        \\}
    ;
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ .path = "env-a.js", .source = source, .bindings = &.{.{ .name = "SECRET", .value = "secret-a" }} },
        .{ .path = "env-b.js", .source = source, .bindings = &.{
            .{ .name = "SECRET", .value = "secret-b" },
            .{ .name = "ONLY_B", .value = "b" },
        } },
        .{ .path = "env-none.js", .source = source },
    });
    defer fixture.deinit();

    const expected = [_][]const u8{
        "{\"SECRET\":\"secret-a\"}",
        "{\"SECRET\":\"secret-b\",\"ONLY_B\":\"b\"}",
        "{}",
    };
    for (expected, 0..) |text, route_index| {
        const body = try fixture.run(route_index + 1, @intCast(route_index));
        defer std.testing.allocator.free(body);
        try std.testing.expectEqualStrings(text, body);
    }
}

test "a route without bindings receives an empty frozen env object" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        .path = "env-empty.js",
        .source =
        \\export default function handle(request, env) {
        \\    return String(typeof env === "object" && Object.keys(env).length === 0 && Object.isFrozen(env));
        \\}
        ,
    }});
    defer fixture.deinit();

    const body = try fixture.run(1, 0);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("true", body);
}

test "a binding named like a prototype property is an own value of env" {
    // Defining properties directly bypasses the `__proto__` setter of
    // Object.prototype, so the binding neither vanishes nor swaps the
    // prototype.
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        .path = "env-proto.js",
        .source =
        \\export default function handle(request, env) {
        \\    const own = Object.getOwnPropertyDescriptor(env, "__proto__");
        \\    return JSON.stringify({
        \\        proto: own && own.value,
        \\        toString: env.toString,
        \\        ordinary: Object.getPrototypeOf(env) === Object.prototype,
        \\    });
        \\}
        ,
        .bindings = &.{
            .{ .name = "__proto__", .value = "own" },
            .{ .name = "toString", .value = "shadowed" },
        },
    }});
    defer fixture.deinit();

    const body = try fixture.run(1, 0);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"proto\":\"own\",\"toString\":\"shadowed\",\"ordinary\":true}", body);
}

test "the env bridge refuses entries it cannot define without running JavaScript" {
    var vm = try support.createVm();
    defer vm.deinit();

    // The decoder never passes any of these, and the bridge refuses each on
    // its own: array index names, which would need indexed storage, an
    // empty name, and a value that is not UTF-8.
    const refused = [_]support.bindings.NameValuePair{
        .{ .name = raw("0"), .value = raw("v") },
        .{ .name = raw("4294967294"), .value = raw("v") },
        .{ .name = raw(""), .value = raw("v") },
        .{ .name = raw("NAME"), .value = raw("\xc3") },
    };
    const realm = vm.mainRealm();
    for (refused) |entry|
        try std.testing.expectError(error.InvalidArgument, realm.envObjectValue(&.{entry}));

    // An array index is below 2^32 - 1 (ECMA-262), so this index-like name
    // is an ordinary one.
    var accepted = try realm.envObjectValue(&.{.{ .name = raw("4294967295"), .value = raw("max") }});
    accepted.deinit();
}

fn raw(bytes: []const u8) support.bindings.RawString {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

test "the boot refuses an artifact with a malformed bindings section and registers nothing" {
    const too_many_count = server_limits.bindings_per_route_max + 1;
    var too_many: [too_many_count]Entry = undefined;
    var names: [too_many_count][8]u8 = undefined;
    for (&too_many, &names, 0..) |*entry, *name, index| {
        const text = try std.fmt.bufPrint(name, "B{d}", .{index});
        entry.* = .{ .name = text, .value = "v" };
    }
    const invalid_cases = [_][]const Entry{
        &.{.{ .name = "1NAME", .value = "v" }},
        &.{.{ .name = "", .value = "v" }},
        &.{.{ .name = "has-dash", .value = "v" }},
        &.{ .{ .name = "TWICE", .value = "a" }, .{ .name = "TWICE", .value = "b" } },
        &.{.{ .name = "BYTES", .value = "\xff\xfe" }},
        &too_many,
    };
    for (invalid_cases) |entries| {
        // The builder refuses each case on its own; the worker must refuse
        // the same bytes when they arrive anyway.
        try std.testing.expectError(error.InvalidModulePack, module_pack.buildAlloc(
            std.testing.allocator,
            &.{.{ .specifier = env_specifier, .source = env_source }},
            &.{.{ .entry_module = 0, .bindings = entries }},
        ));
        const section = try uncheckedSection(entries);
        defer std.testing.allocator.free(section);
        const artifact = try uncheckedArtifact(section);
        defer std.testing.allocator.free(artifact);
        try expectBootRefuses(artifact);
    }

    // Sections the builder never writes: a count with no entry behind it, a
    // name length past the end, a byte after the last entry, a truncated
    // count and no bytes at all.
    const raw_sections = [_][]const u8{
        &.{ 1, 0, 0, 0 },
        &.{ 1, 0, 0, 0, 200, 0, 0, 0, 'A' },
        &.{ 0, 0, 0, 0, 0 },
        &.{ 0, 0 },
        &.{},
    };
    for (raw_sections) |section| {
        const artifact = try uncheckedArtifact(section);
        defer std.testing.allocator.free(artifact);
        try expectBootRefuses(artifact);
    }

    // The writer below matches the builder: with a valid section the two
    // produce the same bytes, which the boot accepts.
    const empty_section = try uncheckedSection(&.{});
    defer std.testing.allocator.free(empty_section);
    const written = try uncheckedArtifact(empty_section);
    defer std.testing.allocator.free(written);
    const built = try module_pack.buildSingleRouteAlloc(std.testing.allocator, env_specifier, env_source);
    defer std.testing.allocator.free(built);
    try std.testing.expectEqualSlices(u8, built, written);

    // And an artifact that is not one at all.
    try expectBootRefuses(&.{ 1, 0 });
}

const env_specifier = module_pack.task_root ++ "/env.js";
const env_source = "export default (request, env) => JSON.stringify(env);";

/// `entries` in the bindings layout without the encoder's checks; the
/// caller frees it.
fn uncheckedSection(entries: []const Entry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    try bytes.appendSlice(std.testing.allocator, &le32(entries.len));
    for (entries) |entry| {
        for ([_][]const u8{ entry.name, entry.value }) |field| {
            try bytes.appendSlice(std.testing.allocator, &le32(field.len));
            try bytes.appendSlice(std.testing.allocator, field);
        }
    }
    return bytes.toOwnedSlice(std.testing.allocator);
}

/// The artifact of one ASCII module, `env_specifier` with `env_source`, and
/// one route to it whose bindings section is `section`, laid out as
/// `common/ipc/module_pack.zig` describes but without the builder's checks;
/// the caller frees it.
fn uncheckedArtifact(section: []const u8) ![]u8 {
    const header_len = @sizeOf(module_pack.Header);
    const record_len = @sizeOf(module_pack.ModuleRecord);
    const index_capacity = 2;
    const route_record_offset = header_len + record_len + index_capacity * @sizeOf(module_pack.IndexEntry);
    const bindings_offset = route_record_offset + @sizeOf(route_table.RouteRecord);
    const specifiers_offset = bindings_offset + section.len;
    const sources_offset = specifiers_offset + env_specifier.len;
    const total_len = sources_offset + env_source.len;
    const hash = module_pack.hashSpecifier(env_specifier);
    const empty_slot = [_]u32{ 0, module_pack.empty_index_module };
    const live_slot = [_]u32{ hash, 0 };
    // The u16 version, then the u16 flags, which are zero.
    var version_and_flags: [4]u8 = @splat(0);
    std.mem.writeInt(u16, version_and_flags[0..2], module_pack.version, .little);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    const allocator = std.testing.allocator;
    try bytes.appendSlice(allocator, &le32(module_pack.magic));
    try bytes.appendSlice(allocator, &version_and_flags);
    for ([_]usize{ 1, index_capacity, 1, specifiers_offset, sources_offset, total_len }) |field|
        try bytes.appendSlice(allocator, &le32(field));
    for ([_]usize{ specifiers_offset, env_specifier.len, sources_offset, env_source.len, 0 }) |field|
        try bytes.appendSlice(allocator, &le32(field));
    // Linear probing puts the module at its hash's slot of the two.
    for (0..index_capacity) |slot| {
        const entry = if (slot == hash & (index_capacity - 1)) live_slot else empty_slot;
        for (entry) |field|
            try bytes.appendSlice(allocator, &le32(field));
    }
    for ([_]usize{ 0, bindings_offset, section.len }) |field|
        try bytes.appendSlice(allocator, &le32(field));
    try bytes.appendSlice(allocator, section);
    try bytes.appendSlice(allocator, env_specifier);
    try bytes.appendSlice(allocator, env_source);
    std.debug.assert(bytes.items.len == total_len);
    return bytes.toOwnedSlice(allocator);
}

fn le32(value: usize) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast(value), .little);
    return bytes;
}

/// Boots a fresh runtime from `artifact`, sealed into a memfd as the server
/// seals one, and expects the boot to refuse it with nothing registered.
fn expectBootRefuses(artifact: []const u8) !void {
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion = try rt.CompletionFixture.init();
    defer completion.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();

    const fd = try std.posix.memfd_create("collo-test-artifact", std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    defer std.posix.close(fd);
    try fd_mod.writeAllRaw(fd, artifact);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    try std.testing.expectError(error.InvalidModulePack, runtime.evaluateBootRoutes(fd, 0, null));
    try std.testing.expectEqual(@as(usize, 0), runtime.modules.state.routes.items.len);
}
