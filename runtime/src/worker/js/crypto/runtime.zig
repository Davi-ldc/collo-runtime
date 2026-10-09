//! The worker side of WebCrypto jobs: admits a job for an active request into
//! the crypto pool (`jobs.zig`) and settles or destroys the jobs it hands
//! back. It belongs to the `worker` module and runs on the VM thread, taking
//! the worker `Runtime` as `runtime`.
//!
//! A job settles in a turn of its own request, run from the loop's collect
//! pass (`collectFast` in `scheduler/loop.zig`) rather than from a ready-queue
//! work item, so this file does for that turn what the loop does for a work
//! item: it publishes the turn owner to the sentinel and records the turn in
//! the request's timeline.

const bindings = @import("collo_bindings");
const std = @import("std");
const turn = @import("collo_worker_js").turn;
const scheduler_resources = @import("../../scheduler/resources.zig");

/// Hands `job` to the crypto pool for the active request `request_id`. On
/// success the pool owns the job; on failure the caller keeps it. Fails with
/// `error.CryptoJobOutsideActiveRequest` for a request that is not active, or
/// with the pool's admission error.
pub fn scheduleJob(runtime: anytype, request_id: u64, job: *bindings.RawCryptoJob) !void {
    if (request_id == 0 or !runtime.requests.active.contains(request_id))
        return error.CryptoJobOutsideActiveRequest;
    try runtime.crypto.jobs.submit(request_id, job);
}

/// Discards the jobs of a finishing request; `collectCompleted` destroys
/// them later.
pub fn cancelForRequest(runtime: anytype, request_id: u64) void {
    runtime.crypto.jobs.cancelForRequest(request_id);
}

/// Destroys discarded jobs and settles completed ones, a bounded batch of
/// each per call. When jobs remain, it wakes the loop, which collects again on
/// its next pass. A failed settlement is logged and fails only its own
/// request.
pub fn collectCompleted(runtime: anytype) !void {
    var discarded_drained: usize = 0;
    while (discarded_drained < 16) : (discarded_drained += 1) {
        const entry = runtime.crypto.jobs.popDiscarded() orelse break;
        bindings.destroyCryptoJob(entry.job);
    }

    var completed_drained: usize = 0;
    while (completed_drained < 16) : (completed_drained += 1) {
        const entry = runtime.crypto.jobs.popCompleted() orelse break;
        executeCompletion(runtime, entry.request_id, entry.job, entry.completed_at_ns) catch |err| {
            std.log.warn("crypto job completion failed request_id={d}: {s}", .{
                entry.request_id,
                @errorName(err),
            });
            runtime.handleRequestFailure(entry.request_id, err);
        };
    }

    if (runtime.crypto.jobs.hasReady())
        runtime.wake();
}

/// Settles `job` in a turn of request `request_id`, or destroys it when the
/// request is gone, consuming it on every path.
fn executeCompletion(
    runtime: anytype,
    request_id: u64,
    job: *bindings.RawCryptoJob,
    completed_at_ns: u64,
) !void {
    const request = runtime.requests.active.get(request_id) orelse {
        bindings.destroyCryptoJob(job);
        return;
    };
    // The sentinel terminates the VM only when the published turn owner is
    // the request whose deadline expired (`handleExpiredDeadline` in
    // `runtime/sentinel.zig`). No work item published one for this turn, so
    // without this a continuation that hangs inside the settlement could
    // never be stopped.
    scheduler_resources.publishTurnOwner(runtime, request_id);
    defer scheduler_resources.clearTurnOwner(runtime);
    // The request's I/O time ends at the pool thread's completion stamp: the
    // job is counted ready at that stamp and consumed by this turn at once,
    // with no ready-queue item between. The request is looked up again after
    // the JavaScript runs, because the settlement may finish and destroy it
    // or fail. The turn's length counts toward the request's longest turn.
    const sub_turn_start = runtime.nowMonoNs();
    request.noteReady(completed_at_ns, sub_turn_start, true);
    request.noteTurnBegin(sub_turn_start, true);
    defer if (runtime.requests.active.get(request_id)) |still_alive| {
        const sub_turn_end = runtime.nowMonoNs();
        still_alive.noteTurnEnd(sub_turn_end);
        still_alive.max_turn_ns = @max(still_alive.max_turn_ns, sub_turn_end - sub_turn_start);
    };
    try turn.settleCryptoJob(runtime.core.vm, &request.exec, job);
}
