//! The `collo_runtime_request_*` exports behind a handler's `Request` body
//! readers (`bindings/host_functions/runtime/request_body.cpp`), each of
//! which hands one read to `request/body_read.zig`. Runs on the worker's VM
//! thread. As abi.h requires, every export takes the read's deferred on
//! every path, failures included; a zero request id is an invalid argument.

const bindings = @import("collo_bindings");
const deferred = @import("collo_worker_js").deferred;
const request_body = @import("collo_worker_request").body_read;
const host_adapter = @import("adapter.zig");

// The `ColloStatus` values of abi.h.
const status_ok: c_int = 0;
const status_error: c_int = 1;
const status_invalid_argument: c_int = 2;

pub export fn collo_runtime_request_text(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    request_generation: u64,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_task_id: ?*u64,
) c_int {
    var deferred_handle = if (deferred_raw) |raw| deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred_handle) |*owned| owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or deferred_handle == null or out_task_id == null)
        return status_invalid_argument;

    const owned_deferred = deferred_handle.?;
    deferred_handle = null;
    const task_id = request_body.scheduleText(runtime, request_id, request_generation, owned_deferred) catch
        return status_error;
    out_task_id.?.* = task_id;
    return status_ok;
}

pub export fn collo_runtime_request_json(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    request_generation: u64,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_task_id: ?*u64,
) c_int {
    var deferred_handle = if (deferred_raw) |raw| deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred_handle) |*owned| owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or deferred_handle == null or out_task_id == null)
        return status_invalid_argument;

    const owned_deferred = deferred_handle.?;
    deferred_handle = null;
    const task_id = request_body.scheduleJson(runtime, request_id, request_generation, owned_deferred) catch
        return status_error;
    out_task_id.?.* = task_id;
    return status_ok;
}

pub export fn collo_runtime_request_array_buffer(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    request_generation: u64,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_task_id: ?*u64,
) c_int {
    var deferred_handle = if (deferred_raw) |raw| deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred_handle) |*owned| owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or deferred_handle == null or out_task_id == null)
        return status_invalid_argument;

    const owned_deferred = deferred_handle.?;
    deferred_handle = null;
    const task_id = request_body.scheduleArrayBuffer(runtime, request_id, request_generation, owned_deferred) catch
        return status_error;
    out_task_id.?.* = task_id;
    return status_ok;
}

pub export fn collo_runtime_request_bytes(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    request_generation: u64,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_task_id: ?*u64,
) c_int {
    var deferred_handle = if (deferred_raw) |raw| deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred_handle) |*owned| owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or deferred_handle == null or out_task_id == null)
        return status_invalid_argument;

    const owned_deferred = deferred_handle.?;
    deferred_handle = null;
    const task_id = request_body.scheduleBytes(runtime, request_id, request_generation, owned_deferred) catch
        return status_error;
    out_task_id.?.* = task_id;
    return status_ok;
}

pub export fn collo_runtime_request_blob(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    request_generation: u64,
    blob_type_raw: bindings.RawString,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_task_id: ?*u64,
) c_int {
    var deferred_handle = if (deferred_raw) |raw| deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred_handle) |*owned| owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or deferred_handle == null or out_task_id == null)
        return status_invalid_argument;

    const owned_deferred = deferred_handle.?;
    deferred_handle = null;
    const task_id = request_body.scheduleBlob(
        runtime,
        request_id,
        request_generation,
        owned_deferred,
        bindings.rawStringSlice(blob_type_raw),
    ) catch return status_error;
    out_task_id.?.* = task_id;
    return status_ok;
}

pub export fn collo_runtime_request_form_data(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    request_generation: u64,
    content_type_raw: bindings.RawString,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_task_id: ?*u64,
) c_int {
    var deferred_handle = if (deferred_raw) |raw| deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred_handle) |*owned| owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (request_id == 0 or deferred_handle == null or out_task_id == null)
        return status_invalid_argument;

    const owned_deferred = deferred_handle.?;
    deferred_handle = null;
    const task_id = request_body.scheduleFormData(
        runtime,
        request_id,
        request_generation,
        owned_deferred,
        bindings.rawStringSlice(content_type_raw),
    ) catch return status_error;
    out_task_id.?.* = task_id;
    return status_ok;
}
