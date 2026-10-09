//! Scheduling policy over the runtime's scheduler state, on the worker's VM
//! thread: setting up the worker ring, arming request deadlines with the
//! sentinel, publishing the turn owner, and scheduling, collecting and
//! cancelling timers and immediates. `Runtime` forwards to it through thin
//! methods.
//!
//! Timers and immediates share one budget, `RuntimeLimits.max_timers_per_worker`,
//! counted over the timer heap, the pending immediates, both ready maps and
//! a repeating timer whose callback is running. Only an active request,
//! including the boot context, can schedule them. Collection moves an entry
//! into its ready map before queueing its work item, and an entry that finds
//! the ready queue full goes back where it came from with its readiness
//! stamp; if even that fails, the worker stops.

const std = @import("std");
const bindings = @import("collo_bindings");
const restricted_uring = @import("collo_common_io").restricted_uring;
const worker_fs = @import("../fs/index.zig");
const js_value = @import("collo_worker_js").value;
const request_context = @import("collo_worker_request").context;
const runtime_types = @import("../runtime/types.zig");
const immediates = @import("immediates.zig");
const timers = @import("timers.zig");

/// Creates the timerfd and the worker ring over its complete fixed-file
/// table; a second call does nothing. The two egress slots take the
/// completion eventfd and the liveness pipe of the worker's wake descriptors,
/// held by its endpoint or, for a worker launched without a session, by its
/// egress state (`State.wakeFds` in `egress/state.zig`). Every later session
/// of the worker carries the same two files, so the ring watches it without
/// registering another. Fails with a `error.WorkerRingMissing*` error when a
/// fixed file is absent, or with the validation or ring setup error, leaving
/// no ring behind.
pub fn initRestrictedWorkerRing(runtime: anytype) !void {
    if (runtime.scheduler.worker_ring != null)
        return;
    const control_fd = runtime.core.control_fd orelse return error.WorkerRingMissingControlFd;
    const wakeup_fd = runtime.scheduler.wakeup_fd orelse return error.WorkerRingMissingWakeupFd;
    const egress_wake = runtime.egress.state.wakeFds() orelse
        return error.WorkerRingMissingEgressWake;
    const egress_completion_fd = egress_wake.completion_eventfd;
    const egress_liveness_fd = egress_wake.liveness_fd;
    const ingress_payload_credit_eventfd = runtime.requests.ingress_payload_credit_eventfd orelse
        return error.WorkerRingMissingIngressPayloadCreditEventFd;
    // The fault channel is a required fixed file. The worker boot installs
    // the fs index before the ring (`zygote/child_boot.zig`), and a worker
    // without the channel could never fault a file in.
    const fs_fault_fd = worker_fs.faultFd() orelse
        return error.WorkerRingMissingFsFaultFd;
    const timer_fd = try std.posix.timerfd_create(.MONOTONIC, .{
        .CLOEXEC = true,
        .NONBLOCK = true,
    });
    errdefer std.posix.close(timer_fd);
    const fixed_files = [_]std.posix.fd_t{
        control_fd,
        wakeup_fd,
        egress_completion_fd,
        egress_liveness_fd,
        timer_fd,
        ingress_payload_credit_eventfd,
        fs_fault_fd,
    };
    try restricted_uring.validateWorkerFixedFiles(&fixed_files);
    runtime.scheduler.worker_ring = try restricted_uring.WorkerRing.init(.{ .files = fixed_files });
    errdefer {
        if (runtime.scheduler.worker_ring) |*ring|
            ring.deinit();
        runtime.scheduler.worker_ring = null;
    }
    runtime.scheduler.worker_ring_fixed_files = fixed_files;
    runtime.scheduler.worker_timer_fd = timer_fd;
}

pub fn workerRingFd(runtime: anytype) ?std.posix.fd_t {
    return if (runtime.scheduler.worker_ring) |*ring| ring.fd() else null;
}

pub fn workerTimerFd(runtime: anytype) ?std.posix.fd_t {
    return runtime.scheduler.worker_timer_fd;
}

pub fn workerRingFixedFiles(
    runtime: anytype,
) ?[restricted_uring.FixedFile.count]std.posix.fd_t {
    return runtime.scheduler.worker_ring_fixed_files;
}

pub fn workerSchedulerMetricsSnapshot(runtime: anytype) runtime_types.WorkerSchedulerMetrics {
    return runtime.scheduler.metrics;
}

/// Arms the request's deadline in the sentinel and pushes it on the deadline
/// heap; does nothing when it is already armed. A full heap is cleared of
/// stale entries and the push retried. On failure the sentinel entry is
/// disarmed again.
pub fn armRequestDeadline(
    runtime: anytype,
    request: *request_context.RequestContext,
) !void {
    if (request.deadline_armed)
        return;
    var sentinel_armed = false;
    errdefer {
        if (sentinel_armed)
            runtime.observability.sentinel.disarm(request.exec.request_id, request.deadline_generation);
    }

    request.deadline_generation = try runtime.observability.sentinel.arm(
        request.exec.request_id,
        request.exec.deadline_monotonic_ns,
    );
    sentinel_armed = true;
    pushRequestDeadline(runtime, request) catch |err| switch (err) {
        error.DeadlineHeapFull => {
            compactRequestDeadlineHeap(runtime);
            try pushRequestDeadline(runtime, request);
        },
        else => return err,
    };
    request.deadline_armed = true;
    sentinel_armed = false;
}

/// Disarms the request's deadline in the sentinel; does nothing when it is
/// not armed. Its heap entry turns stale and is dropped by the reader.
pub fn disarmRequestDeadline(runtime: anytype, request: *request_context.RequestContext) void {
    if (!request.deadline_armed)
        return;
    {
        const sentinel = &runtime.observability.sentinel;
        // Every terminal path of a request disarms here, and disarming drops
        // the entry with its fire flag. A fire that landed where no path
        // checks it, such as after the turn while the response is extracted,
        // or in an exception the extract turned into a local 500, would
        // otherwise leave a terminated VM serving 500s for good, so the flag
        // is folded into `stop_after_deadline_fire` first.
        if (sentinel.terminationWasRequested(request.exec.request_id, request.deadline_generation))
            runtime.stop_after_deadline_fire = true;
        sentinel.disarm(request.exec.request_id, request.deadline_generation);
    }
    request.deadline_armed = false;
    request.deadline_due_queued = false;
}

/// Whether the sentinel fired for the request or its deadline has passed;
/// false when no deadline is armed.
pub fn requestDeadlineTerminationRequested(
    runtime: anytype,
    request: *const request_context.RequestContext,
) bool {
    if (!request.deadline_armed)
        return false;
    if (runtime.observability.sentinel.terminationWasRequested(request.exec.request_id, request.deadline_generation))
        return true;
    return runtime.nowMonoNs() >= request.exec.deadline_monotonic_ns;
}

/// Publishes `request_id` as the owner of the JavaScript about to run; zero
/// means no single owner. The sentinel terminates the VM for an expired
/// deadline only while that deadline's request is the published owner. The
/// loop publishes around every work item, and the runtime around JavaScript
/// that runs outside one, such as the boot evaluation
/// (`runtime/boot_context.zig`) and module settlements
/// (`runtime/modules.zig`).
pub fn publishTurnOwner(runtime: anytype, request_id: u64) void {
    runtime.observability.sentinel.publishTurnOwner(request_id);
}

pub fn clearTurnOwner(runtime: anytype) void {
    runtime.observability.sentinel.clearTurnOwner();
}

/// Schedules a timer of `request_id` due `delay_ms` from now, repeating when
/// `repeats`, and returns its id. Takes `callback` and `args` on every path.
/// Fails with `error.TimerOutsideActiveRequest` for a request that is not
/// active, `error.TimerWorkerLimitExceeded` when the shared budget is spent,
/// or the heap's error.
pub fn scheduleTimer(
    runtime: anytype,
    request_id: u64,
    callback: js_value.JsFunctionOwned,
    receiver: ?js_value.JsValueOwned,
    args: ?[]js_value.JsValueOwned,
    delay_ms: u32,
    repeats: bool,
) !u64 {
    var callback_fn = callback;
    var callback_owned = true;
    defer if (callback_owned)
        callback_fn.deinit();
    var receiver_value = receiver;
    defer if (receiver_value) |*owned|
        owned.deinit();
    var args_slice = args;
    defer if (args_slice) |owned_args| {
        for (owned_args) |*arg|
            arg.deinit();
        runtime.core.allocator.free(owned_args);
    };

    if (request_id == 0 or !runtime.requests.active.contains(request_id))
        return error.TimerOutsideActiveRequest;
    if (schedulerCallbackCount(runtime) >= runtime.core.limits.max_timers_per_worker)
        return error.TimerWorkerLimitExceeded;

    const timer_id = runtime.scheduler.next_timer_id;
    runtime.scheduler.next_timer_id += 1;

    const delay_ns = @as(u64, delay_ms) * std.time.ns_per_ms;
    var entry = timers.TimerEntry{
        .id = timer_id,
        .request_id = request_id,
        .due_mono_ns = runtime.nowMonoNs() + delay_ns,
        .delay_ms = delay_ms,
        .repeats = repeats,
        .callback = callback_fn.take(),
        .receiver = if (receiver_value) |*owned| owned.take() else null,
        .args = args_slice,
    };
    callback_owned = false;
    receiver_value = null;
    args_slice = null;
    errdefer entry.deinit(runtime.core.allocator);
    try runtime.scheduler.timers.push(entry);
    return timer_id;
}

/// Schedules an immediate of `request_id` in the next generation and returns
/// its id, drawn from the timer id counter so the two never collide. Takes
/// `callback`, `this_arg` and `args` on every path, and fails like
/// `scheduleTimer`.
pub fn scheduleImmediate(
    runtime: anytype,
    request_id: u64,
    callback: js_value.JsFunctionOwned,
    this_arg: ?js_value.JsValueOwned,
    args: ?[]js_value.JsValueOwned,
) !u64 {
    var callback_fn = callback;
    var callback_owned = true;
    defer if (callback_owned)
        callback_fn.deinit();
    var this_value = this_arg;
    defer if (this_value) |*owned|
        owned.deinit();
    var args_slice = args;
    defer if (args_slice) |owned_args| {
        for (owned_args) |*arg|
            arg.deinit();
        runtime.core.allocator.free(owned_args);
    };

    if (request_id == 0 or !runtime.requests.active.contains(request_id))
        return error.TimerOutsideActiveRequest;
    if (schedulerCallbackCount(runtime) >= runtime.core.limits.max_timers_per_worker)
        return error.TimerWorkerLimitExceeded;

    const immediate_id = runtime.scheduler.next_timer_id;
    runtime.scheduler.next_timer_id += 1;

    var entry = immediates.ImmediateEntry{
        .id = immediate_id,
        .request_id = request_id,
        .generation = runtime.scheduler.immediate_next_generation,
        .scheduled_at_mono_ns = runtime.nowMonoNs(),
        .callback = callback_fn.take(),
        .this_arg = if (this_value) |*owned| owned.take() else null,
        .args = args_slice,
    };
    callback_owned = false;
    this_value = null;
    args_slice = null;
    errdefer entry.deinit(runtime.core.allocator);
    try runtime.scheduler.pending_immediate_callbacks.push(entry);
    return immediate_id;
}

/// The entries the shared budget counts (see the file header).
fn schedulerCallbackCount(runtime: anytype) usize {
    return runtime.scheduler.timers.reservedCount() +
        runtime.scheduler.ready_timer_callbacks.count() +
        runtime.scheduler.pending_immediate_callbacks.reservedCount() +
        runtime.scheduler.ready_immediate_callbacks.count() +
        @intFromBool(runtime.scheduler.executing_repeating_timer_reserved);
}

/// Moves due timers into the ready map and queues their work items while
/// the ready queue has room.
pub fn collectDueTimers(runtime: anytype) !void {
    const now = runtime.nowMonoNs();
    while (runtime.scheduler.ready_queue.remainingCapacity() != 0) {
        const popped = runtime.scheduler.timers.popDue(now) orelse return;
        var entry = popped;
        var moved_to_ready = false;
        defer if (!moved_to_ready)
            entry.deinit(runtime.core.allocator);
        try runtime.scheduler.ready_timer_callbacks.putNoClobber(runtime.core.allocator, entry.id, entry);
        moved_to_ready = true;
        errdefer {
            if (runtime.scheduler.ready_timer_callbacks.fetchRemove(entry.id)) |removed| {
                var timer = removed.value;
                timer.deinit(runtime.core.allocator);
            }
        }
        // The timer became ready at its due time, so the io interval closes
        // there rather than at the drain that noticed it.
        if (!runtime.tryQueueReadyWorkReadySince(.{ .timer_callback = entry.id }, entry.due_mono_ns)) {
            if (runtime.scheduler.ready_timer_callbacks.fetchRemove(entry.id)) |removed| {
                var timer = removed.value;
                runtime.scheduler.timers.push(timer) catch |err| {
                    timer.deinit(runtime.core.allocator);
                    std.log.err("failed to return saturated timer to heap timer_id={d}: {s}", .{
                        entry.id,
                        @errorName(err),
                    });
                    runtime.core.running = false;
                };
            }
            return;
        }
    }
}

/// Moves the pending immediates of the generation being collected into the
/// ready map and queues their work items while the ready queue has room,
/// then starts the next generation. It does nothing while an immediate
/// already in the ready map has not run, which is what holds back the
/// immediates a running batch schedules.
pub fn collectReadyImmediates(runtime: anytype) !void {
    if (runtime.scheduler.ready_immediate_callbacks.count() != 0)
        return;

    while (runtime.scheduler.ready_queue.remainingCapacity() != 0) {
        const generation = runtime.scheduler.immediate_collect_generation orelse generation: {
            if (runtime.scheduler.pending_immediate_callbacks.isEmpty())
                return;
            const next_generation = runtime.scheduler.immediate_next_generation;
            runtime.scheduler.immediate_next_generation += 1;
            runtime.scheduler.immediate_collect_generation = next_generation;
            break :generation next_generation;
        };

        const popped =
            runtime.scheduler.pending_immediate_callbacks.popGeneration(generation) orelse {
                runtime.scheduler.immediate_collect_generation = null;
                continue;
            };
        var entry = popped;
        var moved_to_ready = false;
        defer if (!moved_to_ready)
            entry.deinit(runtime.core.allocator);

        try runtime.scheduler.ready_immediate_callbacks.putNoClobber(
            runtime.core.allocator,
            entry.id,
            entry,
        );
        moved_to_ready = true;
        errdefer {
            if (runtime.scheduler.ready_immediate_callbacks.fetchRemove(entry.id)) |removed| {
                var immediate = removed.value;
                immediate.deinit(runtime.core.allocator);
            }
        }

        if (!runtime.tryQueueReadyWorkReadySince(
            .{ .immediate_callback = entry.id },
            entry.scheduled_at_mono_ns,
        )) {
            if (runtime.scheduler.ready_immediate_callbacks.fetchRemove(entry.id)) |removed| {
                var immediate = removed.value;
                runtime.scheduler.pending_immediate_callbacks.pushFront(immediate) catch |err| {
                    immediate.deinit(runtime.core.allocator);
                    std.log.err("failed to return saturated immediate to queue immediate_id={d}: {s}", .{
                        entry.id,
                        @errorName(err),
                    });
                    runtime.core.running = false;
                };
            }
            return;
        }
    }
}

/// Queues a `.request_deadline` item for each due deadline, dropping stale
/// heap entries on the way. A deadline that finds the ready queue full stays
/// on the heap for the next pass.
pub fn collectDueRequestDeadlines(runtime: anytype) !void {
    const now = runtime.nowMonoNs();
    while (true) {
        const entry = runtime.scheduler.request_deadlines.peek() orelse return;
        const request = validRequestDeadline(runtime, entry) orelse {
            _ = runtime.scheduler.request_deadlines.popMin();
            continue;
        };
        if (entry.due_mono_ns > now)
            return;
        if (!runtime.tryQueueReadyWorkReadySince(
            .{ .request_deadline = request.exec.request_id },
            entry.due_mono_ns,
        )) {
            return;
        }
        _ = runtime.scheduler.request_deadlines.popMin();
        request.deadline_due_queued = true;
    }
}

/// The earliest live deadline, dropping stale entries from the top of the
/// heap.
pub fn nextRequestDeadlineNs(runtime: anytype) ?u64 {
    while (true) {
        const entry = runtime.scheduler.request_deadlines.peek() orelse return null;
        if (validRequestDeadline(runtime, entry) != null)
            return entry.due_mono_ns;
        _ = runtime.scheduler.request_deadlines.popMin();
    }
}

/// Frees every timer of `request_id` in the heap and in the ready map.
pub fn cancelTimersForRequest(runtime: anytype, request_id: u64) void {
    _ = runtime.scheduler.timers.cancelForRequest(request_id);
    while (true) {
        var remove_id: ?u64 = null;
        var iterator = runtime.scheduler.ready_timer_callbacks.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.request_id == request_id) {
                remove_id = entry.key_ptr.*;
                break;
            }
        }
        const timer_id = remove_id orelse return;
        if (runtime.scheduler.ready_timer_callbacks.fetchRemove(timer_id)) |removed| {
            var timer = removed.value;
            timer.deinit(runtime.core.allocator);
        }
    }
}

/// Frees every immediate of `request_id`, pending or ready, and marks each
/// Immediate object destroyed.
pub fn cancelImmediatesForRequest(runtime: anytype, request_id: u64) void {
    while (runtime.scheduler.pending_immediate_callbacks.takeForRequest(request_id)) |entry| {
        var immediate = entry;
        immediates.markDestroyed(runtime, &immediate);
        immediate.deinit(runtime.core.allocator);
    }
    while (true) {
        var remove_id: ?u64 = null;
        var iterator = runtime.scheduler.ready_immediate_callbacks.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.request_id == request_id) {
                remove_id = entry.key_ptr.*;
                break;
            }
        }
        const immediate_id = remove_id orelse return;
        if (runtime.scheduler.ready_immediate_callbacks.fetchRemove(immediate_id)) |removed| {
            var immediate = removed.value;
            immediates.markDestroyed(runtime, &immediate);
            immediate.deinit(runtime.core.allocator);
        }
    }
}

/// clearTimeout: frees timer `timer_id` when `request_id` owns it, in the
/// ready map or the heap. For a timer whose callback is running it only
/// stops the repeat.
pub fn cancelTimeout(runtime: anytype, request_id: u64, timer_id: u64) void {
    if (runtime.scheduler.ready_timer_callbacks.getPtr(timer_id)) |timer| {
        if (timer.request_id != request_id)
            return;
        if (runtime.scheduler.ready_timer_callbacks.fetchRemove(timer_id)) |removed| {
            var removed_timer = removed.value;
            removed_timer.deinit(runtime.core.allocator);
        }
        return;
    }
    if (runtime.scheduler.timers.cancelByIdForRequest(timer_id, request_id))
        return;
    if (runtime.scheduler.executing_timer_id == timer_id and
        runtime.scheduler.executing_timer_request_id == request_id)
    {
        runtime.scheduler.executing_timer_cancelled = true;
        runtime.scheduler.executing_repeating_timer_reserved = false;
    }
}

/// clearImmediate: frees immediate `immediate_id` when `request_id` owns it,
/// ready or pending, and marks its Immediate object destroyed.
pub fn cancelImmediate(runtime: anytype, request_id: u64, immediate_id: u64) void {
    if (runtime.scheduler.ready_immediate_callbacks.getPtr(immediate_id)) |immediate| {
        if (immediate.request_id != request_id)
            return;
        if (runtime.scheduler.ready_immediate_callbacks.fetchRemove(immediate_id)) |removed| {
            var removed_immediate = removed.value;
            immediates.markDestroyed(runtime, &removed_immediate);
            removed_immediate.deinit(runtime.core.allocator);
        }
        return;
    }
    if (runtime.scheduler.pending_immediate_callbacks.takeByIdForRequest(
        immediate_id,
        request_id,
    )) |entry| {
        var immediate = entry;
        immediates.markDestroyed(runtime, &immediate);
        immediate.deinit(runtime.core.allocator);
    }
}

fn pushRequestDeadline(runtime: anytype, request: *const request_context.RequestContext) !void {
    try runtime.scheduler.request_deadlines.push(.{
        .request_id = request.exec.request_id,
        .request_generation = request.request_generation,
        .due_mono_ns = request.exec.deadline_monotonic_ns,
    });
}

/// Removes every stale entry from the deadline heap.
fn compactRequestDeadlineHeap(runtime: anytype) void {
    var index: usize = 0;
    while (index < runtime.scheduler.request_deadlines.len) {
        const entry = runtime.scheduler.request_deadlines.entries[index];
        if (validRequestDeadline(runtime, entry) != null) {
            index += 1;
            continue;
        }
        runtime.scheduler.request_deadlines.removeAt(index);
    }
}

/// The request a heap entry still describes: active with the same
/// generation, armed, not yet queued, and due at the entry's time. Null
/// means the entry is stale.
fn validRequestDeadline(
    runtime: anytype,
    entry: @import("deadlines.zig").Entry,
) ?*request_context.RequestContext {
    const request = runtime.requests.active.get(entry.request_id) orelse return null;
    if (request.request_generation != entry.request_generation)
        return null;
    if (!request.deadline_armed)
        return null;
    if (request.deadline_due_queued)
        return null;
    if (request.exec.deadline_monotonic_ns != entry.due_mono_ns)
        return null;
    return request;
}
