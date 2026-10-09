//! The `collo_runtime_complete_request_task` export. The bridge calls it
//! from the reaction it registers on a handler's thenable
//! (`collo_request_task_settle_thenable` in
//! `bindings/jsc/runtime/promise.cpp`), on the worker's VM thread during a
//! microtask drain, and `request/completion.zig` checks the token and parks
//! the value. As abi.h requires, the export takes the value on every call.

const bindings = @import("collo_bindings");
const host_adapter = @import("adapter.zig");
const request_task = @import("collo_worker_request").task;

// The `ColloStatus` values of abi.h.
const status_ok: c_int = 0;
const status_error: c_int = 1;
const status_invalid_argument: c_int = 2;

pub export fn collo_runtime_complete_request_task(
    runtime_ptr: ?*anyopaque,
    slot: u32,
    generation: u32,
    request_id: u64,
    request_generation: u64,
    value_raw: ?*bindings.RawValue,
    is_error: u8,
) c_int {
    var value = if (value_raw) |raw| bindings.Value.fromRawOwnedNonNull(raw) else null;
    var owns_value = true;
    defer if (owns_value) {
        if (value) |*owned|
            owned.deinit();
    };

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (value == null)
        return status_invalid_argument;

    // `scheduleRequestTaskCompletion` takes the value on every path, a stale
    // task and a failed insert included.
    owns_value = false;
    runtime.scheduleRequestTaskCompletion(
        request_task.TaskToken{ .slot = slot, .generation = generation },
        request_id,
        request_generation,
        value.?,
        is_error != 0,
    ) catch {
        return status_error;
    };
    return status_ok;
}
