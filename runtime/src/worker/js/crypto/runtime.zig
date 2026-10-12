//! The worker side of WebCrypto jobs: admits a job for an active owner, a
//! request or an evaluation, into the crypto pool (`jobs.zig`) and settles
//! or destroys the jobs it hands back. It belongs to the `worker` module and
//! runs on the VM thread, taking the worker `Runtime` as `runtime`.
//!
//! A job settles in a turn of its own owner, run from the loop's collect
//! pass (`collectFast` in `scheduler/loop.zig`) rather than from a ready-queue
//! work item, so this file does for that turn what the loop does for a work
//! item: it opens the owner's window (`runtime/owner.zig`), which publishes
//! the owner to the sentinel and records the turn in a request's timeline.
//! The CPU a pool thread spent on the job is the owner's too, charged at the
//! settlement, since the pool thread is the request's work as much as the VM
//! thread's windows are.

const bindings = @import("collo_bindings");
const std = @import("std");
const turn = @import("collo_worker_js").turn;
const request_context = @import("collo_worker_request").context;
const crypto_jobs = @import("jobs.zig");
const runtime_owner = @import("../../runtime/owner.zig");
const termination = @import("../../serve/termination.zig");

/// Hands `job` to the crypto pool for the active owner `request_id`, a
/// request or an evaluation. On success the pool owns the job; on failure
/// the caller keeps it. Fails with `error.CryptoJobOutsideActiveRequest` for
/// an owner that is not active or accepts no work
/// (`RequestContext.acceptsWork`), or with the pool's admission error.
pub fn scheduleJob(runtime: anytype, request_id: u64, job: *bindings.RawCryptoJob) !void {
    const owner = runtime.requests.active.get(request_id) orelse return error.CryptoJobOutsideActiveRequest;
    if (!owner.acceptsWork())
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
        executeCompletion(runtime, entry) catch |err| {
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

/// Settles the finished job of `entry` in a turn of its owner, a request or
/// an evaluation, or destroys it when that owner is gone, consuming it on
/// every path. The pool thread's CPU on the job is the owner's and is
/// charged before any of the owner's JavaScript runs, so a job that takes a
/// request to its CPU budget settles nothing: the job is destroyed and the
/// request answers 503 at once (`serve/termination.zig`), which the collect
/// pass may do, since it runs outside every owner window.
fn executeCompletion(runtime: anytype, entry: crypto_jobs.Entry) !void {
    const request_id = entry.request_id;
    const request = runtime.requests.active.get(request_id) orelse {
        bindings.destroyCryptoJob(entry.job);
        return;
    };
    runtime_owner.chargeContext(runtime, request, entry.cpu_ns);
    if (request.cpu_spent) {
        bindings.destroyCryptoJob(entry.job);
        if (!request_context.isReservedId(request_id))
            try termination.end(runtime, request, .cpu);
        return;
    }
    // No work item opened a window for this turn, so without this one a
    // continuation that hangs inside the settlement would run under no owner
    // the sentinel could stop. A request's I/O time ends at the pool
    // thread's completion stamp: the job is counted ready at that stamp and
    // consumed by this turn at once, with no ready-queue item between.
    if (!request_context.isReservedId(request_id))
        request.noteReady(entry.completed_at_ns, runtime.nowMonoNs(), true);
    const previous_owner_id = runtime_owner.enter(runtime, request_id, .{ .consumes_ready_item = true });
    defer runtime_owner.leave(runtime, previous_owner_id);
    try turn.settleCryptoJob(runtime.core.vm, &request.exec, entry.job);
}
