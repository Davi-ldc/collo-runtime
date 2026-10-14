//! What the gateway does with its worker sessions, on its loop thread: attaching and removing
//! them, the packets it writes to their completion rings, and the attention list of sessions it
//! looks at again before its next wait.
//!
//! A session goes at once when its worker closes its end of the liveness pipe, when its command
//! ring fails its checks or carries a command that does not decode, and when an upload extent it
//! names is one the pool rejects (`command_flow.zig`, `upload_flow.zig`). It is marked for drop,
//! and goes at the end of the pass, when a packet the gateway writes finds its completion ring
//! full or broken, when its body-pool release drain fails or returns an extent the ledger cannot
//! match (`release_flow.zig`), when its rings cannot be measured, and when its completion ring has
//! stayed at `hard_percent` for `hard_drop_grace_ns`: a worker that stops reading completions
//! breaks the protocol. A response head instead waits while the ring lacks `head_reserve_bytes`
//! below the hard mark behind it (`queueHead`), so an honest worker, which reads its ring however
//! late, never finds it at the mark or full. Nothing else removes a session; a well-formed command
//! the gateway refuses fails only its fetch. Every removal the server did not ask for is reported
//! to it with its cause (`control.SessionRemoved`): the worker's closed end of the liveness pipe,
//! or a protocol violation, for which the server retires the worker.
//!
//! The attention list holds the sessions the pass wrote to, whose body pool gained room, whose
//! completion ring is at `hard_percent`, or whose body drain waits for ring room.
//! `processAttention` measures each one's completion ring and pumps the fetches of each one whose
//! pool gained room or whose ring has room again, so the per-pass work follows what happened in
//! the pass and what waits, never the number of sessions.

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

const engine_mod = @import("../engine.zig");
const fetch_table = @import("../fetch_table.zig");
const policy_mod = @import("../policy.zig");
const publisher = @import("../publisher.zig");
const readiness_mod = @import("../readiness.zig");
const sessions_mod = @import("../sessions.zig");
const body_pump = @import("body_pump.zig");
const command_flow = @import("command_flow.zig");
const control_flow = @import("control_flow.zig");
const fetch_flow = @import("fetch_flow.zig");
const Gateway = @import("root.zig").Gateway;
const shard_flow = @import("shard_flow.zig");

const Session = sessions_mod.Session;

/// The completion-ring fill, in percent, from which a session counts as not reading.
pub const hard_percent: u8 = 95;
/// How long a session's completion ring may stay at `hard_percent` before the gateway drops the
/// session.
pub const hard_drop_grace_ns: u64 = std.time.ns_per_s;

/// Completion-ring bytes a response head leaves free below the hard mark behind it: room for the
/// terminal packet of every fetch an honest worker counts and for every body batch its pool can
/// back. An honest worker counts a fetch until it reads the fetch's terminal packet and refuses one
/// past `fetches_per_worker_max` (`worker/egress/state.zig`), and every unread batch descriptor
/// holds a pool extent, so heads written only with this room left keep the ring below the hard
/// mark, and every packet the gateway owes the worker fits, however long it reads nothing.
pub const head_reserve_bytes: usize =
    limits.worker.fetches_per_worker_max * publisher.ringRecordBytes(publisher.terminal_packet_bytes_max) +
    publisher.unread_batch_bytes_max;

comptime {
    // An empty ring takes the largest head with its reserve below the hard mark, so a head never
    // waits on a worker that has read everything.
    std.debug.assert(belowHardMark(
        publisher.ringRecordBytes(publisher.head_packet_bytes_max) + head_reserve_bytes,
        ipc.egress_shared.completion_ring_capacity,
    ));
}

pub const RemovalReason = enum {
    liveness_closed,
    command_ring_failed,
    attach_ack_failed,
    dropped,
};

/// Attaches a session that takes over `endpoint`, leaving it undefined, and polls its command
/// eventfd and liveness descriptor. On error the caller still owns `endpoint` and nothing is
/// attached.
pub fn attachSession(
    gateway: *Gateway,
    endpoint: *ipc.egress_shared.Endpoint,
    security_cell_id: policy_mod.SecurityCellId,
) !sessions_mod.Attached {
    try gateway.attention.ensureTotalCapacity(gateway.allocator, gateway.sessions.len() + 1);
    try gateway.attention_pass.ensureTotalCapacity(gateway.allocator, gateway.sessions.len() + 1);
    try gateway.readiness.reserveSession();
    const command_fd = endpoint.command_eventfd;
    const liveness_fd = endpoint.peer_liveness_fd;
    const attached = try gateway.sessions.attach(gateway.allocator, endpoint, security_cell_id);
    gateway.readiness.addSession(attached.session_id, command_fd, liveness_fd) catch |err| {
        var removed = gateway.sessions.removeAt(attached.index);
        endpoint.* = removed.endpoint;
        removed.endpoint = undefined;
        removed.extents.deinit(gateway.allocator);
        return err;
    };
    return attached;
}

/// Removes the session in slot `index`: ends its fetches without a packet, stops polling it and
/// frees it. Closing the session's end of the liveness pipe the worker watches detaches the
/// worker. The server learns of the removal from the report sent here, except for a session
/// whose attach ack never left, which the server never knew. Fails, which ends the gateway, when
/// the readiness ring fails or the report can be neither sent nor queued.
pub fn removeSession(gateway: *Gateway, index: usize, reason: RemovalReason) !void {
    const session_id = gateway.sessions.byIndex(index).id;
    std.log.warn("egress gateway removing session={d} reason={s}", .{ session_id, @tagName(reason) });
    try gateway.readiness.removeSession(session_id);
    discardSession(gateway, index);
    switch (reason) {
        .attach_ack_failed => {},
        .liveness_closed => try control_flow.reportSessionRemoved(gateway, session_id, .liveness_closed),
        .command_ring_failed, .dropped => try control_flow.reportSessionRemoved(gateway, session_id, .protocol_violation),
    }
}

/// Takes the session in slot `index` out of the registry, ends its fetches without a packet and
/// frees it, leaving its polls and the server's view to the caller.
pub fn discardSession(gateway: *Gateway, index: usize) void {
    var removed = gateway.sessions.removeAt(index);
    fetch_flow.endSessionFetches(gateway, &removed);
    // The attention list holds only registered sessions, so the room each attach reserves in it
    // covers every entry.
    if (removed.attention_queued) {
        for (gateway.attention.items, 0..) |session_id, position| {
            if (session_id == removed.id) {
                _ = gateway.attention.swapRemove(position);
                break;
            }
        }
    }
    removed.deinit(gateway.allocator);
}

/// Handles one readiness completion of a session's command eventfd or liveness descriptor.
pub fn handleSessionReady(gateway: *Gateway, ready: anytype) !void {
    const index = gateway.sessions.indexOf(ready.session_id) orelse return;
    switch (@as(readiness_mod.SessionSource, ready.source)) {
        .liveness => {
            if ((ready.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
                try removeSession(gateway, index, .liveness_closed);
        },
        .command => {
            if ((ready.revents & std.posix.POLL.IN) != 0) {
                if (!command_flow.handleCommands(gateway, gateway.sessions.byIndex(index)))
                    try removeSession(gateway, index, .command_ring_failed);
            }
        },
    }
}

/// Marks `session` for removal at the end of the pass, logging why.
pub fn markForDrop(gateway: *Gateway, session: *Session, reason: []const u8) void {
    if (!session.drop_pending)
        std.log.warn("egress gateway dropping session={d}: {s}", .{ session.id, reason });
    gateway.sessions.markForDrop(session);
}

/// Removes every session marked for drop. Fails as `removeSession` does.
pub fn removeDroppedSessions(gateway: *Gateway) !void {
    while (gateway.sessions.nextDrop()) |index|
        try removeSession(gateway, index, .dropped);
}

/// Writes `bytes` onto the session's completion ring. A ring that is full or broken marks the
/// session for drop and fails with `error.EgressGatewaySessionUnwritable`, so the caller ends what
/// it was publishing without a packet.
pub fn queuePacket(gateway: *Gateway, session: *Session, bytes: []const u8) !void {
    const result = publisher.queuePacket(&session.endpoint, bytes) catch |err| {
        markForDrop(gateway, session, @errorName(err));
        return error.EgressGatewaySessionUnwritable;
    };
    noteCompletionWrite(gateway, session, result);
}

pub const HeadWrite = enum {
    written,
    /// The ring lacked room; the session is watched until it has some (`awaitRingRoom`).
    waits,
    /// The ring could not be measured or written, and the session is marked for drop.
    unwritable,
};

/// Writes the response head `bytes` when the session's completion ring keeps `head_reserve_bytes`
/// free below the hard mark after it. A ring short of that room leaves the head waiting, and the
/// attention pass that finds room pumps the fetch again (`lookAgain`). A ring that cannot be
/// measured or written marks the session for drop.
pub fn queueHead(gateway: *Gateway, session: *Session, bytes: []const u8) HeadWrite {
    const usage = session.endpoint.completion.usage() catch |err| {
        markForDrop(gateway, session, @errorName(err));
        return .unwritable;
    };
    if (!belowHardMark(usage.used + publisher.ringRecordBytes(bytes.len) + head_reserve_bytes, usage.capacity)) {
        awaitRingRoom(gateway, session);
        return .waits;
    }
    queuePacket(gateway, session, bytes) catch return .unwritable;
    return .written;
}

/// Whether a ring holding `used` of `capacity` bytes stays below `hard_percent`.
fn belowHardMark(used: usize, capacity: usize) bool {
    return used * 100 < capacity * @as(usize, hard_percent);
}

/// Publishes one body batch of `fetch`, whose credits run `run` of its shard's engine issued,
/// records each extent it wrote in the session's ledger with the credit it carries and that run,
/// and returns how many it wrote. A full pool or ring fails with `error.EgressSharedRingFull`,
/// which only a bookkeeping bug reaches, since the body drain reserves the batch's worst case
/// first; any other publication failure marks the session for drop and fails with
/// `error.EgressGatewaySessionUnwritable`.
pub fn publishBody(
    gateway: *Gateway,
    session: *Session,
    fetch: *const fetch_table.Fetch,
    run: engine_mod.Run,
    chunks: []const publisher.BodyChunkPayload,
) !usize {
    try session.extents.reserve(gateway.allocator);
    var extents: [ipc.egress_shared.body_pool_slot_count]publisher.PublishedExtent = undefined;
    const result = publisher.publishBodyChunkBatch(
        &session.endpoint,
        fetch.fetch_id,
        fetch.body_id,
        chunks,
        gateway.encode_scratch,
        &extents,
    ) catch |err| switch (err) {
        error.EgressSharedRingFull => return err,
        else => {
            markForDrop(gateway, session, @errorName(err));
            return error.EgressGatewaySessionUnwritable;
        },
    };
    for (extents[0..result.extents]) |extent|
        session.extents.record(extent.handle, extent.len, fetch.shard_index, run, extent.credit);
    noteCompletionWrite(gateway, session, result.write);
    return result.extents;
}

/// Queues the session for a measurement of its completion ring, and writes its completion
/// eventfd when the ring write asked for it: at once outside a shard's collection pass, and at
/// the end of the pass otherwise, since a pass publishes many packets but owes each worker one
/// wake.
fn noteCompletionWrite(gateway: *Gateway, session: *Session, result: ipc.egress_shared.PacketWriteResult) void {
    queueAttention(gateway, session);
    if (!result.eventfd_notify_required)
        return;
    if (gateway.coalesce_completion_notifies) {
        session.completion_notify_pending = true;
        return;
    }
    ipc.egress_shared.notify(session.endpoint.completion_eventfd);
}

/// Writes the completion eventfd of every session a collection pass owes one. Each such session
/// is in the attention list, which `noteCompletionWrite` puts it in before it defers the wake.
pub fn flushCompletionNotifies(gateway: *Gateway) void {
    for (gateway.attention.items) |session_id| {
        const session = gateway.sessions.byId(session_id) orelse continue;
        if (!session.completion_notify_pending)
            continue;
        session.completion_notify_pending = false;
        ipc.egress_shared.notify(session.endpoint.completion_eventfd);
    }
}

/// Puts `session` in the attention list unless it is there. Never fails: attach reserved room
/// for every session.
pub fn queueAttention(gateway: *Gateway, session: *Session) void {
    if (session.attention_queued)
        return;
    session.attention_queued = true;
    gateway.attention.appendAssumeCapacity(session.id);
}

/// Notes that the session's body pool gained room, so its fetches waiting for room are pumped
/// before the next wait.
pub fn noteRoomGained(gateway: *Gateway, session: *Session) void {
    session.rescan_pending = true;
    queueAttention(gateway, session);
}

/// Notes that a body drain of the session stopped because its completion ring lacked room. The
/// worker reads its ring without telling the gateway, so the session stays in the attention list,
/// measured on every pass, until its ring holds what a drain needs, and its fetches are then
/// pumped (`lookAgain`).
pub fn awaitRingRoom(gateway: *Gateway, session: *Session) void {
    session.ring_room_pending = true;
    queueAttention(gateway, session);
}

/// Looks at every session in the attention list: measures its completion ring, marks it for drop
/// after `hard_drop_grace_ns` at `hard_percent`, and pumps the fetches of a session whose pool
/// gained room or whose ring has room again for a drain that waited on it. A session at
/// `hard_percent`, or whose drain still waits for ring room, stays in the list, so the next pass,
/// at most `readiness.wait_tick_ns` away, looks again. Fails, which ends the gateway, when a
/// pump's shard failure cannot be contained (`shard_flow.superviseShardFailure`).
pub fn processAttention(gateway: *Gateway, now_ns: u64) !void {
    // The pass works on its own copy, and every session in it leaves the list first, so a write
    // during the pass, to any session, queues it again for the next pass, and the list never holds
    // a session twice.
    gateway.attention_pass.clearRetainingCapacity();
    gateway.attention_pass.appendSliceAssumeCapacity(gateway.attention.items);
    gateway.attention.clearRetainingCapacity();
    for (gateway.attention_pass.items) |session_id| {
        const session = gateway.sessions.byId(session_id) orelse continue;
        session.attention_queued = false;
    }
    for (gateway.attention_pass.items) |session_id| {
        const session = gateway.sessions.byId(session_id) orelse continue;
        if (try lookAgain(gateway, session, now_ns))
            queueAttention(gateway, session);
    }
}

/// Measures one session and pumps its fetches when its pool gained room. Returns whether the
/// session stays in the attention list.
fn lookAgain(gateway: *Gateway, session: *Session, now_ns: u64) !bool {
    // A session marked for drop goes at the end of the pass.
    if (session.drop_pending)
        return false;
    var stays = false;
    const usage = session.endpoint.completion.usage() catch |err| {
        markForDrop(gateway, session, @errorName(err));
        return false;
    };
    if (usage.atLeastPercent(hard_percent)) {
        if (session.hard_since_ns == 0) {
            // A failed clock read (0) still starts the grace.
            session.hard_since_ns = @max(now_ns, 1);
            stays = true;
        } else if (now_ns -| session.hard_since_ns >= hard_drop_grace_ns) {
            markForDrop(gateway, session, "completion ring left unread");
            return false;
        } else {
            stays = true;
        }
    } else {
        session.hard_since_ns = 0;
    }
    if (session.ring_room_pending) {
        if (usage.capacity - usage.used >= body_pump.drainRingReserveBytes(gateway)) {
            session.ring_room_pending = false;
            session.rescan_pending = true;
        } else {
            stays = true;
        }
    }
    if (session.rescan_pending) {
        session.rescan_pending = false;
        try pumpSessionFetches(gateway, session);
    }
    return stays;
}

/// Pumps every fetch of the session whose head went out or waits for ring room, so a head or a
/// body drain that stopped for lack of room takes what fits now. A pump whose error restarts a
/// shard ends the walk and leaves the rest for the next pass, since the restart ended records the
/// walk would visit.
fn pumpSessionFetches(gateway: *Gateway, session: *Session) !void {
    var cursor = session.fetches.first;
    while (cursor != fetch_table.null_index) {
        const fetch = gateway.fetches.at(cursor);
        const next = fetch.next;
        const pumped = fetch.head_sent or fetch.head_waits_room;
        if (fetch.stage == .running and fetch.ending == null and pumped) {
            if (try shard_flow.pumpOrSupervise(gateway, gateway.fetches.handleAt(cursor))) {
                noteRoomGained(gateway, session);
                return;
            }
        }
        cursor = next;
    }
}

/// After a drain of the session's commands, a higher drop count on its command ring means the
/// worker found the ring full and parked a command. The ring has room again, so the gateway
/// writes the completion eventfd the worker waits on; without it, a lone parked fetch start would
/// wait for an unrelated completion.
pub fn wakeWorkerAfterCommandDrops(session: *Session) void {
    const drops = @atomicLoad(u64, &session.endpoint.command.producer.dropped_packets, .acquire);
    if (drops == session.last_seen_command_drops)
        return;
    session.last_seen_command_drops = drops;
    ipc.egress_shared.notify(session.endpoint.completion_eventfd);
}
