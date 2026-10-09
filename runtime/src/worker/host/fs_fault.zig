//! The fs fault exports the `node:fs` binding
//! (`bindings/host_functions/node/fs.cpp`) calls when a read reaches a file
//! of the worker's read-only tree: to fault in a file that has no copy in
//! the tmpfs yet, and to record a direct read of a copy that exists.
//! `worker/fs/fault.zig` owns the behavior. Runs on the worker's VM thread.
//!
//! `fs.cpp` declares these exports itself, outside abi.h, and they return
//! `int` codes of their own, not `ColloStatus`.

const bindings = @import("collo_bindings");
const copies = @import("../fs/copies.zig");
const promise_deferred = @import("collo_worker_js").deferred;
const host_adapter = @import("adapter.zig");

const status_ok: c_int = 0;
const status_error: c_int = 1;
const status_invalid_argument: c_int = 2;
// Equals `faultSyncStatusNotFound` in `fs.cpp`, which turns it into ENOENT.
const status_not_found: c_int = 3;

/// Parks a promise-returning read of a file that has no copy yet and writes
/// the fault id to `out_fault_id`. Takes `deferred` on every path, failures
/// included; the deferred settles on the event loop once the host answers
/// the fault, and on a failure the binding rejects the read with EIO.
pub export fn collo_runtime_fs_fault_read_file(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    path_ptr: ?[*]const u8,
    path_len: usize,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_fault_id: ?*u64,
) c_int {
    var deferred = if (deferred_raw) |raw| promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    var owns_deferred = true;
    defer if (owns_deferred)
        if (deferred) |*owned|
            owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (deferred == null or out_fault_id == null)
        return status_invalid_argument;
    const path = pathSlice(path_ptr, path_len) orelse return status_invalid_argument;
    if (request_id == 0 or path.len == 0)
        return status_invalid_argument;

    const owned_deferred = deferred.?;
    deferred = null;
    owns_deferred = false;
    const fault_id = runtime.scheduleFsFaultRead(request_id, path, owned_deferred) catch
        return status_error;
    out_fault_id.?.* = fault_id;
    return status_ok;
}

/// Faults in a file for a synchronous read such as `readFileSync`, blocking
/// the VM thread until the copy exists or the wait that `faultSync` in
/// `worker/fs/fault_sync.zig` bounds runs out. On `status_ok` the binding reads
/// the copy itself; it turns `status_not_found` into ENOENT and any other
/// status into EIO.
pub export fn collo_runtime_fs_fault_sync(
    runtime_ptr: ?*anyopaque,
    request_id: u64,
    path_ptr: ?[*]const u8,
    path_len: usize,
) c_int {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    const path = pathSlice(path_ptr, path_len) orelse return status_invalid_argument;
    if (request_id == 0 or path.len == 0)
        return status_invalid_argument;
    runtime.fsFaultReadSync(request_id, path) catch |err| return switch (err) {
        error.FsFaultNotFound => status_not_found,
        else => status_error,
    };
    return status_ok;
}

/// Records that the binding read an existing copy directly. The call traces
/// `worker.fs_fault.hit_local`, which the integration tests assert on, and
/// keeps the copy from the idle sweep (`copies.recordLocalHit`).
pub export fn collo_runtime_fs_fault_hit_local(
    runtime_ptr: ?*anyopaque,
    path_ptr: ?[*]const u8,
    path_len: usize,
) void {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return;
    const path = pathSlice(path_ptr, path_len) orelse return;
    copies.recordLocalHit(runtime, path);
}

fn pathSlice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0)
        return "";
    const raw = ptr orelse return null;
    return raw[0..len];
}
