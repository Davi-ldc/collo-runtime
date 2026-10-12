//! The fs fault exports the `node:fs` binding
//! (`bindings/host_functions/node/fs.cpp`) calls when a read reaches a file
//! of the worker's read-only tree: to fault in a file that has no copy in
//! the tmpfs yet, and to record a direct read of a copy that exists.
//! `worker/fs/fault.zig` owns the behavior. Runs on the worker's VM thread.
//!
//! abi.h declares the exports and states their statuses and what they take;
//! a path argument reads as `abiPath` in `worker/fs/index.zig` defines for
//! every fs export.

const bindings = @import("collo_bindings");
const copies = @import("../fs/copies.zig");
const worker_fs = @import("../fs/index.zig");
const promise_deferred = @import("collo_worker_js").deferred;
const host_adapter = @import("adapter.zig");

/// Parks a promise-returning read of a file that has no copy yet. The
/// deferred settles on the event loop once the host answers the fault, and
/// on a failure the binding rejects the read with EIO.
pub export fn collo_runtime_fs_fault_read_file(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    path_raw: bindings.RawString,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_fault_id: ?*u64,
) bindings.RawStatus {
    var deferred = if (deferred_raw) |raw| promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred) |*owned| owned.deinit();
    if (out_fault_id) |cleared| cleared.* = 0;

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return bindings.status_invalid_argument;
    if (deferred == null or out_fault_id == null)
        return bindings.status_invalid_argument;
    const path = worker_fs.abiPath(path_raw) orelse return bindings.status_invalid_argument;
    if (request_id == 0 or path.len == 0)
        return bindings.status_invalid_argument;

    // `scheduleFsFaultRead` takes the deferred on every path, failures
    // included.
    const owned_deferred = deferred.?;
    deferred = null;
    const fault_id = runtime.scheduleFsFaultRead(request_id, path, owned_deferred) catch
        return bindings.status_error;
    out_fault_id.?.* = fault_id;
    return bindings.status_ok;
}

/// Faults in a file for a synchronous read such as `readFileSync`, blocking
/// the VM thread until the copy exists or the wait that `faultSync` in
/// `worker/fs/fault_sync.zig` bounds runs out. On `bindings.status_ok` the
/// binding reads the copy itself; it turns `bindings.status_not_found` into
/// ENOENT and any other status into EIO.
pub export fn collo_runtime_fs_fault_sync(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    path_raw: bindings.RawString,
) bindings.RawStatus {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return bindings.status_invalid_argument;
    const path = worker_fs.abiPath(path_raw) orelse return bindings.status_invalid_argument;
    if (request_id == 0 or path.len == 0)
        return bindings.status_invalid_argument;
    runtime.fsFaultReadSync(request_id, path) catch |err| return switch (err) {
        error.FsFaultNotFound => bindings.status_not_found,
        else => bindings.status_error,
    };
    return bindings.status_ok;
}

/// Records that the binding read an existing copy directly. The call traces
/// `worker.fs_fault.hit_local`, which the integration tests assert on, and
/// keeps the copy from the idle sweep (`copies.recordLocalHit`). An empty
/// path names no file, so it records nothing, like a null one.
pub export fn collo_runtime_fs_fault_hit_local(
    runtime_ptr: ?*anyopaque,
    path_raw: bindings.RawString,
) void {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return;
    const path = worker_fs.abiPath(path_raw) orelse return;
    if (path.len == 0)
        return;
    copies.recordLocalHit(runtime, path);
}
