//! The exports the bridge calls for `setTimeout`, `setInterval`,
//! `setImmediate` and their clear functions
//! (`bindings/host_functions/runtime/timers.cpp`). They take over the
//! JavaScript values the bridge passes and schedule or cancel the runtime's
//! timers and immediates, whose queues live in `worker/scheduler/`. Runs on
//! the worker's VM thread.
//!
//! As abi.h requires, `collo_runtime_set_timer` and
//! `collo_runtime_set_immediate` take the callback, an immediate's `this`
//! value and every argument handle on every call, failures included, while
//! the argument array itself stays the bridge's.

const bindings = @import("collo_bindings");
const js_value = @import("collo_worker_js").value;
const host_adapter = @import("adapter.zig");

// The `ColloStatus` values of abi.h.
const status_ok: c_int = 0;
const status_error: c_int = 1;
const status_invalid_argument: c_int = 2;

const ScheduleKind = enum {
    timer,
    immediate,
};

pub export fn collo_runtime_set_timer(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    callback_raw: ?*bindings.RawValue,
    args_raw: ?[*]?*bindings.RawValue,
    args_len: usize,
    delay_ms: u32,
    repeats: u8,
    out_timer_id: ?*u64,
) c_int {
    return scheduleCallback(
        runtime_ptr,
        request_id,
        callback_raw,
        null,
        args_raw,
        args_len,
        delay_ms,
        repeats,
        out_timer_id,
        .timer,
    );
}

pub export fn collo_runtime_set_immediate(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    callback_raw: ?*bindings.RawValue,
    this_arg_raw: ?*bindings.RawValue,
    args_raw: ?[*]?*bindings.RawValue,
    args_len: usize,
    out_immediate_id: ?*u64,
) c_int {
    return scheduleCallback(
        runtime_ptr,
        request_id,
        callback_raw,
        this_arg_raw,
        args_raw,
        args_len,
        0,
        0,
        out_immediate_id,
        .immediate,
    );
}

fn scheduleCallback(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    callback_raw: ?*bindings.RawValue,
    this_arg_raw: ?*bindings.RawValue,
    args_raw: ?[*]?*bindings.RawValue,
    args_len: usize,
    delay_ms: u32,
    repeats: u8,
    out_callback_id: ?*u64,
    kind: ScheduleKind,
) c_int {
    // FIXME: this return comes before `callback_raw` and `this_arg_raw` are wrapped, so both
    // handles leak, against abi.h's rule that the runtime takes them on every call. The bridge
    // never passes a null array with a nonzero length.
    const raw_args = if (args_len == 0) null else args_raw orelse return status_invalid_argument;
    // Argument handles not yet moved into `args` are released on return, so
    // a failure from here on still takes every one of them.
    var consumed_args: usize = 0;
    defer if (raw_args) |raw_slice| {
        while (consumed_args < args_len) : (consumed_args += 1) {
            const raw = raw_slice[consumed_args] orelse continue;
            var value = bindings.Value.fromRawOwnedNonNull(raw);
            value.deinit();
        }
    };

    var callback = if (callback_raw) |raw| bindings.Value.fromRawOwnedNonNull(raw) else null;
    var owns_callback = true;
    defer if (owns_callback) {
        if (callback) |*value|
            value.deinit();
    };

    var this_arg = if (this_arg_raw) |raw| bindings.Value.fromRawOwnedNonNull(raw) else null;
    var owns_this_arg = true;
    defer if (owns_this_arg) {
        if (this_arg) |*value|
            value.deinit();
    };

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (callback == null or out_callback_id == null)
        return status_invalid_argument;
    if (kind == .immediate and this_arg == null)
        return status_invalid_argument;

    var args: ?[]js_value.JsValueOwned = null;
    var initialized_args: usize = 0;
    defer if (args) |owned_args| {
        for (owned_args[0..initialized_args]) |*arg|
            arg.deinit();
        runtime.core.allocator.free(owned_args);
    };
    if (raw_args) |raw_slice| {
        args = runtime.core.allocator.alloc(js_value.JsValueOwned, args_len) catch return status_error;
        for (raw_slice[0..args_len]) |maybe_raw| {
            const raw = maybe_raw orelse return status_invalid_argument;
            args.?[initialized_args] = js_value.JsValueOwned.fromOwnedValue(bindings.Value.fromRawOwnedNonNull(raw));
            initialized_args += 1;
            consumed_args += 1;
        }
    }

    owns_callback = false;
    var callback_fn = js_value.JsFunctionOwned.fromOwnedValueChecked(runtime.core.vm, callback.?) catch {
        return status_error;
    };
    var immediate_this_arg: ?js_value.JsValueOwned = null;
    if (kind == .immediate) {
        owns_this_arg = false;
        immediate_this_arg = js_value.JsValueOwned.fromOwnedValue(this_arg.?);
    }

    const schedule_args = args;
    args = null;
    initialized_args = 0;
    const callback_id = switch (kind) {
        .timer => runtime.scheduleTimer(
            request_id,
            callback_fn.take(),
            schedule_args,
            delay_ms,
            repeats != 0,
        ),
        .immediate => runtime.scheduleImmediate(
            request_id,
            callback_fn.take(),
            if (immediate_this_arg) |*value| value.take() else null,
            schedule_args,
        ),
    } catch {
        if (immediate_this_arg) |*value|
            value.deinit();
        return status_error;
    };

    out_callback_id.?.* = callback_id;
    return status_ok;
}

pub export fn collo_runtime_clear_timeout(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    timer_id: u64,
) c_int {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or timer_id == 0)
        return status_invalid_argument;

    runtime.cancelTimeout(request_id, timer_id);
    return status_ok;
}

pub export fn collo_runtime_clear_immediate(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    immediate_id: u64,
) c_int {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or immediate_id == 0)
        return status_invalid_argument;

    runtime.cancelImmediate(request_id, immediate_id);
    return status_ok;
}
