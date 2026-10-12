//! How the worker ends a request with an answer of its own instead of the
//! handler's: when the request passed its wall deadline or spent its CPU
//! budget, when a termination the sentinel fired for another owner poisoned
//! the VM under it, or when its begin reached a worker that had already
//! asked to retire. It also owns the one rule that turns a JavaScript
//! exception into a response (`answerException`): the ending first, then the
//! tenant's log and 500 `js_exception`. Runs on the worker's VM thread.
//!
//! | Ending | Answer | Done status |
//! | --- | --- | --- |
//! | `deadline` | 504 | `deadline_timeout` |
//! | `cpu` | 503 "cpu limit exceeded" | `cpu_exceeded` |
//! | `worker_stopped` | 503, nothing in the tenant's log | `worker_stopped` |
//! | `worker_retiring` | 503, no JavaScript runs | `worker_retiring` |
//!
//! A response whose head already went out cannot be answered anew, so its
//! stream is reset and the request finishes with the ending's status.
//! Every ending of a dispatched request but `cpu` at a boundary follows a
//! state the request cannot leave: the sentinel's fire cannot be undone
//! (`runtime/sentinel.zig`) and a passed deadline stays passed. A boundary
//! `cpu` ending leaves the VM healthy, so the worker keeps serving.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const exception_log = @import("collo_worker_js").exception_log;
const request_context = @import("collo_worker_request").context;
const worker_shared_page = @import("collo_worker_state").page;
const response_flow = @import("response.zig");
const sentinel_mod = @import("../runtime/sentinel.zig");
const state = @import("../runtime/root.zig");

pub const Ending = enum {
    deadline,
    cpu,
    worker_stopped,
    worker_retiring,
};

const Answer = struct {
    http_status: u16,
    done_status: ipc.RequestDoneStatus,
    body: []const u8,
    /// Why a request body still arriving fails, which a read waiting on it
    /// rejects with.
    body_failure: []const u8,
};

fn answerOf(ending: Ending) Answer {
    return switch (ending) {
        .deadline => .{
            .http_status = 504,
            .done_status = .deadline_timeout,
            .body = "gateway timeout",
            .body_failure = "request deadline exceeded",
        },
        .cpu => .{
            .http_status = 503,
            .done_status = .cpu_exceeded,
            .body = "cpu limit exceeded",
            .body_failure = "request cpu limit exceeded",
        },
        .worker_stopped => .{
            .http_status = 503,
            .done_status = .worker_stopped,
            .body = "service unavailable",
            .body_failure = "worker stopped",
        },
        .worker_retiring => .{
            .http_status = 503,
            .done_status = .worker_retiring,
            .body = "service unavailable",
            .body_failure = "worker retiring",
        },
    };
}

/// The ending a dispatched request has reached, or null while it may run:
/// the sentinel's fire for this request, with its cause; its CPU budget,
/// spent at a boundary; its armed wall deadline, passed; its begin crossing
/// the worker's retiring notice, so none of its JavaScript may run; or a
/// fire for another owner, which left the VM unable to run this request's
/// JavaScript. The request's own reasons come first, so a request past its
/// own deadline answers 504 whoever's fire stopped it, and a begin that
/// arrived after the notice answers `worker_retiring` even when a fire
/// caused the notice.
pub fn endingOf(runtime: *state.Runtime, request_ctx: *const request_context.RequestContext) ?Ending {
    const fired = runtime.observability.sentinel.fired();
    if (fired) |record| {
        if (record.owner_id == request_ctx.exec.request_id)
            return endingOfCause(record.cause);
    }
    if (request_ctx.cpu_spent)
        return .cpu;
    if (request_ctx.deadline_armed and runtime.nowMonoNs() >= request_ctx.exec.deadline_monotonic_ns)
        return .deadline;
    if (request_ctx.arrived_retiring)
        return .worker_retiring;
    if (fired != null)
        return .worker_stopped;
    return null;
}

fn endingOfCause(cause: sentinel_mod.Cause) Ending {
    return switch (cause) {
        .deadline => .deadline,
        .cpu => .cpu,
    };
}

/// Ends the dispatched request `request_ctx` with `ending`'s answer; does
/// nothing once its finish started. Its deadline is disarmed first, so the
/// sentinel watches no deadline of a request that is being answered, and a
/// body still arriving fails, so a read waiting on it settles in the
/// finish's cleanup. A response whose head went out is reset at once with
/// the ending's statuses (`response.zig:failResponse`), which runs no
/// JavaScript for these done statuses; left to finish, its completion would
/// park on the server until the request's grace backstop.
pub fn end(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    ending: Ending,
) !void {
    std.debug.assert(!request_context.isReservedId(request_ctx.exec.request_id));
    if (request_ctx.finish_started)
        return;
    const answer = answerOf(ending);
    runtime.disarmRequestDeadline(request_ctx);
    if (!request_ctx.body.isComplete())
        request_ctx.body.pipe.fail(answer.body_failure);
    if (request_ctx.response_committed) {
        try response_flow.failResponse(runtime, request_ctx, answer.done_status, answer.http_status);
        return;
    }
    try response_flow.replaceUnsentResponse(
        runtime,
        request_ctx,
        answer.http_status,
        answer.body,
        answer.done_status,
    );
}

/// The one rule for a JavaScript `exception` that ended a request's turn,
/// whether its handler threw, its thenable rejected or its Response's
/// extraction threw: a request that reached an ending answers that ending,
/// since a termination surfaces as an exception the tenant's code did not
/// throw; any other exception is the tenant's, written to its log under the
/// request's id with `context`, and answers 500 `js_exception`.
/// `exception` stays the caller's.
pub fn answerException(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    exception: *const bindings.Value,
    context: []const u8,
) !void {
    if (endingOf(runtime, request_ctx)) |ending| {
        try end(runtime, request_ctx, ending);
        return;
    }
    exception_log.logException(runtime.core.vm, request_ctx.exec.request_id, exception, context);
    var response = response_flow.Response{ .status = 500, .body = .{ .bytes = "internal server error" } };
    try response_flow.writeAndFinishResponse(runtime, request_ctx, &response, .js_exception, 500);
}

/// Answers every dispatched request the sentinel's fire left unable to
/// finish, once the loop first sees the fire (`checkRetirement` in
/// `runtime/retirement.zig`): the fired owner, when it is a request, by the
/// fire's cause, and every other request whose answer still needs its
/// JavaScript with `worker_stopped`, so none of them waits for its own
/// deadline on a VM that will never run it. A request whose response is
/// already decided (its head sent, a body streaming from a fetch, a step
/// parked in its outbox) is left to finish without JavaScript. A failure is
/// handled per request (`handleLocalFailure` in `dispatch.zig`).
pub fn endAfterFire(runtime: *state.Runtime, fired: sentinel_mod.Fired) void {
    var ids: [worker_shared_page.LIVE_SLOT_COUNT]u64 = undefined;
    var count: usize = 0;
    var iterator = runtime.requests.active.iterator();
    while (iterator.next()) |entry| {
        const request_ctx = entry.value_ptr.*;
        if (request_context.isReservedId(request_ctx.exec.request_id))
            continue;
        if (request_ctx.finish_started)
            continue;
        if (request_ctx.exec.request_id != fired.owner_id and responseDecided(request_ctx))
            continue;
        // A dispatched request holds a live slot, and the page has
        // `LIVE_SLOT_COUNT` of them, so the array cannot overflow.
        std.debug.assert(count < ids.len);
        ids[count] = request_ctx.exec.request_id;
        count += 1;
    }
    // Ending a request removes it from the active map, so the ids are taken
    // first and each is looked up again.
    for (ids[0..count]) |request_id|
        endById(runtime, request_id);
}

/// Answers `cpu` for every active request a window's charge took past its
/// CPU budget since the last call (`owner.zig` marks them), outside every
/// owner window, so no JavaScript of theirs runs in between and the VM is
/// left as it is. The loop calls it after each work item and each collect
/// pass.
pub fn endSpentBudgets(runtime: *state.Runtime) void {
    if (!runtime.owners.budget_overrun_pending)
        return;
    runtime.owners.budget_overrun_pending = false;
    var ids: [worker_shared_page.LIVE_SLOT_COUNT]u64 = undefined;
    var count: usize = 0;
    var iterator = runtime.requests.active.iterator();
    while (iterator.next()) |entry| {
        const request_ctx = entry.value_ptr.*;
        if (!request_ctx.cpu_spent or request_ctx.finish_started)
            continue;
        if (request_context.isReservedId(request_ctx.exec.request_id))
            continue;
        std.debug.assert(count < ids.len);
        ids[count] = request_ctx.exec.request_id;
        count += 1;
    }
    for (ids[0..count]) |request_id|
        endById(runtime, request_id);
}

/// Answers the owner of a work item about to run instead of running its
/// JavaScript, when that owner is a dispatched request that reached an
/// ending (`executeWorkItem` in `scheduler/loop.zig`). The item still runs
/// afterwards and finds its request finished, which releases what it held.
pub fn endAtBoundary(runtime: *state.Runtime, owner_id: u64) void {
    if (request_context.isReservedId(owner_id))
        return;
    const request_ctx = runtime.requests.active.get(owner_id) orelse return;
    if (request_ctx.finish_started)
        return;
    const ending = endingOf(runtime, request_ctx) orelse return;
    end(runtime, request_ctx, ending) catch |err|
        runtime.handleRequestFailure(owner_id, err);
}

/// Ends request `request_id` with the ending it reached, `worker_stopped`
/// when it reached none: its caller found it unable to run.
fn endById(runtime: *state.Runtime, request_id: u64) void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    const ending = endingOf(runtime, request_ctx) orelse .worker_stopped;
    end(runtime, request_ctx, ending) catch |err|
        runtime.handleRequestFailure(request_id, err);
}

/// Whether the response of `request_ctx` can reach its end without running
/// JavaScript: its head went out or its body streams from a fetch, or a
/// step of it waits in its outbox for the flush, and no body stream still
/// needs a read, which a poisoned VM can never give.
fn responseDecided(request_ctx: *const request_context.RequestContext) bool {
    if (request_ctx.response_stream.needsJavaScript())
        return false;
    if (request_ctx.response_committed)
        return true;
    if (request_ctx.response_stream == .fetch)
        return true;
    return !request_ctx.response_outbox.isEmpty();
}
