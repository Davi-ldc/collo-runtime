//! Settlement of fetch body readers from the ready queue: a `fetch_body_ready`
//! item runs `executeReady`, which answers the waiting JS promise in a turn of
//! the body's request and lets the body's decoder resume. Runs on the worker's
//! event loop thread. Resolving a promise runs JS, which may release the body
//! being settled. In a stream pull, the reference `schedulePull` took keeps
//! the body's pointer valid after its table entry is gone.

const std = @import("std");
const bindings = @import("collo_bindings");
const egress_core = @import("collo_egress_core");
const promise_deferred = @import("collo_worker_js").deferred;
const turn = @import("collo_worker_js").turn;
const request_context = @import("collo_worker_request").context;
const egress_context = @import("../context.zig");
const gateway_control = @import("../gateway_control.zig");
const common = @import("common.zig");
const cleanup = @import("cleanup.zig");

const FetchBody = common.FetchBody;
const FetchBodyWaiter = common.FetchBodyWaiter;
const ByteLease = egress_core.ByteLease;

/// Runs the `fetch_body_ready` item of `body_id`; a body that is gone does
/// nothing. The scheduler hands an error to `cleanup.handleReadyFailure`.
pub fn executeReady(runtime: *egress_context.Context, body_id: u64) !void {
    // Settlement runs first because it frees decoded-queue capacity for the
    // decoder; one pool-release wake then covers everything both consumed.
    defer gateway_control.flushBodyPoolReleases(runtime);
    try settleReady(runtime, body_id);
    try resumeBodyDecoder(runtime, body_id);
}

/// Lets the body's decoder, if it has one, resume after the JS consumer
/// drained chunks below the decoded watermark. Once the gateway sent
/// `EgressBodyEnd` (`end_seen`) it runs `finish` again, and completes the body
/// only when the trailer flush finished and every extent was consumed. A
/// decode error fails the body; only `error.OutOfMemory` propagates.
fn resumeBodyDecoder(runtime: *egress_context.Context, body_id: u64) !void {
    const decoder = runtime.egress_state.body_decoders.get(body_id) orelse return;
    const body = runtime.egress_state.bodies.get(body_id) orelse {
        // Settlement released the body; dropping the decoder returns its
        // pending extents to the pool.
        _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, body_id);
        return;
    };

    var ready = decoder.drainPending(runtime.allocator, body) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            failBodyDecodeOnResume(runtime, body, err);
            return;
        },
    };
    if (decoder.end_seen) {
        const finish = decoder.finish(runtime.allocator, body) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                failBodyDecodeOnResume(runtime, body, err);
                return;
            },
        };
        ready = finish.ready or ready;
        if (finish.complete) {
            _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, body_id);
            ready = body.complete() or ready;
        }
    }
    if (ready and body.claimReadyForQueue()) {
        if (!runtime.tryQueueReadyReadySince(
            .{ .fetch_body_ready = body_id },
            body.ready_at_mono_ns,
        )) {
            body.clearReadyQueued();
            return;
        }
    }
}

/// Fails the body with the decode error's name, drops its decoder and stops
/// the fetch at the gateway, as `gateway_runtime.failBodyDecode` does for a
/// packet.
fn failBodyDecodeOnResume(runtime: *egress_context.Context, body: *FetchBody, err: anyerror) void {
    _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, body.identity.body_id);
    const ready = body.fail(runtime.allocator, @errorName(err)) catch body.failNoAlloc();
    if (ready and body.claimReadyForQueue()) {
        if (!runtime.tryQueueReadyReadySince(
            .{ .fetch_body_ready = body.identity.body_id },
            body.ready_at_mono_ns,
        )) {
            body.clearReadyQueued();
        }
    }
    gateway_control.sendCancel(runtime, body.identity.fetch_id, "fetch body decode failed");
    gateway_control.sendRelease(runtime, body.identity);
}

/// Answers the body's reader. A pull gets its next chunk or the end; a
/// whole-body read gets its value once the body is complete or failed, and the
/// body then leaves the table. A reader whose request is gone or moved to a
/// new generation is dropped unanswered.
fn settleReady(runtime: *egress_context.Context, body_id: u64) !void {
    const body = runtime.egress_state.bodies.get(body_id) orelse return;

    var pull = try body.drainReadyForPull(runtime.allocator);
    defer pull.deinit(runtime.allocator);
    for (pull.credits.slice()) |credit|
        gateway_control.releaseBodyCredit(runtime, credit);
    if (pull.waiter) |*waiter| {
        // A pull without a promise is a response stream's, which took no
        // reference and which `serve/response.zig` drains before this runs.
        // Reaching here means its request no longer streams this body, so the
        // chunk is dropped.
        if (waiter.deferred == null)
            return;
        defer body.releaseAfterQueuedResourcesReleased(runtime.allocator);
        common.accountEgress(runtime, body);
        const request = runtime.requests.get(body.identity.request_id) orelse return;
        if (request.request_generation != body.identity.request_generation)
            return;

        const raw_deferred = try waiter.takeDeferredRaw();
        var deferred = promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw_deferred);
        defer deferred.deinit();

        if (pull.failed) {
            rejectFailure(runtime, request, &deferred, body) catch |err| {
                if (rejectSettlementError(runtime, request, &deferred, "fetch body pull rejection", err)) {
                    cleanup.cancel(runtime, body.identity);
                    return;
                }
                return err;
            };
            return;
        }

        var value = pullResultValue(bindings.promiseDeferredRealm(raw_deferred), &pull.bytes, pull.done) catch |err| {
            _ = rejectSettlementError(runtime, request, &deferred, "fetch body pull value", err);
            cleanup.cancel(runtime, body.identity);
            return;
        };
        defer value.deinit();
        turn.resolvePromise(runtime.vm, &request.exec, &deferred, &value) catch |err| {
            cleanup.cancel(runtime, body.identity);
            return err;
        };
        if (body.viewReleased()) {
            // The view was released, either by JS that the resolution ran or
            // by a release that arrived while this read was pending and kept
            // the body for it; either way the release finishes now. The
            // reference `schedulePull` took is dropped only by the deferred
            // release above, so `body` is valid even when its table entry is
            // already gone.
            _ = cleanup.releaseInternal(runtime, body.identity, false);
        }
        return;
    }

    var drain = try body.drainReadyForWaiter(runtime.allocator);
    defer drain.deinit(runtime.allocator);
    for (drain.credits) |credit|
        gateway_control.releaseBodyCredit(runtime, credit);
    if (!drain.terminal)
        return;

    defer {
        const removed = cleanup.releaseInternal(runtime, body.identity, false);
        std.debug.assert(removed);
    }
    common.accountEgress(runtime, body);

    var waiter = drain.waiter orelse return;
    drain.waiter = null;
    defer body.releaseAfterQueuedResourcesReleased(runtime.allocator);
    defer waiter.deinit(runtime.allocator);

    const request = runtime.requests.get(body.identity.request_id) orelse return;
    if (request.request_generation != body.identity.request_generation)
        return;

    const raw_deferred = try waiter.takeDeferredRaw();
    var deferred = promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw_deferred);
    defer deferred.deinit();

    if (body.isFailed()) {
        rejectFailure(runtime, request, &deferred, body) catch |err| {
            if (rejectSettlementError(runtime, request, &deferred, "fetch body read rejection", err)) {
                cleanup.cancel(runtime, body.identity);
                return;
            }
            return err;
        };
        return;
    }

    const bytes = body.borrowCompleteBytes() orelse return;
    resolveWaiter(runtime, request, &deferred, waiter, bytes) catch |err| {
        if (rejectSettlementError(runtime, request, &deferred, "fetch body read settlement", err)) {
            cleanup.cancel(runtime, body.identity);
            return;
        }
        cleanup.cancel(runtime, body.identity);
        return err;
    };
}

/// Rejects the promise with a message naming `context` and `err` after the
/// settlement itself failed. Returns false when the promise was already taken
/// or this rejection failed too.
fn rejectSettlementError(
    runtime: *egress_context.Context,
    request: *request_context.RequestContext,
    deferred: *promise_deferred.DeferredOwned,
    context: []const u8,
    err: anyerror,
) bool {
    if (deferred.raw == null)
        return false;
    var message_buf: [160]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buf,
        "{s}: {s}",
        .{ context, @errorName(err) },
    ) catch "fetch body read failed";
    var error_value = runtime.vm.stringValueUtf8(message) catch |value_err| {
        std.log.warn("failed to create fetch body settlement rejection value: {s}", .{@errorName(value_err)});
        return false;
    };
    defer error_value.deinit();
    turn.rejectPromise(runtime.vm, &request.exec, deferred, &error_value) catch |reject_err| {
        std.log.warn("failed to reject fetch body promise after settlement error: {s}", .{@errorName(reject_err)});
        return false;
    };
    return true;
}

/// Rejects with the body's failure: the abort reason JS gave, or else its
/// failure message.
fn rejectFailure(
    runtime: *egress_context.Context,
    request: *request_context.RequestContext,
    deferred: *promise_deferred.DeferredOwned,
    body: *FetchBody,
) !void {
    if (body.failureReasonRetained()) |reason| {
        var owned_reason = reason;
        defer owned_reason.deinit();
        try turn.rejectPromise(runtime.vm, &request.exec, deferred, &owned_reason);
    } else {
        const message = body.failureMessage() orelse "fetch body read failed";
        var error_value = try runtime.vm.stringValueUtf8(message);
        defer error_value.deinit();
        try turn.rejectPromise(runtime.vm, &request.exec, deferred, &error_value);
    }
}

fn resolveWaiter(
    runtime: *egress_context.Context,
    request: *request_context.RequestContext,
    deferred: *promise_deferred.DeferredOwned,
    waiter: FetchBodyWaiter,
    bytes: []const u8,
) !void {
    // The read's value belongs to the realm of the code that started it.
    const realm = try deferred.realm();
    switch (waiter.kind) {
        .text => {
            var text = try runtime.vm.stringValueUtf8(bytes);
            defer text.deinit();
            try turn.resolvePromise(runtime.vm, &request.exec, deferred, &text);
        },
        .json => {
            try turn.settlePromiseValueResult(
                runtime.vm,
                &request.exec,
                deferred,
                try turn.jsonParseUtf8(runtime.vm, realm, &request.exec, bytes),
            );
        },
        .array_buffer => {
            try turn.settlePromiseValueResult(
                runtime.vm,
                &request.exec,
                deferred,
                try realm.arrayBufferValueCopy(bytes),
            );
        },
        .bytes => {
            try turn.settlePromiseValueResult(
                runtime.vm,
                &request.exec,
                deferred,
                try realm.uint8ArrayValueCopy(bytes),
            );
        },
        .blob => {
            try turn.settlePromiseValueResult(
                runtime.vm,
                &request.exec,
                deferred,
                try realm.blobValueCopy(bytes, waiter.content_type),
            );
        },
        .form_data => {
            try turn.settlePromiseValueResult(
                runtime.vm,
                &request.exec,
                deferred,
                try turn.formDataFromBytes(runtime.vm, realm, &request.exec, bytes, waiter.content_type),
            );
        },
    }
}

fn pullResultValue(realm: bindings.Realm, lease: *const ByteLease, done: bool) !bindings.Value {
    const bytes: ?[]const u8 = if (lease.isPresent()) lease.bytes() else null;
    return switch (try realm.fetchReadResultValueCopy(bytes, done)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.JsException;
        },
    };
}

/// Rescans every body after a full ready queue dropped a claim, folding each
/// body's meters and queueing those that are ready. It stops at the next full
/// queue and leaves the rescan flag set.
pub fn collectReady(runtime: *egress_context.Context) !void {
    if (!runtime.egress_state.fetch_body_rescan_needed)
        return;
    runtime.egress_state.fetch_body_rescan_needed = false;

    var iterator = runtime.egress_state.bodies.iterator();
    while (iterator.next()) |entry| {
        const body = entry.value_ptr.*;
        common.accountEgress(runtime, body);
        if (!body.claimReadyForQueue())
            continue;
        if (!runtime.tryQueueReadyReadySince(
            .{ .fetch_body_ready = body.identity.body_id },
            body.ready_at_mono_ns,
        )) {
            body.clearReadyQueued();
            runtime.egress_state.fetch_body_rescan_needed = true;
            return;
        }
    }
}
