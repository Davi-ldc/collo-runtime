//! The lives of the supervisor's worker records beyond what a pool decides.
//! A pool says which table entry a launch holds and when a worker is finished
//! (`pool.zig`); this file fills the entry's record for the launch's publish
//! and empties it again in the teardown that ends a finished worker, which
//! drains the worker's last console lines and writes its line in
//! `workers.jsonl`.
//!
//! The worker line is the record of what no request owns: the CPU of the
//! worker's whole life, boot, collection, compilation and JavaScript no
//! request owned included, as the kernel counted it in the worker's cgroup
//! (`cpu.stat` `usage_usec`), so the worker cannot forge it, and the peak of
//! its memory (`memory.peak`). It is read after the worker's exit, so the
//! count is final, and before `Record.vacate` removes the cgroup. Every
//! worker the server ends gets one, the ones its shutdown stops included.
//!
//! `buildRecord` runs on the launcher thread, which alone touches a launching
//! entry's record and the supervisor's worker counters. `teardown` blocks on
//! the worker's exit, its last console drain and its cgroup removal, so it
//! runs on the reaper thread for a retirement, and on the exiting thread for
//! the workers `Supervisor.deinit` finds still held; never on a lane.

const std = @import("std");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const cgroup = @import("collo_cgroup");
const lifecycle = @import("collo_server_lifecycle");
const config = @import("collo_server_config");
const analytics = @import("collo_server_analytics");

const launcher = @import("launcher.zig");
const pool = @import("pool.zig");
const request_table = @import("request_table.zig");
const worker_table = @import("worker_table.zig");

const Supervisor = @import("supervisor.zig").Supervisor;
const WorkerRecord = worker_table.Record;
const ConsoleRequests = analytics.logs.WorkerRequests(request_table.RequestTable, config.Route);

/// How a worker's life ended, as its line in `workers.jsonl` says it.
pub const Ending = analytics.workers.Ending;

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
        .boot_egress = ready.boot_egress,
    });
    return record;
}

/// Ends the life of the worker `worker` holds and leaves the record vacant:
/// SIGKILL, the exit wait, the last drain of its console ring
/// (`drainDyingConsole`), its line in `workers.jsonl`, which says it ended
/// as `ending`, then its handle and send scratch released
/// (`Record.vacate`), which removes its cgroup leaf. The server keeps no
/// record of the worker's egress session: the gateway drops the session
/// when the exit hangs up its liveness descriptor. The worker must be
/// finished in its pool, so that no lane holds a slot of it or reads it, or
/// its pool must be gone. The reaper calls `Pool.remove` after this returns,
/// which lets a launch reuse the entry. Blocks for up to the exit wait and
/// the cgroup removal's retries.
pub fn teardown(supervisor: *Supervisor, worker: *WorkerRecord, ending: Ending) void {
    worker.signalKill();
    if (!worker.awaitExit())
        std.log.warn("worker pid={d} worker_id={d} did not exit after SIGKILL; its last console lines may be lost", .{
            worker.handle.pid,
            worker.id,
        });
    drainDyingConsole(supervisor, worker);
    writeWorkerRecord(supervisor, worker, ending);
    worker.vacate(supervisor.allocator);
}

/// The last drain of `worker`'s console ring and the end of every drain:
/// under one hold of `worker.metrics_mutex`, the ring drains into the sink
/// (`analytics.logs.drainDyingRing`) and the page is marked unmapped, so the
/// metrics thread never reads it again and `Record.vacate` may unmap it.
/// The worker has exited, or the exit wait gave up, so the ring holds its
/// last lines. A line keeps its request id only when the worker's request
/// table confirms the request, as the metrics thread's drain does; the
/// table is left as it is, and the record's next worker starts with a table
/// of its own (`Record.occupy`).
fn drainDyingConsole(supervisor: *Supervisor, worker: *WorkerRecord) void {
    worker.metrics_mutex.lock();
    defer worker.metrics_mutex.unlock();
    if (!worker.page_mapped)
        return;
    defer worker.page_mapped = false;
    // A ring that already failed is never read again
    // (`Record.log_ring_failed`).
    if (worker.log_ring_failed)
        return;
    const view = if (worker.handle.metrics) |*mapped| mapped else return;
    var requests: ConsoleRequests = .{
        .table = &worker.requests,
        .routes = supervisor.routes.definition(worker.definition_index).routes,
    };
    // A line whose request id the table refuses prints under request id 0,
    // which is all a refusal costs.
    _ = analytics.logs.drainDyingRing(
        view,
        &requests,
        analytics.Identity.ofWorker(worker),
        &worker.log_drops_reported,
        supervisor.analytics,
    );
}

/// Appends `worker`'s line to `workers.jsonl` (`analytics.workers`). A
/// figure its cgroup cannot give is null. A full stream is written out and
/// offered the line again, which the teardown's thread may block for (file
/// header), since a shutdown tears down every worker still held with no
/// flush between them; a line that still finds no room is dropped and
/// counted.
fn writeWorkerRecord(supervisor: *Supervisor, worker: *WorkerRecord, ending: Ending) void {
    const sink = supervisor.analytics;
    if (!sink.enabled(.workers)) {
        sink.noteDiscarded(.workers, 1);
        return;
    }
    const clock = analytics.Clock.capture();
    const record: analytics.workers.WorkerRecord = .{
        .worker = worker.name,
        .worker_id = worker.id,
        .worker_generation = worker.generation,
        .started_ts_ms = clock.wallMs(worker.created_mono_ns),
        .ts_ms = clock.wall_now_ms,
        .life_ns = clock.mono_now_ns -| worker.created_mono_ns,
        .worker_cpu_ns = readWorkerCpuNs(worker),
        .memory_peak_bytes = readWorkerMemoryPeak(worker),
        .ending = ending,
    };
    var buffer: [analytics.workers.json_record_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    // The buffer holds the largest record, so the writer cannot run out.
    analytics.workers.writeRecordJson(&writer, &record) catch unreachable;
    const line = writer.buffered();
    if (sink.tryAppend(.workers, line)) return;
    sink.flush(process.monotonicNowNsOrZero());
    sink.appendLossy(.workers, line);
}

/// The CPU every thread of the worker used over its life, from its cgroup
/// leaf (`cpu.stat` `usage_usec`); null when the leaf cannot say.
fn readWorkerCpuNs(worker: *const WorkerRecord) ?u64 {
    const usage_usec = cgroup.readLeafFigure(worker.handle.leaf, .cpu_usage_usec) catch |err| {
        std.log.debug("worker line: cpu.stat read failed for worker_id={d}: {s}", .{ worker.id, @errorName(err) });
        return null;
    };
    return usage_usec *| std.time.ns_per_us;
}

/// The worker's peak memory from its cgroup leaf; null on a kernel without
/// `memory.peak` (before Linux 5.19) or when the leaf cannot say.
fn readWorkerMemoryPeak(worker: *const WorkerRecord) ?u64 {
    return cgroup.readLeafFigure(worker.handle.leaf, .memory_peak) catch |err| {
        std.log.debug("worker line: memory.peak read failed for worker_id={d}: {s}", .{ worker.id, @errorName(err) });
        return null;
    };
}
