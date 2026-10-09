//! The worker's side of its egress gateway session: it reads packets from the
//! shared completion ring and applies each one (fetch head, body chunk batch,
//! body end, fetch error, abort ack) to the tasks and bodies it names, and it
//! attaches the worker to a session and detaches it. Runs on the worker's
//! event loop thread.
//!
//! Every packet is adversarial input. A packet that does not decode, or whose
//! ids contradict live worker state, detaches the worker, while data the
//! origin controls, such as a body that will not decode, fails that fetch and
//! never the session.
//!
//! A detach never ends the worker. It settles every fetch and body that
//! depended on the session and unmaps the endpoint; the worker then keeps
//! serving, refuses each fetch at once (`fetch_runtime.refusal`) and waits for
//! the server to attach it to the session of a new gateway (`attach`).

const std = @import("std");
const ipc = @import("collo_ipc");
const egress_core = @import("collo_egress_core");
const egress_context = @import("context.zig");
const task_mod = @import("task.zig");
const fetch_body_runtime = @import("body/root.zig");
const task_runtime = @import("task_runtime.zig");
const gateway_control = @import("gateway_control.zig");
const upload_runtime = @import("upload_runtime.zig");

/// The failure of every fetch and body a detach cuts off.
const detached_message = "fetch failed: egress gateway closed";

pub fn disconnect(runtime: *egress_context.Context) void {
    disconnectWithReason(runtime, "runtime");
}

/// Detaches the worker from its gateway session, for `reason`, which goes to
/// the trace. It fails every active fetch, every open body and every complete
/// body that still has chunks queued, drops those chunks, returns each extent
/// the worker holds to the pool while the endpoint is still mapped, and
/// unmaps it. The event loop keeps running. Does nothing when the worker is
/// detached.
pub fn disconnectWithReason(runtime: *egress_context.Context, reason: []const u8) void {
    if (runtime.egress_state.shared == null)
        return;
    runtime.traceRuntimeEvent("worker.egress_gateway.disconnect={s}", .{reason});
    failActiveFetches(runtime, detached_message);
    // Parked uploads name tasks that `failActiveFetches` just settled.
    upload_runtime.clearPendingUploads(runtime);
    drainBodyChunksBeforeEndpointClose(runtime);
    runtime.egress_state.releaseEndpoint();
    // A release that failed before or during this detach belonged to the
    // session just released.
    runtime.egress_state.body_pool_release_failed = false;
}

/// Detaches the worker when a body-pool release failed since the last call
/// (`State.body_pool_release_failed`). The event loop calls it after the
/// handlers of each pass, where no body or task is in use, which the release
/// itself could not promise.
pub fn detachAfterFailedRelease(runtime: *egress_context.Context) void {
    if (!runtime.egress_state.body_pool_release_failed)
        return;
    disconnectWithReason(runtime, "body_pool_release");
}

/// Attaches the worker to the session whose worker half `fds` holds, which
/// the server sends on the control socket once the worker's gateway was
/// replaced (`ipc.egress_attach`). A worker still attached, because the loop
/// has not seen the old gateway hang up yet, detaches first. Takes the fds
/// once they are mapped; on failure `fds` keeps every descriptor and the
/// worker stays detached. Fails as `State.attach` does. The loop polls the
/// new session from its next pass (`scheduler/uring_backend.zig`).
pub fn attach(runtime: *egress_context.Context, fds: *ipc.egress_shared.RawFds) !void {
    disconnectWithReason(runtime, "replaced");
    try runtime.egress_state.attach(fds);
    runtime.traceRuntimeEvent("worker.egress_gateway.attach", .{});
}

fn drainBodyChunksBeforeEndpointClose(runtime: *egress_context.Context) void {
    // Decoders go first so their pending encoded extents reach the release
    // queue while the endpoint is still mapped.
    runtime.egress_state.removeAllBodyDecoders(runtime.allocator);
    var body_it = runtime.egress_state.bodies.iterator();
    while (body_it.next()) |entry| {
        entry.value_ptr.*.releaseQueuedChunksPreservingWaitersCallback(
            runtime.allocator,
            @as(?*anyopaque, null),
            ignoreFetchBodyCredit,
        );
    }
    gateway_control.flushBodyPoolReleases(runtime);
}

fn failActiveFetches(runtime: *egress_context.Context, message: []const u8) void {
    var task_it = runtime.egress_state.tasks.iterator();
    while (task_it.next()) |entry| {
        const task = entry.value_ptr.*;
        const should_fail = !task.done;
        if (should_fail) {
            task_runtime.publishResult(runtime, task, .{ .failure = .{
                .message = message,
                .owned = false,
            } });
        }
    }

    var body_it = runtime.egress_state.bodies.iterator();
    while (body_it.next()) |entry| {
        const body = entry.value_ptr.*;
        // No gateway packet made the body ready here, so the enqueue below
        // must not carry the last packet's stamp.
        body.ready_at_mono_ns = 0;
        const ready = failBodyCutOff(runtime, body, message);
        _ = queueBodyReadyAfterGatewayMutation(runtime, body, ready);
    }
}

/// Fails `body` because the session it reads from goes away, and returns
/// whether a reader became ready. An open body fails. A complete body keeps
/// its bytes unless chunks are still queued: the detach drops every queued
/// chunk, since most borrow the pool it unmaps, and a body still complete
/// would then hand its reader a truncated body, so it is canceled with its
/// tee branches.
fn failBodyCutOff(runtime: *egress_context.Context, body: *egress_core.fetch_body.Body, message: []const u8) bool {
    if (body.state == .complete and body.queuedDecodedBytes() != 0) {
        return body.cancel(runtime.allocator, message, null) catch |err| blk: {
            std.log.warn("failed to cancel cut-off fetch body body_id={d}: {s}", .{
                body.identity.body_id,
                @errorName(err),
            });
            break :blk body.cancelNoAlloc();
        };
    }
    return body.fail(runtime.allocator, message) catch |err| blk: {
        std.log.warn("failed to mark fetch body failed after gateway disconnect body_id={d}: {s}", .{
            body.identity.body_id,
            @errorName(err),
        });
        break :blk body.failNoAlloc();
    };
}

/// Applies at most one completion packet.
pub fn collectPacket(runtime: *egress_context.Context) !void {
    defer gateway_control.flushBodyPoolReleases(runtime);
    // The gateway also signals returned upload extents and drained command
    // packets through the completion eventfd, so parked uploads resume here.
    defer upload_runtime.drainReleasesAndPump(runtime);
    _ = try collectPacketOne(runtime);
}

/// Applies up to `max_packets` completion packets. Returns true when it
/// stopped at the bound, so more may be waiting, and false when the ring ran
/// empty or the worker detached.
pub fn collectPacketsBounded(runtime: *egress_context.Context, max_packets: usize) !bool {
    // One wake covers every extent the decoders and the orphan path return
    // during the batch.
    defer gateway_control.flushBodyPoolReleases(runtime);
    // As in `collectPacket`, parked uploads resume after the batch.
    defer upload_runtime.drainReleasesAndPump(runtime);
    var count: usize = 0;
    while (count < max_packets) : (count += 1) {
        if (!try collectPacketOne(runtime))
            return false;
        if (runtime.egress_state.shared == null)
            return false;
    }
    return max_packets != 0;
}

/// Applies the next completion packet and returns whether there was one; a
/// detached worker has none. A ring the gateway left corrupt, or a packet
/// that does not decode or whose ids contradict live state, detaches the
/// worker and returns false, so a broken gateway costs its session and never
/// the worker. Only `error.OutOfMemory` propagates.
fn collectPacketOne(runtime: *egress_context.Context) !bool {
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return false;
    const packet = endpoint.completion.readPacket(runtime.dispatch_recv_scratch) catch {
        disconnectWithReason(runtime, "ring_fault");
        return false;
    } orelse return false;
    handlePacketBytes(runtime, packet) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // A handler that already detached, as a failed command write does,
        // makes this a no-op.
        else => {
            disconnectWithReason(runtime, "invalid_packet");
            return false;
        },
    };
    return true;
}

/// Applies one completion packet. Fails on a malformed packet, with
/// `error.InvalidEgressPacket` when its ids contradict live state or name a
/// pool range outside the pool, or with `error.OutOfMemory`.
pub fn handlePacketBytes(runtime: *egress_context.Context, bytes: []const u8) !void {
    if (bytes.len < @sizeOf(u32))
        return error.ShortRead;

    const kind = try ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)]));
    switch (kind) {
        .egress_fetch_head => try handleHead(runtime, try ipc.decodeEgressFetchHead(runtime.decode_scratch, bytes)),
        .egress_body_chunk_batch => {
            const chunks = try ipc.decodeEgressBodyChunkBatch(runtime.decode_scratch, bytes);
            for (chunks) |chunk|
                try handleBodyChunk(runtime, chunk);
        },
        .egress_body_end => try handleBodyEnd(runtime, try ipc.decodeEgressBodyEnd(bytes)),
        .egress_fetch_error => try handleError(runtime, try ipc.decodeEgressFetchError(bytes)),
        .egress_abort_ack => handleAbortAck(runtime, try ipc.decodeEgressAbortAck(bytes)),
        else => return error.InvalidMessageKind,
    }
}

fn handleHead(runtime: *egress_context.Context, head: ipc.EgressFetchHeadView) !void {
    const task = runtime.egress_state.tasks.get(head.fetch_id) orelse return;
    if (task.response_body_identity.body_id != head.body_id)
        return error.InvalidEgressPacket;
    // Either settlement this packet can drive, the success below or the
    // decoder setup failure, carries the head's readiness time.
    task.ready_at_mono_ns = head.ready_at_mono_ns;

    // The gateway forwards an HTTP/2 response body still encoded and names
    // the origin's coding in the head, so the body is decoded here, inside
    // the tenant worker's cgroup. A decoder that cannot be set up, as when a
    // codec library fails to load, fails the fetch and not the worker. A
    // decoder is installed only for a body still in the table, keeping the
    // rule that a decoder implies its body; chunks of a released body take
    // the orphan path in `handleBodyChunk` and return to the pool undecoded.
    if (head.body_encoding != .identity and runtime.egress_state.bodies.contains(head.body_id)) {
        installBodyDecoder(runtime, head) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                failFetchDecoderSetup(runtime, task, head, err);
                return;
            },
        };
    }

    const allocator = task.resultAllocator();
    const status_text = try allocator.dupe(u8, head.status_text);
    const url = try allocator.dupe(u8, head.url);
    const headers = try task_mod.cloneBindResponseHeaders(allocator, head.headers);
    task_runtime.publishResult(runtime, task, .{ .success = .{
        .status = head.status,
        .status_text = status_text,
        .url = url,
        .body_identity = task.response_body_identity,
        .headers = headers,
        .redirected = (head.flags & ipc.egress_fetch_head_flag_redirected) != 0,
    } });
}

fn handleBodyChunk(runtime: *egress_context.Context, chunk: ipc.EgressBodyChunkView) !void {
    // A failed command write earlier in the batch may have detached the
    // worker, which leaves the rest of the batch nothing to apply.
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return;
    if (chunk.len == 0)
        return error.InvalidEgressPacket;
    endpoint.body_pool.validateChunkRange(chunk.body_pool_offset, chunk.len) catch
        return error.InvalidEgressPacket;
    const body = runtime.egress_state.bodies.get(chunk.body_id) orelse {
        // The orphan path: the body was released, so the extent goes straight
        // back. A decoder never outlives its body, so this removal finds one
        // only if that rule broke.
        _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, chunk.body_id);
        gateway_control.noteBodyPoolChunkReleased(runtime, chunk.body_pool_offset, chunk.len);
        gateway_control.sendRelease(runtime, .{
            .request_id = 0,
            .request_generation = 0,
            .fetch_id = chunk.fetch_id,
            .body_id = chunk.body_id,
        });
        return;
    };
    if (body.identity.fetch_id != chunk.fetch_id) {
        gateway_control.noteBodyPoolChunkReleased(runtime, chunk.body_pool_offset, chunk.len);
        return error.InvalidEgressPacket;
    }
    // The first stamp since the body's ready item last ran stays, so a later
    // chunk cannot move the end of the request's io interval forward while
    // the body waits for a reader, in the ready queue or for the rescan after
    // a full queue. `Runtime.executeFetchBodyReady` zeroes the stamp when the
    // item runs.
    if (body.ready_at_mono_ns == 0)
        body.ready_at_mono_ns = chunk.ready_at_mono_ns;

    if (runtime.egress_state.body_decoders.get(chunk.body_id)) |decoder| {
        // An encoded body: the decoder owns the extent and releases it once
        // fully decoded, which is the flow-control refill, so no credit
        // message is sent. A decode or budget error comes from the origin's
        // data, so it fails the fetch body and never the worker loop.
        const ready = fetch_body_runtime.pushGatewayBodyPoolChunkToDecoder(
            runtime,
            decoder,
            body,
            chunk,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                failBodyDecode(runtime, body, err);
                return;
            },
        };
        setBodyMetersFromGateway(body, chunk.billed_sent_total, chunk.billed_received_total, chunk.cost_total);
        if (!queueBodyReadyAfterGatewayMutation(runtime, body, ready))
            return;
        return;
    }

    // No credit message is sent: returning the extent through the release
    // queue is the acknowledgment the gateway turns back into engine credit.
    // An append fails on body state the origin's data drives, such as a later
    // chunk of a batch whose earlier chunk already failed the body, so it
    // ends the fetch and never the worker loop. The ingest helper has already
    // returned the extent, and only `error.OutOfMemory` propagates.
    const ready = fetch_body_runtime.appendGatewayBodyPoolChunk(runtime, body, chunk, .none) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            gateway_control.sendCancel(runtime, chunk.fetch_id, "fetch body append failed");
            gateway_control.sendRelease(runtime, body.identity);
            return;
        },
    };
    setBodyMetersFromGateway(body, chunk.billed_sent_total, chunk.billed_received_total, chunk.cost_total);
    if (!queueBodyReadyAfterGatewayMutation(runtime, body, ready))
        return;
}

fn handleBodyEnd(runtime: *egress_context.Context, end: ipc.EgressBodyEndView) !void {
    const body = runtime.egress_state.bodies.get(end.body_id) orelse {
        _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, end.body_id);
        return;
    };
    if (body.identity.fetch_id != end.fetch_id)
        return error.InvalidEgressPacket;
    if (body.ready_at_mono_ns == 0)
        body.ready_at_mono_ns = end.ready_at_mono_ns;
    setBodyMetersFromGateway(body, end.billed_sent_total, end.billed_received_total, end.cost_total);

    if (runtime.egress_state.body_decoders.get(end.body_id)) |decoder| {
        // `finish` latches `end_seen`. When the trailer flush pauses at the
        // decoded watermark (`complete == false`), the ready path runs
        // `finish` again after the JS consumer drains, and only then
        // completes the body.
        const finish = decoder.finish(runtime.allocator, body) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                failBodyDecode(runtime, body, err);
                return;
            },
        };
        var ready = finish.ready;
        if (finish.complete) {
            _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, end.body_id);
            ready = body.complete() or ready;
        }
        if (!queueBodyReadyAfterGatewayMutation(runtime, body, ready))
            return;
        return;
    }

    if (!queueBodyReadyAfterGatewayMutation(runtime, body, body.complete()))
        return;
}

fn handleError(runtime: *egress_context.Context, failure: ipc.EgressFetchErrorView) !void {
    // The gateway sends no more chunks, so the decoder goes and returns its
    // pending encoded extents to the pool.
    _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, failure.body_id);
    if (runtime.egress_state.bodies.get(failure.body_id)) |body| {
        if (body.identity.fetch_id != failure.fetch_id)
            return error.InvalidEgressPacket;
        if (body.ready_at_mono_ns == 0)
            body.ready_at_mono_ns = failure.ready_at_mono_ns;
        setBodyMetersFromGateway(body, failure.billed_sent_total, failure.billed_received_total, failure.cost_total);
        const ready = body.fail(runtime.allocator, failure.message) catch |err| blk: {
            std.log.warn("fetch body gateway failure message failed body_id={d}: {s}", .{
                body.identity.body_id,
                @errorName(err),
            });
            break :blk body.failNoAlloc();
        };
        if (!queueBodyReadyAfterGatewayMutation(runtime, body, ready))
            return;
    }

    const task = runtime.egress_state.tasks.get(failure.fetch_id) orelse return;
    task.ready_at_mono_ns = failure.ready_at_mono_ns;
    const message = try task.resultAllocator().dupe(u8, failure.message);
    // The body's meters count the bytes of a fetch that failed after its
    // head. The task failure only carries the rejection message; counting
    // bytes for it too would count a failed streaming response twice.
    task_runtime.publishResult(runtime, task, .{ .failure = .{
        .message = message,
        .owned = true,
    } });
}

/// Folds the meter totals a gateway packet carries into the body. The totals
/// are absolute and each field keeps its maximum, so a repeated packet or a
/// stale snapshot counts nothing twice.
fn setBodyMetersFromGateway(
    body: *egress_core.fetch_body.Body,
    billed_sent_total: u64,
    billed_received_total: u64,
    cost_total: u64,
) void {
    body.setEgressMeters(.{
        .billed_sent = billed_sent_total,
        .billed_received = billed_received_total,
        .cost = cost_total,
    });
}

/// Applies the gateway's acknowledgment of a cancel or release: the named body
/// view drops its decoder and fails as aborted, and a task still waiting fails
/// as aborted.
fn handleAbortAck(runtime: *egress_context.Context, ack: ipc.egress.AbortAckView) void {
    if (ack.body_id != 0) {
        if (runtime.egress_state.bodies.get(ack.body_id)) |body| {
            if (body.identity.fetch_id == ack.fetch_id) {
                _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, ack.body_id);
                _ = body.cancelViewOnly(runtime.allocator, "fetch aborted", null) catch body.cancelViewOnlyNoAlloc();
            }
        }
    }
    if (runtime.egress_state.tasks.get(ack.fetch_id)) |task| {
        task.markCanceled();
        task_runtime.publishResult(runtime, task, .{ .failure = .{
            .message = "fetch aborted",
            .owned = false,
        } });
    }
}

/// Creates the body's streaming decoder from the limits the head carries.
/// Zeroed fields fall back to the decoder defaults
/// (`encoded_body.limitsFromHeadFields`), so a half-filled head never yields a
/// decoder with a zero budget. A second head for the same body fails with
/// `error.InvalidEgressPacket`.
fn installBodyDecoder(runtime: *egress_context.Context, head: ipc.EgressFetchHeadView) !void {
    if (runtime.egress_state.body_decoders.contains(head.body_id))
        return error.InvalidEgressPacket;
    const encoding: egress_core.decompress.Encoding = switch (head.body_encoding) {
        .identity => unreachable,
        .gzip => .gzip,
        .deflate => .deflate,
        .br => .br,
    };
    const limits = egress_core.encoded_body.limitsFromHeadFields(
        head.max_decoded_body_bytes,
        head.max_pending_decoded_bytes,
        head.max_decoded_to_encoded_ratio,
    );
    const decoder = try runtime.allocator.create(egress_core.encoded_body.Decoder);
    errdefer runtime.allocator.destroy(decoder);
    decoder.* = try egress_core.encoded_body.Decoder.init(encoding, limits);
    errdefer decoder.deinit(runtime.allocator);
    try runtime.egress_state.body_decoders.putNoClobber(runtime.allocator, head.body_id, decoder);
}

/// Fails the fetch whose decoder could not be set up: its body, when still
/// there, fails with the error's name, the gateway is told to stop, and the
/// task fails.
fn failFetchDecoderSetup(
    runtime: *egress_context.Context,
    task: *task_mod.Task,
    head: ipc.EgressFetchHeadView,
    err: anyerror,
) void {
    if (runtime.egress_state.bodies.get(head.body_id)) |body| {
        if (body.identity.fetch_id == head.fetch_id) {
            // The head is the packet that made this body readable, as failed.
            if (body.ready_at_mono_ns == 0)
                body.ready_at_mono_ns = head.ready_at_mono_ns;
            failBodyReady(runtime, body, @errorName(err));
        }
    }
    gateway_control.sendCancel(runtime, head.fetch_id, "fetch body decoder unavailable");
    gateway_control.sendRelease(runtime, .{
        .request_id = 0,
        .request_generation = 0,
        .fetch_id = head.fetch_id,
        .body_id = head.body_id,
    });
    task_runtime.publishResult(runtime, task, .{ .failure = .{
        .message = "fetch response decoder unavailable",
        .owned = false,
    } });
}

/// Handles a decode or budget failure on an encoded body: drops the decoder,
/// which returns its pending extents to the pool, fails the body and tells the
/// gateway to stop sending. The error's name, such as `FetchResponseTooLarge`,
/// `FetchCompressionRatioExceeded` or `InvalidCompressedResponse`, becomes the
/// body's failure message, as in the gateway engine's own body failures.
fn failBodyDecode(runtime: *egress_context.Context, body: *egress_core.fetch_body.Body, err: anyerror) void {
    _ = runtime.egress_state.removeBodyDecoder(runtime.allocator, body.identity.body_id);
    failBodyReady(runtime, body, @errorName(err));
    gateway_control.sendCancel(runtime, body.identity.fetch_id, "fetch body decode failed");
    gateway_control.sendRelease(runtime, body.identity);
}

fn failBodyReady(runtime: *egress_context.Context, body: *egress_core.fetch_body.Body, message: []const u8) void {
    const ready = body.fail(runtime.allocator, message) catch |err| blk: {
        std.log.warn("fetch body decode failure message failed body_id={d}: {s}", .{
            body.identity.body_id,
            @errorName(err),
        });
        break :blk body.failNoAlloc();
    };
    _ = queueBodyReadyAfterGatewayMutation(runtime, body, ready);
}

fn ignoreFetchBodyCredit(_: ?*anyopaque, _: egress_core.body_credit.Handle) void {}

fn queueClaimedBodyReady(
    runtime: *egress_context.Context,
    body: *egress_core.fetch_body.Body,
) bool {
    if (runtime.tryQueueReadyReadySince(
        .{ .fetch_body_ready = body.identity.body_id },
        body.ready_at_mono_ns,
    ))
        return true;
    body.clearReadyQueued();
    return false;
}

/// Queues `body` after a gateway packet changed it, when `ready` says a reader
/// became ready. A tee source also sets the body rescan flag, since a packet
/// that feeds the source can ready its branches, which only
/// `ready.collectReady` queues. Returns false when a full queue dropped the
/// claim.
fn queueBodyReadyAfterGatewayMutation(
    runtime: *egress_context.Context,
    body: *egress_core.fetch_body.Body,
    ready: bool,
) bool {
    if (body.hasTeeBranches())
        runtime.egress_state.fetch_body_rescan_needed = true;
    if (!ready)
        return true;
    if (!body.claimReadyForQueue())
        return true;
    return queueClaimedBodyReady(runtime, body);
}
