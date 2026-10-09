//! Hands a handler's settled thenable back to its request. The bridge
//! reports the settlement through `collo_runtime_complete_request_task`
//! (`worker/host/completion.zig`), `schedule` checks it against the request
//! task table and parks the value, and a `request_completion` work item
//! later writes the response (`executeCompletion` in `serve/dispatch.zig`).
//! Runs on the worker's VM thread; the runtime holds the pending map, keyed
//! by request id.
//!
//! A request has at most one pending completion, because its task
//! registers one reaction on its thenable (`collo_request_task_settle_thenable`
//! in `bindings/jsc/runtime/promise.cpp`) and a reaction fires once.
//! `schedule` inserts with `putNoClobber`, which relies on that.

const bindings = @import("collo_bindings");
const request_task = @import("task.zig");

/// A settled thenable value waiting for its work item; `is_error` marks a
/// rejection.
pub const Completion = struct {
    token: request_task.TaskToken,
    value: bindings.Value,
    is_error: bool,
    /// When the completion was produced. A completion that finds the ready
    /// queue full keeps this stamp for the rescan's retry, so the request's
    /// timeline counts the wait for queue room as waiting time, not I/O.
    ready_at_mono_ns: u64,

    pub fn deinit(self: *Completion) void {
        self.value.deinit();
        self.* = undefined;
    }
};

/// Parks the settled `value` of the thenable behind `token` and queues its
/// work item, or leaves it for `collectReady` when the ready queue and its
/// backlog are full. Takes `value` on every path. A token whose task is
/// gone, belongs to another request or generation, no longer waits on a
/// thenable, or was canceled or timed out is counted as stale and dropped
/// without an error. Fails only when the pending map cannot grow.
pub fn schedule(
    runtime: anytype,
    token: request_task.TaskToken,
    request_id: u64,
    request_generation: u64,
    value: bindings.Value,
    is_error: bool,
) !void {
    var owned_value = value;
    var moved = false;
    defer if (!moved)
        owned_value.deinit();

    const task = runtime.requests.tasks.get(token) orelse {
        runtime.observability.stale_task_completion_count += 1;
        return;
    };
    if (task.request_id != request_id or
        task.request_generation != request_generation or
        task.state != .waiting_thenable or
        task.canceled or
        task.timed_out)
    {
        runtime.observability.stale_task_completion_count += 1;
        return;
    }

    const ready_at_mono_ns = runtime.nowMonoNs();
    try runtime.requests.pending_completions.putNoClobber(runtime.core.allocator, request_id, .{
        .token = token,
        .value = owned_value,
        .is_error = is_error,
        .ready_at_mono_ns = ready_at_mono_ns,
    });
    moved = true;
    errdefer {
        if (runtime.requests.pending_completions.fetchRemove(request_id)) |removed| {
            var completion = removed.value;
            completion.deinit();
        }
    }
    if (!task.completion_queued) {
        if (runtime.tryQueueReadyWorkReadySince(.{ .request_completion = token }, ready_at_mono_ns)) {
            task.completion_queued = true;
        }
    }
}

/// Queues the parked completions that found no room earlier, once a full
/// queue asked for a rescan. It stops at the first one that still finds no
/// room, which asks for the rescan again, and drops a completion whose task
/// is gone.
pub fn collectReady(runtime: anytype) void {
    if (!runtime.scheduler.request_completion_rescan_needed)
        return;
    runtime.scheduler.request_completion_rescan_needed = false;

    // Removing an entry invalidates the iterator, so the walk restarts after
    // each stale completion it drops.
    while (true) {
        var stale_request_id: ?u64 = null;
        var iterator = runtime.requests.pending_completions.iterator();
        while (iterator.next()) |entry| {
            const completion = entry.value_ptr;
            const task = runtime.requests.tasks.get(completion.token) orelse {
                stale_request_id = entry.key_ptr.*;
                break;
            };
            if (task.completion_queued)
                continue;
            if (!runtime.tryQueueReadyWorkReadySince(
                .{ .request_completion = completion.token },
                completion.ready_at_mono_ns,
            ))
                return;
            task.completion_queued = true;
        }

        const request_id = stale_request_id orelse return;
        if (runtime.requests.pending_completions.fetchRemove(request_id)) |removed| {
            var completion = removed.value;
            completion.deinit();
        }
    }
}
