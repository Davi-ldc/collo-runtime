//! Sends a fetch's start packet and request body to the gateway, on the
//! worker's VM thread. A body up to
//! `ipc.fetch_limits.request_body_inline_preferred_bytes_max` rides inline in
//! the start packet. A larger one is flagged pooled in the start, which
//! carries its total length, and then streams as upload-pool extents that
//! batch packets on the command ring announce. The bytes of each go into the
//! request's record once their packet is in the ring
//! (`task_runtime.chargeFetchBytes`).
//!
//! Backpressure from the pool or the command ring is never fatal here: a task
//! that cannot progress parks in `State.pending_uploads` and resumes from the
//! completion pump. The gateway wakes that pump through the completion
//! eventfd both when it returns upload extents and after a drain pass that
//! found commands dropped on a full ring, so a parked task is always woken
//! once space returns.
//!
//! A pooled start also waits for room in the session's upload reservations
//! (`State.uploadRoom`), reserving its body's length and the copies of its
//! start the gateway keeps (`ipc.fetch_limits.pooledStartHeldBytes`), so the
//! worker never sends more than the gateway admits in flight. Room returns
//! only with a terminal packet of a reserved fetch, after which the pump
//! runs, and a start waits only while some fetch holds a reservation, since
//! one start never exceeds the whole room.

const std = @import("std");
const ipc = @import("collo_ipc");
const Runtime = @import("../runtime/root.zig").Runtime;
const task_mod = @import("task.zig");
const task_runtime = @import("task_runtime.zig");
const gateway_control = @import("gateway_control.zig");
const gateway_runtime = @import("gateway_runtime.zig");

const FetchTask = task_mod.Task;

/// Segments per pool transaction, and so descriptors per batch packet. It
/// bounds the stack arrays; a body that needs more takes more transactions.
const max_segments_per_batch: usize = 128;

/// Drives `task` until the gateway holds its start packet and every
/// request-body byte, or parks it on backpressure. Any other error propagates:
/// `fetch_runtime.schedule` unwinds, and the pump fails the task.
pub fn ensureTaskUploadProgress(runtime: *Runtime, task: *FetchTask) !void {
    if (!task.start_sent) {
        sendStart(runtime, task) catch |err| switch (err) {
            error.EgressSharedRingFull => return park(runtime, task),
            error.EgressUploadRoomExhausted => {
                runtime.egress.state.upload_room_waiter = true;
                return park(runtime, task);
            },
            else => return err,
        };
    }
    if (task.uploadRemaining() == 0)
        return;
    // Parked tasks go first: a fresh fetch must not jump ahead of uploads
    // that backpressure interrupted.
    if (!task.upload_parked and runtime.egress.state.pending_uploads.items.len != 0)
        return park(runtime, task);
    try progressPooledBody(runtime, task);
}

/// Takes back the upload extents the gateway returned and resumes parked
/// uploads. The completion pump calls it, because both signals arrive through
/// the completion eventfd.
pub fn drainReleasesAndPump(runtime: *Runtime) void {
    drainUploadReleases(runtime);
    pumpPendingUploads(runtime);
}

fn sendStart(runtime: *Runtime, task: *FetchTask) !void {
    const state = &runtime.egress.state;
    const request = runtime.requests.active.get(task.request_id) orelse return error.FetchOutsideActiveRequest;
    const fetch = state.fetches.getPtr(task.id) orelse return error.FetchNotCounted;
    // `fetch_runtime.schedule` held the headers to the start's bounds.
    std.debug.assert(task.headers.len <= ipc.max_request_header_count);
    var header_storage: [ipc.max_request_header_count]ipc.RequestHeader = undefined;
    for (task.headers, 0..) |header, index|
        header_storage[index] = .{ .name = header.name, .value = header.value };
    const pooled = task.bodyPooled();
    // A pooled start holds its body and the copies of its start in the
    // gateway, which counts the same sum against the session's room.
    const reserved_bytes: u64 = if (pooled)
        task.body.len + ipc.fetch_limits.pooledStartHeldBytes(task.method.len, task.url.len, task.headers)
    else
        0;
    // A start waiting for room already goes first, so a small start cannot
    // keep a large one waiting.
    if (pooled and (state.upload_room_waiter or reserved_bytes > state.uploadRoom()))
        return error.EgressUploadRoomExhausted;

    // The token is the start's only identity (`ipc.EgressFetchStartHeader`),
    // so the worker's own ids never reach the gateway: a request's start
    // names the request the server minted its token for, and every
    // evaluation's start presents its copy of the boot token, whichever
    // evaluation id owns the fetch inside the worker. `fetch_runtime.schedule`
    // already refused an owner without a token; this check keeps `none` off
    // the wire on every later pass too.
    if (ipc.egress_token.isNone(&request.dispatch_work.egress_token))
        return error.FetchWithoutEgressToken;
    const bytes = try ipc.encodeEgressFetchStartInto(runtime.core.dispatch_recv_scratch, .{
        .fetch_id = task.id,
        .egress_token = request.dispatch_work.egress_token,
        .body_id = task.response_body_identity.body_id,
        .flags = if (pooled) task.flags | ipc.egress_fetch_start_flag_body_pooled else task.flags,
        .method = task.method,
        .url = task.url,
        .headers = header_storage[0..task.headers.len],
        .body = if (pooled) &.{} else task.body,
        .pooled_body_len = if (pooled) task.body.len else 0,
    });
    try gateway_control.tryQueuePacketReserved(runtime, bytes, ipc.egress_shared.command_control_reserve_bytes);
    task.start_sent = true;
    state.noteStartSent(fetch, reserved_bytes);
    if (!pooled)
        task_runtime.chargeFetchBytes(runtime, task.id, .sent, task.body.len);
}

fn progressPooledBody(runtime: *Runtime, task: *FetchTask) !void {
    const endpoint = if (runtime.egress.state.shared) |*endpoint| endpoint else return error.PeerClosed;
    while (task.uploadRemaining() > 0) {
        const remaining: usize = @intCast(task.uploadRemaining());
        const want = @min(remaining, passShareBytes(runtime, endpoint), max_segments_per_batch * ipc.egress_shared.body_pool_block_size);
        if (want == 0)
            return park(runtime, task);

        var transaction = endpoint.upload_pool.beginWriteTransaction() catch |err| {
            gateway_runtime.detachForGatewayFault(runtime, "upload_pool");
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
                gateway_runtime.detachForGatewayFault(runtime, "upload_pool");
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
            gateway_runtime.detachForGatewayFault(runtime, "upload_pool");
            return err;
        };
        const packet_bytes = ipc.encodeEgressUploadChunkBatchInto(
            runtime.core.dispatch_recv_scratch,
            .{ .chunks = chunk_storage[0..segments.len] },
        ) catch |err| {
            transaction.rollback();
            gateway_runtime.detachForGatewayFault(runtime, "upload_pool");
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
        task_runtime.chargeFetchBytes(runtime, task.id, .sent, running_total - task.upload_bytes_sent);
        task.upload_bytes_sent = running_total;
    }
    task.upload_parked = false;
}

/// The bytes one pass may write: the free pool split across every upload
/// contending for it, this task and the parked queue, and never less than one
/// block, so the head of the queue always progresses.
fn passShareBytes(runtime: *Runtime, endpoint: *ipc.egress_shared.Endpoint) usize {
    const free_blocks = endpoint.upload_pool.freeBlocks();
    if (free_blocks == 0)
        return 0;
    const contenders = runtime.egress.state.pending_uploads.items.len + 1;
    const share_blocks = @max(@as(usize, 1), free_blocks / contenders);
    return share_blocks * ipc.egress_shared.body_pool_block_size;
}

fn park(runtime: *Runtime, task: *FetchTask) void {
    if (task.upload_parked)
        return;
    runtime.egress.state.pending_uploads.append(runtime.core.allocator, task.id) catch {
        // Without a queue slot nothing would retry the upload, so the fetch
        // fails rather than leave its promise pending forever.
        failUploadTask(runtime, task, "fetch upload backpressure queue exhausted");
        return;
    };
    task.upload_parked = true;
}

fn pumpPendingUploads(runtime: *Runtime) void {
    const state = &runtime.egress.state;
    // Every start that still finds no room in this pass sets it again.
    state.upload_room_waiter = false;
    if (state.pending_uploads.items.len == 0)
        return;
    // The queue moves aside and unfinished tasks park again in the fresh
    // list, which keeps the passes round-robin.
    var pending = state.pending_uploads;
    state.pending_uploads = .{};
    defer pending.deinit(runtime.core.allocator);
    for (pending.items) |fetch_id| {
        const task = state.tasks.get(fetch_id) orelse continue;
        task.upload_parked = false;
        if (task.done or task.canceled)
            continue;
        ensureTaskUploadProgress(runtime, task) catch |err| switch (err) {
            error.PeerClosed => return,
            else => failUploadTask(runtime, task, @errorName(err)),
        };
        if (state.shared == null)
            return;
    }
}

fn drainUploadReleases(runtime: *Runtime) void {
    const endpoint = if (runtime.egress.state.shared) |*endpoint| endpoint else return;
    _ = endpoint.upload_pool.drainReleasedChunksObserved({}, observeNothing) catch |err| {
        std.log.warn("egress upload pool release drain failed: {s}", .{@errorName(err)});
        gateway_runtime.detachForGatewayFault(runtime, "upload_pool");
    };
}

fn observeNothing(_: void, _: ipc.egress_shared.BodyPoolView.ReleasedExtent) void {}

/// Fails the fetch with `message`, which must outlive the task, and stops it
/// (`task_runtime.stopFetch`).
fn failUploadTask(runtime: *Runtime, task: *FetchTask, message: []const u8) void {
    task_runtime.publishResult(runtime, task, .{ .failure = .{ .message = message } });
    task_runtime.stopFetch(runtime, task.id);
}
