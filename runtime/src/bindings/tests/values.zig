//! Values and exceptions across the ABI. A value's kind names its type as `typeof` does, with
//! null apart and every callable object a function, and reading it runs no proxy trap. An
//! exception thrown by an invoked function comes back as a value `Vm.exceptionFormat` can
//! format; one thrown by a property getter or setter or by a string conversion comes back
//! through `out_exception` with nothing left pending, so the enclosing turn still exits cleanly.
//! An empty string is a valid property key. A TypeError made outside any turn is a TypeError to
//! JavaScript and keeps its message, an empty one included, and a message that is not UTF-8 is
//! refused. Lane: `bindings-test`.

const std = @import("std");
const support = @import("bindings_support");

/// Fails when turn exit reports an exception, which means an earlier call left one pending.
fn expectCleanTurnExit(vm: *support.bindings.Vm) !void {
    switch (try vm.turnExitResult()) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
    }
}

test "a value's kind names its type as typeof does, with null apart and every callable object a function" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export let trapCalls = 0;
        \\const countingTraps = {
        \\    get() { trapCalls += 1; },
        \\    getPrototypeOf() { trapCalls += 1; return null; },
        \\    getOwnPropertyDescriptor() { trapCalls += 1; },
        \\    has() { trapCalls += 1; return false; },
        \\    apply() { trapCalls += 1; },
        \\};
        \\export const undefinedValue = undefined;
        \\export const nullValue = null;
        \\export const booleanValue = false;
        \\export const integerValue = 7;
        \\export const doubleValue = 1.5;
        \\export const smallBigint = 1n;
        \\export const largeBigint = 2n ** 80n;
        \\export const stringValue = "text";
        \\export const symbolValue = Symbol("symbol");
        \\export const objectValue = {};
        \\export const arrayValue = [];
        \\export const arrowValue = () => {};
        \\export const classValue = class {};
        \\export const boundValue = function () {}.bind(null);
        \\export const objectProxy = new Proxy({}, countingTraps);
        \\export const callableProxy = new Proxy(function () {}, countingTraps);
    ;
    try support.registerModule(&vm, "/kinds.js", source);
    try support.evaluateOk(&vm, "/kinds.js");

    const Kind = support.bindings.ValueKind;
    const expected = [_]struct { name: []const u8, kind: Kind }{
        .{ .name = "undefinedValue", .kind = .undefined },
        .{ .name = "nullValue", .kind = .null },
        .{ .name = "booleanValue", .kind = .boolean },
        .{ .name = "integerValue", .kind = .number },
        .{ .name = "doubleValue", .kind = .number },
        .{ .name = "smallBigint", .kind = .bigint },
        .{ .name = "largeBigint", .kind = .bigint },
        .{ .name = "stringValue", .kind = .string },
        .{ .name = "symbolValue", .kind = .symbol },
        .{ .name = "objectValue", .kind = .object },
        .{ .name = "arrayValue", .kind = .object },
        .{ .name = "arrowValue", .kind = .function },
        .{ .name = "classValue", .kind = .function },
        .{ .name = "boundValue", .kind = .function },
        .{ .name = "objectProxy", .kind = .object },
        .{ .name = "callableProxy", .kind = .function },
    };
    for (expected) |entry| {
        var value = try support.getExportOk(&vm, "/kinds.js", entry.name);
        defer value.deinit();
        try std.testing.expectEqual(entry.kind, try vm.valueKind(&value));
        try std.testing.expectEqual(entry.kind == .function, try vm.isCallable(&value));
    }

    var trap_calls = try support.getExportOk(&vm, "/kinds.js", "trapCalls");
    defer trap_calls.deinit();
    try support.expectValueString(&vm, &trap_calls, "0");
}

test "formatted js exception is exposed through root wrapper" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function explode() {
        \\    throw new Error("boom from invoke");
        \\}
    ;

    try support.registerModule(&vm, "/fail.js", source);
    try support.evaluateOk(&vm, "/fail.js");

    var entry = try support.getExportOk(&vm, "/fail.js", "default");
    defer entry.deinit();

    var exec_ctx = support.makeExecCtx(31);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    var exception = try support.invokeException(&vm, &exec_ctx, &entry, &.{});
    defer exception.deinit();

    try support.expectExceptionContains(&vm, &exception, "boom from invoke");
}

test "a TypeError made outside a turn is a TypeError to JavaScript and keeps its message, an empty one included" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export function describe(error) {
        \\    return `${error instanceof TypeError}|${error.message}`;
        \\}
    ;

    try support.registerModule(&vm, "/describe.js", source);
    try support.evaluateOk(&vm, "/describe.js");

    var describe = try support.getExportOk(&vm, "/describe.js", "describe");
    defer describe.deinit();

    var exec_ctx = support.makeExecCtx(54);
    // Two-byte and three-byte sequences, so the message crosses a UTF-8
    // decode into the engine and an encode back out.
    const messages = [_][]const u8{ "fetch failed: r\u{e9}sum\u{e9} \u{2713}", "" };
    inline for (messages) |message| {
        var type_error = try vm.mainRealm().typeErrorValueUtf8(message);
        defer type_error.deinit();

        try vm.turnEnter(&exec_ctx);
        var description = try support.invokeOk(&vm, &exec_ctx, &describe, &.{&type_error});
        defer description.deinit();
        try expectCleanTurnExit(&vm);

        try support.expectValueString(&vm, &description, "true|" ++ message);
    }
}

test "a TypeError message that is not UTF-8 is refused" {
    var vm = try support.createVm();
    defer vm.deinit();

    try std.testing.expectError(error.InvalidArgument, vm.mainRealm().typeErrorValueUtf8("fetch failed: \xff"));
}

test "empty string object property key is valid" {
    var vm = try support.createVm();
    defer vm.deinit();

    var object = try vm.mainRealm().objectValue();
    defer object.deinit();

    var value = try vm.stringValueUtf8("blank-key");
    defer value.deinit();

    switch (try vm.mainRealm().objectSetUtf8(&object, "", &value)) {
        .success => {},
        .exception => |exception| {
            var owned_exception = exception;
            defer owned_exception.deinit();
            return error.UnexpectedException;
        },
    }

    var actual = switch (try vm.mainRealm().objectGetUtf8(&object, "")) {
        .success => |result| result,
        .exception => |exception| {
            var owned_exception = exception;
            defer owned_exception.deinit();
            return error.UnexpectedException;
        },
    };
    defer actual.deinit();

    try support.expectValueString(&vm, &actual, "blank-key");
}

test "object getter exception is cleared before returning over ABI" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\const object = {};
        \\Object.defineProperty(object, "boom", {
        \\    get() {
        \\        throw new Error("getter boom");
        \\    },
        \\});
        \\export default object;
    ;

    try support.registerModule(&vm, "/getter.js", source);
    try support.evaluateOk(&vm, "/getter.js");

    var object = try support.getExportOk(&vm, "/getter.js", "default");
    defer object.deinit();

    var exec_ctx = support.makeExecCtx(51);
    try vm.turnEnter(&exec_ctx);

    var exception = switch (try vm.mainRealm().objectGetUtf8(&object, "boom")) {
        .success => |value| {
            var owned = value;
            defer owned.deinit();
            return error.ExpectedJsException;
        },
        .exception => |value| value,
    };
    defer exception.deinit();
    try support.expectExceptionContains(&vm, &exception, "getter boom");

    try expectCleanTurnExit(&vm);
}

test "object setter exception is cleared before returning over ABI" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\const object = {};
        \\Object.defineProperty(object, "boom", {
        \\    set() {
        \\        throw new Error("setter boom");
        \\    },
        \\});
        \\export default object;
    ;

    try support.registerModule(&vm, "/setter.js", source);
    try support.evaluateOk(&vm, "/setter.js");

    var object = try support.getExportOk(&vm, "/setter.js", "default");
    defer object.deinit();
    var value = try vm.stringValueUtf8("ignored");
    defer value.deinit();

    var exec_ctx = support.makeExecCtx(52);
    try vm.turnEnter(&exec_ctx);

    var exception = switch (try vm.mainRealm().objectSetUtf8(&object, "boom", &value)) {
        .success => return error.ExpectedJsException,
        .exception => |exception_value| exception_value,
    };
    defer exception.deinit();
    try support.expectExceptionContains(&vm, &exception, "setter boom");

    try expectCleanTurnExit(&vm);
}

test "string conversion exception is cleared before returning over ABI" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default {
        \\    toString() {
        \\        throw new Error("string boom");
        \\    },
        \\};
    ;

    try support.registerModule(&vm, "/string-conversion.js", source);
    try support.evaluateOk(&vm, "/string-conversion.js");

    var value = try support.getExportOk(&vm, "/string-conversion.js", "default");
    defer value.deinit();

    var exec_ctx = support.makeExecCtx(53);
    try vm.turnEnter(&exec_ctx);

    var exception = switch (try vm.mainRealm().valueToUtf8Copy(&value)) {
        .success => |text| {
            var owned = text;
            defer owned.deinit();
            return error.ExpectedJsException;
        },
        .exception => |exception_value| exception_value,
    };
    defer exception.deinit();
    try support.expectExceptionContains(&vm, &exception, "string boom");

    try expectCleanTurnExit(&vm);
}
