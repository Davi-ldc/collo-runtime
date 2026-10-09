//! Covers the handler's second argument: the `env` object a route's bindings
//! blob becomes (`worker/modules/route_env.zig`), its identity across
//! requests, the route it belongs to, the blob validation that runs when the
//! runtime starts, and the entries `collo_env_object_new` refuses on its
//! own. Valid blobs come from the builder the server uses
//! (`route_bindings.buildSealed` in `common/ipc/route_bindings.zig`), so
//! these tests also pin the layout both ends share. The forked path, where
//! WorkerInit delivers the blob, runs in `local-e2e`.

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
const Entry = route_bindings.Entry;

/// The blob `entries` serialize to, read back from the sealed memfd a worker
/// receives with WorkerInit.
fn sealedBlob(entries: []const Entry) ![]u8 {
    const sealed = try route_bindings.buildSealed(std.testing.allocator, entries);
    defer sealed.close();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(sealed.blob_len));
    errdefer std.testing.allocator.free(bytes);
    if (try std.posix.pread(sealed.fd, bytes, 0) != bytes.len)
        return error.ShortBlobRead;
    return bytes;
}

/// `entries` in the blob layout without the builder's checks, for blobs the
/// builder refuses to write.
fn uncheckedBlob(entries: []const Entry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, @intCast(entries.len), .little);
    try bytes.appendSlice(std.testing.allocator, &count);
    for (entries) |entry| {
        for ([_][]const u8{ entry.name, entry.value }) |field| {
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(field.len), .little);
            try bytes.appendSlice(std.testing.allocator, &len);
            try bytes.appendSlice(std.testing.allocator, field);
        }
    }
    return bytes.toOwnedSlice(std.testing.allocator);
}

/// One runtime under test, with the bindings blob it borrows.
const Fixture = struct {
    vm: support.bindings.Vm,
    control_pair: [2]std.posix.fd_t,
    now_mono_ns: u64,
    completion: rt.CompletionFixture,
    runtime: worker.Runtime,
    /// The entry specifier `blob` belongs to, as the harness dispatches the
    /// route named at `init`.
    bindings_route: []u8,

    /// Initializes in place: the runtime keeps pointers to the clock and the
    /// completion view. `blob` belongs to the route the harness dispatches
    /// as `route` and must outlive the fixture.
    fn init(self: *Fixture, blob: []const u8, route: []const u8) !void {
        self.bindings_route = try rt.routeSpecifier(std.testing.allocator, route);
        errdefer std.testing.allocator.free(self.bindings_route);
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
            .route_bindings_blob = blob,
            .route_bindings_route = self.bindings_route,
        });
        errdefer self.runtime.deinit();
        try self.runtime.attachHostRuntime();
    }

    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.completion.deinit();
        for (self.control_pair) |fd| std.posix.close(fd);
        self.vm.deinit();
        std.testing.allocator.free(self.bindings_route);
        self.* = undefined;
    }

    fn run(self: *Fixture, source: []const u8, request_id: u64, specifier: []const u8) ![]u8 {
        return runRouteAndReadBody(&self.runtime, self.control_pair[1], source, request_id, specifier);
    }
};

test "handler receives the route's text bindings as a frozen env object" {
    const blob = try sealedBlob(&.{
        .{ .name = "SECRET", .value = "s3cr3t" },
        .{ .name = "GREETING", .value = "olá" },
        .{ .name = "EMPTY", .value = "" },
    });
    defer std.testing.allocator.free(blob);
    const route = "/__test_route/env-bindings.js";
    var fixture: Fixture = undefined;
    try fixture.init(blob, route);
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
    const blob = try sealedBlob(&.{.{ .name = "TOKEN", .value = "abc" }});
    defer std.testing.allocator.free(blob);
    const route = "/__test_route/env-identity.js";
    var fixture: Fixture = undefined;
    try fixture.init(blob, route);
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

test "a route other than the one the bindings belong to never receives them" {
    const blob = try sealedBlob(&.{.{ .name = "SECRET", .value = "s3cr3t" }});
    defer std.testing.allocator.free(blob);
    var fixture: Fixture = undefined;
    try fixture.init(blob, "/__test_route/env-owner.js");
    defer fixture.deinit();

    // The worker refuses to build `env` for the other route, so its handler
    // never runs and the worker answers the request with its own 500.
    var response = try rt.runRouteAndReadIngressResponse(&fixture.runtime, fixture.control_pair[1],
        \\export default function handle(request, env) {
        \\    return String(env.SECRET);
        \\}
    , 1, "/__test_route/env-other.js");
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 500), response.status);
    try std.testing.expect(!std.mem.containsAtLeast(u8, response.body, 1, "s3cr3t"));
}

test "a route without bindings receives an empty frozen env object" {
    const blob = try sealedBlob(&.{});
    defer std.testing.allocator.free(blob);
    const route = "/__test_route/env-empty.js";
    var fixture: Fixture = undefined;
    try fixture.init(blob, route);
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
    const blob = try sealedBlob(&.{
        .{ .name = "__proto__", .value = "own" },
        .{ .name = "toString", .value = "shadowed" },
    });
    defer std.testing.allocator.free(blob);
    const route = "/__test_route/env-proto.js";
    var fixture: Fixture = undefined;
    try fixture.init(blob, route);
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
    for (refused) |entry|
        try std.testing.expectError(error.InvalidArgument, vm.envObjectValue(&.{entry}));

    // An array index is below 2^32 - 1 (ECMA-262), so this index-like name
    // is an ordinary one.
    var accepted = try vm.envObjectValue(&.{.{ .name = raw("4294967295"), .value = raw("max") }});
    accepted.deinit();
}

fn raw(bytes: []const u8) support.bindings.RawString {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

test "runtime start refuses a malformed bindings blob" {
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
        try std.testing.expectError(error.InvalidRouteBindings, route_bindings.buildSealed(std.testing.allocator, entries));
        const blob = try uncheckedBlob(entries);
        defer std.testing.allocator.free(blob);
        try expectRuntimeRefuses(blob);
    }

    // Layouts the builder never writes: a count with no entry behind it, a
    // name length past the end, a byte after the last entry, a truncated
    // count and no bytes at all.
    const raw_cases = [_][]const u8{
        &.{ 1, 0, 0, 0 },
        &.{ 1, 0, 0, 0, 200, 0, 0, 0, 'A' },
        &.{ 0, 0, 0, 0, 0 },
        &.{ 0, 0 },
        &.{},
    };
    for (raw_cases) |blob|
        try expectRuntimeRefuses(blob);
}

fn expectRuntimeRefuses(blob: []const u8) !void {
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var now_mono_ns: u64 = 0;
    var completion = try rt.CompletionFixture.init();
    defer completion.deinit();
    // On failure `Runtime.init` closes the completion eventfd it took over.
    try std.testing.expectError(error.InvalidRouteBindings, worker.Runtime.init(
        std.testing.allocator,
        &vm,
        control_pair[0],
        &completion.view,
        try rt.createCompletionEventfd(),
        .{ .ctx = &now_mono_ns, .now_fn = fakeNow, .route_bindings_blob = blob },
    ));
}
