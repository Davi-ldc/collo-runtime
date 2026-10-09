//! Runs a dispatched request: checks its head, builds the handler's
//! `Request`, calls `handler(request, env)` and answers with what the
//! handler returns or throws. It also owns the request's failure paths: a
//! client reset, a deadline and a local error each end the request with a
//! response or a reset. It runs on the worker's VM thread.
//!
//! The server chose the route from the request path and names it in the
//! dispatch (`DispatchWork.route_entry_specifier`), so the worker serves
//! every request with that route's handler and never compares the request's
//! authority with a name of its own.

const std = @import("std");
const bindings = @import("collo_bindings");
const state = @import("../runtime/root.zig");
const request_head = @import("collo_worker_request").head;
const request_context = @import("collo_worker_request").context;
const body_read = @import("collo_worker_request").body_read;
const handler_thenable = @import("handler_thenable.zig");
const turn = @import("collo_worker_js").turn;
const request_bridge = @import("../js/server_api/request.zig");
const response_bridge = @import("../js/server_api/response.zig");
const js_value = @import("collo_worker_js").value;
const request_task = @import("collo_worker_request").task;
const worker_shared_page = @import("collo_worker_state").page;
const response_flow = @import("response.zig");
const tracing = @import("trace.zig");
const module_routes = @import("../modules/routes.zig");

pub fn execute(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return error.RequestNotFound;
    request_ctx.dispatch_queued = false;
    if (request_ctx.finish_started)
        return;
    if (request_ctx.client_reset) {
        try cancelClientReset(runtime, request_id);
        return;
    }
    request_ctx.dispatch_started = true;
    executeLoaded(runtime, request_ctx) catch |err|
        handleLocalFailure(runtime, request_id, err);
}

pub fn executeBodyReady(runtime: *state.Runtime, request_id: u64) !void {
    try body_read.executeReady(runtime, request_id);
}

/// The client reset the stream: the request ends as client-closed and no
/// response is written.
pub fn cancelClientReset(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    request_ctx.cancel_queued = false;
    request_ctx.client_reset = true;
    request_ctx.body.pipe.fail("http2 stream reset");
    if (request_ctx.request_task) |token| {
        if (runtime.requests.tasks.get(token)) |task| {
            task.canceled = true;
            task.state = .canceled;
        }
    }
    _ = try response_flow.finishRequest(runtime, request_ctx, .client_closed, 499);
}

/// The request's deadline passed. It answers 504 in place of a response
/// whose head has not gone out, or ends a committed response with that
/// status.
pub fn deadlineTimeout(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    if (!request_ctx.deadline_armed and !request_ctx.deadline_due_queued)
        return;
    // A top-level await that never settles outlives every request, and
    // traffic keeps the worker from going idle, so once the evaluation
    // budget is spent the only way out is to recycle the worker: requests in
    // flight fail through the server's death path and the next one starts a
    // fresh worker. The deadline of a request parked on the evaluation is
    // the one wake guaranteed to reach this point.
    {
        var modules_ctx = runtime.modulesContext();
        if (module_routes.evaluationZombie(&modules_ctx, request_ctx.dispatch_work.route_entry_specifier)) {
            // warn, not err: the boot tests exercise this recycle on purpose,
            // and the test runner fails a run on any err line. The recycle
            // after a failed evaluation in `worker/runtime/modules.zig` logs at
            // the same level.
            std.log.warn("route module evaluation exceeded budget; recycling worker specifier={s}", .{
                request_ctx.dispatch_work.route_entry_specifier,
            });
            runtime.core.running = false;
        }
    }
    // The boot context's deadline is the evaluation budget, and it has no
    // client stream to answer. Either the check above already recycled the
    // worker, or the module settled before this entry fired; either way the
    // window is over.
    if (request_id == request_context.boot_request_id) {
        runtime.disarmRequestDeadline(request_ctx);
        request_ctx.exec.deadline_monotonic_ns = 0;
        return;
    }
    // A sentinel that fired terminated the VM for good, so once this 504 is
    // written the worker stops after the drain instead of answering every
    // later request with a 500. The fired bit is read before the disarm,
    // which erases it.
    const sentinel_fired = runtime.requestDeadlineSentinelFired(request_ctx);
    defer if (sentinel_fired) {
        runtime.stop_after_deadline_fire = true;
    };
    runtime.disarmRequestDeadline(request_ctx);
    if (!request_ctx.body.isComplete()) {
        request_ctx.body.pipe.fail("request deadline exceeded");
    }
    if (request_ctx.response_committed) {
        _ = try response_flow.finishRequest(runtime, request_ctx, .deadline_timeout, 504);
        return;
    }
    try response_flow.replaceUnsentResponse(runtime, request_ctx, 504, "gateway timeout", .deadline_timeout);
}

/// The funnel for an error a request's work returned. A full record ring or
/// completion ring stops the worker, so the server synthesizes the records
/// of the requests in flight; any other error ends the request with a 500,
/// or with a reset when its response is already committed.
pub fn handleLocalFailure(runtime: *state.Runtime, request_id: u64, err: anyerror) void {
    runtime.traceRuntimeEvent("worker.request.failure={d},{s}", .{ request_id, @errorName(err) });
    if (err == error.CompletedRecordRingFull) {
        runtime.traceRuntimeEvent("worker.runtime.stop=completed_record_ring_full,{d}", .{request_id});
        runtime.core.running = false;
        std.log.err("worker completed-record ring full request_id={d}; stopping worker for host-side synthesis", .{request_id});
        return;
    }
    if (err == error.WorkerCompletionRingOverflow) {
        runtime.traceRuntimeEvent("worker.runtime.stop=worker_completion_ring_overflow,{d}", .{request_id});
        runtime.core.running = false;
        std.log.err("worker completion ring overflow request_id={d}; stopping worker for host-side synthesis", .{request_id});
        return;
    }
    if (!runtime.core.running) {
        std.log.warn("request-local failure after worker stop request_id={d}: {s}", .{
            request_id,
            @errorName(err),
        });
        return;
    }
    // The boot context has no response path. `failInternal` would send
    // frames with a zeroed dispatch identity, publish a record for no
    // request and destroy the boot context while later top-level fetches and
    // timers still need it. The failed operation already reached JavaScript
    // as a rejection, so the error is only logged; at warn, because a test
    // exercises this guard and the test runner fails a run on any err line.
    if (request_id == request_context.boot_request_id) {
        std.log.warn("instance-context work failed (dropped, no response path): {s}", .{
            @errorName(err),
        });
        return;
    }
    if (runtime.requests.active.get(request_id)) |active_request| {
        failInternal(runtime, active_request, err);
        return;
    }
    std.log.warn("request-local work failed after request removal request_id={d}: {s}", .{ request_id, @errorName(err) });
}

/// The failure funnel of an asynchronous handler's settlement, the
/// counterpart of `handleLocalFailure` for the synchronous path. Without it
/// a committed response whose completion failed would stay open, truncated,
/// until the deadline, with nothing left to drive the request.
pub fn handleCompletionFailure(runtime: *state.Runtime, token: request_task.TaskToken, err: anyerror) void {
    const task = runtime.requests.tasks.get(token) orelse {
        std.log.warn("request task completion failed slot={d} generation={d}: {s}", .{
            token.slot,
            token.generation,
            @errorName(err),
        });
        return;
    };
    handleLocalFailure(runtime, task.request_id, err);
}

/// Answers a request whose handler returned a thenable, once it settled. A
/// token that no longer names the waiting task is counted as stale and
/// ignored.
pub fn executeCompletion(runtime: *state.Runtime, token: request_task.TaskToken) !void {
    const task = runtime.requests.tasks.get(token) orelse {
        runtime.observability.stale_task_completion_count += 1;
        return;
    };
    task.completion_queued = false;
    const request_id = task.request_id;
    const removed = runtime.requests.pending_completions.fetchRemove(request_id) orelse return error.RequestCompletionNotFound;
    var completion = removed.value;
    defer completion.deinit();
    if (completion.token.slot != token.slot or completion.token.generation != token.generation) {
        runtime.observability.stale_task_completion_count += 1;
        return;
    }

    const request_ctx = runtime.requests.active.get(request_id) orelse {
        runtime.observability.stale_task_completion_count += 1;
        return;
    };
    if (task.state != .waiting_thenable or task.canceled or task.timed_out) {
        runtime.observability.stale_task_completion_count += 1;
        return;
    }
    if (task.pending_thenable) |*pending| {
        pending.deinit();
        task.pending_thenable = null;
    }
    tracing.mark(runtime, request_ctx, "completion_received_ns");
    if (runtime.requestDeadlineTerminationRequested(request_ctx)) {
        task.timed_out = true;
        try deadlineTimeout(runtime, request_id);
        return;
    }
    task.state = .extracting_response;
    if (completion.is_error) {
        task.state = .failed;
        try response_flow.writeException(runtime, request_ctx, &completion.value);
    } else {
        try response_bridge.writeValueResponse(runtime, request_ctx, &completion.value, response_flow.writeAndFinishResponse);
    }
}

fn executeLoaded(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !void {
    tracing.mark(runtime, request_ctx, "execute_request_start_ns");
    try runtime.armRequestDeadline(request_ctx);
    if (runtime.requestDeadlineTerminationRequested(request_ctx)) {
        try deadlineTimeout(runtime, request_ctx.exec.request_id);
        return;
    }

    var modules_ctx = runtime.modulesContext();
    const route = switch (try module_routes.ensureRouteHandler(&modules_ctx, request_ctx)) {
        .ready => |route| route,
        // The entry's evaluation (a top-level await) is still running: the
        // request waits in the module's waiter list, settlement queues it
        // again, and its armed deadline bounds the wait.
        .pending => return,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            // A sentinel fire can surface as this exception too, so the
            // worker stops once the response is written, as on the handler
            // path.
            const sentinel_fired = runtime.requestDeadlineSentinelFired(request_ctx);
            defer if (sentinel_fired) {
                runtime.stop_after_deadline_fire = true;
            };
            try response_flow.writeException(runtime, request_ctx, &owned);
            return;
        },
    };
    tracing.mark(runtime, request_ctx, "get_export_done_ns");
    try invokeHandlerAfterParse(runtime, request_ctx, route);
}

fn failInternal(runtime: *state.Runtime, request_ctx: *request_context.RequestContext, err: anyerror) void {
    const request_id = request_ctx.exec.request_id;
    // `handleLocalFailure` already keeps the boot context out; this guard
    // keeps it from the response and finish paths whatever the caller.
    if (request_id == request_context.boot_request_id) {
        std.log.err("refusing response-path failure for the boot context: {s}", .{@errorName(err)});
        return;
    }
    // A sentinel fire that unwound as an internal error, such as a
    // settlement turn trapped mid-drain, arrives with the deadline still
    // armed. The fired bit is read before the finish path disarms it, and
    // the worker stops once the 500 is written.
    const sentinel_fired = runtime.requestDeadlineSentinelFired(request_ctx);
    defer if (sentinel_fired) {
        runtime.stop_after_deadline_fire = true;
    };
    std.log.warn("request-local failure request_id={d}: {s}", .{ request_id, @errorName(err) });
    if (request_ctx.response_committed) {
        // A committed response that broke can never end its stream, so the
        // stream is reset and the server aborts the client now instead of
        // holding a truncated response open until the deadline.
        response_flow.failResponse(runtime, request_ctx, 502) catch |fail_err| {
            std.log.warn("failed to finalize committed failed request_id={d}: {s}", .{ request_id, @errorName(fail_err) });
        };
        return;
    }
    response_flow.replaceUnsentResponse(runtime, request_ctx, 500, "internal server error", .internal_error) catch |write_err| {
        std.log.warn("failed to write internal error response request_id={d}: {s}", .{ request_id, @errorName(write_err) });
        const active_request = runtime.requests.active.get(request_id) orelse return;
        if (active_request.finish_started)
            return;
        _ = response_flow.finishRequest(runtime, active_request, .internal_error, 500) catch |finish_err| {
            std.log.warn("failed to finalize internal error request_id={d}: {s}", .{ request_id, @errorName(finish_err) });
            return;
        };
    };
}

/// Answers a head that failed `request_head.fromDispatchWork` with 400 and
/// the failed check's name as the body.
fn writeRequestParseError(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    err: request_head.Error,
) !void {
    try response_flow.writeSimpleError(runtime, request_ctx, 400, @errorName(err), .bad_request);
}

fn invokeHandlerAfterParse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    route: *const module_routes.RouteModule,
) !void {
    var parsed = request_head.fromDispatchWork(&request_ctx.dispatch_work) catch |err| {
        try writeRequestParseError(runtime, request_ctx, err);
        return;
    };
    tracing.mark(runtime, request_ctx, "parse_request_done_ns");
    if (!request_ctx.body.isInitialized())
        try request_ctx.body.initFromHead(request_ctx.requestAllocator(), &parsed);

    var request_value = try request_bridge.makeRequestObject(runtime, request_ctx, &parsed);
    tracing.mark(runtime, request_ctx, "make_request_done_ns");
    defer request_value.deinit();

    try invokeHandlerOrFinish(runtime, request_ctx, route, &request_value);
}

/// Calls `handler(request, env)`, where `env` is the route's frozen bindings
/// object (`worker/modules/route_env.zig`), the same object for every request
/// of the route.
fn invokeHandlerOrFinish(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    route: *const module_routes.RouteModule,
    request_value: *const bindings.Value,
) !void {
    const token = try ensureRequestTask(runtime, request_ctx);
    var task = runtime.requests.tasks.get(token) orelse return error.RequestTaskMissing;
    task.state = .invoking_handler;

    const bench_handler = runtime.observability.bench_handler;
    var handler_started_ns: u64 = 0;
    const invocation = turn.invokeWithTiming(
        runtime.core.vm,
        request_ctx.requestAllocator(),
        &request_ctx.exec,
        route.handler.ptr(),
        null,
        &.{ request_value, route.env.inner.ptr() },
        if (bench_handler) &handler_started_ns else null,
    );
    if (bench_handler) {
        runtime.observability.metrics_view.publishBenchHandler(.{
            .request_id = request_ctx.exec.request_id,
            .worker_id = request_ctx.dispatch_work.worker_id,
            .worker_generation = request_ctx.dispatch_work.worker_generation,
            .handler_started_ns = handler_started_ns,
        });
        runtime.observability.bench_handler = false;
    }
    var result = switch (try invocation) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            task.state = .failed;
            // A sentinel that terminated this handler turn surfaces as this
            // exception, so the fired bit is read here and the worker stops
            // once the response is written.
            const sentinel_fired = runtime.requestDeadlineSentinelFired(request_ctx);
            defer if (sentinel_fired) {
                runtime.stop_after_deadline_fire = true;
            };
            try response_flow.writeException(runtime, request_ctx, &owned);
            return;
        },
    };
    tracing.mark(runtime, request_ctx, "handler_invoke_done_ns");
    var result_moved = false;
    defer if (!result_moved)
        result.deinit();

    if (try handler_thenable.isThenableValue(runtime, request_ctx, &result)) {
        runtime.observability.thenable_handler_count += 1;
        task.state = .waiting_thenable;
        task.pending_thenable = js_value.JsValueOwned.fromOwnedValue(result);
        result_moved = true;
        try handler_thenable.settleRequestThenable(runtime, request_ctx, token, task.pending_thenable.?.ptr());
        return;
    }
    runtime.observability.sync_handler_fast_path_count += 1;
    task.state = .completed_sync;
    try response_bridge.writeValueResponse(runtime, request_ctx, &result, response_flow.writeAndFinishResponse);
}

fn ensureRequestTask(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !request_task.TaskToken {
    if (request_ctx.request_task) |token|
        return token;
    // Every live request needs a live slot on the shared page, so the worker
    // admits at most `LIVE_SLOT_COUNT` at once. The server sends a worker at
    // most `worker_concurrency_max` requests at a time
    // (`common/limits/server.zig`), pinned equal to that count in
    // `tests/contracts/limits.zig`, and the worker still checks it instead of
    // trusting the server. Two requests can share the VM because
    // each microtask runs under the request that registered it, which
    // `runtime/patches/webkit/0004-microtask-owner-context.patch` carries
    // from registration to execution (`worker/tests/runtime/multiplexing.zig`
    // covers it).
    if (runtime.requests.tasks.activeCount() >= worker_shared_page.LIVE_SLOT_COUNT)
        return error.RequestSlotsExhausted;
    const token = try runtime.requests.tasks.create(.{
        .request_id = request_ctx.exec.request_id,
        .request_generation = request_ctx.request_generation,
        .request_ctx = request_ctx,
        .deadline_ns = request_ctx.exec.deadline_monotonic_ns,
        .trace = if (request_ctx.trace_enabled) &request_ctx.trace else null,
    });
    request_ctx.request_task = token;
    return token;
}
