//! Calls a timer or immediate callback as a turn of the request that
//! scheduled it, under that request's exec context, on the worker's VM
//! thread. A callback whose request is no longer active is skipped, never
//! run under another identity.

const std = @import("std");
const bindings = @import("collo_bindings");
const js_value = @import("collo_worker_js").value;
const turn = @import("collo_worker_js").turn;

/// `invokeDiscardWithThis` with globalThis as `this`.
pub fn invokeDiscard(
    runtime: anytype,
    request_id: u64,
    callback: *const js_value.JsFunctionOwned,
    args: ?[]js_value.JsValueOwned,
) !void {
    var global_this = try runtime.core.vm.globalThisValue();
    defer global_this.deinit();
    try invokeDiscardWithThis(runtime, request_id, callback, &global_this, args);
}

/// Calls `callback` with `this_value` and `args` in a turn of `request_id`
/// and discards the result; does nothing when the request is no longer
/// active. The callback and the arguments stay the caller's. A thrown
/// exception is logged and returned as `error.JsException`; more arguments
/// than the stack array holds cost one allocation, which can fail with
/// OutOfMemory.
pub fn invokeDiscardWithThis(
    runtime: anytype,
    request_id: u64,
    callback: *const js_value.JsFunctionOwned,
    this_value: ?*const bindings.Value,
    args: ?[]js_value.JsValueOwned,
) !void {
    const request = runtime.requests.active.get(request_id) orelse return;
    var stack_args: [8]*const bindings.Value = undefined;
    var heap_args: ?[]*const bindings.Value = null;
    const argv: []*const bindings.Value = if (args) |owned_args| blk: {
        if (owned_args.len <= stack_args.len)
            break :blk stack_args[0..owned_args.len];
        const allocated = try runtime.core.allocator.alloc(*const bindings.Value, owned_args.len);
        heap_args = allocated;
        break :blk allocated;
    } else stack_args[0..0];
    defer if (heap_args) |allocated| runtime.core.allocator.free(allocated);

    if (args) |owned_args| {
        for (owned_args, 0..) |*arg, index|
            argv[index] = arg.ptr();
    }

    try turn.invokeDiscard(
        runtime.core.vm,
        request.requestAllocator(),
        &request.exec,
        callback.ptr(),
        this_value,
        argv,
    );
}
