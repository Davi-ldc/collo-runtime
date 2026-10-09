//! Realms (`ColloRealm` in `bindings/jsc/runtime/state.h`): a realm the VM
//! adds has globals, intrinsics, a module registry and console labels of its
//! own and every install the VM made; an object the ABI creates belongs to
//! the realm it was created in; and a reseed gives every realm a Math.random
//! sequence of its own. The worker serving its routes from their realms is
//! covered by `worker/tests/runtime/routes.zig` and by local-e2e.

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
    \\export function consoleProbe() {
    \\    console.count("hits");
    \\    console.time("t");
    \\    console.group();
    \\    return "done";
    \\}
;

/// Calls the probe's export `name` of `realm` with `args` in a turn and
/// returns the result, which the caller owns.
fn call(vm: *bindings.Vm, realm: bindings.Realm, name: []const u8, args: []const *const bindings.Value) !bindings.Value {
    var function = try support.getExportInRealmOk(realm, probe_specifier, name);
    defer function.deinit();
    var exec_ctx = support.makeExecCtx(77);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};
    return support.invokeOk(vm, &exec_ctx, &function, args);
}

fn expectCall(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    name: []const u8,
    args: []const *const bindings.Value,
    expected: []const u8,
) !void {
    var result = try call(vm, realm, name, args);
    defer result.deinit();
    try support.expectValueString(vm, &result, expected);
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
        var text = switch (try vm.valueToUtf8Copy(&description)) {
            .success => |owned| owned,
            .exception => |exception| {
                var owned = exception;
                owned.deinit();
                return error.UnexpectedJsException;
            },
        };
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
        samples[filled] = switch (try vm.valueToUtf8Copy(&value)) {
            .success => |text| text,
            .exception => |exception| {
                var owned = exception;
                owned.deinit();
                return error.UnexpectedJsException;
            },
        };
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

test "a realm is added outside a turn only" {
    var vm = try support.createVm();
    defer vm.deinit();
    var exec_ctx = support.makeExecCtx(78);
    try vm.turnEnter(&exec_ctx);
    try std.testing.expectError(error.InvalidArgument, vm.createRealm());
    try vm.turnExit();
}

test "evicting a specifier drops its namespace from every realm that evaluated it" {
    var vm = try probeVm();
    defer vm.deinit();
    const second = try vm.createRealm();
    try support.evaluateInRealmOk(vm.mainRealm(), probe_specifier);
    try support.evaluateInRealmOk(second, probe_specifier);

    const stats = try vm.evictModuleSpecifier(probe_specifier);
    try std.testing.expectEqual(@as(usize, 1), stats.sources_removed);
    try std.testing.expectEqual(@as(usize, 2), stats.namespaces_removed);
}
