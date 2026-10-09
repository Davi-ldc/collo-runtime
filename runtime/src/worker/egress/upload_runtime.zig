//! Sends a fetch's start packet and request body to the gateway, on the
//! worker's event loop thread. A body up to
//! `ipc.fetch_limits.request_body_inline_preferred_bytes_max` rides inline in
//! the start packet. A larger one is flagged pooled in the start, which
//! carries its total length, and then streams as upload-pool extents that
//! batch packets on the command ring announce.
//!
//! Backpressure from the pool or the command ring is never fatal here: a task
//! that cannot progress parks in `State.pending_uploads` and resumes from the
//! completion pump. The gateway wakes that pump through the completion
//! eventfd both when it returns upload extents and after a drain pass that
//! found commands dropped on a full ring, so a parked task is always woken
//! once space returns.

const std = @import("std");
const ipc = @import("collo_ipc");
const egress_context = @import("context.zig");
const task_mod = @import("task.zig");
const task_runtime = @import("task_runtime.zig");
const gateway_control = @import("gateway_control.zig");

const FetchTask = task_mod.Task;

/// Segments per pool transaction, and so descriptors per batch packet. It
/// bounds the stack arrays; a body that needs more takes more transactions.
const max_segments_per_batch: usize = 128;

/// Drives `task` until the gateway holds its start packet and every
/// request-body byte, or parks it on backpressure. Any other error propagates:
/// `fetch_runtime.schedule` unwinds, and the pump fails the task.
pub fn ensureTaskUploadProgress(runtime: *egress_context.Context, task: *FetchTask) !void {
    if (!task.start_sent) {
        sendStart(runtime, task) catch |err| switch (err) {
            error.EgressSharedRingFull => return park(runtime, task),
            else => return err,
        };
        task.start_sent = true;
    }
    if (task.uploadRemaining() == 0)
        return;
    // Parked tasks go first: a fresh fetch must not jump ahead of uploads
    // that backpressure interrupted.
    if (!task.upload_parked and runtime.egress_state.pending_uploads.items.len != 0)
        return park(runtime, task);
    try progressPooledBody(runtime, task);
}

/// Takes back the upload extents the gateway returned and resumes parked
/// uploads. The completion pump calls it, because both signals arrive through
/// the completion eventfd.
pub fn drainReleasesAndPump(runtime: *egress_context.Context) void {
    drainUploadReleases(runtime);
    pumpPendingUploads(runtime);
}

/// Empties the pending-upload queue on a gateway disconnect, whose
/// `failActiveFetches` already settled every task it names.
pub fn clearPendingUploads(runtime: *egress_context.Context) void {
    runtime.egress_state.pending_uploads.clearRetainingCapacity();
}

fn sendStart(runtime: *egress_context.Context, task: *FetchTask) !void {
    const request = runtime.requests.get(task.request_id) orelse return error.FetchOutsideActiveRequest;
    var header_storage: [ipc.max_request_header_count]ipc.RequestHeader = undefined;
    if (task.headers.len > header_storage.len)
        return error.TooManyFetchHeaders;
    for (task.headers, 0..) |header, index|
        header_storage[index] = .{ .name = header.name, .value = header.value };
    const pooled = task.bodyPooled();
    if (task.body.len > ipc.fetch_limits.request_body_pooled_bytes_max)
        return error.EgressGatewayRequestBodyLimitExceeded;

    // The token is the start's only identity (`ipc.EgressFetchStartHeader`).
    // `fetch_runtime.schedule` already refused a request without one; this
    // check keeps `none` off the wire on every later pass too, since the
    // gateway counts a start it cannot verify against the worker's session.
    if (ipc.egress_token.isNone(&request.dispatch_work.egress_token))
        return error.FetchWithoutEgressToken;
    const bytes = try ipc.encodeEgressFetchStartInto(runtime.dispatch_recv_scratch, .{
        .fetch_id = task.id,
        .egress_token = request.dispatch_work.egress_token,
        .body_id = task.response_body_identity.body_id,
        .flags = if (pooled)
            task.flags | ipc.egress_fetch_start_flag_body_pooled
        else
            task.flags,
        .max_body_bytes = 0,
        .method = task.method,
        .url = task.url,
        .headers = header_storage[0..task.headers.len],
        .body = if (pooled) &.{} else task.body,
        .pooled_body_len = if (pooled) task.body.len else 0,
    });
    try gateway_control.tryQueuePacketReserved(
        runtime,
        bytes,
        ipc.egress_shared.command_control_reserve_bytes,
    );
}

fn progressPooledBody(runtime: *egress_context.Context, task: *FetchTask) !void {
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return error.PeerClosed;
    while (task.uploadRemaining() > 0) {
        const remaining: usize = @intCast(task.uploadRemaining());
        const want = @min(remaining, passShareBytes(runtime, endpoint), max_segments_per_batch * ipc.egress_shared.body_pool_block_size);
        if (want == 0)
            return park(runtime, task);

        var transaction = endpoint.upload_pool.beginWriteTransaction() catch |err| {
            runtime.disconnectEgressGateway();
            return err;
        };
        var segment_storage: [max_segments_per_batch]ipc.egress_shared.BodyPoolWriteTransaction.Segment = undefined;
        const sent: usize = @intCast(task.upload_bytes_sent);
        const segments = transaction.writeChunkContiguousSegments(
            task.body[sent..][0..want],
            &segment_storage,
        ) catch |err| switch (err) {
            error.EgressSharedRingFull => {
                transaction.rollback();
                return park(runtime, task);
            },
            else => {
                transaction.rollback();
                runtime.disconnectEgressGateway();
                return err;
            },
        };

        var chunk_storage: [max_segments_per_batch]ipc.EgressUploadChunkView = undefined;
        var running_total = task.upload_bytes_sent;
        for (segments, 0..) |segment, index| {
            running_total += @as(u64, segment.len);
            chunk_storage[index] = .{
                .fetch_id = task.id,
                .upload_pool_offset = segment.seq,
                .len = segment.len,
                .body_bytes_total = running_total,
            };
        }
        // The gateway learns of published extents only through this packet,
        // so when a full ring forces a rollback that frees them, it never saw
        // them, and the bytes go again on the next pass.
        transaction.publish() catch |err| {
            transaction.rollback();
            runtime.disconnectEgressGateway();
            return err;
        };
        const packet_bytes = ipc.encodeEgressUploadChunkBatchInto(
            runtime.dispatch_recv_scratch,
            .{ .chunks = chunk_storage[0..segments.len] },
        ) catch |err| {
            transaction.rollback();
            runtime.disconnectEgressGateway();
            return err;
        };
        gateway_control.tryQueuePacketReserved(
            runtime,
            packet_bytes,
            ipc.egress_shared.command_control_reserve_bytes,
        ) catch |err| switch (err) {
            error.EgressSharedRingFull => {
                transaction.rollback();
                return park(runtime, task);
            },
            else => return err,
        };
        transaction.commit();
        task.upload_bytes_sent = running_total;
    }
    task.upload_parked = false;
}

/// The bytes one pass may write: the free pool split across every upload
/// contending for it, this task and the parked queue, and never less than one
/// block, so the head of the queue always progresses.
fn passShareBytes(runtime: *egress_context.Context, endpoint: *ipc.egress_shared.Endpoint) usize {
    const free_blocks = endpoint.upload_pool.freeBlocks();
    if (free_blocks == 0)
        return 0;
    const contenders = @max(@as(usize, 1), runtime.egress_state.pending_uploads.items.len + 1);
    const share_blocks = @max(@as(usize, 1), free_blocks / contenders);
    return share_blocks * ipc.egress_shared.body_pool_block_size;
}

fn park(runtime: *egress_context.Context, task: *FetchTask) void {
    if (task.upload_parked)
        return;
    runtime.egress_state.pending_uploads.append(runtime.allocator, task.id) catch {
        // Without a queue slot nothing would retry the upload, so the fetch
        // fails rather than leave its promise pending forever.
        failUploadTask(runtime, task, "fetch upload backpressure queue exhausted");
        return;
    };
    task.upload_parked = true;
}

fn pumpPendingUploads(runtime: *egress_context.Context) void {
    if (runtime.egress_state.pending_uploads.items.len == 0)
        return;
    // The queue moves aside and unfinished tasks park again in the fresh
    // list, which keeps the passes round-robin.
    var pending = runtime.egress_state.pending_uploads;
    runtime.egress_state.pending_uploads = .{};
    defer pending.deinit(runtime.allocator);
    for (pending.items) |fetch_id| {
        const task = runtime.egress_state.tasks.get(fetch_id) orelse continue;
        if (task.done or task.isCanceled()) {
            task.upload_parked = false;
            continue;
        }
        task.upload_parked = false;
        ensureTaskUploadProgress(runtime, task) catch |err| switch (err) {
            error.PeerClosed => return,
            else => failUploadTask(runtime, task, @errorName(err)),
        };
        if (runtime.egress_state.shared == null)
            return;
    }
}

fn drainUploadReleases(runtime: *egress_context.Context) void {
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return;
    _ = endpoint.upload_pool.drainReleasedChunksObserved({}, observeNothing) catch |err| {
        std.log.warn("egress upload pool release drain failed: {s}", .{@errorName(err)});
        runtime.disconnectEgressGateway();
    };
}

fn observeNothing(_: void, _: ipc.egress_shared.BodyPoolView.ReleasedExtent) void {}

/// Fails the fetch with `message`, which must outlive the task, and tells the
/// gateway to drop it when the start already went out.
fn failUploadTask(runtime: *egress_context.Context, task: *FetchTask, message: []const u8) void {
    if (task.start_sent)
        gateway_control.sendCancel(runtime, task.id, "fetch upload failed");
    task_runtime.publishResult(runtime, task, .{ .failure = .{
        .message = message,
        .owned = false,
    } });
}
