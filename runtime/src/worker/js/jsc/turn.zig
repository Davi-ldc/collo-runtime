//! Runs each worker operation that can execute JavaScript inside a turn: a
//! handler or callback call, a promise settlement, a body parse, a response
//! extraction. In the worker, this file is the only caller
//! of `turnEnter` and `turnExitResult`; the deferred-work pump enters its own
//! turn inside the bridge. Runs in the worker on the VM thread.
//!
//! Each call enters a turn on the caller's `ExecCtx`, runs one operation and
//! exits; once the enter succeeds, exactly one exit follows on every path. A
//! nested enter must pass the context installed at that moment
//! (`entered_count` in `state.h`), which inside a restored microtask is the
//! continuation's owner. Only the outermost exit drains microtasks, so promise
//! reactions run after the operation, inside the same turn, and the owner
//! dispatcher in `vm.cpp` restores each reaction, where it can, to the owner
//! that registered it, whose window the worker opens for it
//! (`worker/runtime/owner.zig`). A turn reads no clock; the caller's owner
//! window covers it. When the drain throws, its exception takes the place of
//! the operation's result, which is released here, unless the operation
//! failed with a Zig error, which wins after the exception is logged
//! (`turnOutcome`). An exception
//! this file does not return to its caller is logged with the request id
//! through `exception_log.zig` and becomes `error.JsException`.

const bindings = @import("collo_bindings");
const std = @import("std");
const exception_log = @import("exception_log.zig");
const promise_deferred = @import("deferred.zig");

/// Calls `callable` with `this_value` and `args`, all borrowed, in a turn on
/// `exec_ctx`; `realm` is the realm of the code the call belongs to, which
/// serves only a callable that has none of its own (`Realm.invoke`), and
/// `allocator` holds the argument array when it outgrows the bridge's stack
/// buffer. Returns the call's value or exception, owned by the caller, where
/// an exception the drain threw takes the place of the call's result. Fails
/// with the enter, call or exit error.
pub fn invoke(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    allocator: std.mem.Allocator,
    exec_ctx: *bindings.ExecCtx,
    callable: *const bindings.Value,
    this_value: ?*const bindings.Value,
    args: []const *const bindings.Value,
) !bindings.ValueResult {
    return invokeWithTiming(vm, realm, allocator, exec_ctx, callable, this_value, args, null);
}

/// `invoke` with the benchmark marker. When `out_call_started_ns` is not null
/// it receives the CLOCK_MONOTONIC time at which the handler called
/// `__colloBenchHandlerEntered`, or zero when it never did or the clock
/// failed. The marker exists only during the synchronous call, so a reference
/// the handler keeps and calls from a microtask at turn exit records nothing.
pub fn invokeWithTiming(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    allocator: std.mem.Allocator,
    exec_ctx: *bindings.ExecCtx,
    callable: *const bindings.Value,
    this_value: ?*const bindings.Value,
    args: []const *const bindings.Value,
    out_call_started_ns: ?*u64,
) !bindings.ValueResult {
    if (out_call_started_ns) |out| out.* = 0;
    try vm.turnEnter(exec_ctx);
    const invoke_result = realm.invokeWithTiming(
        allocator,
        exec_ctx,
        callable,
        this_value,
        args,
        out_call_started_ns,
    );
    if (try finishTurn(
        bindings.ValueResult,
        vm,
        exec_ctx,
        "invoke",
        invoke_result,
        deinitValueResult,
    )) |exception| return .{ .exception = exception };
    return try invoke_result;
}

/// Runs `invoke` and releases the value it returns. An exception, whether the
/// call or the drain threw it, is logged and returned as `error.JsException`.
pub fn invokeDiscard(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    allocator: std.mem.Allocator,
    exec_ctx: *bindings.ExecCtx,
    callable: *const bindings.Value,
    this_value: ?*const bindings.Value,
    args: []const *const bindings.Value,
) !void {
    switch (try invoke(vm, realm, allocator, exec_ctx, callable, this_value, args)) {
        .success => |value| {
            var owned = value;
            owned.deinit();
        },
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            exception_log.logException(vm, exec_ctx.request_id, &owned, "worker turn discarded exception");
            return error.JsException;
        },
    }
}

/// Behaves as `invokeDiscard`, under its own log context.
pub fn invokeDiscardPropagatingException(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    allocator: std.mem.Allocator,
    exec_ctx: *bindings.ExecCtx,
    callable: *const bindings.Value,
    this_value: ?*const bindings.Value,
    args: []const *const bindings.Value,
) !void {
    switch (try invoke(vm, realm, allocator, exec_ctx, callable, this_value, args)) {
        .success => |value| {
            var owned = value;
            owned.deinit();
        },
        .exception => |exception| {
            var owned = exception;
            exception_log.logException(vm, exec_ctx.request_id, &owned, "worker turn propagated exception");
            owned.deinit();
            return error.JsException;
        },
    }
}

/// Takes the deferred out of `deferred` and resolves its promise with `value`,
/// borrowed, in a turn. Once taken, the deferred is released on every path;
/// an empty handle fails with `error.InvalidPromiseDeferred` and nothing runs.
/// An exception from the settlement or the drain is logged and returned as
/// `error.JsException`.
pub fn resolvePromise(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    deferred: *promise_deferred.DeferredOwned,
    value: *const bindings.Value,
) !void {
    try settlePromise(vm, exec_ctx, deferred, value, false);
}

/// `resolvePromise`, rejecting the promise with `reason` instead.
pub fn rejectPromise(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    deferred: *promise_deferred.DeferredOwned,
    reason: *const bindings.Value,
) !void {
    try settlePromise(vm, exec_ctx, deferred, reason, true);
}

/// Resolves the deferred with a success value or rejects it with an
/// exception, as `resolvePromise` and `rejectPromise` do, and releases
/// `result` on every path.
pub fn settlePromiseValueResult(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    deferred: *promise_deferred.DeferredOwned,
    result: bindings.ValueResult,
) !void {
    switch (result) {
        .success => |value| {
            var owned = value;
            defer owned.deinit();
            try resolvePromise(vm, exec_ctx, deferred, &owned);
        },
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            try rejectPromise(vm, exec_ctx, deferred, &owned);
        },
    }
}

/// Parses `source` as JSON into `realm` in a turn and returns the value or the
/// parse exception, owned by the caller. When the drain throws, the parse
/// result is released and the drain's exception is logged and returned as
/// `error.JsException`.
pub fn jsonParseUtf8(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    exec_ctx: *bindings.ExecCtx,
    source: []const u8,
) !bindings.ValueResult {
    try vm.turnEnter(exec_ctx);
    const parse_result = realm.jsonParseUtf8(source);
    try finishValueResultTurn(vm, exec_ctx, "request body json parse", parse_result);
    return try parse_result;
}

/// Builds a FormData of `realm` from the body bytes `source` of type
/// `content_type`, in a turn, with the results and failures of
/// `jsonParseUtf8`.
pub fn formDataFromBytes(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    exec_ctx: *bindings.ExecCtx,
    source: []const u8,
    content_type: []const u8,
) !bindings.ValueResult {
    try vm.turnEnter(exec_ctx);
    const parse_result = realm.formDataValueFromBytes(source, content_type);
    try finishValueResultTurn(vm, exec_ctx, "request body formData parse", parse_result);
    return try parse_result;
}

/// Converts the Response `value` into a native response within `limits`, in
/// a turn, with the results and failures of `jsonParseUtf8`. `realm` serves
/// only a value with no realm of its own, a primitive.
pub fn extractResponse(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    exec_ctx: *bindings.ExecCtx,
    value: *const bindings.Value,
    limits: bindings.ResponseExtractLimits,
) !bindings.ExtractResponseResult {
    try vm.turnEnter(exec_ctx);
    const extract_result = realm.extractResponse(value, limits);
    try finishExtractResponseTurn(vm, exec_ctx, "response extraction", extract_result);
    return try extract_result;
}

/// Reports whether `value` has a callable `then`. Reading `then` can run a
/// getter, hence the turn; an exception from it or from the drain is logged
/// and returned as `error.JsException`. `realm` serves only a value with no
/// realm of its own, a primitive.
pub fn isThenable(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    exec_ctx: *bindings.ExecCtx,
    value: *const bindings.Value,
) !bool {
    try vm.turnEnter(exec_ctx);
    const check_result = realm.isThenable(value);
    if (try finishTurn(bindings.BoolResult, vm, exec_ctx, "thenable check", check_result, deinitBoolResult)) |exception|
        return failTurnException(vm, exec_ctx, "thenable check", exception);

    switch (try check_result) {
        .success => |is_thenable| return is_thenable,
        .exception => |exception| {
            var owned = exception;
            exception_log.logException(vm, exec_ctx.request_id, &owned, "thenable check");
            owned.deinit();
            return error.JsException;
        },
    }
}

/// Completes the request task named by `token` when `value` settles: in a
/// turn, `value` goes through `Promise.resolve` and the task's settlers are
/// attached to the result. An exception from that or from the drain is
/// logged and returned as `error.JsException`. `realm` serves only a value
/// with no realm of its own, a primitive.
pub fn settleRequestThenable(
    vm: *bindings.Vm,
    realm: bindings.Realm,
    exec_ctx: *bindings.ExecCtx,
    token: bindings.RequestCompletionToken,
    value: *const bindings.Value,
) !void {
    try vm.turnEnter(exec_ctx);
    const settle_result = realm.requestTaskSettleThenable(token, value);
    try finishNativeTurn(vm, exec_ctx, "request thenable settlement", settle_result);
}

/// Starts one read of `stream`, the request's locked response body, in a
/// turn on `exec_ctx`: the stream's pull runs here, and the read's result
/// reaches `collo_runtime_response_body_stream_settled` from a reaction that
/// runs under this owner. An exception from the read or the drain is logged
/// and returned as `error.JsException`.
pub fn readResponseBodyStream(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    stream: bindings.ResponseBodyStream,
) !void {
    try vm.turnEnter(exec_ctx);
    const read_result = stream.read(exec_ctx.request_id);
    try finishNativeTurn(vm, exec_ctx, "response body stream read", read_result);
}

/// Cancels `stream` with `reason` in a turn on `exec_ctx`, which runs the
/// stream's cancel algorithm. Fails as `readResponseBodyStream`.
pub fn cancelResponseBodyStream(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    stream: bindings.ResponseBodyStream,
    reason: bindings.ResponseBodyStreamCancel,
) !void {
    try vm.turnEnter(exec_ctx);
    const cancel_result = stream.cancel(reason);
    try finishNativeTurn(vm, exec_ctx, "response body stream cancel", cancel_result);
}

fn settlePromise(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    deferred: *promise_deferred.DeferredOwned,
    value: *const bindings.Value,
    is_rejection: bool,
) !void {
    const raw_deferred = try deferred.take();
    defer bindings.releasePromiseDeferred(raw_deferred);

    try vm.turnEnter(exec_ctx);
    const settle_result = if (is_rejection)
        vm.promiseDeferredReject(raw_deferred, value)
    else
        vm.promiseDeferredResolve(raw_deferred, value);
    try finishNativeTurn(vm, exec_ctx, if (is_rejection) "promise rejection" else "promise resolution", settle_result);
}

/// Exits the turn after an operation that returns nothing but can throw, and
/// fails with the first of: the exit error, the drain's exception, the
/// operation's error, the operation's exception. Each exception is logged
/// under `context` and returned as `error.JsException`.
fn finishNativeTurn(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    context: []const u8,
    operation_result: bindings.Error!bindings.VoidResult,
) !void {
    if (try finishTurn(bindings.VoidResult, vm, exec_ctx, context, operation_result, deinitVoidResult)) |exception| {
        return failTurnException(vm, exec_ctx, context, exception);
    }

    switch (try operation_result) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            exception_log.logException(vm, exec_ctx.request_id, &owned, context);
            owned.deinit();
            return error.JsException;
        },
    }
}

/// Exits the turn after an operation whose result goes back to the caller.
/// When the exit fails or the drain throws, it disposes of the operation's
/// result as `finishTurn` does and fails with the exit error or, after
/// logging the drain's exception, with `error.JsException`. Otherwise the
/// caller still owns that result.
fn finishValueResultTurn(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    context: []const u8,
    operation_result: bindings.Error!bindings.ValueResult,
) !void {
    if (try finishTurn(bindings.ValueResult, vm, exec_ctx, context, operation_result, deinitValueResult)) |exception| {
        return failTurnException(vm, exec_ctx, context, exception);
    }
}

/// `finishValueResultTurn` for a response extraction.
fn finishExtractResponseTurn(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    context: []const u8,
    operation_result: bindings.Error!bindings.ExtractResponseResult,
) !void {
    if (try finishTurn(
        bindings.ExtractResponseResult,
        vm,
        exec_ctx,
        context,
        operation_result,
        deinitExtractResponseResult,
    )) |exception| {
        return failTurnException(vm, exec_ctx, context, exception);
    }
}

/// Exits the caller's turn and applies `turnOutcome`. Returns null when the
/// drain ran clean, or threw after the operation failed with a Zig error
/// (the exception is then logged), leaving `operation_result` to the caller.
/// When the drain threw after a successful operation, it releases the
/// operation's result and returns the drain's exception, owned by the
/// caller. When the exit failed, it disposes of `operation_result` through
/// `deinitOrLogOperation` and fails with the exit error.
fn finishTurn(
    comptime Result: type,
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    context: []const u8,
    operation_result: anyerror!Result,
    comptime deinitResult: fn (Result) void,
) !?bindings.Value {
    const operation_failed = if (operation_result) |_| false else |_| true;
    const exit_result = vm.turnExitResult() catch |exit_err| {
        std.debug.assert(turnOutcome(true, operation_failed, false) == .exit_error);
        deinitOrLogOperation(Result, context, operation_result, deinitResult, exit_err);
        return exit_err;
    };
    switch (exit_result) {
        .success => return null,
        .exception => |exception| switch (turnOutcome(false, operation_failed, true)) {
            .operation_error => {
                // The drain's exception is the tenant's, so it goes to the
                // tenant's log; the operation's error reaches the caller,
                // whose boundary decides what it means.
                var owned = exception;
                exception_log.logException(vm, exec_ctx.request_id, &owned, context);
                owned.deinit();
                return null;
            },
            .drain_exception => {
                if (operation_result) |result| deinitResult(result) else |_| unreachable;
                return exception;
            },
            .exit_error, .operation => unreachable,
        },
    }
}

/// What a turn's caller gets, from the three ways a turn can end badly.
pub const TurnOutcome = enum {
    /// The turn's exit failed, so the VM's turn state is broken.
    exit_error,
    /// The operation failed with a Zig error, out of memory among them.
    operation_error,
    /// The drain after the operation threw.
    drain_exception,
    /// The operation's own result, success or exception.
    operation,
};

/// The precedence of a turn's outcomes. The exit error comes first: nothing
/// after it can be trusted. The operation's Zig error comes before the
/// drain's exception, since replacing it would turn an out-of-memory, which
/// the request's boundary must decide on (conventions.md, "Errors and
/// assertions"), into an exception of the tenant's code; the drain's
/// exception is still logged to the tenant (`finishTurn`). Then the drain's
/// exception, which replaces a successful result.
pub fn turnOutcome(exit_failed: bool, operation_failed: bool, drain_threw: bool) TurnOutcome {
    if (exit_failed)
        return .exit_error;
    if (operation_failed)
        return .operation_error;
    if (drain_threw)
        return .drain_exception;
    return .operation;
}

/// Logs and releases `exception`, returning `error.JsException` for the
/// caller to return.
fn failTurnException(
    vm: *bindings.Vm,
    exec_ctx: *bindings.ExecCtx,
    context: []const u8,
    exception: bindings.Value,
) anyerror {
    var owned = exception;
    exception_log.logException(vm, exec_ctx.request_id, &owned, context);
    owned.deinit();
    return error.JsException;
}

/// Releases a successful operation result after the turn's exit failed. An
/// operation error is logged with `std.log.err` instead, because the exit
/// error takes its place and the caller never sees it.
fn deinitOrLogOperation(
    comptime Result: type,
    context: []const u8,
    operation_result: anyerror!Result,
    comptime deinitResult: fn (Result) void,
    exit_err: anyerror,
) void {
    if (operation_result) |result| {
        deinitResult(result);
    } else |operation_err| {
        std.log.err(
            "worker native turn failed before turnExit failure: context={s} operation={s} turnExit={s}",
            .{ context, @errorName(operation_err), @errorName(exit_err) },
        );
    }
}

fn deinitVoidResult(result: bindings.VoidResult) void {
    switch (result) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
        },
    }
}

fn deinitBoolResult(result: bindings.BoolResult) void {
    switch (result) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
        },
    }
}

fn deinitValueResult(result: bindings.ValueResult) void {
    var owned = switch (result) {
        .success => |value| value,
        .exception => |exception| exception,
    };
    owned.deinit();
}

fn deinitExtractResponseResult(result: bindings.ExtractResponseResult) void {
    switch (result) {
        .success => |response| {
            var owned = response;
            owned.deinit();
        },
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
        },
    }
}
