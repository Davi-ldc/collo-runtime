//! Test helpers over `collo_bindings`, module `bindings_support`: create a VM,
//! register and evaluate single-module packs, call exports, and turn any
//! outcome a test did not expect into a Zig error. Each helper runs on the
//! calling test's thread against a VM that thread owns, and allocates from
//! `std.testing.allocator`; outside test compilations only the WebAPI bench
//! uses it, for `createVm`. The bindings smokes import nothing else, so this
//! module also pulls in the worker exports their binaries link against.

const std = @import("std");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");

pub const bindings = @import("collo_bindings");
/// Re-exported so suites the bindings smokes compile, which import only this
/// module, can build packs.
pub const module_pack = ipc.module_pack;

// Analyzing the worker facade runs its compile-time block, which reaches every
// `collo_runtime_*` export, so the bridge's calls into Zig resolve in binaries
// that import only this module.
comptime {
    _ = worker;
}

pub const TestError = error{
    UnexpectedJsException,
    UnexpectedPendingEvaluation,
};

/// A VM with default options; the caller owns it and calls `deinit`.
pub fn createVm() !bindings.Vm {
    return bindings.Vm.createDefault();
}

pub fn makeExecCtx(request_id: u64) bindings.ExecCtx {
    return bindings.ExecCtx.init(request_id);
}

/// Builds a pack holding one module and registers it on `vm`. Registration
/// copies the pack, so nothing stays borrowed after the call.
pub fn registerModule(vm: *bindings.Vm, specifier: []const u8, source: []const u8) !void {
    const pack = try ipc.module_pack.buildSingleAlloc(std.testing.allocator, specifier, source);
    defer std.testing.allocator.free(pack);
    try vm.registerModulePack(pack);
}

/// Evaluates `specifier` in the VM's main realm, as every helper below does,
/// and it must complete synchronously. A thrown exception, or the one an
/// `.unsupported` result carries, is released and fails with
/// `error.UnexpectedJsException`; a top-level await still in flight fails with
/// `error.UnexpectedPendingEvaluation`.
pub fn evaluateOk(vm: *bindings.Vm, specifier: []const u8) !void {
    try evaluateInRealmOk(vm.mainRealm(), specifier);
}

/// `evaluateOk` in `realm`.
pub fn evaluateInRealmOk(realm: bindings.Realm, specifier: []const u8) !void {
    switch (try realm.evaluateModule(specifier)) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
        .unsupported => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
        .pending => return error.UnexpectedPendingEvaluation,
    }
}

/// Evaluates `specifier` and returns the exception it throws, which the caller
/// owns. Any other outcome is an error.
pub fn evaluateException(vm: *bindings.Vm, specifier: []const u8) !bindings.Value {
    return switch (try vm.mainRealm().evaluateModule(specifier)) {
        .success => error.UnexpectedJsException,
        .exception => |exception| exception,
        .unsupported => error.UnexpectedJsException,
        .pending => error.UnexpectedPendingEvaluation,
    };
}

/// Evaluates `specifier` and returns the exception carried by an `.unsupported`
/// result (`COLLO_STATUS_UNSUPPORTED`), which the caller owns. Any other
/// outcome is an error.
pub fn evaluateUnsupported(vm: *bindings.Vm, specifier: []const u8) !bindings.Value {
    return switch (try vm.mainRealm().evaluateModule(specifier)) {
        .success => error.UnexpectedJsException,
        .exception => error.UnexpectedJsException,
        .unsupported => |exception| exception,
        .pending => error.UnexpectedPendingEvaluation,
    };
}

/// Evaluates `specifier` and expects its top-level await to be still in flight.
pub fn evaluatePending(vm: *bindings.Vm, specifier: []const u8) !void {
    switch (try vm.mainRealm().evaluateModule(specifier)) {
        .success => return error.UnexpectedEvaluationSuccess,
        .exception, .unsupported => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
        .pending => {},
    }
}

/// The export `export_name` of the evaluated module `specifier`, which the
/// caller owns. A thrown exception is released and fails with
/// `error.UnexpectedJsException`.
pub fn getExportOk(vm: *bindings.Vm, specifier: []const u8, export_name: []const u8) !bindings.Value {
    return getExportInRealmOk(vm.mainRealm(), specifier, export_name);
}

/// `getExportOk` in `realm`.
pub fn getExportInRealmOk(realm: bindings.Realm, specifier: []const u8, export_name: []const u8) !bindings.Value {
    return switch (try realm.moduleGetExport(specifier, export_name)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
    };
}

/// Calls `callable` with `args` and no receiver under `exec_ctx` and returns
/// the result, which the caller owns. A thrown exception is released and fails
/// with `error.UnexpectedJsException`.
pub fn invokeOk(vm: *bindings.Vm, exec_ctx: *const bindings.ExecCtx, callable: *const bindings.Value, args: []const *const bindings.Value) !bindings.Value {
    return switch (try vm.invoke(std.testing.allocator, exec_ctx, callable, null, args)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
    };
}

/// Calls `callable` like `invokeOk` and returns the exception it throws, which
/// the caller owns. A normal return releases the result and fails with
/// `error.UnexpectedJsException`.
pub fn invokeException(vm: *bindings.Vm, exec_ctx: *const bindings.ExecCtx, callable: *const bindings.Value, args: []const *const bindings.Value) !bindings.Value {
    return switch (try vm.invoke(std.testing.allocator, exec_ctx, callable, null, args)) {
        .success => |value| {
            var owned = value;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
        .exception => |exception| exception,
    };
}

pub fn expectValueString(vm: *bindings.Vm, value: *const bindings.Value, expected: []const u8) !void {
    switch (try vm.valueToUtf8Copy(value)) {
        .success => |text| {
            var owned = text;
            defer owned.deinit();
            try std.testing.expectEqualStrings(expected, owned.slice());
        },
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
    }
}

pub fn expectExceptionContains(vm: *bindings.Vm, exception: *const bindings.Value, needle: []const u8) !void {
    var formatted = try vm.exceptionFormat(exception);
    defer formatted.deinit();
    try std.testing.expect(std.mem.indexOf(u8, formatted.slice(), needle) != null);
}

/// The first `Math.random()` result, as a string, of a fresh VM prepared with
/// `postForkChild` and `reseedAfterFork(seeds)` as a forked worker's boot
/// prepares it, without forking. The caller owns the string.
pub fn sampleRandomWithSeeds(seeds: bindings.RandomSeeds) !bindings.OwnedString {
    var vm = try createVm();
    defer vm.deinit();

    try vm.postForkChild();
    try vm.reseedAfterFork(seeds);

    const source =
        \\export default function sample() {
        \\    return String(Math.random());
        \\}
    ;

    try registerModule(&vm, "/random.js", source);
    try evaluateOk(&vm, "/random.js");

    var entry = try getExportOk(&vm, "/random.js", "default");
    defer entry.deinit();

    var exec_ctx = makeExecCtx(9000);
    try vm.turnEnter(&exec_ctx);
    defer vm.turnExit() catch {};

    var result = try invokeOk(&vm, &exec_ctx, &entry, &.{});
    defer result.deinit();

    return switch (try vm.valueToUtf8Copy(&result)) {
        .success => |text| text,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.UnexpectedJsException;
        },
    };
}
