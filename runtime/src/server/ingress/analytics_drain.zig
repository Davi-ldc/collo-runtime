//! The ingress service's analytics drain, one pass per metrics tick: every
//! worker's console lines, then every worker's usage records, then the
//! workers to take out of service, then each lane's access records, then a
//! flush of the record files. Runs on the service's metrics thread, and once
//! more on the exiting thread after every producer has joined
//! (`drainFinal`). Console lines reach stderr from the service's console
//! thread (`Sink.flushConsole`), so a stalled stderr never holds this drain.
//!
//! Invariants:
//! - A worker's console ring is read only under its record's
//!   `metrics_mutex`, and only while `page_mapped` says its page is mapped;
//!   the reaper's final drain clears the flag under the same mutex before it
//!   unmaps the page. That mutex is also what keeps this drain and the final
//!   one from reading the same ring at once (`analytics/logs.zig`).
//! - A console line keeps the request id the worker wrote only when that
//!   worker's request table confirms it (`analytics/logs.zig`). Console lines
//!   drain before usage records, because the usage drain frees the table
//!   entries of the requests whose records it writes, and a line of such a
//!   request then has only the table's ring of ended requests to find it in.
//! - A failed ring is fatal or corrupt, which the worker's own memory
//!   caused, and is never read again: the console ring when its drain here
//!   fails (`log_ring_failed`), the usage record ring when a usage drain on
//!   any thread finds its head where no append puts it (`usage_ring_failed`,
//!   `server/supervisor/usage_drain.zig`). The worker then takes a fault seen
//!   off the lanes, `log_ring_corrupt` or `usage_record_protocol`:
//!   `Pool.markDead`, then `worker_died` to every lane the death names and
//!   the retirement when none holds or reads the worker
//!   (`Service.announceWorkerDeath`). `markDead` runs under the record's
//!   `metrics_mutex`, which keeps the record on the worker whose ring failed;
//!   the pool's mutex nests inside it and takes no other lock, and the posts
//!   wait until the mutex is let go.
//! - A worker whose VM thread still works for an owner past that owner's
//!   deadline by `ownerOverrunGraceNs` is hung: its sentinel did not stop the
//!   owner, is gone, or the thread is stuck where no termination is checked.
//!   The drain takes it out of service as `owner_overran`, the way it takes
//!   out a worker whose ring failed; the lanes end its requests as the grace
//!   backstop does (`runner/worker_fault.zig`) and the reaper kills it. The
//!   deadline is the worker's claim (`OwnerSnapshot` in
//!   `common/worker_state/page/snapshots.zig`) and is added to the grace with
//!   saturating arithmetic, so a worker that writes a deadline near the top
//!   of the clock only keeps itself alive, and no sum wraps into an early
//!   fault.
//! - The record whose console drains first moves one place along the table
//!   every tick. A worker that fills the console buffer on its own then
//!   crowds out a different set of workers each tick, instead of always the
//!   ones behind it.
//! - Console lines reach stderr whether or not an analytics directory is
//!   configured; `analytics/sink.zig` counts and drops the record kinds that
//!   have no file.
//!
//! `State` belongs to the metrics thread.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const config = @import("collo_server_config");
const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const page = @import("collo_worker_state").page;
const fault = @import("fault.zig");
const service_observability = @import("service_observability.zig");

const WorkerRecord = supervision.worker_table.Record;
const WorkerPool = supervision.WorkerPool;
const ConsoleRequests = analytics.logs.WorkerRequests(supervision.request_table.RequestTable, config.Route);

/// Lines drained from one worker per tick before the drain moves on to the
/// next worker. A fairness bound: a producer that outruns it fills its own
/// ring, which drops the newest lines and counts them for the drop marker.
pub const worker_lines_per_tick_max: usize = 2048;

pub const State = struct {
    /// Ticks so far; modulo the record count, the record whose console this
    /// tick drains first.
    ticks: usize = 0,
};

/// How far past its owner's deadline a worker's VM thread may run before
/// the drain faults the worker as `owner_overran`: the lanes' grace backstop
/// plus one metrics interval. A request that owns the overrun is past its
/// own deadline too, so its backstop, at its deadline plus
/// `hard_timeout_grace_ns` (`runner/deadline_driver.zig`), fires first and
/// owns the death; this watch is for the owners no lane watches: the worker
/// owner, and an evaluation that runs after WorkerReady.
pub fn ownerOverrunGraceNs(hard_timeout_grace_ns: u64) u64 {
    return hard_timeout_grace_ns +| service_observability.metrics_drain_interval_ns;
}

/// Whether a worker whose page names an owner due at `deadline_mono_ns`
/// (CLOCK_MONOTONIC, 0 for an owner without a deadline or for none) has
/// overrun it at `now_ns` by more than `grace_ns`. Pure, so the rule is
/// testable without a page.
pub fn ownerOverran(deadline_mono_ns: u64, now_ns: u64, grace_ns: u64) bool {
    if (deadline_mono_ns == 0)
        return false;
    return now_ns > deadline_mono_ns +| grace_ns;
}

/// One metrics tick. `service` provides `supervisor` (its `records`,
/// `routes`, `usage_counters`, `hard_timeout_grace_ns`, `usageDrain` and
/// pools), `analytics`, `analytics_drain`, `lanes`, each lane with an
/// `access_ring`, and `announceWorkerDeath`.
pub fn tick(service: anytype) void {
    const clock = analytics.Clock.capture();
    drainAt(service, clock, clock.mono_now_ns, .announce);
}

/// The last tick, from the exiting thread once the metrics thread, the
/// lanes, the launcher and the reaper have joined: only then are the rings
/// complete. No lane is left to tell and no reaper to retire a worker, and
/// `Supervisor.deinit` tears down every worker still held, so a worker found
/// faulty now is only marked.
pub fn drainFinal(service: anytype) void {
    const clock = analytics.Clock.capture();
    drainAt(service, clock, clock.mono_now_ns, .mark_only);
}

/// What the drain does with a worker it finds faulty.
pub const OnWorkerFault = enum {
    /// Takes the worker out of service and tells the lanes.
    announce,
    /// Only stops reading the failed ring.
    mark_only,
};

/// `tick` against a given clock: records are dated by `clock`, an owner's
/// deadline is compared with its monotonic reading, and `now_ns` is the
/// monotonic time the sink's sync interval is measured against.
pub fn drainAt(
    service: anytype,
    clock: analytics.Clock,
    now_ns: u64,
    on_fault: OnWorkerFault,
) void {
    const records = service.supervisor.records;
    if (records.len != 0) {
        const first = service.analytics_drain.ticks % records.len;
        for (0..records.len) |offset|
            drainConsole(service, &records[(first + offset) % records.len], clock, on_fault);
        // A full usage stream is written out and offered the batch again,
        // and drops and counts only what a write-out leaves no room for
        // (`usage_drain.zig`), so nothing here is fatal.
        supervision.usage_drain.drainAll(service.supervisor.usageDrain(), records);
        const grace_ns = ownerOverrunGraceNs(service.supervisor.hard_timeout_grace_ns);
        for (records) |*worker|
            checkWorker(service, worker, clock.mono_now_ns, grace_ns, on_fault);
    }
    service.analytics_drain.ticks +%= 1;
    for (service.lanes) |*lane|
        analytics.access.drainRing(&lane.access_ring, service.analytics, clock);
    service.analytics.flush(now_ns);
}

/// A worker this drain took out of service: what `Service.announceWorkerDeath`
/// needs once `metrics_mutex` is let go.
const WorkerDeath = struct {
    worker_key: lifecycle.WorkerKey,
    death: WorkerPool.Death,
    reason: fault.WorkerFaultReason,
};

fn drainConsole(
    service: anytype,
    worker: *WorkerRecord,
    clock: analytics.Clock,
    on_fault: OnWorkerFault,
) void {
    const worker_death = drainConsoleLocked(service, worker, clock, on_fault) orelse return;
    service.announceWorkerDeath(worker, worker_death.worker_key, worker_death.death, worker_death.reason);
}

/// Drains `worker`'s console ring under its `metrics_mutex`, each line's
/// request id checked against the worker's request table, and takes the
/// worker out of service when the ring fails. Returns the death to announce
/// when this call took the worker out of service, and null otherwise.
fn drainConsoleLocked(
    service: anytype,
    worker: *WorkerRecord,
    clock: analytics.Clock,
    on_fault: OnWorkerFault,
) ?WorkerDeath {
    worker.metrics_mutex.lock();
    defer worker.metrics_mutex.unlock();
    if (!worker.page_mapped)
        return null;
    if (worker.log_ring_failed)
        return null;
    const view = if (worker.handle.metrics) |*mapped| mapped else return null;
    var requests: ConsoleRequests = .{
        .table = &worker.requests,
        .routes = service.supervisor.routes.definition(worker.definition_index).routes,
    };
    const drained = analytics.logs.drainRing(
        view,
        &requests,
        analytics.Identity.ofWorker(worker),
        &worker.log_drops_reported,
        service.analytics,
        clock,
        worker_lines_per_tick_max,
    ) catch |err| {
        worker.log_ring_failed = true;
        std.log.warn("worker log ring drain failed; the worker leaves service worker_id={d}: {s}", .{
            worker.id,
            @errorName(err),
        });
        return takeOutOfService(service, worker, on_fault, .log_ring_corrupt);
    };
    if (drained.ids_refused != 0)
        _ = service.supervisor.usage_counters.console_ids_refused.fetchAdd(drained.ids_refused, .monotonic);
    return null;
}

fn checkWorker(
    service: anytype,
    worker: *WorkerRecord,
    now_ns: u64,
    grace_ns: u64,
    on_fault: OnWorkerFault,
) void {
    const worker_death = checkWorkerLocked(service, worker, now_ns, grace_ns, on_fault) orelse return;
    service.announceWorkerDeath(worker, worker_death.worker_key, worker_death.death, worker_death.reason);
}

/// Takes `worker` out of service, under its `metrics_mutex`, when a usage
/// drain on any thread found its usage ring corrupt
/// (`Record.usage_ring_failed`) or its VM thread overran its owner's
/// deadline. Returns the death to announce when this call took the worker
/// out of service, and null otherwise.
fn checkWorkerLocked(
    service: anytype,
    worker: *WorkerRecord,
    now_ns: u64,
    grace_ns: u64,
    on_fault: OnWorkerFault,
) ?WorkerDeath {
    worker.metrics_mutex.lock();
    defer worker.metrics_mutex.unlock();
    if (!worker.page_mapped)
        return null;
    // Every tick finds the mark again until the reaper's final drain clears
    // `page_mapped`; `markDead` answers null once the worker left service, so
    // at most one tick announces the death.
    if (worker.usage_ring_failed)
        return takeOutOfService(service, worker, on_fault, .usage_record_protocol);
    const view = if (worker.handle.metrics) |*mapped| mapped else return null;
    const owner = page.OwnerSnapshot.load(view.header);
    if (!ownerOverran(owner.deadline_mono_ns, now_ns, grace_ns))
        return null;
    const worker_death = takeOutOfService(service, worker, on_fault, .owner_overran) orelse return null;
    std.log.warn("worker overran its owner's deadline and leaves service worker_id={d} owner_id={d} overrun_ms={d}", .{
        worker.id,
        owner.owner_id,
        (now_ns - owner.deadline_mono_ns) / std.time.ns_per_ms,
    });
    return worker_death;
}

/// Takes `worker` out of service for `reason`, unless the drain only marks
/// faulty workers. Null when it did not, or when the worker had left service
/// already and whoever took it out finishes it.
fn takeOutOfService(
    service: anytype,
    worker: *WorkerRecord,
    on_fault: OnWorkerFault,
    reason: fault.WorkerFaultReason,
) ?WorkerDeath {
    switch (on_fault) {
        .mark_only => return null,
        .announce => {
            const worker_key = worker.key();
            const death = service.supervisor.poolFor(worker.definition_index).markDead(worker, worker_key) orelse return null;
            return .{ .worker_key = worker_key, .death = death, .reason = reason };
        },
    }
}
