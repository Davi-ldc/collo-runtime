//! Fetch task bookkeeping: cancellation, an evaluation's reap, and
//! publishing a task's result to the ready queue. Runs on the worker's event
//! loop thread. Body storage belongs to `body/`, and packet I/O to
//! `gateway_control.zig` and `gateway_runtime.zig`. A request's fetch count
//! lives in its own context (`RequestContext.egress_fetches_started`), so
//! nothing here gives a fetch back to it.

const std = @import("std");
const bindings = @import("collo_bindings");
const egress_context = @import("context.zig");
const task_mod = @import("task.zig");
const fetch_body_runtime = @import("body/root.zig");
const gateway_control = @import("gateway_control.zig");

const FetchResult = task_mod.Result;
const FetchTask = task_mod.Task;

/// Cancels every task of `request_id` (`cancelTask`), for request cleanup.
pub fn cancelForRequest(runtime: *egress_context.Context, request_id: u64) void {
    var iterator = runtime.egress_state.tasks.iterator();
    while (iterator.next()) |entry| {
        const task = entry.value_ptr.*;
        if (task.request_id == request_id)
            cancelTask(runtime, task, "request canceled");
    }
}

/// Marks `task` canceled, the one way a task is canceled. A canceled task
/// ends when its completion runs (`completion_runtime.execute`): its promise
/// is rejected while its request is still active, and once the request is
/// gone the task is destroyed without running JS. A task whose start is in
/// the gateway's command ring is told to stop, and the gateway's answer
/// queues that completion. A task whose start never left, parked on a full
/// ring, has nothing at the gateway to answer for it, and a cancel would
/// only cost the session a strike for a fetch it never heard of, so it
/// publishes its own failure and its completion runs from the ready queue.
fn cancelTask(runtime: *egress_context.Context, task: *FetchTask, gateway_reason: []const u8) void {
    task.markCanceled();
    if (task.start_sent) {
        gateway_control.sendCancel(runtime, task.id, gateway_reason);
        return;
    }
    publishResult(runtime, task, .{ .failure = .{ .message = "fetch aborted", .owned = false } });
}

/// Destroys every task of `request_id` in place, for an evaluation's close
/// (`Runtime.closeEvaluation` in `runtime/evaluations.zig`). That context is
/// discarded natively, so no JS can observe these promises, and the gateway
/// may never send a completion for a canceled fetch to destroy its task. A
/// completion already queued then finds no task, which
/// `completion_runtime.handleFailure` only logs, and a gateway head that
/// arrives later finds no task and is ignored. Live requests use
/// `cancelForRequest`, whose tasks go when their completion finds the request
/// gone.
pub fn reapForRequest(runtime: *egress_context.Context, request_id: u64) void {
    while (true) {
        var reap_id: ?u64 = null;
        var iterator = runtime.egress_state.tasks.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.request_id == request_id) {
                reap_id = entry.key_ptr.*;
                break;
            }
        }
        const fetch_id = reap_id orelse return;
        const removed = runtime.egress_state.tasks.fetchRemove(fetch_id) orelse return;
        const task = removed.value;
        // A start that never left has nothing at the gateway to stop.
        if (task.start_sent)
            gateway_control.sendCancel(runtime, task.id, "evaluation closed");
        if (task.result) |*stale_result| {
            stale_result.deinit();
            task.result = null;
        }
        _ = fetch_body_runtime.release(runtime, task.response_body_identity);
        task.deinit(runtime.allocator);
        runtime.allocator.destroy(task);
    }
}

/// Aborts fetch `fetch_id` for JS and takes ownership of `reason`. A task
/// still waiting keeps `reason` for its rejection and is canceled
/// (`cancelTask`), so a fetch whose start never left rejects at once. Once
/// the task is gone its head arrived, so the gateway is asked to stop the
/// body it still streams, and the reason goes to the fetch's bodies.
pub fn cancel(runtime: *egress_context.Context, fetch_id: u64, reason: ?bindings.Value) void {
    var owned_reason = reason;
    defer if (owned_reason) |*value|
        value.deinit();

    if (runtime.egress_state.tasks.get(fetch_id)) |task| {
        if (owned_reason) |*value| {
            task.setAbortReason(value);
            owned_reason = null;
        }
        cancelTask(runtime, task, "fetch aborted");
    } else {
        gateway_control.sendCancel(runtime, fetch_id, "fetch aborted");
        // `cancelForFetch` takes ownership of the reason.
        fetch_body_runtime.cancelForFetch(runtime, fetch_id, owned_reason);
        owned_reason = null;
    }
    runtime.wake();
}

/// Stores `result` as the task's answer and queues its completion; a task that
/// already has an answer drops `result`. When the ready queue is full, the
/// completion is left to `collectCompleted`.
pub fn publishResult(runtime: *egress_context.Context, task: *FetchTask, result: FetchResult) void {
    var owned_result = result;
    if (task.done) {
        owned_result.deinit();
        return;
    }
    std.debug.assert(task.result == null);
    task.result = owned_result;
    task.done = true;
    if (!task.queued) {
        task.queued = true;
        if (!runtime.tryQueueReadyReadySince(
            .{ .fetch_completion = task.id },
            task.ready_at_mono_ns,
        )) {
            task.queued = false;
            std.log.warn("failed to queue fetch completion fetch_id={d}: {s}", .{
                task.id,
                "QueueFull",
            });
        }
    }
}

/// Rescans the tasks after a full ready queue dropped a completion, queueing
/// each answered task not yet queued. It stops at the next full queue and
/// leaves the rescan flag set.
pub fn collectCompleted(runtime: *egress_context.Context) !void {
    if (!runtime.egress_state.fetch_task_rescan_needed)
        return;
    runtime.egress_state.fetch_task_rescan_needed = false;

    var iterator = runtime.egress_state.tasks.iterator();
    while (iterator.next()) |entry| {
        const task = entry.value_ptr.*;
        const ready = task.done and !task.queued;
        if (ready)
            task.queued = true;

        if (ready) {
            if (!runtime.tryQueueReadyReadySince(
                .{ .fetch_completion = task.id },
                task.ready_at_mono_ns,
            )) {
                task.queued = false;
                runtime.egress_state.fetch_task_rescan_needed = true;
                return;
            }
        }
    }
}
