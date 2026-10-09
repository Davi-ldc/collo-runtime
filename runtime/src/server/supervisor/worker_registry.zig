//! The lives of the supervisor's worker records beyond what a pool decides.
//! A pool says which table entry a launch holds and when a worker is finished
//! (`pool.zig`); this file fills the entry's record for the launch's publish
//! and empties it again in the teardown that ends a finished worker.
//!
//! `buildRecord` runs on the launcher thread, which alone touches a launching
//! entry's record and the supervisor's worker counters. `teardown` blocks on
//! the worker's exit, its final drains and its cgroup removal, so it runs on
//! the reaper thread for a retirement, and on the exiting thread for the
//! workers `Supervisor.deinit` finds still held; never on a lane.

const std = @import("std");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const lifecycle = @import("collo_server_lifecycle");
const config = @import("collo_server_config");

const launcher = @import("launcher.zig");
const pool = @import("pool.zig");
const worker_table = @import("worker_table.zig");
const usage_drain = @import("usage_drain.zig");

const Supervisor = @import("supervisor.zig").Supervisor;
const WorkerRecord = worker_table.Record;

/// Builds the record of the worker `ready` describes in the storage of the
/// entry `ticket` holds in `definition`'s pool, under the next worker key,
/// and returns it for `Pool.publish`. The record owns `ready.handle`,
/// `ready.egress_wake_set` and `ready.dispatch_send_scratch` from then on;
/// the launcher allocated the scratch before the fork, so the build
/// allocates nothing and cannot fail. Launcher thread only (`Deps.publish`
/// in `launcher.zig`).
pub fn buildRecord(
    supervisor: *Supervisor,
    definition: config.DefinitionIndex,
    ticket: pool.LaunchTicket,
    ready: launcher.ReadyWorker,
) *WorkerRecord {
    std.debug.assert(ready.dispatch_send_scratch.len == ipc.max_message_bytes);
    const record = supervisor.ticketRecord(definition, ticket);
    const key: lifecycle.WorkerKey = .{
        .worker_id = supervisor.next_worker_id,
        .worker_generation = supervisor.next_worker_generation,
    };
    supervisor.next_worker_id = lifecycle.nextGeneration(supervisor.next_worker_id);
    supervisor.next_worker_generation = lifecycle.nextGeneration(supervisor.next_worker_generation);
    record.occupy(.{
        .key = key,
        .handle = ready.handle,
        .dispatch_send_scratch = ready.dispatch_send_scratch,
        .egress_gateway_generation = ready.egress_generation,
        .egress_gateway_session_id = ready.egress_session_id,
        .egress_wake_set = ready.egress_wake_set,
        .created_mono_ns = process.monotonicNowNsOrZero(),
        .boot_work_ns = ready.boot_work_ns,
    });
    return record;
}

/// Ends the life of the worker `worker` holds and leaves the record vacant:
/// SIGKILL, the exit wait, the final drains of its usage and console rings
/// (`usage_drain.drainFinal`), then its handle and send scratch released
/// (`Record.vacate`), which removes its cgroup leaf. The server keeps no
/// record of the worker's egress session: the gateway drops the session
/// when the exit hangs up its liveness descriptor. The worker must be
/// finished in its pool, so that no lane holds a slot of it or reads it, or
/// its pool must be gone. The reaper calls `Pool.remove` after this returns,
/// which lets a launch reuse the entry. Blocks for up to the exit wait and
/// the cgroup removal's retries.
pub fn teardown(supervisor: *Supervisor, worker: *WorkerRecord) void {
    worker.signalKill();
    if (!worker.awaitExit())
        std.log.warn("worker pid={d} worker_id={d} did not exit after SIGKILL; its final drains may miss its last records", .{
            worker.handle.pid,
            worker.id,
        });
    usage_drain.drainFinal(supervisor.usageDrain(), worker);
    worker.vacate(supervisor.allocator);
}
