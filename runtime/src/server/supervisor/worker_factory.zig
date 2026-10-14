//! The supervisor's side of the launcher's egress `Deps`
//! (`server/supervisor/launcher.zig`) and the end of a launch that produced no
//! worker: which definitions get an egress session, the session and boot token
//! grant a worker is attached with, and the ticket a failed launch gives back.
//! The claim is `Supervisor.claimLaunch`, and the record a ready worker is
//! built into is `worker_registry.buildRecord`.
//!
//! A definition gets egress only when some route of it has a `network` grant
//! (`server/routes/network.zig`). A worker of any other definition gets no
//! wake set, no session and no boot token, so it holds no egress path at all,
//! no gateway is spawned on its account, and the reattach pass never names
//! it. A granted definition's boot token names its boot policy, the union of
//! its routes' grants, which its routes' module top-level code fetches under.
//!
//! Everything here runs on the launcher thread. `attachLaunchEgress` waits for
//! the gateway's answer to the attach, one round trip on the server's control
//! channel to the gateway, which the launcher never makes while a fork request
//! is outstanding. A session needs no teardown here: the gateway drops it once
//! every copy of its liveness descriptor is closed.

const std = @import("std");
const ipc = @import("collo_ipc");
const host = @import("collo_host");
const lifecycle = @import("collo_server_lifecycle");
const config = @import("collo_server_config");

const launcher = @import("launcher.zig");
const pool = @import("pool.zig");

const Supervisor = @import("supervisor.zig").Supervisor;

/// Whether workers of `definition` get an egress wake set and session, at
/// launch and again after their gateway is lost: exactly when some route of
/// it has a `network` grant.
pub fn definitionHasEgressGrant(supervisor: *const Supervisor, definition: config.DefinitionIndex) bool {
    return supervisor.routes.network.definitionGranted(definition);
}

/// Attaches a new egress session for a worker of `definition`, built on
/// `wake_set`, the worker's wake set, with the grant of the boot token a
/// launch sends, or returns null when the definition has no egress grant.
/// `boot` is null when the session's gateway was no longer current once the
/// attach returned. Fails with `error.EgressGatewayRequired` when no gateway
/// is wired or the attachment is incomplete, and with the attach hook's error
/// otherwise (`Manager.attachWorker`); nothing stays attached then. The
/// caller owns the attachment.
pub fn attachLaunchEgress(
    supervisor: *Supervisor,
    definition: config.DefinitionIndex,
    wake_set: *const ipc.egress_shared.WakeSet,
) anyerror!?launcher.EgressAttach {
    if (!definitionHasEgressGrant(supervisor, definition))
        return null;
    var attachment = (try supervisor.attachEgressGatewayForDefinition(definition, wake_set)) orelse
        return error.EgressGatewayRequired;
    errdefer attachment.deinit();
    if (!attachment.isValid())
        return error.EgressGatewayRequired;
    return .{
        .attachment = attachment,
        .boot = bootEgress(supervisor, definition, &attachment),
    };
}

/// Ends a launch of `definition` that produced no worker: gives its ticket
/// back to the pool. The caller then answers the waiters left with nothing to
/// serve them (`Pool.takeStranded`) and hands the launch's leftovers to the
/// reaper (`Reaper.queueLeftovers`). Never fails.
pub fn endLaunch(
    supervisor: *Supervisor,
    definition: config.DefinitionIndex,
    ticket: pool.LaunchTicket,
) void {
    // Only the launcher holds a ticket, and it hands each one to exactly one
    // of `Deps.publish` and `Deps.failed`, so the entry is still launching.
    supervisor.poolFor(definition).launchEnded(ticket) catch unreachable;
}

/// What the boot token of `attachment`'s session carries besides its
/// deadline, which `host/launch.zig` fixes when it sends WorkerInit; null when
/// the session's gateway is no longer current, so no key can sign the token.
/// The policy is `definition`'s boot policy, never 0 for a granted one.
fn bootEgress(
    supervisor: *Supervisor,
    definition: config.DefinitionIndex,
    attachment: *const lifecycle.EgressGatewayAttachment,
) ?host.launch.BootEgress {
    const policy_id = supervisor.routes.network.bootPolicy(definition);
    // Only a granted definition attaches, and granted means a boot policy
    // other than 0.
    std.debug.assert(policy_id != 0);
    var key: ipc.egress_token.Key = undefined;
    // The grant keeps the one copy the launch needs; this frame keeps none.
    defer std.crypto.secureZero(u8, &key.bytes);
    if (!supervisor.egressGatewayKeyFor(attachment.generation, &key))
        return null;
    return .{
        .key = key,
        .session_id = attachment.session_id,
        .policy_id = policy_id,
    };
}
