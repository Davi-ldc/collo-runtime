//! Finishes a request: seals its timeline, releases everything it holds,
//! appends its usage record to the shared page's record ring, publishes its
//! completion and signals the host. It runs on the worker's VM thread, at
//! most once per request. A response whose body still streams from a
//! ReadableStream ends here too: the finish cancels that stream when the
//! request's end leaves it budget to run the tenant's cancel algorithm
//! (`response_body_stream.cancelFor`), so a client's reset reaches the
//! stream as its reason.
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
const request_context = @import("collo_worker_request").context;
const response_body_stream = @import("response_body_stream.zig");
const runtime_owner = @import("../runtime/owner.zig");
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
/// finished, so the server's death synthesis still sees the request. The
/// finish is the request's own work, wherever it is called from, so it runs
/// in the request's owner window (`runtime/owner.zig`), and the record's CPU
/// holds every window up to the record, the finish's cleanup included.
pub fn finishRequest(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !FinishOutcome {
    const request_id = request_ctx.exec.request_id;
    // An evaluation has no response to finish. Finishing it would publish a
    // completion and a usage record with a zeroed dispatch identity and
    // destroy the context while its module's code may still use it. The
    // level is warn because a test exercises this refusal, and the test
    // runner fails a run on any err line.
    if (request_context.isReservedId(request_id)) {
        std.log.warn("refusing finishRequest for owner_id={d} (status={d})", .{ request_id, http_status });
        return error.InvalidArgument;
    }
    if (request_ctx.finish_started)
        return .already_finished;
    request_ctx.finish_started = true;

    const finished_mono_ns = runtime.nowMonoNs();
    // The timeline is sealed before the record is written. Inside one of the
    // request's own turns this closes nothing, since execution is neither
    // I/O nor waiting; outside its turns it closes the current slice at the
    // finish stamp, and the window opened below moves a sealed timeline no
    // further.
    request_ctx.noteFinish(finished_mono_ns);
    // Opened before the cleanup, which can run the request's JavaScript, and
    // closed after the context is gone, which charges nobody the tail.
    const previous_owner_id = runtime_owner.enter(runtime, request_id, .{});
    defer runtime_owner.leave(runtime, previous_owner_id);
    errdefer preserveFailedFinish(runtime, request_id);

    // A body stream the response still reads is cancelled here, first, in
    // this window and before the cleanup disarms the deadline, so the
    // tenant's cancel algorithm runs within the request's budget and its CPU
    // enters the record. `cancelFor` leaves out the ends that left no budget.
    response_body_stream.release(runtime, request_ctx, response_body_stream.cancelFor(done_status));
    cleanupRequestSubresources(runtime, request_ctx, .preserve_live_slot);
    try cleanupWebApiRequestOnce(runtime, request_ctx);
    if (done_status == .deadline_timeout)
        request_ctx.exec.termination_reason = @intFromEnum(bindings.TerminationReason.deadline);

    runtime_owner.foldOpenWindow(runtime, request_ctx);
    const cpu_ns = request_ctx.cpu_ns;

    {
        const worker_metrics_state = &runtime.observability.worker_metrics_state;
        // The live slot holds the request's CPU before the record is tried,
        // so a record that cannot be published still leaves it as the floor
        // the server's death record reports.
        try worker_metrics_state.updateLiveSlotCpu(request_ctx.live_slot_index, cpu_ns);
        // A full record ring means this request's usage record cannot be
        // published, so the worker stops here rather than in its callers,
        // several of which only log the error they get back.
        worker_metrics_state.appendCompletedRecord(.{
            .request_id = request_id,
            .request_generation = request_ctx.dispatch_work.request_generation,
            // The worker's partition of its own span of the request; the
            // server takes the wall time from its own clock.
            .exec_ns = request_ctx.execNs(),
            .waiting_ns = request_ctx.waiting_ns,
            .io_ns = request_ctx.io_time_ns,
            .cpu_ns = cpu_ns,
            .client_served_bytes = request_ctx.client_served_bytes,
            .fetch_sent_bytes = request_ctx.fetch_billed_sent_bytes,
            .fetch_received_bytes = request_ctx.fetch_billed_received_bytes,
            .fetch_wire_bytes = request_ctx.fetch_cost_bytes,
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
                .cpu_exceeded => worker_shared_page.CompletedStatus.cpu,
                .worker_retiring => worker_shared_page.CompletedStatus.worker_retiring,
                .worker_stopped => worker_shared_page.CompletedStatus.worker_stopped,
            }),
        }) catch |err| {
            if (err == error.CompletedRecordRingFull) {
                runtime.traceRuntimeEvent("worker.completion.record_append_failed={d},{s}", .{ request_id, @errorName(err) });
                runtime.traceRuntimeEvent("worker.runtime.stop=completed_record_ring_full,{d}", .{request_id});
                runtime.core.running = false;
            }
            return err;
        };
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
    // `finishRequest` released the body stream already, with its cancel;
    // this covers every other path, and runs nothing of the tenant's.
    response_body_stream.release(runtime, request_ctx, null);
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
