//! A handler's reads of its request body (`text`, `json`, `arrayBuffer`,
//! `bytes`, `blob` and `formData`). A read parks its promise on the
//! request's body pipe, and once the body is complete or has failed a
//! `request_body_ready` work item settles it with a value built from the
//! buffered bytes, which stay with the request. Runs on the worker's VM
//! thread.
//!
//! A body is read at most once, and only by the request whose id and
//! generation the call names. The read's deferred belongs to this file from
//! the call on: a failed schedule releases it unsettled, as abi.h requires
//! of the `collo_runtime_request_*` exports, and a read still pending when
//! its request ends is rejected (`rejectPendingRead`).

const promise_deferred = @import("collo_worker_js").deferred;
const request_context = @import("context.zig");
const ingress_runtime = @import("ingress/runtime.zig");
const turn = @import("collo_worker_js").turn;

pub fn scheduleText(
    runtime: anytype,
    request_id: u64,
    request_generation: u64,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    return schedule(runtime, request_id, request_generation, deferred, .text, "");
}

pub fn scheduleJson(
    runtime: anytype,
    request_id: u64,
    request_generation: u64,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    return schedule(runtime, request_id, request_generation, deferred, .json, "");
}

pub fn scheduleArrayBuffer(
    runtime: anytype,
    request_id: u64,
    request_generation: u64,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    return schedule(runtime, request_id, request_generation, deferred, .array_buffer, "");
}

pub fn scheduleBytes(
    runtime: anytype,
    request_id: u64,
    request_generation: u64,
    deferred: promise_deferred.DeferredOwned,
) !u64 {
    return schedule(runtime, request_id, request_generation, deferred, .bytes, "");
}

pub fn scheduleBlob(
    runtime: anytype,
    request_id: u64,
    request_generation: u64,
    deferred: promise_deferred.DeferredOwned,
    content_type: []const u8,
) !u64 {
    return schedule(runtime, request_id, request_generation, deferred, .blob, content_type);
}

pub fn scheduleFormData(
    runtime: anytype,
    request_id: u64,
    request_generation: u64,
    deferred: promise_deferred.DeferredOwned,
    content_type: []const u8,
) !u64 {
    return schedule(runtime, request_id, request_generation, deferred, .form_data, content_type);
}

/// The contract of every `schedule*` function above. Takes `deferred` on
/// every path, parks the read and returns its task id, queueing the work
/// item at once when the body is already complete or failed. `content_type`
/// is copied for a blob or form-data read and ignored otherwise. Fails with
/// `error.RequestBodyOutsideActiveRequest` when the id and generation name
/// no active request, and `error.RequestBodyAlreadyUsed` when the body was
/// read before or has a read pending.
fn schedule(
    runtime: anytype,
    request_id: u64,
    request_generation: u64,
    deferred: promise_deferred.DeferredOwned,
    kind: request_context.BodyReadKind,
    content_type: []const u8,
) !u64 {
    var owned_deferred = deferred;
    errdefer owned_deferred.deinit();

    const request = runtime.requests.active.get(request_id) orelse return error.RequestBodyOutsideActiveRequest;
    if (request.exec.request_id != request_id)
        return error.RequestBodyOutsideActiveRequest;
    if (request.request_generation != request_generation)
        return error.RequestBodyOutsideActiveRequest;
    if (request.body.isUsed() or request.body.hasWaiter())
        return error.RequestBodyAlreadyUsed;

    const task_id = runtime.requests.next_body_task_id;
    runtime.requests.next_body_task_id += 1;

    var waiter = request_context.BodyWaiter{
        .task_id = task_id,
        .kind = kind,
        .content_type = if (kind == .blob or kind == .form_data) try request.requestAllocator().dupe(u8, content_type) else "",
        .deferred = owned_deferred,
    };
    owned_deferred = .{};
    var waiter_stored = false;
    errdefer if (!waiter_stored)
        waiter.deinit(request.requestAllocator());
    request.body.beginRead(request.requestAllocator(), waiter) catch {
        return error.RequestBodyDeferredAlreadyOwned;
    };
    waiter_stored = true;
    errdefer request.body.rollbackWaiterForScheduleFailure();

    if (requestBodyReadReady(request)) {
        _ = ingress_runtime.queueBodyReady(runtime, request);
    }
    return task_id;
}

/// Runs the `request_body_ready` work item of `request_id`: resolves the
/// pending read with the body, or rejects it when the body failed. A
/// request that is gone is skipped. Fails with
/// `error.RequestBodyNotComplete` when the item ran before the body
/// completed, or with the settlement's error.
pub fn executeReady(runtime: anytype, request_id: u64) !void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    request_ctx.body_ready_queued = false;
    if (request_ctx.body.pipe.state == .errored) {
        try rejectPendingRead(runtime, request_ctx);
        return;
    }
    if (!request_ctx.body.isComplete())
        return error.RequestBodyNotComplete;
    try resolveWaiter(runtime, request_ctx);
}

/// Rejects the request's pending read, if it has one, with the reason its
/// body failed, or with "request body unavailable" when the body did not
/// fail. Request cleanup calls it so that no read outlives its request.
pub fn rejectPendingRead(
    runtime: anytype,
    request_ctx: *request_context.RequestContext,
) !void {
    var waiter = request_ctx.body.takeWaiter() orelse return;
    defer waiter.deinit(request_ctx.requestAllocator());

    const message = request_ctx.body.pipe.error_message orelse "request body unavailable";
    var error_value = try runtime.core.vm.stringValueUtf8(message);
    defer error_value.deinit();
    try turn.rejectPromise(runtime.core.vm, &request_ctx.exec, &waiter.deferred, &error_value);
}

/// Whether the request has a pending read that can settle now, because its
/// body is complete or has failed.
pub fn requestBodyReadReady(request_ctx: *const request_context.RequestContext) bool {
    if (!request_ctx.body.hasWaiter())
        return false;
    if (request_ctx.body.isComplete())
        return true;
    return request_ctx.body.pipe.state == .errored;
}

fn resolveWaiter(runtime: anytype, request_ctx: *request_context.RequestContext) !void {
    var waiter = request_ctx.body.takeWaiter() orelse return;
    defer waiter.deinit(request_ctx.requestAllocator());

    // The read's value belongs to the realm of the code that started it.
    const realm = try waiter.deferred.realm();
    switch (waiter.kind) {
        .text => {
            var text = try runtime.core.vm.stringValueUtf8(request_ctx.body.textSlice());
            defer text.deinit();
            try turn.resolvePromise(runtime.core.vm, &request_ctx.exec, &waiter.deferred, &text);
        },
        .json => {
            try turn.settlePromiseValueResult(
                runtime.core.vm,
                &request_ctx.exec,
                &waiter.deferred,
                try turn.jsonParseUtf8(runtime.core.vm, realm, &request_ctx.exec, request_ctx.body.textSlice()),
            );
        },
        .array_buffer => {
            try turn.settlePromiseValueResult(
                runtime.core.vm,
                &request_ctx.exec,
                &waiter.deferred,
                try realm.arrayBufferValueCopy(request_ctx.body.textSlice()),
            );
        },
        .bytes => {
            try turn.settlePromiseValueResult(
                runtime.core.vm,
                &request_ctx.exec,
                &waiter.deferred,
                try realm.uint8ArrayValueCopy(request_ctx.body.textSlice()),
            );
        },
        .blob => {
            try turn.settlePromiseValueResult(
                runtime.core.vm,
                &request_ctx.exec,
                &waiter.deferred,
                try realm.blobValueCopy(request_ctx.body.textSlice(), waiter.content_type),
            );
        },
        .form_data => {
            try turn.settlePromiseValueResult(
                runtime.core.vm,
                &request_ctx.exec,
                &waiter.deferred,
                try turn.formDataFromBytes(
                    runtime.core.vm,
                    realm,
                    &request_ctx.exec,
                    request_ctx.body.textSlice(),
                    waiter.content_type,
                ),
            );
        },
    }
}
