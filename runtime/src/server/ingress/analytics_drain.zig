//! The ingress service's analytics drain: on every metrics tick it moves each
//! worker's console lines and each lane's access records into the analytics
//! sink, takes out of service each worker one of whose page rings failed,
//! then flushes the record files. Runs on the service's metrics thread, and
//! once more on the exiting thread after every producer has joined
//! (`drainFinal`). Console lines reach stderr from the service's console
//! thread (`Sink.flushConsole`), so a stalled stderr never holds this drain.
//!
//! Invariants:
//! - A worker's console ring is read only under its record's
//!   `metrics_mutex`, and only while `page_mapped` says its page is mapped;
//!   the reaper's final drain clears the flag under the same mutex before it
//!   unmaps the page. That mutex is also what keeps this drain and the final
//!   one from reading the same ring at once (`analytics/logs.zig`).
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
//! - The record that drains first moves one place along the table every
//!   tick. A worker that fills the console buffer on its own then crowds out
//!   a different set of workers each tick, instead of always the ones behind
//!   it.
//! - Console lines reach stderr whether or not an analytics directory is
//!   configured; `analytics/sink.zig` counts and drops the record kinds that
//!   have no file.
//!
//! `State` belongs to the metrics thread.

const std = @import("std");
const analytics = @import("collo_server_analytics");
const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const fault = @import("fault.zig");

const WorkerRecord = supervision.worker_table.Record;
const WorkerPool = supervision.WorkerPool;

/// Lines drained from one worker per tick before the drain moves on to the
/// next worker. A fairness bound: a producer that outruns it fills its own
/// ring, which drops the newest lines and counts them for the drop marker.
pub const worker_lines_per_tick_max: usize = 2048;

pub const State = struct {
    /// Ticks so far; modulo the record count, the record this tick drains
    /// first.
    ticks: usize = 0,
};

/// One metrics tick. `service` provides `supervisor` (its `records` and
/// pools), `analytics`, `analytics_drain`, `lanes`, each lane with an
/// `access_ring`, and `announceWorkerDeath`.
pub fn tick(service: anytype) void {
    const clock = analytics.Clock.capture();
    drainAt(service, clock, clock.mono_now_ns, .announce);
}

/// The last tick, from the exiting thread once the metrics thread, the
/// lanes, the launcher and the reaper have joined: only then are the rings
/// complete. No lane is left to tell and no reaper to retire a worker, and
/// `Supervisor.deinit` tears down every worker still held, so a ring that
/// fails now is only marked.
pub fn drainFinal(service: anytype) void {
    const clock = analytics.Clock.capture();
    drainAt(service, clock, clock.mono_now_ns, .mark_only);
}

/// What the drain does with a worker one of whose rings failed.
pub const OnRingFailure = enum {
    /// Takes the worker out of service and tells the lanes.
    announce,
    /// Only stops reading the ring.
    mark_only,
};

/// `tick` against a given clock: records are dated by `clock`, and `now_ns`
/// is the monotonic time the sink's sync interval is measured against.
pub fn drainAt(
    service: anytype,
    clock: analytics.Clock,
    now_ns: u64,
    on_ring_failure: OnRingFailure,
) void {
    const records = service.supervisor.records;
    if (records.len != 0) {
        const first = service.analytics_drain.ticks % records.len;
        for (0..records.len) |offset|
            drainWorker(service, &records[(first + offset) % records.len], clock, on_ring_failure);
    }
    service.analytics_drain.ticks +%= 1;
    for (service.lanes) |*lane|
        analytics.access.drainRing(&lane.access_ring, service.analytics, clock);
    service.analytics.flush(now_ns);
}

/// A worker one of whose rings failed and that this drain took out of
/// service: what `Service.announceWorkerDeath` needs once `metrics_mutex` is
/// let go.
const RingDeath = struct {
    worker_key: lifecycle.WorkerKey,
    death: WorkerPool.Death,
    reason: fault.WorkerFaultReason,
};

fn drainWorker(
    service: anytype,
    worker: *WorkerRecord,
    clock: analytics.Clock,
    on_ring_failure: OnRingFailure,
) void {
    const ring_death = drainWorkerLocked(service, worker, clock, on_ring_failure) orelse return;
    service.announceWorkerDeath(worker, ring_death.worker_key, ring_death.death, ring_death.reason);
}

/// Drains `worker`'s console ring under its `metrics_mutex`, and takes the
/// worker out of service when that ring fails here or a usage drain on any
/// thread found its usage ring corrupt (`Record.usage_ring_failed`). Returns
/// the death to announce when this call took the worker out of service, and
/// null otherwise.
fn drainWorkerLocked(
    service: anytype,
    worker: *WorkerRecord,
    clock: analytics.Clock,
    on_ring_failure: OnRingFailure,
) ?RingDeath {
    worker.metrics_mutex.lock();
    defer worker.metrics_mutex.unlock();
    if (!worker.page_mapped)
        return null;
    if (!worker.log_ring_failed) {
        if (worker.handle.metrics) |*view| {
            _ = analytics.logs.drainRing(
                view,
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
                return takeOutOfService(service, worker, on_ring_failure, .log_ring_corrupt);
            };
        }
    }
    // Every tick finds the mark again until the reaper's final drain clears
    // `page_mapped`; `markDead` answers null once the worker left service, so
    // at most one tick announces the death.
    if (worker.usage_ring_failed)
        return takeOutOfService(service, worker, on_ring_failure, .usage_record_protocol);
    return null;
}

/// Takes `worker` out of service for `reason`, unless the drain only marks
/// failed rings. Null when it did not, or when the worker had left service
/// already and whoever took it out finishes it.
fn takeOutOfService(
    service: anytype,
    worker: *WorkerRecord,
    on_ring_failure: OnRingFailure,
    reason: fault.WorkerFaultReason,
) ?RingDeath {
    switch (on_ring_failure) {
        .mark_only => return null,
        .announce => {
            const worker_key = worker.key();
            const death = service.supervisor.poolFor(worker.definition_index).markDead(worker, worker_key) orelse return null;
            return .{ .worker_key = worker_key, .death = death, .reason = reason };
        },
    }
}
