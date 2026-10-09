//! Covers the handler's second argument: the `env` object a route's
//! bindings section becomes (`worker/modules/route_env.zig`), its identity
//! across requests, each route receiving its own bindings and never another
//! route's, the route table check that runs when the runtime starts, and the
//! entries `collo_env_object_new` refuses on its own. Valid tables come from
//! the builder the server uses (`route_table.buildSealed` in
//! `common/ipc/route_table.zig`), so these tests also pin the layout both
//! ends share. The forked path, where WorkerInit delivers the table, runs in
//! `local-e2e`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const server_limits = @import("collo_limits").server;
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const socketPairType = rt.socketPairType;
const runRouteAndReadBody = rt.runRouteAndReadBody;

const route_bindings = ipc.route_bindings;
const route_table = ipc.route_table;
const Entry = route_bindings.Entry;

/// One route of a fixture's table: the path the harness turns into the
/// route's specifier (`rt.routeSpecifier`), and its bindings.
const RouteSpec = struct {
    path: []const u8,
    bindings: []const Entry = &.{},
};

/// The table `routes` serialize to, read back from the sealed memfd a
/// worker receives with WorkerInit; the caller frees it.
fn sealedTable(routes: []const route_table.RouteInput) ![]u8 {
    const sealed = try route_table.buildSealed(std.testing.allocator, routes);
    defer sealed.close();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(sealed.blob_len));
    errdefer std.testing.allocator.free(bytes);
    if (try std.posix.pread(sealed.fd, bytes, 0) != bytes.len)
        return error.ShortTableRead;
    return bytes;
}

/// A one-route table naming `/__collo_route/test/env.js` whose bindings
/// section is `section`, written without the builder's checks, for sections
/// the builder refuses to write; the caller frees it.
fn uncheckedTable(section: []const u8) ![]u8 {
    const specifier = "/__collo_route/test/env.js";
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    for ([_][]const u8{ &.{ 1, 0, 0, 0 }, &lengthBytes(specifier.len), specifier, &lengthBytes(section.len), section }) |part|
        try bytes.appendSlice(std.testing.allocator, part);
    return bytes.toOwnedSlice(std.testing.allocator);
}

/// `entries` in the bindings layout without the encoder's checks; the
/// caller frees it.
fn uncheckedSection(entries: []const Entry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    try bytes.appendSlice(std.testing.allocator, &lengthBytes(entries.len));
    for (entries) |entry| {
        for ([_][]const u8{ entry.name, entry.value }) |field| {
            try bytes.appendSlice(std.testing.allocator, &lengthBytes(field.len));
            try bytes.appendSlice(std.testing.allocator, field);
        }
    }
    return bytes.toOwnedSlice(std.testing.allocator);
}

fn lengthBytes(len: usize) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast(len), .little);
    return bytes;
}

/// One runtime under test, started with the route table of `routes`, which
/// it borrows.
const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    now_mono_ns: u64,
    completion: rt.CompletionFixture,
    runtime: worker.Runtime,
    table: []u8,

    /// Initializes in place: the runtime keeps pointers to the clock, the
    /// completion view and the table.
    fn init(self: *Fixture, routes: []const RouteSpec) !void {
        var specifiers: [route_table.routes_max][]u8 = undefined;
        var inputs: [route_table.routes_max]route_table.RouteInput = undefined;
        var built: usize = 0;
        defer for (specifiers[0..built]) |specifier| std.testing.allocator.free(specifier);
        for (routes, 0..) |route, index| {
            specifiers[index] = try rt.routeSpecifier(std.testing.allocator, route.path);
            built += 1;
            inputs[index] = .{ .entry_specifier = specifiers[index], .bindings = route.bindings };
        }
        self.table = try sealedTable(inputs[0..routes.len]);
        errdefer std.testing.allocator.free(self.table);
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
            .route_table = self.table,
        });
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
    }

    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        for (self.control_pair) |fd| std.posix.close(fd);
        self.vm.deinit();
        std.testing.allocator.free(self.table);
        self.* = undefined;
    }

    /// Runs one request on the table's route at `path`, with `source` as
    /// that route's entry, and returns the response body.
    fn run(self: *Fixture, source: []const u8, request_id: u64, path: []const u8) ![]u8 {
        return runRouteAndReadBody(&self.runtime, self.control_pair[1], source, request_id, path);
    }
};

test "handler receives the route's text bindings as a frozen env object" {
    const route = "/__test_route/env-bindings.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ .path = route, .bindings = &.{
        .{ .name = "SECRET", .value = "s3cr3t" },
        .{ .name = "GREETING", .value = "olá" },
        .{ .name = "EMPTY", .value = "" },
    } }});
    defer fixture.deinit();

    // Module code is strict, so writing to a frozen object throws.
    const body = try fixture.run(
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
    , 1, route);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"keys\":[\"SECRET\",\"GREETING\",\"EMPTY\"],\"secret\":\"s3cr3t\",\"greeting\":\"olá\",\"empty\":\"\"," ++
            "\"frozen\":true,\"ordinary\":true,\"writeThrew\":true}",
        body,
    );
}

test "every request of a route receives the same env object" {
    const route = "/__test_route/env-identity.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ .path = route, .bindings = &.{.{ .name = "TOKEN", .value = "abc" }} }});
    defer fixture.deinit();

    const source =
        \\let first = null;
        \\export default function handle(request, env) {
        \\    first ??= env;
        \\    return String(first === env && env.TOKEN === "abc");
        \\}
    ;
    for (1..4) |request_id| {
        const body = try fixture.run(source, request_id, route);
        defer std.testing.allocator.free(body);
        try std.testing.expectEqualStrings("true", body);
    }
}

test "each route receives its own bindings and never another route's" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ .path = "/__test_route/env-a.js", .bindings = &.{.{ .name = "SECRET", .value = "secret-a" }} },
        .{ .path = "/__test_route/env-b.js", .bindings = &.{
            .{ .name = "SECRET", .value = "secret-b" },
            .{ .name = "ONLY_B", .value = "b" },
        } },
        .{ .path = "/__test_route/env-none.js" },
    });
    defer fixture.deinit();

    const source =
        \\export default function handle(request, env) {
        \\    return JSON.stringify(env);
        \\}
    ;
    const cases = [_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "/__test_route/env-a.js", .expected = "{\"SECRET\":\"secret-a\"}" },
        .{ .path = "/__test_route/env-b.js", .expected = "{\"SECRET\":\"secret-b\",\"ONLY_B\":\"b\"}" },
        .{ .path = "/__test_route/env-none.js", .expected = "{}" },
    };
    for (cases, 1..) |case, request_id| {
        const body = try fixture.run(source, request_id, case.path);
        defer std.testing.allocator.free(body);
        try std.testing.expectEqualStrings(case.expected, body);
    }
}

test "a route without bindings receives an empty frozen env object" {
    const route = "/__test_route/env-empty.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ .path = route }});
    defer fixture.deinit();

    const body = try fixture.run(
        \\export default function handle(request, env) {
        \\    return String(typeof env === "object" && Object.keys(env).length === 0 && Object.isFrozen(env));
        \\}
    , 1, route);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("true", body);
}

test "a binding named like a prototype property is an own value of env" {
    const route = "/__test_route/env-proto.js";
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ .path = route, .bindings = &.{
        .{ .name = "__proto__", .value = "own" },
        .{ .name = "toString", .value = "shadowed" },
    } }});
    defer fixture.deinit();

    // Defining properties directly bypasses the `__proto__` setter of
    // Object.prototype, so the binding neither vanishes nor swaps the
    // prototype.
    const body = try fixture.run(
        \\export default function handle(request, env) {
        \\    const own = Object.getOwnPropertyDescriptor(env, "__proto__");
        \\    return JSON.stringify({
        \\        proto: own && own.value,
        \\        toString: env.toString,
        \\        ordinary: Object.getPrototypeOf(env) === Object.prototype,
        \\    });
        \\}
    , 1, route);
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

test "runtime start refuses a route table with a malformed bindings section" {
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
        try std.testing.expectError(error.InvalidRouteTable, route_table.buildSealed(std.testing.allocator, &.{.{
            .entry_specifier = "/__collo_route/test/env.js",
            .bindings = entries,
        }}));
        const section = try uncheckedSection(entries);
        defer std.testing.allocator.free(section);
        const table = try uncheckedTable(section);
        defer std.testing.allocator.free(table);
        try expectRuntimeRefuses(table);
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
        const table = try uncheckedTable(section);
        defer std.testing.allocator.free(table);
        try expectRuntimeRefuses(table);
    }
    // And a table that is not one at all.
    try expectRuntimeRefuses(&.{ 1, 0 });
}

fn expectRuntimeRefuses(table: []const u8) !void {
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion = try rt.CompletionFixture.init();
    defer completion.deinit();
    // On failure `Runtime.init` closes the completion eventfd it took over.
    try std.testing.expectError(error.InvalidRouteTable, worker.Runtime.init(
        std.testing.allocator,
        &vm,
        control_pair[0],
        &completion.view,
        try rt.createCompletionEventfd(),
        .{ .ctx = &now_mono_ns, .now_fn = fakeNow, .route_table = table },
    ));
}
