//! Realms (`ColloRealm` in `bindings/jsc/runtime/state.h`): a realm the VM
//! adds has globals, intrinsics, a module registry, console labels and a
//! performance timeline of its own and every install the VM made; an object
//! the ABI creates belongs to the realm it was created in, and an error it
//! raises for a primitive to the realm that asked; a reseed
//! gives every realm a Math.random sequence of its own; and globals past the
//! subspace's precise cells keep their own state across a full collection.
//! The worker serving its routes from their realms is covered by
//! `worker/tests/runtime/routes.zig` and by local-e2e.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const probe_specifier = "/realm-probe.js";
const probe_source =
    \\globalThis.evaluations = (globalThis.evaluations ?? 0) + 1;
    \\export const evaluations = String(globalThis.evaluations);
    \\export function setMarker(value) { globalThis.marker = value; return value; }
    \\export function readMarker() { return String(globalThis.marker); }
    \\export function ownsObject(value) { return String(value instanceof Object); }
    \\export function ownsArray(value) { return String(value instanceof Array); }
    \\export function ownsTypeError(value) { return String(value instanceof TypeError); }
    \\export function ownsRequest(value) { return String(value instanceof Request); }
    \\export function ownsArrayBuffer(value) { return String(value instanceof ArrayBuffer); }
    \\export function ownsUint8Array(value) { return String(value instanceof Uint8Array); }
    \\export function ownsBlob(value) { return String(value instanceof Blob); }
    \\export function ownsFormData(value) { return String(value instanceof FormData); }
    \\export function isOwnGlobal(value) { return String(value === globalThis); }
    \\export function describe() {
    \\    return [typeof Request, typeof process, typeof globalThis.__collo_node_fs, navigator.hardwareConcurrency].join("|");
    \\}
    \\export function random() { return String(Math.random()); }
    \\export function symbol() { return Symbol("probe"); }
    \\export function consoleProbe() {
    \\    console.count("hits");
    \\    console.time("t");
    \\    console.group();
    \\    return "done";
    \\}
    \\export function performanceProbe(name) {
    \\    performance.mark(name);
    \\    const own = performance;
    \\    delete globalThis.performance;
    \\    const mark = new PerformanceMark(name);
    \\    new PerformanceObserver(() => {});
    \\    return [typeof globalThis.performance, mark.name, own.getEntriesByName(name).length].join("|");
    \\}
;

/// The request id every probe call runs under unless a test names one.
const default_request_id: u64 = 77;

/// Calls the probe's export `name` of `realm` with `args` in a turn owned by
/// `request_id` and returns the result, which the caller owns.
fn callAs(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    request_id: u64,
    name: []const u8,
    args: []const *const bindings.Value,
) !bindings.Value {
    var function = try support.getExportInRealmOk(realm, probe_specifier, name);
    defer function.deinit();
    var exec_ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};
    return support.invokeOk(vm, &exec_ctx, &function, args);
}

fn call(vm: *bindings.Vm, realm: bindings.Realm, name: []const u8, args: []const *const bindings.Value) !bindings.Value {
    return callAs(vm, realm, default_request_id, name, args);
}

fn expectCallAs(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    request_id: u64,
    name: []const u8,
    args: []const *const bindings.Value,
    expected: []const u8,
) !void {
    var result = try callAs(vm, realm, request_id, name, args);
    defer result.deinit();
    try support.expectValueString(vm, &result, expected);
}

fn expectCall(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    name: []const u8,
    args: []const *const bindings.Value,
    expected: []const u8,
) !void {
    return expectCallAs(vm, realm, default_request_id, name, args, expected);
}

/// The probe's export `name` in each realm, which must answer `true` in the
/// realm `value` belongs to and `false` in the other.
fn expectOwnedBy(
    vm: *bindings.Vm,
    owner: bindings.Realm,
    other: bindings.Realm,
    name: []const u8,
    value: *const bindings.Value,
) !void {
    try expectCall(vm, owner, name, &.{value}, "true");
    try expectCall(vm, other, name, &.{value}, "false");
}

fn takeSuccess(result: bindings.ValueResult) !bindings.Value {
    return switch (result) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            return error.UnexpectedJsException;
        },
    };
}

fn probeVm() !bindings.Vm {
    var vm = try support.createVm();
    errdefer vm.deinit();
    try support.registerModule(&vm, probe_specifier, probe_source);
    return vm;
}

test "a realm the VM adds has globals, intrinsics and a module registry of its own" {
    var vm = try probeVm();
    defer vm.deinit();
    const main = vm.mainRealm();
    const second = try vm.createRealm();
    try std.testing.expectEqual(@as(u32, 0), main.index());
    try std.testing.expectEqual(@as(u32, 1), second.index());

    // The second evaluation in the main realm reuses its namespace; the
    // second realm evaluates the module again, into globals of its own.
    try support.evaluateInRealmOk(main, probe_specifier);
    try support.evaluateInRealmOk(main, probe_specifier);
    try support.evaluateInRealmOk(second, probe_specifier);
    for ([_]bindings.Realm{ main, second }) |realm| {
        var evaluations = try support.getExportInRealmOk(realm, probe_specifier, "evaluations");
        defer evaluations.deinit();
        try support.expectValueString(&vm, &evaluations, "1");
    }

    var marker = try vm.stringValueUtf8("main-only");
    defer marker.deinit();
    try expectCall(&vm, main, "setMarker", &.{&marker}, "main-only");
    try expectCall(&vm, main, "readMarker", &.{}, "main-only");
    try expectCall(&vm, second, "readMarker", &.{}, "undefined");

    var object = try main.objectValue();
    defer object.deinit();
    try expectOwnedBy(&vm, main, second, "ownsObject", &object);
}

/// JSC gives a subspace's first `JSCell::numberOfLowerTierPreciseCells` (8)
/// cells precise allocations sized from the request; later ones share
/// MarkedBlocks laid out for the subspace's cell size. Ten globals reach two
/// block-allocated ones, where a global sized for `JSGlobalObject` would
/// overlap its neighbour.
const globals_past_precise_cells = 10;

test "realm globals keep their own state across allocation blocks and full collection" {
    var vm = try probeVm();
    defer vm.deinit();
    var realms: [globals_past_precise_cells]bindings.Realm = undefined;
    realms[0] = vm.mainRealm();
    for (realms[1..]) |*realm|
        realm.* = try vm.createRealm();
    for (realms, 0..) |realm, index| {
        try support.evaluateInRealmOk(realm, probe_specifier);
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "realm-{d}", .{index});
        var marker = try vm.stringValueUtf8(text);
        defer marker.deinit();
        try expectCall(&vm, realm, "setMarker", &.{&marker}, text);
    }
    try vm.collectFullGCAndTrim();
    for (realms, 0..) |realm, index| {
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "realm-{d}", .{index});
        try expectCall(&vm, realm, "readMarker", &.{}, text);
    }
}

test "the ABI creates every object in the realm it is given" {
    var vm = try probeVm();
    defer vm.deinit();
    const main = vm.mainRealm();
    const second = try vm.createRealm();
    try support.evaluateInRealmOk(main, probe_specifier);
    try support.evaluateInRealmOk(second, probe_specifier);

    var object = try second.objectValue();
    defer object.deinit();
    try expectOwnedBy(&vm, second, main, "ownsObject", &object);

    var array = try second.arrayValue();
    defer array.deinit();
    try expectOwnedBy(&vm, second, main, "ownsArray", &array);

    var global_this = try second.globalThisValue();
    defer global_this.deinit();
    try expectOwnedBy(&vm, second, main, "isOwnGlobal", &global_this);

    var env = try second.envObjectValue(&.{.{
        .name = .{ .ptr = "NAME", .len = 4 },
        .value = .{ .ptr = "value", .len = 5 },
    }});
    defer env.deinit();
    try expectOwnedBy(&vm, second, main, "ownsObject", &env);

    var type_error = try second.typeErrorValueUtf8("refused");
    defer type_error.deinit();
    try expectOwnedBy(&vm, second, main, "ownsTypeError", &type_error);

    var parsed = try takeSuccess(try second.jsonParseUtf8("{\"a\":1}"));
    defer parsed.deinit();
    try expectOwnedBy(&vm, second, main, "ownsObject", &parsed);

    var array_buffer = try takeSuccess(try second.arrayBufferValueCopy("bytes"));
    defer array_buffer.deinit();
    try expectOwnedBy(&vm, second, main, "ownsArrayBuffer", &array_buffer);

    var bytes = try takeSuccess(try second.uint8ArrayValueCopy("bytes"));
    defer bytes.deinit();
    try expectOwnedBy(&vm, second, main, "ownsUint8Array", &bytes);

    var blob = try takeSuccess(try second.blobValueCopy("bytes", "text/plain"));
    defer blob.deinit();
    try expectOwnedBy(&vm, second, main, "ownsBlob", &blob);

    var form_data = try takeSuccess(try second.formDataValueFromBytes("a=1", "application/x-www-form-urlencoded"));
    defer form_data.deinit();
    try expectOwnedBy(&vm, second, main, "ownsFormData", &form_data);

    const init = bindings.RequestInit{
        .method = .{ .ptr = "GET", .len = 3 },
        .path = .{ .ptr = "/", .len = 1 },
        .raw_query = .{ .ptr = null, .len = 0 },
        .authority = .{ .ptr = "realm.test", .len = 10 },
        .headers = null,
        .headers_len = 0,
        .params = null,
        .params_len = 0,
        .identity = .{ .request_id = 31, .request_generation = 1 },
    };
    var request = try takeSuccess(try second.requestValue(&init));
    defer request.deinit();
    try expectOwnedBy(&vm, second, main, "ownsRequest", &request);
}

/// The exception an operation raised, which the caller owns. Any other
/// outcome is released and fails.
fn takeException(result: anytype) !bindings.Value {
    return switch (result) {
        .exception => |exception| exception,
        inline else => |value| {
            var owned = value;
            owned.deinit();
            return error.ExpectedJsException;
        },
    };
}

test "an error raised for a primitive belongs to the realm that asked, not the main realm" {
    var vm = try probeVm();
    defer vm.deinit();
    const main = vm.mainRealm();
    const second = try vm.createRealm();
    for ([_]bindings.Realm{ main, second }) |realm|
        try support.evaluateInRealmOk(realm, probe_specifier);

    var number = try vm.numberValue(7);
    defer number.deinit();
    var symbol = try call(&vm, second, "symbol", &.{});
    defer symbol.deinit();

    // A handler of the second realm that returns a Symbol: the string
    // conversion of its result throws.
    var exec_ctx = support.makeExecCtx(default_request_id);
    try vm.turnEnter(&exec_ctx);
    const extract_limits = bindings.ResponseExtractLimits{
        .max_body_bytes = 1024,
        .max_header_count = 16,
        .max_header_bytes = 1024,
    };
    const extract_result = second.extractResponse(&symbol, extract_limits);
    const invoke_result = second.invoke(std.testing.allocator, &exec_ctx, &number, null, &.{});
    try vm.turnExit();

    var extract_error = try takeException(try extract_result);
    defer extract_error.deinit();
    try expectOwnedBy(&vm, second, main, "ownsTypeError", &extract_error);

    var invoke_error = try takeException(try invoke_result);
    defer invoke_error.deinit();
    try expectOwnedBy(&vm, second, main, "ownsTypeError", &invoke_error);

    var await_error = try takeException(try second.promiseAwaitSync(&number));
    defer await_error.deinit();
    try expectOwnedBy(&vm, second, main, "ownsTypeError", &await_error);
}

test "a realm gets every install the VM made before or after it, and one hardwareConcurrency" {
    var vm = try probeVm();
    defer vm.deinit();
    const main = vm.mainRealm();
    try vm.installProcess();
    const early = try vm.createRealm();
    try vm.enableNodeFsForWorker();
    const late = try vm.createRealm();

    var expected: ?bindings.OwnedString = null;
    defer if (expected) |*owned| owned.deinit();
    for ([_]bindings.Realm{ main, early, late }) |realm| {
        try support.evaluateInRealmOk(realm, probe_specifier);
        var description = try call(&vm, realm, "describe", &.{});
        defer description.deinit();
        var text = try support.valueString(realm, &description);
        try std.testing.expect(std.mem.startsWith(u8, text.slice(), "function|object|object|"));
        if (expected) |*first| {
            defer text.deinit();
            try std.testing.expectEqualStrings(first.slice(), text.slice());
        } else expected = text;
    }
}

/// The first Math.random() result of the main realm and of one added realm,
/// in a VM reseeded with `seeds` as a forked worker's boot reseeds it. The
/// added realm comes before the reseed when `realm_before_reseed` is set.
fn sampleRealmRandoms(seeds: bindings.RandomSeeds, realm_before_reseed: bool) ![2]bindings.OwnedString {
    var vm = try probeVm();
    defer vm.deinit();
    try vm.postForkChild();
    var added: ?bindings.Realm = null;
    if (realm_before_reseed)
        added = try vm.createRealm();
    try vm.reseedAfterFork(seeds);
    if (added == null)
        added = try vm.createRealm();

    var samples: [2]bindings.OwnedString = undefined;
    var filled: usize = 0;
    errdefer for (samples[0..filled]) |*sample| sample.deinit();
    for ([_]bindings.Realm{ vm.mainRealm(), added.? }) |realm| {
        try support.evaluateInRealmOk(realm, probe_specifier);
        var value = try call(&vm, realm, "random", &.{});
        defer value.deinit();
        samples[filled] = try support.valueString(realm, &value);
        filled += 1;
    }
    return samples;
}

test "a reseed gives every realm a sequence of its own, fixed by the seed and the realm's index" {
    const seeds = bindings.RandomSeeds{ .weak_random_seed = 1234, .vm_random_seed = 5, .heap_random_seed = 6 };
    var before = try sampleRealmRandoms(seeds, true);
    defer for (&before) |*sample| sample.deinit();
    var after = try sampleRealmRandoms(seeds, false);
    defer for (&after) |*sample| sample.deinit();

    try std.testing.expect(!std.mem.eql(u8, before[0].slice(), before[1].slice()));
    // A realm reseeded after its creation and one created after the reseed
    // draw the same sequence: both derive it from the seed and index 1.
    try std.testing.expectEqualStrings(before[0].slice(), after[0].slice());
    try std.testing.expectEqualStrings(before[1].slice(), after[1].slice());
    // The main realm takes the seed as it is, as a single-realm worker did.
    var single = try support.sampleRandomWithSeeds(seeds);
    defer single.deinit();
    try std.testing.expectEqualStrings(single.slice(), before[0].slice());
}

/// Keeps the text of the first `max_lines` console lines.
const LineCapture = struct {
    const max_lines = 8;
    texts: [max_lines][64]u8 = undefined,
    lens: [max_lines]usize = undefined,
    count: usize = 0,

    fn sink(
        ctx: ?*anyopaque,
        level: u8,
        flags: u8,
        request_id: u64,
        bytes: ?[*]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = level;
        _ = flags;
        _ = request_id;
        const self: *LineCapture = @ptrCast(@alignCast(ctx orelse return));
        if (self.count == max_lines) return;
        const kept = @min(len, self.texts[self.count].len);
        if (bytes) |ptr|
            @memcpy(self.texts[self.count][0..kept], ptr[0..kept]);
        self.lens[self.count] = kept;
        self.count += 1;
    }

    fn lines(self: *const LineCapture, out: *[max_lines][]const u8) []const []const u8 {
        for (0..self.count) |index|
            out[index] = self.texts[index][0..self.lens[index]];
        return out[0..self.count];
    }
};

test "each realm keeps its own console counts, timers and groups" {
    var vm = try probeVm();
    defer vm.deinit();
    var capture: LineCapture = .{};
    try vm.setConsoleSink(LineCapture.sink, &capture, 4096, 64, 1 << 20);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};
    const main = vm.mainRealm();
    const second = try vm.createRealm();
    for ([_]bindings.Realm{ main, second }) |realm|
        try support.evaluateInRealmOk(realm, probe_specifier);

    // Each call counts "hits", starts timer "t" and opens a group. The second
    // realm's first call finds its own count at zero, its timer name free and
    // no group to indent by; the main realm's second call finds its own.
    try expectCall(&vm, main, "consoleProbe", &.{}, "done");
    try expectCall(&vm, second, "consoleProbe", &.{}, "done");
    try expectCall(&vm, main, "consoleProbe", &.{}, "done");
    var buffer: [LineCapture.max_lines][]const u8 = undefined;
    const lines = capture.lines(&buffer);
    const expected = [_][]const u8{ "hits: 1", "hits: 1", "  hits: 2", "  Timer 't' already exists" };
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, got|
        try std.testing.expectEqualStrings(want, got);
}

test "each realm records into a performance timeline of its own, which outlives its global property" {
    var vm = try probeVm();
    defer vm.deinit();
    const main = vm.mainRealm();
    const second = try vm.createRealm();
    for ([_]bindings.Realm{ main, second }) |realm|
        try support.evaluateInRealmOk(realm, probe_specifier);

    // Each realm finds only its own mark, and its PerformanceMark and
    // PerformanceObserver constructors still reach its timeline once script
    // has deleted `performance`.
    var name = try vm.stringValueUtf8("probe");
    defer name.deinit();
    try expectCall(&vm, main, "performanceProbe", &.{&name}, "undefined|probe|1");
    try expectCall(&vm, second, "performanceProbe", &.{&name}, "undefined|probe|1");
}

test "a realm is added outside a turn only" {
    var vm = try support.createVm();
    defer vm.deinit();
    var exec_ctx = support.makeExecCtx(78);
    try vm.turnEnter(&exec_ctx);
    try std.testing.expectError(error.InvalidArgument, vm.createRealm());
    try vm.turnExit();
}
