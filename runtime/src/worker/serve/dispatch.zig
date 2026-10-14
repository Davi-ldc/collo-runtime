//! Runs a dispatched request: checks its head, builds the handler's
//! `Request`, calls `handler(request, env)` and answers with what the
//! handler returns or throws. It also owns the request's failure paths: a
//! client reset, a deadline and a local error each end the request with a
//! response or a reset, and a begin that reached a retiring worker answers
//! 503 without running JavaScript (`termination.zig` owns those answers and
//! how an exception becomes one). It runs on the worker's VM thread.
//!
//! The server chose the route from the request path and names it in the
//! dispatch by its index in the definition's route table
//! (`DispatchWork.route_index`), so the worker serves every request with that
//! route's handler, in that route's realm, and never compares the request's
//! authority or path with a name of its own.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
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
const response_flow = @import("response.zig");
const termination = @import("termination.zig");
const module_routes = @import("../modules/routes.zig");

/// Starts the request's run. A request already answered, as one the
/// worker ended while its begin waited in the queue, is gone or finishing,
/// and its item does nothing.
pub fn execute(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    request_ctx.dispatch_queued = false;
    if (request_ctx.finish_started)
        return;
    if (request_ctx.client_reset) {
        try cancelClientReset(runtime, request_id);
        return;
    }
    request_ctx.dispatch_started = true;
    if (request_ctx.arrived_retiring) {
        // The server may already be replacing this worker, and the VM may
        // be unable to run the handler, so none of its JavaScript runs and
        // the 503 lets the client retry elsewhere.
        try termination.end(runtime, request_ctx, .worker_retiring);
        return;
    }
    executeLoaded(runtime, request_ctx) catch |err|
        handleLocalFailure(runtime, request_id, err);
}

pub fn executeBodyReady(runtime: *state.Runtime, request_id: u64) !void {
    try body_read.executeReady(runtime, request_id);
}

/// The client reset the stream: the request ends as client-closed and no
/// response is written. A request that finished while its last packet
/// waits for room ends without that packet, which no client would receive.
pub fn cancelClientReset(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    request_ctx.cancel_queued = false;
    if (request_ctx.last_packet_done != null) {
        try response_flow.dropParkedLast(runtime, request_ctx, .client_closed, 499);
        return;
    }
    request_ctx.client_reset = true;
    request_ctx.body.pipe.fail("http2 stream reset");
    if (request_ctx.request_task) |token| {
        if (runtime.requests.tasks.get(token)) |task| {
            task.canceled = true;
            task.state = .canceled;
        }
    }
    _ = try response_flow.finishRequest(runtime, request_ctx, .client_closed, 499, .none);
}

/// The request's deadline passed. It answers 504 in place of a response
/// whose head has not gone out, or ends a committed response with that
/// status; a request that reached another ending first, as a fire for
/// another owner, answers that one (`termination.endingOf`).
pub fn deadlineTimeout(runtime: *state.Runtime, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    if (!request_ctx.deadline_armed and !request_ctx.deadline_due_queued)
        return;
    // A top-level await still pending past its budget pins its route failed
    // and nothing else (`expireRouteEvaluations`). A deadline is the wake
    // that finds it: an evaluation's, armed to its routes' budget, reaches
    // its routes even when no request waits, and a parked request's reaches
    // its own route sooner.
    runtime.expireRouteEvaluations();
    if (request_context.isEvaluationId(request_id)) {
        // An evaluation's deadline is its routes' budget, and it has no
        // client stream to answer. Its routes have expired by now, so the
        // expiry above has closed it, which frees `request_ctx`. One still
        // open is armed again at its routes' deadline.
        runtime.armEvaluationBudget(request_id) catch |err|
            std.log.warn("evaluation budget re-arm failed evaluation_id={d}: {s}", .{
                request_id,
                @errorName(err),
            });
        return;
    }
    try termination.end(runtime, request_ctx, termination.endingOf(runtime, request_ctx) orelse .deadline);
}

/// The funnel for an error a request's work returned. A failure that already
/// stopped the worker, as a `request_done` it could not send
/// (`response_finish.zig`), leaves the server to end the requests in flight;
/// any other error ends the request with a 500, or with a reset when its
/// response is already committed.
pub fn handleLocalFailure(runtime: *state.Runtime, request_id: u64, err: anyerror) void {
    if (!runtime.core.running) {
        std.log.warn("request-local failure after worker stop request_id={d}: {s}", .{
            request_id,
            @errorName(err),
        });
        return;
    }
    // An evaluation or the worker owner has no response path. `failInternal`
    // would send frames with a zeroed dispatch identity, publish a record for
    // no request and destroy an evaluation while its top-level fetches and
    // timers still need it. The failed operation already reached JavaScript
    // as a rejection, so the error is only logged; at warn, because a test
    // exercises this guard and the test runner fails a run on any err line.
    if (request_context.isReservedId(request_id)) {
        std.log.warn("work of an owner with no response path failed owner_id={d}: {s}", .{
            request_id,
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
/// token that no longer names the waiting task is stale and ignored.
pub fn executeCompletion(runtime: *state.Runtime, token: request_task.TaskToken) !void {
    const task = runtime.requests.tasks.get(token) orelse return;
    task.completion_queued = false;
    const request_id = task.request_id;
    const removed = runtime.requests.pending_completions.fetchRemove(request_id) orelse return error.RequestCompletionNotFound;
    var completion = removed.value;
    defer completion.deinit();
    if (completion.token.slot != token.slot or completion.token.generation != token.generation)
        return;

    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    if (task.state != .waiting_thenable or task.canceled or task.timed_out)
        return;
    if (task.pending_thenable) |*pending| {
        pending.deinit();
        task.pending_thenable = null;
    }
    if (termination.endingOf(runtime, request_ctx)) |ending| {
        task.timed_out = true;
        try termination.end(runtime, request_ctx, ending);
        return;
    }
    task.state = .extracting_response;
    if (completion.is_error) {
        task.state = .failed;
        try termination.answerException(runtime, request_ctx, &completion.value, "js exception");
    } else {
        try response_bridge.writeValueResponse(runtime, request_ctx, &completion.value);
    }
}

fn executeLoaded(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !void {
    try runtime.armRequestDeadline(request_ctx);
    if (termination.endingOf(runtime, request_ctx)) |ending| {
        try termination.end(runtime, request_ctx, ending);
        return;
    }

    const route = switch (try runtime.lookupRouteHandler(request_ctx)) {
        .ready => |route| route,
        // The entry's evaluation (a top-level await) is still running: the
        // request waits in the module's waiter list, settlement queues it
        // again, and its armed deadline bounds the wait.
        .pending => return,
    };
    try invokeHandlerAfterParse(runtime, request_ctx, route);
}

fn failInternal(runtime: *state.Runtime, request_ctx: *request_context.RequestContext, err: anyerror) void {
    const request_id = request_ctx.exec.request_id;
    // `handleLocalFailure` already keeps every owner without a response path
    // out; this guard keeps an evaluation from the response and finish paths
    // whatever the caller.
    if (request_context.isReservedId(request_id)) {
        std.log.err("refusing response-path failure for owner_id={d}: {s}", .{ request_id, @errorName(err) });
        return;
    }
    std.log.warn("request-local failure request_id={d}: {s}", .{ request_id, @errorName(err) });
    // A termination can surface as an internal error, such as a settlement
    // turn trapped mid-drain, so a request that reached an ending answers it
    // instead of a 500 or a 502.
    if (termination.endingOf(runtime, request_ctx)) |ending| {
        termination.end(runtime, request_ctx, ending) catch |end_err| {
            std.log.warn("failed to end request request_id={d}: {s}", .{ request_id, @errorName(end_err) });
            finishAfterFailedAnswer(runtime, request_id, .internal_error, 500);
        };
        return;
    }
    if (request_ctx.response_committed) {
        // A committed response that broke can never end its stream, so the
        // stream is reset and the server aborts the client now instead of
        // holding a truncated response open until the deadline.
        response_flow.failResponse(runtime, request_ctx, .internal_error, 502) catch |fail_err| {
            std.log.warn("failed to finalize committed failed request_id={d}: {s}", .{ request_id, @errorName(fail_err) });
        };
        return;
    }
    response_flow.replaceUnsentResponse(runtime, request_ctx, 500, "internal server error", .internal_error) catch |write_err| {
        std.log.warn("failed to write internal error response request_id={d}: {s}", .{ request_id, @errorName(write_err) });
        finishAfterFailedAnswer(runtime, request_id, .internal_error, 500);
    };
}

/// Finishes a request whose answer could not be written, so the server
/// still gets its completion; does nothing once its finish started.
fn finishAfterFailedAnswer(
    runtime: *state.Runtime,
    request_id: u64,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) void {
    const active_request = runtime.requests.active.get(request_id) orelse return;
    if (active_request.finish_started)
        return;
    _ = response_flow.finishRequest(runtime, active_request, done_status, http_status, .none) catch |finish_err| {
        std.log.warn("failed to finalize failed request request_id={d}: {s}", .{ request_id, @errorName(finish_err) });
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
    route: module_routes.ReadyRoute,
) !void {
    var parsed = request_head.fromDispatchWork(&request_ctx.dispatch_work) catch |err| {
        try writeRequestParseError(runtime, request_ctx, err);
        return;
    };
    if (!request_ctx.body.isInitialized())
        try request_ctx.body.initFromHead(request_ctx.requestAllocator(), &parsed);

    // Built in the route's realm, so `request instanceof Request` holds in
    // the handler whichever realm the route runs in.
    var request_value = try request_bridge.makeRequestObject(route.realm, request_ctx, &parsed);
    defer request_value.deinit();

    try invokeHandlerOrFinish(runtime, request_ctx, route, &request_value);
}

/// Calls `handler(request, env)` in the route's realm, where `env` is the
/// route's frozen bindings object (`worker/modules/route_env.zig`), the same
/// object for every request of the route, and `this` is the handler's
/// receiver: the default export when the handler is its `fetch`, else
/// undefined (`RouteHandler` in `worker/runtime/types.zig`). No third
/// argument follows, since the worker offers no execution context object.
fn invokeHandlerOrFinish(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    route: module_routes.ReadyRoute,
    request_value: *const bindings.Value,
) !void {
    const token = try ensureRequestTask(runtime, request_ctx);
    var task = runtime.requests.tasks.get(token) orelse return error.RequestTaskMissing;
    task.state = .invoking_handler;

    const bench_handler = runtime.observability.bench_handler;
    var handler_started_ns: u64 = 0;
    const handler = &route.module.handler;
    const invocation = turn.invokeWithTiming(
        runtime.core.vm,
        route.realm,
        request_ctx.requestAllocator(),
        &request_ctx.exec,
        handler.function.ptr(),
        if (handler.receiver) |*receiver| receiver.inner.ptr() else null,
        &.{ request_value, route.module.env.inner.ptr() },
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
            try termination.answerException(runtime, request_ctx, &owned, "js exception");
            return;
        },
    };
    var result_moved = false;
    defer if (!result_moved)
        result.deinit();

    if (try handler_thenable.isThenableValue(runtime, request_ctx, &result)) {
        task.state = .waiting_thenable;
        task.pending_thenable = js_value.JsValueOwned.fromOwnedValue(result);
        result_moved = true;
        try handler_thenable.settleRequestThenable(runtime, request_ctx, token, task.pending_thenable.?.ptr());
        return;
    }
    task.state = .completed_sync;
    try response_bridge.writeValueResponse(runtime, request_ctx, &result);
}

fn ensureRequestTask(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !request_task.TaskToken {
    if (request_ctx.request_task) |token|
        return token;
    // The worker runs at most `request_task_capacity` handlers at once, one
    // per live slot of its page (`common/limits/worker.zig`). Each request it
    // holds has a pool slot of its own, since a begin on a held one is
    // refused (`request/ingress/runtime.zig:requireUnheld`), so a runtime
    // with the default capacity always finds a task; one built with less, as
    // a test may build, answers the begin past it 500. Requests can share the
    // VM because each microtask runs under the request that registered it,
    // which `runtime/patches/webkit/0004-microtask-owner-context.patch`
    // carries from registration to execution
    // (`worker/tests/runtime/multiplexing.zig` covers it).
    if (runtime.requests.tasks.activeCount() >= runtime.core.limits.request_task_capacity)
        return error.RequestSlotsExhausted;
    const token = try runtime.requests.tasks.create(.{
        .request_id = request_ctx.exec.request_id,
        .request_generation = request_ctx.request_generation,
        .request_ctx = request_ctx,
        .deadline_ns = request_ctx.exec.deadline_monotonic_ns,
    });
    request_ctx.request_task = token;
    return token;
}
