//! Settlement of fetch promises: a `fetch_completion` item runs `execute`,
//! which removes the task and resolves its promise with a `Response` or
//! rejects it. Runs on the worker's VM thread.
//!
//! The task owns its promise's deferred, and a deferred released unsettled
//! leaves the fetch promise pending for good. So once a live request owns the
//! task, every path settles the promise, or fails the request when even a
//! rejection cannot be made, before the task is destroyed. A task whose
//! request is gone, or will run no more JavaScript, is destroyed without
//! running JavaScript (`discard`).

const std = @import("std");
const bindings = @import("collo_bindings");
const Runtime = @import("../runtime/root.zig").Runtime;
const request_context = @import("collo_worker_request").context;
const turn = @import("collo_worker_js").turn;
const fetch_body_runtime = @import("body/root.zig");
const task_mod = @import("task.zig");
const task_runtime = @import("task_runtime.zig");

const Task = task_mod.Task;
const Result = task_mod.Result;

/// Destroys the task of `fetch_id` with its response body view, leaving its
/// promise unsettled, for a request that is gone or that an ending already
/// answered, so none of its JavaScript runs again
/// (`serve/termination.zig:admitAtBoundary`). Does nothing when the task is
/// already gone.
pub fn discard(runtime: *Runtime, fetch_id: u64) void {
    const task = runtime.egress.state.tasks.get(fetch_id) orelse return;
    task_runtime.destroyTask(runtime, task);
}

/// Runs the `fetch_completion` item of `fetch_id`: settles the task's promise
/// and destroys the task. Fails with `error.FetchCompletionNotFound` when the
/// task is already gone, as after an evaluation's reap
/// (`task_runtime.reapForRequest`).
pub fn execute(runtime: *Runtime, fetch_id: u64) !void {
    const task = runtime.egress.state.tasks.get(fetch_id) orelse return error.FetchCompletionNotFound;
    const request = runtime.requests.active.get(task.request_id) orelse {
        task_runtime.destroyTask(runtime, task);
        return;
    };
    // Out of the table before any JavaScript runs, so nothing a settlement's
    // reactions do finds the task.
    _ = runtime.egress.state.tasks.remove(fetch_id);
    defer {
        task.deinit(runtime.core.allocator);
        runtime.core.allocator.destroy(task);
    }
    if (task.canceled) {
        _ = fetch_body_runtime.release(runtime, task.response_body_identity);
        rejectCanceledTask(runtime, task, request);
        return;
    }

    const result = task.result orelse {
        // Rejected before the deferred dies with the task, as the file header
        // requires.
        rejectDeferredBestEffort(runtime, task, request, "fetch completion missing result");
        runtime.handleRequestFailure(request.exec.request_id, error.FetchResultMissing);
        return;
    };
    deliver(runtime, task, result) catch |err| {
        // Rejected before the task is destroyed, like the path above. When
        // `deliver` failed after its settle took the deferred, the rejection
        // does nothing.
        if (runtime.requests.active.get(task.request_id)) |active_request| {
            rejectDeferredBestEffort(runtime, task, active_request, "fetch completion failed");
            runtime.handleRequestFailure(active_request.exec.request_id, err);
        } else std.log.warn("fetch completion callback failed after request removal request_id={d}: {s}", .{
            task.request_id,
            @errorName(err),
        });
    };
}

/// Rejects the task's promise with `message`, and does nothing when the
/// deferred was already taken. `turn.settlePromise` takes the raw handle
/// before it enters the turn, so a `deliver` that failed mid-settle leaves it
/// taken, and the rejection then fails with `error.InvalidPromiseDeferred`,
/// which is ignored. Any other failure is logged.
fn rejectDeferredBestEffort(
    runtime: *Runtime,
    task: *Task,
    request: *request_context.RequestContext,
    message: []const u8,
) void {
    var reason = runtime.core.vm.stringValueUtf8(message) catch |err| {
        std.log.warn("fetch completion reject reason alloc failed request_id={d}: {s}", .{
            task.request_id,
            @errorName(err),
        });
        return;
    };
    defer reason.deinit();
    turn.rejectPromise(runtime.core.vm, &request.exec, &task.deferred, &reason) catch |err| switch (err) {
        error.InvalidPromiseDeferred => {},
        else => std.log.warn("fetch completion reject failed request_id={d}: {s}", .{
            task.request_id,
            @errorName(err),
        }),
    };
}

/// Rejects a canceled task's promise with the abort reason JavaScript gave,
/// or else "fetch aborted"; a rejection that fails fails the request.
fn rejectCanceledTask(runtime: *Runtime, task: *Task, request: *request_context.RequestContext) void {
    if (task.takeAbortReason()) |reason| {
        var owned_reason = reason;
        defer owned_reason.deinit();
        turn.rejectPromise(runtime.core.vm, &request.exec, &task.deferred, &owned_reason) catch |err|
            runtime.handleRequestFailure(request.exec.request_id, err);
        return;
    }
    var error_value = runtime.core.vm.stringValueUtf8(task_runtime.aborted_message) catch |err| {
        runtime.handleRequestFailure(request.exec.request_id, err);
        return;
    };
    defer error_value.deinit();
    turn.rejectPromise(runtime.core.vm, &request.exec, &task.deferred, &error_value) catch |err|
        runtime.handleRequestFailure(request.exec.request_id, err);
}

/// Handles an error from `execute`: fails the task's request, or only logs
/// when the task is already gone.
pub fn handleFailure(runtime: *Runtime, fetch_id: u64, err: anyerror) void {
    const task = runtime.egress.state.tasks.get(fetch_id) orelse {
        std.log.warn("fetch completion failed after task removal fetch_id={d}: {s}", .{ fetch_id, @errorName(err) });
        return;
    };
    runtime.handleRequestFailure(task.request_id, err);
}

/// Settles the promise from `result`: a success resolves it with a `Response`
/// that takes over the response body view, and a failure releases that view
/// and rejects with a TypeError carrying the failure's message, which is how
/// the Fetch standard reports a network error. A failure the network setting
/// caused also writes that message once to the tenant's log, so a denial
/// the handler swallows still shows.
fn deliver(runtime: *Runtime, task: *Task, result: Result) !void {
    const request = runtime.requests.active.get(task.request_id) orelse return error.RequestNotFound;
    switch (result) {
        .success => |success| {
            var response = try makeFetchResponse(task, success);
            defer response.deinit();
            try turn.resolvePromise(runtime.core.vm, &request.exec, &task.deferred, &response);
        },
        .failure => |failure| {
            switch (failure.cause) {
                .network_denied => runtime.logNetworkDenial(task.request_id, failure.message),
                .failed => {},
            }
            _ = fetch_body_runtime.release(runtime, task.response_body_identity);
            const realm = try task.deferred.realm();
            var error_value = try realm.typeErrorValueUtf8(failure.message);
            defer error_value.deinit();
            try turn.rejectPromise(runtime.core.vm, &request.exec, &task.deferred, &error_value);
        },
    }
}

/// The `Response` of a fetch that succeeded, in the realm of the `fetch()`
/// call's promise.
fn makeFetchResponse(task: *const Task, success: @FieldType(Result, "success")) !bindings.Value {
    const init = bindings.FetchResponseInit{
        .response = .{
            .body = bindings.borrowedBuffer(""),
            .status_text = .{ .ptr = if (success.status_text.len == 0) null else success.status_text.ptr, .len = success.status_text.len },
            .url = .{ .ptr = if (success.url.len == 0) null else success.url.ptr, .len = success.url.len },
            .headers = if (success.headers.len == 0) null else success.headers.ptr,
            .headers_len = success.headers.len,
            .status = success.status,
            .flags = if (success.redirected) bindings.response_init_flag_redirected else 0,
        },
        .body_identity = success.body_identity,
    };
    const realm = try task.deferred.realm();
    return switch (try realm.fetchResponseValue(&init)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.JsException;
        },
    };
}
