//! Settlement of fetch body readers from the ready queue: a `fetch_body_ready`
//! item runs `executeReady`, which answers the waiting JavaScript promise in a
//! turn of the body's request and lets the body's decoder resume. Runs on the
//! worker's VM thread.
//!
//! A stored reader holds no reference of its own: it never outlives the
//! body's table entry, since every removal drops the reader and a release
//! that finds a reader waiting keeps the entry (`cleanup.releaseInternal`).
//! The settlement is the one span in which JavaScript runs while the body
//! must stay alive, since resolving a promise drains reactions that may
//! release the body and a collection there may sweep its Response, so the
//! settlement takes a reference of its own for its whole run and reads the
//! body's identity before any JavaScript runs.

const std = @import("std");
const bindings = @import("collo_bindings");
const promise_deferred = @import("collo_worker_js").deferred;
const turn = @import("collo_worker_js").turn;
const request_context = @import("collo_worker_request").context;
const Runtime = @import("../../runtime/root.zig").Runtime;
const gateway_control = @import("../gateway_control.zig");
const gateway_runtime = @import("../gateway_runtime.zig");
const body_mod = @import("body.zig");
const common = @import("common.zig");
const cleanup = @import("cleanup.zig");

const Body = body_mod.Body;

/// Runs the `fetch_body_ready` item of `body_id`; a body that is gone does
/// nothing. The scheduler hands an error to `cleanup.handleReadyFailure`.
pub fn executeReady(runtime: *Runtime, body_id: u64) !void {
    // Settlement runs first because it frees decoded-queue room for the
    // decoder; one pool-release wake then covers everything both consumed.
    defer gateway_control.flushBodyPoolReleases(runtime);
    try settleReady(runtime, body_id);
    // The settlement's JavaScript may have released the body.
    const body = runtime.egress.state.bodies.get(body_id) orelse return;
    try resumeBodyDecoder(runtime, body);
}

/// Lets the decoder of `body`, a body in the table, resume after its queue
/// lost bytes: a reader drained chunks below the decoded watermark, or a
/// cancel or release dropped them. The decoder's room is this body's queue
/// (`decoder.zig`), and it resumes only from here or from a new extent, so
/// every path that empties the queue of a body that keeps its decoder calls
/// this; otherwise a paused decoder whose end already arrived, or whose held
/// extents use up the gateway's window, never runs again and its clones
/// never complete. Once the gateway sent the body's end (`end_seen`) it runs
/// `finish` again, and completes the body only when the trailer flush
/// finished and every extent was consumed. A decode error fails the body;
/// only `error.OutOfMemory` propagates.
pub fn resumeBodyDecoder(runtime: *Runtime, body: *Body) !void {
    const allocator = runtime.core.allocator;
    const decoder = body.decoder orelse return;
    decoder.drainPending(allocator, body) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            gateway_runtime.failBodyDecode(runtime, body, err);
            return;
        },
    };
    if (decoder.end_seen) {
        const complete = decoder.finish(allocator, body) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                gateway_runtime.failBodyDecode(runtime, body, err);
                return;
            },
        };
        if (complete) {
            body.dropDecoder(allocator);
            body.complete();
        }
    }
    common.queueReadyViews(runtime, body);
}

/// `resumeBodyDecoder` for a caller that returns no error: running out of
/// memory fails the body and stops its fetch, as a decode error does.
pub fn resumeBodyDecoderOrFail(runtime: *Runtime, body: *Body) void {
    resumeBodyDecoder(runtime, body) catch |err| gateway_runtime.failBodyDecode(runtime, body, err);
}

/// Answers the body's reader. A pull gets its next chunk or the end; a
/// whole-body read gets its value once the body is complete or failed, and the
/// body then leaves the table. A reader whose request is gone or moved to a
/// new generation is dropped unanswered.
fn settleReady(runtime: *Runtime, body_id: u64) !void {
    const allocator = runtime.core.allocator;
    const body = runtime.egress.state.bodies.get(body_id) orelse return;
    // Declared first, so it runs last, after every use of `body` below.
    body.retain();
    defer body.release(allocator);
    const identity = body.identity;

    var pull = body.drainReadyForPull(allocator);
    defer pull.deinit(allocator);
    if (pull.waiter) |*waiter| {
        // A pull without a promise is a response stream's, which
        // `serve/response.zig` drains before this runs. Reaching here means
        // its request no longer streams this body, so the chunk is dropped.
        if (waiter.deferred == null)
            return;
        const request = runtime.requests.active.get(identity.request_id) orelse return;
        if (request.request_generation != identity.request_generation)
            return;

        const raw_deferred = try waiter.takeDeferredRaw();
        var deferred = promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw_deferred);
        defer deferred.deinit();

        if (pull.failed) {
            rejectFailure(runtime, request, &deferred, body) catch |err| {
                if (rejectSettlementError(runtime, request, &deferred, "fetch body pull rejection", err)) {
                    cleanup.cancel(runtime, identity);
                    return;
                }
                return err;
            };
            return;
        }

        var value = pullResultValue(bindings.promiseDeferredRealm(raw_deferred), &pull.bytes, pull.done) catch |err| {
            _ = rejectSettlementError(runtime, request, &deferred, "fetch body pull value", err);
            cleanup.cancel(runtime, identity);
            return;
        };
        defer value.deinit();
        turn.resolvePromise(runtime.core.vm, &request.exec, &deferred, &value) catch |err| {
            cleanup.cancel(runtime, identity);
            return err;
        };
        if (body.viewReleased()) {
            // The view was released, either by JavaScript the resolution ran
            // or by a release that arrived while this read was pending and
            // kept the body for it; either way the release finishes now. The
            // settlement's own reference keeps `body` valid even when its
            // table entry is already gone, and finds it gone without harm.
            _ = cleanup.releaseInternal(runtime, identity, false);
        }
        return;
    }

    var drain = try body.drainReadyForWaiter(allocator);
    defer drain.deinit(allocator);
    if (!drain.terminal)
        return;

    // A terminal body leaves the table once its reader is answered. The
    // JavaScript the answer runs may have released it first, so finding no
    // entry is no error.
    defer _ = cleanup.releaseInternal(runtime, identity, false);

    var waiter = drain.waiter orelse return;
    drain.waiter = null;
    defer waiter.deinit(allocator);

    const request = runtime.requests.active.get(identity.request_id) orelse return;
    if (request.request_generation != identity.request_generation)
        return;

    const raw_deferred = try waiter.takeDeferredRaw();
    var deferred = promise_deferred.DeferredOwned.fromRawOwnedNonNull(raw_deferred);
    defer deferred.deinit();

    if (body.isFailed()) {
        rejectFailure(runtime, request, &deferred, body) catch |err| {
            if (rejectSettlementError(runtime, request, &deferred, "fetch body read rejection", err)) {
                cleanup.cancel(runtime, identity);
                return;
            }
            return err;
        };
        return;
    }

    const bytes = body.borrowCompleteBytes() orelse return;
    resolveWaiter(runtime, request, &deferred, waiter, bytes) catch |err| {
        const rejected = rejectSettlementError(runtime, request, &deferred, "fetch body read settlement", err);
        cleanup.cancel(runtime, identity);
        if (!rejected)
            return err;
    };
}

/// Rejects the promise with a message naming `context` and `err` after the
/// settlement itself failed. Returns false when the promise was already taken
/// or this rejection failed too.
fn rejectSettlementError(
    runtime: *Runtime,
    request: *request_context.RequestContext,
    deferred: *promise_deferred.DeferredOwned,
    context: []const u8,
    err: anyerror,
) bool {
    if (deferred.raw == null)
        return false;
    var message_buf: [160]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, "{s}: {s}", .{ context, @errorName(err) }) catch
        "fetch body read failed";
    var error_value = runtime.core.vm.stringValueUtf8(message) catch |value_err| {
        std.log.warn("failed to create fetch body settlement rejection value: {s}", .{@errorName(value_err)});
        return false;
    };
    defer error_value.deinit();
    turn.rejectPromise(runtime.core.vm, &request.exec, deferred, &error_value) catch |reject_err| {
        std.log.warn("failed to reject fetch body promise after settlement error: {s}", .{@errorName(reject_err)});
        return false;
    };
    return true;
}

/// Rejects with the body's failure: the abort reason JavaScript gave, or else
/// its failure message.
fn rejectFailure(
    runtime: *Runtime,
    request: *request_context.RequestContext,
    deferred: *promise_deferred.DeferredOwned,
    body: *Body,
) !void {
    if (body.failureReasonRetained()) |reason| {
        var owned_reason = reason;
        defer owned_reason.deinit();
        try turn.rejectPromise(runtime.core.vm, &request.exec, deferred, &owned_reason);
        return;
    }
    const message = body.failureMessage() orelse "fetch body read failed";
    var error_value = try runtime.core.vm.stringValueUtf8(message);
    defer error_value.deinit();
    try turn.rejectPromise(runtime.core.vm, &request.exec, deferred, &error_value);
}

fn resolveWaiter(
    runtime: *Runtime,
    request: *request_context.RequestContext,
    deferred: *promise_deferred.DeferredOwned,
    waiter: body_mod.Waiter,
    bytes: []const u8,
) !void {
    const vm = runtime.core.vm;
    // The read's value belongs to the realm of the code that started it.
    const realm = try deferred.realm();
    switch (waiter.kind) {
        .text => {
            var text = try vm.stringValueUtf8(bytes);
            defer text.deinit();
            try turn.resolvePromise(vm, &request.exec, deferred, &text);
        },
        .json => try turn.settlePromiseValueResult(
            vm,
            &request.exec,
            deferred,
            try turn.jsonParseUtf8(vm, realm, &request.exec, bytes),
        ),
        .array_buffer => try turn.settlePromiseValueResult(vm, &request.exec, deferred, try realm.arrayBufferValueCopy(bytes)),
        .bytes => try turn.settlePromiseValueResult(vm, &request.exec, deferred, try realm.uint8ArrayValueCopy(bytes)),
        .blob => try turn.settlePromiseValueResult(
            vm,
            &request.exec,
            deferred,
            try realm.blobValueCopy(bytes, waiter.content_type),
        ),
        .form_data => try turn.settlePromiseValueResult(
            vm,
            &request.exec,
            deferred,
            try turn.formDataFromBytes(vm, realm, &request.exec, bytes, waiter.content_type),
        ),
    }
}

fn pullResultValue(realm: bindings.Realm, lease: *const body_mod.ByteLease, done: bool) !bindings.Value {
    const bytes: ?[]const u8 = if (lease.isPresent()) lease.bytes else null;
    return switch (try realm.fetchReadResultValueCopy(bytes, done)) {
        .success => |value| value,
        .exception => |exception| {
            var owned = exception;
            defer owned.deinit();
            return error.JsException;
        },
    };
}
