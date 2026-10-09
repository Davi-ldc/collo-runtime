//! Finishes a request: seals its timeline, releases everything it holds,
//! appends its usage record to the shared page's record ring, publishes its
//! completion and signals the host. It runs on the worker's VM thread, at
//! most once per request.
//!
//! Both records carry only the identities the dispatch assigned (request id,
//! generation, lane slot, worker) next to the worker's measurements. The
//! server accepts a usage record only for a request it dispatched to this
//! worker and stamps its own identity on it
//! (`server/supervisor/usage_drain.zig`), so a worker cannot
//! choose whose record its measurements enter. A record the worker cannot
//! publish stops the worker: the server then synthesizes the records of
//! every request still in flight, and none is lost.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const worker_shared_page = @import("collo_worker_state").page;
const body_read = @import("collo_worker_request").body_read;
const copies = @import("../fs/copies.zig");
const process_cpu = @import("process_cpu.zig");
const request_context = @import("collo_worker_request").context;
const state = @import("../runtime/root.zig");
const tracing = @import("trace.zig");

const CleanupMode = enum {
    preserve_live_slot,
    release_live_slot,
};

pub const FinishOutcome = enum {
    already_finished,
    completed,
};

/// Finishes `request_ctx` with `done_status` and `http_status` and destroys
/// it. A second call for the same request returns `.already_finished`. On
/// failure the context stays in the active map with its live slot, marked
/// finished, so the server's death synthesis still sees the request. Call it
/// between engine turns, as every caller does: the engine adds a turn's CPU
/// to `cpu_used_ns_total` at the turn's exit, so the record's turn CPU holds
/// every turn the request ran.
pub fn finishRequest(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !FinishOutcome {
    const request_id = request_ctx.exec.request_id;
    // The boot context has no response to finish. Finishing it would publish
    // a completion and a usage record with a zeroed dispatch identity and
    // destroy the context while module evaluation may still use it. The
    // level is warn because a test exercises this refusal, and the test
    // runner fails a run on any err line.
    if (request_id == request_context.boot_request_id) {
        std.log.warn("refusing finishRequest for the boot context (status={d})", .{http_status});
        return error.InvalidArgument;
    }
    if (request_ctx.finish_started)
        return .already_finished;
    request_ctx.finish_started = true;
    errdefer preserveFailedFinish(runtime, request_id);

    const finished_mono_ns = runtime.nowMonoNs();
    // The timeline is sealed before the record is written. Inside one of the
    // request's own turns this closes nothing, since execution is neither
    // I/O nor waiting; outside its turns it closes the current slice at the
    // finish stamp.
    request_ctx.noteFinish(finished_mono_ns);
    cleanupRequestSubresources(runtime, request_ctx, .preserve_live_slot);
    try cleanupWebApiRequestOnce(runtime, request_ctx);
    if (done_status == .deadline_timeout)
        request_ctx.exec.termination_reason = @intFromEnum(bindings.TerminationReason.deadline);

    // When a work item of this request runs this finish, the item's turn is
    // still open while this record is written. Its partial duration and
    // queue wait are folded in here, or a request that ran in one
    // synchronous turn would report neither.
    var queued_ns = request_ctx.queued_ns_total;
    var max_turn_ns = request_ctx.max_turn_ns;
    if (runtime.scheduler.executing_turn_request_id == request_id and
        runtime.scheduler.turn_started_mono_ns != 0)
    {
        queued_ns +|= runtime.scheduler.turn_queued_wait_ns;
        max_turn_ns = @max(max_turn_ns, finished_mono_ns -| runtime.scheduler.turn_started_mono_ns);
    }
    const turn_cpu_ns = request_ctx.exec.cpu_used_ns_total;

    // The process CPU delta is peeked, written into the record and committed
    // only once the record is in the ring, so a failed append leaves the
    // delta uncommitted for the live-slot fold below.
    var process_cpu_ns: u64 = 0;
    {
        const worker_metrics_state = &runtime.observability.worker_metrics_state;
        try worker_metrics_state.updateLiveSlotCpu(request_ctx.live_slot_index, request_ctx.exec.cpu_used_ns_total);
        process_cpu_ns = process_cpu.peekBilledDeltaNs();
        // A full record ring means this request's usage record cannot be
        // published, so the worker stops here rather than in its callers,
        // several of which only log the error they get back.
        worker_metrics_state.appendCompletedRecord(.{
            .request_id = request_id,
            .request_generation = request_ctx.dispatch_work.request_generation,
            .worker_id = request_ctx.dispatch_work.worker_id,
            .worker_generation = request_ctx.dispatch_work.worker_generation,
            .started_mono_ns = request_ctx.started_mono_ns,
            .finished_mono_ns = finished_mono_ns,
            // The process CPU delta since the previous record
            // (`process_cpu.zig`). The per-turn clock goes to `turn_cpu_ns`,
            // and the live slot keeps the completed turns' total, the floor a
            // death record reports.
            .cpu_time_ns = process_cpu_ns,
            .turn_cpu_ns = turn_cpu_ns,
            .io_time_ns = request_ctx.io_time_ns,
            .waiting_ns = request_ctx.waiting_ns,
            .queued_ns = queued_ns,
            .max_turn_ns = max_turn_ns,
            .client_served_bytes = request_ctx.client_served_bytes,
            .fetch_billed_sent_bytes = request_ctx.fetch_billed_sent_bytes,
            .fetch_billed_received_bytes = request_ctx.fetch_billed_received_bytes,
            .fetch_cost_bytes = request_ctx.fetch_cost_bytes,
            .billing_sequence = request_id,
            .request_slot = request_ctx.dispatch_work.request_slot,
            .request_lane_id = request_ctx.dispatch_work.request_lane_id,
            .status = @intFromEnum(switch (done_status) {
                .ok => worker_shared_page.CompletedStatus.done,
                .bad_request => worker_shared_page.CompletedStatus.bad_request,
                .js_exception => worker_shared_page.CompletedStatus.js_exception,
                .internal_error => worker_shared_page.CompletedStatus.internal_error,
                .deadline_timeout => worker_shared_page.CompletedStatus.deadline,
                .worker_crash => worker_shared_page.CompletedStatus.crash,
                .client_closed => worker_shared_page.CompletedStatus.client_closed,
            }),
            .flags = request_ctx.dispatch_work.accounting_flags,
        }) catch |err| {
            if (err == error.CompletedRecordRingFull) {
                runtime.traceRuntimeEvent("worker.completion.record_append_failed={d},{s}", .{ request_id, @errorName(err) });
                runtime.traceRuntimeEvent("worker.runtime.stop=completed_record_ring_full,{d}", .{request_id});
                runtime.core.running = false;
                // No later record will carry the uncommitted delta, since the
                // worker stops. The server's death record reports the live
                // slot's CPU, so the delta goes there. It already contains
                // this request's completed turns, so the slot takes the
                // larger of the two instead of their sum, which would count
                // those turns twice.
                worker_metrics_state.updateLiveSlotCpu(
                    request_ctx.live_slot_index,
                    @max(request_ctx.exec.cpu_used_ns_total, process_cpu_ns),
                ) catch |slot_err|
                    std.log.warn("ring-full CPU fold failed request_id={d}: {s}", .{ request_id, @errorName(slot_err) });
            }
            return err;
        };
        process_cpu.commitBilledDeltaNs(process_cpu_ns);
    }

    // A completion reaches the host only through the shared page's
    // completion ring, followed by a signal on the completion eventfd. No
    // packet of the response follows it: a response whose steps waited in
    // the outbox finishes its request from the flush once the last one is
    // sent (`serve/response.zig`), and any other finish dropped what the
    // outbox held in the cleanup above.
    runtime.observability.metrics_view.publishWorkerCompletion(.{
        .external_request_id = request_id,
        .request_lane_id = request_ctx.dispatch_work.request_lane_id,
        .request_slot = request_ctx.dispatch_work.request_slot,
        .request_generation = request_ctx.dispatch_work.request_generation,
        .worker_id = request_ctx.dispatch_work.worker_id,
        .worker_generation = request_ctx.dispatch_work.worker_generation,
        .status = @intFromEnum(done_status),
        .http_status = http_status,
        // The per-turn clock, not the process delta of the usage record. The
        // process delta is right for a tenant's total and wrong for one
        // request: a worker's first record absorbs the boot evaluation, and
        // co-scheduled requests split the span by whichever publishes first.
        // This ring feeds the per-request timeline, where that would charge a
        // cold start's evaluation, or one request's work, to another request.
        .cpu_time_ns = turn_cpu_ns,
        .io_time_ns = request_ctx.io_time_ns,
        .waiting_ns = request_ctx.waiting_ns,
    }) catch |err| {
        runtime.traceRuntimeEvent("worker.completion.publish_failed={d},{s}", .{ request_id, @errorName(err) });
        runtime.traceRuntimeEvent("worker.runtime.stop=completion_publish_failed,{d}", .{request_id});
        runtime.core.running = false;
        return err;
    };
    worker_shared_page.signalCompletionEventfd(runtime.egress.completion_eventfd) catch |err| {
        runtime.traceRuntimeEvent("worker.completion.signal_failed={d},{s}", .{ request_id, @errorName(err) });
        runtime.traceRuntimeEvent("worker.runtime.stop=completion_signal_failed,{d}", .{request_id});
        runtime.core.running = false;
        return err;
    };
    tracing.mark(runtime, request_ctx, "completion_published_ns");
    tracing.emit(runtime, request_ctx);

    removeFinishedRequest(runtime, request_id);
    // Request finish is where idle fs fault copies are swept;
    // `copies.sweepIdleMaterialized` bounds how often it walks.
    copies.sweepIdleMaterialized(runtime);
    return .completed;
}

fn preserveFailedFinish(runtime: *state.Runtime, request_id: u64) void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    request_ctx.finish_started = true;
    cleanupRequestSubresources(runtime, request_ctx, .preserve_live_slot);
}

fn removeFinishedRequest(runtime: *state.Runtime, request_id: u64) void {
    const removed = runtime.requests.active.fetchRemove(request_id) orelse return;
    cleanupRequestSubresources(runtime, removed.value, .release_live_slot);
    runtime.destroyRequestContext(removed.value);
}

fn cleanupRequestSubresources(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    mode: CleanupMode,
) void {
    const request_id = request_ctx.exec.request_id;
    releasePendingIngressResponse(runtime, request_ctx);
    runtime.cancelCryptoJobsForRequest(request_id);
    runtime.cancelFetchesForRequest(request_id);
    // A completed streaming fetch body can outlive its fetch promise until
    // JavaScript consumes or drops the Response, so the request's end is
    // its last owner.
    runtime.cleanupFetchBodiesForRequest(request_id);
    body_read.rejectPendingRead(runtime, request_ctx) catch |err|
        std.log.warn("failed to reject pending request body read request_id={d}: {s}", .{
            request_id,
            @errorName(err),
        });
    runtime.cancelTimersForRequest(request_id);
    cleanupWebApiRequestOnce(runtime, request_ctx) catch |err|
        std.log.warn("failed to cleanup request WebAPI state request_id={d}: {s}", .{
            request_id,
            @errorName(err),
        });
    removePendingCompletion(runtime, request_id);
    destroyRequestTask(runtime, request_ctx);
    runtime.disarmRequestDeadline(request_ctx);
    switch (mode) {
        .preserve_live_slot => {},
        .release_live_slot => {
            freeLiveSlotOnce(runtime, request_ctx) catch |err|
                std.log.warn("failed to release live slot request_id={d}: {s}", .{
                    request_id,
                    @errorName(err),
                });
        },
    }
}

fn cleanupWebApiRequestOnce(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !void {
    if (request_ctx.webapi_cleanup_done)
        return;
    try runtime.core.vm.cleanupWebApiRequest(request_ctx.exec.request_id);
    request_ctx.webapi_cleanup_done = true;
}

fn removePendingCompletion(runtime: *state.Runtime, request_id: u64) void {
    if (runtime.requests.pending_completions.fetchRemove(request_id)) |removed| {
        var completion = removed.value;
        completion.deinit();
    }
}

fn destroyRequestTask(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) void {
    const token = request_ctx.request_task orelse return;
    if (runtime.requests.tasks.get(token)) |task|
        task.state = .done;
    runtime.requests.tasks.destroy(token);
    request_ctx.request_task = null;
}

fn freeLiveSlotOnce(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !void {
    if (request_ctx.live_slot_released)
        return;
    try runtime.observability.worker_metrics_state.freeLiveSlot(request_ctx.live_slot_index);
    request_ctx.live_slot_released = true;
}

/// Frees the response steps `request_ctx` still has waiting to be sent,
/// returning a stream chunk's credits to the gateway.
pub fn releasePendingIngressResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) void {
    switch (request_ctx.response_outbox.take()) {
        .none, .stream_end, .stream_reset => {},
        .buffered_body => |buffered| {
            var parked = buffered;
            if (parked.head) |*head|
                head.deinit(runtime.core.allocator);
            runtime.core.allocator.free(parked.body);
        },
        .stream_head => |stream_head| {
            var head = stream_head;
            head.deinit(runtime.core.allocator);
        },
        .stream_chunk => |stream_chunk| {
            var chunk = stream_chunk;
            runtime.releaseFetchBodyResponseStreamCredits(chunk.credits.slice());
            var released_credits = chunk.credits.take();
            released_credits.deinit(runtime.core.allocator);
            chunk.deinit(runtime.core.allocator);
            runtime.flushFetchBodyPoolReleases();
        },
    }
}
