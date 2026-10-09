//! Creation of fetch bodies and the transitions that end them, on the worker's
//! event loop thread. A new body enters `State.bodies`, which holds its first
//! reference, and a transition that readies a reader queues the body.

const std = @import("std");
const bindings = @import("collo_bindings");
const request_context = @import("collo_worker_request").context;
const egress_context = @import("../context.zig");
const common = @import("common.zig");

const FetchBody = common.FetchBody;

/// Registers a complete body of `fetch_id` under `request`, holding a copy of
/// `bytes`, and returns its identity. Fails with `error.MaxBufferExceeded`
/// when `bytes` exceed `max_bytes`, or `error.OutOfMemory`; nothing stays
/// registered on failure.
pub fn registerComplete(
    runtime: *egress_context.Context,
    request: *const request_context.RequestContext,
    fetch_id: u64,
    bytes: []const u8,
    max_bytes: ?u64,
) !bindings.FetchBodyIdentity {
    const identity = common.nextIdentity(runtime, request, fetch_id);
    const body = try runtime.allocator.create(FetchBody);
    var body_initialized = false;
    errdefer {
        if (body_initialized)
            body.deinitAfterQueuedResourcesReleased(runtime.allocator);
        runtime.allocator.destroy(body);
    }
    body.* = try FetchBody.initComplete(runtime.allocator, identity, bytes, max_bytes);
    body_initialized = true;
    try runtime.egress_state.bodies.putNoClobber(runtime.allocator, identity.body_id, body);
    return identity;
}

/// Registers an open, empty body of `fetch_id` under `request` that accepts up
/// to `max_bytes`, or any amount when null, and returns its identity. Fails
/// only with `error.OutOfMemory`.
pub fn registerOpen(
    runtime: *egress_context.Context,
    request: *const request_context.RequestContext,
    fetch_id: u64,
    max_bytes: ?u64,
) !bindings.FetchBodyIdentity {
    const identity = common.nextIdentity(runtime, request, fetch_id);
    const body = try runtime.allocator.create(FetchBody);
    var body_initialized = false;
    errdefer {
        if (body_initialized)
            body.deinitAfterQueuedResourcesReleased(runtime.allocator);
        runtime.allocator.destroy(body);
    }
    body.* = FetchBody.initOpen(runtime.allocator, identity, max_bytes);
    body_initialized = true;
    try runtime.egress_state.bodies.putNoClobber(runtime.allocator, identity.body_id, body);
    return identity;
}

/// Appends a copy of `bytes` to the body's materialized bytes. Fails with
/// `error.FetchBodyNotFound` for a stale identity, or as `Body.append` does.
pub fn appendBytes(
    runtime: *egress_context.Context,
    identity: bindings.FetchBodyIdentity,
    bytes: []const u8,
) !void {
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    try body.append(bytes);
}

/// Completes the body; fails with `error.FetchBodyNotFound` for a stale
/// identity.
pub fn complete(runtime: *egress_context.Context, identity: bindings.FetchBodyIdentity) !void {
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    if (body.complete())
        try common.queueReady(runtime, body);
}

/// Fails an open body with `message`; a body without memory for the message
/// still fails, without one. Fails with `error.FetchBodyNotFound` for a stale
/// identity.
pub fn fail(
    runtime: *egress_context.Context,
    identity: bindings.FetchBodyIdentity,
    message: []const u8,
) !void {
    const body = common.ptr(runtime, identity) orelse return error.FetchBodyNotFound;
    const ready = body.fail(runtime.allocator, message) catch |err| blk: {
        std.log.warn("fetch body rich failure message failed body_id={d}: {s}", .{
            body.identity.body_id,
            @errorName(err),
        });
        break :blk body.failNoAlloc();
    };
    if (ready)
        try common.queueReady(runtime, body);
}
