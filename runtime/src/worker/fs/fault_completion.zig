//! The completion of a fault (`fault.zig`) on the worker's VM thread: the
//! response read off the fault channel, the copy an `ok` response carries
//! (`copies.zig`), the completion work item that follows, and the settle of
//! every waiter when the loop runs that item.
//!
//! A fault completes once, from its first response, and its waiters settle
//! only from the work item, each in a sub-turn published under its own
//! request (`resolveWaiters`). A completion that finds the ready queue and
//! its backlog full sets `State.rescan_needed`, and `collectCompletions`
//! queues it later, as egress does for fetch completions.

const std = @import("std");
const ipc = @import("collo_ipc");
const worker_fs = @import("index.zig");
const turn = @import("collo_worker_js").turn;
const scheduler_resources = @import("../scheduler/resources.zig");
const fault = @import("fault.zig");
const copies = @import("copies.zig");

/// Reads one response off the fault channel for the loop's `.fs_fault_ready`
/// event; the re-armed poll brings the next one, as on the control channel.
/// An unknown fault id or a malformed packet is dropped with any fd it
/// carried and never stops the loop. Fails only on an unexpected receive
/// error.
pub fn collectResponse(runtime: anytype) !void {
    const fault_fd = worker_fs.faultFd() orelse return;
    var packet = ipc.recvPacketWithFdsScratch(
        runtime.core.allocator,
        fault_fd,
        runtime.core.dispatch_recv_scratch,
    ) catch |err| switch (err) {
        // A sync fault may already have read the packets behind this poll
        // completion, so an empty channel is a spurious wake.
        error.WouldBlock => return,
        // The host end closed. The worker keeps serving until the control
        // channel's hangup stops the loop, and requests waiting on a fault
        // end at their deadlines.
        error.PeerClosed => {
            std.log.warn("fs fault channel peer closed", .{});
            return;
        },
        else => return err,
    };
    // The decoder frees the packet on every path.
    var response = ipc.fs_fault.decodeResponseFromPacket(&packet) catch |err| {
        std.log.warn("dropping malformed fs fault response: {s}", .{@errorName(err)});
        return;
    };
    defer response.deinit();
    completeFault(runtime, &response);
}

pub fn completeFault(runtime: anytype, response: *ipc.FsFaultResponseWithFd) void {
    const state: *fault.State = &runtime.fs_fault;
    const task = state.tasks.getPtr(response.response.fault_id) orelse {
        std.log.warn("dropping fs fault response for unknown fault_id={d}", .{
            response.response.fault_id,
        });
        return;
    };
    if (task.done) {
        // A duplicate response to a finished fault: the first one wins.
        std.log.warn("dropping duplicate fs fault response fault_id={d}", .{task.id});
        return;
    }
    task.completed_at_ns = runtime.nowMonoNs();

    if (response.response.status != .ok) {
        task.outcome = .{ .failed = statusMessage(response.response.status) };
    } else {
        const memfd = response.takeFileFd() orelse {
            // `decodeResponseFromPacket` requires exactly one fd on ok, so a
            // missing fd is a bug; it fails the fault, not the worker.
            task.outcome = .{ .failed = "fs fault response missing file descriptor" };
            task.done = true;
            queueCompletion(runtime, task);
            return;
        };
        defer std.posix.close(memfd);
        materialize(task, memfd, runtime.nowMonoNs());
    }
    task.done = true;
    queueCompletion(runtime, task);
}

fn queueCompletion(runtime: anytype, task: *fault.Task) void {
    if (task.queued)
        return;
    task.queued = true;
    if (!runtime.tryQueueReadyWork(.{ .fs_fault_completion = task.id })) {
        // `tryQueueReadyWork` already set `State.rescan_needed`; clearing
        // `queued` lets `collectCompletions` pick the task up again.
        task.queued = false;
        return;
    }
    noteWaitersReady(runtime, task);
}

/// Marks each live waiter's request ready once the shared completion is
/// queued: its io interval closes at `completed_at_ns`, and it counts one
/// ready item that the waiter's settle sub-turn in `resolveWaiters` or
/// `rejectWaiters` consumes under the same liveness checks. Runs once per
/// fault, only after the completion item was queued; a full queue clears
/// `queued` and retries without calling it.
fn noteWaitersReady(runtime: anytype, task: *fault.Task) void {
    const now = runtime.nowMonoNs();
    for (task.waiters.items) |*waiter| {
        const request = runtime.requests.active.get(waiter.request_id) orelse continue;
        if (request.request_generation != waiter.request_generation)
            continue;
        request.noteReady(task.completed_at_ns, now, true);
        waiter.ready_counted = true;
    }
}

/// Releases the ready items still counted for waiters when a settle stopped
/// before or during its waiter loop, for example because the VM could not
/// build the settle value. Each is released through a zero-length turn, so
/// the waiting since the fan-out is folded and the request's next slice
/// derives from its remaining ready items instead of staying io.
fn releaseUnconsumedWaiterCounts(runtime: anytype, task: *fault.Task) void {
    for (task.waiters.items) |*waiter| {
        if (!waiter.ready_counted)
            continue;
        waiter.ready_counted = false;
        const request = runtime.requests.active.get(waiter.request_id) orelse continue;
        if (request.request_generation != waiter.request_generation)
            continue;
        const now = runtime.nowMonoNs();
        request.noteTurnBegin(now, true);
        request.noteTurnEnd(now);
    }
}

/// Queues the completions that found the ready queue full, as
/// `collectCompleted` in `egress/task_runtime.zig` does for fetches. It
/// stops at the first one that still does not fit and keeps the rescan
/// flag set.
pub fn collectCompletions(runtime: anytype) void {
    const state: *fault.State = &runtime.fs_fault;
    if (!state.rescan_needed)
        return;
    state.rescan_needed = false;

    var it = state.tasks.valueIterator();
    while (it.next()) |task| {
        if (!(task.done and !task.queued))
            continue;
        queueCompletion(runtime, task);
        if (!task.queued) {
            state.rescan_needed = true;
            return;
        }
    }
}

/// Runs the `.fs_fault_completion` work item: removes the fault and settles
/// every waiter whose request still has the same id and generation. Other
/// waiters are skipped, and their promises die with their requests. Returns
/// the first error the settle raised.
pub fn executeCompletion(runtime: anytype, fault_id: u64) !void {
    const state: *fault.State = &runtime.fs_fault;
    const removed = state.tasks.fetchRemove(fault_id) orelse return;
    var task = removed.value;
    _ = state.faults_by_path.remove(task.path);
    defer task.deinit(runtime.core.allocator);

    var first_error: ?anyerror = null;
    switch (task.outcome) {
        .materialized => resolveWaiters(runtime, &task, &first_error),
        .failed => |message| rejectWaiters(runtime, &task, message, &first_error),
        // A completion can only be queued after `done` flipped, and `done`
        // always sets a terminal outcome first.
        .pending => rejectWaiters(runtime, &task, "fs fault settled without outcome", &first_error),
    }
    releaseUnconsumedWaiterCounts(runtime, &task);
    runtime.traceRuntimeEvent("worker.fs_fault.settled={s}", .{task.path});
    if (first_error) |err|
        return err;
}

/// Logs a failed completion. A waiter it left unsettled ends with its
/// request's deadline.
pub fn handleCompletionFailure(runtime: anytype, fault_id: u64, err: anyerror) void {
    _ = runtime;
    std.log.warn("fs fault completion failed fault_id={d}: {s}", .{ fault_id, @errorName(err) });
}

fn resolveWaiters(runtime: anytype, task: *fault.Task, first_error: *?anyerror) void {
    // The copy is read once to prove it exists and is readable, then every
    // waiter resolves with undefined. The binding chains its own read of
    // the copy onto each promise (`scheduleDeployReadFault` in `fs.cpp`) and
    // applies the caller's encoding there, so the value only signals that
    // the copy exists; a string of the bytes could not represent a binary
    // file.
    const content: []u8 = copies.readMaterialized(runtime.core.allocator, task.path) catch {
        rejectWaiters(runtime, task, "materialized deploy file read failed", first_error);
        return;
    };
    runtime.core.allocator.free(content);

    var value = runtime.core.vm.undefinedValue() catch |err| {
        first_error.* = err;
        return;
    };
    defer value.deinit();
    for (task.waiters.items) |*waiter| {
        const request = runtime.requests.active.get(waiter.request_id) orelse continue;
        if (request.request_generation != waiter.request_generation)
            continue;
        // The shared settle spans several requests, so the work item
        // publishes no turn owner. Each waiter's resolution is its own
        // sub-turn, published under that waiter's request and cleared before
        // the next, so the sentinel can stop a hang inside a reaction at
        // that request's deadline.
        scheduler_resources.publishTurnOwner(runtime, request.exec.request_id);
        defer scheduler_resources.clearTurnOwner(runtime);
        // The sub-turn runs this waiter's request and consumes the ready
        // item counted for it, if one was. The request is looked up again
        // after the JavaScript runs, because a reaction may finish and
        // destroy it. The sub-turn's length counts toward the request's
        // longest turn.
        const sub_turn_start = runtime.nowMonoNs();
        request.noteTurnBegin(sub_turn_start, waiter.ready_counted);
        waiter.ready_counted = false;
        turn.resolvePromise(runtime.core.vm, &request.exec, &waiter.deferred, &value) catch |err| {
            if (first_error.* == null)
                first_error.* = err;
        };
        const sub_turn_end = runtime.nowMonoNs();
        if (runtime.requests.active.get(waiter.request_id)) |still_alive| {
            still_alive.noteTurnEnd(sub_turn_end);
            still_alive.max_turn_ns = @max(still_alive.max_turn_ns, sub_turn_end - sub_turn_start);
        }
    }
}

fn rejectWaiters(runtime: anytype, task: *fault.Task, message: []const u8, first_error: *?anyerror) void {
    var reason = runtime.core.vm.stringValueUtf8(message) catch |err| {
        first_error.* = err;
        return;
    };
    defer reason.deinit();
    for (task.waiters.items) |*waiter| {
        const request = runtime.requests.active.get(waiter.request_id) orelse continue;
        if (request.request_generation != waiter.request_generation)
            continue;
        // Published per waiter, for the reason given in `resolveWaiters`.
        scheduler_resources.publishTurnOwner(runtime, request.exec.request_id);
        defer scheduler_resources.clearTurnOwner(runtime);
        // The same sub-turn accounting as in `resolveWaiters`.
        const sub_turn_start = runtime.nowMonoNs();
        request.noteTurnBegin(sub_turn_start, waiter.ready_counted);
        waiter.ready_counted = false;
        turn.rejectPromise(runtime.core.vm, &request.exec, &waiter.deferred, &reason) catch |err| {
            if (first_error.* == null)
                first_error.* = err;
        };
        const sub_turn_end = runtime.nowMonoNs();
        if (runtime.requests.active.get(waiter.request_id)) |still_alive| {
            still_alive.noteTurnEnd(sub_turn_end);
            still_alive.max_turn_ns = @max(still_alive.max_turn_ns, sub_turn_end - sub_turn_start);
        }
    }
}

fn materialize(task: *fault.Task, memfd: std.posix.fd_t, now_mono_ns: u64) void {
    if (copies.materializeEntry(task.entry, task.path, memfd, now_mono_ns)) |message| {
        task.outcome = .{ .failed = message };
        return;
    }
    task.outcome = .materialized;
}

fn statusMessage(status: ipc.messages.FsFaultResponseStatus) []const u8 {
    return switch (status) {
        .ok => "deploy file materialized",
        .not_found => "deploy file not found",
        .refused => "fs fault identity refused",
        .fetch_failed => "deploy file fetch failed",
    };
}
