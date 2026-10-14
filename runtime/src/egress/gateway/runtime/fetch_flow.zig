//! How a fetch's record begins and ends, on the gateway's loop thread. Admission reserves the
//! record (`insert`); every way a fetch ends goes through `end`, which records the fetch's ending
//! and, while the shard's engine still holds the fetch, cancels it there, and `retire`, which
//! runs once the engine has let go: it writes the fetch's one terminal packet, lowers its
//! session's and cell's counts and its session's upload bytes, and frees the record with what it
//! held.
//!
//! The engine has let go of a running fetch when it settled the task without a response (a
//! failure, or a cancel before the head) or ended the response queue, which it does exactly when
//! it drops a fetch whose head it published (`egress/core/response_queue.zig`). The task's `done`
//! alone says nothing after the head: it turns true when the head is published, while the stream
//! goes on. So every ending the gateway decides itself, a stop, a refused head, a publication
//! that failed, cancels the fetch unless the engine already let go, and the record waits for the
//! engine's end, which wakes the shard (`shard_flow.zig`).
//!
//! A fetch therefore counts against its caps from admission until its terminal packet leaves,
//! the lifetime the worker counts it over too, so an honest worker that stays under its own cap
//! never meets the gateway's, and the session's cap bounds what its fetches hold in the engines,
//! canceled ones included. A session that goes cannot wait: its records retire at once, each
//! running one canceled first, so the engines drop their streams with the next pass of their
//! owner threads and no stream waits for a credit that died with the session's extent ledger. A
//! record never outlives its terminal packet: extents the worker still holds carry their own
//! shard, engine run and credit in the session's ledger (`sessions.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const body_credit = @import("collo_egress_client").body_credit;
const engine_mod = @import("../engine.zig");
const fetch_table = @import("../fetch_table.zig");
const sessions_mod = @import("../sessions.zig");
const Gateway = @import("root.zig").Gateway;
const session_flow = @import("session_flow.zig");
const upload_flow = @import("upload_flow.zig");

const Session = sessions_mod.Session;
const Handle = fetch_table.Handle;
const Task = @import("collo_egress_client").task.Task;

/// Reserves the record of an admitted fetch in its session and counts its pooled upload bytes.
/// Fails with `error.OutOfMemory`, leaving nothing behind.
pub fn insert(gateway: *Gateway, session: *Session, fetch: fetch_table.Fetch) !Handle {
    std.debug.assert(fetch.session_id == session.id);
    const handle = try gateway.fetches.insert(gateway.allocator, &session.fetches, session.security_cell_id, fetch);
    session.upload_bytes_in_flight += fetch.upload_bytes;
    return handle;
}

/// Ends the fetch `handle` names with `ending`, unless it is already ending; a handle whose fetch
/// is gone is a no-op. A running fetch the engine still holds is canceled there, and the record
/// waits for the engine to let go, which wakes its shard and retires it (`retireIfSettled`);
/// anything else retires now.
pub fn end(gateway: *Gateway, handle: Handle, ending: fetch_table.Ending) void {
    const fetch = gateway.fetches.get(handle) orelse return;
    if (fetch.ending != null)
        return;
    fetch.ending = ending;
    switch (fetch.stage) {
        .admitting, .assembling => {},
        .running => |running| {
            if (!cancelUnlessLetGo(gateway, fetch.shard_index, running))
                return;
        },
    }
    retire(gateway, handle);
}

/// Retires an ending fetch once the engine has let go of it; a no-op otherwise. A running record
/// that is ending had its fetch canceled by `end`, so a wake follows the engine's letting go.
pub fn retireIfSettled(gateway: *Gateway, handle: Handle) void {
    const fetch = gateway.fetches.get(handle) orelse return;
    if (fetch.ending == null)
        return;
    switch (fetch.stage) {
        .running => |running| if (!engineLetGo(running)) return,
        .admitting, .assembling => {},
    }
    retire(gateway, handle);
}

/// Ends every fetch of a session that is going, already out of the registry, without a packet:
/// each running fetch the engine still holds is canceled there, unless `end` already did, and
/// every record retires now, since nothing will deliver to the session again.
pub fn endSessionFetches(gateway: *Gateway, session: *Session) void {
    while (session.fetches.first != fetch_table.null_index) {
        const index = session.fetches.first;
        const fetch = gateway.fetches.at(index);
        switch (fetch.stage) {
            .running => |running| {
                // A running record that is already ending went through `end`, which canceled
                // whatever the engine still held.
                if (fetch.ending == null)
                    _ = cancelUnlessLetGo(gateway, fetch.shard_index, running);
            },
            .admitting, .assembling => {},
        }
        fetch.ending = .silent;
        retireFrom(gateway, session, gateway.fetches.handleAt(index));
    }
}

/// Ends every fetch the session admitted under its boot token, running or assembling its upload,
/// with an error, once the server ended that token (`control_flow.zig`): a worker compromised
/// after its startup keeps nothing its boot token started. Each such fetch gets its terminal
/// packet as any ending does, so the worker's count of it ends too.
pub fn endBootFetches(gateway: *Gateway, session: *Session) void {
    var cursor = session.fetches.first;
    while (cursor != fetch_table.null_index) {
        const fetch = gateway.fetches.at(cursor);
        // Ending a record can take it out of the list, never another one.
        const next = fetch.next;
        if (fetch.boot and fetch.ending == null)
            end(gateway, gateway.fetches.handleAt(cursor), .{ .failed = .{ .message = boot_ended_message } });
        cursor = next;
    }
}

/// The error a fetch of an ended boot token fails with, the text admission refuses a later start
/// under that token with (`command_flow.Refusal.boot_ended`).
pub const boot_ended_message = "egress boot token ended";

/// Ends every running fetch of shard `shard_index`, whose engine has stopped and settled every
/// task it held, with `failure`; a fetch already ending keeps its ending. Pooled uploads still
/// assembling are left alone: they reach the restarted engine once their bodies arrive.
pub fn endShardFetches(gateway: *Gateway, shard_index: usize, failure: fetch_table.Failure) void {
    var index: usize = 0;
    while (index < gateway.fetches.slotCount()) : (index += 1) {
        const fetch = gateway.fetches.liveAt(index) orelse continue;
        if (fetch.shard_index != shard_index or fetch.stage != .running)
            continue;
        if (fetch.ending == null)
            fetch.ending = .{ .failed = failure };
        retire(gateway, gateway.fetches.handleAt(@intCast(index)));
    }
}

/// Whether the shard's engine holds nothing of the running fetch any more: it settled the task
/// without a response, or it ended the response queue. Both facts only ever turn true, so a
/// false answer that goes stale is followed by the engine's wake.
fn engineLetGo(running: engine_mod.Running) bool {
    if (running.queue.producerEnded())
        return true;
    return settledWithoutResponse(running.task);
}

/// Cancels a running fetch the gateway is ending, unless the engine already let go of it, and
/// returns whether it had. Canceling makes the queue refuse the engine's further appends, which
/// resets the stream at its next chunk, arms the queue, so the engine's end of it wakes the
/// shard, and asks the engine to cancel the fetch wherever it holds it. The queue's answer and
/// its arm come under one lock, so an end that races the cancel is either reported here or wakes
/// the loop.
fn cancelUnlessLetGo(gateway: *Gateway, shard_index: usize, running: engine_mod.Running) bool {
    if (running.queue.cancel())
        return true;
    if (settledWithoutResponse(running.task))
        return true;
    gateway.shards.get(shard_index).engine.cancel(running.task);
    return false;
}

/// Whether the engine settled the task without a response head: a failure, or a cancel that
/// found the fetch before its head. Such a task never had a stream, so the engine let go of it
/// when it settled it.
fn settledWithoutResponse(task: *Task) bool {
    task.mutex.lock();
    defer task.mutex.unlock();
    if (!task.done)
        return false;
    const result = task.result orelse return true;
    return switch (result) {
        .success => false,
        .failure => true,
    };
}

fn retire(gateway: *Gateway, handle: Handle) void {
    const fetch = gateway.fetches.get(handle).?;
    // Every record belongs to a registered session: a session that goes ends its records first
    // (`endSessionFetches`).
    const session = gateway.sessions.byId(fetch.session_id).?;
    retireFrom(gateway, session, handle);
}

/// Writes the fetch's terminal packet, takes the record out of the table and its session, lowers
/// the counts and frees what the record held.
fn retireFrom(gateway: *Gateway, session: *Session, handle: Handle) void {
    const fetch = gateway.fetches.get(handle).?;
    const ending = fetch.ending.?;
    sendTerminalPacket(gateway, session, fetch, ending);
    const removed = gateway.fetches.remove(&session.fetches, session.security_cell_id, handle);
    std.debug.assert(session.upload_bytes_in_flight >= removed.upload_bytes);
    session.upload_bytes_in_flight -= removed.upload_bytes;
    switch (removed.stage) {
        .admitting => {},
        .assembling => |upload| upload_flow.forget(gateway, upload),
        .running => |running| {
            const engine = &gateway.shards.get(removed.shard_index).engine;
            // The queue refuses appends from now on, so the credits returned here are the last
            // its chunks carry, and the engine's final release finds it empty. Whether the
            // engine had ended it no longer matters: the record goes either way.
            _ = running.queue.cancel();
            const credit_return = CreditReturn{ .engine = engine, .run = running.run };
            running.queue.releaseQueued(engine.allocator, credit_return, CreditReturn.release);
            running.queue.release(engine.allocator);
            // Engine threads may still hold the task; the last reference frees it.
            running.task.release();
        },
    }
}

/// Where a retiring record's queued credits go: the engine of its shard, as credits of the run
/// its task belongs to.
const CreditReturn = struct {
    engine: *engine_mod.Engine,
    run: engine_mod.Run,

    fn release(self: CreditReturn, credit: body_credit.Handle) void {
        self.engine.releaseCredit(self.run, credit);
    }
};

comptime {
    // A denial is the longest text a fetch fails with, and its error packet carries it whole, so
    // only a defect falls back to the generic text below.
    std.debug.assert(@import("collo_egress_client").network.grant.denial_bytes_max <=
        ipc.fetch_limits.response_error_message_bytes_max);
}

/// Writes the packet that tells the worker the fetch is over. A ring that cannot take it marks
/// the session for drop (`session_flow.queuePacket`), and the session's removal tells the worker
/// instead.
fn sendTerminalPacket(
    gateway: *Gateway,
    session: *Session,
    fetch: *const fetch_table.Fetch,
    ending: fetch_table.Ending,
) void {
    const ready_at_mono_ns = os_process.monotonicNowNsOrZero();
    switch (ending) {
        .silent => {},
        .body_end => {
            var message = ipc.EgressBodyEnd.init(fetch.fetch_id, fetch.body_id);
            message.ready_at_mono_ns = ready_at_mono_ns;
            session_flow.queuePacket(gateway, session, std.mem.asBytes(&message)) catch return;
        },
        .stopped => {
            const message = ipc.EgressAbortAck.init(fetch.fetch_id, fetch.body_id);
            session_flow.queuePacket(gateway, session, std.mem.asBytes(&message)) catch return;
        },
        .failed => |failure| {
            var view = ipc.EgressFetchErrorView{
                .fetch_id = fetch.fetch_id,
                .body_id = fetch.body_id,
                .message = failure.message,
                .cause = failure.cause,
                .ready_at_mono_ns = ready_at_mono_ns,
            };
            const bytes = ipc.encodeEgressFetchErrorInto(gateway.encode_scratch, view) catch |err| retry: {
                // The error packet bounds its message, which a task's failure text can exceed;
                // the worker still learns the fetch failed.
                std.log.warn("egress gateway fetch error not encoded fetch_id={d}: {s}", .{ fetch.fetch_id, @errorName(err) });
                view.message = "egress internal error";
                break :retry ipc.encodeEgressFetchErrorInto(gateway.encode_scratch, view) catch unreachable;
            };
            session_flow.queuePacket(gateway, session, bytes) catch return;
        },
    }
}
