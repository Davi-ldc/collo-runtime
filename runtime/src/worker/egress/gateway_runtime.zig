//! The worker's side of its egress gateway session: it reads packets from the
//! shared completion ring and applies each one (fetch head, body chunk batch,
//! body end, fetch error, stop acknowledgment) to the fetches, tasks and
//! bodies it names, and it attaches the worker to a session and detaches it.
//! Runs on the worker's VM thread.
//!
//! A body end, a fetch error and a stop's acknowledgment are a fetch's
//! terminal packets: the gateway stopped counting the fetch when it published
//! one, so the worker stops counting it when it reads one
//! (`State.endFetch`). A body chunk's bytes enter the record of the request
//! that started its fetch when the packet arrives, whatever happens to the
//! body afterwards.
//!
//! Every packet is adversarial input. A packet that does not decode, or whose
//! ids contradict live worker state, detaches the worker, while data the
//! origin controls, such as a body that will not decode, fails that fetch and
//! never the session.
//!
//! A detach does not end the worker by itself. It settles every fetch and
//! body that depended on the session and unmaps the endpoint, and the worker
//! keeps serving and refuses each fetch at once (`fetch_runtime.refusal`).
//! What follows depends on who ended the session. When the gateway hung up,
//! the server attaches the worker to the session of a new gateway (`attach`)
//! once it lost the gateway, or retires it once the gateway reported the
//! session removed for what the worker sent or left unread. When the worker
//! detached on its own (`detachForGatewayFault`), on a packet, a ring or a
//! pool state that only a gateway defect produces, the server sees only a
//! closed liveness pipe and gives it no new session, so the worker asks to
//! be retired (`runtime/retirement.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");
const Runtime = @import("../runtime/root.zig").Runtime;
const body_mod = @import("body/body.zig");
const decoder_mod = @import("body/decoder.zig");
const fetch_body_runtime = @import("body/root.zig");
const task_mod = @import("task.zig");
const task_runtime = @import("task_runtime.zig");
const gateway_control = @import("gateway_control.zig");
const upload_runtime = @import("upload_runtime.zig");

const Body = body_mod.Body;

/// The failure of every fetch and body a detach cuts off.
const detached_message = "fetch failed: egress gateway closed";

/// Detaches the worker from its gateway session, for `reason`, which one log
/// line names. It fails every active fetch, every open body and every complete
/// body that still has chunks queued, drops those chunks, returns each extent
/// the worker holds to the pool while the endpoint is still mapped, and
/// unmaps it. The event loop keeps running. A worker already detached, or a
/// write failure met inside the detach, does nothing.
pub fn disconnectWithReason(runtime: *Runtime, reason: []const u8) void {
    const state = &runtime.egress.state;
    if (state.detach_in_progress or state.shared == null)
        return;
    state.detach_in_progress = true;
    defer state.detach_in_progress = false;
    std.log.info("worker detached from its egress gateway: {s}", .{reason});
    failActiveFetches(runtime);
    // Parked uploads name tasks that `failActiveFetches` just settled.
    state.pending_uploads.clearRetainingCapacity();
    // Decoders go first, so their pending extents reach the release queue
    // while the endpoint is still mapped, then every queued chunk.
    state.dropAllDecoders(runtime.core.allocator);
    var bodies = state.bodies.valueIterator();
    while (bodies.next()) |body|
        body.*.releaseQueuedChunksPreservingWaiters(runtime.core.allocator);
    gateway_control.flushBodyPoolReleases(runtime);
    state.releaseEndpoint();
    // A release that failed before or during this detach belonged to the
    // session just released.
    state.body_pool_release_failed = false;
}

/// Detaches the worker, for `reason`, from a session whose packet, ring or
/// pool state only a gateway defect produces, and marks the worker to ask to
/// be retired (`State.detached_for_gateway_fault`). A worker already detached,
/// or a failure met inside a detach, does nothing, as `disconnectWithReason`
/// does.
pub fn detachForGatewayFault(runtime: *Runtime, reason: []const u8) void {
    const state = &runtime.egress.state;
    if (state.detach_in_progress or state.shared == null)
        return;
    state.detached_for_gateway_fault = true;
    disconnectWithReason(runtime, reason);
}

/// Detaches the worker when a body-pool release failed since the last call
/// (`State.body_pool_release_failed`). The event loop calls it after the
/// handlers of each pass, where no body or task is in use, which the release
/// itself could not promise.
pub fn detachAfterFailedRelease(runtime: *Runtime) void {
    if (!runtime.egress.state.body_pool_release_failed)
        return;
    detachForGatewayFault(runtime, "body_pool_release");
}

/// Attaches the worker to the session whose worker half `fds` holds, which
/// the server sends on the control socket once the worker's gateway was
/// replaced (`ipc.egress_attach`). A half that is not the worker's own, as
/// `State.checkAttach` judges it, is refused before anything changes. A
/// worker still attached, because the loop has not seen the old gateway hang
/// up yet, detaches first. Takes the fds once they are mapped; on failure
/// `fds` keeps every descriptor. Fails as `State.attach` does. The loop
/// watches the new session from its next wait (`scheduler/poll_backend.zig`).
pub fn attach(runtime: *Runtime, fds: *ipc.egress_shared.RawFds) !void {
    try runtime.egress.state.checkAttach(fds);
    disconnectWithReason(runtime, "replaced");
    try runtime.egress.state.attach(fds);
}

fn failActiveFetches(runtime: *Runtime) void {
    const state = &runtime.egress.state;
    var tasks = state.tasks.valueIterator();
    while (tasks.next()) |task|
        task_runtime.publishResult(runtime, task.*, .{ .failure = .{ .message = detached_message } });

    var bodies = state.bodies.valueIterator();
    while (bodies.next()) |entry| {
        const body = entry.*;
        // No gateway packet made the body ready here, so the enqueue must
        // not carry the last packet's stamp.
        body.ready_at_mono_ns = 0;
        failBodyCutOff(runtime, body);
        fetch_body_runtime.queueReadyViews(runtime, body);
    }
}

/// Fails `body` because the session it reads from goes away. An open body
/// fails. A complete body keeps its bytes unless chunks are still queued: the
/// detach drops every queued chunk, since most borrow the pool it unmaps,
/// and a body still complete would then hand its reader a truncated body, so
/// it is canceled with its tee branches.
fn failBodyCutOff(runtime: *Runtime, body: *Body) void {
    if (body.state == .complete and body.queuedBytes() != 0) {
        body.cancel(runtime.core.allocator, detached_message, null);
        return;
    }
    body.fail(runtime.core.allocator, detached_message);
}

/// Applies up to `max_packets` completion packets. Returns true when it
/// stopped at the bound, so more may be waiting, and false when the ring ran
/// empty or the worker detached.
pub fn collectPacketsBounded(runtime: *Runtime, max_packets: usize) !bool {
    // One wake covers every extent the decoders and the orphan path return
    // during the batch.
    defer gateway_control.flushBodyPoolReleases(runtime);
    // The gateway also signals returned upload extents and drained command
    // packets through the completion eventfd, so parked uploads resume after
    // the batch.
    defer upload_runtime.drainReleasesAndPump(runtime);
    var count: usize = 0;
    while (count < max_packets) : (count += 1) {
        if (!try collectPacketOne(runtime))
            return false;
        if (runtime.egress.state.shared == null)
            return false;
    }
    return max_packets != 0;
}

/// Applies the next completion packet and returns whether there was one; a
/// detached worker has none. A ring the gateway left corrupt, or a packet
/// that does not decode or whose ids contradict live state, detaches the
/// worker and returns false, so a broken gateway costs its session and never
/// the worker. Only `error.OutOfMemory` propagates.
fn collectPacketOne(runtime: *Runtime) !bool {
    const endpoint = if (runtime.egress.state.shared) |*endpoint| endpoint else return false;
    const packet = endpoint.completion.readPacket(runtime.core.dispatch_recv_scratch) catch {
        detachForGatewayFault(runtime, "ring_fault");
        return false;
    } orelse return false;
    handlePacketBytes(runtime, packet) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // A handler that already detached, as a failed command write does,
        // makes this a no-op.
        else => {
            detachForGatewayFault(runtime, "invalid_packet");
            return false;
        },
    };
    return true;
}

/// Applies one completion packet. Fails on a malformed packet, with
/// `error.InvalidEgressPacket` when its ids contradict live state or name a
/// pool range outside the pool, or with `error.OutOfMemory`.
fn handlePacketBytes(runtime: *Runtime, bytes: []const u8) !void {
    if (bytes.len < @sizeOf(u32))
        return error.ShortRead;
    const scratch = runtime.core.egress_decode_scratch;
    const kind = try ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)]));
    switch (kind) {
        .egress_fetch_head => try handleHead(runtime, try ipc.decodeEgressFetchHead(scratch, bytes)),
        .egress_body_chunk_batch => {
            for (try ipc.decodeEgressBodyChunkBatch(scratch, bytes)) |chunk|
                try handleBodyChunk(runtime, chunk);
        },
        .egress_body_end => try handleBodyEnd(runtime, try ipc.decodeEgressBodyEnd(bytes)),
        .egress_fetch_error => try handleError(runtime, try ipc.decodeEgressFetchError(bytes)),
        .egress_abort_ack => try handleAbortAck(runtime, try ipc.decodeEgressAbortAck(bytes)),
        else => return error.InvalidMessageKind,
    }
}

fn handleHead(runtime: *Runtime, head: ipc.EgressFetchHeadView) !void {
    const task = runtime.egress.state.tasks.get(head.fetch_id) orelse return;
    if (task.response_body_identity.body_id != head.body_id)
        return error.InvalidEgressPacket;
    // Either settlement this packet can drive, the success below or the
    // decoder's failure, carries the head's readiness time.
    task.ready_at_mono_ns = head.ready_at_mono_ns;

    // The gateway forwards an HTTP/2 response body still encoded and names
    // the origin's coding in the head, so the body is decoded here, inside
    // the tenant worker's cgroup. Only a body still in the table gets a
    // decoder; chunks of a released body take the orphan path in
    // `handleBodyChunk` and return to the pool undecoded.
    if (head.body_encoding != .identity) {
        if (runtime.egress.state.bodies.get(head.body_id)) |body| {
            // A second head for one body contradicts the fetch's state.
            if (body.decoder != null)
                return error.InvalidEgressPacket;
            installDecoder(runtime, body, head) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // A codec that refuses to start fails this fetch only.
                else => {
                    failFetchDecoderSetup(runtime, task, body, head, err);
                    return;
                },
            };
        }
    }

    const allocator = task.resultAllocator();
    task_runtime.publishResult(runtime, task, .{ .success = .{
        .status = head.status,
        .status_text = try allocator.dupe(u8, head.status_text),
        .url = try allocator.dupe(u8, head.url),
        .body_identity = task.response_body_identity,
        .headers = try task_mod.cloneBindResponseHeaders(allocator, head.headers),
        .redirected = (head.flags & ipc.egress_fetch_head_flag_redirected) != 0,
    } });
}

fn handleBodyChunk(runtime: *Runtime, chunk: ipc.EgressBodyChunkView) !void {
    const state = &runtime.egress.state;
    // A failed command write earlier in the batch may have detached the
    // worker, which leaves the rest of the batch nothing to apply.
    const endpoint = if (state.shared) |*endpoint| endpoint else return;
    if (chunk.len == 0)
        return error.InvalidEgressPacket;
    endpoint.body_pool.validateChunkRange(chunk.body_pool_offset, chunk.len) catch
        return error.InvalidEgressPacket;
    task_runtime.chargeFetchBytes(runtime, chunk.fetch_id, .received, chunk.len);
    const body = state.bodies.get(chunk.body_id) orelse {
        // The orphan path: no view reads the body any more, so the extent
        // goes straight back and the fetch is stopped, once.
        gateway_control.noteBodyPoolChunkReleased(runtime, chunk.body_pool_offset, chunk.len);
        task_runtime.stopFetch(runtime, chunk.fetch_id);
        return;
    };
    if (body.identity.fetch_id != chunk.fetch_id) {
        gateway_control.noteBodyPoolChunkReleased(runtime, chunk.body_pool_offset, chunk.len);
        return error.InvalidEgressPacket;
    }
    // The first stamp since the body's ready item last ran stays, so a later
    // chunk cannot move the end of the request's I/O interval forward while
    // the body waits for a reader. `Runtime.executeFetchBodyReady` zeroes
    // the stamp when the item runs.
    if (body.ready_at_mono_ns == 0)
        body.ready_at_mono_ns = chunk.ready_at_mono_ns;

    if (body.decoder) |decoder| {
        // An encoded body: the decoder owns the extent and releases it once
        // fully decoded, which is the flow-control refill. A decode or
        // budget error comes from the origin's data, so it fails the fetch
        // body and never the worker loop.
        fetch_body_runtime.pushGatewayBodyPoolChunkToDecoder(runtime, decoder, body, chunk) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                failBodyDecode(runtime, body, err);
                return;
            },
        };
    } else {
        // Returning the extent through the release queue is the
        // acknowledgment the gateway turns back into engine credit. An
        // append fails on body state the origin's data drives, so it ends
        // the fetch and never the worker loop; the ingest helper has already
        // returned the extent.
        fetch_body_runtime.appendGatewayBodyPoolChunk(runtime, body, chunk) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                task_runtime.stopFetch(runtime, chunk.fetch_id);
                return;
            },
        };
    }
    fetch_body_runtime.queueReadyViews(runtime, body);
}

fn handleBodyEnd(runtime: *Runtime, end: ipc.EgressBodyEndView) !void {
    runtime.egress.state.endFetch(end.fetch_id);
    // A body that left the table took its decoder with it.
    const body = runtime.egress.state.bodies.get(end.body_id) orelse return;
    if (body.identity.fetch_id != end.fetch_id)
        return error.InvalidEgressPacket;
    if (body.ready_at_mono_ns == 0)
        body.ready_at_mono_ns = end.ready_at_mono_ns;

    if (body.decoder) |decoder| {
        // `finish` latches `end_seen`. A trailer flush that pauses at the
        // decoded watermark completes the body only when the ready path runs
        // `finish` again after the reader drained.
        const complete = decoder.finish(runtime.core.allocator, body) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                failBodyDecode(runtime, body, err);
                return;
            },
        };
        if (complete) {
            body.dropDecoder(runtime.core.allocator);
            body.complete();
        }
    } else {
        body.complete();
    }
    fetch_body_runtime.queueReadyViews(runtime, body);
}

fn handleError(runtime: *Runtime, failure: ipc.EgressFetchErrorView) !void {
    const state = &runtime.egress.state;
    state.endFetch(failure.fetch_id);
    if (state.bodies.get(failure.body_id)) |body| {
        if (body.identity.fetch_id != failure.fetch_id)
            return error.InvalidEgressPacket;
        // The gateway sends no more chunks, so the decoder goes and returns
        // its pending encoded extents.
        body.dropDecoder(runtime.core.allocator);
        if (body.ready_at_mono_ns == 0)
            body.ready_at_mono_ns = failure.ready_at_mono_ns;
        body.fail(runtime.core.allocator, failure.message);
        fetch_body_runtime.queueReadyViews(runtime, body);
    }

    const task = state.tasks.get(failure.fetch_id) orelse return;
    task.ready_at_mono_ns = failure.ready_at_mono_ns;
    task_runtime.publishResult(runtime, task, .{ .failure = .{
        .message = try task.resultAllocator().dupe(u8, failure.message),
        .cause = failure.cause,
    } });
}

/// Applies the gateway's acknowledgment of a stop: the fetch's source body,
/// which the packet names, drops its decoder, and it and every clone still
/// open fail as aborted, since the gateway sends no more chunks for any of
/// them; a task still waiting fails as aborted. A view that already
/// completed or failed keeps its state.
fn handleAbortAck(runtime: *Runtime, ack: ipc.egress.AbortAckView) !void {
    const state = &runtime.egress.state;
    state.endFetch(ack.fetch_id);
    if (state.bodies.get(ack.body_id)) |body| {
        if (body.identity.fetch_id != ack.fetch_id)
            return error.InvalidEgressPacket;
        body.dropDecoder(runtime.core.allocator);
        body.fail(runtime.core.allocator, task_runtime.aborted_message);
        fetch_body_runtime.queueReadyViews(runtime, body);
    }
    if (state.tasks.get(ack.fetch_id)) |task| {
        task.canceled = true;
        task_runtime.publishResult(runtime, task, .{ .failure = .{ .message = task_runtime.aborted_message } });
    }
}

/// Gives `body` the streaming decoder the head's coding and limits call for.
/// Zeroed limits fall back to the decoder defaults
/// (`decoder.limitsFromHeadFields`).
fn installDecoder(runtime: *Runtime, body: *Body, head: ipc.EgressFetchHeadView) !void {
    const allocator = runtime.core.allocator;
    const encoding: decoder_mod.Encoding = switch (head.body_encoding) {
        .identity => unreachable,
        .gzip => .gzip,
        .deflate => .deflate,
        .br => .br,
    };
    const decoder = try allocator.create(decoder_mod.Decoder);
    errdefer allocator.destroy(decoder);
    decoder.* = try decoder_mod.Decoder.init(encoding, decoder_mod.limitsFromHeadFields(
        head.max_decoded_body_bytes,
        head.max_pending_decoded_bytes,
        head.max_decoded_to_encoded_ratio,
    ));
    body.decoder = decoder;
}

/// Fails the fetch whose decoder could not start: its body fails with the
/// error's name, the fetch is stopped and the task fails.
fn failFetchDecoderSetup(
    runtime: *Runtime,
    task: *task_mod.Task,
    body: *Body,
    head: ipc.EgressFetchHeadView,
    err: anyerror,
) void {
    // The head is the packet that made this body readable, as failed.
    if (body.ready_at_mono_ns == 0)
        body.ready_at_mono_ns = head.ready_at_mono_ns;
    body.fail(runtime.core.allocator, @errorName(err));
    fetch_body_runtime.queueReadyViews(runtime, body);
    task_runtime.stopFetch(runtime, head.fetch_id);
    task_runtime.publishResult(runtime, task, .{ .failure = .{ .message = "fetch response decoder unavailable" } });
}

/// Handles a decode or budget failure of an encoded body: drops the decoder,
/// which returns its pending extents, fails the body and stops the fetch. The
/// error's name, such as `FetchResponseTooLarge`,
/// `FetchCompressionRatioExceeded` or `InvalidCompressedResponse`, becomes
/// the body's failure message, as in the gateway engine's own failures.
pub fn failBodyDecode(runtime: *Runtime, body: *Body, err: anyerror) void {
    body.dropDecoder(runtime.core.allocator);
    body.fail(runtime.core.allocator, @errorName(err));
    fetch_body_runtime.queueReadyViews(runtime, body);
    task_runtime.stopFetch(runtime, body.identity.fetch_id);
}
