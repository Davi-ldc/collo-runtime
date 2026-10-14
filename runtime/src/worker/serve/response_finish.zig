//! Finishes a request: seals its timeline, releases everything it holds and
//! sends its last packet, the step that ends its response when one is left
//! (`LastStep`), with its `request_done` and what it measured as that
//! packet's last entry. It runs on the worker's VM thread, at most once per
//! request. A response whose body still streams from a ReadableStream ends
//! here too: the finish cancels that stream when the request's end leaves it
//! budget to run the tenant's cancel algorithm
//! (`response_body_stream.cancelFor`), so a client's reset reaches the
//! stream as its reason.
//!
//! `request_done` (`common/ipc/ingress_channel/framing.zig:RequestDone`) is
//! the last descriptor the worker sends for a request, and it rides the
//! packet that ends the response, so the server gives the request's slot
//! back as it reads the response's end; every response writer stops before
//! that packet and leaves it to the finish
//! (`response_payload_writer.zig:Ending`). The packet waits for the
//! request's cleanup, which can run the tenant's JavaScript, and its
//! `request_done` is written once the rest of it is composed
//! (`done_carry.zig`), so the record's CPU holds both. It carries only the
//! identity the dispatch assigned next to the worker's measurements, and the
//! server records them only under a request it dispatched to this worker,
//! so a worker cannot choose whose record they enter.
//!
//! A `request_done` alone that finds the control socket full waits in
//! `Requests.done_outbox`, and the context goes. A last packet that carries
//! a step of the response and finds no room waits with that step in the
//! request's response outbox and its record in
//! `RequestContext.last_packet_done`, and the context stays, finished, until
//! the advance that finds room sends both (`sendParkedLast`). The finish
//! leaves the request's live slot as it is, holding the request's final CPU
//! (`runtime/owner.zig:chargeContext`), so a worker that dies before the
//! packet goes out leaves the server that CPU to report. A worker that
//! cannot send a packet, or owes more than the done outbox holds, stops, and
//! the server ends its requests from their live slots.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const body_read = @import("collo_worker_request").body_read;
const request_context = @import("collo_worker_request").context;
const response_model = @import("collo_worker_request").response_model;
const done_carry = @import("done_carry.zig");
const response_body_stream = @import("response_body_stream.zig");
const response_payload_writer = @import("response_payload_writer.zig");
const response_writer = @import("response_writer.zig");
const response_stream = @import("collo_worker_request").response_stream;
const runtime_owner = @import("../runtime/owner.zig");
const runtime_requests = @import("../runtime/requests.zig");
const state = @import("../runtime/root.zig");

pub const FinishOutcome = enum {
    already_finished,
    completed,
};

/// The step that ends a request's response, which its finish sends with the
/// request's `request_done` once the request's cleanup is done. The caller
/// keeps what a step borrows until `finishRequest` returns.
pub const LastStep = union(enum) {
    /// The response needs nothing more: its end went out, it never started,
    /// or the finish drops it. The `request_done` goes alone.
    none,
    /// The end of a streamed response.
    stream_end,
    /// The reset of a committed response that cannot go on, with its HTTP/2
    /// error code.
    stream_reset: u32,
    /// The step the request's outbox holds: the rest of a buffered body, a
    /// fetch's last chunk, a stream's end or its reset.
    outbox,
    /// The rest of a buffered response from `body_offset`, its head first
    /// unless `head_sent` (`response_writer.writeRest`).
    response: struct {
        response: *response_model.Response,
        head_sent: bool,
        body_offset: usize,
    },
    /// The last bytes of a fetch-streamed body, from `offset` on.
    stream_bytes: struct {
        bytes: []const u8,
        offset: usize,
    },
};

/// Finishes `request_ctx` with `done_status` and `http_status`, sends
/// `last` with its `request_done`, and destroys it. A second call for the
/// same request returns `.already_finished`. A last packet that found no
/// room parks, and the context stays until its advance sends it. On failure
/// the context stays in the active map, marked finished, and the server
/// finds the request's CPU in its live slot. The finish is the request's
/// own work, wherever it is called from, so it runs in the request's owner
/// window (`runtime/owner.zig`), and the CPU its `request_done` reports
/// holds every window up to the last packet's composition, the finish's
/// cleanup included.
pub fn finishRequest(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
    last: LastStep,
) !FinishOutcome {
    const request_id = request_ctx.exec.request_id;
    // An evaluation has no response to finish. Finishing it would send a
    // `request_done` with a zeroed dispatch identity and destroy the context
    // while its module's code may still use it. The level is warn because a
    // test exercises this refusal, and the test runner fails a run on any
    // err line.
    if (request_context.isReservedId(request_id)) {
        std.log.warn("refusing finishRequest for owner_id={d} (status={d})", .{ request_id, http_status });
        return error.InvalidArgument;
    }
    if (request_ctx.finish_started)
        return .already_finished;
    request_ctx.finish_started = true;

    const finished_mono_ns = runtime.nowMonoNs();
    // The timeline is sealed before the measures are read. Inside one of the
    // request's own turns this closes nothing, since execution is neither
    // I/O nor waiting; outside its turns it closes the current slice at the
    // finish stamp, and the window opened below moves a sealed timeline no
    // further.
    request_ctx.noteFinish(finished_mono_ns);
    // Opened before the cleanup, which can run the request's JavaScript, and
    // closed after the context is gone, which charges nobody the tail.
    const previous_owner_id = runtime_owner.enter(runtime, request_id, .{});
    defer runtime_owner.leave(runtime, previous_owner_id);
    errdefer preserveFailedFinish(runtime, request_id);

    // A body stream the response still reads is cancelled here, first, in
    // this window and before the cleanup disarms the deadline, so the
    // tenant's cancel algorithm runs within the request's budget and its CPU
    // enters the measures. `cancelFor` leaves out the ends that left no
    // budget.
    response_body_stream.release(runtime, request_ctx, response_body_stream.cancelFor(done_status));
    // The outbox stays: the last step may be the one it holds, and it goes
    // with the context once that step is sent.
    releaseRequestWork(runtime, request_ctx);
    try cleanupWebApiRequestOnce(runtime, request_ctx);
    if (done_status == .deadline_timeout)
        request_ctx.exec.termination_reason = @intFromEnum(bindings.TerminationReason.deadline);

    var carry: done_carry.DoneCarry = .{ .done_status = done_status, .http_status = http_status };
    switch (last) {
        .none => {
            // The fold charges the request its CPU up to here, which also
            // stores it in the request's live slot (`owner.chargeContext`),
            // so a worker that dies before the packet goes out still leaves
            // every window there.
            try sendRequestDone(runtime, .{
                .identity = response_payload_writer.h2Identity(request_ctx),
                .stream_id = request_ctx.ingress_channel_id,
                .done = carry.take(runtime, request_ctx, 0),
            });
        },
        else => {
            // `sendLast` moves the step past what went out, so a park keeps
            // only the rest.
            var step = last;
            const sent = sendLast(runtime, request_ctx, &step, &carry) catch |err|
                return stopForLastPacket(runtime, request_id, err);
            if (!sent) {
                // `sendLast` built the record before it found no room.
                const done = carry.done.?;
                parkLast(runtime, request_ctx, step) catch |err| {
                    // The step cannot wait, so the request ends without it,
                    // as an internal error, which the server answers or
                    // resets itself; its record goes alone.
                    std.log.warn("last packet could not wait request_id={d}; it ends as an internal error: {s}", .{ request_id, @errorName(err) });
                    var failed = done;
                    failed.status = .internal_error;
                    failed.http_status = 500;
                    try sendRequestDone(runtime, .{
                        .identity = response_payload_writer.h2Identity(request_ctx),
                        .stream_id = request_ctx.ingress_channel_id,
                        .done = failed,
                    });
                    removeFinishedRequest(runtime, request_id);
                    return .completed;
                };
                request_ctx.last_packet_done = done;
                return .completed;
            }
        },
    }
    removeFinishedRequest(runtime, request_id);
    return .completed;
}

/// Ends a finished request whose last packet waits for room, without that
/// packet, for an end that leaves the client nothing to receive, a reset of
/// its stream: the parked step goes, and the `request_done` the finish
/// computed goes alone with `done_status` and `http_status`, its measures
/// unchanged. Does nothing for a request whose last packet went out.
pub fn dropParkedLast(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
) !void {
    var done = request_ctx.last_packet_done orelse return;
    request_ctx.last_packet_done = null;
    done.status = done_status;
    done.http_status = http_status;
    const request_id = request_ctx.exec.request_id;
    try sendRequestDone(runtime, .{
        .identity = response_payload_writer.h2Identity(request_ctx),
        .stream_id = request_ctx.ingress_channel_id,
        .done = done,
    });
    removeFinishedRequest(runtime, request_id);
}

/// Sends the last packet of a finished request whose packet found no room
/// at its finish: the step its outbox holds, with the `request_done` the
/// finish computed, unchanged. The request's `response_advance` calls it
/// once the socket or the ring has room. A packet that finds no room again
/// waits again; one that goes out destroys the context.
pub fn sendParkedLast(runtime: *state.Runtime, request_ctx: *request_context.RequestContext) !void {
    const done = request_ctx.last_packet_done orelse return;
    var carry: done_carry.DoneCarry = .{
        .done_status = done.status,
        .http_status = done.http_status,
        .done = done,
    };
    var step: LastStep = .outbox;
    const sent = sendLast(runtime, request_ctx, &step, &carry) catch |err|
        return stopForLastPacket(runtime, request_ctx.exec.request_id, err);
    if (sent)
        removeFinishedRequest(runtime, request_ctx.exec.request_id);
}

/// A last packet that cannot go out, or whose step cannot wait, means the
/// channel cannot carry this worker's packets or the worker is out of
/// memory, so the worker stops and the server ends its requests from their
/// live slots.
fn stopForLastPacket(runtime: *state.Runtime, request_id: u64, err: anyerror) anyerror {
    std.log.warn("last packet failed request_id={d}; stopping worker: {s}", .{ request_id, @errorName(err) });
    runtime.core.running = false;
    return err;
}

/// Sends `step` with the request's `request_done` from `carry`, and moves
/// `step` past what went out; false when the socket or the ring had no room
/// for the packet that ends the response, which then sent nothing.
fn sendLast(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
    step: *LastStep,
    carry: *done_carry.DoneCarry,
) !bool {
    const ending: response_payload_writer.Ending = .{ .carry = carry };
    switch (step.*) {
        .none => unreachable, // `finishRequest` sends a `request_done` alone itself.
        .stream_end => return sentPacket(try response_payload_writer.writeStreamEnd(runtime, request_ctx, ending)),
        .stream_reset => |reset_code| return sentPacket(try response_payload_writer.writeStreamReset(runtime, request_ctx, reset_code, ending)),
        .response => |*rest| return sentBody(try response_writer.writeRest(runtime, request_ctx, rest.response, &rest.head_sent, &rest.body_offset, ending)),
        .stream_bytes => |*chunk| return sentBody(try response_payload_writer.writeStreamBytes(runtime, request_ctx, chunk.bytes, &chunk.offset, true, ending)),
        .outbox => switch (request_ctx.response_outbox.pending) {
            .buffered_body => |*buffered| return sentBody(try response_payload_writer.flushBufferedBody(runtime, request_ctx, buffered, ending)),
            .stream_chunk => |*chunk| return sentBody(try response_payload_writer.writeStreamBytes(runtime, request_ctx, chunk.bytes, &chunk.offset, chunk.done, ending)),
            .stream_end => return sentPacket(try response_payload_writer.writeStreamEnd(runtime, request_ctx, ending)),
            .stream_reset => |reset_code| return sentPacket(try response_payload_writer.writeStreamReset(runtime, request_ctx, reset_code, ending)),
            .none, .stream_head => return error.ResponseOutboxHoldsNoLastStep,
        },
    }
}

fn sentPacket(sent: response_payload_writer.Sent) !bool {
    return switch (sent) {
        .sent => true,
        .blocked => false,
        // A write with `carry` holds no packet.
        .last => error.LastPacketHeld,
    };
}

fn sentBody(progress: response_payload_writer.BodyProgress) !bool {
    return switch (progress) {
        .sent => true,
        .ring_full, .socket_full => false,
        // The finish runs once every step before the last went out within
        // the request's credit, so the last needs no more.
        .credit_empty => error.LastPacketWithoutCredit,
        .last => error.LastPacketHeld,
    };
}

/// Moves `last`, which found no room, into the request's outbox, where the
/// request's advance finds it (`sendParkedLast`).
fn parkLast(runtime: *state.Runtime, request_ctx: *request_context.RequestContext, last: LastStep) !void {
    switch (last) {
        .none => unreachable, // A `request_done` alone waits in the done outbox.
        .outbox => {},
        .stream_end => try request_ctx.response_outbox.park(.stream_end),
        .stream_reset => |reset_code| try request_ctx.response_outbox.park(.{ .stream_reset = reset_code }),
        .response => |rest| try response_writer.parkRest(runtime, request_ctx, rest.response, rest.head_sent, rest.body_offset),
        .stream_bytes => |chunk| {
            // The bytes are the caller's until the finish returns, so the
            // outbox keeps its own copy of what is left of them.
            const bytes = try runtime.core.allocator.dupe(u8, chunk.bytes[chunk.offset..]);
            errdefer runtime.core.allocator.free(bytes);
            try request_ctx.response_outbox.park(.{ .stream_chunk = .{ .bytes = bytes, .done = true } });
        },
    }
}

/// Sends the `request_done` packets that found the control socket full,
/// oldest first, until the socket is full again or none waits. The loop
/// calls it when the socket turns writable
/// (`scheduler/loop.zig:handleControlWritable`). Fails with
/// `error.ControlPeerClosed` once the server hung up, and with the send's
/// error for a channel that cannot carry the packet, which ends the loop.
pub fn flushPendingRequestDones(runtime: *state.Runtime) !void {
    while (runtime.requests.done_outbox.oldest()) |pending| {
        const sent = trySendRequestDone(runtime, pending) catch |err| switch (err) {
            error.PeerClosed => return error.ControlPeerClosed,
            else => |other| return other,
        };
        if (!sent)
            return;
        runtime.requests.done_outbox.pop();
    }
}

/// Sends `pending`, or queues it while earlier packets wait or the control
/// socket has no room. A send that fails, or an outbox that is full, stops
/// the worker and fails with that error.
fn sendRequestDone(runtime: *state.Runtime, pending: runtime_requests.PendingRequestDone) !void {
    if (runtime.requests.done_outbox.isEmpty()) {
        const sent = trySendRequestDone(runtime, &pending) catch |err| {
            std.log.warn("request_done send failed request_id={d}; stopping worker: {s}", .{
                pending.identity.request_id,
                @errorName(err),
            });
            runtime.core.running = false;
            return err;
        };
        if (sent)
            return;
    }
    runtime.requests.done_outbox.push(pending) catch |err| {
        std.log.err("worker owes more request_done packets than it has pool slots request_id={d}; stopping worker", .{
            pending.identity.request_id,
        });
        runtime.core.running = false;
        return err;
    };
}

/// Sends one `request_done`; false when the control socket has no room for
/// it. A runtime without a control socket, as in-process tests build, has
/// nobody to tell, and the packet counts as sent. Fails with
/// `error.PeerClosed` once the server hung up, or with the send's error.
fn trySendRequestDone(runtime: *state.Runtime, pending: *const runtime_requests.PendingRequestDone) !bool {
    const control_fd = runtime.core.control_fd orelse return true;
    ipc.ingress_channel.sendRequestDone(
        control_fd,
        pending.identity,
        pending.stream_id,
        pending.done,
        runtime.core.dispatch_recv_scratch,
    ) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => |other| return other,
    };
    return true;
}

fn preserveFailedFinish(runtime: *state.Runtime, request_id: u64) void {
    const request_ctx = runtime.requests.active.get(request_id) orelse return;
    request_ctx.finish_started = true;
    request_ctx.last_packet_done = null;
    cleanupRequestSubresources(runtime, request_ctx);
}

fn removeFinishedRequest(runtime: *state.Runtime, request_id: u64) void {
    const removed = runtime.requests.active.fetchRemove(request_id) orelse return;
    cleanupRequestSubresources(runtime, removed.value);
    runtime.destroyRequestContext(removed.value);
}

/// Releases everything `request_ctx` holds. Its live slot is not among them:
/// the slot names the request until the next begin on its pool slot.
fn cleanupRequestSubresources(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) void {
    releasePendingIngressResponse(runtime, request_ctx);
    releaseRequestWork(runtime, request_ctx);
}

/// Releases what `request_ctx` holds besides its response outbox: its
/// queued advance, body stream, fetches, pending body read, timers, Web API
/// state, completion, task and deadline. Rejecting a pending read can run
/// the tenant's reactions, in the caller's window.
fn releaseRequestWork(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) void {
    const request_id = request_ctx.exec.request_id;
    response_stream.discardAdvance(runtime, request_ctx);
    // `finishRequest` released the body stream already, with its cancel;
    // this covers every other path, and runs nothing of the tenant's.
    response_body_stream.release(runtime, request_ctx, null);
    runtime.cancelFetchesForRequest(request_id);
    // A completed streaming fetch body can outlive its fetch promise until
    // JavaScript consumes or drops the Response, so the request's end is
    // its last owner.
    runtime.cleanupFetchBodiesForRequest(request_id);
    body_read.rejectPendingRead(runtime, request_ctx) catch |err|
        std.log.warn("failed to reject pending request body read request_id={d}: {s}", .{
            request_id,
            @errorName(err),
        });
    runtime.cancelTimersForRequest(request_id);
    cleanupWebApiRequestOnce(runtime, request_ctx) catch |err|
        std.log.warn("failed to cleanup request WebAPI state request_id={d}: {s}", .{
            request_id,
            @errorName(err),
        });
    removePendingCompletion(runtime, request_id);
    destroyRequestTask(runtime, request_ctx);
    runtime.disarmRequestDeadline(request_ctx);
}

fn cleanupWebApiRequestOnce(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) !void {
    if (request_ctx.webapi_cleanup_done)
        return;
    try runtime.core.vm.cleanupWebApiRequest(request_ctx.exec.request_id);
    request_ctx.webapi_cleanup_done = true;
}

fn removePendingCompletion(runtime: *state.Runtime, request_id: u64) void {
    if (runtime.requests.pending_completions.fetchRemove(request_id)) |removed| {
        var completion = removed.value;
        completion.deinit();
    }
}

fn destroyRequestTask(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) void {
    const token = request_ctx.request_task orelse return;
    if (runtime.requests.tasks.get(token)) |task|
        task.state = .done;
    runtime.requests.tasks.destroy(token);
    request_ctx.request_task = null;
}

/// Drops the response's queued advance and frees the step `request_ctx`
/// still has waiting to be sent.
pub fn releasePendingIngressResponse(
    runtime: *state.Runtime,
    request_ctx: *request_context.RequestContext,
) void {
    response_stream.discardAdvance(runtime, request_ctx);
    switch (request_ctx.response_outbox.take()) {
        .none, .stream_end, .stream_reset => {},
        .buffered_body => |buffered| {
            var parked = buffered;
            if (parked.head) |*head|
                head.deinit(runtime.core.allocator);
            parked.body.deinitOwned(runtime.core.allocator);
        },
        .stream_head => |stream_head| {
            var head = stream_head;
            head.deinit(runtime.core.allocator);
        },
        .stream_chunk => |stream_chunk| {
            var chunk = stream_chunk;
            chunk.deinit(runtime.core.allocator);
        },
    }
}
