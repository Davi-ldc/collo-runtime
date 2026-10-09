//! Recognizes a handler's returned thenable and arranges for the request's
//! task to complete when it settles, both in a turn on the request's
//! `ExecCtx` (`worker/js/jsc/turn.zig`). Runs in the worker on the VM thread.
//!
//! The settlement returns with the completion token built here: the task's
//! slot and generation, which key the request task table, and the request's
//! id and generation. `worker/request/completion.zig` compares all four
//! before it queues the settled value, so a settlement that outlives its
//! task or its request is counted as stale and answers no other request.

const bindings = @import("collo_bindings");
const request_context = @import("collo_worker_request").context;
const request_task = @import("collo_worker_request").task;
const state = @import("../runtime/root.zig");
const turn = @import("collo_worker_js").turn;

/// Whether `value`, borrowed, has a callable `then`. Fails as
/// `turn.isThenable` does, since reading `then` can run a getter.
pub fn isThenableValue(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    value: *const bindings.Value,
) !bool {
    return turn.isThenable(runtime.core.vm, &request.exec, value);
}

/// Completes the task `token` names when `value`, borrowed, settles. Fails
/// as `turn.settleRequestThenable` does.
pub fn settleRequestThenable(
    runtime: *state.Runtime,
    request: *request_context.RequestContext,
    token: request_task.TaskToken,
    value: *const bindings.Value,
) !void {
    try turn.settleRequestThenable(runtime.core.vm, &request.exec, completionToken(request, token), value);
}

fn completionToken(
    request: *const request_context.RequestContext,
    token: request_task.TaskToken,
) bindings.RequestCompletionToken {
    return .{
        .slot = token.slot,
        .generation = token.generation,
        .request_id = request.exec.request_id,
        .request_generation = request.request_generation,
    };
}
