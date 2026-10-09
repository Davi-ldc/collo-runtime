//! Settlement of fetch promises: a `fetch_completion` item runs `execute`,
//! which removes the task and resolves its promise with a `Response` or
//! rejects it. Runs on the worker's event loop thread.
//!
//! The task owns its promise's deferred, and a deferred released unsettled
//! leaves the fetch promise pending for good. So once a live request owns the
//! task, every path settles the promise, or fails the request when even a
//! rejection cannot be made, before the task is destroyed. A task whose
//! request is gone is destroyed without running JS.

const std = @import("std");
const bindings = @import("collo_bindings");
const egress_context = @import("context.zig");
const fetch_body_runtime = @import("body/root.zig");
const request_context = @import("collo_worker_request").context;
const task_mod = @import("task.zig");
const turn = @import("collo_worker_js").turn;

const Task = task_mod.Task;
const Result = task_mod.Result;

/// Runs the `fetch_completion` item of `fetch_id`: removes the task and
/// settles its promise. Fails with `error.FetchCompletionNotFound` when the
/// task is already gone, as after the boot context's reap
/// (`task_runtime.reapForRequest`).
pub fn execute(runtime: *egress_context.Context, fetch_id: u64) !void {
    const removed = runtime.egress_state.tasks.fetchRemove(fetch_id) orelse return error.FetchCompletionNotFound;
    const task = removed.value;
    defer {
        task.deinit(runtime.allocator);
        runtime.allocator.destroy(task);
    }

    const request = runtime.requests.get(task.request_id) orelse {
        task.markCanceled();
        if (task.result) |*stale_result| {
            stale_result.deinit();
            task.result = null;
        }
        _ = fetch_body_runtime.release(runtime, task.response_body_identity);
        return;
    };
    if (task.isCanceled()) {
        if (task.result) |*stale_result| {
            stale_result.deinit();
            task.result = null;
        }
        _ = fetch_body_runtime.release(runtime, task.response_body_identity);
        rejectCanceledTask(runtime, task, request);
        return;
    }

    var result = task.result orelse {
        // Rejected before the deferred dies with the task, as the file header
        // requires.
        rejectDeferredBestEffort(runtime, task, request, "fetch completion missing result");
        runtime.handleRequestFailure(request.exec.request_id, error.FetchResultMissing);
        return;
    };
    task.result = null;
    defer result.deinit();

    deliver(runtime, task, &result) catch |err| {
        // Rejected before the task is destroyed, like the path above. When
        // `deliver` failed after its settle took the deferred, the rejection
        // does nothing.
        if (runtime.requests.get(task.request_id)) |active_request| {
            rejectDeferredBestEffort(runtime, task, active_request, "fetch completion failed");
            runtime.handleRequestFailure(active_request.exec.request_id, err);
        } else std.log.warn("fetch completion callback failed after request removal request_id={d}: {s}", .{ task.request_id, @errorName(err) });
    };
}

/// Rejects the task's promise with `message`, and does nothing when the
/// deferred was already taken. `turn.settlePromise` takes the raw handle
/// before it enters the turn, so a `deliver` that failed mid-settle leaves it
/// taken, and the rejection then fails with `error.InvalidPromiseDeferred`,
/// which is ignored. Any other failure is logged.
fn rejectDeferredBestEffort(
    runtime: *egress_context.Context,
    task: *Task,
    request: *request_context.RequestContext,
    message: []const u8,
) void {
    var reason = runtime.vm.stringValueUtf8(message) catch |err| {
        std.log.warn("fetch completion reject reason alloc failed request_id={d}: {s}", .{
            task.request_id,
            @errorName(err),
        });
        return;
    };
    defer reason.deinit();
    turn.rejectPromise(runtime.vm, &request.exec, &task.deferred, &reason) catch |err| switch (err) {
        error.InvalidPromiseDeferred => {},
        else => std.log.warn("fetch completion reject failed request_id={d}: {s}", .{
            task.request_id,
            @errorName(err),
        }),
    };
}

/// Rejects a canceled task's promise with the abort reason JS gave, or else
/// "fetch aborted"; a rejection that fails fails the request.
fn rejectCanceledTask(
    runtime: *egress_context.Context,
    task: *Task,
    request: *request_context.RequestContext,
) void {
    if (task.takeAbortReason()) |reason| {
        var owned_reason = reason;
        defer owned_reason.deinit();
        turn.rejectPromise(runtime.vm, &request.exec, &task.deferred, &owned_reason) catch |err| {
            runtime.handleRequestFailure(request.exec.request_id, err);
        };
        return;
    }

    var error_value = runtime.vm.stringValueUtf8("fetch aborted") catch |err| {
        runtime.handleRequestFailure(request.exec.request_id, err);
        return;
    };
    defer error_value.deinit();
    turn.rejectPromise(runtime.vm, &request.exec, &task.deferred, &error_value) catch |err| {
        runtime.handleRequestFailure(request.exec.request_id, err);
    };
}

/// Handles an error from `execute`: fails the task's request, or only logs
/// when the task is already gone.
pub fn handleFailure(runtime: *egress_context.Context, fetch_id: u64, err: anyerror) void {
    const task = runtime.egress_state.tasks.get(fetch_id) orelse {
        std.log.warn("fetch completion failed after task removal fetch_id={d}: {s}", .{ fetch_id, @errorName(err) });
        return;
    };
    runtime.handleRequestFailure(task.request_id, err);
}

/// Settles the promise from `result`: a success resolves it with a `Response`
/// that takes over the response body view, and a failure releases that view
/// and rejects with a TypeError carrying the failure's message, which is how
/// the Fetch standard reports a network error. `task` is not canceled:
/// `execute` settles a canceled task in `rejectCanceledTask`.
fn deliver(runtime: *egress_context.Context, task: *Task, result: *Result) !void {
    const request = runtime.requests.get(task.request_id) orelse return error.RequestNotFound;
    const exec_ctx_ptr: *bindings.ExecCtx = &request.exec;

    switch (result.*) {
        .success => {
            var response = try makeFetchResponse(runtime, task, result.*);
            defer response.deinit();
            try turn.resolvePromise(runtime.vm, exec_ctx_ptr, &task.deferred, &response);
        },
        .failure => |failure| {
            _ = fetch_body_runtime.release(runtime, task.response_body_identity);
            var error_value = try runtime.vm.typeErrorValueUtf8(failure.message);
            defer error_value.deinit();
            try turn.rejectPromise(runtime.vm, exec_ctx_ptr, &task.deferred, &error_value);
        },
    }
}

fn makeFetchResponse(
    runtime: *egress_context.Context,
    task: *const Task,
    result: Result,
) !bindings.Value {
    const payload = switch (result) {
        .success => |success| success,
        .failure => return error.InvalidArgument,
    };

    _ = runtime.requests.get(task.request_id) orelse return error.RequestNotFound;
    const init = bindings.FetchResponseInit{
        .response = .{
            .body = bindings.borrowedBuffer(""),
            .status_text = .{ .ptr = if (payload.status_text.len == 0) null else payload.status_text.ptr, .len = payload.status_text.len },
            .url = .{ .ptr = if (payload.url.len == 0) null else payload.url.ptr, .len = payload.url.len },
            .headers = if (payload.headers.len == 0) null else payload.headers.ptr,
            .headers_len = payload.headers.len,
            .status = payload.status,
            .flags = if (payload.redirected) bindings.response_init_flag_redirected else 0,
        },
        .body_identity = payload.body_identity,
    };
    return switch (try runtime.vm.fetchResponseValue(&init)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.JsException;
        },
    };
}
