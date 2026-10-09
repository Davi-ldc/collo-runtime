//! The `collo_runtime_fetch*` exports: the bridge starts and cancels a
//! handler's fetch here, and reads, clones, cancels and releases a fetch
//! response body. `worker/egress/` owns the behavior. Runs on the worker's
//! VM thread.
//!
//! A call's ABI strings, buffers and header arrays become slices that borrow
//! the bridge's memory for the call only, and a null pointer with a nonzero
//! length is an invalid argument. As abi.h requires, a promise deferred or a
//! cancel reason passed in is Zig's on every path, failures included.

const bindings = @import("collo_bindings");
const fetch_body = @import("collo_egress_core").fetch_body;
const promise_deferred = @import("collo_worker_js").deferred;
const egress_fetch = @import("../egress/fetch_runtime.zig");
const host_adapter = @import("adapter.zig");

// The `ColloStatus` values of abi.h.
const status_ok: c_int = 0;
const status_error: c_int = 1;
const status_invalid_argument: c_int = 2;

/// Starts a fetch and writes its id to `out_fetch_id`. A fetch that cannot
/// leave the worker, because the worker is detached from its gateway or the
/// request carries no egress token (`fetch_runtime.refusal`), rejects at once
/// with a TypeError naming the cause, as a network error does, and the call
/// succeeds with fetch id 0, which names no fetch. Any other failure returns
/// `status_error` with the promise left unsettled.
pub export fn collo_runtime_fetch(
    runtime_ptr: ?*anyopaque,
    init_ptr: ?*const bindings.FetchInit,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_fetch_id: ?*u64,
) c_int {
    var deferred = if (deferred_raw) |raw| promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    var owns_deferred = true;
    defer if (owns_deferred)
        if (deferred) |*owned|
            owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (init_ptr == null or deferred == null or out_fetch_id == null)
        return status_invalid_argument;

    const init = init_ptr.?;
    const url = stringSlice(init.url) orelse return status_invalid_argument;
    const method = stringSlice(init.method) orelse return status_invalid_argument;
    const body = bufferSlice(init.body) orelse return status_invalid_argument;
    const headers = headerSlice(init.headers, init.headers_len) orelse return status_invalid_argument;

    var egress_ctx = runtime.egressContext();
    if (egress_fetch.refusal(&egress_ctx, init.request_id)) |refused| {
        rejectRefusedFetch(runtime.core.vm, &deferred.?, refused.message()) catch
            return status_error;
        out_fetch_id.?.* = 0;
        return status_ok;
    }

    const owned_deferred = deferred.?;
    deferred = null;
    owns_deferred = false;
    const fetch_id = runtime.scheduleFetch(init.request_id, url, method, body, headers, init.flags, owned_deferred) catch
        return status_error;
    out_fetch_id.?.* = fetch_id;
    return status_ok;
}

/// Rejects the promise of `deferred` with a TypeError carrying `message` and
/// releases the deferred. It runs inside the `fetch()` call that created the
/// promise, so the rejection enters no turn of its own: its reactions run at
/// the caller's next microtask checkpoint. On failure `deferred` keeps the
/// deferred when it was not taken yet.
fn rejectRefusedFetch(vm: *bindings.Vm, deferred: *promise_deferred.DeferredOwned, message: []const u8) !void {
    const realm = try deferred.realm();
    var reason = try realm.typeErrorValueUtf8(message);
    defer reason.deinit();
    const raw = try deferred.take();
    defer bindings.releasePromiseDeferred(raw);
    switch (try vm.promiseDeferredReject(raw, &reason)) {
        .success => {},
        .exception => |exception| {
            var owned = exception;
            owned.deinit();
            return error.JsException;
        },
    }
}

pub export fn collo_runtime_fetch_cancel(
    runtime_ptr: ?*anyopaque,
    fetch_id: u64,
    reason_raw: ?*bindings.RawValue,
) void {
    var reason = if (reason_raw) |raw| bindings.Value.fromRawOwnedNonNull(raw) else null;
    var reason_owned = reason != null;
    defer if (reason_owned)
        if (reason) |*value|
            value.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return;
    if (fetch_id == 0)
        return;
    const moved_reason = reason;
    reason = null;
    reason_owned = false;
    runtime.cancelFetch(fetch_id, moved_reason);
}

pub export fn collo_runtime_fetch_body_consume(
    runtime_ptr: ?*anyopaque,
    init_ptr: ?*const bindings.FetchBodyConsumeInit,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_task_id: ?*u64,
) c_int {
    var deferred = if (deferred_raw) |raw| promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred) |*owned| owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (init_ptr == null or deferred == null or out_task_id == null)
        return status_invalid_argument;

    const init = init_ptr.?;
    const content_type = stringSlice(init.content_type) orelse return status_invalid_argument;
    const kind = fetchBodyReadKind(init.kind) orelse return status_invalid_argument;

    const owned_deferred = deferred.?;
    deferred = null;
    const task_id = runtime.scheduleFetchBodyConsume(init.identity, kind, content_type, owned_deferred) catch
        return status_error;
    out_task_id.?.* = task_id;
    return status_ok;
}

pub export fn collo_runtime_fetch_body_pull(
    runtime_ptr: ?*anyopaque,
    identity_ptr: ?*const bindings.FetchBodyIdentity,
    deferred_raw: ?*bindings.RawPromiseDeferred,
    out_task_id: ?*u64,
) c_int {
    var deferred = if (deferred_raw) |raw| promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw) else null;
    defer if (deferred) |*owned| owned.deinit();

    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (identity_ptr == null or deferred == null or out_task_id == null)
        return status_invalid_argument;

    const owned_deferred = deferred.?;
    deferred = null;
    const task_id = runtime.scheduleFetchBodyPull(identity_ptr.?.*, owned_deferred) catch
        return status_error;
    out_task_id.?.* = task_id;
    return status_ok;
}

pub export fn collo_runtime_fetch_body_cancel(
    runtime_ptr: ?*anyopaque,
    identity_ptr: ?*const bindings.FetchBodyIdentity,
) void {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return;
    if (identity_ptr == null)
        return;
    runtime.cancelFetchBody(identity_ptr.?.*);
}

pub export fn collo_runtime_fetch_body_borrow(
    runtime_ptr: ?*anyopaque,
    identity_ptr: ?*const bindings.FetchBodyIdentity,
    out_body: ?*bindings.RawBuffer,
) c_int {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (identity_ptr == null or out_body == null)
        return status_invalid_argument;
    const body = runtime.borrowFetchBody(identity_ptr.?.*) orelse return status_error;
    out_body.?.* = .{
        .ptr = if (body.len == 0) null else body.ptr,
        .len = body.len,
    };
    return status_ok;
}

pub export fn collo_runtime_fetch_body_clone(
    runtime_ptr: ?*anyopaque,
    identity_ptr: ?*const bindings.FetchBodyIdentity,
    out_identity: ?*bindings.FetchBodyIdentity,
) c_int {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return status_invalid_argument;
    if (identity_ptr == null or out_identity == null)
        return status_invalid_argument;
    out_identity.?.* = runtime.cloneFetchBody(identity_ptr.?.*) catch return status_error;
    return status_ok;
}

pub export fn collo_runtime_fetch_body_release(
    runtime_ptr: ?*anyopaque,
    identity_ptr: ?*const bindings.FetchBodyIdentity,
) void {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return;
    if (identity_ptr == null)
        return;
    _ = runtime.releaseFetchBody(identity_ptr.?.*);
}

fn fetchBodyReadKind(raw: u8) ?fetch_body.ReadKind {
    return switch (raw) {
        @intFromEnum(bindings.FetchBodyConsumeKind.text) => .text,
        @intFromEnum(bindings.FetchBodyConsumeKind.json) => .json,
        @intFromEnum(bindings.FetchBodyConsumeKind.array_buffer) => .array_buffer,
        @intFromEnum(bindings.FetchBodyConsumeKind.bytes) => .bytes,
        @intFromEnum(bindings.FetchBodyConsumeKind.blob) => .blob,
        @intFromEnum(bindings.FetchBodyConsumeKind.form_data) => .form_data,
        else => null,
    };
}

fn stringSlice(raw: bindings.RawString) ?[]const u8 {
    if (raw.len == 0)
        return "";
    const ptr = raw.ptr orelse return null;
    return ptr[0..raw.len];
}

fn bufferSlice(raw: bindings.RawBuffer) ?[]const u8 {
    if (raw.len == 0)
        return "";
    const ptr = raw.ptr orelse return null;
    return ptr[0..raw.len];
}

fn headerSlice(ptr: ?[*]const bindings.NameValuePair, len: usize) ?[]const bindings.NameValuePair {
    if (len == 0)
        return &.{};
    const raw = ptr orelse return null;
    return raw[0..len];
}
