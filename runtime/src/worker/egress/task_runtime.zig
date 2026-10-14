//! Fetch task bookkeeping: stopping a fetch at the gateway, cancellation,
//! an evaluation's reap, publishing a task's answer and destroying a task.
//! Runs on the worker's VM thread. Body storage belongs to `body/`, and
//! packet I/O to `gateway_control.zig` and `gateway_runtime.zig`. A request's
//! fetch count lives in its own context (`RequestContext.egress_fetches_started`),
//! so nothing here gives a fetch back to it.

const std = @import("std");
const bindings = @import("collo_bindings");
const Runtime = @import("../runtime/root.zig").Runtime;
const task_mod = @import("task.zig");
const fetch_body_runtime = @import("body/root.zig");
const gateway_control = @import("gateway_control.zig");

const FetchResult = task_mod.Result;
const FetchTask = task_mod.Task;

/// The failure a fetch stopped before the gateway answered rejects with.
pub const aborted_message = "fetch aborted";

/// Stops the fetch `fetch_id` at the gateway, the one way the worker does:
/// at most one stop per fetch, and none for a fetch the gateway holds
/// nothing of. A fetch whose terminal packet the worker already read, or
/// whose session went, is not counted and needs nothing. A fetch whose start
/// never left the worker, parked on a full ring, has nothing at the gateway
/// to answer for it, so it ends here and its task, if it still has one,
/// fails as aborted from the ready queue.
pub fn stopFetch(runtime: *Runtime, fetch_id: u64) void {
    const state = &runtime.egress.state;
    const fetch = state.fetches.getPtr(fetch_id) orelse return;
    if (fetch.start_sent) {
        if (fetch.stop_sent)
            return;
        fetch.stop_sent = true;
        gateway_control.sendStop(runtime, fetch_id);
        return;
    }
    state.endFetch(fetch_id);
    if (state.tasks.get(fetch_id)) |task| {
        task.canceled = true;
        publishResult(runtime, task, .{ .failure = .{ .message = aborted_message } });
    }
}

/// Cancels every task of `request_id` (`cancelTask`), for request cleanup.
pub fn cancelForRequest(runtime: *Runtime, request_id: u64) void {
    var iterator = runtime.egress.state.tasks.valueIterator();
    while (iterator.next()) |task| {
        if (task.*.request_id == request_id)
            cancelTask(runtime, task.*);
    }
}

/// Marks `task` canceled and stops its fetch. A canceled task ends when its
/// completion runs (`completion_runtime.execute`): its promise is rejected
/// while its request is still active, and once the request is gone the task
/// is destroyed without running JavaScript. The gateway's acknowledgment of
/// the stop queues that completion, or `stopFetch` does for a start that
/// never left.
fn cancelTask(runtime: *Runtime, task: *FetchTask) void {
    task.canceled = true;
    stopFetch(runtime, task.id);
}

/// Destroys every task of `request_id` in place, for an evaluation's close
/// (`Runtime.closeEvaluation` in `runtime/evaluations.zig`). That context is
/// discarded natively, so no JavaScript can observe these promises. Each
/// task's response body leaves the table with it, which stops a fetch still
/// open (`destroyTask`). A completion already queued then finds no task,
/// which `completion_runtime.handleFailure` only logs, and a gateway head
/// that arrives later finds no task and is ignored. Live requests use
/// `cancelForRequest`, whose tasks go when their completion finds the
/// request gone.
pub fn reapForRequest(runtime: *Runtime, request_id: u64) void {
    while (true) {
        var reaped: ?*FetchTask = null;
        var iterator = runtime.egress.state.tasks.valueIterator();
        while (iterator.next()) |task| {
            if (task.*.request_id == request_id) {
                reaped = task.*;
                break;
            }
        }
        destroyTask(runtime, reaped orelse return);
    }
}

/// Aborts fetch `fetch_id` for JavaScript and takes ownership of `reason`. A
/// task still waiting keeps `reason` for its rejection and is canceled
/// (`cancelTask`). Once the task is gone its head arrived, so the fetch's
/// bodies take the reason and the fetch is stopped once
/// (`body/cleanup.zig:cancelForFetch`).
pub fn cancel(runtime: *Runtime, fetch_id: u64, reason: ?bindings.Value) void {
    if (runtime.egress.state.tasks.get(fetch_id)) |task| {
        if (reason) |value| {
            var owned = value;
            task.setAbortReason(&owned);
        }
        cancelTask(runtime, task);
    } else {
        fetch_body_runtime.cancelForFetch(runtime, fetch_id, reason);
    }
    runtime.wake();
}

/// Stores `result` as the task's answer and queues its completion; a task
/// that already has an answer drops `result`. A task queues one completion
/// for its life, so the tasks bound the completion items
/// (`fetch_runtime.schedule`).
pub fn publishResult(runtime: *Runtime, task: *FetchTask, result: FetchResult) void {
    if (task.done)
        return;
    std.debug.assert(task.result == null);
    std.debug.assert(!task.ready_queued);
    task.result = result;
    task.done = true;
    task.ready_queued = true;
    runtime.queueReadyWork(.{ .fetch_completion = task.id }, task.ready_at_mono_ns);
}

pub const ByteDirection = enum { sent, received };

/// Adds `bytes` of fetch `fetch_id`'s body to the record of the request that
/// started it: the inline body and upload chunks the worker sent, or the
/// body-pool extents it received, as the pool holds them. A fetch the table
/// no longer counts, or a request that ended or moved to a new generation,
/// takes nothing, so bytes never enter another request's record.
pub fn chargeFetchBytes(runtime: *Runtime, fetch_id: u64, direction: ByteDirection, bytes: u64) void {
    const fetch = runtime.egress.state.fetches.get(fetch_id) orelse return;
    const request = runtime.requests.active.get(fetch.request_id) orelse return;
    if (request.request_generation != fetch.request_generation)
        return;
    switch (direction) {
        .sent => request.fetch_sent_bytes += bytes,
        .received => request.fetch_received_bytes += bytes,
    }
}

/// Removes `task` from the table and frees it, its result and its deferred,
/// leaving its promise unsettled unless the caller settled it. Its response
/// body view leaves the table too (`body/cleanup.zig:release`), which stops
/// the fetch when that view was the last that could read an open body. A
/// completion still queued keeps its place counted until it pops
/// (`State.completion_ready_orphans`).
pub fn destroyTask(runtime: *Runtime, task: *FetchTask) void {
    const state = &runtime.egress.state;
    // Out of the table first: a stop that reaches a start that never left
    // then ends the fetch without publishing to this task.
    _ = state.tasks.remove(task.id);
    if (task.ready_queued)
        state.completion_ready_orphans += 1;
    _ = fetch_body_runtime.release(runtime, task.response_body_identity);
    task.deinit(runtime.core.allocator);
    runtime.core.allocator.destroy(task);
}
