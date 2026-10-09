//! The supervisor's side of the launcher's egress `Deps`
//! (`server/supervisor/launcher.zig`) and the end of a launch that produced no
//! worker: which definitions get an egress session, the session and boot token
//! grant a worker is attached with, and the ticket a failed launch gives back.
//! The claim is `Supervisor.claimLaunch`, and the record a ready worker is
//! built into is `worker_registry.buildRecord`.
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
const policy = @import("collo_egress_gateway").policy;

const launcher = @import("launcher.zig");
const pool = @import("pool.zig");

const Supervisor = @import("supervisor.zig").Supervisor;

/// Whether workers of `definition` get an egress session, at launch and again
/// after their gateway is lost. Every definition has a grant: the
/// configuration has no `network` setting that could withhold one.
pub fn definitionHasEgressGrant(definition: *const config.WorkerDefinition) bool {
    _ = definition;
    return true;
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
    if (!definitionHasEgressGrant(supervisor.routes.definition(definition)))
        return null;
    var attachment = (try supervisor.attachEgressGatewayForDefinition(definition, wake_set)) orelse
        return error.EgressGatewayRequired;
    errdefer attachment.deinit();
    if (!attachment.isValid())
        return error.EgressGatewayRequired;
    return .{
        .attachment = attachment,
        .boot = bootEgress(supervisor, &attachment),
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
/// The policy is the one entry of every gateway's table.
fn bootEgress(
    supervisor: *Supervisor,
    attachment: *const lifecycle.EgressGatewayAttachment,
) ?host.launch.BootEgress {
    var key: ipc.egress_token.Key = undefined;
    // The grant keeps the one copy the launch needs; this frame keeps none.
    defer std.crypto.secureZero(u8, &key.bytes);
    if (!supervisor.egressGatewayKeyFor(attachment.generation, &key))
        return null;
    return .{
        .key = key,
        .session_id = attachment.session_id,
        .policy_id = policy.public_https_id,
        .budget = @intCast(policy.production.max_fetches_per_boot),
    };
}
