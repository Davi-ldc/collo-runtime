//! A worker session's commands, on the gateway's loop thread: draining its command ring,
//! admitting fetch starts, stopping fetches and handing upload batches on.
//!
//! Every command is untrusted input to the process that holds the network capability, and the
//! gateway trusts nothing in a fetch start before `egress_token.verify` accepts its token under
//! the hello's key (`control_flow.zig`). The request, the deadline and the network policy of a
//! fetch come from the verified token alone, never from the packet around it. Admission checks,
//! in this order, the tag, the token's session against the session whose ring carried it, the
//! clock and the deadline, the end of the session's boot token, the policy id in the hello's
//! table, the active-fetch caps of the session and of its security cell, an unused fetch id in
//! the session, the start's shape (`policy.checkStart`, the same for an inline and a pooled body,
//! before any buffer exists) and, for a pooled body, the session's upload bytes in flight, which
//! count the body and the copies of its start (`ipc.fetch_limits.pooledStartHeldBytes`). Only
//! then does it reserve the fetch's record (`fetch_flow.zig`), its first step that changes state,
//! and hand the fetch to its shard's engine or to the upload assembler; a handover that fails
//! ends the record, which is the one undo.
//!
//! A refused start fails only its fetch, with an error packet naming the refusal, and leaves the
//! session as it was: a refused command costs the gateway what an accepted one costs, the drain
//! bound below limits one session's share of a pass, and a 128-bit tag cannot be guessed at any
//! rate. A stop names a fetch by id; one the session no longer has is ignored, since a worker
//! cannot see when the gateway ended its fetch, and the terminal packet already on its way
//! settles the worker's count. A command ring that fails its checks, or a command that does not
//! decode, removes the session (`session_flow.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const engine_mod = @import("../engine.zig");
const policy_mod = @import("../policy.zig");
const sessions_mod = @import("../sessions.zig");
const fetch_flow = @import("fetch_flow.zig");
const Gateway = @import("root.zig").Gateway;
const release_flow = @import("release_flow.zig");
const session_flow = @import("session_flow.zig");
const upload_flow = @import("upload_flow.zig");

const egress_token = ipc.egress_token;
const Session = sessions_mod.Session;

/// Commands one session's drain handles per pass; a full batch writes the command eventfd so the
/// next pass comes back for the rest.
pub const command_drain_batch: usize = 64;

/// Every way admission refuses a fetch start, each with the message the worker's fetch fails
/// with.
pub const Refusal = enum {
    invalid_token,
    other_session,
    clock_unavailable,
    expired,
    boot_ended,
    unknown_policy,
    worker_fetch_limit,
    security_cell_fetch_limit,
    duplicate_identity,
    upload_bytes_in_flight,

    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .invalid_token => "invalid egress token",
            .other_session => "egress token of another session",
            .clock_unavailable => "egress clock unavailable",
            .expired => "egress token expired",
            .boot_ended => fetch_flow.boot_ended_message,
            .unknown_policy => "egress policy unknown",
            .worker_fetch_limit => "egress worker fetch limit exceeded",
            .security_cell_fetch_limit => "egress security cell fetch limit exceeded",
            .duplicate_identity => "duplicate egress fetch identity",
            .upload_bytes_in_flight => "egress upload bytes in flight exceeded",
        };
    }
};

/// Drains the session's body-pool releases, then up to `command_drain_batch` of its commands.
/// Returns false when the session must be removed.
pub fn handleCommands(gateway: *Gateway, session: *Session) bool {
    ipc.egress_shared.drainEventfd(session.endpoint.command_eventfd);
    release_flow.drainReleases(gateway, session);
    defer session_flow.wakeWorkerAfterCommandDrops(session);
    var drained: usize = 0;
    while (drained < command_drain_batch) : (drained += 1) {
        const packet = session.endpoint.command.readPacket(gateway.read_scratch) catch |err| {
            std.log.warn("egress gateway command ring read failed session={d}: {s}", .{ session.id, @errorName(err) });
            return false;
        } orelse return true;
        if (!handlePacket(gateway, session, packet))
            return false;
    }
    ipc.egress_shared.notify(session.endpoint.command_eventfd);
    return true;
}

/// Handles one command copied out of the session's ring. Returns false, which removes the
/// session, for a packet shorter than a kind, of a kind the command ring does not carry, or that
/// does not decode.
pub fn handlePacket(gateway: *Gateway, session: *Session, bytes: []const u8) bool {
    if (bytes.len < @sizeOf(u32))
        return false;
    const kind = ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)])) catch return false;
    switch (kind) {
        .egress_fetch_start => {
            const fetch = ipc.decodeEgressFetchStart(gateway.decode_scratch, bytes) catch |err| {
                std.log.warn("invalid egress fetch start session={d}: {s}", .{ session.id, @errorName(err) });
                return false;
            };
            admitFetchStart(gateway, session, fetch);
            return true;
        },
        .egress_stop => {
            const fetch_id = ipc.decodeEgressStop(bytes) catch return false;
            const handle = gateway.fetches.find(session.id, fetch_id) orelse return true;
            fetch_flow.end(gateway, handle, .stopped);
            return true;
        },
        .egress_upload_chunk_batch => return upload_flow.handleBatch(gateway, session, bytes),
        else => return false,
    }
}

/// Admits a decoded fetch start in the order the file header gives, or refuses it with an error
/// packet to the worker. `fetch` points into `gateway.read_scratch`; nothing reads it after the
/// handover copied what it needs.
fn admitFetchStart(gateway: *Gateway, session: *Session, fetch: ipc.EgressFetchStartView) void {
    const token = egress_token.fromBytes(&fetch.egress_token);
    const fields = egress_token.verify(&gateway.hello.key, &token) catch
        return refuse(gateway, session, fetch, .invalid_token);
    if (fields.session_id != session.id)
        return refuse(gateway, session, fetch, .other_session);
    // A clock that cannot be read could not tell an expired token from a live one.
    const now_ns = os_process.monotonicNowNs() catch
        return refuse(gateway, session, fetch, .clock_unavailable);
    if (egress_token.deadlinePassed(fields.deadline_monotonic_ns, now_ns))
        return refuse(gateway, session, fetch, .expired);
    if (fields.kind == .boot and session.boot_ended)
        return refuse(gateway, session, fetch, .boot_ended);
    const network_policy = gateway.hello.lookup(fields.policy_id) orelse {
        std.log.err("egress token names policy id={d} outside the hello's {d} policies", .{
            fields.policy_id,
            gateway.hello.policyCount(),
        });
        return refuse(gateway, session, fetch, .unknown_policy);
    };
    if (session.fetches.len >= gateway.policy.max_active_fetches_per_worker_session)
        return refuse(gateway, session, fetch, .worker_fetch_limit);
    if (gateway.fetches.cellCount(session.security_cell_id) >= gateway.policy.max_active_fetches_per_security_cell)
        return refuse(gateway, session, fetch, .security_cell_fetch_limit);
    if (gateway.fetches.contains(session.id, fetch.fetch_id))
        return refuse(gateway, session, fetch, .duplicate_identity);
    const max_response_body_bytes = policy_mod.checkStart(fetch, gateway.policy) catch |err|
        return fail(gateway, session, fetch, @errorName(err));
    const pooled = (fetch.flags & ipc.egress_fetch_start_flag_body_pooled) != 0;
    // A pooled start holds its body and the copies of its start until its terminal packet, and
    // the worker counts the same sum before it sends the start.
    const upload_bytes: u64 = if (pooled)
        fetch.pooled_body_len + ipc.fetch_limits.pooledStartHeldBytes(fetch.method.len, fetch.url.len, fetch.headers)
    else
        0;
    const upload_room = ipc.fetch_limits.request_body_pooled_in_flight_bytes_max -| session.upload_bytes_in_flight;
    if (upload_bytes > upload_room)
        return refuse(gateway, session, fetch, .upload_bytes_in_flight);

    // A policy that grants nothing, policy 0 included, is admitted like any other and refused by
    // the transport on the fetch's first hop, so one place decides what a fetch may reach.
    const isolation = policy_mod.PoolIsolation{
        .security_cell_id = session.security_cell_id,
        .policy_id = policy_mod.poolPolicyId(fields.policy_id),
    };
    const grant = engine_mod.Grant{
        .isolation = isolation,
        .network = network_policy,
        .request_id = fields.request_id,
        .request_generation = fields.request_generation,
        .deadline_mono_ns = fields.deadline_monotonic_ns,
        .max_response_body_bytes = max_response_body_bytes,
    };
    const shard_index = gateway.shards.selectIndex(isolation, fetch.url);
    const handle = fetch_flow.insert(gateway, session, .{
        .session_id = session.id,
        .fetch_id = fetch.fetch_id,
        .body_id = fetch.body_id,
        .shard_index = shard_index,
        .upload_bytes = upload_bytes,
        .boot = fields.kind == .boot,
        .stage = .admitting,
    }) catch |err| return fail(gateway, session, fetch, @errorName(err));

    // A pooled fetch waits in the upload assembler until its announced length has arrived as
    // upload-pool extents; any other goes to its engine now.
    if (pooled) {
        upload_flow.register(gateway, handle, fetch, grant) catch |err|
            return fetch_flow.end(gateway, handle, .{ .failed = .{ .message = @errorName(err) } });
        return;
    }
    const running = gateway.shards.get(shard_index).engine.submit(handle, fetch, grant, null) catch |err|
        return fetch_flow.end(gateway, handle, .{ .failed = .{ .message = @errorName(err) } });
    gateway.fetches.get(handle).?.stage = .{ .running = running };
}

fn refuse(gateway: *Gateway, session: *Session, fetch: ipc.EgressFetchStartView, refusal: Refusal) void {
    fail(gateway, session, fetch, refusal.message());
}

/// Fails a fetch that never got a record with an error packet carrying `text`. The worker counts
/// the fetch until that packet, so a refusal that cannot be encoded or written marks the session
/// for drop, and its removal ends the worker's count instead (`session_flow.queuePacket`).
fn fail(gateway: *Gateway, session: *Session, fetch: ipc.EgressFetchStartView, text: []const u8) void {
    const bytes = ipc.encodeEgressFetchErrorInto(gateway.encode_scratch, .{
        .fetch_id = fetch.fetch_id,
        .body_id = fetch.body_id,
        .message = text,
        .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
    }) catch |err| {
        std.log.warn("egress gateway could not encode a refusal fetch_id={d}: {s}", .{ fetch.fetch_id, @errorName(err) });
        session_flow.markForDrop(gateway, session, "refusal not encoded");
        return;
    };
    session_flow.queuePacket(gateway, session, bytes) catch return;
}
